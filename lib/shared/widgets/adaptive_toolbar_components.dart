import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import '../theme/theme_extensions.dart';
import '../utils/adaptive_glass.dart';
import 'conduit_components.dart';
import 'conduit_loading.dart';
import 'middle_ellipsis_text.dart';
import 'themed_sheets.dart';

const double kConduitAdaptiveToolbarLeadingGap = Spacing.sm;
const double kConduitAdaptiveToolbarMaxPillWidth = 220;
const double kConduitMaximumSystemControlScale = 1.5;
const double kConduitNativeToolbarSymbolExtent = 17;
const double kConduitNativeGroupedToolbarSymbolExtent = 20;
const double kConduitNativeUtilitySymbolExtent = 17;
const double kConduitNativePrimarySymbolExtent = 17;
const double kConduitNativeModelChevronExtent = 13;

const double _kConduitNativeButtonHorizontalInsets = 32;
const double _kConduitNativeModelChevronPadding = 6;
const double _kConduitNativeModelChevronReservedWidth =
    kConduitNativeModelChevronExtent + _kConduitNativeModelChevronPadding;
// Flutter and UIKit do not produce perfectly identical SF Pro advances. Keep
// a small optical guard instead of letting UIButton wrap at the measured edge.
const double _kConduitNativeModelTitleWrapGuard = 8;
const int kConduitNativeModelLabelMaxCodeUnits = 256;
const int _kConduitNativeModelLabelPrefixCodeUnits = 160;
const TextStyle _kConduitNativeModelTitleStyle = TextStyle(
  fontSize: 17,
  fontWeight: FontWeight.w600,
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

double conduitScaledIconExtent(BuildContext context, double baseExtent) {
  return baseExtent * conduitSystemControlScaleOf(context);
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
    this.systemOverlayStyle,
  });

  final TextScaler textScaler;
  final Widget leading;
  final Widget? middle;
  final Widget? trailing;
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
          child: Stack(
            fit: StackFit.expand,
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: leading,
              ),
              if (middle != null)
                PositionedDirectional(
                  start: (TouchTarget.minimum * _controlScale) + Spacing.sm,
                  end: (TouchTarget.minimum * _controlScale) + Spacing.sm,
                  top: 0,
                  bottom: 0,
                  child: Center(child: middle),
                ),
              if (trailing != null)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: trailing,
                ),
            ],
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
    iosSymbol: action.iosSymbol,
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

double resolveConduitAdaptiveToolbarLeadingWidth({
  required double pillWidth,
  double leadingGap = kConduitAdaptiveToolbarLeadingGap,
  double controlExtent = TouchTarget.minimum,
}) {
  return Spacing.inputPadding +
      controlExtent +
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
    this.iosSymbolSize = kConduitNativeToolbarSymbolExtent,
  });

  /// Icon shown inside the control.
  final IconData icon;

  /// Native SF Symbol rendered on iOS 26+.
  final String? iosSymbol;

  /// Invoked when the control is tapped.
  final VoidCallback? onPressed;

  /// Optional icon tint.
  final Color? iconColor;

  /// Native SF Symbol point size on iOS 26+.
  final double iosSymbolSize;

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
              sfSymbol: SFSymbol(
                nativeSymbol,
                size: iosSymbolSize,
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
) => <String, Object?>{
  'actions': encodeConduitNativeToolbarActions(actions),
  'symbolSize': kConduitNativeGroupedToolbarSymbolExtent,
};

/// A single native toolbar surface whose adjacent items share Liquid Glass.
///
/// This is intentionally used only for the two-action iOS 26 trailing group.
/// Other action counts and platforms keep their existing Flutter controls.
class ConduitNativeToolbarActionGroup extends StatefulWidget {
  const ConduitNativeToolbarActionGroup({super.key, required this.actions})
    : assert(actions.length == 2);

  final List<ConduitNativeToolbarAction> actions;

  @override
  State<ConduitNativeToolbarActionGroup> createState() =>
      _ConduitNativeToolbarActionGroupState();
}

class _ConduitNativeToolbarActionGroupState
    extends State<ConduitNativeToolbarActionGroup> {
  MethodChannel? _channel;

  Object get _configurationKey => Object.hashAll([
    for (final action in widget.actions) ...[
      action.iosSymbol,
      action.accessibilityLabel,
      action.enabled,
      action.tintColor?.toARGB32(),
      for (final item in action.menuItems) ...[
        item.label,
        item.iosSymbol,
        item.isDestructive,
        item.isChecked,
        item.enabled,
      ],
    ],
  ]);

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map<Object?, Object?>) return;
    final actionIndex = arguments['actionIndex'];
    if (actionIndex is! int ||
        actionIndex < 0 ||
        actionIndex >= widget.actions.length) {
      return;
    }

    final action = widget.actions[actionIndex];
    switch (call.method) {
      case 'actionTapped':
        action.onPressed?.call();
      case 'menuItemSelected':
        final itemIndex = arguments['itemIndex'];
        if (itemIndex is int &&
            itemIndex >= 0 &&
            itemIndex < action.menuItems.length) {
          action.menuItems[itemIndex].onSelected();
        }
    }
  }

  void _onPlatformViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    _channel = MethodChannel(
      'app.cogwheel.conduit/native_toolbar_action_group_$id',
    )..setMethodCallHandler(_handleMethodCall);
  }

  @override
  Widget build(BuildContext context) {
    final controlExtent = conduitScaledControlExtent(context);
    final width = (controlExtent * widget.actions.length) + Spacing.sm;
    final size = Size(width, controlExtent);

    return _hideNativeToolbarChromeWhileSheetCovered(
      size: size,
      child: SizedBox.fromSize(
        size: size,
        child: UiKitView(
          key: ValueKey<Object>(_configurationKey),
          viewType: 'app.cogwheel.conduit/native_toolbar_action_group',
          creationParams: encodeConduitNativeToolbarActionGroupParams(
            widget.actions,
          ),
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        ),
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

/// Forces the package-owned platform view to be recreated when its foreground
/// changes. adaptive_platform_ui 0.1.110 does not synchronize `textColor` from
/// `didUpdateWidget`, so preserving the state would retain the previous theme.
ValueKey<Object> conduitNativeModelSelectorViewKey(
  Color foregroundColor, {
  double titleFontSize = 17,
}) => ValueKey<Object>((foregroundColor.toARGB32(), titleFontSize));

class _ConduitNativeModelSelectorButton extends StatefulWidget {
  const _ConduitNativeModelSelectorButton({
    super.key,
    required this.label,
    required this.symbolName,
    required this.foregroundColor,
    required this.titleFontSize,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final String? symbolName;
  final Color foregroundColor;
  final double titleFontSize;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_ConduitNativeModelSelectorButton> createState() =>
      _ConduitNativeModelSelectorButtonState();
}

class _ConduitNativeModelSelectorButtonState
    extends State<_ConduitNativeModelSelectorButton> {
  MethodChannel? _channel;

  void _handlePlatformViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final channel = MethodChannel(
      'app.cogwheel.conduit/native_model_selector_button_$id',
    );
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'pressed' && widget.enabled) {
        widget.onPressed();
      }
    });
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return UiKitView(
      key: ValueKey<Object>((
        widget.label,
        widget.symbolName,
        widget.foregroundColor.toARGB32(),
        widget.titleFontSize,
        widget.enabled,
      )),
      viewType: 'app.cogwheel.conduit/native_model_selector_button',
      creationParams: <String, Object?>{
        'label': widget.label,
        'symbolName': widget.symbolName,
        'symbolSize': kConduitNativeModelChevronExtent,
        'symbolPadding': _kConduitNativeModelChevronPadding,
        'foregroundColor': widget.foregroundColor.toARGB32(),
        'titleFontSize': widget.titleFontSize,
        'enabled': widget.enabled,
      },
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _handlePlatformViewCreated,
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<TapGestureRecognizer>(() => TapGestureRecognizer()),
      },
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
        textStyle ?? conduitAdaptiveToolbarPillTextStyle(context);
    final safeMaxWidth = maxWidth.clamp(0.0, double.infinity).toDouble();
    if (safeMaxWidth == 0) {
      return const SizedBox.shrink();
    }
    final controlExtent = conduitScaledControlExtent(context);
    final chevronSize = conduitScaledIconExtent(
      context,
      Platform.isIOS ? IconSize.small : IconSize.medium,
    );
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
                          semanticsLabel: boundedLabel,
                          textHeightBehavior: const TextHeightBehavior(
                            applyHeightToFirstAscent: false,
                            applyHeightToLastDescent: false,
                          ),
                        ),
                      ),
                      if (showChevron) ...[
                        const SizedBox(width: Spacing.xs),
                        ConduitSystemAdaptiveIcon(
                          Platform.isIOS
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
        semanticLabel: boundedLabel,
        child: buildFallbackChild(),
      );
    }

    return _hideNativeToolbarChromeWhileSheetCovered(
      size: Size(targetWidth, controlExtent),
      child: usesNativeGlass
          ? Semantics(
              label: boundedLabel,
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
                  titleFontSize: nativeTitleFontSize,
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
