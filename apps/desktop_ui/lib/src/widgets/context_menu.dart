import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../keyboard.dart';
import '../rpc/rpc_providers.dart';
import 'ui.dart';

/// One entry in a [ContextMenu].
class ContextMenuItem {
  const ContextMenuItem(this.label, this.onSelect, {this.destructive = false});

  final String label;
  final void Function() onSelect;
  final bool destructive;
}

/// A right-click menu (WP-3.1).
///
/// Everything it offers is also reachable without it -- the hover actions,
/// the header -- because a context menu is where a mouse user looks first
/// and a keyboard user never does. It takes focus when it opens, so Tab and
/// Enter work inside it, and Esc or a click anywhere else closes it.
class ContextMenu extends StatefulComponent {
  const ContextMenu({
    required this.x,
    required this.y,
    required this.items,
    required this.onClose,
    this.label,
    super.key,
  });

  /// Where the pointer was, in viewport pixels.
  final double x;
  final double y;
  final List<ContextMenuItem> items;
  final void Function() onClose;
  final String? label;

  @override
  State<ContextMenu> createState() => _ContextMenuState();
}

class _ContextMenuState extends State<ContextMenu> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      if (mounted) context.read(windowCommandsProvider).focus('context-menu-0');
    });
  }

  @override
  Component build(BuildContext context) => div(
    classes: 'fixed inset-0 z-50',
    events: <String, EventCallback>{
      'click': (_) => component.onClose(),
      // A second right-click elsewhere closes this one rather than
      // stacking another on top.
      'contextmenu': suppressContextMenu(component.onClose),
    },
    [
      div(
        classes: 'fixed z-50 $menuClasses',
        styles: Styles(
          raw: <String, String>{
            'left': '${component.x}px',
            'top': '${component.y}px',
          },
        ),
        attributes: <String, String>{
          'role': 'menu',
          'aria-label': ?component.label,
        },
        events: <String, EventCallback>{
          'click': (event) => event.stopPropagation(),
          'keydown': submitOrCancel(submit: () {}, cancel: component.onClose),
        },
        [
          for (var i = 0; i < component.items.length; i++)
            button(
              [Component.text(component.items[i].label)],
              id: 'context-menu-$i',
              classes: menuItemClasses(
                destructive: component.items[i].destructive,
              ),
              type: ButtonType.button,
              attributes: const <String, String>{'role': 'menuitem'},
              onClick: () {
                component.onClose();
                component.items[i].onSelect();
              },
            ),
        ],
      ),
    ],
  );
}
