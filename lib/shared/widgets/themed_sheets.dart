import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/theme_extensions.dart';
import 'modal_safe_area.dart';
import 'sheet_handle.dart';

/// Default size fractions for [DraggableScrollableSheet] inside modal sheets.
///
/// [maxChildSize] stops below the top safe area so sheets do not sit under the
/// status bar or dynamic island when fully expanded.
abstract final class DraggableModalSheetSizes {
  static const double initialChildSize = 0.6;
  static const double minChildSize = 0.3;
  static const double maxChildSize = 0.92;
}

/// Centralized helper for modal bottom sheets.
///
/// Use [showCustom] when the sheet widget draws its own rounded surface. Use
/// [showSurface] when the route should provide the standard Conduit sheet
/// chrome around simpler content.
class ThemedSheets {
  ThemedSheets._();

  static final ValueNotifier<int> _activeSheetCount = ValueNotifier<int>(0);

  /// Whether a Conduit bottom sheet currently covers application content.
  ///
  /// This is independent of navigator nesting. Native UIKit platform views on
  /// an inner route can otherwise remain composited above a sheet presented by
  /// the root navigator.
  static bool get hasActiveSheet => _activeSheetCount.value > 0;

  static Listenable get activeSheetListenable => _activeSheetCount;

  /// Removes UIKit-backed chrome before a tracked root sheet is presented.
  ///
  /// Native glass controls use platform views whose compositor layer can sit
  /// above Flutter modal routes. The tracked sheet presenter updates this
  /// signal one frame before pushing the route so covered controls are gone
  /// before the sheet starts animating.
  static Widget hideNativeChromeWhileCovered({
    required Widget child,
    Widget replacement = const SizedBox.shrink(),
  }) {
    return ListenableBuilder(
      listenable: activeSheetListenable,
      builder: (context, _) => hasActiveSheet ? replacement : child,
    );
  }

  /// Prevents compact sheets from stretching across tablet and desktop widths.
  static const double maxSheetWidth = 640;

  static const ShapeBorder roundedShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(
      top: Radius.circular(AppBorderRadius.bottomSheet),
    ),
  );

  /// Matches the radius used by Conduit's native-style bottom-sheet theme.
  static double cornerRadiusFor(BuildContext context) =>
      AppBorderRadius.bottomSheet;

  static ShapeBorder roundedShapeFor(BuildContext context) {
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(cornerRadiusFor(context)),
      ),
    );
  }

  static BoxConstraints _sheetConstraints(
    BuildContext context,
    BoxConstraints? requested, {
    bool capWidth = true,
  }) {
    final availableWidth = MediaQuery.sizeOf(context).width;
    var sheetWidth = capWidth
        ? math.min(availableWidth, maxSheetWidth)
        : availableWidth;
    if (requested != null) {
      sheetWidth = math.min(sheetWidth, requested.constrainWidth(sheetWidth));
    }

    return BoxConstraints(
      minWidth: sheetWidth,
      maxWidth: sheetWidth,
      minHeight: requested?.minHeight ?? 0,
      maxHeight: requested?.maxHeight ?? double.infinity,
    );
  }

  static Future<T?> showCustom<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isScrollControlled = true,
    bool useSafeArea = false,
    bool enableDrag = true,
    bool isDismissible = true,
    bool useRootNavigator = false,
    Color? barrierColor,
    RouteSettings? routeSettings,
    BoxConstraints? constraints,
    ShapeBorder? shape,
    double? elevation,
    Clip? clipBehavior,
  }) {
    final resolvedShape = shape ?? roundedShapeFor(context);
    return _showTracked<T>(
      context: context,
      present: (coverage) => showModalBottomSheet<T>(
        context: context,
        isScrollControlled: isScrollControlled,
        useSafeArea: useSafeArea,
        enableDrag: enableDrag,
        isDismissible: isDismissible,
        useRootNavigator: useRootNavigator,
        backgroundColor: Colors.transparent,
        barrierColor: barrierColor,
        routeSettings: routeSettings,
        constraints: _sheetConstraints(context, constraints),
        shape: resolvedShape,
        elevation: elevation,
        clipBehavior: clipBehavior ?? Clip.antiAlias,
        builder: (sheetContext) => _SheetCoverageBoundary(
          coverage: coverage,
          child: builder(sheetContext),
        ),
      ),
    );
  }

  /// Presents large previews with the same rounded modal route as the rest of
  /// the app while retaining a near-full-screen canvas.
  static Future<T?> showRoundedPage<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isDismissible = true,
    Color? barrierColor,
    RouteSettings? routeSettings,
  }) {
    return _showTracked<T>(
      context: context,
      present: (coverage) => showModalBottomSheet<T>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        isDismissible: isDismissible,
        enableDrag: false,
        barrierColor: barrierColor,
        routeSettings: routeSettings,
        backgroundColor: context.conduitTheme.surfaceBackground,
        shape: roundedShapeFor(context),
        clipBehavior: Clip.antiAlias,
        constraints: _sheetConstraints(context, null, capWidth: false),
        builder: (sheetContext) => _SheetCoverageBoundary(
          coverage: coverage,
          child: FractionallySizedBox(
            heightFactor: DraggableModalSheetSizes.maxChildSize,
            child: builder(sheetContext),
          ),
        ),
      ),
    );
  }

  static Future<T?> _showTracked<T>({
    required BuildContext context,
    required Future<T?> Function(_SheetCoverageToken coverage) present,
  }) async {
    final coverage = _SheetCoverageToken(() {
      _activeSheetCount.value = math.max(0, _activeSheetCount.value - 1);
    });
    _activeSheetCount.value += 1;
    try {
      // Let UIKit-backed chrome leave the compositor before presenting the
      // Flutter route. Hiding it after the route is pushed is one frame late.
      await WidgetsBinding.instance.endOfFrame;
      if (!context.mounted) return null;
      return await present(coverage);
    } finally {
      coverage.close();
    }
  }

  static Future<T?> showSurface<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isScrollControlled = true,
    bool useSafeArea = false,
    bool enableDrag = true,
    bool isDismissible = true,
    bool useRootNavigator = false,
    Color? barrierColor,
    RouteSettings? routeSettings,
    BoxConstraints? constraints,
    EdgeInsets? padding,
    bool showHandle = true,
    bool useViewInsets = true,
  }) {
    return showCustom<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      enableDrag: enableDrag,
      isDismissible: isDismissible,
      useRootNavigator: useRootNavigator,
      barrierColor: barrierColor,
      routeSettings: routeSettings,
      constraints: constraints,
      builder: (sheetContext) {
        Widget sheet = ConduitModalSheetSurface(
          padding: padding,
          showHandle: showHandle,
          child: builder(sheetContext),
        );

        if (useViewInsets) {
          sheet = AnimatedPadding(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: sheet,
          );
        }

        return sheet;
      },
    );
  }
}

class _SheetCoverageToken {
  _SheetCoverageToken(this._onClose);

  final VoidCallback _onClose;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    _onClose();
  }
}

class _SheetCoverageBoundary extends StatefulWidget {
  const _SheetCoverageBoundary({required this.coverage, required this.child});

  final _SheetCoverageToken coverage;
  final Widget child;

  @override
  State<_SheetCoverageBoundary> createState() => _SheetCoverageBoundaryState();
}

class _SheetCoverageBoundaryState extends State<_SheetCoverageBoundary> {
  @override
  void dispose() {
    widget.coverage.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class SheetCloseButton extends StatelessWidget {
  const SheetCloseButton({
    super.key,
    required this.onPressed,
    this.color,
    this.tooltip,
    this.iconSize = IconSize.md,
    this.buttonSize = 36,
  });

  final VoidCallback? onPressed;
  final Color? color;
  final String? tooltip;
  final double iconSize;
  final double buttonSize;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final iconColor = color ?? theme.textSecondary;
    final icon = Icon(
      Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
      size: iconSize,
      color: iconColor,
    );

    final button = AdaptiveButton.child(
      onPressed: onPressed,
      style: AdaptiveButtonStyle.glass,
      size: buttonSize > 36
          ? AdaptiveButtonSize.large
          : AdaptiveButtonSize.medium,
      padding: EdgeInsets.zero,
      minSize: Size.square(buttonSize),
      useSmoothRectangleBorder: false,
      child: icon,
    );
    if (tooltip == null) {
      return button;
    }
    return Tooltip(message: tooltip!, child: button);
  }
}

/// Shared chrome for modal sheet headers.
///
/// Keeping the handle, title row, and close control in one widget
/// prevents platform-view sheets and Flutter-only sheets from drifting apart.
class ConduitModalSheetHeader extends StatelessWidget {
  const ConduitModalSheetHeader({
    super.key,
    required this.leading,
    required this.title,
    required this.titleStyle,
    required this.onClose,
    this.closeTooltip,
    this.onVerticalDragEnd,
  });

  final Widget leading;
  final String title;
  final TextStyle titleStyle;
  final VoidCallback onClose;
  final String? closeTooltip;
  final GestureDragEndCallback? onVerticalDragEnd;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final header = ColoredBox(
      color: theme.surfaceBackground,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHandle(margin: EdgeInsets.only(top: Spacing.sm)),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.lg,
              vertical: Spacing.sm,
            ),
            child: Row(
              children: [
                leading,
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
                SheetCloseButton(
                  onPressed: onClose,
                  color: theme.textSecondary,
                  tooltip: closeTooltip,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.3)),
        ],
      ),
    );
    if (onVerticalDragEnd == null) {
      return header;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragEnd: onVerticalDragEnd,
      child: header,
    );
  }
}

class ConduitModalSheetSurface extends StatelessWidget {
  const ConduitModalSheetSurface({
    super.key,
    required this.child,
    this.padding,
    this.showHandle = true,
  });

  final Widget child;
  final EdgeInsets? padding;
  final bool showHandle;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    Widget content = child;
    if (showHandle) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [const SheetHandle(), child],
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(ThemedSheets.cornerRadiusFor(context)),
        ),
        border: Border.all(
          color: theme.dividerColor,
          width: BorderWidth.regular,
        ),
        boxShadow: ConduitShadows.modal(context),
      ),
      child: ModalSheetSafeArea(padding: padding, child: content),
    );
  }
}
