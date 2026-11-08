import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_native_better/cupertino_native_better.dart'
    show CNPopover, CNPopoverContent, CNPopoverToggle;
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';

import '../theme/theme_extensions.dart';
import '../utils/adaptive_glass.dart';
import 'conduit_components.dart';
import 'conduit_loading.dart';
import 'themed_sheets.dart';

const double kConduitAdaptiveToolbarLeadingGap = Spacing.sm;
const double kConduitAdaptiveToolbarMaxPillWidth = 220;
const double kConduitAdaptiveToolbarMaxModelSelectorWidth = 320;
const double kConduitModelSelectorChevronExtent = 13;
const double kConduitNativeSingleActionSymbolExtent = 18;
const double kConduitMaximumSystemControlScale = 1.5;

const double _kConduitNativeButtonHorizontalInsets = 32;
const double _kConduitNativeModelChevronPadding = 6;
const double _kConduitNativeModelChevronReservedWidth =
    kConduitModelSelectorChevronExtent + _kConduitNativeModelChevronPadding;
// Flutter and UIKit do not produce perfectly identical SF Pro advances. Keep
// a small optical guard instead of letting UIButton wrap at the measured edge.
const double _kConduitNativeModelTitleWrapGuard = 8;
const int kConduitNativeModelLabelMaxCodeUnits = 256;
const int _kConduitNativeModelLabelPrefixCodeUnits = 160;
const TextStyle _kConduitNativeModelTitleStyle = TextStyle(
  fontSize: 17,
  fontWeight: FontWeight.w400,
);

/// Converts Dynamic Type into bounded control geometry.
///
/// Text remains free to use the full system scale. Chrome grows more slowly,
/// matching the way sidebar rows expand around their scaled text without ever
/// shrinking below the normal 44-point touch target.
double resolveConduitSystemControlScale(TextScaler textScaler) {
  final scaledBodySize = textScaler.scale(AppTypography.bodyLarge);
  final scale = scaledBodySize / AppTypography.bodyLarge;
  if (!scale.isFinite) return 1;
  return scale.clamp(1, kConduitMaximumSystemControlScale).toDouble();
}

double conduitSystemControlScaleOf(BuildContext context) {
  return resolveConduitSystemControlScale(MediaQuery.textScalerOf(context));
}

double conduitScaledControlExtent(
  BuildContext context, {
  double baseExtent = TouchTarget.minimum,
}) {
  return baseExtent * conduitSystemControlScaleOf(context);
}

double conduitScaledIconExtent(BuildContext _, double baseExtent) {
  // Touch targets may grow for Dynamic Type, but glyphs retain the platform's
  // standard visual size. Scaling both made app-bar, tab, and composer icons
  // compete with their labels at accessibility sizes.
  return baseExtent;
}

double conduitAdaptiveToolbarHeightOf(BuildContext context) {
  return kTextTabBarHeight * conduitSystemControlScaleOf(context);
}

/// Icon glyph that follows the platform Bold Text accessibility setting.
///
/// Flutter applies [MediaQueryData.boldText] to [Text] and [EditableText]
/// automatically, but fixed icon fonts do not gain the heavier strokes that
/// native SF Symbols do. A small, hard-edged outline closes that gap without
/// changing the glyph's measured size or touch target.
class ConduitSystemAdaptiveIcon extends StatelessWidget {
  const ConduitSystemAdaptiveIcon(
    this.icon, {
    super.key,
    required this.size,
    required this.color,
  });

  final IconData icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const offset = 0.45;
    final shadows = MediaQuery.boldTextOf(context)
        ? <Shadow>[
            Shadow(color: color, offset: const Offset(-offset, 0)),
            Shadow(color: color, offset: const Offset(offset, 0)),
            Shadow(color: color, offset: const Offset(0, -offset)),
            Shadow(color: color, offset: const Offset(0, offset)),
          ]
        : null;

    return Icon(icon, size: size, color: color, shadows: shadows);
  }
}

/// Restores the route's system text scaler inside framework chrome that clamps
/// or disables scaling, including Cupertino navigation bars.
class ConduitSystemTextScaling extends StatelessWidget {
  const ConduitSystemTextScaling({
    super.key,
    required this.textScaler,
    required this.child,
  });

  final TextScaler textScaler;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child,
    );
  }
}

/// Transparent Cupertino toolbar that expands with Dynamic Type.
///
/// [CupertinoPageScaffold] deliberately disables text scaling for navigation
/// bars. This shell restores the route scaler and advertises the matching
/// preferred height so scaled controls are neither clipped nor overlaid on the
/// page body.
class ConduitAdaptiveCupertinoNavigationBar extends StatelessWidget
    implements ObstructingPreferredSizeWidget {
  const ConduitAdaptiveCupertinoNavigationBar({
    super.key,
    required this.textScaler,
    required this.leading,
    this.middle,
    this.trailing,
    this.centerMiddle = true,
    this.systemOverlayStyle,
  });

  final TextScaler textScaler;
  final Widget leading;
  final Widget? middle;
  final Widget? trailing;
  final bool centerMiddle;
  final SystemUiOverlayStyle? systemOverlayStyle;

  double get _controlScale => resolveConduitSystemControlScale(textScaler);

  @override
  Size get preferredSize => Size.fromHeight(kTextTabBarHeight * _controlScale);

  @override
  bool shouldFullyObstruct(BuildContext context) => false;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;
    Widget bar = SizedBox(
      height: topPadding + preferredSize.height,
      child: Padding(
        padding: EdgeInsets.only(
          top: topPadding,
          left: Spacing.inputPadding,
          right: Spacing.inputPadding,
        ),
        child: ConduitSystemTextScaling(
          textScaler: textScaler,
          child: NavigationToolbar(
            centerMiddle: centerMiddle,
            middleSpacing: Spacing.sm,
            leading: Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              child: leading,
            ),
            middle: middle == null
                ? null
                : Align(widthFactor: 1, child: middle),
            trailing: trailing == null
                ? null
                : Align(
                    alignment: AlignmentDirectional.centerEnd,
                    widthFactor: 1,
                    child: trailing,
                  ),
          ),
        ),
      ),
    );

    if (systemOverlayStyle != null) {
      bar = AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemOverlayStyle!,
        child: bar,
      );
    }
    return bar;
  }
}

Widget _hideNativeToolbarChromeWhileSheetCovered({
  required Size size,
  required Widget child,
}) {
  return ThemedSheets.hideNativeChromeWhileCovered(
    replacement: SizedBox.fromSize(size: size),
    child: child,
  );
}

/// Builds the shared app bar used by chat-style routes.
///
/// [NavigationToolbar] applies the same collision-aware title placement to the
/// Cupertino shell that Material's [AppBar] uses. Most page identities stay
/// centered, while wide interactive titles such as model selectors can opt
/// into the platform's leading title position.
AdaptiveAppBar buildConduitCenteredAdaptiveAppBar({
  required BuildContext context,
  required Color tintColor,
  required Widget leading,
  required Widget title,
  required List<Widget> actions,
  Widget? cupertinoTrailing,
  bool centerTitle = true,
}) {
  final textScaler = MediaQuery.textScalerOf(context);
  final controlExtent = conduitScaledControlExtent(context);
  final toolbarHeight = conduitAdaptiveToolbarHeightOf(context);
  final overlayStyle = Theme.of(context).appBarTheme.systemOverlayStyle;

  Widget scaled(Widget child) =>
      ConduitSystemTextScaling(textScaler: textScaler, child: child);

  return AdaptiveAppBar(
    useNativeToolbar: false,
    tintColor: tintColor,
    cupertinoNavigationBar: ConduitAdaptiveCupertinoNavigationBar(
      textScaler: textScaler,
      leading: leading,
      middle: title,
      centerMiddle: centerTitle,
      trailing:
          cupertinoTrailing ??
          (actions.isEmpty
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: actions)),
      systemOverlayStyle: overlayStyle,
    ),
    appBar: AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: Elevation.none,
      scrolledUnderElevation: Elevation.none,
      toolbarHeight: toolbarHeight,
      systemOverlayStyle: overlayStyle,
      centerTitle: centerTitle,
      titleSpacing: Spacing.sm,
      leadingWidth: controlExtent + Spacing.inputPadding,
      leading: Padding(
        padding: const EdgeInsetsDirectional.only(start: Spacing.inputPadding),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: scaled(leading),
        ),
      ),
      title: scaled(title),
      actions: [for (final action in actions) scaled(action)],
    ),
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

TextStyle conduitAdaptiveToolbarLeadingTitleTextStyle(BuildContext context) {
  return (PlatformInfo.isIOS
          ? CupertinoTheme.of(context).textTheme.textStyle
          : Theme.of(context).textTheme.titleMedium ?? AppTypography.standard)
      .copyWith(
        color: context.conduitTheme.textPrimary,
        fontWeight: FontWeight.w400,
      );
}

Widget buildConduitAdaptiveToolbarPillSurface({
  required double width,
  required Widget child,
  VoidCallback? onPressed,
  String? semanticLabel,
  double height = TouchTarget.minimum,
}) {
  final sizedChild = SizedBox(width: width, height: height, child: child);

  if (conduitUsesOpaqueGlassFallback()) {
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

  final borderRadius = BorderRadius.circular(height / 2);
  Widget content = sizedChild;
  if (onPressed != null) {
    content = CupertinoButton(
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      minimumSize: Size(width, height),
      borderRadius: borderRadius,
      child: sizedChild,
    );
    if (semanticLabel != null) {
      content = Semantics(
        label: semanticLabel,
        button: true,
        child: ExcludeSemantics(child: content),
      );
    }
  }

  return _hideNativeToolbarChromeWhileSheetCovered(
    size: Size(width, height),
    child: SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AdaptiveGlassBackdrop(
            borderRadius: borderRadius,
            autoHideOnModal: false,
          ),
          content,
        ],
      ),
    ),
  );
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
  final controlExtent = conduitScaledControlExtent(context);
  final trailingSpacing = trailingActionCount > 1
      ? (trailingActionCount - 1) * trailingActionSpacing
      : 0.0;
  final trailingWidth = trailingActionCount > 0
      ? (trailingActionCount * controlExtent) +
            trailingSpacing +
            Spacing.inputPadding
      : Spacing.inputPadding;
  final availableWidth =
      MediaQuery.sizeOf(context).width -
      controlExtent -
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

/// Resolves the native SF Symbol used by Conduit's common toolbar actions.
///
/// Callers may still provide [iosSymbol] explicitly for icons that do not have
/// a stable cross-platform mapping.
String? conduitToolbarSfSymbolForIcon(IconData icon, {String? iosSymbol}) =>
    iosSymbol ?? conduitSfSymbolForIcon(icon);

/// A labelled toolbar action, retaining its busy indicator while UIKit owns
/// the normal iOS glass button.
class ConduitAdaptiveAppBarTextButton extends StatelessWidget {
  const ConduitAdaptiveAppBarTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.isLoading = false,
    this.prominent = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final nativeProminent = conduitSupportsNativeGlass() && prominent;
    if (isLoading) {
      final indicator = SizedBox.square(
        dimension: TouchTarget.minimum,
        child: const Center(
          child: AdaptiveProgressIndicator.activity(radius: 8),
        ),
      );
      return Semantics(
        label: label,
        button: true,
        enabled: false,
        child: conduitSupportsNativeGlass()
            ? FloatingAppBarPill(child: indicator)
            : indicator,
      );
    }
    return AdaptiveButton(
      label: label,
      onPressed: onPressed,
      style: conduitSupportsNativeGlass()
          ? prominent
                ? AdaptiveButtonStyle.prominentGlass
                : AdaptiveButtonStyle.glass
          : AdaptiveButtonStyle.plain,
      color: nativeProminent ? theme.buttonPrimary : null,
      textColor: onPressed == null
          ? theme.buttonDisabledText
          : nativeProminent
          ? theme.buttonPrimaryText
          : theme.buttonPrimary,
      minSize: const Size(0, TouchTarget.minimum),
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
    );
  }
}

/// Adaptive floating app-bar icon button for route-level toolbar actions.
class ConduitAdaptiveAppBarIconButton extends StatelessWidget {
  /// Creates an adaptive toolbar icon button.
  const ConduitAdaptiveAppBarIconButton({
    super.key,
    required this.icon,
    this.iosSymbol,
    this.onPressed,
    this.iconColor,
    this.semanticLabel,
  });

  /// Icon shown inside the control.
  final IconData icon;

  /// Native SF Symbol rendered on iOS 26+.
  final String? iosSymbol;

  /// Invoked when the control is tapped.
  final VoidCallback? onPressed;

  /// Optional icon tint.
  final Color? iconColor;

  /// Accessibility label. Without it, VoiceOver reads the native glass
  /// button's generated SF Symbol description (e.g. "drag").
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final label = semanticLabel;
    final button = _buildButton(context);
    if (label == null ||
        (conduitSupportsNativeGlass() &&
            conduitToolbarSfSymbolForIcon(icon, iosSymbol: iosSymbol) !=
                null)) {
      return button;
    }
    return Semantics(
      label: label,
      button: true,
      enabled: onPressed != null,
      excludeSemantics: true,
      onTap: onPressed,
      child: button,
    );
  }

  Widget _buildButton(BuildContext context) {
    final effectiveIconColor = iconColor ?? context.conduitTheme.textPrimary;
    final controlExtent = conduitScaledControlExtent(context);
    final iconExtent = conduitScaledIconExtent(context, IconSize.appBar);
    final nativeSymbol = conduitToolbarSfSymbolForIcon(
      icon,
      iosSymbol: iosSymbol,
    );
    if (conduitUsesOpaqueGlassFallback()) {
      return SizedBox.square(
        dimension: controlExtent,
        child: FloatingAppBarButton(
          onTap: onPressed,
          isCircular: true,
          child: ConduitSystemAdaptiveIcon(
            icon,
            size: iconExtent,
            color: effectiveIconColor,
          ),
        ),
      );
    }

    return _hideNativeToolbarChromeWhileSheetCovered(
      size: Size.square(controlExtent),
      child: conduitSupportsNativeGlass() && nativeSymbol != null
          ? AdaptiveButton.sfSymbol(
              onPressed: onPressed,
              semanticLabel: semanticLabel,
              sfSymbol: SFSymbol(
                nativeSymbol,
                size: kConduitNativeSingleActionSymbolExtent,
                color: effectiveIconColor,
              ),
              style: AdaptiveButtonStyle.glass,
              size: AdaptiveButtonSize.large,
              padding: EdgeInsets.zero,
              minSize: Size.square(controlExtent),
              useSmoothRectangleBorder: false,
            )
          : AdaptiveButton.child(
              onPressed: onPressed,
              style: AdaptiveButtonStyle.glass,
              size: AdaptiveButtonSize.large,
              padding: EdgeInsets.zero,
              minSize: Size.square(controlExtent),
              useSmoothRectangleBorder: false,
              child: ConduitSystemAdaptiveIcon(
                icon,
                size: iconExtent,
                color: effectiveIconColor,
              ),
            ),
    );
  }
}

/// One native iOS toolbar menu item shown from a grouped trailing action.
class ConduitNativeToolbarMenuItem {
  const ConduitNativeToolbarMenuItem({
    required this.label,
    required this.onSelected,
    this.iosSymbol,
    this.isDestructive = false,
    this.isChecked = false,
    this.enabled = true,
  });

  final String label;
  final String? iosSymbol;
  final VoidCallback onSelected;
  final bool isDestructive;
  final bool isChecked;
  final bool enabled;
}

/// One action in an iOS 26 toolbar group.
class ConduitNativeToolbarAction {
  const ConduitNativeToolbarAction({
    required this.iosSymbol,
    required this.accessibilityLabel,
    this.onPressed,
    this.menuItems = const <ConduitNativeToolbarMenuItem>[],
    this.tintColor,
    this.enabled = true,
  }) : assert(onPressed != null || menuItems.length > 0 || !enabled);

  final String iosSymbol;
  final String accessibilityLabel;
  final VoidCallback? onPressed;
  final List<ConduitNativeToolbarMenuItem> menuItems;
  final Color? tintColor;
  final bool enabled;
}

/// A cupertino_native_better toolbar surface for adjacent shared actions.
class ConduitNativeToolbarActionGroup extends StatelessWidget {
  const ConduitNativeToolbarActionGroup({super.key, required this.actions})
    : assert(actions.length >= 1 && actions.length <= 3);

  final List<ConduitNativeToolbarAction> actions;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty || actions.length > 3) {
      throw StateError(
        'ConduitNativeToolbarActionGroup requires between 1 and 3 actions.',
      );
    }
    final controlExtent = conduitScaledControlExtent(context);
    final width = actions.length == 1
        ? controlExtent
        : (controlExtent * actions.length) +
              (Spacing.sm * (actions.length - 1));
    final size = Size(width, controlExtent);

    // Each action is its own circular glass control. The package's merged
    // CNGlassButtonGroup forces a wide glass-blend spacing on horizontal
    // groups, which draws adjacent buttons as one pinched "dumbbell" pill on
    // real iOS 26 devices (#686), and it cannot express checked or disabled
    // menu rows. Separate controls match the leading toolbar buttons.
    final controls = actions.length == 1
        ? _buildAction(actions.single, controlExtent)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < actions.length; index++) ...[
                if (index > 0) const SizedBox(width: Spacing.sm),
                _buildAction(actions[index], controlExtent),
              ],
            ],
          );

    return _hideNativeToolbarChromeWhileSheetCovered(
      size: size,
      child: SizedBox.fromSize(size: size, child: controls),
    );
  }

  /// Colors the symbol itself so trailing actions render the exact theme
  /// color, like the leading button and the sidebar's glass group. A bare
  /// control tint lets Liquid Glass lift the foreground to a brighter shade.
  /// Pre-colored symbols skip UIKit's disabled dimming, so apply it here.
  static Color? _symbolColor(ConduitNativeToolbarAction action) {
    final color = action.tintColor;
    if (color == null || action.enabled) return color;
    return color.withValues(alpha: color.a * 0.35);
  }

  Widget _buildAction(ConduitNativeToolbarAction action, double extent) {
    if (action.menuItems.isEmpty) {
      return Semantics(
        label: action.accessibilityLabel,
        button: true,
        enabled: action.enabled,
        onTap: action.enabled ? action.onPressed : null,
        child: CNButton.icon(
          icon: CNSymbol(
            action.iosSymbol,
            size: kConduitNativeSingleActionSymbolExtent,
            color: _symbolColor(action),
          ),
          onPressed: action.onPressed,
          enabled: action.enabled,
          tint: action.tintColor,
          config: CNButtonConfig(
            width: extent,
            minHeight: extent,
            padding: EdgeInsets.zero,
            borderRadius: extent / 2,
            style: CNButtonStyle.glass,
          ),
        ),
      );
    }

    return Semantics(
      label: action.accessibilityLabel,
      button: true,
      enabled: action.enabled,
      child: AdaptivePopupMenuButton.icon<int>(
        icon: action.iosSymbol,
        iconSize: kConduitNativeSingleActionSymbolExtent,
        iconColor: _symbolColor(action),
        tint: action.tintColor,
        size: extent,
        enabled: action.enabled,
        buttonStyle: PopupButtonStyle.glass,
        items: [
          for (var index = 0; index < action.menuItems.length; index++)
            AdaptivePopupMenuItem<int>(
              label: action.menuItems[index].label,
              icon: action.menuItems[index].iosSymbol,
              enabled: action.menuItems[index].enabled,
              isDestructive: action.menuItems[index].isDestructive,
              checked: action.menuItems[index].isChecked,
              value: index,
            ),
        ],
        onSelected: (index, entry) {
          if (!action.enabled) return;
          final selected = entry.value;
          if (selected != null &&
              selected >= 0 &&
              selected < action.menuItems.length) {
            action.menuItems[selected].onSelected();
          }
        },
      ),
    );
  }
}

/// Width of one action inside a grouped toolbar capsule. Grouped glyphs sit
/// a little closer than separate circles, as in an iOS 26 bar button group.
const double kConduitToolbarClusterSlotExtent = 40;

/// Width of a toolbar cluster holding [count] actions: a single action is a
/// circle the size of the leading button; more share one capsule.
double conduitToolbarClusterWidth(BuildContext context, int count) {
  if (count <= 0) return 0;
  if (count == 1) return conduitScaledControlExtent(context);
  return count *
      kConduitToolbarClusterSlotExtent *
      conduitSystemControlScaleOf(context);
}

/// The widest a bar title may be while it stays centred on the screen.
///
/// The title keeps the same gap to the screen's centre line on both sides,
/// so it reserves the wider of the leading and trailing controls on each
/// side, plus the standard gap between a title and a control.
double resolveConduitCenteredTitleMaxWidth(
  BuildContext context, {
  required double leadingWidth,
  required double trailingWidth,
  required double maxWidth,
  double gap = kConduitAdaptiveToolbarLeadingGap,
}) {
  final side = math.max(leadingWidth, trailingWidth);
  final available =
      MediaQuery.sizeOf(context).width -
      2 * (Spacing.inputPadding + side + gap);
  return available.clamp(0.0, math.max(0.0, maxWidth)).toDouble();
}

/// Explains a bar toggle whose glyph has no label: the system popover of iOS
/// 26 and later, pointing at the toggle, with the setting as a labelled
/// switch and a line on what it does.
///
/// Completes with false right away, having shown nothing, where there is no
/// native popover or the anchor is not laid out.
Future<bool> showConduitToolbarTogglePopover({
  required BuildContext context,
  required GlobalKey anchorKey,
  required String label,
  required bool value,
  required ValueChanged<bool> onChanged,
  String? detail,
  String? symbol,
  Color? tint,
}) async {
  if (!PlatformUiCapabilities.usesNativeIOS26) return false;
  final box = anchorKey.currentContext?.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return false;
  await CNPopover.show(
    context: context,
    anchorKey: anchorKey,
    content: CNPopoverContent(
      toggles: [
        CNPopoverToggle(
          id: 'toggle',
          label: label,
          subtitle: detail,
          value: value,
          symbol: symbol == null ? null : CNSymbol(symbol),
        ),
      ],
    ),
    // The app's switches are monochrome, not the system green.
    tint: tint ?? context.conduitTheme.buttonPrimary,
    onToggleChanged: (_, newValue) => onChanged(newValue),
  );
  return true;
}

/// One action of a [ConduitToolbarActionCluster].
@immutable
class ConduitToolbarClusterItem {
  const ConduitToolbarClusterItem({
    required this.id,
    required this.action,
    this.fallbackIcon,
    this.onLongPress,
    this.anchorKey,
  });

  /// Identifies the action across rebuilds, so a change of the cluster's
  /// actions fades out only those that leave and fades in only those that
  /// arrive.
  final Object id;

  final ConduitNativeToolbarAction action;

  /// Glyph drawn where the platform has no native glass controls.
  final IconData? fallbackIcon;

  /// Invoked on a long press, for example to explain an unlabeled glyph.
  final VoidCallback? onLongPress;

  /// Attached to the action's slot, for a popover pointing at it.
  final GlobalKey? anchorKey;
}

/// The most one frame may advance the cluster's springs, in seconds.
const double _kClusterMaxStep = 1 / 30;

/// Where an arriving action's presence starts: below zero, so its fade
/// begins about 60 ms after the change.
const double _kClusterArrivalLead = -0.35;

/// Critically damped spring stepped by hand, so several values can share one
/// ticker and each can be retargeted from its current value and velocity.
class _ClusterSpring {
  _ClusterSpring(this.value, {required this.tolerance}) : target = value;

  double value;
  double velocity = 0;
  double target;
  final double tolerance;

  bool get isSettled =>
      (value - target).abs() < tolerance && velocity.abs() < tolerance * 10;

  void step(double seconds, double omega) {
    final displacement = value - target;
    final b = velocity + omega * displacement;
    final decay = math.exp(-omega * seconds);
    value = target + (displacement + b * seconds) * decay;
    velocity = (velocity - omega * b * seconds) * decay;
    if (isSettled) snap();
  }

  void snap() {
    value = target;
    velocity = 0;
  }
}

class _ClusterEntry {
  _ClusterEntry(
    this.item, {
    required double centerFromTrailing,
    required double presence,
  }) : centerFromTrailing = _ClusterSpring(centerFromTrailing, tolerance: 0.25),
       presence = _ClusterSpring(presence, tolerance: 0.01);

  ConduitToolbarClusterItem item;

  /// Distance from the cluster's trailing edge to the action's centre.
  final _ClusterSpring centerFromTrailing;
  final _ClusterSpring presence;

  bool get isLeaving => presence.target == 0;
}

/// Trailing toolbar actions grouped on one Liquid Glass surface, the way an
/// iOS 26 navigation bar groups its bar button items: one action is a
/// circle, two or three share one capsule with plain glyphs inside.
///
/// The surface is a single glass shape rather than merged per-button glass,
/// which pinches into a "dumbbell" between buttons on device (#686).
///
/// When the set of actions changes (a new chat becoming a real one), the
/// capsule reshapes once: its width and each glyph's place ride one
/// critically damped spring, actions that leave fade out where they were and
/// actions that arrive fade in where they will rest. A change mid-way
/// retargets from the current values. Reduce Motion keeps only the fades.
///
/// The capsule is anchored at its trailing edge, so it grows and shrinks
/// toward the title.
class ConduitToolbarActionCluster extends StatefulWidget {
  const ConduitToolbarActionCluster({super.key, required this.items})
    : assert(items.length <= 3);

  final List<ConduitToolbarClusterItem> items;

  /// Critically damped, settling in about a third of a second.
  static final double springOmega = math.sqrt(380);

  @override
  State<ConduitToolbarActionCluster> createState() =>
      _ConduitToolbarActionClusterState();
}

class _ConduitToolbarActionClusterState
    extends State<ConduitToolbarActionCluster>
    with SingleTickerProviderStateMixin {
  final Map<Object, _ClusterEntry> _entries = <Object, _ClusterEntry>{};
  late final _ClusterSpring _width = _ClusterSpring(0, tolerance: 0.25);
  late final Ticker _ticker = createTicker(_onTick);
  Duration? _lastTick;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The first layout, and any Dynamic Type change, place everything at
    // rest: only a change of actions animates.
    _sync(animate: _initialized);
    _initialized = true;
  }

  @override
  void didUpdateWidget(covariant ConduitToolbarActionCluster oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(animate: true);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double _centerFromTrailing(int index, int count) {
    if (count == 1) return conduitScaledControlExtent(context) / 2;
    final slot =
        kConduitToolbarClusterSlotExtent * conduitSystemControlScaleOf(context);
    return (count - index - 0.5) * slot;
  }

  void _sync({required bool animate}) {
    final items = widget.items;
    final ids = <Object>{};
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      ids.add(item.id);
      final center = _centerFromTrailing(index, items.length);
      final entry = _entries[item.id];
      if (entry == null) {
        // Arrives where it will rest; only its opacity moves. It starts a
        // little below zero, so it shows only once its native control has
        // been created (a few frames) rather than popping in part-way.
        _entries[item.id] = _ClusterEntry(
          item,
          centerFromTrailing: center,
          presence: animate ? _kClusterArrivalLead : 1,
        )..presence.target = 1;
      } else {
        entry.item = item;
        entry.centerFromTrailing.target = center;
        entry.presence.target = 1;
      }
    }
    for (final entry in _entries.values) {
      if (!ids.contains(entry.item.id)) entry.presence.target = 0;
    }
    _width.target = conduitToolbarClusterWidth(context, items.length);

    final reduceMotion = context.reduceMotion;
    if (!animate || reduceMotion) {
      _width.snap();
      for (final entry in _entries.values) {
        entry.centerFromTrailing.snap();
      }
    }
    if (!animate) {
      for (final entry in _entries.values) {
        entry.presence.snap();
      }
      _entries.removeWhere((_, entry) => entry.presence.value == 0);
    }
    _startIfNeeded();
  }

  bool get _isSettled =>
      _width.isSettled &&
      _entries.values.every(
        (entry) =>
            entry.presence.isSettled && entry.centerFromTrailing.isSettled,
      );

  void _startIfNeeded() {
    if (_isSettled || _ticker.isActive) return;
    _lastTick = null;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final last = _lastTick;
    _lastTick = elapsed;
    if (last == null) return;
    // The step is the spring's exact solution, but a long frame (creating
    // the arriving glyphs' native views stalls one) advances it by at most
    // two frames' time, so the reshape slows for a moment instead of
    // jumping to its end.
    final seconds = math.min(
      (elapsed - last).inMicroseconds / Duration.microsecondsPerSecond,
      _kClusterMaxStep,
    );
    final omega = ConduitToolbarActionCluster.springOmega;
    _width.step(seconds, omega);
    for (final entry in _entries.values) {
      entry.centerFromTrailing.step(seconds, omega);
      entry.presence.step(seconds, omega);
    }
    _entries.removeWhere(
      (_, entry) => entry.isLeaving && entry.presence.isSettled,
    );
    if (_isSettled) _ticker.stop();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final height = conduitScaledControlExtent(context);
    final width = math.max(0.0, _width.value);
    final usesNativeGlass = conduitSupportsNativeGlass();
    final borderRadius = BorderRadius.circular(height / 2);
    final theme = context.conduitTheme;

    final Widget background = usesNativeGlass
        ? AdaptiveGlassBackdrop(
            borderRadius: borderRadius,
            autoHideOnModal: false,
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              color: theme.surfaceContainerHighest,
              borderRadius: borderRadius,
              border: Border.all(
                color: theme.cardBorder,
                width: BorderWidth.thin,
              ),
            ),
          );

    final children = <Widget>[Positioned.fill(child: background)];
    for (final entry in _entries.values) {
      final opacity = entry.presence.value.clamp(0.0, 1.0);
      if (opacity <= 0 && entry.isLeaving) continue;
      // The same wrappers whether or not there is a long press or anchor,
      // so a change of either never rebuilds the native control (a blank
      // frame).
      final child = KeyedSubtree(
        key: entry.item.anchorKey,
        child: GestureDetector(
          onLongPress: entry.item.onLongPress,
          child: _buildAction(entry.item, height, usesNativeGlass),
        ),
      );
      children.add(
        Positioned(
          key: ValueKey<Object>(entry.item.id),
          right: entry.centerFromTrailing.value - height / 2,
          top: 0,
          width: height,
          height: height,
          child: IgnorePointer(
            ignoring: entry.isLeaving,
            child: Opacity(opacity: opacity, child: child),
          ),
        ),
      );
    }

    return _hideNativeToolbarChromeWhileSheetCovered(
      size: Size(width, height),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(clipBehavior: Clip.none, children: children),
      ),
    );
  }

  Widget _buildAction(
    ConduitToolbarClusterItem item,
    double extent,
    bool usesNativeGlass,
  ) {
    final action = item.action;
    final color = ConduitNativeToolbarActionGroup._symbolColor(action);
    if (!usesNativeGlass) return _buildFallbackAction(item, extent);
    // The native controls carry the label themselves, as the leading button
    // does: VoiceOver reads it once, not alongside the symbol's own
    // generated name ("compose").
    if (action.menuItems.isEmpty) {
      return CNButton.icon(
        icon: CNSymbol(
          action.iosSymbol,
          size: kConduitNativeSingleActionSymbolExtent,
          color: color,
        ),
        semanticLabel: action.accessibilityLabel,
        onPressed: action.onPressed,
        enabled: action.enabled,
        tint: action.tintColor,
        config: CNButtonConfig(
          width: extent,
          minHeight: extent,
          padding: EdgeInsets.zero,
          style: CNButtonStyle.plain,
        ),
      );
    }
    return AdaptivePopupMenuButton.icon<int>(
      icon: action.iosSymbol,
      semanticLabel: action.accessibilityLabel,
      iconSize: kConduitNativeSingleActionSymbolExtent,
      iconColor: color,
      tint: action.tintColor,
      size: extent,
      enabled: action.enabled,
      buttonStyle: PopupButtonStyle.plain,
      items: _menuEntries(action),
      onSelected: (index, entry) => _onMenuSelected(action, entry),
    );
  }

  List<AdaptivePopupMenuEntry> _menuEntries(ConduitNativeToolbarAction action) {
    return [
      for (var index = 0; index < action.menuItems.length; index++)
        AdaptivePopupMenuItem<int>(
          label: action.menuItems[index].label,
          icon: action.menuItems[index].iosSymbol,
          enabled: action.menuItems[index].enabled,
          isDestructive: action.menuItems[index].isDestructive,
          checked: action.menuItems[index].isChecked,
          value: index,
        ),
    ];
  }

  void _onMenuSelected(
    ConduitNativeToolbarAction action,
    AdaptivePopupMenuItem<int> entry,
  ) {
    if (!action.enabled) return;
    final selected = entry.value;
    if (selected != null &&
        selected >= 0 &&
        selected < action.menuItems.length) {
      action.menuItems[selected].onSelected();
    }
  }

  Widget _buildFallbackAction(ConduitToolbarClusterItem item, double extent) {
    final action = item.action;
    final color =
        ConduitNativeToolbarActionGroup._symbolColor(action) ??
        context.conduitTheme.textPrimary;
    final glyph = SizedBox.square(
      dimension: extent,
      child: Center(
        child: ConduitSystemAdaptiveIcon(
          item.fallbackIcon ?? CupertinoIcons.ellipsis,
          size: conduitScaledIconExtent(context, IconSize.appBar),
          color: color,
        ),
      ),
    );
    if (action.menuItems.isNotEmpty) {
      return Semantics(
        label: action.accessibilityLabel,
        button: true,
        enabled: action.enabled,
        excludeSemantics: true,
        child: IgnorePointer(
          ignoring: !action.enabled,
          child: AdaptivePopupMenuButton.widget<int>(
            items: _menuEntries(action),
            onSelected: (index, entry) => _onMenuSelected(action, entry),
            child: glyph,
          ),
        ),
      );
    }
    return Semantics(
      label: action.accessibilityLabel,
      button: true,
      enabled: action.enabled,
      excludeSemantics: true,
      child: CupertinoButton(
        onPressed: action.enabled ? action.onPressed : null,
        padding: EdgeInsets.zero,
        minimumSize: Size.square(extent),
        child: glyph,
      ),
    );
  }
}

double resolveConduitNativeModelTitleFontSize(TextScaler textScaler) {
  final scaledSize = textScaler.scale(_kConduitNativeModelTitleStyle.fontSize!);
  if (!scaledSize.isFinite || scaledSize <= 0) {
    return _kConduitNativeModelTitleStyle.fontSize!;
  }
  return scaledSize;
}

bool _isLeadingSurrogate(int codeUnit) =>
    codeUnit >= 0xd800 && codeUnit <= 0xdbff;

bool _isTrailingSurrogate(int codeUnit) =>
    codeUnit >= 0xdc00 && codeUnit <= 0xdfff;

/// Bounds backend-controlled model names before regex, layout, grapheme, or
/// platform-channel work while preserving enough of both ends to distinguish
/// namespaced model identifiers.
String boundConduitNativeModelLabel(String value) {
  if (value.length <= kConduitNativeModelLabelMaxCodeUnits) return value;

  var prefixEnd = _kConduitNativeModelLabelPrefixCodeUnits;
  if (_isLeadingSurrogate(value.codeUnitAt(prefixEnd - 1)) &&
      _isTrailingSurrogate(value.codeUnitAt(prefixEnd))) {
    prefixEnd -= 1;
  }

  final suffixBudget = kConduitNativeModelLabelMaxCodeUnits - prefixEnd - 1;
  var suffixStart = value.length - suffixBudget;
  if (_isTrailingSurrogate(value.codeUnitAt(suffixStart)) &&
      _isLeadingSurrogate(value.codeUnitAt(suffixStart - 1))) {
    suffixStart += 1;
  }

  return '${value.substring(0, prefixEnd)}…${value.substring(suffixStart)}';
}

double _measureConduitNativeModelTitle(
  String value,
  TextDirection textDirection,
  double titleFontSize,
) {
  final painter = TextPainter(
    text: TextSpan(
      text: value,
      style: _kConduitNativeModelTitleStyle.copyWith(fontSize: titleFontSize),
    ),
    maxLines: 1,
    textScaler: TextScaler.noScaling,
    textDirection: textDirection,
  )..layout(minWidth: 0, maxWidth: double.infinity);
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Truncates [value] at its end, the way iOS truncates titles: a model name
/// reads from its start ("GPT-5 Mi…"), and a cut through its middle made
/// raw ids look garbled ("openai/…-5-mini").
String _endEllipsizeConduitNativeModelTitle({
  required String value,
  required double maxWidth,
  required TextDirection textDirection,
  required double titleFontSize,
}) {
  if (value.isEmpty || maxWidth <= 0) return '';
  if (_measureConduitNativeModelTitle(value, textDirection, titleFontSize) <=
      maxWidth) {
    return value;
  }

  const ellipsis = '…';
  if (_measureConduitNativeModelTitle(ellipsis, textDirection, titleFontSize) >
      maxWidth) {
    return '';
  }

  final graphemes = value.characters;
  var low = 0;
  var high = graphemes.length;
  var best = ellipsis;
  while (low <= high) {
    final visibleCount = (low + high) >> 1;
    final candidate =
        '${graphemes.take(visibleCount).toString().trimRight()}$ellipsis';
    if (_measureConduitNativeModelTitle(
          candidate,
          textDirection,
          titleFontSize,
        ) <=
        maxWidth) {
      best = candidate;
      low = visibleCount + 1;
    } else {
      high = visibleCount - 1;
    }
  }
  return best;
}

String _normalizedConduitNativeModelLabel(String label) =>
    boundConduitNativeModelLabel(label).replaceAll(RegExp(r'\s+'), ' ').trim();

String? conduitNativeModelSelectorSymbol({required bool showChevron}) =>
    showChevron ? 'chevron.down' : null;

VoidCallback? conduitNativeModelSelectorActivation({
  required bool isLoading,
  required bool showChevron,
  required VoidCallback onPressed,
}) => !isLoading && showChevron ? onPressed : null;

/// Width required by the package's native large label button, capped to the
/// toolbar space Conduit can safely allocate.
double resolveConduitNativeModelSelectorWidth({
  required String label,
  required bool isLoading,
  required bool showChevron,
  required double maxWidth,
  required TextDirection textDirection,
  double minWidth = 112,
  double titleFontSize = 17,
}) {
  final safeMaxWidth = maxWidth.clamp(0.0, double.infinity).toDouble();
  if (safeMaxWidth == 0) return 0;
  if (isLoading) return safeMaxWidth.clamp(0.0, 104.0).toDouble();

  final safeMinWidth = minWidth.clamp(0.0, safeMaxWidth).toDouble();
  final normalizedLabel = _normalizedConduitNativeModelLabel(label);
  final desiredWidth =
      _measureConduitNativeModelTitle(
        normalizedLabel,
        textDirection,
        titleFontSize,
      ) +
      (showChevron ? _kConduitNativeModelChevronReservedWidth : 0) +
      _kConduitNativeButtonHorizontalInsets +
      _kConduitNativeModelTitleWrapGuard;
  return desiredWidth.clamp(safeMinWidth, safeMaxWidth).toDouble();
}

/// Produces a single-line native button title, truncated at its end, while
/// reserving the trailing disclosure chevron.
String resolveConduitNativeModelSelectorLabel({
  required String label,
  required bool isLoading,
  required bool showChevron,
  required double availableWidth,
  required TextDirection textDirection,
  double titleFontSize = 17,
}) {
  if (isLoading) return '…';

  final normalizedLabel = _normalizedConduitNativeModelLabel(label);
  final contentWidth =
      availableWidth -
      _kConduitNativeButtonHorizontalInsets -
      (showChevron ? _kConduitNativeModelChevronReservedWidth : 0);
  final guardedContentWidth =
      (contentWidth - _kConduitNativeModelTitleWrapGuard)
          .clamp(0.0, double.infinity)
          .toDouble();
  if (_measureConduitNativeModelTitle(
        normalizedLabel,
        textDirection,
        titleFontSize,
      ) <=
      guardedContentWidth) {
    return normalizedLabel;
  }
  return _endEllipsizeConduitNativeModelTitle(
    value: normalizedLabel,
    maxWidth: guardedContentWidth,
    textDirection: textDirection,
    titleFontSize: titleFontSize,
  );
}

/// Creates a stable key for native model-selector appearance changes.
ValueKey<Object> conduitNativeModelSelectorViewKey(
  Color foregroundColor, {
  double titleFontSize = 17,
}) => ValueKey<Object>((foregroundColor.toARGB32(), titleFontSize));

class _ConduitNativeModelSelectorButton extends StatelessWidget {
  const _ConduitNativeModelSelectorButton({
    super.key,
    required this.label,
    required this.symbolName,
    required this.foregroundColor,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final String? symbolName;
  final Color foregroundColor;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return CNButton(
      label: label,
      icon: symbolName == null
          ? null
          : CNSymbol(
              symbolName!,
              size: kConduitModelSelectorChevronExtent,
              color: foregroundColor,
            ),
      onPressed: enabled ? onPressed : null,
      enabled: enabled,
      config: CNButtonConfig(
        minHeight: conduitScaledControlExtent(context),
        shrinkWrap: false,
        style: CNButtonStyle.glass,
        imagePlacement: CNImagePlacement.trailing,
        imagePadding: _kConduitNativeModelChevronPadding,
        maxLines: 1,
        labelColor: foregroundColor,
        // UIKit's default body style supplies the standard iOS button
        // metrics, optical sizing, and weight.
      ),
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
    this.showChevron = true,
    this.title,
    this.showsTitle,
  });

  /// Text shown inside the selector.
  final String label;

  /// The page's title (a chat's title), shown above a smaller [label] while
  /// [showsTitle] is true, like an iOS navigation title with a subtitle.
  final String? title;

  /// Whether the content has scrolled under the bar, so the bar should name
  /// the page. When given, the selector cross-fades between the model alone
  /// and [title] over the model, instead of drawing a native button label.
  final ValueListenable<bool>? showsTitle;

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

  /// Whether to show the dropdown chevron and allow tapping to change models.
  /// Hidden for single-agent backends (e.g. the Hermes agent) where there is
  /// nothing to pick.
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final effectiveTextStyle =
        textStyle ?? conduitAdaptiveToolbarLeadingTitleTextStyle(context);
    final safeMaxWidth = maxWidth.clamp(0.0, double.infinity).toDouble();
    if (safeMaxWidth == 0) {
      return const SizedBox.shrink();
    }
    if (showsTitle case final showsTitle?) {
      return _ConduitTitledModelSelector(
        label: boundConduitNativeModelLabel(label),
        semanticsLabel: label,
        title: title == null ? null : boundConduitNativeModelLabel(title!),
        showsTitle: showsTitle,
        maxWidth: safeMaxWidth,
        isLoading: isLoading,
        showChevron: showChevron,
        labelStyle: effectiveTextStyle,
        onPressed: onPressed,
      );
    }
    final controlExtent = conduitScaledControlExtent(context);
    final chevronSize = PlatformInfo.isIOS
        ? kConduitModelSelectorChevronExtent
        : IconSize.small;
    final usesNativeGlass = conduitSupportsNativeGlass();
    final textDirection = Directionality.of(context);
    final nativeTitleFontSize = resolveConduitNativeModelTitleFontSize(
      MediaQuery.textScalerOf(context),
    );
    final boundedLabel = boundConduitNativeModelLabel(label);
    // Equal side insets so the label and chevron sit centered in the pill.
    const horizontalInset = 13.0;
    final targetWidth = isLoading
        ? safeMaxWidth.clamp(0.0, 104.0).toDouble()
        : usesNativeGlass
        ? resolveConduitNativeModelSelectorWidth(
            label: boundedLabel,
            isLoading: false,
            showChevron: showChevron,
            maxWidth: safeMaxWidth,
            textDirection: textDirection,
            titleFontSize: nativeTitleFontSize,
          )
        : resolveConduitAdaptiveTextPillWidth(
            context: context,
            label: boundedLabel,
            textStyle: effectiveTextStyle,
            maxWidth: safeMaxWidth,
            minWidth: 96,
            horizontalPadding: horizontalInset * 2,
            // Only reserve chevron space when a chevron is actually rendered.
            trailingWidth: showChevron ? chevronSize + Spacing.xs : 0,
          );
    Widget buildFallbackChild() => SizedBox(
      width: targetWidth,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: controlExtent),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: horizontalInset),
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
                        child: Text(
                          boundedLabel,
                          style: effectiveTextStyle,
                          textAlign: TextAlign.center,
                          semanticsLabel: label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          textHeightBehavior: const TextHeightBehavior(
                            applyHeightToFirstAscent: false,
                            applyHeightToLastDescent: false,
                          ),
                        ),
                      ),
                      if (showChevron) ...[
                        const SizedBox(width: Spacing.xs),
                        ConduitSystemAdaptiveIcon(
                          PlatformInfo.isIOS
                              ? CupertinoIcons.chevron_down
                              : Icons.keyboard_arrow_down,
                          color: context.conduitTheme.iconSecondary,
                          size: chevronSize,
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );

    if (conduitUsesOpaqueGlassFallback()) {
      return FloatingAppBarButton(
        onTap: conduitNativeModelSelectorActivation(
          isLoading: isLoading,
          showChevron: showChevron,
          onPressed: onPressed,
        ),
        semanticLabel: label,
        child: buildFallbackChild(),
      );
    }

    return _hideNativeToolbarChromeWhileSheetCovered(
      size: Size(targetWidth, controlExtent),
      child: usesNativeGlass
          ? Semantics(
              label: label,
              button: true,
              enabled: !isLoading && showChevron,
              onTap: conduitNativeModelSelectorActivation(
                isLoading: isLoading,
                showChevron: showChevron,
                onPressed: onPressed,
              ),
              excludeSemantics: true,
              child: SizedBox(
                width: targetWidth,
                height: controlExtent,
                child: _ConduitNativeModelSelectorButton(
                  key: conduitNativeModelSelectorViewKey(
                    context.conduitTheme.textPrimary,
                    titleFontSize: nativeTitleFontSize,
                  ),
                  label: resolveConduitNativeModelSelectorLabel(
                    label: boundedLabel,
                    isLoading: isLoading,
                    showChevron: showChevron,
                    availableWidth: targetWidth,
                    textDirection: textDirection,
                    titleFontSize: nativeTitleFontSize,
                  ),
                  symbolName: conduitNativeModelSelectorSymbol(
                    showChevron: showChevron,
                  ),
                  foregroundColor: context.conduitTheme.textPrimary,
                  enabled: !isLoading && showChevron,
                  onPressed: onPressed,
                ),
              ),
            )
          : AdaptiveButton.child(
              onPressed: conduitNativeModelSelectorActivation(
                isLoading: isLoading,
                showChevron: showChevron,
                onPressed: onPressed,
              ),
              style: AdaptiveButtonStyle.glass,
              size: AdaptiveButtonSize.large,
              padding: EdgeInsets.zero,
              minSize: Size(targetWidth, controlExtent),
              useSmoothRectangleBorder: false,
              child: buildFallbackChild(),
            ),
    );
  }
}

/// The model pill of a page whose title cross-fades into the bar.
///
/// At rest it shows the model alone. Once [showsTitle] turns true it shows
/// the page [title] (semibold) over a smaller model line, the shape of an iOS
/// 26 navigation title with a subtitle, and stays one tap from the model
/// picker. The pill's width follows its content.
///
/// The change rides one critically damped spring, started from the current
/// value and velocity, so a scroll that flips back mid-way reverses it
/// without a jump. The outgoing line drifts up as it fades, the incoming one
/// rises into place; Reduce Motion keeps only the cross-fade.
class _ConduitTitledModelSelector extends StatefulWidget {
  const _ConduitTitledModelSelector({
    required this.label,
    required this.semanticsLabel,
    required this.title,
    required this.showsTitle,
    required this.maxWidth,
    required this.isLoading,
    required this.showChevron,
    required this.labelStyle,
    required this.onPressed,
  });

  final String label;
  final String semanticsLabel;
  final String? title;
  final ValueListenable<bool> showsTitle;
  final double maxWidth;
  final bool isLoading;
  final bool showChevron;
  final TextStyle labelStyle;
  final VoidCallback onPressed;

  @override
  State<_ConduitTitledModelSelector> createState() =>
      _ConduitTitledModelSelectorState();
}

/// Critically damped; settles in about a third of a second.
final SpringDescription _kConduitTitleSpring =
    SpringDescription.withDampingRatio(mass: 1, stiffness: 300, ratio: 1);

const double _kConduitTitledPillInset = 14;
const double _kConduitTitledPillDrift = 7;
const double _kConduitTitledPillTitleSize = 15;
const double _kConduitTitledPillSubtitleSize = 12;
const double _kConduitTitledPillSubtitleChevron = 9;

/// Bar titles stop growing with Dynamic Type well before body text does, as
/// UIKit's inline navigation titles do, so two lines still fit the pill.
const double _kConduitTitledPillMaxTextScale = 1.3;

class _ConduitTitledModelSelectorState
    extends State<_ConduitTitledModelSelector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController.unbounded(
    vsync: this,
    value: _wantsTitle ? 1 : 0,
  );
  late double _target = _progress.value;

  bool get _hasTitle => widget.title?.trim().isNotEmpty ?? false;
  bool get _wantsTitle =>
      _hasTitle && !widget.isLoading && widget.showsTitle.value;

  @override
  void initState() {
    super.initState();
    widget.showsTitle.addListener(_syncTarget);
  }

  @override
  void didUpdateWidget(covariant _ConduitTitledModelSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.showsTitle, widget.showsTitle)) {
      oldWidget.showsTitle.removeListener(_syncTarget);
      widget.showsTitle.addListener(_syncTarget);
    }
    _syncTarget();
  }

  @override
  void dispose() {
    widget.showsTitle.removeListener(_syncTarget);
    _progress.dispose();
    super.dispose();
  }

  void _syncTarget() {
    if (!mounted) return;
    final target = _wantsTitle ? 1.0 : 0.0;
    if (target == _target) return;
    _target = target;
    if (context.reduceMotion) {
      _progress.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
      return;
    }
    _progress
        .animateWith(
          SpringSimulation(
            _kConduitTitleSpring,
            _progress.value,
            target,
            _progress.velocity,
          ),
        )
        // A spring stops within its tolerance; land exactly on the target.
        .then((_) {
          if (mounted && _target == target) _progress.value = target;
        });
  }

  double _textWidth(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textScaler: scaler,
      textDirection: Directionality.of(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final controlExtent = conduitScaledControlExtent(context);
    final scaler = MediaQuery.textScalerOf(context);
    final titleScaler = scaler.clamp(
      maxScaleFactor: _kConduitTitledPillMaxTextScale,
    );
    final labelStyle = widget.labelStyle.copyWith(
      fontSize: _kConduitNativeModelTitleStyle.fontSize,
    );
    final titleStyle = widget.labelStyle.copyWith(
      fontSize: _kConduitTitledPillTitleSize,
      fontWeight: FontWeight.w600,
      height: 1.2,
    );
    final subtitleStyle = widget.labelStyle.copyWith(
      fontSize: _kConduitTitledPillSubtitleSize,
      color: theme.textSecondary,
      height: 1.2,
    );
    final chevronIcon = PlatformInfo.isIOS
        ? CupertinoIcons.chevron_down
        : Icons.keyboard_arrow_down;
    final title = widget.title?.trim() ?? '';
    final showChevron = widget.showChevron;

    double clampWidth(double width) =>
        width.clamp(math.min(96.0, widget.maxWidth), widget.maxWidth);
    final modelWidth = widget.isLoading
        ? math.min(104.0, widget.maxWidth)
        : clampWidth(
            _textWidth(widget.label, labelStyle, scaler) +
                (showChevron ? kConduitModelSelectorChevronExtent + 6 : 0) +
                _kConduitTitledPillInset * 2,
          );
    final titledWidth = title.isEmpty
        ? modelWidth
        : clampWidth(
            math.max(
                  _textWidth(title, titleStyle, titleScaler),
                  _textWidth(widget.label, subtitleStyle, titleScaler) +
                      (showChevron
                          ? _kConduitTitledPillSubtitleChevron + 3
                          : 0),
                ) +
                _kConduitTitledPillInset * 2,
          );

    Widget line(String text, TextStyle style, double chevronSize) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            text,
            style: style,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            textHeightBehavior: const TextHeightBehavior(
              applyHeightToFirstAscent: false,
              applyHeightToLastDescent: false,
            ),
          ),
        ),
        if (showChevron) ...[
          SizedBox(width: chevronSize < 12 ? 3 : 6),
          ConduitSystemAdaptiveIcon(
            chevronIcon,
            size: chevronSize,
            color: style.color ?? theme.textPrimary,
          ),
        ],
      ],
    );

    // Narrow bars (large text on a small phone) trade inset before glyphs.
    double contentWidth(double pillWidth, double chevronRoom) {
      final inset = ((pillWidth - chevronRoom) / 2).clamp(
        2.0,
        _kConduitTitledPillInset,
      );
      return math.max(0.0, pillWidth - inset * 2);
    }

    final modelContent = SizedBox(
      width: contentWidth(
        modelWidth,
        showChevron ? kConduitModelSelectorChevronExtent + 6 : 0,
      ),
      child: Center(
        child: widget.isLoading
            ? ConduitLoading.skeleton(
                width: 80,
                height: 14,
                borderRadius: BorderRadius.circular(AppBorderRadius.sm),
              )
            : line(
                widget.label,
                labelStyle,
                kConduitModelSelectorChevronExtent,
              ),
      ),
    );
    final titledContent = title.isEmpty
        ? null
        : MediaQuery.withClampedTextScaling(
            maxScaleFactor: _kConduitTitledPillMaxTextScale,
            child: SizedBox(
              width: contentWidth(
                titledWidth,
                showChevron ? _kConduitTitledPillSubtitleChevron + 3 : 0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: titleStyle,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 1),
                  line(
                    widget.label,
                    subtitleStyle,
                    _kConduitTitledPillSubtitleChevron,
                  ),
                ],
              ),
            ),
          );

    final enabled = !widget.isLoading && showChevron;

    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final t = _progress.value.clamp(0.0, 1.0);
        final semanticLabel = _target == 1 && titledContent != null
            ? '$title, ${widget.semanticsLabel}'
            : widget.semanticsLabel;
        final drift = context.reduceMotion ? 0.0 : _kConduitTitledPillDrift;
        final width = lerpDouble(modelWidth, titledWidth, t)!;
        // One curve for both directions, a pure function of the spring's
        // value, so a reversal mid-way never pops: each line holds its
        // own half and they overlap only faintly around the middle, never
        // smudging together nor leaving the pill empty for long.
        double smoothstep(double from, double to, double x) {
          final u = ((x - from) / (to - from)).clamp(0.0, 1.0);
          return u * u * (3 - 2 * u);
        }

        final modelOpacity = 1 - smoothstep(0.15, 0.55, t);
        final titleOpacity = smoothstep(0.45, 0.85, t);
        final content = ClipRect(
          child: OverflowBox(
            minWidth: 0,
            maxWidth: math.max(modelWidth, titledWidth),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (modelOpacity > 0)
                  Opacity(
                    opacity: modelOpacity,
                    child: Transform.translate(
                      offset: Offset(0, -drift * t),
                      child: modelContent,
                    ),
                  ),
                if (titledContent != null && titleOpacity > 0)
                  Opacity(
                    opacity: titleOpacity,
                    child: Transform.translate(
                      offset: Offset(0, drift * (1 - t)),
                      child: titledContent,
                    ),
                  ),
              ],
            ),
          ),
        );
        return Semantics(
          label: semanticLabel,
          button: true,
          enabled: enabled,
          onTap: enabled ? widget.onPressed : null,
          excludeSemantics: true,
          child: buildConduitAdaptiveToolbarPillSurface(
            width: width,
            height: controlExtent,
            onPressed: enabled ? widget.onPressed : null,
            child: content,
          ),
        );
      },
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
    final controlExtent = conduitScaledControlExtent(context);
    final iconExtent = conduitScaledIconExtent(context, IconSize.appBar);
    final nativeMenuAction = conduitSupportsNativeGlass()
        ? buildConduitNativeToolbarMenuAction<T>(
            iosSymbol: iosIcon,
            accessibilityLabel: MaterialLocalizations.of(context)
                .moreButtonTooltip,
            tintColor: tintColor,
            items: items,
            onSelected: onSelected,
          )
        : null;
    if (nativeMenuAction != null) {
      return ConduitNativeToolbarActionGroup(actions: [nativeMenuAction]);
    }
    if (conduitUsesOpaqueGlassFallback()) {
      return AdaptivePopupMenuButton.widget<T>(
        items: items,
        onSelected: _handleSelected,
        child: SizedBox.square(
          dimension: controlExtent,
          child: FloatingAppBarButton(
            isCircular: true,
            child: ConduitSystemAdaptiveIcon(
              Platform.isIOS ? CupertinoIcons.ellipsis : materialIcon,
              size: iconExtent,
              color: tintColor,
            ),
          ),
        ),
      );
    }

    return _hideNativeToolbarChromeWhileSheetCovered(
      size: Size.square(controlExtent),
      child: AdaptivePopupMenuButton.icon<T>(
        icon: Platform.isIOS ? iosIcon : materialIcon,
        iconColor: tintColor,
        tint: tintColor,
        size: controlExtent,
        buttonStyle: PopupButtonStyle.glass,
        items: items,
        onSelected: _handleSelected,
      ),
    );
  }
}

/// Converts simple adaptive popup entries into one native toolbar menu action.
///
/// Entries with subtitles, images, dividers, non-SF-Symbol icons, or null
/// values keep the package popup fallback because UIKit cannot reproduce those
/// trigger/menu contracts through this compact adapter.
ConduitNativeToolbarAction? buildConduitNativeToolbarMenuAction<T>({
  required String iosSymbol,
  required String accessibilityLabel,
  required Color tintColor,
  required List<AdaptivePopupMenuEntry> items,
  required ValueChanged<T> onSelected,
}) {
  final nativeItems = <ConduitNativeToolbarMenuItem>[];
  for (final entry in items) {
    if (entry is! AdaptivePopupMenuItem<T> ||
        entry.value == null ||
        entry.subtitle?.isNotEmpty == true ||
        entry.imageBytes != null ||
        (entry.icon != null && entry.icon is! String)) {
      return null;
    }
    final value = entry.value as T;
    nativeItems.add(
      ConduitNativeToolbarMenuItem(
        label: entry.label,
        iosSymbol: entry.icon as String?,
        isDestructive: entry.isDestructive,
        isChecked: entry.checked,
        enabled: entry.enabled,
        onSelected: () => onSelected(value),
      ),
    );
  }
  if (nativeItems.isEmpty) return null;

  return ConduitNativeToolbarAction(
    iosSymbol: iosSymbol,
    accessibilityLabel: accessibilityLabel,
    menuItems: nativeItems,
    tintColor: tintColor,
  );
}
