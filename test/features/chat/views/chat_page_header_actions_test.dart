import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/live_connection_button.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
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
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];

  void show(List<ChatMessage> messages) => state = messages;
}

class _Active extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _Models extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(id: 'fixture-model', name: 'Fixture model'),
  ];
}

class _SelectedModel extends SelectedModel {
  @override
  Model? build() => const Model(id: 'fixture-model', name: 'Fixture model');
}

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const [];
}

class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const [];
}

class _Tools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const [];
}

class _Speech extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _Connectivity extends Fake implements ConnectivityService {
  @override
  Stream<ConnectivityStatus> get statusStream => const Stream.empty();
  @override
  ConnectivityStatus get currentStatus => ConnectivityStatus.online;
  @override
  bool get isOnline => true;
  @override
  bool get isAppForeground => true;
  @override
  int get lastLatencyMs => 0;
}

final _firstTurn = [
  ChatMessage(
    id: 'turn-user',
    role: 'user',
    content: 'Which herbs grow well on a sunny windowsill?',
    timestamp: DateTime.utc(2026, 10, 1),
    model: 'fixture-model',
  ),
];

final _conversation = Conversation(
  id: 'herb-chat',
  title: 'Windowsill herbs',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

Future<ProviderContainer> _pumpChatPage(
  WidgetTester tester, {
  EdgeInsets? safePadding,
}) async {
  tester.view.physicalSize = const Size(402, 874);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
  PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
  PlatformUiCapabilities.debugNativeIOS26Override = true;
  addTearDown(PlatformUiCapabilities.resetDebugOverrides);

  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      apiServiceProvider.overrideWithValue(
        ApiService(
          serverConfig: const ServerConfig(
            id: 'header',
            name: 'Example server',
            url: 'https://header.example.test',
          ),
          workerManager: WorkerManager(),
        ),
      ),
      activeConversationProvider.overrideWith(_Active.new),
      openWebUiChatSettingsMenuEntryProvider.overrideWith(
        (ref) => OpenWebUiChatSettingsMenuEntry.none,
      ),
      appDatabaseProvider.overrideWith((ref) => null),
      connectivityServiceProvider.overrideWithValue(_Connectivity()),
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
      textToSpeechControllerProvider.overrideWith(_Speech.new),
      liveConnectionDisconnectedProvider.overrideWith(
        (ref) => Stream.value(false),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat)
            .copyWith(platform: TargetPlatform.iOS),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: safePadding == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(padding: safePadding, viewPadding: safePadding),
                child: child!,
              ),
        home: const ChatPage(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return container;
}

List<Object> _barActions(WidgetTester tester) => [
  for (final item
      in tester
          .widget<ConduitToolbarActionCluster>(
            find.byType(ConduitToolbarActionCluster),
          )
          .items)
    item.id,
];

Future<void> _tearDown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  test('the first send holds a new chat\'s actions until its chat exists', () {
    // Nothing sent: no hold.
    expect(
      chatHeaderHoldsNewChatActions(
        hasMessages: false,
        hasSettledConversation: false,
        holdExpired: false,
      ),
      isFalse,
    );
    // The first message is on its way, its conversation not made yet.
    expect(
      chatHeaderHoldsNewChatActions(
        hasMessages: true,
        hasSettledConversation: false,
        holdExpired: false,
      ),
      isTrue,
    );
    // The conversation exists: the chat's own actions.
    expect(
      chatHeaderHoldsNewChatActions(
        hasMessages: true,
        hasSettledConversation: true,
        holdExpired: false,
      ),
      isFalse,
    );
    // It took too long: show the chat's actions anyway.
    expect(
      chatHeaderHoldsNewChatActions(
        hasMessages: true,
        hasSettledConversation: false,
        holdExpired: true,
      ),
      isFalse,
    );
  });

  test('a local placeholder settles only a chat meant to stay temporary', () {
    final placeholder = _conversation.copyWith(id: 'local:herb-chat');
    expect(
      chatHeaderConversationSettled(
        conversation: null,
        temporaryChatEnabled: false,
      ),
      isFalse,
    );
    expect(
      chatHeaderConversationSettled(
        conversation: placeholder,
        temporaryChatEnabled: false,
      ),
      isFalse,
    );
    expect(
      chatHeaderConversationSettled(
        conversation: placeholder,
        temporaryChatEnabled: true,
      ),
      isTrue,
    );
    expect(
      chatHeaderConversationSettled(
        conversation: _conversation,
        temporaryChatEnabled: false,
      ),
      isTrue,
    );
  });

  testWidgets(
    'a first send changes the bar actions once, to New Chat and More',
    (tester) async {
      final container = await _pumpChatPage(tester);
      expect(_barActions(tester), ['temporary-chat']);
      expect(find.byKey(const ValueKey('chat-sidebar-toggle')), findsOneWidget);

      final seen = <String>[_barActions(tester).join(',')];
      void record() {
        final current = _barActions(tester).join(',');
        if (current != seen.last) seen.add(current);
      }

      // The message lands before its conversation is made, then a local
      // placeholder stands in until the server's chat replaces it.
      (container.read(chatMessagesProvider.notifier) as _Messages).show(
        _firstTurn,
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        record();
      }
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation.copyWith(id: 'local:herb-chat'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        record();
      }
      container.read(activeConversationProvider.notifier).set(_conversation);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        record();
      }

      // Exactly one change, never through "toggle and New Chat" or "New Chat
      // alone".
      expect(seen, ['temporary-chat', 'new-chat,more']);
      await _tearDown(tester);
    },
  );

  testWidgets('without a conversation the hold ends after a moment', (
    tester,
  ) async {
    final container = await _pumpChatPage(tester);
    (container.read(chatMessagesProvider.notifier) as _Messages).show(
      _firstTurn,
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(_barActions(tester), ['temporary-chat']);
    await tester.pump(kChatHeaderNewChatActionsHold);
    await tester.pump(const Duration(milliseconds: 16));
    // What a chat without a conversation offers: the toggle and New Chat.
    expect(_barActions(tester), ['temporary-chat', 'new-chat']);
    // The send has read the setting, so until its chat exists the toggle
    // changes nothing; past the hold it shows as disabled.
    final toggle = tester
        .widget<ConduitToolbarActionCluster>(
          find.byType(ConduitToolbarActionCluster),
        )
        .items
        .firstWhere((item) => item.id == 'temporary-chat')
        .action;
    expect(toggle.onPressed, isNull);
    expect(toggle.enabled, isFalse);
    expect(container.read(temporaryChatEnabledProvider), isFalse);
    await _tearDown(tester);
  });

  testWidgets('the model pill starts beside the sidebar button and may take '
      'the room up to the trailing actions', (tester) async {
    final container = await _pumpChatPage(tester);
    final pill = find.byType(ConduitAdaptiveAppBarModelSelector);
    final sidebar = find.byKey(const ValueKey('chat-sidebar-toggle'));
    // The bar's 8 pt gap after the sidebar button.
    expect(
      tester.getTopLeft(pill).dx - tester.getTopRight(sidebar).dx,
      closeTo(kConduitBarTitleGap, 0.5),
    );
    // A new chat: everything between the sidebar button and the one
    // trailing circle (402 - 2 * 16 - 44 - 44 - 2 * 8).
    expect(
      tester.widget<ConduitAdaptiveAppBarModelSelector>(pill).maxWidth,
      266,
    );

    container.read(activeConversationProvider.notifier).set(_conversation);
    (container.read(chatMessagesProvider.notifier) as _Messages).show(
      _firstTurn,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_barActions(tester), ['new-chat', 'more']);
    expect(
      tester.getTopLeft(pill).dx - tester.getTopRight(sidebar).dx,
      closeTo(kConduitBarTitleGap, 0.5),
    );
    // A chat's title may run up to the two-glyph group, 8 pt clear
    // (402 - 2 * 16 - 44 - 103 - 2 * 8), rather than twice the room from
    // the centre line to the nearer control.
    final maxWidth = tester
        .widget<ConduitAdaptiveAppBarModelSelector>(pill)
        .maxWidth;
    expect(maxWidth, 207);
    await _tearDown(tester);
  });

  testWidgets('the header keeps clear of a side safe area, and the model '
      'pill gives up that room', (tester) async {
    // iPhone Duo's front display: the status bar runs down the right edge.
    await _pumpChatPage(
      tester,
      safePadding: const EdgeInsets.only(top: 24, right: 54),
    );
    final pill = find.byType(ConduitAdaptiveAppBarModelSelector);
    final sidebar = find.byKey(const ValueKey('chat-sidebar-toggle'));
    final actions = find.byType(ConduitToolbarActionCluster);
    expect(tester.getTopLeft(sidebar).dx, Spacing.inputPadding);
    expect(tester.getTopRight(actions).dx, 402 - 54 - Spacing.inputPadding);
    // 266 without the strip, less its 54 pt.
    expect(
      tester.widget<ConduitAdaptiveAppBarModelSelector>(pill).maxWidth,
      212,
    );
    await _tearDown(tester);
  });

  testWidgets('a tap on the Temporary Chat glyph turns it on and off at once', (
    tester,
  ) async {
    final container = await _pumpChatPage(tester);
    ConduitToolbarClusterItem toggle() => tester
        .widget<ConduitToolbarActionCluster>(
          find.byType(ConduitToolbarActionCluster),
        )
        .items
        .single;
    expect(toggle().id, 'temporary-chat');
    expect(container.read(temporaryChatEnabledProvider), isFalse);

    toggle().action.onPressed!();
    await tester.pumpAndSettle();
    // No popover stands between the tap and the setting: it is on, and the
    // empty chat says so.
    expect(container.read(temporaryChatEnabledProvider), isTrue);
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'CupertinoSwitch',
      ),
      findsNothing,
    );
    expect(find.text("This chat won't appear in history"), findsOneWidget);

    toggle().action.onPressed!();
    await tester.pumpAndSettle();
    expect(container.read(temporaryChatEnabledProvider), isFalse);
    expect(find.text("This chat won't appear in history"), findsNothing);
    await _tearDown(tester);
  });

  test('the composer asks the chat\'s model, or Conduit without one', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(
      chatComposerPlaceholder(l10n, modelName: 'GPT-5 mini'),
      'Ask GPT-5 mini',
    );
    // A name split over lines still reads as one.
    expect(
      chatComposerPlaceholder(l10n, modelName: ' Research\n Assistant '),
      'Ask Research Assistant',
    );
    // A long name is cut short; the header's pill shows it whole.
    final long = chatComposerPlaceholder(
      l10n,
      modelName: 'research-assistant-with-a-long-name-v2-instruct',
    );
    expect(long, 'Ask research-assistant-with\u2026');
    expect(
      long!.substring('Ask '.length).characters.length,
      kChatComposerPlaceholderMaxNameLength,
    );
    // Whole characters only: an emoji is never split.
    expect(
      chatComposerPlaceholder(
        l10n,
        modelName: '\u{1F469}\u200D\u{1F52C} ${'a' * 30}',
      ),
      'Ask \u{1F469}\u200D\u{1F52C} ${'a' * 21}\u2026',
    );
    // No name: the composer keeps "Ask Conduit".
    expect(chatComposerPlaceholder(l10n, modelName: null), isNull);
    expect(chatComposerPlaceholder(l10n, modelName: '  '), isNull);
  });

  testWidgets('the composer names the selected model only once the setting '
      'is on', (tester) async {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    addTearDown(PreferencesStore.debugReset);
    final container = await _pumpChatPage(tester);
    String? placeholder() => tester
        .widget<ModernChatInput>(find.byType(ModernChatInput))
        .placeholder;

    // Off by default: the composer keeps its own "Ask Conduit".
    expect(container.read(appSettingsProvider).showModelNameInComposer, false);
    expect(placeholder(), isNull);
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField))
          .placeholder,
      contains('Ask Conduit'),
    );

    await container
        .read(appSettingsProvider.notifier)
        .setShowModelNameInComposer(true);
    await tester.pump();
    expect(placeholder(), 'Ask Fixture model');

    await container
        .read(appSettingsProvider.notifier)
        .setShowModelNameInComposer(false);
    await tester.pump();
    expect(placeholder(), isNull);
    await _tearDown(tester);
  });
}
