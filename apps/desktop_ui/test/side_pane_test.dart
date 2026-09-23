@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/layout_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/notes_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/session_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/terminal_providers.dart';
import 'package:conduit_desktop_ui/src/widgets/side_pane.dart';
import 'package:conduit_desktop_ui/src/window_commands.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button;
import 'package:jaspr/jaspr.dart' show Component, DomComponent;
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

ChatMessageDto _answer(String content, {List<ChatSourceDto>? sources}) =>
    ChatMessageDto(
      id: 'm${content.hashCode}',
      role: 'assistant',
      content: content,
      timestampMs: 1,
      sources: sources ?? const <ChatSourceDto>[],
    );

final Finder _tabs = find.byComponentPredicate(
  (component) => component is button && component.attributes?['role'] == 'tab',
  description: 'tab',
);

void main() {
  group('conversationSources', () {
    test('each source once, in the order first cited', () {
      const a = ChatSourceDto(label: 'A', url: 'https://a.example');
      const b = ChatSourceDto(label: 'B');
      final sources = conversationSources(<ChatMessageDto>[
        _answer('one', sources: const <ChatSourceDto>[a, b]),
        _answer('two', sources: const <ChatSourceDto>[b, a]),
      ]);
      expect(sources, <ChatSourceDto>[a, b]);
    });
  });

  group('previewablePages', () {
    test('only fenced HTML from answers, oldest first', () {
      final pages = previewablePages(<ChatMessageDto>[
        _answer('```html\n<p>first</p>\n```'),
        const ChatMessageDto(
          id: 'q',
          role: 'user',
          content: '```html\n<p>asked</p>\n```',
          timestampMs: 1,
        ),
        _answer('```dart\nfinal x = 1;\n```\n```html\n<p>second</p>\n```'),
      ]);
      expect(pages, <String>['<p>first</p>\n', '<p>second</p>\n']);
    });
  });

  group('SidePane', () {
    Component pane({
      bool signedIn = false,
      bool controls = true,
      List<ChatMessageDto> messages = const <ChatMessageDto>[],
      RecordingWindowCommands? commands,
    }) => ProviderScope(
      overrides: [
        windowCommandsProvider.overrideWithValue(
          commands ?? RecordingWindowCommands(),
        ),
        terminalServersProvider.overrideWith(
          (ref) async => const TerminalServers(),
        ),
        authStatusProvider.overrideWith(
          (ref) async => signedIn
              ? const AuthSnapshot(
                  phase: AuthPhase.authenticated,
                  isAuthenticated: true,
                )
              : const AuthSnapshot(phase: AuthPhase.unauthenticated),
        ),
        noteListProvider.overrideWith((ref) async => const NoteList()),
        chatTreeProvider.overrideWith((ref) async => null),
      ],
      child: SidePane(
        chatId: 'c1',
        controls: controls,
        detail: ChatDetail(
          summary: const ChatSummary(id: 'c1', title: 'T', updatedAtMs: 1),
          messages: messages,
        ),
      ),
    );

    testComponents('offers only the tabs that can do something', (
      tester,
    ) async {
      tester.pumpComponent(pane());
      await pumpEventQueue();
      expect(find.text(t.desktop.desktopControls), findsOneComponent);
      expect(find.text(t.desktop.desktopPreview), findsOneComponent);
      // No terminal server, and no account for notes.
      expect(find.text(t.app.terminal), findsNothing);
      expect(find.text(t.app.notes), findsNothing);
      expect(_tabs, findsNComponents(2));

      tester.pumpComponent(pane(signedIn: true));
      await pumpEventQueue();
      expect(find.text(t.app.notes), findsOneComponent);
    });

    testComponents('the preview tab renders a page, sandboxed, and is kept', (
      tester,
    ) async {
      final commands = RecordingWindowCommands();
      tester.pumpComponent(
        pane(
          commands: commands,
          messages: <ChatMessageDto>[_answer('```html\n<p>hi</p>\n```')],
        ),
      );
      await pumpEventQueue();
      await tester.click(
        find.componentWithText(button, t.desktop.desktopPreview),
      );
      await pumpEventQueue();

      // Every restriction: an empty sandbox, not an absent one.
      expect(
        find.byComponentPredicate(
          (component) =>
              component is DomComponent &&
              component.tag == 'iframe' &&
              component.attributes?['sandbox'] == '' &&
              component.attributes?['srcdoc'] == '<p>hi</p>\n',
        ),
        findsOneComponent,
      );
      expect(
        commands.stored(WorkspaceLayoutNotifier.storageKey),
        contains('"sidePaneTab":"preview"'),
      );
    });

    testComponents('a conversation kept here has no controls tab', (
      tester,
    ) async {
      tester.pumpComponent(pane(controls: false));
      await pumpEventQueue();
      expect(find.text(t.desktop.desktopControls), findsNothing);
      // The first tab there is, open.
      expect(find.text(t.desktop.desktopNoPreview), findsOneComponent);
    });

    testComponents('with no pages, the preview says why it is empty', (
      tester,
    ) async {
      tester.pumpComponent(pane());
      await pumpEventQueue();
      await tester.click(
        find.componentWithText(button, t.desktop.desktopPreview),
      );
      await pumpEventQueue();
      expect(find.text(t.desktop.desktopNoPreview), findsOneComponent);
    });
  });
}
