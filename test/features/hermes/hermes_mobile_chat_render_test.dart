import 'package:conduit/features/chat/voice_call/presentation/voice_call_launcher.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'package:flutter/rendering.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:conduit/features/chat/widgets/chat_timeline_viewport.dart';
import 'package:conduit/features/hermes/widgets/hermes_mobile_shell.dart';
import 'package:conduit/features/hermes/widgets/hermes_chat_quick_switcher.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart'
    show CompactNavigationSurface;
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _CallLauncher extends VoiceCallLauncher {
  _CallLauncher(super.ref, this.onLaunch);
  final void Function() onLaunch;
  @override
  Future<void> launch({required bool startNewConversation}) async => onLaunch();
}

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

class _Models extends Models {
  @override
  Future<List<Model>> build() async => [hermesSyntheticModel()];
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
  Model? build() => hermesSyntheticModel();
}

class _Active extends ActiveConversationNotifier {
  _Active(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

class _Messages extends ChatMessagesNotifier {
  _Messages(this.initial);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;

  void loadHistory() {
    state = [
      initial.first,
      for (var i = 0; i < 60; i++)
        initial.last.copyWith(
          id: 'history-$i',
          content: 'A paragraph in the conversation history. This reply contains a few lines of ordinary text.',
        ),
      initial.last,
    ];
  }

  void replaceReply(String content) {
    state = [state.first, state.last.copyWith(content: content)];
  }

  void askQuestion() {
    state = [
      state.first,
      state.last.copyWith(
        content: '',
        metadata: {
          'transport': 'hermesRun',
          'hermesDecision': {
            'state': 'pending',
            'kind': 'clarification',
            'prompt': 'Which pages should I update?',
            'requestId': 'pages',
            'runtimeId': 'runtime',
            'storedSessionId': 'example',
            'expiresAt': DateTime.now()
                .add(const Duration(hours: 1))
                .toUtc()
                .toIso8601String(),
          },
        },
      ),
    ];
  }
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

// Advanced stays off: the branch switcher does not depend on it.
class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() {
  testWidgets(
    'Android Hermes chat renders a compact header, bubbles, composer and back-to-list',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(bottom: 24);
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPadding);
      const renderFont = String.fromEnvironment('CONDUIT_RENDER_FONT');
      const renderDark = bool.fromEnvironment('CONDUIT_RENDER_DARK');
      final renderTheme = renderDark
          ? AppTheme.dark(TweakcnThemes.conduit)
          : AppTheme.light(TweakcnThemes.conduit);
      if (renderFont.isNotEmpty) {
        await tester.runAsync(() async {
          final loader = FontLoader('Roboto')
            ..addFont(
              Future.value(
                ByteData.sublistView(await File(renderFont).readAsBytes()),
              ),
            );
          await loader.load();
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
          await (FontLoader('HermesControls')
                ..addFont(rootBundle.load('assets/icons/hermes-controls.ttf')))
              .load();
        });
      }
      final at = DateTime.utc(2026, 10, 9);
      final messages = [
        ChatMessage(
          id: 'u',
          role: 'user',
          content: 'Can you help me redesign my website?',
          timestamp: at,
        ),
        ChatMessage(
          id: 'a',
          role: 'assistant',
          content: 'Hello. What do you need?',
          timestamp: at,
          model: hermesSyntheticModel().id,
        ),
      ];
      final chat = markNativeHermesConversation(
        Conversation(
          id: 'local:hermes_example',
          title: 'Website redesign',
          createdAt: at,
          updatedAt: at,
          messages: messages,
          metadata: const {'backend': 'hermes', 'hermesSessionId': 'example'},
        ),
      );
      var calls = 0;
      final container = ProviderContainer(
        overrides: [
          voiceCallLauncherProvider.overrideWith(
            (ref) => _CallLauncher(ref, () => calls++),
          ),
          appSettingsProvider.overrideWith(_Settings.new),
          apiServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWith((_) => null),
          isAuthenticatedProvider2.overrideWithValue(false),
          reviewerModeProvider.overrideWithValue(false),
          selectedModelProvider.overrideWith(_SelectedModel.new),
          activeConversationProvider.overrideWith(() => _Active(chat)),
          chatMessagesProvider.overrideWith(() => _Messages(messages)),
          optimizedStorageServiceProvider.overrideWithValue(_Storage()),
          isChatStreamingProvider.overrideWithValue(false),
          isOnlineProvider.overrideWithValue(true),
          conversationsProvider.overrideWith(_Conversations.new),
          modelsProvider.overrideWith(_Models.new),
          foldersProvider.overrideWith(_Folders.new),
          toolsListProvider.overrideWith(_Tools.new),
          currentUserProvider2.overrideWithValue(
            const User(
              id: 'example',
              username: 'Example',
              email: 'example@example.test',
              role: 'user',
            ),
          ),
          hermesMobileLayoutProvider.overrideWithValue(true),
          hermesApiServiceProvider.overrideWithValue(null),
          hermesCapabilitiesProvider.overrideWith(
            (_) async => const HermesCapabilities(inputImages: true),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(hermesActiveSessionProvider.notifier).set('example');
      container
          .read(hermesMobileNavigationProvider.notifier)
          .showConversation();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: renderTheme.copyWith(
                appBarTheme: renderTheme.appBarTheme.copyWith(
                  titleTextStyle: TextStyle(
                    fontFamily: renderFont.isEmpty ? null : 'Roboto',
                  ),
                ),
                textTheme: renderTheme.textTheme.apply(
                  fontFamily: renderFont.isEmpty ? null : 'Roboto',
                ),
              ),
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const HermesMobileShell(child: ChatPage()),
            ),
          ),
        ),
      );
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(tester.takeException(), isNull);
      expect(find.text('Website redesign'), findsOneWidget);
      expect(find.byTooltip('Conversations'), findsOneWidget);
      expect(find.text('Hermes Agent'), findsNothing);
      expect(find.byIcon(Icons.auto_awesome), findsNothing);
      expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 48);
      expect(find.byKey(const ValueKey('hermes-nav-chat')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-dictation-start')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('primary-btn-send')), findsNothing);
      expect(find.byType(HermesChatQuickSwitcher), findsNothing);
      expect(tester.getRect(find.byType(ChatPage)).bottom, 844);
      final composer = tester.getRect(
        find.byKey(const ValueKey('composer-native-shell')),
      );
      final navigation = tester.getRect(
        find.byKey(const ValueKey('hermes-nav-chat')),
      );
      expect(navigation.top - composer.bottom, inExclusiveRange(0, 14));
      final navSurface = tester.getRect(find.byType(CompactNavigationSurface));
      final selectedNav = tester.getRect(
        find.byKey(const ValueKey('hermes-nav-chat')),
      );
      expect(selectedNav.top, greaterThanOrEqualTo(navSurface.top));
      expect(selectedNav.bottom, lessThanOrEqualTo(navSurface.bottom));
      expect(selectedNav.height, greaterThanOrEqualTo(48));
      // A partial IME covers the footer progressively without moving the
      // composer through it. Reversing restores the original geometry.
      for (final inset in [1.0, 30.0, 79.0, 300.0, 30.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pumpAndSettle();
        final input = tester.getRect(
          find.byKey(const ValueKey('composer-native-shell')),
        );
        expect(input.bottom, lessThanOrEqualTo(844 - inset));
        expect(tester.takeException(), isNull);
      }
      tester.view.resetViewInsets();
      expect(
        tester.getRect(find.byKey(const ValueKey('composer-native-shell'))),
        composer,
      );
      // Refresh is an overscroll at latest, not navigation into history. Check
      // during the live drag as well as after settling (where the old bug hid).
      final gesture = await tester.startGesture(const Offset(200, 380));
      await gesture.moveBy(const Offset(0, -65));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester
            .widget<ModernChatInput>(find.byType(ModernChatInput))
            .showModelSelector,
        isTrue,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      final user = tester.getRect(
        find.byKey(const Key('user-message-bubble-surface')),
      );
      expect(user.right, greaterThan(350));
      final assistantSurface = tester.getRect(
        find
            .descendant(
              of: find.byKey(
                const ValueKey('assistant-message-bubble-surface-a'),
              ),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final assistantText = tester.getRect(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText() == messages.last.content,
        ),
      );
      expect(
        assistantSurface.bottom - assistantText.bottom,
        lessThanOrEqualTo(16),
      );
      expect(assistantSurface.width, lessThan(300));
      // 12dp padding and the new 1dp outline on each side.
      expect(assistantSurface.width - assistantText.width, closeTo(26, 1));
      if (const bool.fromEnvironment('CONDUIT_CAPTURE_RENDER')) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory('build/mobile-preview')
            ..createSync(recursive: true);
          File('${directory.path}/native-chat${renderDark ? '-dark' : ''}.png')
              .writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      // Calling has its own menu action; the existing dictation mic remains.
      expect(find.byIcon(Icons.mic), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hermes-attachment-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Voice Call'), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      final popup = find
          .ancestor(
            of: find.byType(PopupMenuItem<String>).first,
            matching: find.byType(Material),
          )
          .first;
      for (final inset in [180.0, 60.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pumpAndSettle();
        final plusTop = tester
            .getRect(find.byKey(const ValueKey('hermes-attachment-menu')))
            .top;
        expect(plusTop - tester.getRect(popup).bottom, closeTo(8, 1));
      }
      tester.view.resetViewInsets();
      if (const bool.fromEnvironment('CONDUIT_CAPTURE_RENDER')) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory('build/mobile-preview')
            ..createSync(recursive: true);
          File(
            '${directory.path}/voice-call-menu${renderDark ? '-dark' : ''}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('Voice Call'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      final messageNotifier =
          container.read(chatMessagesProvider.notifier) as _Messages;
      messageNotifier.loadHistory();
      container
          .read(chatTranscriptPagingProvider.notifier)
          .restoreLoadedCount(totalMessages: 62, loadedCount: 62);
      await tester.pumpAndSettle();
      tester
          .widget<ChatTimelineViewport>(find.byType(ChatTimelineViewport))
          .controller
          .jumpToLatest();
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(200, 380), const Offset(0, 350));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ModernChatInput>(find.byType(ModernChatInput))
            .showModelSelector,
        isFalse,
      );
      await tester.dragFrom(const Offset(200, 500), const Offset(0, -10000));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ModernChatInput>(find.byType(ModernChatInput))
            .showModelSelector,
        isTrue,
      );
      messageNotifier.replaceReply(messages.last.content);
      await tester.pumpAndSettle();
      // Generic actions stay hidden until either message is held.
      expect(find.text('Copy'), findsNothing);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      expect(find.byIcon(Icons.refresh), findsNothing);
      await tester.longPress(
        find.byKey(const ValueKey('hermes-message-actions-a')),
      );
      await tester.pumpAndSettle();
      for (final label in ['Reply', 'Copy', 'Select', 'Speak']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Delete'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Reply')).dy,
        lessThan(tester.getTopLeft(find.text('Copy')).dy),
      );
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      final selection = find.byKey(
        const ValueKey('hermes-select-message-text'),
      );
      expect(selection, findsOneWidget);
      expect(
        tester.widget<StreamingMarkdownWidget>(selection).content,
        messages.last.content,
      );
      await tester.longPressAt(
        tester.getTopLeft(selection) + const Offset(20, 12),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: selection, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      expect(find.byType(SelectableRegion), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'My draft');
      await tester.longPress(
        find.byKey(const ValueKey('hermes-message-actions-u')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      final draft = tester
          .widget<TextField>(find.byType(TextField))
          .controller!
          .text;
      expect(draft, contains('My draft'));
      expect(draft, contains('My draft\n\n> ${messages.first.content}'));
      // Growing replies wrap within the same maximum width. Rich blocks keep
      // their bounded layout without an intrinsic sizing pass.
      for (final reply in [
        List.filled(
          8,
          'Tell me who the website is for and what visitors need.',
        ).join(' '),
        '**Plan**\n\n- Keep the navigation clear.\n- Make the text readable.\n\n```dart\nfinal title = "A longer example for a small phone screen";\n```\n\n| Page | Purpose |\n| --- | --- |\n| Home | Introduce the website |',
      ]) {
        messageNotifier.replaceReply(reply);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final surface = tester.getRect(
          find
              .descendant(
                of: find.byKey(
                  const ValueKey('assistant-message-bubble-surface-a'),
                ),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(surface.width, lessThanOrEqualTo(390 * .88));
        expect(surface.right, lessThan(390));
      }
      expect(find.byTooltip('Switch conversation'), findsNothing);
      FocusManager.instance.primaryFocus?.unfocus();
      messageNotifier.askQuestion();
      await tester.pumpAndSettle();
      expect(find.text('Which pages should I update?'), findsOneWidget);
      final inlineField = find.byKey(const ValueKey('hermes-written-answer'));
      expect(inlineField, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ModernChatInput),
          matching: inlineField,
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('assistant-message-bubble-surface-a')),
          matching: inlineField,
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.menu_rounded), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hermes-nav-chat')));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Messages'), findsOneWidget);
      expect(find.byKey(const ValueKey('messages-tab-chats')), findsOneWidget);
      expect(
        container.read(hermesMobileNavigationProvider).conversation,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );
}
