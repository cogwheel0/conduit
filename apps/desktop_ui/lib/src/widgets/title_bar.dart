import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../desktop_shell.dart';
import '../l10n/strings.g.dart';
import '../rpc/layout_providers.dart';
import '../rpc/rpc_providers.dart';
import '../shortcuts.dart';
import 'desktop_integration.dart';
import 'ui.dart';

/// The window's own title bar (docs/desktop/REDESIGN.md).
///
/// The whole bar drags the window, and a double-click on it maximizes -- the
/// system does both for a drag region -- while its buttons stay buttons. On
/// macOS the traffic lights sit at its left, so it keeps their space clear
/// unless the window is full screen. On Windows and Linux it draws minimize, maximize and close.
///
/// With [workspace], it carries the sidebar toggle, a new chat and search:
/// the controls that belong to the window rather than to a conversation.
/// The side pane's toggle is the conversation header's, beside the pane.
class TitleBar extends StatefulComponent {
  const TitleBar({this.workspace = true, super.key});

  final bool workspace;

  @override
  State<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<TitleBar> {
  WindowFrameState _frame = const WindowFrameState();

  @override
  void initState() {
    super.initState();
    final shell = context.read(desktopShellProvider);
    if (!shell.available) return;
    shell.onWindowState((state) {
      if (mounted && state != _frame) setState(() => _frame = state);
    });
  }

  @override
  Component build(BuildContext context) {
    final bridge = context.read(shellBridgeProvider);
    final isMac = bridge.platform == 'darwin';
    final drawsControls = bridge.isElectron && !isMac;
    final shortcuts = context.watch(shortcutTableProvider);
    String? keys(ShortcutAction action) {
      for (final shortcut in shortcuts) {
        if (shortcut.action == action) {
          return describeStroke(shortcut.stroke, isMac: isMac);
        }
      }
      return null;
    }

    final layout = context.watch(workspaceLayoutProvider);
    return header(
      classes:
          'app-drag flex h-10 shrink-0 items-center gap-0.5 bg-window px-1.5 '
          '${_frame.focused ? 'text-foreground' : 'text-foreground-subtle'}',
      [
        // The traffic lights' place.
        if (isMac && bridge.isElectron && !_frame.fullscreen)
          div(classes: 'w-[70px] shrink-0', const []),
        if (component.workspace) ...[
          iconButton(
            id: 'toggle-sidebar',
            glyph: LucideIcon.panelLeft,
            label: t.desktop.desktopSidebar,
            pressed: layout.sidebarOpen,
            shortcut: keys(ShortcutAction.toggleSidebar),
            onClick: () =>
                context.read(workspaceLayoutProvider.notifier).toggleSidebar(),
          ),
          iconButton(
            id: 'title-new-chat',
            glyph: LucideIcon.squarePen,
            label: t.app.newChat,
            shortcut: keys(ShortcutAction.newChat),
            onClick: () => context
                .read(shortcutRequestsProvider)
                .request(ShortcutAction.newChat),
          ),
          iconButton(
            id: 'title-search',
            glyph: LucideIcon.search,
            label: t.desktop.desktopSearch,
            shortcut: keys(ShortcutAction.openPalette),
            onClick: () => context
                .read(shortcutRequestsProvider)
                .request(ShortcutAction.openPalette),
          ),
        ],
        div(classes: 'min-w-0 flex-1', const []),
        if (drawsControls) _windowControls(context),
      ],
    );
  }

  /// Minimize, maximize or restore, and close, at the right edge as
  /// Windows and most Linux desktops put them. Full height and flush to the
  /// corner, so the corner pixel closes the window.
  Component _windowControls(BuildContext context) {
    void control(WindowControl action) =>
        context.read(desktopShellProvider).windowControl(action);
    Component controlButton({
      required LucideIcon glyph,
      required String label,
      required void Function() onClick,
      bool close = false,
    }) => button(
      [icon(glyph, classes: 'size-4')],
      classes:
          'inline-flex h-10 w-11 items-center justify-center '
          'text-foreground-subtle transition-colors '
          '${close ? 'hover:bg-destructive hover:text-destructive-foreground' : 'hover:bg-hover hover:text-foreground'}',
      type: ButtonType.button,
      attributes: <String, String>{
        'aria-label': label,
        ...tooltipAttributes(label, side: TooltipSide.left),
      },
      onClick: onClick,
    );

    return div(classes: '-mr-1.5 ml-1 flex shrink-0 items-stretch', [
      controlButton(
        glyph: LucideIcon.minus,
        label: t.desktop.desktopMinimizeWindow,
        onClick: () => control(WindowControl.minimize),
      ),
      controlButton(
        glyph: _frame.maximized ? LucideIcon.copy : LucideIcon.square,
        label: _frame.maximized
            ? t.desktop.desktopRestoreWindow
            : t.desktop.desktopMaximizeWindow,
        onClick: () => control(WindowControl.toggleMaximize),
      ),
      controlButton(
        glyph: LucideIcon.x,
        label: t.desktop.desktopCloseWindow,
        close: true,
        onClick: () => control(WindowControl.close),
      ),
    ]);
  }
}
