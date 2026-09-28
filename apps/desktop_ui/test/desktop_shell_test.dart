@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_desktop_ui/src/desktop_shell.dart';
import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/desktop_settings_tab.dart';
import 'package:conduit_desktop_ui/src/pages/keyboard_settings_tab.dart';
import 'package:conduit_desktop_ui/src/pages/quick_ask_page.dart';
import 'package:conduit_desktop_ui/src/pages/workspace/workspace_common.dart';
import 'package:conduit_desktop_ui/src/rpc/channels_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/session_providers.dart';
import 'package:conduit_desktop_ui/src/shell_bridge.dart';
import 'package:conduit_desktop_ui/src/widgets/desktop_integration.dart';
import 'package:conduit_desktop_ui/src/widgets/release_banner.dart';
import 'package:conduit_desktop_ui/src/window_commands.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

class _Chats extends ChatActions {
  _Chats(super.ref);

  final List<String?> selected = <String?>[];
  final List<String> sent = <String>[];

  @override
  void select(String? chatId) => selected.add(chatId);

  @override
  Future<SendTurnAccepted> send({
    required String text,
    String? model,
    List<String> fileIds = const <String>[],
    List<String> toolIds = const <String>[],
    List<KnowledgeSummary> knowledge = const <KnowledgeSummary>[],
    bool webSearch = false,
    bool imageGeneration = false,
  }) async {
    sent.add(text);
    return const SendTurnAccepted(
      chatId: 'quick-1',
      userMessageId: 'u1',
      assistantMessageId: 'a1',
    );
  }
}

dynamic _input(String id) => find
    .byComponentPredicate((c) => c is input && c.id == id)
    .evaluate()
    .first
    .component;

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await pumpEventQueue();
  }
}

void main() {
  late RecordingDesktopShell shell;
  late _Chats chats;
  late List<String> went;
  late StreamController<LiveTurn?> turns;
  late StreamController<ChannelList> channels;

  Component scoped(
    Component child, {
    bool signedIn = true,
    String version = '0.1.0',
  }) {
    shell = RecordingDesktopShell(available: true);
    went = <String>[];
    turns = StreamController<LiveTurn?>.broadcast();
    channels = StreamController<ChannelList>.broadcast();
    addTearDown(() async {
      await turns.close();
      await channels.close();
    });
    return ProviderScope(
      overrides: [
        desktopShellProvider.overrideWithValue(shell),
        shellBridgeProvider.overrideWithValue(
          ShellBridge(
            rpcPort: 1,
            token: 'test',
            platform: 'linux',
            windowKind: WindowKind.main,
            isElectron: true,
            appVersion: version,
          ),
        ),
        chatActionsProvider.overrideWith((ref) => chats = _Chats(ref)),
        workspaceNavigateProvider.overrideWithValue(
          (context, to, {replace = false}) => went.add(to),
        ),
        liveTurnProvider.overrideWith((ref) => turns.stream),
        channelListProvider.overrideWith((ref) => channels.stream.first),
        chatListProvider.overrideWith(
          (ref) async => const ChatList(
            chats: <ChatSummary>[
              ChatSummary(id: 'c1', title: 'Trip plans', updatedAtMs: 1),
            ],
          ),
        ),
        authStatusProvider.overrideWith(
          (ref) async => signedIn
              ? const AuthSnapshot(
                  phase: AuthPhase.authenticated,
                  isAuthenticated: true,
                )
              : const AuthSnapshot(phase: AuthPhase.unauthenticated),
        ),
        directOnlyProvider.overrideWithValue(const AsyncData(false)),
        windowCommandsProvider.overrideWithValue(RecordingWindowCommands()),
      ],
      child: child,
    );
  }

  group('DesktopIntegration', () {
    testComponents('opens what a link or notification asks for', (
      tester,
    ) async {
      tester.pumpComponent(scoped(const DesktopIntegration()));
      await _settle();
      shell.open(const OpenRequest.chat('c9'));
      expect(chats.selected, ['c9']);
      expect(went, ['/']);
      shell.open(const OpenRequest('settings', tab: 'audio'));
      shell.open(const OpenRequest('channel', id: 'general'));
      shell.open(const OpenRequest('note', id: 'n1'));
      expect(went.skip(1), [
        '/settings/audio',
        '/channels/general',
        '/notes/n1',
      ]);
    });

    testComponents('a new chat link fills the composer', (tester) async {
      late ProviderContainer container;
      tester.pumpComponent(
        scoped(
          Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return const DesktopIntegration();
            },
          ),
        ),
      );
      await _settle();
      shell.open(const OpenRequest.newChat(text: 'Plan a trip'));
      expect(chats.selected, [null]);
      expect(container.read(composerPrefillProvider)?.text, 'Plan a trip');
    });

    testComponents('files opened with Conduit start a chat with them', (
      tester,
    ) async {
      late ProviderContainer container;
      tester.pumpComponent(
        scoped(
          Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return const DesktopIntegration();
            },
          ),
        ),
      );
      await _settle();
      final request = OpenRequest.fromJson(<String, dynamic>{
        'kind': 'newChat',
        'files': [
          {
            'id': 'f1',
            'name': 'notes.md',
            'size': 4,
            'contentType': 'text/markdown',
          },
        ],
      })!;
      shell.open(request);
      expect(chats.selected, [null]);
      expect(went, ['/']);
      final draft = container.read(composerPrefillProvider)!;
      expect(draft.text, isNull);
      expect(draft.files.single.name, 'notes.md');
    });

    testComponents('an answer out of sight is a notification', (tester) async {
      tester.pumpComponent(scoped(const DesktopIntegration()));
      await _settle();
      shell.focused = false;
      turns.add(const LiveTurn(chatId: 'c1', messageId: 'm1', text: 'Half an'));
      await _settle();
      expect(shell.notified, isEmpty, reason: 'still streaming');
      turns.add(
        const LiveTurn(
          chatId: 'c1',
          messageId: 'm1',
          text: '**Lisbon** in May.',
          settled: true,
        ),
      );
      await _settle();
      expect(shell.notified.single.title, 'Trip plans');
      expect(shell.notified.single.body, 'Lisbon in May.');
      expect(shell.notified.single.open, const OpenRequest.chat('c1'));
    });

    testComponents('not while the window has focus, or when turned off', (
      tester,
    ) async {
      tester.pumpComponent(scoped(const DesktopIntegration()));
      await _settle();
      turns.add(
        const LiveTurn(
          chatId: 'c1',
          messageId: 'm1',
          text: 'Hi',
          settled: true,
        ),
      );
      await _settle();
      expect(shell.notified, isEmpty);
      shell
        ..focused = false
        ..current = const ShellSettings(notifyAnswers: false);
      turns.add(
        const LiveTurn(
          chatId: 'c1',
          messageId: 'm2',
          text: 'Hi',
          settled: true,
        ),
      );
      await _settle();
      expect(shell.notified, isEmpty);
    });
  });

  group('Settings → Desktop', () {
    testComponents('each setting goes to the shell', (tester) async {
      tester.pumpComponent(scoped(const DesktopSettingsTab()));
      await _settle();
      _input('shell-close-to-tray').onChange(true);
      await _settle();
      expect(shell.patches.last, {'closeToTray': true});
      _input('shell-quick-ask-shortcut').onInput('Alt+');
      await _settle();
      expect(
        find.text(t.desktop.desktopQuickAskShortcutInvalid),
        findsOneComponent,
      );
      expect(shell.patches, hasLength(1));
      _input('shell-quick-ask-shortcut').onInput('Alt+K');
      await _settle();
      expect(shell.patches.last, {'quickAskShortcut': 'Alt+K'});
    });

    testComponents('says when another app holds the shortcut', (tester) async {
      tester.pumpComponent(scoped(const DesktopSettingsTab()));
      await _settle();
      expect(
        find.text(t.desktop.desktopQuickAskShortcutTaken),
        findsOneComponent,
      );
    });
  });

  group('QuickAskPage', () {
    Finder byId(String id) =>
        find.byComponentPredicate((c) => c is DomComponent && c.id == id);

    testComponents('asks in a new chat and continues in the main window', (
      tester,
    ) async {
      tester.pumpComponent(scoped(const QuickAskPage()));
      await _settle();
      (find
                  .byComponentPredicate(
                    (c) => c is textarea && c.id == 'quick-ask',
                  )
                  .evaluate()
                  .first
                  .component
              as textarea)
          .onInput!('What is the capital of Portugal?');
      await _settle();
      await tester.click(byId('quick-ask-send'));
      await _settle();
      expect(chats.selected, [null], reason: 'a conversation of its own');
      expect(chats.sent, ['What is the capital of Portugal?']);
      turns.add(
        const LiveTurn(chatId: 'quick-1', messageId: 'a1', text: 'Lisbon.'),
      );
      await _settle();
      expect(find.text('Lisbon.'), findsOneComponent);

      await tester.click(byId('quick-ask-continue'));
      await _settle();
      expect(shell.openedInMain, [const OpenRequest.chat('quick-1')]);
      expect(byId('quick-ask-continue'), findsNothing);
    });

    testComponents('says to finish setting up first', (tester) async {
      tester.pumpComponent(scoped(const QuickAskPage(), signedIn: false));
      await _settle();
      expect(find.text(t.desktop.desktopQuickAskNeedsSetup), findsOneComponent);
    });
  });

  group('Settings → Keyboard', () {
    testComponents('shows the keys the user chose, and resets them', (
      tester,
    ) async {
      final component = scoped(const KeyboardSettingsTab());
      shell.current = const ShellSettings(
        shortcuts: <String, String>{'newChat': 'mod+n'},
      );
      tester.pumpComponent(component);
      await _settle();
      expect(find.text('Ctrl+N'), findsOneComponent);
      await tester.click(
        find.componentWithText(button, t.desktop.desktopShortcutReset),
      );
      await _settle();
      expect(shell.patches.last, {'shortcuts': <String, String>{}});
    });
  });

  group("What's new", () {
    test('versions compare as releases do', () {
      expect(isNewerVersion('0.2.0', '0.1.9'), isTrue);
      expect(isNewerVersion('0.10.0', '0.9.0'), isTrue);
      expect(isNewerVersion('0.2.0', '0.2.0'), isFalse);
      expect(isNewerVersion('0.2.0-alpha.2', '0.2.0-alpha.1'), isTrue);
      expect(isNewerVersion('0.2.0', '0.2.0-alpha.1'), isTrue);
      expect(isNewerVersion('0.1.0', '0.2.0'), isFalse);
    });

    testComponents('a first run only remembers the version', (tester) async {
      tester.pumpComponent(scoped(const ReleaseBanner(), version: '0.2.0'));
      await _settle();
      expect(find.text(t.app.releaseNotesTitle), findsNothing);
      expect(shell.patches.single, {'lastSeenVersion': '0.2.0'});
    });

    testComponents('after an update it says so, until dismissed', (
      tester,
    ) async {
      final component = scoped(const ReleaseBanner(), version: '0.2.1');
      shell.current = const ShellSettings(lastSeenVersion: '0.1.0');
      tester.pumpComponent(component);
      await _settle();
      expect(
        find.text(t.app.releaseNotesAnnouncementTitle(version: '0.2')),
        findsOneComponent,
      );
      await tester.click(
        find.byComponentPredicate(
          (c) =>
              c is button &&
              c.attributes?['aria-label'] == t.desktop.desktopReleaseDismiss,
        ),
      );
      await _settle();
      expect(shell.patches.last, {'lastSeenVersion': '0.2.1'});
      expect(
        find.text(t.app.releaseNotesAnnouncementTitle(version: '0.2')),
        findsNothing,
      );
    });
  });
}
