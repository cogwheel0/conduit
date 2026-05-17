import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/theme_extensions.dart';
import 'conduit_components.dart';
import 'conduit_loading.dart';
import 'middle_ellipsis_text.dart';

const double kConduitAdaptiveToolbarLeadingGap = Spacing.sm;
const double kConduitAdaptiveToolbarMaxPillWidth = 220;

/// Builds the shared adaptive toolbar shell used by chat-style pages.
AdaptiveAppBar buildConduitAdaptiveToolbarAppBar({
  required Color tintColor,
  required Widget Function() buildLeading,
  required List<AdaptiveAppBarAction> Function() buildActions,
  double? leadingWidth,
}) {
  final leading = buildLeading();
  final actions = buildActions();
  final materialActions = _buildMaterialToolbarActions(
    actions,
    defaultTint: tintColor,
  );

  return AdaptiveAppBar(
    useNativeToolbar: Platform.isIOS || leadingWidth == null,
    leading: leading,
    tintColor: tintColor,
    actions: actions,
    appBar: leadingWidth == null
        ? null
        : _buildMaterialToolbarAppBar(
            leading: leading,
            leadingWidth: leadingWidth,
            actions: materialActions,
          ),
  );
}

PreferredSizeWidget _buildMaterialToolbarAppBar({
  required Widget leading,
  required double leadingWidth,
  required List<Widget> actions,
}) {
  return AppBar(
    automaticallyImplyLeading: false,
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    shadowColor: Colors.transparent,
    elevation: Elevation.none,
    scrolledUnderElevation: Elevation.none,
    toolbarHeight: kTextTabBarHeight,
    centerTitle: false,
    titleSpacing: Spacing.sm,
    leadingWidth: leadingWidth,
    leading: leading,
    actions: actions,
  );
}

List<Widget> _buildMaterialToolbarActions(
  List<AdaptiveAppBarAction> actions, {
  required Color defaultTint,
}) {
  return buildConduitAdaptiveToolbarActionWidgets([
    for (final action in actions)
      _buildMaterialToolbarAction(action, defaultTint: defaultTint),
  ]);
}

Widget _buildMaterialToolbarAction(
  AdaptiveAppBarAction action, {
  required Color defaultTint,
}) {
  final tintColor = action.tintColor ?? defaultTint;
  if (action.title != null) {
    return TextButton(
      onPressed: action.onPressed,
      style: TextButton.styleFrom(foregroundColor: tintColor),
      child: Text(action.title!),
    );
  }

  return ConduitAdaptiveAppBarIconButton(
    icon: action.icon ?? Icons.circle,
    onPressed: action.onPressed,
    iconColor: tintColor,
  );
}

Widget buildConduitAdaptiveToolbarLeadingRow({required List<Widget> children}) {
  if (Platform.isIOS) {
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  return Padding(
    padding: const EdgeInsets.only(left: Spacing.inputPadding),
    child: Row(mainAxisSize: MainAxisSize.min, children: children),
  );
}

List<Widget> buildConduitAdaptiveToolbarActionWidgets(List<Widget> actions) {
  final widgets = <Widget>[];
  for (var i = 0; i < actions.length; i++) {
    if (i > 0) {
      widgets.add(const SizedBox(width: Spacing.sm));
    }
    widgets.add(
      i == actions.length - 1
          ? Platform.isIOS
                ? actions[i]
                : Padding(
                    padding: const EdgeInsets.only(right: Spacing.inputPadding),
                    child: actions[i],
                  )
          : actions[i],
    );
  }

  return widgets;
}

TextStyle conduitAdaptiveToolbarPillTextStyle(BuildContext context) {
  return AppTypography.standard.copyWith(
    color: context.conduitTheme.textPrimary,
    fontWeight: FontWeight.w600,
  );
}

Widget buildConduitAdaptiveToolbarPillSurface({
  required double width,
  required Widget child,
  VoidCallback? onPressed,
  String? semanticLabel,
}) {
  final sizedChild = SizedBox(width: width, child: child);

  if (Platform.isAndroid) {
    if (onPressed == null) {
      return SizedBox(
        width: width,
        child: FloatingAppBarPill(child: child),
      );
    }

    return FloatingAppBarButton(
      onTap: onPressed,
      semanticLabel: semanticLabel,
      child: sizedChild,
    );
  }

  return AdaptiveButton.child(
    onPressed: onPressed ?? () {},
    style: AdaptiveButtonStyle.glass,
    size: AdaptiveButtonSize.large,
    padding: EdgeInsets.zero,
    minSize: Size(width, 44),
    useSmoothRectangleBorder: false,
    child: sizedChild,
  );
}

double resolveConduitAdaptiveToolbarLeadingWidth({
  required double pillWidth,
  double leadingGap = kConduitAdaptiveToolbarLeadingGap,
}) {
  return Spacing.inputPadding +
      TouchTarget.minimum +
      leadingGap +
      pillWidth +
      Spacing.md;
}

/// Resolves a stable pill width inside a constrained toolbar slot.
///
/// The result never exceeds the available space. When the preferred padding
/// would make the pill too small, the helper still keeps a small minimum gap so
/// the title does not visually collide with neighboring controls.
double resolveConduitAdaptiveToolbarPillWidth({
  required double availableWidth,
  required double maxWidth,
  double preferredPadding = 0,
  double minimumPadding = Spacing.sm,
}) {
  final preferredReservedPadding = preferredPadding > minimumPadding
      ? preferredPadding
      : minimumPadding;
  final effectivePadding = availableWidth > minimumPadding
      ? preferredReservedPadding
            .clamp(minimumPadding, availableWidth)
            .toDouble()
      : 0.0;
  final effectiveWidth = availableWidth - effectivePadding;

  return effectiveWidth.clamp(0.0, maxWidth).toDouble();
}

/// Estimates a safe leading-pill width for native adaptive toolbars.
///
/// Native toolbars do not automatically rebalance the leading area against
/// trailing actions, so callers provide the trailing action count and let this
/// helper reserve the remaining space before sizing the pill.
double resolveConduitAdaptiveLeadingPillWidth(
  BuildContext context, {
  required int trailingActionCount,
  required double maxWidth,
  double leadingGap = kConduitAdaptiveToolbarLeadingGap,
  double trailingActionSpacing = Spacing.sm,
}) {
  final trailingSpacing = trailingActionCount > 1
      ? (trailingActionCount - 1) * trailingActionSpacing
      : 0.0;
  final trailingWidth = trailingActionCount > 0
      ? (trailingActionCount * TouchTarget.minimum) +
            trailingSpacing +
            Spacing.inputPadding
      : Spacing.inputPadding;
  final availableWidth =
      MediaQuery.sizeOf(context).width -
      TouchTarget.minimum -
      leadingGap -
      trailingWidth -
      (Spacing.inputPadding * 2);

  return resolveConduitAdaptiveToolbarPillWidth(
    availableWidth: availableWidth,
    maxWidth: maxWidth,
  );
}

/// Measures a text pill and clamps it to the safe toolbar width budget.
double resolveConduitAdaptiveTextPillWidth({
  required BuildContext context,
  required String label,
  required TextStyle textStyle,
  required double maxWidth,
  double minWidth = 0,
  double horizontalPadding = 0,
  double leadingWidth = 0,
  double trailingWidth = 0,
}) {
  final safeMaxWidth = maxWidth.clamp(0.0, double.infinity).toDouble();
  if (safeMaxWidth == 0) {
    return 0;
  }
  final safeMinWidth = minWidth.clamp(0.0, safeMaxWidth).toDouble();
  final textPainter = TextPainter(
    text: TextSpan(text: label, style: textStyle),
    maxLines: 1,
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: Directionality.of(context),
  )..layout(minWidth: 0, maxWidth: double.infinity);

  final measuredWidth =
      textPainter.width + horizontalPadding + leadingWidth + trailingWidth;

  return measuredWidth.clamp(safeMinWidth, safeMaxWidth).toDouble();
}

Object conduitAdaptivePopupMenuIcon({
  required String iosSymbol,
  required IconData materialIcon,
}) {
  return Platform.isIOS ? iosSymbol : materialIcon;
}

/// Adaptive floating app-bar icon button for route-level toolbar actions.
class ConduitAdaptiveAppBarIconButton extends StatelessWidget {
  /// Creates an adaptive toolbar icon button.
  const ConduitAdaptiveAppBarIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.iconColor,
  });

  /// Icon shown inside the control.
  final IconData icon;

  /// Invoked when the control is tapped.
  final VoidCallback? onPressed;

  /// Optional icon tint.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final effectiveIconColor = iconColor ?? context.conduitTheme.textPrimary;

    if (Platform.isAndroid) {
      return FloatingAppBarIconButton(
        icon: icon,
        onTap: onPressed,
        iconColor: effectiveIconColor,
      );
    }

    return AdaptiveButton.child(
      onPressed: onPressed,
      style: AdaptiveButtonStyle.glass,
      size: AdaptiveButtonSize.large,
      padding: EdgeInsets.zero,
      minSize: const Size(TouchTarget.minimum, TouchTarget.minimum),
      useSmoothRectangleBorder: false,
      child: Icon(icon, size: IconSize.appBar, color: effectiveIconColor),
    );
  }
}

/// Adaptive model-selector control used by floating route toolbars.
class ConduitAdaptiveAppBarModelSelector extends StatelessWidget {
  /// Creates an adaptive toolbar model selector.
  const ConduitAdaptiveAppBarModelSelector({
    super.key,
    required this.label,
    required this.maxWidth,
    required this.onPressed,
    this.isLoading = false,
    this.textStyle,
  });

  /// Text shown inside the selector.
  final String label;

  /// Maximum width available for the selector.
  ///
  /// Short labels shrink to fit their content while longer labels ellipsize
  /// inside this cap so toolbar layout still respects neighboring actions.
  final double maxWidth;

  /// Invoked when the selector is tapped.
  final VoidCallback onPressed;

  /// Whether to render a loading placeholder instead of the current label.
  final bool isLoading;

  /// Optional text style override for the selector label.
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final effectiveTextStyle =
        textStyle ?? conduitAdaptiveToolbarPillTextStyle(context);
    final safeMaxWidth = maxWidth.clamp(0.0, double.infinity).toDouble();
    if (safeMaxWidth == 0) {
      return const SizedBox.shrink();
    }
    final chevronSize = Platform.isIOS ? IconSize.small : IconSize.medium;
    const leadingPadding = 10.0;
    final targetWidth = isLoading
        ? safeMaxWidth.clamp(0.0, 104.0).toDouble()
        : resolveConduitAdaptiveTextPillWidth(
            context: context,
            label: label,
            textStyle: effectiveTextStyle,
            maxWidth: safeMaxWidth,
            minWidth: 96,
            horizontalPadding: leadingPadding + Spacing.xs + 12,
            trailingWidth: chevronSize + Spacing.xs,
          );
    final child = SizedBox(
      width: targetWidth,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: EdgeInsets.only(left: leadingPadding, right: Spacing.xs),
          child: Center(
            widthFactor: 1,
            child: isLoading
                ? ConduitLoading.skeleton(
                    width: 80,
                    height: 14,
                    borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: MiddleEllipsisText(
                          label,
                          style: effectiveTextStyle,
                          textAlign: TextAlign.center,
                          semanticsLabel: label,
                        ),
                      ),
                      const SizedBox(width: Spacing.xs),
                      Icon(
                        Platform.isIOS
                            ? CupertinoIcons.chevron_down
                            : Icons.keyboard_arrow_down,
                        color: context.conduitTheme.iconSecondary,
                        size: chevronSize,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );

    if (Platform.isAndroid) {
      return FloatingAppBarButton(
        onTap: isLoading ? null : onPressed,
        semanticLabel: label,
        child: child,
      );
    }

    return AdaptiveButton.child(
      onPressed: isLoading ? () {} : onPressed,
      style: AdaptiveButtonStyle.glass,
      size: AdaptiveButtonSize.large,
      padding: EdgeInsets.zero,
      minSize: Size(targetWidth, 44),
      useSmoothRectangleBorder: false,
      child: child,
    );
  }
}

class ConduitAdaptiveToolbarOverflowButton<T> extends StatelessWidget {
  const ConduitAdaptiveToolbarOverflowButton({
    super.key,
    required this.tintColor,
    required this.items,
    required this.onSelected,
    this.iosIcon = 'ellipsis',
    this.materialIcon = Icons.more_vert_rounded,
  });

  final Color tintColor;
  final List<AdaptivePopupMenuEntry> items;
  final ValueChanged<T> onSelected;
  final String iosIcon;
  final IconData materialIcon;

  void _handleSelected(int index, AdaptivePopupMenuItem<T> entry) {
    final value = entry.value;
    if (value != null) {
      onSelected(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) {
      return AdaptivePopupMenuButton.widget<T>(
        items: items,
        onSelected: _handleSelected,
        child: FloatingAppBarIconButton(
          icon: materialIcon,
          iconColor: tintColor,
        ),
      );
    }

    return AdaptivePopupMenuButton.icon<T>(
      icon: Platform.isIOS ? iosIcon : materialIcon,
      tint: tintColor,
      size: TouchTarget.minimum,
      buttonStyle: PopupButtonStyle.glass,
      items: items,
      onSelected: _handleSelected,
    );
  }
}
