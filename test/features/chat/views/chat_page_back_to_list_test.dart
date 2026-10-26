import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/navigation/providers/chat_back_provider.dart';
import 'package:conduit/features/navigation/utils/chat_list_back.dart';
import 'package:conduit/features/navigation/widgets/responsive_drawer_layout.dart';
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
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter/services.dart';
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
    title: id,
    createdAt: DateTime.utc(2026, 10, 26),
    updatedAt: DateTime.utc(2026, 10, 26),
  ),
  ChatStorageKind.openWebUi,
);

/// The real chat page under the real drawer, as the shell route builds it.
class _Rig {
  _Rig(this.tester, this.container, this.drawer, this.exits);

  final WidgetTester tester;
  final ProviderContainer container;
  final GlobalKey<ResponsiveDrawerLayoutState> drawer;
  final List<String> exits;

  bool get listOpen => drawer.currentState!.isOpen;

  bool get asksToClose => find.text(_en.endYourSession).evaluate().isNotEmpty;

  /// Opens [chat] the way the list does.
  Future<void> switchTo(Conversation chat) async {
    container
        .read(chatBackOpensListProvider.notifier)
        .switchTo(chat, chatOnScreen: true);
    container.read(activeConversationProvider.notifier).set(chat);
    await settle();
  }

  /// Settles with the composer cleared. The page focuses it once on start,
  /// and back clears it before anything else.
  Future<void> settle() async {
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
  }

  Future<void> back() async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Future<void> answer(String button) async {
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
  }
}

void main() {
  Future<_Rig> mount(
    WidgetTester tester, {
    bool android = true,
    Size size = const Size(400, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    debugChatBackIsAndroidOverride = android;
    addTearDown(() => debugChatBackIsAndroidOverride = null);

    final exits = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') exits.add('exit');
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(
          ApiService(
            serverConfig: const ServerConfig(
              id: 'back',
              name: 'back',
              url: 'https://back.example.test',
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

    final drawer = GlobalKey<ResponsiveDrawerLayoutState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ResponsiveDrawerLayout(
            key: drawer,
            maxFraction: 1.0,
            edgeFraction: 1.0,
            drawer: const Text('Chat list'),
            child: const ChatPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return _Rig(tester, container, drawer, exits);
  }

  testWidgets('back on the chat the app opened into asks to close', (
    tester,
  ) async {
    final rig = await mount(tester);

    // The first back clears the composer focused on start.
    await rig.back();
    expect(FocusManager.instance.primaryFocus, isA<FocusScopeNode>());
    expect(rig.asksToClose, isFalse);

    // The scope left holding focus is not an input, so back gets through.
    await rig.back();
    expect(rig.asksToClose, isTrue);
    expect(rig.listOpen, isFalse);
    await rig.answer(_en.confirm);
    expect(rig.exits, ['exit']);
  });

  testWidgets('back on a switched chat opens the list, then asks to close', (
    tester,
  ) async {
    final rig = await mount(tester);
    await rig.switchTo(_chat('older'));

    await rig.back();
    expect(rig.listOpen, isTrue);
    expect(rig.asksToClose, isFalse);

    // Back on the list asks rather than closing it onto the same chat, which
    // the next back would open the list over again.
    await rig.back();
    expect(rig.asksToClose, isTrue);
    await rig.answer(_en.cancel);
    expect(rig.listOpen, isTrue);
    expect(rig.exits, isEmpty);

    await rig.back();
    await rig.answer(_en.confirm);
    expect(rig.exits, ['exit']);
  });

  testWidgets('back with a list opened by hand asks to close, as before', (
    tester,
  ) async {
    final rig = await mount(tester);
    await rig.switchTo(_chat('older'));
    rig.drawer.currentState!.open();
    await rig.settle();

    await rig.back();

    expect(rig.asksToClose, isTrue);
    expect(rig.listOpen, isTrue);
  });

  testWidgets('a list closed by hand opens again on the next back', (
    tester,
  ) async {
    final rig = await mount(tester);
    await rig.switchTo(_chat('older'));
    await rig.back();
    rig.drawer.currentState!.close();
    await rig.settle();

    await rig.back();

    expect(rig.listOpen, isTrue);
    expect(rig.asksToClose, isFalse);
  });

  testWidgets('a new chat after a switch asks to close again', (tester) async {
    final rig = await mount(tester);
    await rig.switchTo(_chat('older'));
    startNewChat(rig.container);
    await rig.settle();

    await rig.back();

    expect(rig.asksToClose, isTrue);
    expect(rig.listOpen, isFalse);
  });

  testWidgets('the predictive back gesture opens the list too', (tester) async {
    final rig = await mount(tester);
    await rig.switchTo(_chat('older'));

    Future<void> gesture(String method, [Object? arguments]) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          SystemChannels.backGesture.name,
          SystemChannels.backGesture.codec.encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );
    await gesture('startBackGesture', <String, Object?>{
      'touchOffset': <double>[5, 300],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await gesture('updateBackGestureProgress', <String, Object?>{
      'touchOffset': <double>[120, 300],
      'progress': 0.5,
      'swipeEdge': 0,
    });
    await gesture('commitBackGesture');
    await tester.pumpAndSettle();

    expect(rig.listOpen, isTrue);
    expect(rig.asksToClose, isFalse);
    expect(rig.exits, isEmpty);
  });

  testWidgets('a tablet keeps its docked list and asks to close', (
    tester,
  ) async {
    final rig = await mount(tester, size: const Size(1200, 900));
    await rig.switchTo(_chat('older'));
    expect(rig.listOpen, isTrue);

    await rig.back();

    expect(rig.asksToClose, isTrue);
  });

  testWidgets('without a system back button the list never opens', (
    tester,
  ) async {
    final rig = await mount(tester, android: false);
    await rig.switchTo(_chat('older'));

    await rig.back();

    expect(rig.listOpen, isFalse);
    expect(rig.asksToClose, isTrue);
    await rig.answer(_en.confirm);
    expect(rig.exits, isEmpty);
  });
}
