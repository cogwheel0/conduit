import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
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
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/primary_account_providers.dart';
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
  @override
  Conversation? build() => null;
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
  @override
  AppSettings build() => const AppSettings();
}

/// Who owns the Chats tab, and who is signed in to it, as a test sets them.
typedef _Primary = ({PrimaryAccountRef account, PrimaryUserSummary? user});

class _PrimaryController extends Notifier<_Primary> {
  @override
  _Primary build() => (
    account: const PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'owui'),
    user: const PrimaryUserSummary(
      kind: PrimaryAccountKind.openWebUi,
      id: 'root',
      displayName: 'Root',
    ),
  );

  void set(_Primary next) => state = next;
}

final _primary = NotifierProvider<_PrimaryController, _Primary>(
  _PrimaryController.new,
);

ApiService _api() => ApiService(
  serverConfig: const ServerConfig(
    id: 'page',
    name: 'page',
    url: 'https://page.example.test',
  ),
  workerManager: WorkerManager(),
);

void main() {
  Future<ProviderContainer> mountPage(WidgetTester tester) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(_Settings.new),
        apiServiceProvider.overrideWithValue(_api()),
        appDatabaseProvider.overrideWith((ref) => null),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(_SelectedModel.new),
        activeConversationProvider.overrideWith(_Active.new),
        chatMessagesProvider.overrideWith(_Messages.new),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        isChatStreamingProvider.overrideWith((ref) => false),
        conversationsProvider.overrideWith(_Conversations.new),
        modelsProvider.overrideWith(_Models.new),
        foldersProvider.overrideWith(_Folders.new),
        toolsListProvider.overrideWith(_Tools.new),
        primaryAccountProvider.overrideWith(
          (ref) => ref.watch(_primary).account,
        ),
        primaryUserProvider.overrideWith((ref) => ref.watch(_primary).user),
        openWebUiChatSettingsAccessProvider.overrideWith(
          (ref) async => OpenWebUiChatSettingsAccess.all,
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
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('keeps the name while the same account reloads its user', (
    tester,
  ) async {
    final container = await mountPage(tester);
    expect(find.text(_en.greetingTitle('Root')), findsOneWidget);

    container
        .read(_primary.notifier)
        .set((account: container.read(_primary).account, user: null));
    await tester.pumpAndSettle();

    expect(find.text(_en.greetingTitle('Root')), findsOneWidget);
  });

  testWidgets('never greets another account by the last one\'s name', (
    tester,
  ) async {
    final container = await mountPage(tester);
    expect(find.text(_en.greetingTitle('Root')), findsOneWidget);

    // LibreChat takes the Chats tab before its user is known.
    container
        .read(_primary.notifier)
        .set((
          account: const PrimaryAccountRef(
            PrimaryAccountKind.libreChat,
            'librechat:account',
          ),
          user: null,
        ));
    await tester.pumpAndSettle();

    expect(find.text(_en.greetingTitle('Root')), findsNothing);
  });
}
