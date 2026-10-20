import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _en = AppLocalizationsEn();

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

class _Models extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(id: 'model-1', name: 'Model 1'),
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

class _SelectedModel extends SelectedModel {
  @override
  Model? build() => const Model(id: 'model-1', name: 'Model 1');
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

class _Settings extends AppSettingsNotifier {
  _Settings(this.advanced);

  final bool advanced;

  @override
  AppSettings build() => AppSettings(advancedFeaturesEnabled: advanced);
}

ApiService _api() => ApiService(
  serverConfig: const ServerConfig(
    id: 'page',
    name: 'page',
    url: 'https://page.example.test',
  ),
  workerManager: WorkerManager(),
);

Conversation _chat({Map<String, dynamic> chatParams = const {}}) =>
    withChatStorageProvenance(
      Conversation(
        id: 'stored-chat',
        title: 'A chat',
        createdAt: DateTime.utc(2026, 7, 13),
        updatedAt: DateTime.utc(2026, 7, 13),
        chatParams: chatParams,
      ),
      ChatStorageKind.openWebUi,
    );

void main() {
  Future<ProviderContainer> mountPage(
    WidgetTester tester, {
    required bool advanced,
    Conversation? active,
    OpenWebUiChatSettingsAccess access = OpenWebUiChatSettingsAccess.all,
    Model? model,
    ApiService? api,
  }) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(() => _Settings(advanced)),
        apiServiceProvider.overrideWithValue(api ?? _api()),
        appDatabaseProvider.overrideWith((ref) => null),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(
          model == null ? _SelectedModel.new : () => _FixedModel(model),
        ),
        activeConversationProvider.overrideWith(() => _Active(active)),
        chatMessagesProvider.overrideWith(_Messages.new),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        isChatStreamingProvider.overrideWith((ref) => false),
        conversationsProvider.overrideWith(_Conversations.new),
        modelsProvider.overrideWith(_Models.new),
        foldersProvider.overrideWith(_Folders.new),
        toolsListProvider.overrideWith(_Tools.new),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'me',
            email: 'me@example.test',
            role: 'user',
          ),
        ),
        openWebUiChatSettingsAccessProvider.overrideWith((ref) async => access),
      ],
    );
    addTearDown(container.dispose);
    container.listen(openWebUiChatSettingsAccessProvider, (_, _) {});
    await container.read(openWebUiChatSettingsAccessProvider.future);

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
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> openOverflow(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }

  testWidgets('the chat overflow opens the editor when Advanced is on', (
    tester,
  ) async {
    await mountPage(tester, advanced: true, active: _chat());

    await openOverflow(tester);
    expect(find.text(_en.chatSettingsTitle), findsOneWidget);

    await tester.tap(find.text(_en.chatSettingsTitle));
    await tester.pumpAndSettle();

    // The real action landed on the editor, not just a menu row.
    expect(find.text(_en.chatSettingsDescription), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-settings-save')), findsOneWidget);
  });

  testWidgets('with Advanced off there is no editor entry for a plain chat', (
    tester,
  ) async {
    await mountPage(tester, advanced: false, active: _chat());

    // Nothing in the overflow is about settings, so it may not even exist.
    expect(find.text(_en.chatSettingsTitle), findsNothing);
    expect(find.text(_en.chatSettingsApplied), findsNothing);
  });

  testWidgets(
    'with Advanced off a chat that has saved settings says they apply',
    (tester) async {
      await mountPage(
        tester,
        advanced: false,
        active: _chat(chatParams: const {'temperature': 0.2}),
      );

      await openOverflow(tester);
      expect(find.text(_en.chatSettingsTitle), findsNothing);
      await tester.tap(find.text(_en.chatSettingsApplied));
      await tester.pumpAndSettle();

      // Read-only: what applies is shown, and nothing can be saved from here.
      expect(find.text(_en.chatSettingTemperature), findsOneWidget);
      expect(find.text('0.2'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-settings-save')), findsNothing);
    },
  );

  testWidgets('a new chat can be configured before its first message', (
    tester,
  ) async {
    await mountPage(tester, advanced: true);

    await openOverflow(tester);
    await tester.tap(find.text(_en.chatSettingsTitle));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('chat-settings-save')), findsOneWidget);
  });

  testWidgets('another user\'s chat never offers it', (tester) async {
    await mountPage(
      tester,
      advanced: true,
      active: _chat().copyWith(userId: 'someone-else'),
    );

    expect(find.text(_en.chatSettingsTitle), findsNothing);
  });
}

class _FixedModel extends SelectedModel {
  _FixedModel(this.model);

  final Model model;

  @override
  Model? build() => model;
}
