import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/widgets.dart';

import 'adaptive_controls.dart'
    show
        AdaptivePopupMenuDivider,
        AdaptivePopupMenuEntry,
        AdaptivePopupMenuItem;

/// An item of an [AdaptiveBottomToolbar].
///
/// [id] keeps the native item across rebuilds, so a change of label, symbol
/// or state updates it in place. Ids are unique within a toolbar.
sealed class AdaptiveBottomToolbarItem {
  const AdaptiveBottomToolbarItem({required this.id});

  final String id;

  CNToolbarItem _toNative();
}

/// A toolbar button showing an SF Symbol. [label] is what VoiceOver reads.
final class AdaptiveBottomToolbarButton extends AdaptiveBottomToolbarItem {
  const AdaptiveBottomToolbarButton({
    required super.id,
    required this.label,
    required this.sfSymbol,
    required this.onPressed,
    this.prominent = false,
    this.tint,
  });

  final String label;
  final String sfSymbol;

  /// Null disables the button.
  final VoidCallback? onPressed;

  /// Draws the button tinted with [tint], for an action under way such as a
  /// recording to stop.
  final bool prominent;
  final Color? tint;

  @override
  CNToolbarItem _toNative() => CNToolbarButton(
    id: id,
    label: label,
    icon: CNSymbol(sfSymbol),
    enabled: onPressed != null,
    style: prominent ? CNToolbarItemStyle.prominent : CNToolbarItemStyle.plain,
    tint: tint,
    onPressed: onPressed,
  );
}

/// A toolbar button that opens a menu of [items]: [AdaptivePopupMenuItem]s
/// carrying values of type [T], and [AdaptivePopupMenuDivider]s. Choosing an
/// enabled item calls [onSelected] with its value.
final class AdaptiveBottomToolbarMenu<T> extends AdaptiveBottomToolbarItem {
  const AdaptiveBottomToolbarMenu({
    required super.id,
    required this.label,
    required this.sfSymbol,
    required this.items,
    required this.onSelected,
    this.enabled = true,
  });

  final String label;
  final String sfSymbol;
  final List<AdaptivePopupMenuEntry> items;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  CNToolbarItem _toNative() => CNToolbarMenu(
    id: id,
    label: label,
    icon: CNSymbol(sfSymbol),
    enabled: enabled,
    items: [
      for (final entry in items)
        if (entry is AdaptivePopupMenuItem<T>)
          CNPopupMenuItem(
            label: entry.label,
            subtitle: entry.subtitle?.isNotEmpty == true
                ? entry.subtitle
                : null,
            icon: entry.icon is String ? CNSymbol(entry.icon as String) : null,
            customIcon: entry.icon is IconData ? entry.icon as IconData : null,
            enabled: entry.enabled,
            checked: entry.checked,
            isDestructive: entry.isDestructive,
          )
        else
          // Every entry keeps its slot: the menu reports chosen entries by
          // their index in [items].
          const CNPopupMenuDivider(),
    ],
    onSelected: _select,
  );

  void _select(List<int> path) {
    if (!enabled || path.isEmpty) return;
    final index = path.first;
    if (index < 0 || index >= items.length) return;
    final entry = items[index];
    if (entry is! AdaptivePopupMenuItem<T> || !entry.enabled) return;
    final value = entry.value;
    if (value is T) onSelected(value);
  }
}

/// Space between toolbar items. On iOS 26 a space also ends one shared
/// Liquid Glass background, so the items on either side form two groups.
final class AdaptiveBottomToolbarSpace extends AdaptiveBottomToolbarItem {
  /// Takes the room left, pushing the items after it to the trailing edge.
  const AdaptiveBottomToolbarSpace.flexible({required super.id})
    : flexible = true;

  /// A standard gap.
  const AdaptiveBottomToolbarSpace.fixed({required super.id})
    : flexible = false;

  final bool flexible;

  @override
  CNToolbarItem _toNative() =>
      flexible ? CNToolbarSpace.flexible(id: id) : CNToolbarSpace.fixed(id: id);
}

/// The iOS 26 bottom toolbar: a native `UIToolbar` with Liquid Glass, laid
/// out where this widget is placed, [height] points high. Put it inside the
/// bottom safe area.
///
/// Callers show it when [PlatformUiCapabilities.usesNativeIOS26] is true and
/// keep their own controls elsewhere; on other platforms the package draws a
/// plain Flutter toolbar.
class AdaptiveBottomToolbar extends StatelessWidget {
  const AdaptiveBottomToolbar({super.key, required this.items, this.tint});

  /// Height of the toolbar.
  static const double height = 44;

  /// The items, from the leading edge to the trailing one.
  final List<AdaptiveBottomToolbarItem> items;

  /// Colour of the items' symbols.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return CNToolbar(
      items: [for (final item in items) item._toNative()],
      tint: tint,
    );
  }
}
