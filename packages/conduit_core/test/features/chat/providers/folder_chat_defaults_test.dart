import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

const _previous = Model(id: 'previous', name: 'Previous chat model');
const _fallback = Model(id: 'fallback', name: 'User default');
const _modelA = Model(id: 'm-a', name: 'Model A');
const _modelB = Model(id: 'm-b', name: 'Model B');

const _offered = [_modelA, _modelB, _fallback];

enum _Wait {
  savedPick('a saved model is about to be picked', ['m-b']),
  retiredSaved('the user default replaces retired saved models', ['retired']),
  cachedDefault('the cached default is being cleared', null),
  defaultResolution('the user default is being resolved', null),
  // The cache says Model A; the held answer, Model B.
  folderDetail("the folder's own defaults are being read", ['m-a']);

  const _Wait(this.label, this.saved);

  final String label;
  final List<Object?>? saved;
}

class _GatedModels extends Models {
  _GatedModels(this.gate);

  final Completer<List<Model>> gate;

  @override
  Future<List<Model>> build() => gate.future;
}

class _Selected extends SelectedModel {
  @override
  Model? build() => _previous;
}

class _Active extends ActiveConversationNotifier {
  _Active(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

class _Epoch extends Notifier<Object> {
  @override
  Object build() => Object();

  void rotate() => state = Object();
}

final _epochProvider = NotifierProvider<_Epoch, Object>(_Epoch.new);

/// Holds the clearing of the cached default, which is the first await of a
/// restore that has no saved folder model, until [release] is called.
class _Storage extends Fake implements OptimizedStorageService {
  final entered = Completer<void>();
  Completer<void>? _gate;

  void hold() => _gate = Completer<void>();

  void release() => _gate!.complete();

  @override
  Future<void> saveLocalDefaultModel(Model? model) async {
    final gate = _gate;
    if (model == null && gate != null) {
      entered.complete();
      await gate.future;
    }
  }
}

/// The server's folder-by-id answers. A folder it has no answer for is a
/// failed request (offline), and [hold] keeps every answer back until
/// [release].
class _ServerApi extends ApiService {
  _ServerApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server-a',
          name: 'Server A',
          url: 'https://server-a.example.test',
        ),
        workerManager: WorkerManager(),
      );

  final answers = <String, Map<String, dynamic>>{};
  Completer<void>? _gate;

  void hold() => _gate = Completer<void>();

  void release() => _gate!.complete();

  @override
  Future<Map<String, dynamic>?> getFolderById(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    await _gate?.future;
    final answer = answers[id];
    if (answer != null) return answer;
    throw DioException(
      requestOptions: RequestOptions(path: '/api/v1/folders/$id'),
      type: DioExceptionType.connectionError,
    );
  }
}

/// The project data the server holds for [id], as `GET /folders/{id}` answers.
Map<String, dynamic> _detail(String id, {Object? modelIds}) => {
  'id': id,
  'name': id,
  'created_at': 1,
  'updated_at': 3,
  'data': {'system_prompt': 'Folder prompt', 'model_ids': modelIds},
};

/// A listed folder. The server's real list is [lean] and has no `data` at all.
Map<String, dynamic> _folder(
  String id, {
  List<Object?>? modelIds,
  bool lean = false,
}) => {
  'id': id,
  'name': id,
  'created_at': 1,
  'updated_at': 2,
  if (lean) ...{
    'meta': null,
    'is_expanded': false,
    'unread_count': 0,
  } else
    'data': {
      'system_prompt': 'Folder prompt',
      'files': [
        {'type': 'collection', 'id': 'kb-1', 'name': 'Docs'},
      ],
      'model_ids': ?modelIds,
    },
};

void main() {
  late AppDatabase db;
  late Completer<List<Model>> modelsGate;
  late _Storage storage;
  late _ServerApi api;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    modelsGate = Completer<List<Model>>();
    storage = _Storage();
    api = _ServerApi();
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    // The user's own default, which the real default resolution applies when a
    // draft has no usable saved model.
    return SettingsService.setDefaultModel(_fallback.id);
  });

  tearDown(() async {
    await db.close();
    PreferencesStore.debugReset();
  });

  /// A signed-in account with a folder list read from the real database, a
  /// draft inside folder `f-1`, and a model list that arrives when
  /// [modelsGate] is completed.
  Future<ProviderContainer> draftIn({
    List<Object?>? saved,
    Conversation? active,
    String pendingFolder = 'f-1',
    bool lean = false,
  }) async {
    await db.foldersDao.replaceServerFolders([
      _folder('f-1', modelIds: saved, lean: lean),
      _folder('f-2', modelIds: ['m-a']),
    ]);
    final c = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        apiServiceProvider.overrideWithValue(api),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWithValue('token'),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'me',
            email: 'me@example.test',
            role: 'user',
          ),
        ),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(_epochProvider),
        ),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(_Selected.new),
        activeConversationProvider.overrideWith(() => _Active(active)),
        modelsProvider.overrideWith(() => _GatedModels(modelsGate)),
        optimizedStorageServiceProvider.overrideWithValue(storage),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        isAuthLoadingProvider2.overrideWithValue(false),
        authStatusProvider.overrideWithValue(AuthStatus.authenticated),
      ],
    );
    addTearDown(c.dispose);
    c.read(pendingFolderIdProvider.notifier).set(pendingFolder);
    return c;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  group('a new draft inside a folder', () {
    test('starts on the first saved model the server still offers', () async {
      final c = await draftIn(saved: ['retired', 'm-b', 'm-a']);

      final started = restoreFolderDraftModel(c, 'f-1');
      modelsGate.complete([_previous, _modelA, _modelB]);
      await started;

      check(c.read(selectedModelProvider)).identicalTo(_modelB);
      check(c.read(isManualModelSelectionProvider)).isFalse();
      // The draft stays in the folder, which is what lets the server apply the
      // project's knowledge and system prompt to the chat.
      check(c.read(pendingFolderIdProvider)).equals('f-1');
      check(c.read(folderDraftModelNoticeProvider)).isNull();
    });

    test('a lean folder list after a save keeps the saved models', () async {
      final c = await draftIn(saved: ['m-b']);
      await c.read(foldersProvider.future);

      // The server's list has no project data, whatever was saved; the server
      // cannot be reached for the folder itself here.
      await db.foldersDao.replaceServerFolders([
        _folder('f-1', lean: true),
        _folder('f-2', lean: true),
      ]);
      await settle();

      final started = restoreFolderDraftModel(c, 'f-1');
      modelsGate.complete(_offered);
      await started;

      check(c.read(selectedModelProvider)).identicalTo(_modelB);
    });

    test('a folder listed without project data starts on what the folder '
        'itself has saved', () async {
      final c = await draftIn(lean: true);
      api.answers['f-1'] = _detail('f-1', modelIds: ['retired', 'm-b', 'm-a']);

      final started = restoreFolderDraftModel(c, 'f-1');
      modelsGate.complete(_offered);
      await started;

      check(c.read(selectedModelProvider)).identicalTo(_modelB);
      check(c.read(folderDraftModelNoticeProvider)).isNull();
    });

    test(
      'defaults changed in another client replace the cached ones',
      () async {
        final c = await draftIn(saved: ['m-a']);
        api.answers['f-1'] = _detail('f-1', modelIds: ['m-b']);

        final started = restoreFolderDraftModel(c, 'f-1');
        modelsGate.complete(_offered);
        await started;

        check(c.read(selectedModelProvider)).identicalTo(_modelB);
      },
    );

    for (final (name, answer) in <(String, Map<String, dynamic>)>[
      ('an emptied model list', _detail('f-1')),
      ('no project data at all', {..._detail('f-1'), 'data': null}),
    ]) {
      test('defaults cleared in another client ($name) leave the user '
          'default', () async {
        final c = await draftIn(saved: ['m-b']);
        api.answers['f-1'] = answer;

        final started = restoreFolderDraftModel(c, 'f-1');
        modelsGate.complete(_offered);
        await started;

        check(c.read(selectedModelProvider)).identicalTo(_fallback);
        check(c.read(folderDraftModelNoticeProvider)).isNull();
      });
    }

    test('never picks a hidden or a Hermes model from a saved list', () async {
      final hermes = hermesSyntheticModel();
      const hidden = Model(
        id: 'hidden-model',
        name: 'Hidden',
        metadata: {'hidden': true},
      );
      final c = await draftIn(saved: [hermes.id, hidden.id, 'm-a']);

      final started = restoreFolderDraftModel(c, 'f-1');
      modelsGate.complete([hermes, hidden, _modelA]);
      await started;

      check(c.read(selectedModelProvider)).identicalTo(_modelA);
    });

    test('uses the user default and says so when no saved model is offered', () async {
      final c = await draftIn(saved: ['retired-1', 'retired-2']);

      final started = restoreFolderDraftModel(c, 'f-1');
      modelsGate.complete(_offered);
      await started;

      check(c.read(selectedModelProvider)).identicalTo(_fallback);
      check(c.read(folderDraftModelNoticeProvider)).equals('f-1');
      // Reading the saved list is not editing it: the slots are still there for
      // when a model comes back.
      final folders = await c.read(foldersProvider.future);
      check(folders.firstWhere((folder) => folder.id == 'f-1').projectModelIds)
          .deepEquals(['retired-1', 'retired-2']);
    });

    test('claims nothing is missing when no model list is available', () async {
      final c = await draftIn(saved: ['m-a']);

      final started = restoreFolderDraftModel(c, 'f-1');
      await settle();
      modelsGate.completeError(StateError('models unavailable'));
      await started;

      check(c.read(selectedModelProvider)).identicalTo(_previous);
      check(c.read(folderDraftModelNoticeProvider)).isNull();
    });

    test(
      'a folder without saved models leaves the user default alone',
      () async {
        final c = await draftIn();

        final started = restoreFolderDraftModel(c, 'f-1');
        modelsGate.complete(_offered);
        await started;

        check(c.read(selectedModelProvider)).identicalTo(_fallback);
        check(c.read(folderDraftModelNoticeProvider)).isNull();
      },
    );
  });

  group('a folder that saves models to compare', () {
    List<String>? comparing(ProviderContainer c) => c
        .read(folderDraftComparisonModelsProvider)
        ?.map((model) => model.id)
        .toList();

    Future<ProviderContainer> restored(
      List<Object?> saved, {
      List<Model> offered = _offered,
    }) async {
      final c = await draftIn(saved: saved);
      final started = restoreFolderDraftModel(c, 'f-1');
      modelsGate.complete(offered);
      await started;
      return c;
    }

    test('two saved models start the draft comparing them, in slot order, '
        'with Advanced off', () async {
      final c = await restored(['m-b', 'm-a']);

      check(c.read(appSettingsProvider).advancedFeaturesEnabled).isFalse();
      check(c.read(selectedModelProvider)).identicalTo(_modelB);
      check(comparing(c)).isNotNull().deepEquals(['m-b', 'm-a']);
      check(c.read(folderDraftModelNoticeProvider)).isNull();
      check(c.read(folderDraftComparisonNoticeProvider)).isNull();
      check(c.read(pendingFolderIdProvider)).equals('f-1');
    });

    test('the same model saved twice is two slots', () async {
      final c = await restored(['m-a', 'm-a']);

      check(comparing(c)).isNotNull().deepEquals(['m-a', 'm-a']);
    });

    // Anything but exactly two usable slots cannot be one comparison. The draft
    // keeps the first usable model and says so, and the saved list is not edited.
    for (final (name, saved, usable, expectedComparing) in <
      (String, List<Object?>, List<Model>, List<String>?)
    >[
      ('three usable slots', ['m-a', 'm-b', 'fallback'], _offered, null),
      ('one slot gone', ['m-a', 'retired'], _offered, null),
      ('a Hermes slot', [hermesSyntheticModel().id, 'm-a'], [
        hermesSyntheticModel(),
        _modelA,
      ], null),
      // Two still make a comparison; the one that is gone is still explained.
      ('two usable slots and one gone', ['m-a', 'retired', 'm-b'], _offered, [
        'm-a',
        'm-b',
      ]),
    ]) {
      test('$name keeps the first usable model and says the saved models '
          'were not all used', () async {
        final c = await restored(saved, offered: usable);

        check(c.read(selectedModelProvider)).identicalTo(
          usable.firstWhere((model) => model.id == 'm-a'),
        );
        if (expectedComparing == null) {
          check(comparing(c)).isNull();
        } else {
          check(comparing(c)).isNotNull().deepEquals(expectedComparing);
        }
        check(c.read(folderDraftComparisonNoticeProvider)).equals('f-1');
        final folders = await c.read(foldersProvider.future);
        check(folders.firstWhere((f) => f.id == 'f-1').projectModelIds)
            .deepEquals(saved);
      });
    }

    test('one saved model is no comparison and needs no notice', () async {
      final c = await restored(['m-a']);

      check(comparing(c)).isNull();
      check(c.read(folderDraftComparisonNoticeProvider)).isNull();
    });

    // The saved comparison belongs to the draft it was made for, so anything
    // that changes that draft ends it with nothing to clear.
    for (final (name, meanwhile) in <(String, void Function(ProviderContainer))>[
      ('another model is picked', (c) {
        c.read(selectedModelProvider.notifier).set(_fallback);
      }),
      ('a chat is opened', (c) {
        c
            .read(activeConversationProvider.notifier)
            .set(
              Conversation(
                id: 'opened',
                title: 'Opened',
                createdAt: DateTime.utc(2026, 7, 13),
                updatedAt: DateTime.utc(2026, 7, 13),
              ),
            );
      }),
      ("another folder's draft opens", (c) {
        c.read(pendingFolderIdProvider.notifier).set('f-2');
      }),
      ('a different account signs in', (c) {
        c.read(_epochProvider.notifier).rotate();
      }),
      ('the draft becomes a temporary chat', (c) {
        c.read(temporaryChatEnabledProvider.notifier).set(true);
      }),
    ]) {
      test('ends when $name', () async {
        final c = await restored(['m-a', 'm-b']);
        check(comparing(c)).isNotNull();

        meanwhile(c);

        check(comparing(c)).isNull();
      });
    }

    test('a new draft in the same folder starts from the models it saves now',
        () async {
      final c = await restored(['m-a', 'm-b']);
      check(comparing(c)).isNotNull();

      // Another client dropped the second slot; the next draft here asks again.
      api.answers['f-1'] = _detail('f-1', modelIds: ['m-a']);
      await restoreFolderDraftModel(c, 'f-1');

      check(comparing(c)).isNull();
      check(c.read(selectedModelProvider)).identicalTo(_modelA);
    });

    test('a later draft in another folder starts from its own models',
        () async {
      final c = await restored(['m-a', 'm-b']);
      check(comparing(c)).isNotNull();

      c.read(pendingFolderIdProvider.notifier).set('f-2');
      await restoreFolderDraftModel(c, 'f-2');

      // f-2 saves one model, so nothing of f-1's comparison is left.
      check(comparing(c)).isNull();
      check(c.read(selectedModelProvider)).identicalTo(_modelA);
    });

    for (final (name, meanwhile) in <(String, void Function(ProviderContainer))>[
      ('a model the person picked', (c) {
        c.read(selectedModelProvider.notifier).set(_fallback);
      }),
      ('a different account signing in', (c) {
        c.read(_epochProvider.notifier).rotate();
      }),
      ("another folder's draft", (c) {
        c.read(pendingFolderIdProvider.notifier).set('f-2');
      }),
    ]) {
      test('a restore that finishes after $name starts no comparison and '
          'says nothing', () async {
        final c = await draftIn(saved: ['m-a', 'm-b']);

        final started = restoreFolderDraftModel(c, 'f-1');
        await settle();
        meanwhile(c);
        modelsGate.complete(_offered);
        await started;
        await settle();

        check(c.read(folderDraftComparisonProvider)).isNull();
        check(comparing(c)).isNull();
        check(c.read(folderDraftComparisonNoticeProvider)).isNull();
      });
    }
  });

  // Each wait is an await of the restore where the draft can move on: reading
  // the saved models, clearing the cached default, and the user default's own
  // resolution. The user default is the real [defaultModelProvider], so its
  // late application is what is being fenced, not a stand-in for it.
  group('nothing is applied to a draft that has moved on', () {
    final scenarios = <(String, void Function(ProviderContainer), Model)>[
      (
        'a model the person picked',
        (c) {
          c.read(selectedModelProvider.notifier).set(_modelA);
          c.read(isManualModelSelectionProvider.notifier).set(true);
        },
        _modelA,
      ),
      (
        'a chat opened',
        (c) => c
            .read(activeConversationProvider.notifier)
            .set(
              Conversation(
                id: 'opened',
                title: 'Opened',
                createdAt: DateTime.utc(2026, 7, 13),
                updatedAt: DateTime.utc(2026, 7, 13),
              ),
            ),
        _previous,
      ),
      (
        "another folder's draft",
        (c) => c.read(pendingFolderIdProvider.notifier).set('f-2'),
        _previous,
      ),
      (
        'a different account signing in',
        (c) => c.read(_epochProvider.notifier).rotate(),
        _previous,
      ),
    ];

    for (final wait in _Wait.values) {
      for (final (name, meanwhile, expected) in scenarios) {
        test('$name while ${wait.label}', () async {
          final c = await draftIn(saved: wait.saved);
          if (wait == _Wait.cachedDefault) storage.hold();
          if (wait == _Wait.folderDetail) {
            api.answers['f-1'] = _detail('f-1', modelIds: ['m-b']);
            api.hold();
          }

          final started = restoreFolderDraftModel(c, 'f-1');
          if (wait == _Wait.cachedDefault) {
            await storage.entered.future;
          } else {
            await settle();
          }
          meanwhile(c);
          if (wait == _Wait.cachedDefault) storage.release();
          if (wait == _Wait.folderDetail) api.release();
          modelsGate.complete(_offered);
          await started;
          await settle();

          check(c.read(selectedModelProvider)).identicalTo(expected);
          check(c.read(folderDraftModelNoticeProvider)).isNull();
        });
      }
    }

    test('an existing chat is never given a folder default', () async {
      final c = await draftIn(
        active: Conversation(
          id: 'existing',
          title: 'Existing',
          createdAt: DateTime.utc(2026, 7, 13),
          updatedAt: DateTime.utc(2026, 7, 13),
          folderId: 'f-1',
        ),
      );

      final started = restoreFolderDraftModel(c, 'f-1');
      modelsGate.complete(_offered);
      await started;
      await settle();

      check(c.read(selectedModelProvider)).identicalTo(_previous);
      check(c.read(folderDraftModelNoticeProvider)).isNull();
    });
  });
}
