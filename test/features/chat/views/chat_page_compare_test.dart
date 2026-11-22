import 'dart:async';
import 'dart:convert';
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
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit_core/features/direct_connections/services/direct_run_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
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

  /// Closes the page [compareOnPage] opened; a second call does nothing.
  Future<void> Function() closePage = () async {};

  /// A test of the page from [compareOnPage], which it closes before
  /// returning. A tear-down would be too late: flutter_test checks for pending
  /// timers as soon as a test returns, and a send can leave the page's
  /// Markdown service starting a worker isolate, whose timers end only when
  /// the container disposes the service.
  void testPage(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      await body(tester);
      await closePage();
    });
  }

  /// Opens the page on a stored chat and runs the real command to its start
  /// button: overflow menu, "Compare models", a second slot, Compare. [db] is
  /// the database a turn is admitted into; without one admission is refused.
  Future<ProviderContainer> compareOnPage(
    WidgetTester tester, {
    AppDatabase? db,
    bool ordinarySend = false,
    bool modelPicked = true,
    Future<List<Model>>? modelList,
    bool holdDrain = false,
    bool newChat = false,
    Conversation? conversation,
    bool reviewer = false,
    Model? model,
    DirectConnectionProfile? directProfile,
    List<ChatMessage> transcript = const <ChatMessage>[],
    String? followUp,
    List<Override> overrides = const <Override>[],
    void Function(ProviderContainer container)? whileSending,
  }) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    late final ProviderContainer container;
    var closed = false;
    closePage = () async {
      if (closed) return;
      closed = true;
      // Dropping the streaming placeholders ends the task poll they started.
      container.read(chatMessagesProvider.notifier)
        ..clearMessages()
        ..finishStreaming();
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await settle(tester);
      if (db != null) await pumpDatabaseOperation(tester, db.close);
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    };
    // A test that fails before the end still closes the page.
    addTearDown(closePage);
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
        selectedModelProvider.overrideWith(
          () => _Selected(modelPicked ? model : null, picked: modelPicked),
        ),
        activeConversationProvider.overrideWith(
          () => _Active(newChat ? null : (conversation ?? chat)),
        ),
        chatMessagesProvider.overrideWith(() => _Messages(transcript)),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        isChatStreamingProvider.overrideWith((ref) => false),
        isOnlineProvider.overrideWithValue(true),
        conversationsProvider.overrideWith(_Conversations.new),
        modelsProvider.overrideWith(() => _Models(modelList)),
        foldersProvider.overrideWith(_Folders.new),
        toolsListProvider.overrideWith(_Tools.new),
        comparisonCommandAvailableProvider.overrideWithValue(true),
        personalizationSettingsProvider.overrideWith(_Personalization.new),
        directConnectionProfilesProvider.overrideWith(
          directProfile == null
              ? _NoProfiles.new
              : () => _FixedDirectProfiles(directProfile),
        ),
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

    if (followUp != null) {
      await tester.tap(find.text(followUp));
      await settle(tester);
      return container;
    }
    await tester.enterText(find.byType(TextField), 'compare this');
    if (ordinarySend) {
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
      whileSending?.call(container);
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

  testPage('a refused comparison explains itself and keeps the draft', (
    tester,
  ) async {
    final container = await compareOnPage(tester);

    expect(find.text(l10n.chatCompareErrorUnavailable), findsOneWidget);
    expect(composerText(tester), 'compare this');
    // Nothing was admitted: the transcript is as it was.
    expect(container.read(chatMessagesProvider), isEmpty);
  });

  testPage('an admitted comparison puts both answers in the chat and '
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
  });

  testPage(
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
      }
    },
  );

  // Send waits until every file in the tray is uploaded. A file attached
  // after that, while the send reads the draft's recordings, is not one it
  // checked: the message goes without it, and it stays for the next one.
  testPage('a file attached while a send is admitted stays in the tray', (
    tester,
  ) async {
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
    final checked = _upload(
      'checked.txt',
      status: FileUploadStatus.completed,
      fileId: 'file-checked',
    );
    final later = _upload('later.txt', status: FileUploadStatus.uploading);
    final container = await compareOnPage(
      tester,
      db: db,
      ordinarySend: true,
      overrides: [
        attachedFilesProvider.overrideWith(() => _Tray([checked])),
      ],
      whileSending: (container) =>
          (container.read(attachedFilesProvider.notifier) as _Tray).put(later),
    );

    final sent = container
        .read(chatMessagesProvider)
        .firstWhere((message) => message.role == 'user');
    expect(sent.attachmentIds, ['file-checked']);
    expect(container.read(attachedFilesProvider), [same(later)]);
  });

  // With no model picked, the send waits for the model list. Another account
  // signing in meanwhile gets neither the message nor its files.
  testPage('a send waiting for a model sends nothing once another account '
      'signs in', (tester) async {
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
    final listed = Completer<List<Model>>();
    final checked = _upload(
      'checked.txt',
      status: FileUploadStatus.completed,
      fileId: 'file-checked',
    );
    final container = await compareOnPage(
      tester,
      db: db,
      ordinarySend: true,
      modelPicked: false,
      modelList: listed.future,
      overrides: [
        attachedFilesProvider.overrideWith(() => _Tray([checked])),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(_signIn),
        ),
      ],
    );

    container.read(_signIn.notifier).another();
    listed.complete(const [Model(id: 'alpha', name: 'Alpha')]);
    await settle(tester);

    expect(container.read(chatMessagesProvider), isEmpty);
    expect(await tester.runAsync(() => db.select(db.outboxOps).get()), isEmpty);
    expect(container.read(attachedFilesProvider), [same(checked)]);
  });

  testPage('a tapped follow-up is sent with the tools picked for the chat', (
    tester,
  ) async {
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
    await compareOnPage(
      tester,
      db: db,
      followUp: 'Is the water hot yet?',
      transcript: [
        ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Is the kettle on?',
          timestamp: DateTime.utc(2026, 11, 3),
        ),
        ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: 'It is.',
          timestamp: DateTime.utc(2026, 11, 3),
          model: 'alpha',
          followUps: const ['Is the water hot yet?'],
        ),
      ],
      overrides: [
        selectedToolIdsProvider.overrideWith(
          () => _PickedTools(const ['kettle-tools']),
        ),
      ],
    );

    final ops = await tester.runAsync(() => db.select(db.outboxOps).get());
    final completions = [
      for (final op in ops!)
        if (op.kind == 'requestCompletion')
          jsonDecode(op.payload) as Map<String, dynamic>,
    ];
    expect(completions, hasLength(1));
    expect(completions.single['toolIds'], ['kettle-tools']);
  });

  // An Open WebUI Direct turn goes through the server, which never says
  // when it reached its run: its draft is let go once the send is accepted,
  // as for any server model. Treated like a device Direct turn, it stayed
  // in the composer to be sent again.
  testPage('an Open WebUI Direct send clears its draft', (tester) async {
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
  testPage('a Hermes send whose session cannot be made keeps its draft', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final hermes = _NoNewSessionDesktopApi();
    final image = _dataImageUpload('before-turn.png');
    final container = await compareOnPage(
      tester,
      db: db,
      ordinarySend: true,
      newChat: true,
      model: hermesSyntheticModel(),
      overrides: [
        attachedFilesProvider.overrideWith(() => _Tray([image])),
        hermesConfigProvider.overrideWith(_DesktopHermesConfig.new),
        hermesApiServiceProvider.overrideWithValue(hermes),
        hermesCapabilitiesProvider.overrideWith(
          (ref) async => const HermesCapabilities(inputImages: true),
        ),
      ],
    );

    expect(hermes.sessionsAsked, 1);
    expect(hermes.turns, 0);
    expect(composerText(tester), 'compare this');
    expect(container.read(attachedFilesProvider), [same(image)]);
  });

  testPage('a stored Direct send clears composer text on turn 2 and retires '
      'attachments when the turn starts', (tester) async {
    final directDb = AppDatabase(NativeDatabase.memory());
    addTearDown(() => pumpDatabaseOperation(tester, directDb.close));
    final profile = DirectConnectionProfile(
      id: 'local-profile',
      name: 'Local provider',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'http://localhost:11434',
    );
    final registry = DirectModelRegistry();
    final model = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'local-model', isMultimodal: true),
    ]).single;
    final adapter = _WaitingDirectAdapter();
    final firstImage = _dataImageUpload('turn-1.png');
    final secondImage = _dataImageUpload('turn-2.png');

    final container = await compareOnPage(
      tester,
      ordinarySend: true,
      newChat: true,
      model: model,
      directProfile: profile,
      overrides: [
        openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        directModelRegistryProvider.overrideWithValue(registry),
        directModelDiscoveryProvider.overrideWith(_IdleDirectDiscovery.new),
        directRunRegistryProvider.overrideWithValue(DirectRunRegistry()),
        directProviderAdapterRegistryProvider.overrideWithValue(
          DirectProviderAdapterRegistry([adapter]),
        ),
        attachedFilesProvider.overrideWith(() => _Tray([firstImage])),
      ],
    );

    await tester.runAsync(() => adapter.asked.future);
    await settle(tester);

    // Turn 1: text clears and attachment retires while stream is still open.
    expect(adapter.runs, 1);
    expect(composerText(tester), isEmpty);
    expect(container.read(attachedFilesProvider), isEmpty);

    adapter.events
      ..add(const DirectContentDelta('First direct reply.'))
      ..add(const DirectStreamDone());
    await tester.runAsync(adapter.finish);
    await settle(tester);

    // Turn 2 on the same stored Direct chat: text must clear and attachment
    // must retire at onTurnStarted and stay retired if the stream fails.
    adapter.prepareNextRun();
    (container.read(attachedFilesProvider.notifier) as _Tray).put(secondImage);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'second direct turn');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
    await settle(tester);
    await tester.runAsync(
      () => adapter.asked.future.timeout(const Duration(seconds: 5)),
    );
    await settle(tester);

    expect(adapter.runs, 2);
    expect(composerText(tester), isEmpty);
    expect(container.read(attachedFilesProvider), isEmpty);

    adapter.events.addError(StateError('stream dropped'));
    await tester.runAsync(adapter.finish);
    await settle(tester);

    expect(composerText(tester), isEmpty);
    expect(container.read(attachedFilesProvider), isEmpty);
  });

  testPage('a Hermes send retires attachments when the turn starts even if the '
      'stream fails', (tester) async {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    addTearDown(() {
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      PreferencesStore.debugReset();
    });
    final db = AppDatabase(NativeDatabase.memory());
    final hermes = _WaitingDesktopHermesApi();
    final image = _dataImageUpload('hermes-turn.png');
    final container = await compareOnPage(
      tester,
      db: db,
      ordinarySend: true,
      newChat: true,
      model: hermesSyntheticModel(),
      overrides: [
        attachedFilesProvider.overrideWith(() => _Tray([image])),
        hermesConfigProvider.overrideWith(_DesktopHermesConfig.new),
        hermesApiServiceProvider.overrideWithValue(hermes),
        hermesCapabilitiesProvider.overrideWith(
          (ref) async => const HermesCapabilities(inputImages: true),
        ),
      ],
    );

    await tester.runAsync(
      () => hermes.asked.future.timeout(const Duration(seconds: 5)),
    );
    await settle(tester);

    expect(composerText(tester), isEmpty);
    expect(container.read(attachedFilesProvider), isEmpty);

    hermes.events.addError(StateError('hermes stream dropped'));
    await tester.runAsync(() => hermes.events.close());
    await settle(tester);

    expect(composerText(tester), isEmpty);
    expect(container.read(attachedFilesProvider), isEmpty);
  });

  testPage(
    'a Direct send rejected for an unsupported image keeps its draft and '
    'attachment',
    (tester) async {
      final directDb = AppDatabase(NativeDatabase.memory());
      addTearDown(() => pumpDatabaseOperation(tester, directDb.close));
      final existingDirect = withChatStorageProvenance(
        Conversation(
          id: 'direct-local:existing-chat',
          title: 'Existing direct chat',
          createdAt: DateTime.utc(2026, 7, 13),
          updatedAt: DateTime.utc(2026, 7, 13),
          metadata: const <String, dynamic>{'backend': 'direct'},
        ),
        ChatStorageKind.directLocal,
      );
      await tester.runAsync(
        () => directDb
            .into(directDb.chats)
            .insert(
              ChatsCompanion.insert(
                id: existingDirect.id,
                title: existingDirect.title,
                createdAt: 1,
                updatedAt: 1,
                bodySynced: const Value(true),
              ),
            ),
      );
      final profile = DirectConnectionProfile(
        id: 'text-only-profile',
        name: 'Text-only provider',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
      );
      final registry = DirectModelRegistry();
      final textOnlyModel = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'text-only-model', isMultimodal: false),
      ]).single;
      final adapter = _WaitingDirectAdapter();
      final photo = _dataImageUpload('rejected-photo.png');

      final container = await compareOnPage(
        tester,
        ordinarySend: true,
        conversation: existingDirect,
        model: textOnlyModel,
        directProfile: profile,
        overrides: [
          openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
          directLocalDatabaseProvider.overrideWithValue(directDb),
          directModelRegistryProvider.overrideWithValue(registry),
          directModelDiscoveryProvider.overrideWith(_IdleDirectDiscovery.new),
          directRunRegistryProvider.overrideWithValue(DirectRunRegistry()),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
          attachedFilesProvider.overrideWith(() => _Tray([photo])),
        ],
      );

      expect(adapter.runs, 0);
      expect(composerText(tester), 'compare this');
      expect(container.read(attachedFilesProvider), [same(photo)]);
    },
  );
}

FileUploadState _dataImageUpload(String name) {
  final dataUrl = 'data:image/png;base64,${base64Encode([1, 2, 3])}';
  return FileUploadState(
    file: File('${Directory.systemTemp.path}/sendpath-$name'),
    fileName: name,
    fileSize: 3,
    progress: 1,
    status: FileUploadStatus.completed,
    fileId: dataUrl,
    isImage: true,
    base64DataUrl: dataUrl,
  );
}

FileUploadState _upload(
  String name, {
  required FileUploadStatus status,
  String? fileId,
}) => FileUploadState(
  file: File('${Directory.systemTemp.path}/sendpath-$name'),
  fileName: name,
  fileSize: 1,
  progress: status == FileUploadStatus.completed ? 1 : 0.5,
  status: status,
  fileId: fileId,
);

/// The composer's tray, starting with [initial].
class _Tray extends AttachedFilesNotifier {
  _Tray(this.initial);

  final List<FileUploadState> initial;

  @override
  List<FileUploadState> build() => initial;

  void put(FileUploadState file) => state = [...state, file];
}

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

class _Models extends Models {
  _Models([this.list]);

  /// The list as the server gives it, once it does; Alpha alone when unset.
  final Future<List<Model>>? list;

  @override
  Future<List<Model>> build() async =>
      list ?? const [Model(id: 'alpha', name: 'Alpha')];
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
  _Selected(this.model, {this.picked = true});

  final Model? model;

  /// False for a chat with no model picked yet.
  final bool picked;

  @override
  Model? build() =>
      picked ? model ?? const Model(id: 'alpha', name: 'Alpha') : null;
}

/// The sign-in session, which a test replaces as another account signs in.
final _signIn = NotifierProvider<_SignIn, Object>(_SignIn.new);

class _SignIn extends Notifier<Object> {
  @override
  Object build() => Object();

  void another() => state = Object();
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
  _Messages([this.initial = const <ChatMessage>[]]);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;
}

class _PickedTools extends SelectedToolIds {
  _PickedTools(this.ids);

  final List<String> ids;

  @override
  List<String> build() => ids;
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

class _FixedDirectProfiles extends DirectConnectionProfilesController {
  _FixedDirectProfiles(this.profile);

  final DirectConnectionProfile profile;

  @override
  Future<List<DirectConnectionProfile>> build() async => [profile];
}

class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

class _WaitingDirectAdapter implements DirectProviderAdapter {
  StreamController<DirectStreamEvent> events =
      StreamController<DirectStreamEvent>();
  Completer<void> done = Completer<void>();
  Completer<void> asked = Completer<void>();
  var runs = 0;

  void prepareNextRun() {
    events = StreamController<DirectStreamEvent>();
    done = Completer<void>();
    asked = Completer<void>();
  }

  @override
  String get key => kOllamaAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => const [];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    runs++;
    if (!asked.isCompleted) asked.complete();
    return DirectCompletionRun(
      id: 'run-$runs',
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      events: events.stream,
      cancelToken: CancelToken(),
      done: done.future,
    );
  }

  Future<void> finish() async {
    await events.close();
    if (!done.isCompleted) done.complete();
  }
}

class _WaitingDesktopHermesApi extends HermesApiService
    implements HermesDesktopTurnService {
  _WaitingDesktopHermesApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example.test',
          mode: HermesBackendMode.desktopGateway,
        ),
        dio: Dio(),
      );

  final events = StreamController<HermesRunEvent>();
  final asked = Completer<void>();

  @override
  Future<List<Map<String, dynamic>>> getCurrentSessionMessages(
    String id,
  ) async => const [];

  @override
  Future<String> createDesktopSession({
    String? title,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
  }) async => 'desktop-session-1';

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
    if (!asked.isCompleted) asked.complete();
    return HermesResponseStream(events: events.stream);
  }
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
