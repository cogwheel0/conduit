import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/widgets.dart';

import 'platform_ui_capabilities.dart';

/// A button of an [AdaptivePreviewPopover] other than its close button.
@immutable
class AdaptivePreviewPopoverAction {
  const AdaptivePreviewPopoverAction({
    required this.id,
    required this.label,
    this.isDefault = false,
  });

  /// Returned by [AdaptivePreviewPopover.show] when the button is pressed.
  final String id;

  final String label;

  /// Whether this is the popover's main, prominent action.
  final bool isDefault;
}

/// The system popover of iOS 26 and later, pointing at a widget: a title, a
/// line or two of text and buttons, all drawn by UIKit.
///
/// Only iOS 26 and later show it: check [canShow] first and keep the
/// widget's own path elsewhere. The popover reports a failure to present the
/// same way as a tap outside it, so [canShow] is the only fallback point.
abstract final class AdaptivePreviewPopover {
  /// Whether [show] can point a popover at [anchorContext]'s widget: iOS 26
  /// or later, with that widget laid out.
  static bool canShow(BuildContext anchorContext) {
    if (!PlatformUiCapabilities.usesNativeIOS26) return false;
    final box = anchorContext.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize;
  }

  /// Shows [title] and [message] with [actions] and a [closeLabel] button,
  /// and returns the id of the pressed action, or null when the popover was
  /// closed without one. An action's id comes back once the popover's
  /// dismissal has finished, so the caller can present what the action opens
  /// (the in-app browser, a sheet) straight away.
  static Future<String?> show({
    required BuildContext anchorContext,
    required String title,
    String? message,
    List<AdaptivePreviewPopoverAction> actions = const [],
    required String closeLabel,
  }) {
    return CNPopover.show(
      context: anchorContext,
      content: CNPopoverContent(
        title: title,
        message: message,
        actions: [
          for (final action in actions)
            CNPopoverAction(
              id: action.id,
              label: action.label,
              style: action.isDefault
                  ? CNPopoverActionStyle.defaultAction
                  : CNPopoverActionStyle.plain,
            ),
          CNPopoverAction.cancel(label: closeLabel),
        ],
      ),
    );
  }
}
