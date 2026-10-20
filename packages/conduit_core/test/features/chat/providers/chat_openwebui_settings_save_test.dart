import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/reasoning_effort_provider.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Preference storage that does not finish until the test lets it: the window
/// in which a person can move to another chat or account.
class _SlowEfforts extends LocalReasoningEfforts {
  _SlowEfforts(this.gate);

  final Completer<void> gate;

  @override
  Future<void> set(String key, String? effort) async {
    await gate.future;
    await super.set(key, effort);
  }
}

class _EpochNotifier extends Notifier<Object> {
  @override
  Object build() => Object();

  /// A new sign-in session: a sign-out and back in, or another account.
  void rotate() => state = Object();
}

final _epochProvider = NotifierProvider<_EpochNotifier, Object>(
  _EpochNotifier.new,
);

class _SeededActive extends ActiveConversationNotifier {
  _SeededActive(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

/// Counts the drains a settings edit asks for, without running a real drain.
class _CountingSyncEngine extends SyncEngine {
  final drained = <AppDatabase>[];

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {
    drained.add(expectedDatabase);
  }
}

ApiService _api(String id) => ApiService(
  serverConfig: ServerConfig(id: id, name: id, url: 'https://$id.example.test'),
  workerManager: WorkerManager(),
);

Conversation _conversation(String id, {Map<String, dynamic>? chatParams}) =>
    withChatStorageProvenance(
      Conversation(
        id: id,
        title: 'Chat',
        createdAt: DateTime.utc(2026, 7, 13),
        updatedAt: DateTime.utc(2026, 7, 13),
        chatParams: chatParams ?? const {},
      ),
      ChatStorageKind.openWebUi,
    );

Future<void> _seed(AppDatabase db, String id, {Map<String, dynamic>? params}) =>
    db
        .into(db.chats)
        .insert(
          ChatsCompanion.insert(
            id: id,
            title: 'Chat',
            createdAt: 1,
            updatedAt: 1,
            bodySynced: const Value(true),
            rawExtra: Value(
              jsonEncode(<String, dynamic>{
                'params': ?params,
                'tags': <String>['keep'],
              }),
            ),
          ),
        );

void main() {
  late AppDatabase db;
  late _CountingSyncEngine engine;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    engine = _CountingSyncEngine();
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
  });

  tearDown(() async {
    await db.close();
    PreferencesStore.debugReset();
  });

  ProviderContainer container({
    Conversation? active,
    OpenWebUiChatSettingsAccess access = OpenWebUiChatSettingsAccess.all,
    Future<OpenWebUiChatSettingsAccess> Function()? accessLoader,
    AppDatabase? database,
    ApiService? api,
    Object? epoch,
    // The sign-in session can then be replaced mid-test with
    // `c.read(_epochProvider.notifier).rotate()`, the API and database objects
    // staying exactly as they were.
    bool rotatingEpoch = false,
    List<Override> extraOverrides = const [],
  }) {
    final c = ProviderContainer(
      overrides: [
        ...extraOverrides,
        appDatabaseProvider.overrideWith((ref) => database ?? db),
        apiServiceProvider.overrideWithValue(api ?? _api('server-a')),
        if (rotatingEpoch)
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(_epochProvider),
          )
        else
          openWebUiAuthSessionEpochProvider.overrideWithValue(
            epoch ?? Object(),
          ),
        activeConversationProvider.overrideWith(() => _SeededActive(active)),
        syncEngineProvider.overrideWith(() => engine),
        openWebUiChatSettingsAccessProvider.overrideWith(
          (ref) => accessLoader == null ? Future.value(access) : accessLoader(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<Map<String, dynamic>> stored(String id) async =>
      (await db.chatsDao.getChatParams(id))!;

  group('saving an edit to a stored chat', () {
    test(
      'writes only that edit, queues the sync, and refreshes the open chat',
      () async {
        await _seed(
          db,
          'c1',
          params: {
            'temperature': 0.2,
            'custom_params': {'k': 1},
          },
        );
        final c = container(
          active: _conversation('c1', chatParams: {'temperature': 0.2}),
        );

        final saved = await saveOpenWebUiChatSettings(
          c,
          conversation: c.read(activeConversationProvider),
          set: {'seed': 7},
          remove: ['temperature'],
        );

        check(saved).deepEquals({
          'custom_params': {'k': 1},
          'seed': 7,
        });
        check(await stored('c1')).deepEquals(saved);
        check(jsonDecode((await db.chatsDao.getChat('c1'))!.rawExtra))
            .isA<Map<String, dynamic>>()
            .containsKey('tags');
        final ops = await db.outboxDao.pendingForChat('c1');
        check(ops.map((op) => op.kind).toList()).deepEquals(['updateChat']);
        check(c.read(activeConversationProvider)!.chatParams).deepEquals(saved);
        check(engine.drained).length.equals(1);
      },
    );

    test('an edit that changes nothing queues nothing', () async {
      await _seed(db, 'c1', params: {'seed': 7});
      final c = container(active: _conversation('c1'));

      await saveOpenWebUiChatSettings(
        c,
        conversation: c.read(activeConversationProvider),
        set: {'seed': 7},
      );

      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
    });
  });

  group('permissions', () {
    const noPrompt = OpenWebUiChatSettingsAccess(
      canEditSystemPrompt: false,
      canEditParameters: true,
    );
    const noParams = OpenWebUiChatSettingsAccess(
      canEditSystemPrompt: true,
      canEditParameters: false,
    );

    Future<void> expectDenied(
      ProviderContainer c, {
      Map<String, dynamic> set = const {},
      Iterable<String> remove = const [],
    }) async {
      await check(
        saveOpenWebUiChatSettings(
          c,
          conversation: c.read(activeConversationProvider),
          set: set,
          remove: remove,
        ),
      ).throws<OpenWebUiChatSettingsException>(
        (e) => e
            .has((it) => it.reason, 'reason')
            .equals(OpenWebUiChatSettingsFailure.permissionDenied),
      );
    }

    test(
      'without system-prompt rights the prompt cannot be written or reset',
      () async {
        await _seed(db, 'c1', params: {'system': 'keep me', 'seed': 1});
        final c = container(active: _conversation('c1'), access: noPrompt);

        await expectDenied(c, set: {'system': 'x'});
        await expectDenied(c, remove: ['system']);
        // A mixed edit is refused as a whole: nothing partial lands.
        await expectDenied(c, set: {'seed': 2, 'system': 'x'});

        check(await stored('c1')).deepEquals({'system': 'keep me', 'seed': 1});
        check(await db.outboxDao.pendingForChat('c1')).isEmpty();
      },
    );

    test('without parameter rights only the prompt may change', () async {
      await _seed(db, 'c1', params: {'system': 'keep me', 'seed': 1});
      final c = container(active: _conversation('c1'), access: noParams);

      await expectDenied(c, set: {'seed': 2});
      await expectDenied(c, set: {'reasoning_effort': null});
      await saveOpenWebUiChatSettings(
        c,
        conversation: c.read(activeConversationProvider),
        set: {'system': 'new prompt'},
      );

      check(await stored('c1')).deepEquals({'system': 'new prompt', 'seed': 1});
    });

    test('a denied draft edit changes nothing either', () async {
      final c = container(access: OpenWebUiChatSettingsAccess.denied);

      await expectDenied(c, set: {'seed': 1});

      check(c.read(pendingOpenWebUiChatSettingsProvider)).isEmpty();
    });
  });

  group('owner changes', () {
    test('switching server mid-edit writes to neither server', () async {
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      await _seed(db, 'same-id', params: {'seed': 1});
      await _seed(dbB, 'same-id', params: {'seed': 100});
      final gate = Completer<OpenWebUiChatSettingsAccess>();
      final apiA = _api('server-a');
      final epoch = Object();
      final c = container(
        active: _conversation('same-id'),
        accessLoader: () => gate.future,
        api: apiA,
        epoch: epoch,
      );

      final save = saveOpenWebUiChatSettings(
        c,
        conversation: c.read(activeConversationProvider),
        set: {'seed': 2},
      );
      c.updateOverrides([
        appDatabaseProvider.overrideWith((ref) => dbB),
        apiServiceProvider.overrideWithValue(_api('server-b')),
        openWebUiAuthSessionEpochProvider.overrideWithValue(epoch),
        activeConversationProvider.overrideWith(
          () => _SeededActive(_conversation('same-id')),
        ),
        syncEngineProvider.overrideWith(() => engine),
        openWebUiChatSettingsAccessProvider.overrideWith((ref) => gate.future),
      ]);
      gate.complete(OpenWebUiChatSettingsAccess.all);

      await check(save).throws<OpenWebUiChatSettingsException>(
        (e) => e
            .has((it) => it.reason, 'reason')
            .equals(OpenWebUiChatSettingsFailure.ownerChanged),
      );
      check(await stored('same-id')).deepEquals({'seed': 1});
      check(await dbB.chatsDao.getChatParams('same-id'))
          .isNotNull()
          .deepEquals({'seed': 100});
      check(await db.outboxDao.pendingForChat('same-id')).isEmpty();
      check(await dbB.outboxDao.pendingForChat('same-id')).isEmpty();
    });

    test('a new sign-in session mid-edit also aborts the write', () async {
      await _seed(db, 'c1', params: {'seed': 1});
      final gate = Completer<OpenWebUiChatSettingsAccess>();
      final apiA = _api('server-a');
      final c = container(
        active: _conversation('c1'),
        accessLoader: () => gate.future,
        api: apiA,
        epoch: Object(),
      );

      final save = saveOpenWebUiChatSettings(
        c,
        conversation: c.read(activeConversationProvider),
        set: {'seed': 2},
      );
      c.updateOverrides([
        appDatabaseProvider.overrideWith((ref) => db),
        apiServiceProvider.overrideWithValue(apiA),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        activeConversationProvider.overrideWith(
          () => _SeededActive(_conversation('c1')),
        ),
        syncEngineProvider.overrideWith(() => engine),
        openWebUiChatSettingsAccessProvider.overrideWith((ref) => gate.future),
      ]);
      gate.complete(OpenWebUiChatSettingsAccess.all);

      await check(save).throws<OpenWebUiChatSettingsException>();
      check(await stored('c1')).deepEquals({'seed': 1});
    });
  });

  group('chats that are not stored Open WebUI chats', () {
    test('an on-device chat is not editable here', () async {
      final c = container(
        active: withChatStorageProvenance(
          Conversation(
            id: 'device-chat',
            title: 'Device',
            createdAt: DateTime.utc(2026, 7, 13),
            updatedAt: DateTime.utc(2026, 7, 13),
          ),
          ChatStorageKind.directLocal,
        ),
      );

      await check(
        saveOpenWebUiChatSettings(
          c,
          conversation: c.read(activeConversationProvider),
          set: {'seed': 1},
        ),
      ).throws<OpenWebUiChatSettingsException>(
        (e) => e
            .has((it) => it.reason, 'reason')
            .equals(OpenWebUiChatSettingsFailure.notEditable),
      );
      check(engine.drained).isEmpty();
    });

    test('a temporary chat keeps its edit in memory only', () async {
      final c = container(active: _conversation('local:socket_temp'));

      final saved = await saveOpenWebUiChatSettings(
        c,
        conversation: c.read(activeConversationProvider),
        set: {'system': 'temp prompt'},
      );

      check(saved).deepEquals({'system': 'temp prompt'});
      check(c.read(activeConversationProvider)!.chatParams)
          .deepEquals({'system': 'temp prompt'});
      check(engine.drained).isEmpty();
    });

    test(
      'a stored-looking chat with no row is reported, not invented',
      () async {
        final c = container(active: _conversation('gone-chat'));

        await check(
          saveOpenWebUiChatSettings(
            c,
            conversation: c.read(activeConversationProvider),
            set: {'seed': 1},
          ),
        ).throws<OpenWebUiChatSettingsException>(
          (e) => e
              .has((it) => it.reason, 'reason')
              .equals(OpenWebUiChatSettingsFailure.unavailable),
        );
      },
    );
  });

  group('draft for the next new chat', () {
    test(
      'accumulates edits, supports reset, and touches no database',
      () async {
        final c = container();

        await saveOpenWebUiChatSettings(
          c,
          conversation: null,
          set: {'system': 'draft prompt', 'temperature': 0.3},
        );
        await saveOpenWebUiChatSettings(
          c,
          conversation: null,
          set: {'seed': 4},
          remove: ['temperature'],
        );

        check(c.read(pendingOpenWebUiChatSettingsProvider))
            .deepEquals({'system': 'draft prompt', 'seed': 4});
        check(engine.drained).isEmpty();
      },
    );

    test('opening a chat discards the draft', () async {
      final c = container();
      await saveOpenWebUiChatSettings(c, conversation: null, set: {'seed': 4});
      check(c.read(pendingOpenWebUiChatSettingsProvider)).isNotEmpty();

      c.read(activeConversationProvider.notifier).set(_conversation('c1'));

      check(c.read(pendingOpenWebUiChatSettingsProvider)).isEmpty();
    });

    test(
      'a draft does not survive a new sign-in session on the same API',
      () async {
        // The API object is the same for every account on a server, so a draft
        // keyed to it alone would carry account A's prompt into account B.
        final c = container(rotatingEpoch: true);
        await saveOpenWebUiChatSettings(
          c,
          conversation: null,
          set: {'system': 'Account A only', 'temperature': 0.2},
        );
        check(c.read(pendingOpenWebUiChatSettingsProvider)).isNotEmpty();

        c.read(_epochProvider.notifier).rotate();

        check(c.read(pendingOpenWebUiChatSettingsProvider)).isEmpty();
      },
    );

    test('a save started under one session cannot land in the next', () async {
      final gate = Completer<OpenWebUiChatSettingsAccess>();
      final c = container(rotatingEpoch: true, accessLoader: () => gate.future);

      final save = saveOpenWebUiChatSettings(
        c,
        conversation: null,
        set: {'system': 'Account A only'},
      );
      c.read(_epochProvider.notifier).rotate();
      gate.complete(OpenWebUiChatSettingsAccess.all);

      await check(save).throws<OpenWebUiChatSettingsException>(
        (e) => e
            .has((it) => it.reason, 'reason')
            .equals(OpenWebUiChatSettingsFailure.ownerChanged),
      );
      check(c.read(pendingOpenWebUiChatSettingsProvider)).isEmpty();
    });
  });

  group('the reasoning picker', () {
    const model = Model(id: 'o-model', name: 'O');

    test('an explicit pick becomes the chat\'s saved override', () async {
      await _seed(db, 'c1', params: {'temperature': 0.2});
      final c = container(active: _conversation('c1'));

      await persistOpenWebUiReasoningPick(c, model, 'high');

      check(await stored('c1'))
          .deepEquals({'temperature': 0.2, 'reasoning_effort': 'high'});
    });

    test(
      '"automatic" is saved as an explicit default, not left to inherit',
      () async {
        await _seed(db, 'c1', params: {'reasoning_effort': 'high'});
        final c = container(active: _conversation('c1'));

        await persistOpenWebUiReasoningPick(c, model, 'automatic');

        final params = await stored('c1');
        check(params.containsKey('reasoning_effort')).isTrue();
        check(params['reasoning_effort']).isNull();
      },
    );

    test('with no chat open it seeds the next chat\'s draft', () async {
      final c = container();

      await persistOpenWebUiReasoningPick(c, model, 'low');

      check(c.read(pendingOpenWebUiChatSettingsProvider))
          .deepEquals({'reasoning_effort': 'low'});
    });

    test('a Hermes model keeps its device-local pick only', () async {
      await _seed(db, 'c1');
      final c = container(active: _conversation('c1'));

      await persistOpenWebUiReasoningPick(c, hermesSyntheticModel(), 'high');

      check(await stored('c1')).isEmpty();
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
    });

    test(
      'a user without parameter rights still gets the pick, just not saved',
      () async {
        await _seed(db, 'c1');
        final c = container(
          active: _conversation('c1'),
          access: const OpenWebUiChatSettingsAccess(
            canEditSystemPrompt: true,
            canEditParameters: false,
          ),
        );

        await check(persistOpenWebUiReasoningPick(c, model, 'high'))
            .completes();

        check(await stored('c1')).isEmpty();
      },
    );

    test(
      'the picker entry point records the pick and saves it on the chat',
      () async {
        await _seed(db, 'c1');
        final c = container(active: _conversation('c1'));
        const reasoner = Model(id: 'gpt-5', name: 'GPT-5');

        await selectReasoningEffortForModel(c, reasoner, 'high');

        check(localReasoningEffortForModel(c.read, reasoner)).equals('high');
        check(await stored('c1')).deepEquals({'reasoning_effort': 'high'});
      },
    );

    test('a value the model rejects is neither recorded nor saved', () async {
      await _seed(db, 'c1');
      final c = container(active: _conversation('c1'));
      const plain = Model(id: 'plain-chat-model', name: 'Plain');

      await check(selectReasoningEffortForModel(c, plain, 'high'))
          .throws<FormatException>();

      check(localReasoningEffortForModel(c.read, plain)).isNull();
      check(await stored('c1')).isEmpty();
    });

    test('an invalid effort saves nothing', () async {
      await _seed(db, 'c1');
      final c = container(active: _conversation('c1'));

      await persistOpenWebUiReasoningPick(c, model, 'not valid!');

      check(await stored('c1')).isEmpty();
    });

    group('while the pick is still being recorded locally', () {
      const reasoner = Model(id: 'gpt-5', name: 'GPT-5');

      test('it is saved on the chat it was made in, not the one opened since',
          () async {
        await _seed(db, 'c1');
        await _seed(db, 'c2', params: {'temperature': 0.5});
        final gate = Completer<void>();
        final c = container(
          active: _conversation('c1'),
          extraOverrides: [
            localReasoningEffortsProvider.overrideWith(
              () => _SlowEfforts(gate),
            ),
          ],
        );

        final pick = selectReasoningEffortForModel(c, reasoner, 'high');
        // Preference storage is slow; the user opens another chat meanwhile.
        c.read(activeConversationProvider.notifier).set(_conversation('c2'));
        gate.complete();
        await pick;

        check(await stored('c1')).deepEquals({'reasoning_effort': 'high'});
        check(await stored('c2')).deepEquals({'temperature': 0.5});
        check(await db.outboxDao.pendingForChat('c2')).isEmpty();
        // The device-local pick is the one the user made, whatever chat is open.
        check(localReasoningEffortForModel(c.read, reasoner)).equals('high');
      });

      test(
        'a picker that opened on one chat saves there even if it is used later',
        () async {
          await _seed(db, 'c1');
          await _seed(db, 'c2');
          final c = container(active: _conversation('c1'));

          // The picker opens on c1 ...
          final target = captureOpenWebUiReasoningPickTarget(c);
          // ... the user moves on, and picks without closing it.
          c.read(activeConversationProvider.notifier).set(_conversation('c2'));
          await selectReasoningEffortForModel(
            c,
            reasoner,
            'low',
            target: target,
          );

          check(await stored('c1')).deepEquals({'reasoning_effort': 'low'});
          check(await stored('c2')).isEmpty();
        },
      );

      test('a pick for a new chat is dropped once a chat has been opened',
          () async {
        await _seed(db, 'c1');
        final gate = Completer<void>();
        final c = container(
          extraOverrides: [
            localReasoningEffortsProvider.overrideWith(
              () => _SlowEfforts(gate),
            ),
          ],
        );

        final pick = selectReasoningEffortForModel(c, reasoner, 'high');
        c.read(activeConversationProvider.notifier).set(_conversation('c1'));
        gate.complete();
        await pick;

        check(await stored('c1')).isEmpty();
        check(c.read(pendingOpenWebUiChatSettingsProvider)).isEmpty();
      });

      test('another account never receives it', () async {
        await _seed(db, 'c1');
        final gate = Completer<void>();
        final c = container(
          active: _conversation('c1'),
          rotatingEpoch: true,
          extraOverrides: [
            localReasoningEffortsProvider.overrideWith(
              () => _SlowEfforts(gate),
            ),
          ],
        );

        final pick = selectReasoningEffortForModel(c, reasoner, 'high');
        // Same server, same API, same chat id: a different sign-in session.
        c.read(_epochProvider.notifier).rotate();
        gate.complete();
        await pick;

        check(await stored('c1')).isEmpty();
        check(await db.outboxDao.pendingForChat('c1')).isEmpty();
      });

      test('a Hermes pick is never saved on a chat, however slow', () async {
        await _seed(db, 'c1');
        final gate = Completer<void>();
        final c = container(
          active: _conversation('c1'),
          extraOverrides: [
            localReasoningEffortsProvider.overrideWith(
              () => _SlowEfforts(gate),
            ),
          ],
        );

        final pick = selectReasoningEffortForModel(
          c,
          hermesSyntheticModel(),
          'high',
        );
        gate.complete();
        await pick;

        check(await stored('c1')).isEmpty();
      });
    });

    group('on a chat that is another user\'s', () {
      const model = Model(id: 'gpt-5', name: 'GPT-5');
      const me = User(
        id: 'me',
        username: 'me',
        email: 'me@example.test',
        role: 'user',
      );

      Conversation shared() =>
          _conversation('shared').copyWith(userId: 'someone-else');

      test('saving settings is refused by the save itself', () async {
        await _seed(db, 'shared', params: {'seed': 1});
        final c = container(
          active: shared(),
          extraOverrides: [currentUserProvider2.overrideWithValue(me)],
        );

        await check(
          saveOpenWebUiChatSettings(
            c,
            conversation: shared(),
            set: {'seed': 2},
          ),
        ).throws<OpenWebUiChatSettingsException>(
          (e) => e
              .has((it) => it.reason, 'reason')
              .equals(OpenWebUiChatSettingsFailure.notEditable),
        );

        check(await stored('shared')).deepEquals({'seed': 1});
        check(await db.outboxDao.pendingForChat('shared')).isEmpty();
      });

      test('the reasoning picker keeps the local pick and saves nothing',
          () async {
        await _seed(db, 'shared');
        final c = container(
          active: shared(),
          extraOverrides: [currentUserProvider2.overrideWithValue(me)],
        );

        await selectReasoningEffortForModel(c, model, 'high');

        check(localReasoningEffortForModel(c.read, model)).equals('high');
        check(await stored('shared')).isEmpty();
        check(await db.outboxDao.pendingForChat('shared')).isEmpty();
      });

      test('the owner of the same chat may still save', () async {
        await _seed(db, 'mine');
        final mine = _conversation('mine').copyWith(userId: 'me');
        final c = container(
          active: mine,
          extraOverrides: [currentUserProvider2.overrideWithValue(me)],
        );

        await selectReasoningEffortForModel(c, model, 'high');

        check(await stored('mine')).deepEquals({'reasoning_effort': 'high'});
      });
    });
  });

  group('which entry the chat overflow offers', () {
    const openWebUiModel = Model(id: 'gpt-5', name: 'GPT-5');

    ProviderContainer menu({
      bool advanced = true,
      Model? model = openWebUiModel,
      Conversation? active,
      OpenWebUiChatSettingsAccess access = OpenWebUiChatSettingsAccess.all,
      bool reviewer = false,
      DirectModelRegistry? registry,
      bool signedIn = true,
    }) {
      final c = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(reviewer),
          selectedModelProvider.overrideWithValue(model),
          apiServiceProvider.overrideWithValue(signedIn ? _api('menu') : null),
          activeConversationProvider.overrideWith(() => _SeededActive(active)),
          currentUserProvider2.overrideWithValue(
            const User(
              id: 'me',
              username: 'me',
              email: 'me@example.test',
              role: 'user',
            ),
          ),
          openWebUiChatSettingsAccessProvider.overrideWith(
            (ref) async => access,
          ),
          if (registry != null)
            directModelRegistryProvider.overrideWithValue(registry),
          appSettingsProvider.overrideWith(
            () =>
                _FixedSettings(AppSettings(advancedFeaturesEnabled: advanced)),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    // Resolves the async permission first, as the app does before the menu
    // is ever built.
    Future<OpenWebUiChatSettingsMenuEntry> entry(ProviderContainer c) async {
      c.listen(openWebUiChatSettingsAccessProvider, (_, _) {});
      await c.read(openWebUiChatSettingsAccessProvider.future);
      return c.read(openWebUiChatSettingsMenuEntryProvider);
    }

    test(
      'Advanced on offers the editor for a stored chat and for a new chat',
      () async {
        check(await entry(menu(active: _conversation('c1'))))
            .equals(OpenWebUiChatSettingsMenuEntry.editor);
        check(await entry(menu()))
            .equals(OpenWebUiChatSettingsMenuEntry.editor);
      },
    );

    test(
      'Advanced off offers no editor, only a notice when settings apply',
      () async {
        check(await entry(menu(advanced: false, active: _conversation('c1'))))
            .equals(OpenWebUiChatSettingsMenuEntry.none);
        check(
          await entry(
            menu(
              advanced: false,
              active: _conversation('c1', chatParams: {'temperature': 0.2}),
            ),
          ),
        ).equals(OpenWebUiChatSettingsMenuEntry.applied);
      },
    );

    test('an account that may edit nothing gets only the notice', () async {
      check(
        await entry(
          menu(
            access: OpenWebUiChatSettingsAccess.denied,
            active: _conversation('c1', chatParams: {'seed': 1}),
          ),
        ),
      ).equals(OpenWebUiChatSettingsMenuEntry.applied);
      check(
        await entry(
          menu(
            access: OpenWebUiChatSettingsAccess.denied,
            active: _conversation('c1'),
          ),
        ),
      ).equals(OpenWebUiChatSettingsMenuEntry.none);
    });

    test(
      'an account that may edit only one half still gets the editor',
      () async {
        check(
          await entry(
            menu(
              active: _conversation('c1'),
              access: const OpenWebUiChatSettingsAccess(
                canEditSystemPrompt: true,
                canEditParameters: false,
              ),
            ),
          ),
        ).equals(OpenWebUiChatSettingsMenuEntry.editor);
      },
    );

    test('a draft with settings but no Advanced shows the notice', () async {
      final c = menu(advanced: false);
      c.read(pendingOpenWebUiChatSettingsProvider.notifier).replace({
        'seed': 1,
      });

      check(await entry(c)).equals(OpenWebUiChatSettingsMenuEntry.applied);
    });

    test('Hermes models never see it', () async {
      check(await entry(menu(model: hermesSyntheticModel())))
          .equals(OpenWebUiChatSettingsMenuEntry.none);
    });

    test(
      'an on-device direct model never sees it, an Open WebUI direct one does',
      () async {
        final profile = DirectConnectionProfile(
          id: 'p',
          name: 'p',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://provider.example.test/v1',
          modelIdPrefix: 'pfx',
        );
        Model directModel(
          DirectModelRegistry registry,
          DirectModelSource source,
        ) => registry
            .replaceProfileModels(
              profile,
              [DirectRemoteModel(id: 'm', name: 'm')],
              source: source,
              openWebUiUrlIndex: source == DirectModelSource.openWebUi
                  ? 1
                  : null,
            )
            .single;

        final device = DirectModelRegistry();
        final deviceModel = directModel(device, DirectModelSource.device);
        check(await entry(menu(model: deviceModel, registry: device)))
            .equals(OpenWebUiChatSettingsMenuEntry.none);

        final server = DirectModelRegistry();
        final serverModel = directModel(server, DirectModelSource.openWebUi);
        check(await entry(menu(model: serverModel, registry: server)))
            .equals(OpenWebUiChatSettingsMenuEntry.editor);
      },
    );

    test("on-device chats and another user's chats never see it", () async {
      final device = withChatStorageProvenance(
        Conversation(
          id: 'device',
          title: 'd',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          chatParams: const {'seed': 1},
        ),
        ChatStorageKind.directLocal,
      );
      check(await entry(menu(active: device)))
          .equals(OpenWebUiChatSettingsMenuEntry.none);

      final shared = _conversation(
        'shared',
        chatParams: {'seed': 1},
      ).copyWith(userId: 'someone-else');
      check(await entry(menu(active: shared)))
          .equals(OpenWebUiChatSettingsMenuEntry.none);
    });

    test('reviewer mode and a signed-out session never see it', () async {
      check(await entry(menu(reviewer: true)))
          .equals(OpenWebUiChatSettingsMenuEntry.none);
      check(await entry(menu(signedIn: false)))
          .equals(OpenWebUiChatSettingsMenuEntry.none);
    });
  });

  test(
    'the permission provider fails closed when the server is unreachable',
    () async {
      final api = _ThrowingPermissionsApi();
      final c = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          reviewerModeProvider.overrideWithValue(false),
          currentUserProvider2.overrideWithValue(
            const User(
              id: 'u1',
              username: 'u',
              email: 'u@example.test',
              role: 'user',
            ),
          ),
        ],
      );
      addTearDown(c.dispose);

      final access = await c.read(openWebUiChatSettingsAccessProvider.future);

      check(access.canEditAnything).isFalse();
    },
  );

  test(
    'a permission answer for an earlier sign-in session is not handed to the next',
    () async {
      // Same API object, same user id: a sign-out and back in. The first
      // session's request is still in flight when the second begins.
      final first = Completer<Map<String, dynamic>>();
      final second = Completer<Map<String, dynamic>>();
      final api = _GatedPermissionsApi([first, second]);
      final c = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          reviewerModeProvider.overrideWithValue(false),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(_epochProvider),
          ),
          currentUserProvider2.overrideWithValue(
            const User(
              id: 'u1',
              username: 'u',
              email: 'u@example.test',
              role: 'user',
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.listen(openWebUiChatSettingsAccessProvider, (_, _) {});

      final oldSession = c.read(openWebUiChatSettingsAccessProvider.future);
      await Future<void>.delayed(Duration.zero);
      c.read(_epochProvider.notifier).rotate();
      await Future<void>.delayed(Duration.zero);
      check(api.permissionCalls).equals(2);

      // The new session may change parameters only; the old one's late answer
      // would have allowed everything.
      second.complete({
        'chat': {'controls': true, 'system_prompt': false, 'params': true},
      });
      first.complete({
        'chat': {'controls': true, 'system_prompt': true, 'params': true},
      });

      final current = await c.read(openWebUiChatSettingsAccessProvider.future);
      check(current.canEditParameters).isTrue();
      check(current.canEditSystemPrompt).isFalse();
      check((await oldSession).canEditSystemPrompt).isFalse();
    },
  );

  test('an admin is never asked for permissions', () async {
    final api = _ThrowingPermissionsApi();
    final c = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        reviewerModeProvider.overrideWithValue(false),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'a1',
            username: 'a',
            email: 'a@example.test',
            role: 'admin',
          ),
        ),
      ],
    );
    addTearDown(c.dispose);

    final access = await c.read(openWebUiChatSettingsAccessProvider.future);

    check(access.canEditSystemPrompt).isTrue();
    check(access.canEditParameters).isTrue();
    check(api.permissionCalls).equals(0);
  });
}

class _FixedSettings extends AppSettingsNotifier {
  _FixedSettings(this._settings);

  final AppSettings _settings;

  @override
  AppSettings build() => _settings;
}

/// Answers each permission request with the next gate, in call order.
class _GatedPermissionsApi extends ApiService {
  _GatedPermissionsApi(this.gates)
    : super(
        serverConfig: const ServerConfig(
          id: 'perm',
          name: 'perm',
          url: 'https://perm.example.test',
        ),
        workerManager: WorkerManager(),
      );

  final List<Completer<Map<String, dynamic>>> gates;
  int permissionCalls = 0;

  @override
  Future<Map<String, dynamic>> getUserPermissions({Object? authSnapshot}) =>
      gates[permissionCalls++].future;
}

class _ThrowingPermissionsApi extends ApiService {
  _ThrowingPermissionsApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'perm',
          name: 'perm',
          url: 'https://perm.example.test',
        ),
        workerManager: WorkerManager(),
      );

  int permissionCalls = 0;

  @override
  Future<Map<String, dynamic>> getUserPermissions({
    Object? authSnapshot,
  }) async {
    permissionCalls += 1;
    throw StateError('unreachable');
  }
}
