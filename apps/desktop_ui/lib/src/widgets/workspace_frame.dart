import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../keyboard.dart';
import '../l10n/strings.g.dart';
import '../rpc/layout_providers.dart';
import '../rpc/rpc_providers.dart';
import 'sidebar.dart';

/// A layout frame: its own background and border, with `lg` corners.
///
/// Frames are the workspace's structure, not content, so they do not count
/// toward the radius nesting inside them.
const String frameClasses =
    'flex min-h-0 min-w-0 flex-col overflow-hidden rounded-lg border '
    'border-border bg-panel';

/// The workspace: the sidebar on the window, then [child] -- a route's
/// frames -- with a 4 px gap between them that is also the handle that
/// resizes the sidebar.
///
/// The sidebar stays mounted when hidden, so its scroll position, open
/// folders and activity survive a toggle.
class Workspace extends StatelessComponent {
  const Workspace({required this.child, super.key});

  final Component child;

  @override
  Component build(BuildContext context) {
    final layout = context.watch(workspaceLayoutProvider);
    final notifier = context.read(workspaceLayoutProvider.notifier);
    return div(classes: 'flex min-h-0 flex-1 px-1 pb-1', [
      div(
        id: 'sidebar-column',
        classes: layout.sidebarOpen ? 'flex min-h-0 shrink-0' : 'hidden',
        styles: Styles(
          raw: <String, String>{'width': '${layout.sidebarWidth}px'},
        ),
        [const Sidebar()],
      ),
      if (layout.sidebarOpen)
        ResizeHandle(
          id: 'resize-sidebar',
          label: t.desktop.desktopResizeSidebar,
          value: layout.sidebarWidth,
          min: WorkspaceLayout.sidebarWidths.min,
          max: WorkspaceLayout.sidebarWidths.max,
          onResize: notifier.setSidebarWidth,
        ),
      div(classes: 'flex min-h-0 min-w-0 flex-1', [child]),
    ]);
  }
}

/// The gap between two frames, which resizes the one on its [growsLeft]
/// side.
///
/// A 4 px hit area showing a 2 px line on hover, focus or drag. It is a
/// focusable `separator` with its value, so the arrow keys resize it too
/// and a screen reader says what it is and where it stands.
class ResizeHandle extends StatefulComponent {
  const ResizeHandle({
    required this.id,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onResize,
    this.growsLeft = true,
    this.horizontal = false,
    super.key,
  });

  final String id;
  final String label;

  /// The width of the frame it resizes.
  final double value;
  final double min;
  final double max;
  final void Function(double width) onResize;

  /// Whether the frame it resizes is on its left: the sidebar's handle.
  /// The side pane's is on the pane's left, and the pane grows as it moves
  /// left.
  final bool growsLeft;

  /// Between frames stacked one above the other: it moves up and down, and
  /// the frame it resizes is below it.
  final bool horizontal;

  @override
  State<ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<ResizeHandle> {
  bool _dragging = false;

  @override
  Component build(BuildContext context) {
    final horizontal = component.horizontal;
    // A horizontal handle resizes the frame below it, which grows upward.
    final sign = horizontal ? -1 : (component.growsLeft ? 1 : -1);
    return div(
      id: component.id,
      classes:
          'group relative shrink-0 outline-none focus-visible:outline-none '
          '${horizontal ? 'h-1 cursor-row-resize' : 'w-1 cursor-col-resize'}',
      attributes: <String, String>{
        'role': 'separator',
        'aria-orientation': horizontal ? 'horizontal' : 'vertical',
        'aria-label': component.label,
        'aria-valuenow': '${component.value.round()}',
        'aria-valuemin': '${component.min.round()}',
        'aria-valuemax': '${component.max.round()}',
        'tabindex': '0',
      },
      events: <String, EventCallback>{
        'pointerdown': (event) {
          event.preventDefault();
          final start = horizontal ? pointerY(event) : pointerX(event);
          final startSize = component.value;
          setState(() => _dragging = true);
          context
              .read(windowCommandsProvider)
              .trackPointer(
                cursor: horizontal ? 'row-resize' : 'col-resize',
                onMove: (x, y) => component.onResize(
                  startSize + sign * ((horizontal ? y : x) - start),
                ),
                onEnd: () {
                  if (mounted) setState(() => _dragging = false);
                },
              );
        },
        'keydown': resizeKeys(
          (delta) => component.onResize(component.value + sign * delta),
          horizontal: horizontal,
        ),
      },
      [
        // The line, inset from the frames' rounded ends.
        span(
          classes:
              'pointer-events-none absolute rounded-full transition-colors '
              '${horizontal ? 'inset-x-2 top-[1px] h-0.5' : 'inset-y-2 left-[1px] w-0.5'} '
              '${_dragging ? 'bg-foreground-subtlest' : 'bg-transparent group-hover:bg-foreground-subtlest/50 group-focus-visible:bg-foreground-subtlest'}',
          const [],
        ),
      ],
    );
  }
}
