import 'package:flutter/widgets.dart';

import '../theme/theme_extensions.dart';

/// Consistent safe area wrapper for modal sheets presented across the app.
///
/// All modal-bottom sheets should rely on this widget to guarantee that
/// system insets (e.g. gesture areas or dynamic island) are respected while
/// maintaining the same padding rhythm used by the attachments sheet.
class ModalSheetSafeArea extends StatelessWidget {
  const ModalSheetSafeArea({
    super.key,
    required this.child,
    this.padding,
    this.bottom = true,
  });

  /// Content rendered inside the safe area.
  final Widget child;

  /// Optional custom padding that wraps the [child]. When omitted the default
  /// modal spacing used by attachments/chat input is applied.
  final EdgeInsets? padding;

  /// Whether this surface owns the bottom system inset.
  ///
  /// Native sheet routes already reserve the home-indicator area, so nested
  /// surfaces can disable this to avoid applying the same inset twice.
  final bool bottom;

  @override
  Widget build(BuildContext context) {
    final resolvedPadding =
        padding ??
        const EdgeInsets.fromLTRB(
          Spacing.modalPadding,
          Spacing.sm,
          Spacing.modalPadding,
          Spacing.modalPadding,
        );

    return SafeArea(
      top: false,
      bottom: bottom,
      child: Padding(padding: resolvedPadding, child: child),
    );
  }
}
