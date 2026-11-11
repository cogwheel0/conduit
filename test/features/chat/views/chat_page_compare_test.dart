import 'dart:async';
import 'dart:io';

import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_database.dart';

/// "Compare models" through the page that really admits the turn: a refusal
/// is explained and the composer keeps what the user wrote.
void main() {
  final l10n = AppLocalizationsEn();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
  }

  /// Opens the page on a stored chat and runs the real command to its start
  /// button: overflow menu, "Compare models", a second slot, Compare. [db] is
  /// the database a turn is admitted into; without one admission is refused.
  Future<ProviderContainer> compareOnPage(
    WidgetTester tester, {
    AppDatabase? db,
    bool ordinarySend = false,
    bool holdDrain = false,
    bool newChat = false,
    bool reviewer = false,
    Model? model,
    List<Override> overrides = const <Override>[],
  }) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    late final ProviderContainer container;
    addTearDown(() async {
      container.read(chatMessagesProvider.notifier)
        ..clearMessages()
        ..finishStreaming();
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await settle(tester);
      if (db != null) await pumpDatabaseOperation(tester, db.close);
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });
    final chat = withChatStorageProvenance(
      Conversation(
        id: 'stored-chat',
        title: 'A chat',
        createdAt: DateTime.utc(2026, 7, 13),
        updatedAt: DateTime.utc(2026, 7, 13),
      ),
      ChatStorageKind.openWebUi,
    );
    container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(_Advanced.new),
        apiServiceProvider.overrideWithValue(
          _QuietApi(
            serverConfig: const ServerConfig(
              id: 'page',
              name: 'page',
              url: 'https://page.example.test',
            ),
            workerManager: WorkerManager(),
          ),
        ),
        // Without a database a durable comparison cannot be admitted, so the
        // real admission refuses it before anything is written.
        appDatabaseProvider.overrideWith((ref) => db),
        syncEngineProvider.overrideWith(() => _NoDrainEngine(hold: holdDrain)),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(reviewer),
        selectedModelProvider.overrideWith(() => _Selected(model)),
        activeConversationProvider.overrideWith(
          () => _Active(newChat ? null : chat),
        ),
        chatMessagesProvider.overrideWith(_Messages.new),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        isChatStreamingProvider.overrideWith((ref) => false),
        isOnlineProvider.overrideWithValue(true),
        conversationsProvider.overrideWith(_Conversations.new),
        modelsProvider.overrideWith(_Models.new),
        foldersProvider.overrideWith(_Folders.new),
        toolsListProvider.overrideWith(_Tools.new),
        comparisonCommandAvailableProvider.overrideWithValue(true),
        personalizationSettingsProvider.overrideWith(_Personalization.new),
        directConnectionProfilesProvider.overrideWith(_NoProfiles.new),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'me',
            email: 'me@example.test',
            role: 'user',
          ),
        ),
        ...overrides,
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChatPage(),
        ),
      ),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField), 'compare this');
    if (ordinarySend) {
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
      await settle(tester);
      return container;
    }
    await tester.tap(
      find.byKey(const ValueKey<String>('composer-overflow-button')),
    );
    await settle(tester);
    await tester.tap(find.text(l10n.chatCompareModelsAction));
    await settle(tester);
    // The chat's own model fills the first slot; the same model twice is a
    // valid pair.
    await tester.tap(find.byKey(const ValueKey<String>('comparison-slot-1')));
    await settle(tester);
    await tester.tap(find.text('Alpha').last);
    await settle(tester);
    await tester.tap(
      find.widgetWithText(ElevatedButton, l10n.chatCompareStart),
    );
    await settle(tester);
    return container;
  }

  String composerText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('a refused comparison explains itself and keeps the draft', (
    tester,
  ) async {
    final container = await compareOnPage(tester);

    expect(find.text(l10n.chatCompareErrorUnavailable), findsOneWidget);
    expect(composerText(tester), 'compare this');
    // Nothing was admitted: the transcript is as it was.
    expect(container.read(chatMessagesProvider), isEmpty);
  });

  testWidgets('an admitted comparison puts both answers in the chat and '
      'clears the draft', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(
      () => db
          .into(db.chats)
          .insert(
            ChatsCompanion.insert(
              id: 'stored-chat',
              title: 'A chat',
              createdAt: 1,
              updatedAt: 1,
              bodySynced: const Value(true),
            ),
          ),
    );
    final container = await compareOnPage(tester, db: db);

    expect(composerText(tester), isEmpty);
    final turn = container.read(chatMessagesProvider);
    expect(
      [for (final message in turn) message.role],
      ['user', 'assistant', 'assistant'],
    );
    // Dropping the streaming placeholders ends the task poll they started.
    container.read(chatMessagesProvider.notifier)
      ..clearMessages()
      ..finishStreaming();
  });

  testWidgets(
    'ordinary admission clears its draft before the network drain completes',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(
        () => db
            .into(db.chats)
            .insert(
              ChatsCompanion.insert(
                id: 'stored-chat',
                title: 'A chat',
                createdAt: 1,
                updatedAt: 1,
                bodySynced: const Value(true),
              ),
            ),
      );
      final container = await compareOnPage(
        tester,
        db: db,
        ordinarySend: true,
        holdDrain: true,
      );
      final engine =
          container.read(syncEngineProvider.notifier) as _NoDrainEngine;
      try {
        // Drive both SQLite and widget callbacks while the network remains held.
        final elapsed = Stopwatch()..start();
        while (composerText(tester).isNotEmpty &&
            elapsed.elapsed < const Duration(seconds: 10)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(composerText(tester), isEmpty);
        expect(engine.gate.isCompleted, isFalse);
        expect(
          container.read(chatMessagesProvider).map((message) => message.role),
          ['user', 'assistant'],
        );
      } finally {
        engine.gate.complete();
        await settle(tester);
        container.read(chatMessagesProvider.notifier)
          ..clearMessages()
          ..finishStreaming();
      }
    },
  );

  // An Open WebUI Direct turn goes through the server, which never says
  // when it reached its run: its draft is let go once the send is accepted,
  // as for any server model. Treated like a device Direct turn, it stayed
  // in the composer to be sent again.
  testWidgets('an Open WebUI Direct send clears its draft', (tester) async {
    final registry = DirectModelRegistry();
    final direct = registry
        .replaceProfileModels(
          DirectConnectionProfile(
            id: 'server-profile',
            name: 'Server connection',
            adapterKey: kOpenAiCompatibleAdapterKey,
            baseUrl: 'https://provider.example/v1',
            modelIdPrefix: 'server-prefix',
          ),
          [DirectRemoteModel(id: 'model', name: 'Provider model')],
          source: DirectModelSource.openWebUi,
          openWebUiUrlIndex: 0,
        )
        .single;
    final container = await compareOnPage(
      tester,
      ordinarySend: true,
      reviewer: true,
      model: direct,
      overrides: [
        directModelRegistryProvider.overrideWithValue(registry),
        // No discovery prunes the server's binding.
        directModelDiscoveryProvider.overrideWith(_IdleDirectDiscovery.new),
      ],
    );

    expect(
      container.read(directModelRegistryProvider).resolve(direct)?.source,
      DirectModelSource.openWebUi,
    );
    expect(composerText(tester), isEmpty);
  });

  // A Hermes turn gives up its words once it goes to its run. One whose new
  // session could not be made never did, and the page cleared them anyway.
  testWidgets('a Hermes send whose session cannot be made keeps its draft', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final hermes = _NoNewSessionDesktopApi();
    await compareOnPage(
      tester,
      db: db,
      ordinarySend: true,
      newChat: true,
      model: hermesSyntheticModel(),
      overrides: [
        hermesConfigProvider.overrideWith(_DesktopHermesConfig.new),
        hermesApiServiceProvider.overrideWithValue(hermes),
      ],
    );

    expect(hermes.sessionsAsked, 1);
    expect(hermes.turns, 0);
    expect(composerText(tester), 'compare this');
  });
}

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

class _Models extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(id: 'alpha', name: 'Alpha'),
  ];
}

class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const <Folder>[];
}

class _Tools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const <Tool>[];
}

class _Selected extends SelectedModel {
  _Selected(this.model);

  final Model? model;

  @override
  Model? build() => model ?? const Model(id: 'alpha', name: 'Alpha');
}

class _DesktopHermesConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example.test',
    mode: HermesBackendMode.desktopGateway,
  );
}

/// A Desktop Gateway whose new sessions cannot be made: the turn fails
/// before Hermes has its words.
class _NoNewSessionDesktopApi extends HermesApiService
    implements HermesDesktopTurnService {
  _NoNewSessionDesktopApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example.test',
          mode: HermesBackendMode.desktopGateway,
        ),
        dio: Dio(),
      );

  var sessionsAsked = 0;
  var turns = 0;

  @override
  Future<List<Map<String, dynamic>>> getCurrentSessionMessages(
    String id,
  ) async => const [];

  @override
  Future<String> createDesktopSession({
    String? title,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
  }) async {
    sessionsAsked++;
    throw StateError('Hermes could not open a session.');
  }

  @override
  Future<HermesResponseStream> streamDesktopResponse(
    HermesChatInput input, {
    String? sessionId,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
    String? voiceContext,
    int? truncateBeforeRowId,
    int? truncateSeenThroughRowId,
  }) async {
    turns++;
    return const HermesResponseStream(events: Stream.empty());
  }
}

class _Active extends ActiveConversationNotifier {
  _Active(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const <ChatMessage>[];
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _Advanced extends AppSettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(sendOnEnter: true, advancedFeaturesEnabled: true);
}

class _Personalization extends PersonalizationSettings {
  @override
  Future<ServerUserSettings> build() async => const ServerUserSettings();
}

class _IdleDirectDiscovery extends DirectModelDiscoveryController {
  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState();
}

class _NoProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => const [];
}

/// Answers the settings read an admission makes, without a network.
class _QuietApi extends ApiService {
  _QuietApi({required super.serverConfig, required super.workerManager});

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async =>
      const <String, dynamic>{};
}

/// A server drain that sends nothing: the turn stays exactly as admitted.
class _NoDrainEngine extends SyncEngine {
  _NoDrainEngine({this.hold = false});
  final bool hold;
  final gate = Completer<void>();
  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {
    if (hold) await gate.future;
  }
}
