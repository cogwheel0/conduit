import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/widgets.dart';

import 'platform_ui_capabilities.dart';

/// A row of an [AdaptiveInfoPopover]: a label, with its value at the
/// trailing end.
@immutable
class AdaptiveInfoPopoverRow {
  const AdaptiveInfoPopoverRow({
    required this.label,
    required this.value,
    this.detail,
    this.symbol,
  });

  final String label;
  final String value;

  /// A smaller second line under [label].
  final String? detail;

  /// The name of an SF Symbol before [label], which VoiceOver skips. Once
  /// one row has a symbol, every row's text starts after that column.
  final String? symbol;
}

/// Read-only figures in the system popover of iOS 26 and later, its arrow
/// pointing at the control that asked for them.
///
/// The popover is native and drawn above the Flutter view. It follows its
/// anchor while it is open and closes on a tap outside, when the anchor's
/// route stops being the current one, and when the anchor is removed. Its
/// rows only show figures: a tap on one keeps the popover open, and
/// VoiceOver reads each as text, its label then its value, after the title,
/// which it reads as a header.
abstract final class AdaptiveInfoPopover {
  /// Whether [show] can show anything here.
  static bool get isSupported => PlatformUiCapabilities.usesNativeIOS26;

  /// Shows [title], [message] and [rows] in a popover pointing at the widget
  /// of [anchorKey], and completes with true once it has closed.
  ///
  /// Completes with false right away, having shown nothing, when the popover
  /// is not [isSupported], there are no [rows], or the anchor is not laid
  /// out: the caller then shows the figures its own way.
  static Future<bool> show({
    required BuildContext context,
    required GlobalKey anchorKey,
    required String title,
    required List<AdaptiveInfoPopoverRow> rows,
    String? message,
  }) async {
    if (!isSupported || rows.isEmpty || !_isLaidOut(anchorKey)) return false;
    await CNPopover.show(
      context: context,
      anchorKey: anchorKey,
      content: CNPopoverContent(
        title: title,
        message: message,
        rows: [
          for (final (index, row) in rows.indexed)
            CNPopoverRow(
              id: '$index',
              readOnly: true,
              item: CNListItem(
                title: row.label,
                subtitle: row.detail,
                trailingText: row.value,
                leadingSymbol: row.symbol == null
                    ? null
                    : CNSymbol(row.symbol!),
              ),
            ),
        ],
      ),
    );
    return true;
  }

  static bool _isLaidOut(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize;
  }
}
