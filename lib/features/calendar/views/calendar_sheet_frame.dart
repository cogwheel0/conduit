import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/themed_sheets.dart';

/// The surface for the calendar's sheets.
///
/// The modal route does not move for the keyboard, so the surface is lifted by
/// the keyboard inset the way [ThemedSheets.showSurface] does it. It also lays
/// its child out with unbounded height, so the body gets a bound: most of the
/// screen, or whatever the keyboard leaves below the status bar. The native iOS
/// presenter gives its content no Material ancestor, which the controls inside
/// need.
class CalendarSheetFrame extends StatelessWidget {
  const CalendarSheetFrame({
    super.key,
    required this.title,
    required this.child,
    this.onClose,
  });

  final String title;
  final Widget child;

  /// Overrides what the close button does; by default it pops the sheet.
  final VoidCallback? onClose;

  // The handle's margins and bar, plus the surface's top and bottom padding.
  static const _surfaceChrome =
      Spacing.sm + 4 + Spacing.md + Spacing.sm + Spacing.modalPadding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final height = MediaQuery.sizeOf(context).height;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    // A modal route without useSafeArea strips the top padding from its
    // MediaQuery, so the status bar has to come from the view itself.
    final view = View.of(context);
    final statusBar = view.padding.top / view.devicePixelRatio;
    final remaining =
        height -
        keyboard -
        statusBar -
        bottomSafe -
        _surfaceChrome -
        Spacing.sm;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboard),
      child: ConduitModalSheetSurface(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.max(0, math.min(height * 0.9, remaining)),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: theme.headingSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SheetCloseButton(
                      tooltip: l10n.close,
                      onPressed: onClose ?? () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm),
                Flexible(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
