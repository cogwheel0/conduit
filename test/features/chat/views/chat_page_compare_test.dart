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
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
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
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// "Compare models" through the page that really admits the turn: a refusal
/// is explained and the composer keeps what the user wrote.
void main() {
  final l10n = AppLocalizationsEn();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  /// Opens the page on a stored chat and runs the real command to its start
  /// button: overflow menu, "Compare models", a second slot, Compare. [db] is
  /// the database a turn is admitted into; without one admission is refused.
  Future<ProviderContainer> compareOnPage(
    WidgetTester tester, {
    AppDatabase? db,
  }) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
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
    final container = ProviderContainer(
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
        syncEngineProvider.overrideWith(_NoDrainEngine.new),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(_Selected.new),
        activeConversationProvider.overrideWith(() => _Active(chat)),
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
      ],
    );
    addTearDown(container.dispose);
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
    addTearDown(db.close);
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
  @override
  Model? build() => const Model(id: 'alpha', name: 'Alpha');
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
  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {}
}
