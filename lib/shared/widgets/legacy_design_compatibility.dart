import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

/// Supplies legacy design themes and localizations to dependencies that have
/// not yet migrated to the standalone Material and Cupertino packages.
///
/// Remove this boundary after the remaining path and hosted dependencies stop
/// importing `package:flutter/material.dart` and `package:flutter/cupertino.dart`.
class LegacyDesignCompatibility extends StatelessWidget {
  const LegacyDesignCompatibility({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // These bridges are deliberately deprecated to mark them as temporary.
    // Keep the suppression at this single compatibility boundary.
    // ignore: deprecated_member_use
    return MaterialUiCompatibilityBridge(
      // ignore: deprecated_member_use
      child: CupertinoUiCompatibilityBridge(child: child),
    );
  }
}
