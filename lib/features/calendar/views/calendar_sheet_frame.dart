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
///
/// [child] scrolls; [footer], when given, stays pinned below it so a sheet's
/// actions and errors are always in reach. When the space is too short for a
/// pinned footer and some of the form, as in landscape with the keyboard up,
/// the title, [child] and [footer] scroll together instead, so nothing
/// overflows and the actions are still reached by scrolling. [child] must
/// shrink-wrap its height (a `ListView` with `shrinkWrap: true`), since it is
/// laid out at its full height then.
class CalendarSheetFrame extends StatefulWidget {
  const CalendarSheetFrame({
    super.key,
    required this.title,
    required this.child,
    this.footer,
    this.onClose,
    this.holdDismiss = false,
  });

  final String title;
  final Widget child;

  /// Pinned under [child], outside its scroll view.
  final Widget? footer;

  /// Overrides what the close button does; by default it pops the sheet.
  final VoidCallback? onClose;

  /// Keeps a swipe down from dismissing the sheet, as for a form with unsaved
  /// edits. The sheet resists the swipe and, when it is let go far or fast
  /// enough, the close action runs instead so it can ask first. A `PopScope`
  /// cannot do this on its own: the route's drag dismissal pops directly.
  final bool holdDismiss;

  // The handle's margins and bar, plus the surface's top and bottom padding.
  static const _handleBarHeight = Spacing.xs;
  static const _surfaceChrome =
      Spacing.sm +
      _handleBarHeight +
      Spacing.md +
      Spacing.sm +
      Spacing.modalPadding;

  /// Below this height the title, form and footer scroll as one: a pinned
  /// footer of two buttons, or one with an error, would leave the form too
  /// little room, or none at all.
  static const _minimumPinnedHeight = 300.0;

  @override
  State<CalendarSheetFrame> createState() => _CalendarSheetFrameState();
}

class _CalendarSheetFrameState extends State<CalendarSheetFrame>
    with SingleTickerProviderStateMixin {
  /// A held swipe this far down, or flung this fast, asks to close.
  static const _closeDistance = 80.0;
  static const _closeVelocity = 700.0;

  late final AnimationController _settle = AnimationController(vsync: this)
    ..addListener(() => setState(() {}));

  /// How far the finger has gone down during a held swipe.
  double _drag = 0;

  /// Where the surface was when a held swipe was let go.
  double _releasedAt = 0;

  /// The column's bound when it scrolls as one: a [Flexible] needs a finite
  /// one, and no form comes near it.
  static const _unpinnedMaximumHeight = 100000.0;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// The surface follows the finger with more and more resistance, so it
  /// reads as held rather than stuck.
  double _resisted(double drag) {
    const constant = 0.55;
    final dimension = MediaQuery.sizeOf(context).height;
    if (drag <= 0 || dimension <= 0) return 0;
    return (drag * dimension * constant) / (dimension + constant * drag);
  }

  double get _offset => _settle.isAnimating
      ? _releasedAt * (1 - _settle.value)
      : _resisted(_drag);

  void _onDragUpdate(DragUpdateDetails details) {
    _settle.stop();
    setState(() => _drag = math.max(0, _drag + (details.primaryDelta ?? 0)));
  }

  void _onDragEnd(DragEndDetails details) {
    final asks =
        _drag > _closeDistance ||
        (details.primaryVelocity ?? 0) > _closeVelocity;
    _releasedAt = _resisted(_drag);
    _drag = 0;
    _settle.duration = context.motionDuration(AnimationDuration.fast);
    _settle.forward(from: 0);
    if (asks) _close();
  }

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
        CalendarSheetFrame._surfaceChrome -
        Spacing.sm;
    final footer = widget.footer;
    final frame = AnimatedPadding(
      duration: context.motionDuration(AnimationDuration.fast),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboard),
      child: ConduitModalSheetSurface(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.max(0, math.min(height * 0.9, remaining)),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final header = Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          widget.title,
                          style: theme.headingSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    SheetCloseButton(tooltip: l10n.close, onPressed: _close),
                  ],
                );
                final pinned =
                    constraints.maxHeight >=
                    CalendarSheetFrame._minimumPinnedHeight;
                final behavior = ScrollConfiguration.of(context);
                // Both layouts are the same tree, so switching between them
                // as the keyboard comes and goes keeps the form's state and
                // its focused field. Pinned, the outer scroll view does not
                // move and the column is held to the sheet, so the form
                // scrolls above the footer. Otherwise the column takes its
                // full height and scrolls as one; the form's own list then
                // takes no drags, so they scroll the whole sheet.
                return SingleChildScrollView(
                  key: const Key('calendar-sheet-scroll'),
                  primary: false,
                  physics: pinned ? const NeverScrollableScrollPhysics() : null,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: pinned
                          ? constraints.maxHeight
                          : _unpinnedMaximumHeight,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        header,
                        const SizedBox(height: Spacing.sm),
                        Flexible(
                          child: ScrollConfiguration(
                            behavior: pinned
                                ? behavior
                                : behavior.copyWith(
                                    scrollbars: false,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                  ),
                            child: widget.child,
                          ),
                        ),
                        if (footer != null) ...[
                          const SizedBox(height: Spacing.md),
                          footer,
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    // The detector and the offset stay in the tree whether or not a swipe is
    // held, so a form turning dirty keeps its fields and their focus. Without
    // callbacks the detector takes no drags and the route's own swipe works.
    final hold = widget.holdDismiss;
    return GestureDetector(
      onVerticalDragUpdate: hold ? _onDragUpdate : null,
      onVerticalDragEnd: hold ? _onDragEnd : null,
      onVerticalDragCancel: hold ? () => setState(() => _drag = 0) : null,
      child: Transform.translate(offset: Offset(0, _offset), child: frame),
    );
  }
}
