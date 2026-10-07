import 'dart:async';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_memory.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit/features/profile/views/personalization_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('direct-only Personalization exposes only the default model', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiAccountAvailableProvider.overrideWithValue(false),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          apiServiceProvider.overrideWithValue(null),
          modelsProvider.overrideWith(_DirectModels.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PersonalizationPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Default model'), findsWidgets);
    expect(find.text('Your system prompt'), findsNothing);
    expect(find.text('Memory'), findsNothing);
    expect(find.text('Advanced prompt overrides'), findsNothing);

    await tester.tap(find.text('Default model').last);
    await tester.pumpAndSettle();

    expect(find.text('Direct Alpha'), findsOneWidget);
    expect(find.text('Direct Beta'), findsOneWidget);
  });

  testWidgets('OpenRouter Personalization exposes the image generation model', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiAccountAvailableProvider.overrideWithValue(false),
          appSettingsProvider.overrideWithValue(
            const AppSettings(
              openRouterImageGenerationModel: 'openai/gpt-5-image-mini',
            ),
          ),
          apiServiceProvider.overrideWithValue(null),
          modelsProvider.overrideWith(_OpenRouterModels.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PersonalizationPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Default image generation model'), findsWidgets);
    expect(find.text('openai/gpt-5-image-mini'), findsOneWidget);
  });

  group('memories', () {
    testWidgets('an entered memory is saved from its content alone', (
      tester,
    ) async {
      final api = _MemoriesApi();
      await _pumpSignedInPage(tester, api);

      await _openMemoryManager(tester);
      await tester.tap(find.text('Add memory').last);
      await tester.pumpAndSettle();
      // The ordinary editor is the content box and nothing else.
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'I prefer metric units');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(api.adds, hasLength(1));
      expect(api.adds.single.content, 'I prefer metric units');
      expect(api.adds.single.type, ServerMemory.userType);
      expect(api.adds.single.path, isNull);
    });

    testWidgets('editing a memory sends only the changed content', (
      tester,
    ) async {
      final api = _MemoriesApi(
        memories: [
          ServerMemory(
            id: 'm1',
            userId: 'u',
            content: 'Project uses Riverpod',
            updatedAtEpoch: 10,
            createdAtEpoch: 1,
            type: ServerMemory.contextType,
            path: 'projects/conduit',
          ),
        ],
      );
      await _pumpSignedInPage(tester, api);

      await _openMemoryManager(tester);
      await tester.tap(find.text('Project uses Riverpod'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Project uses Riverpod 3');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(api.updates, hasLength(1));
      expect(api.updates.single.content, 'Project uses Riverpod 3');
      expect(api.updates.single.type, isNull);
      expect(api.updates.single.path, isNull);
    });

    testWidgets('a refused save keeps the typed text and can be retried', (
      tester,
    ) async {
      final api = _MemoriesApi()..failNextWrite = true;
      await _pumpSignedInPage(tester, api);

      await _openMemoryManager(tester);
      await tester.tap(find.text('Add memory').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'I prefer metric units');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      // The server refused: the form is still open with the draft.
      expect(api.adds, isEmpty);
      expect(find.text('I prefer metric units'), findsOneWidget);

      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(api.adds.map((add) => add.content), ['I prefer metric units']);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('the ordinary editor has no type or path', (tester) async {
      await _pumpSignedInPage(tester, _MemoriesApi());

      await _openMemoryManager(tester);
      await tester.tap(find.text('Add memory').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('memory-type-user')), findsNothing);
      expect(find.byKey(const Key('memory-path')), findsNothing);
    });
  });

  group('memories with Advanced on', () {
    const advanced = AppSettings(advancedFeaturesEnabled: true);

    Future<void> openAdd(WidgetTester tester) async {
      await tester.tap(find.text('Add memory').last);
      await tester.pumpAndSettle();
    }

    testWidgets('a new memory defaults to user and can take a type and path', (
      tester,
    ) async {
      final api = _MemoriesApi();
      await _pumpSignedInPage(tester, api, settings: advanced);

      await _openMemoryManager(tester);
      await openAdd(tester);
      await tester.enterText(find.byType(TextField).first, 'Default type');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      await openAdd(tester);
      await tester.enterText(find.byType(TextField).first, 'Repo notes');
      await tester.tap(find.byKey(const Key('memory-type-context')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('memory-path')),
        ' projects/conduit ',
      );
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(api.adds, [
        (content: 'Default type', type: 'user', path: null),
        (content: 'Repo notes', type: 'context', path: 'projects/conduit'),
      ]);
    });

    testWidgets('a content-only edit leaves type and path alone', (
      tester,
    ) async {
      final api = _MemoriesApi(
        memories: [_memory(type: 'context', path: 'projects/conduit')],
      );
      await _pumpSignedInPage(tester, api, settings: advanced);

      await _openMemoryManager(tester);
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      final contextChip = tester.widget<ConduitChip>(
        find.byKey(const Key('memory-type-context')),
      );
      expect(contextChip.isSelected, isTrue);
      await tester.enterText(find.byType(TextField).first, 'Edited');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(api.updates, [(content: 'Edited', type: null, path: null)]);
    });

    testWidgets('changing the type and clearing the path are sent', (
      tester,
    ) async {
      final api = _MemoriesApi(
        memories: [_memory(type: 'context', path: 'projects/conduit')],
      );
      await _pumpSignedInPage(tester, api, settings: advanced);

      await _openMemoryManager(tester);
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-type-user')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('memory-path')), '');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(api.updates, [(content: 'Original', type: 'user', path: '')]);
    });

    testWidgets('a type this client does not know is kept, not reclassified', (
      tester,
    ) async {
      final api = _MemoriesApi(
        memories: [
          _memory(type: 'episodic'),
          _memory(id: 'old', type: null),
        ],
      );
      await _pumpSignedInPage(tester, api, settings: advanced);

      await _openMemoryManager(tester);
      await tester.tap(find.text('Original').first);
      await tester.pumpAndSettle();
      for (final key in const ['memory-type-user', 'memory-type-context']) {
        expect(
          tester.widget<ConduitChip>(find.byKey(Key(key))).isSelected,
          isFalse,
        );
      }
      await tester.enterText(find.byType(TextField).first, 'Edited');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(api.updates, [(content: 'Edited', type: null, path: null)]);
    });
  });

  group('a form opened for one account', () {
    testWidgets('does not save for the account that signs in next', (
      tester,
    ) async {
      final session = await _pumpSignedInPage(
        tester,
        _MemoriesApi(memories: [_memory()]),
      );

      await _openMemoryManager(tester);
      await tester.tap(find.text('Add memory').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'meant for account A');
      session.switchAccount();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(session.api.adds, isEmpty);
      // The sheet is still open with what was typed.
      expect(find.text('meant for account A'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('keeps the Advanced fields it was filled in with', (
      tester,
    ) async {
      final session = await _pumpSignedInPage(
        tester,
        _MemoriesApi(memories: [_memory()]),
        settings: const AppSettings(advancedFeaturesEnabled: true),
      );

      await _openMemoryManager(tester);
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('memory-path')), 'prefs');
      session.switchAccount();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(session.api.updates, isEmpty);
      expect(find.text('prefs'), findsOneWidget);
    });

    testWidgets('does not delete after a confirmation outlived the account', (
      tester,
    ) async {
      final session = await _pumpSignedInPage(
        tester,
        _MemoriesApi(memories: [_memory()]),
      );

      await _openMemoryManager(tester);
      await tester.tap(find.byTooltip('Delete memory'));
      await tester.pumpAndSettle();
      session.switchAccount();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete memory').last);
      await tester.pumpAndSettle();

      expect(session.api.deleted, isEmpty);
    });
  });

  group('memory permission', () {
    testWidgets(
      'the memory section is hidden when memories are not permitted',
      (tester) async {
        await _pumpSignedInPage(tester, _MemoriesApi(), permitted: false);

        expect(find.text('Memory'), findsNothing);
        expect(find.text('Manage memories'), findsNothing);
        expect(
          find.text('Your system prompt', skipOffstage: false),
          findsOneWidget,
        );
      },
    );

    testWidgets('the memory section stays while the permission is unknown', (
      tester,
    ) async {
      await _pumpSignedInPage(tester, _MemoriesApi(), permitted: null);

      expect(find.text('Manage memories', skipOffstage: false), findsOneWidget);
    });
  });
}

class _DirectModels extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(
      id: 'direct:alpha',
      name: 'Direct Alpha',
      metadata: {'backend': 'direct'},
    ),
    Model(
      id: 'direct:beta',
      name: 'Direct Beta',
      metadata: {'backend': 'direct'},
    ),
  ];
}

class _OpenRouterModels extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(
      id: 'direct:openrouter:text-model',
      name: 'OpenRouter Text Model',
      capabilities: {'openrouter': true, 'image_generation': true},
      metadata: {'backend': 'direct'},
    ),
  ];
}

Future<void> _openMemoryManager(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Manage memories'));
  await tester.tap(find.text('Manage memories'));
  await tester.pumpAndSettle();
}

typedef _MemoryWrite = ({String content, String? type, String? path});

class _SignedInSettings extends PersonalizationSettings {
  @override
  Future<ServerUserSettings> build() async =>
      const ServerUserSettings(memoryEnabled: true);
}

ServerMemory _memory({String id = 'm1', String? type, String? path}) {
  return ServerMemory(
    id: id,
    userId: 'u',
    content: 'Original',
    updatedAtEpoch: 10,
    createdAtEpoch: 1,
    type: type,
    path: path,
  );
}

const _accountServer = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

/// The page on the real memory provider and ownership checks, with an
/// account that can be replaced without replacing the [ApiService], as when
/// another user signs in on the same server.
final class _AccountSession {
  _AccountSession(this.api, this.container);

  final _MemoriesApi api;
  final ProviderContainer container;
  Object epoch = Object();

  void switchAccount() {
    epoch = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
  }
}

/// Pumps the page for a signed-in account whose memories live in [api].
/// [permitted] stands in for the permission document, which null leaves
/// unanswered.
Future<_AccountSession> _pumpSignedInPage(
  WidgetTester tester,
  _MemoriesApi api, {
  bool? permitted = true,
  AppSettings settings = const AppSettings(),
}) async {
  late final _AccountSession session;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        openWebUiAccountAvailableProvider.overrideWithValue(true),
        appSettingsProvider.overrideWithValue(settings),
        apiServiceProvider.overrideWithValue(api),
        modelsProvider.overrideWith(_DirectModels.new),
        personalizationSettingsProvider.overrideWith(_SignedInSettings.new),
        optimizedStorageServiceProvider.overrideWithValue(_AccountStorage()),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'user-1',
            username: 'user',
            email: 'user@example.com',
            role: 'user',
          ),
        ),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => session.epoch),
        memoriesPermittedProvider.overrideWith(
          (ref) => permitted == null
              ? Completer<bool>().future
              : Future<bool>.value(permitted),
        ),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          session = _AccountSession(api, ProviderScope.containerOf(context));
          return const MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PersonalizationPage(),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

final class _AccountStorage extends Fake implements OptimizedStorageService {
  @override
  bool isUncommittedServerConfigCandidate(ServerConfig config) => false;

  @override
  Future<List<ServerConfig>> getServerConfigs() async => const [_accountServer];

  @override
  Future<List<ServerConfig>> getServerConfigsStrict() async => const [
    _accountServer,
  ];

  @override
  Future<String?> getActiveServerId() async => _accountServer.id;
}

/// An [ApiService] that serves [memories] and records what the page sent.
final class _MemoriesApi extends ApiService {
  _MemoriesApi({this.memories = const []})
    : super(serverConfig: _accountServer, workerManager: WorkerManager());

  final List<ServerMemory> memories;
  final adds = <_MemoryWrite>[];
  final updates = <_MemoryWrite>[];
  final deleted = <String>[];

  /// Makes the next create or update fail, as a server refusal would.
  bool failNextWrite = false;

  void _refuseIfRequested() {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('server refused');
    }
  }

  @override
  Future<Map<String, dynamic>> getUserPermissions({
    ApiAuthSnapshot? authSnapshot,
  }) async => const {};

  @override
  Future<List<ServerMemory>> getMemories({
    ApiAuthSnapshot? authSnapshot,
  }) async => memories;

  @override
  Future<ServerMemory> createMemory({
    required String content,
    String type = ServerMemory.userType,
    String? path,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _refuseIfRequested();
    adds.add((content: content, type: type, path: path));
    return ServerMemory(
      id: 'new',
      userId: 'u',
      content: content,
      updatedAtEpoch: 20,
      createdAtEpoch: 20,
      type: type,
      path: path,
    );
  }

  @override
  Future<ServerMemory> updateMemory({
    required String memoryId,
    required String content,
    String? type,
    String? path,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _refuseIfRequested();
    updates.add((content: content, type: type, path: path));
    return ServerMemory(
      id: memoryId,
      userId: 'u',
      content: content,
      updatedAtEpoch: 20,
      createdAtEpoch: 1,
      type: type,
      path: path,
    );
  }

  @override
  Future<void> deleteMemory(
    String memoryId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    deleted.add(memoryId);
  }
}
