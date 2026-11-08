import 'package:flutter/widgets.dart';

import 'themed_sheets.dart';

/// Shows [child], native chrome that UIKit draws above Flutter, only while
/// nothing covers its route, and [replacement] otherwise.
///
/// Covered means a tracked sheet is above it, another route is pushed over
/// its route, or its tickers are off. Removing the chrome then keeps its
/// compositor layer from showing above the cover; [replacement] keeps its
/// room so that the layout does not move.
class NativeChromeWhileRouteVisible extends StatelessWidget {
  const NativeChromeWhileRouteVisible({
    super.key,
    required this.child,
    this.replacement = const SizedBox.shrink(),
  });

  final Widget child;
  final Widget replacement;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemedSheets.activeSheetListenable,
      builder: (context, _) {
        final visible =
            !ThemedSheets.isCoveredBySheet(context) &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.isCurrentOf(context) ?? true);
        return visible ? child : replacement;
      },
    );
  }
}
