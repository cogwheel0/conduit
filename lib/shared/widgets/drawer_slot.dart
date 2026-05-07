import 'package:flutter/material.dart';

/// Splits drawer content into a main region and a footer (e.g. bottom tabs).
///
/// [ResponsiveDrawerLayout] detects this widget on mobile and applies
/// horizontal drawer-drag gestures only to [mainPanel], so platform views
/// in [footerPanel] (native tab bars, etc.) receive taps reliably.
class DrawerSlot extends StatelessWidget {
  const DrawerSlot({
    super.key,
    required this.mainPanel,
    required this.footerPanel,
  });

  final Widget mainPanel;
  final Widget footerPanel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: mainPanel),
        footerPanel,
      ],
    );
  }
}
