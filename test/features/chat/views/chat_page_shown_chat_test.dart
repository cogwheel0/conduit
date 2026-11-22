/// The chat page tells the core which chat is on screen ([shownChatsProvider]):
/// its stored chat while the page shows and the app is in the foreground, and
/// none otherwise, so the core keeps that chat read on the server too.
library;

import 'dart:async';

import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/conduit_core.dart' show AppLifecyclePhase;
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const <ChatMessage>[];
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

Conversation _chat(String id) => withChatStorageProvenance(
  Conversation(
    id: id,
    title: 'Tide tables',
    createdAt: DateTime.utc(2026, 11, 2),
    updatedAt: DateTime.utc(2026, 11, 2),
  ),
  ChatStorageKind.openWebUi,
);

/// The real chat page in an app whose foreground the test drives.
class _Rig {
  _Rig(this.tester, this.container, this.lifecycle, this.navigator, this._app);

  final WidgetTester tester;
  final ProviderContainer container;
  final FakeAppLifecycle lifecycle;
  final GlobalKey<NavigatorState> navigator;
  final Widget Function(Key page) _app;

  /// The chats the core holds on screen.
  Iterable<String> get shown => container.read(shownChatsProvider).values;

  Future<void> open(Conversation chat) async {
    container.read(activeConversationProvider.notifier).set(chat);
    await tester.pumpAndSettle();
  }

  Future<void> goTo(AppLifecyclePhase phase) async {
    lifecycle.emit(phase);
    await tester.pumpAndSettle();
  }

  /// Puts a new chat page in place of the one shown, in one frame, as a
  /// router does when it builds the page anew.
  Future<void> replacePage() async {
    await tester.pumpWidget(_app(UniqueKey()));
    await tester.pumpAndSettle();
  }
}

void main() {
  Future<_Rig> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);
    final container = ProviderContainer(
      overrides: [
        appLifecycleProvider.overrideWithValue(lifecycle),
        apiServiceProvider.overrideWithValue(
          ApiService(
            serverConfig: const ServerConfig(
              id: 'shown',
              name: 'shown',
              url: 'https://shown.example.test',
            ),
            workerManager: WorkerManager(),
          ),
        ),
        appDatabaseProvider.overrideWith((ref) => null),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(_SelectedModel.new),
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
      ],
    );
    addTearDown(container.dispose);

    // Tear-downs run in reverse, so the tree goes before its container.
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    final navigator = GlobalKey<NavigatorState>();
    Widget app(Key page) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatPage(key: page),
      ),
    );
    await tester.pumpWidget(app(UniqueKey()));
    await tester.pumpAndSettle();
    return _Rig(tester, container, lifecycle, navigator, app);
  }

  testWidgets('the chat on screen shows only while the app is in the '
      'foreground', (tester) async {
    final rig = await mount(tester);
    final chat = _chat('chat-tides');
    final id = conversationScopedId(chat);

    await rig.open(chat);
    expect(rig.shown, [id]);

    await rig.goTo(AppLifecyclePhase.inactive);
    expect(rig.shown, isEmpty);
    await rig.goTo(AppLifecyclePhase.paused);
    expect(rig.shown, isEmpty);

    await rig.goTo(AppLifecyclePhase.resumed);
    expect(rig.shown, [id]);
  });

  testWidgets('a page over the chat page shows no chat until it is closed, '
      'while a dialog over it keeps its chat', (tester) async {
    final rig = await mount(tester);
    final chat = _chat('chat-tides');
    final id = conversationScopedId(chat);
    await rig.open(chat);

    unawaited(
      showDialog<void>(
        context: rig.navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Rename')),
      ),
    );
    await tester.pumpAndSettle();
    expect(rig.shown, [id]);
    rig.navigator.currentState!.pop();
    await tester.pumpAndSettle();

    unawaited(
      rig.navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Settings')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(rig.shown, isEmpty);

    rig.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(rig.shown, [id]);
  });

  testWidgets('a new chat, a temporary chat or a page gone shows no chat', (
    tester,
  ) async {
    final rig = await mount(tester);
    final chat = _chat('chat-tides');
    final id = conversationScopedId(chat);

    await rig.open(chat);
    expect(rig.shown, [id]);
    await rig.open(_chat('local:draft-tides'));
    expect(rig.shown, isEmpty);

    await rig.open(chat);
    expect(rig.shown, [id]);
    startNewChat(rig.container);
    await tester.pumpAndSettle();
    expect(rig.shown, isEmpty);

    await rig.open(chat);
    expect(rig.shown, [id]);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(rig.shown, isEmpty);
  });

  testWidgets('a chat page put in place of another shows its chat', (
    tester,
  ) async {
    final rig = await mount(tester);
    final chat = _chat('chat-tides');
    await rig.open(chat);

    await rig.replacePage();

    expect(rig.shown, [conversationScopedId(chat)]);
  });
}
