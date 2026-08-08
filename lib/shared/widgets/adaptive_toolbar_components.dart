import 'dart:io' show Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme_extensions.dart';
import '../utils/adaptive_glass.dart';
import 'conduit_components.dart';
import 'conduit_loading.dart';
import 'middle_ellipsis_text.dart';
import 'themed_sheets.dart';

const double kConduitAdaptiveToolbarLeadingGap = Spacing.sm;
const double kConduitAdaptiveToolbarMaxPillWidth = 220;
const double kConduitAdaptiveToolbarMaxModelSelectorWidth = 320;
const double kConduitModelSelectorChevronExtent = 13;
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

  return _hideNativeToolbarChromeWhileSheetCovered(
    size: Size(width, height),
    child: AdaptiveButton.child(
      onPressed: onPressed ?? () {},
      style: AdaptiveButtonStyle.glass,
      size: AdaptiveButtonSize.large,
      padding: EdgeInsets.zero,
      minSize: Size(width, height),
      useSmoothRectangleBorder: false,
      child: sizedChild,
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
final Map<IconData, String> _kConduitToolbarSfSymbolByIcon = {
  CupertinoIcons.line_horizontal_3: 'line.3.horizontal',
  Icons.menu: 'line.3.horizontal',
  CupertinoIcons.chevron_back: 'chevron.left',
  CupertinoIcons.back: 'chevron.left',
  Icons.arrow_back: 'chevron.left',
  CupertinoIcons.create: 'square.and.pencil',
  Icons.add_comment: 'square.and.pencil',
  CupertinoIcons.add: 'plus',
  Icons.add: 'plus',
  CupertinoIcons.eye: 'eye',
  Icons.visibility_outlined: 'eye',
  CupertinoIcons.eye_slash: 'eye.slash',
  Icons.visibility_off: 'eye.slash',
  CupertinoIcons.arrow_down_doc: 'arrow.down.doc',
  Icons.save_alt: 'arrow.down.doc',
  Icons.people_outline: 'person.2',
  Icons.circle: 'circle',
};

String? conduitToolbarSfSymbolForIcon(IconData icon, {String? iosSymbol}) =>
    iosSymbol ?? _kConduitToolbarSfSymbolByIcon[icon];

/// Adaptive floating app-bar icon button for route-level toolbar actions.
class ConduitAdaptiveAppBarIconButton extends StatelessWidget {
  /// Creates an adaptive toolbar icon button.
  const ConduitAdaptiveAppBarIconButton({
    super.key,
    required this.icon,
    this.iosSymbol,
    this.onPressed,
    this.iconColor,
  });

  /// Icon shown inside the control.
  final IconData icon;

  /// Native SF Symbol rendered on iOS 26+.
  final String? iosSymbol;

  /// Invoked when the control is tapped.
  final VoidCallback? onPressed;

  /// Optional icon tint.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
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
              sfSymbol: SFSymbol(nativeSymbol, color: effectiveIconColor),
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

/// Serializes native toolbar actions without leaking their Dart callbacks.
List<Map<String, Object?>> encodeConduitNativeToolbarActions(
  List<ConduitNativeToolbarAction> actions,
) => [
  for (final action in actions)
    <String, Object?>{
      'iosSymbol': action.iosSymbol,
      'accessibilityLabel': action.accessibilityLabel,
      'enabled': action.enabled,
      if (action.tintColor != null) 'tintColor': action.tintColor!.toARGB32(),
      if (action.menuItems.isNotEmpty)
        'menuItems': <Map<String, Object?>>[
          for (final item in action.menuItems)
            <String, Object?>{
              'label': item.label,
              if (item.iosSymbol != null) 'iosSymbol': item.iosSymbol,
              'isDestructive': item.isDestructive,
              'isChecked': item.isChecked,
              'enabled': item.enabled,
            },
        ],
    },
];

/// Builds the native creation payload with navigation-bar optical sizing.
Map<String, Object?> encodeConduitNativeToolbarActionGroupParams(
  List<ConduitNativeToolbarAction> actions,
) => <String, Object?>{'actions': encodeConduitNativeToolbarActions(actions)};

/// A cupertino_native_better toolbar surface for adjacent shared actions.
class ConduitNativeToolbarActionGroup extends StatelessWidget {
  const ConduitNativeToolbarActionGroup({
    super.key,
    required this.actions,
    this.groupDestructiveMenus = false,
  }) : assert(actions.length >= 1 && actions.length <= 3);

  final List<ConduitNativeToolbarAction> actions;

  /// Keeps menu triggers in the same native glass group when their only rich
  /// attribute is a destructive item. The destructive callback and its
  /// confirmation flow are preserved, although CNButtonData.popup does not
  /// expose per-item destructive coloring in package 1.5.4.
  final bool groupDestructiveMenus;

  @override
  Widget build(BuildContext context) {
    final controlExtent = conduitScaledControlExtent(context);
    final width = actions.length == 1
        ? controlExtent
        : (controlExtent * actions.length) +
              (Spacing.sm * (actions.length - 1));
    final size = Size(width, controlExtent);
    final hasRichMenu = actions.any(
      (action) => !_canUseGroupedNativeAction(action),
    );

    Widget controls;
    if (actions.length == 1) {
      controls = _buildAction(actions.single, controlExtent);
    } else if (!hasRichMenu) {
      controls = _buildGlassGroup(actions, controlExtent);
    } else {
      controls = _buildMixedActionCluster(controlExtent);
    }

    return _hideNativeToolbarChromeWhileSheetCovered(
      size: size,
      child: SizedBox.fromSize(size: size, child: controls),
    );
  }

  bool _canUseGroupedNativeAction(ConduitNativeToolbarAction action) {
    if (action.menuItems.isEmpty) return true;

    // CNButtonData.popup cannot represent checked or disabled menu items.
    // Destructive chat actions may opt into the unified group because their
    // callback still routes through Conduit's destructive confirmation flow.
    return action.menuItems.every(
      (item) =>
          item.enabled &&
          !item.isChecked &&
          (groupDestructiveMenus || !item.isDestructive),
    );
  }

  Widget _buildGlassGroup(
    List<ConduitNativeToolbarAction> groupedActions,
    double extent,
  ) {
    return CNGlassButtonGroup(
      spacing: Spacing.sm,
      spacingForGlass: 36,
      buttons: [
        for (final action in groupedActions)
          if (action.menuItems.isEmpty)
            CNButtonData.icon(
              icon: CNSymbol(
                action.iosSymbol,
                size: kCupertinoNativeControlSymbolExtent,
              ),
              onPressed: action.onPressed,
              enabled: action.enabled,
              tint: action.tintColor,
              config: _groupedButtonConfig(extent),
            )
          else
            CNButtonData.popup(
              icon: CNSymbol(
                action.iosSymbol,
                size: kCupertinoNativeControlSymbolExtent,
              ),
              popupItems: [
                for (final item in action.menuItems)
                  CNButtonDataPopupItem(
                    label: item.label,
                    sfSymbol: item.iosSymbol,
                  ),
              ],
              onMenuSelected: (index) {
                if (index >= 0 && index < action.menuItems.length) {
                  action.menuItems[index].onSelected();
                }
              },
              enabled: action.enabled,
              tint: action.tintColor,
              config: _groupedButtonConfig(extent),
            ),
      ],
    );
  }

  CNButtonDataConfig _groupedButtonConfig(double extent) {
    return CNButtonDataConfig(
      width: extent,
      minHeight: extent,
      style: CNButtonStyle.glass,
    );
  }

  Widget _buildMixedActionCluster(double extent) {
    final children = <Widget>[];
    var index = 0;
    while (index < actions.length) {
      final action = actions[index];
      if (!_canUseGroupedNativeAction(action)) {
        children.add(_buildAction(action, extent));
        index += 1;
        continue;
      }

      final run = <ConduitNativeToolbarAction>[];
      while (index < actions.length &&
          _canUseGroupedNativeAction(actions[index])) {
        run.add(actions[index]);
        index += 1;
      }
      children.add(
        run.length > 1
            ? _buildGlassGroup(run, extent)
            : _buildAction(run.single, extent),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (
          var childIndex = 0;
          childIndex < children.length;
          childIndex++
        ) ...[
          if (childIndex > 0) const SizedBox(width: Spacing.sm),
          children[childIndex],
        ],
      ],
    );
  }

  Widget _buildAction(ConduitNativeToolbarAction action, double extent) {
    if (action.menuItems.isEmpty) {
      return CNButton.icon(
        icon: CNSymbol(
          action.iosSymbol,
          size: kCupertinoNativeControlSymbolExtent,
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
      );
    }

    return AdaptivePopupMenuButton.icon<int>(
      icon: action.iosSymbol,
      tint: action.tintColor,
      size: extent,
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
        final selected = entry.value;
        if (selected != null && selected < action.menuItems.length) {
          action.menuItems[selected].onSelected();
        }
      },
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

String _middleEllipsizeConduitNativeModelTitle({
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
    final leadingCount = (visibleCount + 1) >> 1;
    final trailingCount = visibleCount - leadingCount;
    final leading = graphemes.take(leadingCount).toString();
    final trailing = trailingCount == 0
        ? ''
        : graphemes.takeLast(trailingCount).toString();
    final candidate = '$leading$ellipsis$trailing';
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

/// Produces a single-line native button title while retaining both ends of a
/// long model name and reserving the trailing disclosure chevron.
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
  return _middleEllipsizeConduitNativeModelTitle(
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

/// Builds the native model-selector payload without truncating accessibility
/// content that does not participate in UIKit layout measurement.
Map<String, Object?> encodeConduitNativeModelSelectorParams({
  required String label,
  required String? symbolName,
  required Color foregroundColor,
  required double titleFontSize,
  required bool enabled,
}) => <String, Object?>{
  'label': label,
  'symbolName': symbolName,
  'symbolPadding': _kConduitNativeModelChevronPadding,
  'foregroundColor': foregroundColor.toARGB32(),
  'titleFontSize': titleFontSize,
  'enabled': enabled,
};

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

  /// Whether to show the dropdown chevron and allow tapping to change models.
  /// Hidden for single-agent backends (e.g. the Hermes agent) where there is
  /// nothing to pick.
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final effectiveTextStyle =
        textStyle ??
        (PlatformInfo.isIOS
                ? CupertinoTheme.of(context).textTheme.textStyle
                : Theme.of(context).textTheme.titleMedium ??
                      AppTypography.standard)
            .copyWith(
              color: context.conduitTheme.textPrimary,
              fontWeight: FontWeight.w400,
            );
    final safeMaxWidth = maxWidth.clamp(0.0, double.infinity).toDouble();
    if (safeMaxWidth == 0) {
      return const SizedBox.shrink();
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
    const leadingPadding = 10.0;
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
            horizontalPadding: leadingPadding + Spacing.xs + 12,
            // Only reserve chevron space when a chevron is actually rendered.
            trailingWidth: showChevron ? chevronSize + Spacing.xs : 0,
          );
    Widget buildFallbackChild() => SizedBox(
      width: targetWidth,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: controlExtent),
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
                          boundedLabel,
                          style: effectiveTextStyle,
                          textAlign: TextAlign.center,
                          semanticsLabel: label,
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
            accessibilityLabel: MaterialLocalizations.of(
              context,
            ).moreButtonTooltip,
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
