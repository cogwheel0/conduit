@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/desktop_shell.dart';
import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/rpc/activity_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/layout_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/shell_bridge.dart';
import 'package:conduit_desktop_ui/src/shortcuts.dart';
import 'package:conduit_desktop_ui/src/widgets/title_bar.dart';
import 'package:conduit_desktop_ui/src/window_commands.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button;
import 'package:jaspr/jaspr.dart' show Component;
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

class _Selected extends SelectedChatId {
  _Selected(this._id);

  final String? _id;

  @override
  String? build() => _id;
}

Finder _labelled(String label) => find.byComponentPredicate(
  (component) =>
      component is button && component.attributes?['aria-label'] == label,
);

void main() {
  group('nextActivity', () {
    const none = <String, ChatActivity>{};

    test('a turn runs, then is unread if it finished elsewhere', () {
      var map = nextActivity(
        none,
        event: ConduitEvents.turnStarted,
        chatId: 'a',
        selected: 'b',
      );
      expect(map, <String, ChatActivity>{'a': ChatActivity.running});
      map = nextActivity(
        map,
        event: ConduitEvents.turnCompleted,
        chatId: 'a',
        selected: 'b',
      );
      expect(map, <String, ChatActivity>{'a': ChatActivity.unread});
    });

    test('an answer finishing on screen leaves no dot', () {
      final map = nextActivity(
        const <String, ChatActivity>{'a': ChatActivity.running},
        event: ConduitEvents.turnCompleted,
        chatId: 'a',
        selected: 'a',
      );
      expect(map, isEmpty);
    });

    test('a failure elsewhere says so', () {
      expect(
        nextActivity(
          none,
          event: ConduitEvents.turnFailed,
          chatId: 'a',
          selected: null,
        ),
        <String, ChatActivity>{'a': ChatActivity.failed},
      );
    });

    test('a stream of deltas is one change, not sixty', () {
      final running = nextActivity(
        none,
        event: ConduitEvents.turnDelta,
        chatId: 'a',
        selected: null,
      );
      expect(
        nextActivity(
          running,
          event: ConduitEvents.turnDelta,
          chatId: 'a',
          selected: null,
        ),
        same(running),
      );
    });

    test('other events leave the map alone', () {
      final map = <String, ChatActivity>{'a': ChatActivity.unread};
      expect(
        nextActivity(
          map,
          event: ConduitEvents.chatsChanged,
          chatId: 'a',
          selected: null,
        ),
        same(map),
      );
    });
  });

  group('workspace layout', () {
    late RecordingWindowCommands commands;
    late ProviderContainer container;

    setUp(() {
      commands = RecordingWindowCommands();
      container = ProviderContainer(
        overrides: [windowCommandsProvider.overrideWithValue(commands)],
      );
      addTearDown(container.dispose);
    });

    test('widths are held to their bounds and kept by the window', () {
      final notifier = container.read(workspaceLayoutProvider.notifier);
      notifier.setSidebarWidth(9999);
      expect(
        container.read(workspaceLayoutProvider).sidebarWidth,
        WorkspaceLayout.sidebarWidths.max,
      );
      notifier
        ..setSidePaneWidth(10)
        ..toggleSidebar();

      // A new window reads back what the last one kept.
      final next = ProviderContainer(
        overrides: [windowCommandsProvider.overrideWithValue(commands)],
      );
      addTearDown(next.dispose);
      final layout = next.read(workspaceLayoutProvider);
      expect(layout.sidebarOpen, isFalse);
      expect(layout.sidebarWidth, WorkspaceLayout.sidebarWidths.max);
      expect(layout.sidePaneWidth, WorkspaceLayout.sidePaneWidths.min);
    });

    test('a damaged stored layout falls back to the defaults', () {
      commands.store(WorkspaceLayoutNotifier.storageKey, '{not json');
      final layout = container.read(workspaceLayoutProvider);
      expect(layout.sidebarOpen, isTrue);
      expect(layout.sidebarWidth, WorkspaceLayout.defaultSidebarWidth);
    });

    test('folded sections are remembered', () {
      container.read(collapsedSectionsProvider.notifier)
        ..toggle('earlier')
        ..toggle('pinned')
        ..toggle('pinned');
      expect(container.read(collapsedSectionsProvider), <String>{'earlier'});
      expect(commands.stored(CollapsedSections.storageKey), 'earlier');
    });
  });

  group('title bar', () {
    late RecordingDesktopShell shell;
    late RecordingWindowCommands commands;
    late ShortcutRequests requests;

    Component bar({String platform = 'linux', String? selected}) =>
        ProviderScope(
          overrides: [
            desktopShellProvider.overrideWithValue(shell),
            windowCommandsProvider.overrideWithValue(commands),
            shellBridgeProvider.overrideWithValue(
              ShellBridge(
                rpcPort: 1,
                token: 'test',
                platform: platform,
                windowKind: WindowKind.main,
                isElectron: true,
              ),
            ),
            selectedChatIdProvider.overrideWith(() => _Selected(selected)),
            shortcutRequestsProvider.overrideWithValue(requests),
          ],
          child: const TitleBar(),
        );

    setUp(() {
      shell = RecordingDesktopShell(available: true);
      commands = RecordingWindowCommands();
      requests = ShortcutRequests();
    });

    testComponents('draws window controls on Linux, which call the shell', (
      tester,
    ) async {
      tester.pumpComponent(bar());
      await pumpEventQueue();
      await tester.click(_labelled(t.desktop.desktopMinimizeWindow));
      await tester.click(_labelled(t.desktop.desktopMaximizeWindow));
      await tester.click(_labelled(t.desktop.desktopCloseWindow));
      expect(shell.controls, <WindowControl>[
        WindowControl.minimize,
        WindowControl.toggleMaximize,
        WindowControl.close,
      ]);
    });

    testComponents('a maximized window offers to restore', (tester) async {
      tester.pumpComponent(bar());
      await pumpEventQueue();
      shell.stateHandler!(const WindowFrameState(maximized: true));
      await pumpEventQueue();
      expect(_labelled(t.desktop.desktopRestoreWindow), findsOneComponent);
      expect(_labelled(t.desktop.desktopMaximizeWindow), findsNothing);
    });

    testComponents('leaves the window controls to macOS', (tester) async {
      tester.pumpComponent(bar(platform: 'darwin'));
      await pumpEventQueue();
      expect(_labelled(t.desktop.desktopCloseWindow), findsNothing);
      expect(_labelled(t.desktop.desktopSidebar), findsOneComponent);
    });

    testComponents('the sidebar button toggles the sidebar', (tester) async {
      tester.pumpComponent(bar());
      await pumpEventQueue();
      await tester.click(_labelled(t.desktop.desktopSidebar));
      expect(
        commands.stored(WorkspaceLayoutNotifier.storageKey),
        contains('"sidebarOpen":false'),
      );
    });

    testComponents('search asks for the palette, as its shortcut does', (
      tester,
    ) async {
      final asked = <ShortcutAction>[];
      tester.pumpComponent(bar());
      await pumpEventQueue();
      final subscription = requests.stream.listen(asked.add);
      addTearDown(subscription.cancel);
      await tester.click(_labelled(t.desktop.desktopSearch));
      expect(asked, <ShortcutAction>[ShortcutAction.openPalette]);
    });
  });
}
