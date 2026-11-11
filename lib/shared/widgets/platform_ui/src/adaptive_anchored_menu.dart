import 'dart:async';

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/widgets.dart';

import 'platform_ui_capabilities.dart';

/// A row of an [AdaptiveAnchoredMenu].
@immutable
class AdaptiveAnchoredMenuItem {
  const AdaptiveAnchoredMenuItem({
    required this.id,
    required this.label,
    this.subtitle,
    this.sfSymbol,
    this.checked = false,
    this.startsSection = false,
  });

  /// Returned by [AdaptiveAnchoredMenu.show] when the row is chosen.
  final String id;

  final String label;

  /// A second line under [label].
  final String? subtitle;

  /// An SF Symbol shown with the label.
  final String? sfSymbol;

  /// Whether the row carries the system checkmark, for the current choice.
  final bool checked;

  /// Whether a divider separates this row from the ones above it.
  final bool startsSection;
}

/// The system pull-down menu of iOS 26 and later, opened from code under a
/// control that keeps its own look, as a toolbar button's menu opens.
///
/// Only iOS 26 and later show it: check [canShow] first and keep the
/// control's own path elsewhere.
abstract final class AdaptiveAnchoredMenu {
  /// Whether [show] can open the menu under [anchorContext]'s widget: iOS 26
  /// or later, with that widget laid out.
  static bool canShow(BuildContext anchorContext) =>
      PlatformUiCapabilities.usesNativeIOS26 &&
      _anchorRect(anchorContext) != null;

  /// Opens [items] as a native menu growing out of the bottom of
  /// [anchorContext]'s widget, and returns the id of the chosen row, or null
  /// when the menu closed without a choice.
  static Future<String?> show({
    required BuildContext anchorContext,
    required List<AdaptiveAnchoredMenuItem> items,
  }) async {
    final overlay = Overlay.maybeOf(anchorContext, rootOverlay: true);
    if (items.isEmpty || overlay == null) return null;

    // The package reports the path of the chosen entry, its dividers counted.
    final entries = <CNPopupMenuEntry>[];
    final idAtEntry = <int, String>{};
    for (final item in items) {
      if (item.startsSection && entries.isNotEmpty) {
        entries.add(const CNPopupMenuDivider());
      }
      idAtEntry[entries.length] = item.id;
      entries.add(
        CNPopupMenuItem(
          label: item.label,
          subtitle: item.subtitle?.isNotEmpty == true ? item.subtitle : null,
          icon: item.sfSymbol == null ? null : CNSymbol(item.sfSymbol!),
          checked: item.checked,
        ),
      );
    }

    // The package opens a menu from code only through a context menu region's
    // state. The region is an invisible, inert overlay entry that exists only
    // while the menu is up; the anchor keeps its own look and gestures.
    final regionKey = GlobalKey<CNContextMenuState>();
    List<int>? chosenPath;
    final region = OverlayEntry(
      builder: (_) => ExcludeSemantics(
        child: IgnorePointer(
          child: CNContextMenu(
            key: regionKey,
            items: entries,
            enableHapticFeedback: false,
            onSelected: (path) => chosenPath = path,
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    overlay.insert(region);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final state = regionKey.currentState;
      // Read after the frame, so the anchor has its settled size.
      final rect = anchorContext.mounted ? _anchorRect(anchorContext) : null;
      if (state == null || rect == null) return null;
      await state.showMenu(globalPosition: rect.bottomCenter);
    } finally {
      region.remove();
      region.dispose();
    }
    final path = chosenPath;
    if (path == null || path.isEmpty) return null;
    return idAtEntry[path.first];
  }

  static Rect? _anchorRect(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}
