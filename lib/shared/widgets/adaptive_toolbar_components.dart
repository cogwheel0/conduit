import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
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

/// Point size of every glass bar button's SF Symbol. UIKit draws the native
/// glass and plain buttons' symbols at the large scale, so this matches a
/// UIBarButtonItem's glyph on iOS 26 (17 pt, large: the Files bar's "…" is
/// 19.7 pt wide, as ours now is).
const double kConduitNativeSingleActionSymbolExtent = 17;
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

/// The row an iOS 26 navigation bar's controls sit in: a 44 pt glass button
/// starts right at the top safe-area inset and fills the row, as measured on
/// iOS 27's Files, Calendar and Reminders. Material keeps its 48 pt toolbar.
const double kConduitCupertinoToolbarHeight = 44;

double conduitAdaptiveToolbarHeightOf(BuildContext context) {
  final base = context.usesCupertinoChrome
      ? kConduitCupertinoToolbarHeight
      : kTextTabBarHeight;
  return base * conduitSystemControlScaleOf(context);
}

/// The width a route's top bar lays its controls out in: the route's width
/// less the side safe area the bar keeps clear (a notch in landscape, or the
/// status bar strip down iPhone Duo's front display). Material's app bar
/// and [ConduitAdaptiveCupertinoNavigationBar] both inset by it.
double conduitAdaptiveToolbarWidthOf(BuildContext context) {
  final width =
      MediaQuery.sizeOf(context).width -
      MediaQuery.paddingOf(context).horizontal;
  return math.max(0.0, width);
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
    this.blurWhenScrolledUnder = false,
  });

  final TextScaler textScaler;
  final Widget leading;
  final Widget? middle;
  final Widget? trailing;
  final bool centerMiddle;
  final SystemUiOverlayStyle? systemOverlayStyle;

  /// Clear while nothing is under the bar, then a translucent, blurred
  /// background in the page's own tone with a hairline under it once
  /// content scrolls under it, as [CupertinoNavigationBar] does. Off by
  /// default: chat and the sidebar draw their own scroll edges.
  final bool blurWhenScrolledUnder;

  double get _controlScale => resolveConduitSystemControlScale(textScaler);

  @override
  Size get preferredSize =>
      Size.fromHeight(kConduitCupertinoToolbarHeight * _controlScale);

  @override
  bool shouldFullyObstruct(BuildContext context) => false;

  @override
  Widget build(BuildContext context) {
    final safePadding = MediaQuery.paddingOf(context);
    Widget bar = SizedBox(
      height: safePadding.top + preferredSize.height,
      child: Padding(
        // The controls keep clear of a side safe area as well as the top
        // one: a notch in landscape, or the status bar strip down the edge
        // of iPhone Duo's front display.
        padding: EdgeInsets.only(
          top: safePadding.top,
          left: safePadding.left + Spacing.inputPadding,
          right: safePadding.right + Spacing.inputPadding,
        ),
        child: ConduitSystemTextScaling(
          textScaler: textScaler,
          child: CustomMultiChildLayout(
            delegate: _ConduitBarLayout(
              centerMiddle: centerMiddle,
              textDirection: Directionality.of(context),
            ),
            children: [
              LayoutId(
                id: _ConduitBarSlot.leading,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: 1,
                  child: leading,
                ),
              ),
              if (middle != null)
                LayoutId(
                  id: _ConduitBarSlot.middle,
                  child: Align(widthFactor: 1, child: middle),
                ),
              if (trailing != null)
                LayoutId(
                  id: _ConduitBarSlot.trailing,
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    widthFactor: 1,
                    child: trailing,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (blurWhenScrolledUnder) {
      bar = _ConduitScrolledUnderBarBackground(child: bar);
    }
    if (systemOverlayStyle != null) {
      bar = AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemOverlayStyle!,
        child: bar,
      );
    }
    return bar;
  }
}

/// How far content scrolls under the bar before its background is fully
/// in, as in [CupertinoNavigationBar].
const double _kScrolledUnderBackgroundExtent = 10;

/// The background's opacity once fully in: the page's tone, translucent
/// enough that rows under the bar read as a blur rather than being covered.
const double _kScrolledUnderBackgroundAlpha = 0.6;

/// The background's blur once fully in, as in [CupertinoNavigationBar].
const double _kScrolledUnderBackgroundBlurSigma = 10;

/// The background of a [ConduitAdaptiveCupertinoNavigationBar] with
/// [ConduitAdaptiveCupertinoNavigationBar.blurWhenScrolledUnder]. It follows
/// the page's outermost vertical scrolling through the
/// [CupertinoPageScaffold]'s [ScrollNotificationObserver], as
/// [CupertinoNavigationBar] does. The bar's contents keep one place in the
/// tree whether or not the background shows, so native glass buttons are
/// never recreated by a scroll.
class _ConduitScrolledUnderBarBackground extends StatefulWidget {
  const _ConduitScrolledUnderBarBackground({required this.child});

  final Widget child;

  @override
  State<_ConduitScrolledUnderBarBackground> createState() =>
      _ConduitScrolledUnderBarBackgroundState();
}

class _ConduitScrolledUnderBarBackgroundState
    extends State<_ConduitScrolledUnderBarBackground> {
  ScrollNotificationObserverState? _observer;

  /// 0 while nothing is under the bar, 1 once content is
  /// [_kScrolledUnderBackgroundExtent] under it.
  double _progress = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ScrollNotificationObserver.maybeOf(context);
    if (identical(observer, _observer)) return;
    _observer?.removeListener(_handleScrollNotification);
    _observer = observer?..addListener(_handleScrollNotification);
  }

  @override
  void dispose() {
    _observer?.removeListener(_handleScrollNotification);
    super.dispose();
  }

  void _handleScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification || notification.depth != 0) {
      return;
    }
    final metrics = notification.metrics;
    final scrolledUnder = switch (metrics.axisDirection) {
      AxisDirection.down => metrics.extentBefore,
      AxisDirection.up => metrics.extentAfter,
      // Horizontal rows inside the page (chips, carousels) say nothing
      // about what is under the bar.
      AxisDirection.left || AxisDirection.right => null,
    };
    if (scrolledUnder == null) return;
    final progress = (scrolledUnder / _kScrolledUnderBackgroundExtent)
        .clamp(0.0, 1.0)
        .toDouble();
    if (progress != _progress) setState(() => _progress = progress);
  }

  @override
  Widget build(BuildContext context) {
    final pageColor =
        CupertinoPageScaffoldBackgroundColor.maybeOf(context) ??
        CupertinoTheme.of(context).scaffoldBackgroundColor;
    final hairline = CupertinoColors.separator.resolveFrom(context);
    final sigma = _kScrolledUnderBackgroundBlurSigma * _progress;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRect(
              child: BackdropFilter(
                enabled: _progress > 0,
                filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: pageColor.withValues(
                      alpha:
                          pageColor.a *
                          _kScrolledUnderBackgroundAlpha *
                          _progress,
                    ),
                    // One device pixel, as UIKit draws a bar's shadow line.
                    border: Border(
                      bottom: BorderSide(
                        color: hairline.withValues(
                          alpha: hairline.a * _progress,
                        ),
                        width: 1 / MediaQuery.devicePixelRatioOf(context),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

enum _ConduitBarSlot { leading, middle, trailing }

/// [NavigationToolbar]'s layout, with one change: a centred title keeps
/// [kConduitCenteredTitleClearance] from the controls beside it, moving
/// aside as soon as it would come closer rather than only once it would
/// overlap one. The title's room is unchanged, so it is never squeezed;
/// in a bar too tight for the full clearance it keeps the room it has.
class _ConduitBarLayout extends MultiChildLayoutDelegate {
  _ConduitBarLayout({required this.centerMiddle, required this.textDirection});

  final bool centerMiddle;
  final TextDirection textDirection;

  /// The least space between the title and a control, as NavigationToolbar
  /// keeps.
  static const double _minSpacing = kConduitBarTitleGap;

  @override
  void performLayout(Size size) {
    final rtl = textDirection == TextDirection.rtl;
    var leadingWidth = 0.0;
    var trailingWidth = 0.0;
    if (hasChild(_ConduitBarSlot.leading)) {
      leadingWidth = layoutChild(
        _ConduitBarSlot.leading,
        BoxConstraints(
          maxWidth: size.width,
          minHeight: size.height,
          maxHeight: size.height,
        ),
      ).width;
      positionChild(
        _ConduitBarSlot.leading,
        Offset(rtl ? size.width - leadingWidth : 0, 0),
      );
    }
    if (hasChild(_ConduitBarSlot.trailing)) {
      final trailingSize = layoutChild(
        _ConduitBarSlot.trailing,
        BoxConstraints.loose(size),
      );
      trailingWidth = trailingSize.width;
      positionChild(
        _ConduitBarSlot.trailing,
        Offset(
          rtl ? 0 : size.width - trailingWidth,
          (size.height - trailingSize.height) / 2,
        ),
      );
    }
    if (!hasChild(_ConduitBarSlot.middle)) return;
    final maxWidth = math.max(
      0.0,
      size.width - leadingWidth - trailingWidth - _minSpacing * 2,
    );
    final middleSize = layoutChild(
      _ConduitBarSlot.middle,
      BoxConstraints.loose(size).copyWith(maxWidth: maxWidth),
    );
    // Measured from the leading edge.
    final minStart = leadingWidth + _minSpacing;
    final maxStart = math.max(
      minStart,
      size.width - trailingWidth - _minSpacing - middleSize.width,
    );
    var start = minStart;
    if (centerMiddle) {
      start = (size.width - middleSize.width) / 2;
      final clearEnd =
          size.width - trailingWidth - kConduitCenteredTitleClearance;
      final clearStart = leadingWidth + kConduitCenteredTitleClearance;
      if (start + middleSize.width > clearEnd) {
        start = clearEnd - middleSize.width;
      } else if (start < clearStart) {
        start = clearStart;
      }
    }
    start = start.clamp(minStart, maxStart).toDouble();
    positionChild(
      _ConduitBarSlot.middle,
      Offset(
        rtl ? size.width - middleSize.width - start : start,
        (size.height - middleSize.height) / 2,
      ),
    );
  }

  @override
  bool shouldRelayout(_ConduitBarLayout oldDelegate) =>
      oldDelegate.centerMiddle != centerMiddle ||
      oldDelegate.textDirection != textDirection;
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

/// A bar control without its own chrome that dims while pressed, as bar
/// buttons do on iOS.
Widget _toolbarPressable({
  required VoidCallback? onPressed,
  required Size minimumSize,
  BorderRadius? borderRadius,
  required Widget child,
}) {
  return CupertinoButton(
    onPressed: onPressed,
    padding: EdgeInsets.zero,
    minimumSize: minimumSize,
    borderRadius: borderRadius,
    child: child,
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
    content = _toolbarPressable(
      onPressed: onPressed,
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
      conduitAdaptiveToolbarWidthOf(context) -
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
    this.menuEntries = const <AdaptivePopupMenuEntry>[],
    this.onMenuEntrySelected,
    this.tintColor,
    this.enabled = true,
  }) : assert(
         onPressed != null ||
             menuItems.length > 0 ||
             menuEntries.length > 0 ||
             !enabled,
       );

  final String iosSymbol;
  final String accessibilityLabel;
  final VoidCallback? onPressed;
  final List<ConduitNativeToolbarMenuItem> menuItems;

  /// A menu given as the popup's own entries, for one [menuItems] cannot
  /// express (sections, a palette row). [onMenuEntrySelected] gets the
  /// chosen entry.
  final List<AdaptivePopupMenuEntry> menuEntries;
  final ValueChanged<AdaptivePopupMenuItem<Object?>>? onMenuEntrySelected;
  final Color? tintColor;
  final bool enabled;

  /// Whether the action opens a menu rather than acting at once.
  bool get hasMenu => menuItems.isNotEmpty || menuEntries.isNotEmpty;
}

/// [action]'s menu as popup entries: its own [ConduitNativeToolbarAction.
/// menuEntries], or one row per [ConduitNativeToolbarAction.menuItems],
/// valued by its index.
List<AdaptivePopupMenuEntry> _toolbarMenuEntries(
  ConduitNativeToolbarAction action,
) {
  if (action.menuEntries.isNotEmpty) return action.menuEntries;
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

/// Runs what the [entry] chosen from [action]'s menu does.
void _onToolbarMenuSelected(
  ConduitNativeToolbarAction action,
  AdaptivePopupMenuItem<Object?> entry,
) {
  if (!action.enabled) return;
  if (action.menuEntries.isNotEmpty) {
    action.onMenuEntrySelected?.call(entry);
    return;
  }
  final selected = entry.value;
  if (selected is int && selected >= 0 && selected < action.menuItems.length) {
    action.menuItems[selected].onSelected();
  }
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
    // Two or three actions share one glass capsule, as an iOS 26 bar groups
    // them and as the chat header's and sidebar's actions do. The capsule is
    // drawn once with plain glyphs in it: the package's merged
    // CNGlassButtonGroup pinches adjacent buttons into a "dumbbell" on real
    // devices (#686) and cannot express checked or disabled menu rows.
    if (actions.length > 1 && conduitSupportsNativeGlass()) {
      final symbols = <String>{};
      final unique = actions.every((action) => symbols.add(action.iosSymbol));
      final width = conduitToolbarClusterWidth(context, actions.length);
      return _hideNativeToolbarChromeWhileSheetCovered(
        size: Size(width, controlExtent),
        child: ConduitToolbarActionCluster(
          items: [
            for (var index = 0; index < actions.length; index++)
              ConduitToolbarClusterItem(
                id: unique ? actions[index].iosSymbol : index,
                action: actions[index],
              ),
          ],
        ),
      );
    }
    final width = actions.length == 1
        ? controlExtent
        : (controlExtent * actions.length) +
              (Spacing.sm * (actions.length - 1));
    final size = Size(width, controlExtent);

    // Without native glass each action is its own control, matching the
    // leading toolbar button.
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
    if (!action.hasMenu) {
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
      child: AdaptivePopupMenuButton.icon<Object?>(
        icon: action.iosSymbol,
        iconSize: kConduitNativeSingleActionSymbolExtent,
        iconColor: _symbolColor(action),
        tint: action.tintColor,
        size: extent,
        enabled: action.enabled,
        buttonStyle: PopupButtonStyle.glass,
        items: _toolbarMenuEntries(action),
        onSelected: (index, entry) => _onToolbarMenuSelected(action, entry),
      ),
    );
  }
}

/// Width of one action inside a grouped toolbar capsule, as an iOS 26 bar
/// button group spaces its glyphs: measured on iOS 27, Reminders' two-glyph
/// group is 103 pt wide, its glyphs' centres about 24 pt in from the ends
/// and 55 pt apart, and Calendar's three-glyph group is 164 pt.
const double kConduitToolbarClusterSlotExtent = 51.5;

/// Width of a toolbar cluster holding [count] actions: a single action is a
/// circle the size of the leading button; more share one capsule.
double conduitToolbarClusterWidth(BuildContext context, int count) {
  if (count <= 0) return 0;
  if (count == 1) return conduitScaledControlExtent(context);
  return count *
      kConduitToolbarClusterSlotExtent *
      conduitSystemControlScaleOf(context);
}

/// Clear space a centred bar title keeps from the controls beside it, so a
/// title capsule never crowds the glass next to it.
const double kConduitCenteredTitleClearance = 12;

/// The least space between a bar's title (at the leading edge or centred)
/// and the controls beside it.
const double kConduitBarTitleGap = Spacing.sm;

/// One action of a [ConduitToolbarActionCluster].
@immutable
class ConduitToolbarClusterItem {
  const ConduitToolbarClusterItem({
    required this.id,
    required this.action,
    this.fallbackIcon,
  });

  /// Identifies the action across rebuilds, so a change of the cluster's
  /// actions fades out only those that leave and fades in only those that
  /// arrive.
  final Object id;

  final ConduitNativeToolbarAction action;

  /// Glyph drawn where the platform has no native glass controls.
  final IconData? fallbackIcon;
}

/// The critically damped spring every bar reshape rides (the trailing glass
/// and the title pill): done to the eye in about 200 ms, settled in 270.
final SpringDescription kConduitBarMorphSpring =
    SpringDescription.withDampingRatio(mass: 1, stiffness: 600, ratio: 1);

/// The most one frame may advance a bar morph's springs, in seconds: a long
/// frame (a send, or creating native views, stalls one) slows the morph for
/// a moment rather than skipping it.
const double _kBarMaxStep = 1 / 30;

/// Share of a change over which a leaving glyph fades out and shrinks: it
/// holds on while the glass opens, until a glyph arriving elsewhere is
/// coming in, so the glass is never empty.
const double _kClusterDepartureStart = 0.25;
const double _kClusterDepartureEnd = 0.55;

/// How much faster the glass reshapes than the glyphs change over: it opens
/// first, so a glyph arriving at its far end has its place in the glass
/// before it shows.
const double _kClusterGlassLead = 2;

/// Points of glass past a glyph's ink over which the glyph comes in (or
/// goes, as the glass closes over it).
const double _kClusterCoverRamp = 6;

/// Share of a change over which an arriving glyph fades in and grows. It
/// overlaps the departures, held back by any leaving glyph it overlaps (see
/// [_ConduitToolbarActionClusterState._layOut]), so the glass never shows
/// empty and the two never show at once; its native control has had a
/// frame or two to come up by the time it shows.
const double _kClusterArrivalStart = 0.1;
const double _kClusterArrivalEnd = 0.65;

/// The scale a glyph leaves at and arrives from, as SF Symbols' replace
/// transition draws it.
const double _kClusterGlyphMinScale = 0.8;

/// About the widest a bar glyph draws (square.and.pencil, 17 pt, large
/// scale): two glyphs nearer than this overlap.
const double _kClusterGlyphExtent = 22;

/// Two glyphs nearer than this stand in one spot: one swapped for the other
/// in place, which must clear before the other shows.
const double _kClusterSameSpot = 0.25 * _kClusterGlyphExtent;

double _clusterEase(double from, double to, double x) =>
    _smoothstep(from, to, x);

/// Critically damped spring stepped by hand, so several values can share one
/// ticker and each can be retargeted from its current value and velocity.
class _BarSpring {
  _BarSpring(this.value, {required this.tolerance}) : target = value;

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

/// Where a glyph rests in the glass: a fixed distance from the glass's
/// trailing or leading end, or on its centre line, resolved against a width
/// of the glass (the finished one, for a glyph coming or going).
@immutable
class _ClusterAnchor {
  const _ClusterAnchor._(this.edge, this.inset);

  const _ClusterAnchor.centre() : this._(0, 0);

  /// The anchor of action [index] of [count] in glass of [slot]-wide slots.
  factory _ClusterAnchor.forSlot(int index, int count, double slot) {
    if (count <= 1) return const _ClusterAnchor.centre();
    final width = count * slot;
    final fromTrailing = (count - index - 0.5) * slot;
    if ((fromTrailing - width / 2).abs() < 0.5) {
      return const _ClusterAnchor.centre();
    }
    return fromTrailing < width / 2
        ? _ClusterAnchor._(-1, fromTrailing)
        : _ClusterAnchor._(1, width - fromTrailing);
  }

  /// -1 for the trailing end, 1 for the leading end, 0 for the centre.
  final int edge;
  final double inset;

  /// Distance from the trailing end of glass [width] wide to the centre.
  double resolve(double width) => switch (edge) {
    0 => width / 2,
    < 0 => inset,
    _ => width - inset,
  };
}

class _ClusterEntry {
  _ClusterEntry(
    this.item,
    this.anchor, {
    required this.arrives,
    required this.opacity,
    required this.scale,
  }) : fromOpacity = opacity,
       fromScale = scale;

  ConduitToolbarClusterItem item;
  _ClusterAnchor anchor;

  /// Whether the action left in the latest change.
  bool leaving = false;

  /// Whether the action came in, from nothing, in the latest change.
  bool arrives;

  /// For an arriving glyph that waited for a leaving one in its very spot,
  /// the change's progress at which that one was gone and it set out.
  double? setsOutAt;

  /// The glyph's centre, opacity and scale when the latest change began.
  double? fromCentre;
  double fromOpacity;
  double fromScale;

  /// This frame's centre (from the glass's trailing end), opacity and scale.
  double centre = 0;
  double opacity;
  double scale;
}

/// Trailing toolbar actions grouped on one Liquid Glass surface, the way an
/// iOS 26 navigation bar groups its bar button items: one action is a
/// circle, two or three share one capsule with plain glyphs inside.
///
/// The surface is a single glass shape rather than merged per-button glass,
/// which pinches into a "dumbbell" between buttons on device (#686).
///
/// When the set of actions changes (a new chat becoming a real one), the
/// glass reshapes and the glyphs change over in one step, on critically
/// damped springs ([kConduitBarMorphSpring]): the glass opens (or closes)
/// first, the leaving glyphs fade and shrink away where they stand, and the
/// arriving ones grow in where they will rest, each only once the glass
/// covers it. So no glyph ever shows outside the glass, no two that show are
/// ever nearer than in the finished glass, the glass never shows empty, and
/// an arriving glyph shows in a leaving one's spot only as that one clears.
/// A change mid-way starts again from what is on screen. Reduce Motion
/// reshapes at once and dissolves the glyphs, the old ones out before the
/// new ones in.
///
/// The capsule is anchored at its trailing edge, so it grows and shrinks
/// toward the title.
class ConduitToolbarActionCluster extends StatefulWidget {
  const ConduitToolbarActionCluster({super.key, required this.items})
    : assert(items.length <= 3);

  final List<ConduitToolbarClusterItem> items;

  /// The angular frequency of [kConduitBarMorphSpring].
  static final double springOmega = math.sqrt(
    kConduitBarMorphSpring.stiffness / kConduitBarMorphSpring.mass,
  );

  @override
  State<ConduitToolbarActionCluster> createState() =>
      _ConduitToolbarActionClusterState();
}

class _ConduitToolbarActionClusterState
    extends State<ConduitToolbarActionCluster>
    with SingleTickerProviderStateMixin {
  final Map<Object, _ClusterEntry> _entries = <Object, _ClusterEntry>{};
  late final _BarSpring _width = _BarSpring(0, tolerance: 0.25);

  /// How far the latest change has come, from 0 to 1; it times the glyphs'
  /// fades, and the moving ones' paths, against the glass's reshape.
  late final _BarSpring _phase = _BarSpring(1, tolerance: 0.002);
  late final Ticker _ticker = createTicker(_onTick);
  Duration? _lastTick;
  bool _initialized = false;
  List<Object> _ids = const <Object>[];
  double _controlScale = 1;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The first layout and a Dynamic Type change place everything at rest:
    // only a change of actions animates.
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

  double get _slot =>
      kConduitToolbarClusterSlotExtent * conduitSystemControlScaleOf(context);

  void _sync({required bool animate}) {
    final items = widget.items;
    final ids = [for (final item in items) item.id];
    final controlScale = conduitSystemControlScaleOf(context);
    final reshaped = controlScale != _controlScale;
    final changed = !listEquals(ids, _ids);
    _ids = ids;
    _controlScale = controlScale;
    _reduceMotion = context.reduceMotion;
    _width.target = conduitToolbarClusterWidth(context, items.length);

    if (!changed || !animate) {
      if (!animate) _entries.clear();
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final anchor = _ClusterAnchor.forSlot(index, items.length, _slot);
        final entry = _entries[item.id];
        if (entry == null) {
          _entries[item.id] = _ClusterEntry(
            item,
            anchor,
            arrives: false,
            opacity: 1,
            scale: 1,
          );
        } else {
          entry
            ..item = item
            ..anchor = anchor;
        }
      }
      if (!animate || reshaped) {
        _width.snap();
        _phase.snap();
        for (final entry in _entries.values) {
          entry
            ..fromCentre = null
            ..arrives = false
            ..opacity = 1
            ..scale = 1;
        }
        _entries.removeWhere((_, entry) => entry.leaving);
      }
      _layOut();
      _startIfNeeded();
      return;
    }

    // A change of actions: everything starts from where it shows now.
    for (final entry in _entries.values) {
      entry
        ..fromCentre = entry.centre
        ..fromOpacity = entry.opacity
        ..fromScale = entry.scale
        ..arrives = false
        ..setsOutAt = null
        ..leaving = true;
    }
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final anchor = _ClusterAnchor.forSlot(index, items.length, _slot);
      final entry = _entries[item.id];
      if (entry == null) {
        _entries[item.id] = _ClusterEntry(
          item,
          anchor,
          arrives: true,
          opacity: 0,
          scale: _kClusterGlyphMinScale,
        );
      } else {
        entry
          ..item = item
          ..anchor = anchor
          ..leaving = false;
      }
    }
    _phase
      ..value = 0
      ..velocity = 0
      ..target = 1;
    if (_reduceMotion) _width.snap();
    _layOut();
    _startIfNeeded();
  }

  /// Places, fades and scales every glyph for the glass's width and the
  /// change's progress of this frame.
  void _layOut() {
    final width = math.max(0.0, _width.value);
    final finalWidth = math.max(0.0, _width.target);
    final phase = _phase.value.clamp(0.0, 1.0).toDouble();
    final reduceMotion = _reduceMotion;
    final departure = _clusterEase(
      reduceMotion ? 0 : _kClusterDepartureStart,
      _kClusterDepartureEnd,
      phase,
    );
    // Under Reduce Motion the new glyphs wait for the old ones to be gone.
    final arrivalStart = reduceMotion
        ? _kClusterDepartureEnd
        : _kClusterArrivalStart;
    final arrivalEnd = reduceMotion ? 1.0 : _kClusterArrivalEnd;
    double arrivalOf(_ClusterEntry entry) {
      final start = math.max(arrivalStart, entry.setsOutAt ?? 0);
      return _clusterEase(start, math.max(arrivalEnd, start + 0.25), phase);
    }

    final settle = _clusterEase(
      0,
      _kClusterArrivalEnd - _kClusterArrivalStart,
      phase,
    );

    for (final entry in _entries.values) {
      // Every glyph heads for (or keeps) its place in the finished glass,
      // measured from the trailing end the glass grows from: arriving ones
      // stand there from the start, leaving ones stay where they were, so no
      // two ever draw nearer than the finished spacing, and the reshaping
      // glass shows each one only where it covers it (see [cover] below).
      final resting = entry.anchor.resolve(finalWidth);
      final from = entry.fromCentre;
      if (entry.leaving) {
        entry
          ..centre = from ?? entry.anchor.resolve(width)
          ..opacity = entry.fromOpacity * (1 - departure)
          ..scale = reduceMotion
              ? entry.fromScale
              : lerpDouble(entry.fromScale, _kClusterGlyphMinScale, departure)!;
      } else if (entry.arrives) {
        entry.centre = resting;
      } else {
        entry
          ..centre = reduceMotion || from == null
              ? resting
              : lerpDouble(from, resting, phase)!
          ..opacity = entry.fromOpacity + (1 - entry.fromOpacity) * settle
          ..scale = lerpDouble(entry.fromScale, 1, settle)!;
      }
    }
    // An arriving glyph gives way to a leaving one it overlaps, so together
    // they never show more than one glyph's worth of ink there; one swapped
    // in the very spot of a leaving glyph sets out only once that is gone.
    final controlScale = conduitSystemControlScaleOf(context);
    final apart = _kClusterGlyphExtent * controlScale;
    final sameSpot = _kClusterSameSpot * controlScale;
    for (final entry in _entries.values) {
      if (!entry.arrives) continue;
      var clearing = 0.0;
      var waits = false;
      for (final other in _entries.values) {
        if (!other.leaving) continue;
        final distance = (other.centre - entry.centre).abs();
        if (distance >= apart) continue;
        clearing = math.max(clearing, other.opacity);
        if (distance < sameSpot && other.opacity > 0.001) waits = true;
      }
      if (waits) {
        entry
          ..setsOutAt = phase
          ..opacity = 0
          ..scale = reduceMotion ? 1 : _kClusterGlyphMinScale;
        continue;
      }
      final arrival = arrivalOf(entry);
      entry
        ..opacity = arrival * (1 - clearing)
        ..scale = reduceMotion
            ? 1
            : lerpDouble(_kClusterGlyphMinScale, 1, arrival)!;
    }
    // A glyph shows only where the glass covers all of its ink: the opening
    // glass brings the far one in, a closing one takes it away.
    final half = _kClusterGlyphExtent * controlScale / 2;
    for (final entry in _entries.values) {
      final inner = entry.centre + half;
      final cover = _clusterEase(inner, inner + _kClusterCoverRamp, width);
      if (cover < 1) entry.opacity *= cover;
    }
  }

  bool get _isSettled => _width.isSettled && _phase.isSettled;

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
      _kBarMaxStep,
    );
    final omega = ConduitToolbarActionCluster.springOmega;
    _width.step(seconds, omega * _kClusterGlassLead);
    _phase.step(seconds, omega);
    _layOut();
    _entries.removeWhere(
      (_, entry) =>
          entry.leaving &&
          (_phase.isSettled || (entry.opacity <= 0.001 && _phase.value > 0)),
    );
    if (_isSettled) {
      for (final entry in _entries.values) {
        entry
          ..arrives = false
          ..setsOutAt = null
          ..fromCentre = null
          ..fromOpacity = 1
          ..fromScale = 1
          ..opacity = 1
          ..scale = 1;
      }
      _ticker.stop();
    }
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
      final opacity = entry.opacity.clamp(0.0, 1.0).toDouble();
      if (opacity <= 0 && entry.leaving) continue;
      final child = _buildAction(entry.item, height, usesNativeGlass);
      children.add(
        Positioned(
          key: ValueKey<Object>(entry.item.id),
          right: entry.centre - height / 2,
          top: 0,
          width: height,
          height: height,
          child: IgnorePointer(
            ignoring: entry.leaving,
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(scale: entry.scale, child: child),
            ),
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
    if (!action.hasMenu) {
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
    return AdaptivePopupMenuButton.icon<Object?>(
      icon: action.iosSymbol,
      semanticLabel: action.accessibilityLabel,
      iconSize: kConduitNativeSingleActionSymbolExtent,
      iconColor: color,
      tint: action.tintColor,
      size: extent,
      enabled: action.enabled,
      buttonStyle: PopupButtonStyle.plain,
      items: _toolbarMenuEntries(action),
      onSelected: (index, entry) => _onToolbarMenuSelected(action, entry),
    );
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
    if (action.hasMenu) {
      return Semantics(
        label: action.accessibilityLabel,
        button: true,
        enabled: action.enabled,
        excludeSemantics: true,
        child: IgnorePointer(
          ignoring: !action.enabled,
          child: AdaptivePopupMenuButton.widget<Object?>(
            items: _toolbarMenuEntries(action),
            onSelected: (index, entry) => _onToolbarMenuSelected(action, entry),
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
      child: _toolbarPressable(
        onPressed: action.enabled ? action.onPressed : null,
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
/// The change is one continuous step on [kConduitBarMorphSpring], started
/// from the current value and velocity, so a scroll that flips back mid-way
/// reverses it without a jump. The model line never leaves: it shrinks into
/// the subtitle's place, ahead of the capsule, while the title grows in above
/// it with the capsule, always as large as the capsule holds it (see
/// [ConduitTitledPillMotion]), so no frame shows a clipped glyph, two lines
/// over each other, or a wide pill waiting for its title. Reduce Motion
/// resizes the capsule and dissolves between the two states.
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

const double _kConduitTitledPillInset = 14;

double _smoothstep(double from, double to, double x) {
  if (x <= from) return 0;
  if (x >= to) return 1;
  final u = (x - from) / (to - from);
  return u * u * (3 - 2 * u);
}

/// Where the titled pill's parts are at value `t` of its spring, from 0 (the
/// model alone) to 1 (the title over the model); a pure function of `t`, so
/// a change reversed mid-way retraces the same frames.
///
/// The capsule's width rides the spring. The model line becomes the
/// subtitle over the first part of it ([modelMorphAt]), so it clears the
/// title's line early. The title grows in with the capsule: it is drawn as
/// large as the capsule holds it with [roundedEndClearance] to spare at each
/// end, up to full size, and fades in from the moment that is at least
/// [revealScale] and the dropping model line has cleared its line
/// ([linesClearAt]). So the pill changes in one continuous step: never a wide
/// capsule waiting for its title, never a title outside the capsule. Going
/// back retraces the same frames.
@visibleForTesting
@immutable
class ConduitTitledPillMotion {
  const ConduitTitledPillMotion({
    required this.modelWidth,
    required this.titledWidth,
    required this.titleWidth,
    this.linesClearAt = 0.3,
    this.reduceMotion = false,
  });

  /// The title is never drawn smaller than this.
  static const double minTitleScale = 0.6;

  /// The title starts to show once the capsule holds it at this scale; above
  /// [minTitleScale], so a title that shows always fits.
  static const double revealScale = 0.65;

  /// Room kept between the title and each end of the capsule, past the
  /// curve of its rounded ends at the title's line.
  static const double roundedEndClearance = 10;

  /// Share of the change over which the model line becomes the subtitle.
  static const double modelMorphEnd = 0.6;

  /// Share of the change the title's fade takes.
  static const double revealSpan = 0.4;

  /// Width of the capsule with the model alone.
  final double modelWidth;

  /// Width of the capsule with the title over the model.
  final double titledWidth;

  /// Width of the title's text at full size.
  final double titleWidth;

  /// Spring value from which the dropping model line no longer reaches the
  /// title's line.
  final double linesClearAt;

  /// Whether to dissolve between the two states instead of morphing.
  final bool reduceMotion;

  /// Under Reduce Motion the capsule resizes while the model fades out,
  /// before the title and subtitle fade in.
  static const double _reducedResizeEnd = 0.45;
  static const double _reducedRevealStart = 0.55;

  double _widthProgress(double t) => reduceMotion
      ? _smoothstep(0, _reducedResizeEnd, t)
      : t.clamp(0.0, 1.0).toDouble();

  /// The capsule's width at [t].
  double widthAt(double t) =>
      lerpDouble(modelWidth, titledWidth, _widthProgress(t))!;

  double get _fitInset => math.max(
    0.0,
    math.min(roundedEndClearance, (titledWidth - titleWidth) / 2),
  );

  /// The largest scale at which the title fits the capsule at [t].
  double fitScaleAt(double t) =>
      titleWidth <= 0 ? 1 : (widthAt(t) - 2 * _fitInset) / titleWidth;

  /// The spring value from which the capsule holds the title at
  /// [revealScale].
  double get _fitsFrom {
    final needed = revealScale * titleWidth + 2 * _fitInset;
    if (needed <= modelWidth) return 0;
    final growth = titledWidth - modelWidth;
    if (growth <= 0) return 1;
    return ((needed - modelWidth) / growth).clamp(0.0, 1.0).toDouble();
  }

  /// The spring value at which the title starts to show.
  double get revealStart {
    if (reduceMotion) return _reducedRevealStart;
    return math.max(_fitsFrom, linesClearAt.clamp(0.0, 1.0).toDouble());
  }

  /// The spring value at which the title is fully shown.
  double get revealEnd =>
      reduceMotion ? 1 : math.min(1.0, revealStart + revealSpan);

  /// The title's opacity at [t].
  double titleOpacityAt(double t) {
    final start = revealStart;
    final end = revealEnd;
    if (end <= start) return t >= end ? 1 : 0;
    return _smoothstep(start, end, t);
  }

  /// The title's scale at [t]: as large as the capsule holds it, up to full
  /// size.
  double titleScaleAt(double t) =>
      reduceMotion ? 1 : fitScaleAt(t).clamp(minTitleScale, 1.0).toDouble();

  /// How far the model line has turned into the subtitle at [t]; under
  /// Reduce Motion it does not move, but dissolves (see [modelOpacityAt]).
  double modelMorphAt(double t) =>
      reduceMotion ? 0 : _smoothstep(0, modelMorphEnd, t);

  /// The centred model line's opacity at [t]. Without Reduce Motion it is
  /// the subtitle itself and never fades.
  double modelOpacityAt(double t) =>
      reduceMotion ? 1 - _smoothstep(0, _reducedResizeEnd, t) : 1;

  /// Under Reduce Motion, the subtitle's opacity at [t]; it fades in with
  /// the title.
  double subtitleOpacityAt(double t) =>
      reduceMotion ? _smoothstep(_reducedRevealStart, 1, t) : 0;
}

const double _kConduitTitledPillTitleSize = 15;

/// The smallest the title is set to fit a long name before it truncates.
const double _kConduitTitledPillMinTitleSize = 13;
const double _kConduitTitledPillTitleSizeStep = 0.5;
const double _kConduitTitledPillSubtitleSize = 12;
const double _kConduitTitledPillSubtitleChevron = 9;

/// Apple's tracking for SF Pro Text at [fontSize] points: open below 12 pt,
/// tightening as the text grows (the values iOS's text styles use).
@visibleForTesting
double conduitSystemTextTracking(double fontSize) {
  const table = <(double, double)>[
    (11, 0.06),
    (12, 0),
    (13, -0.08),
    (14, -0.15),
    (15, -0.23),
    (16, -0.31),
    (17, -0.43),
    (20, -0.45),
  ];
  if (fontSize <= table.first.$1) return table.first.$2;
  for (var i = 1; i < table.length; i++) {
    final (size, tracking) = table[i];
    if (fontSize <= size) {
      final (previousSize, previousTracking) = table[i - 1];
      final t = (fontSize - previousSize) / (size - previousSize);
      return lerpDouble(previousTracking, tracking, t)!;
    }
  }
  return table.last.$2;
}

/// Characters a title should not end on before an ellipsis.
const String _kConduitTruncationTrailingMarks = ',;:-\u2013\u2014(/&\u00b7';

/// [text] shortened to fit [maxWidth], as [measure] lays it out, with an
/// ellipsis after the last whole word that fits ("Sourdough starter…"
/// rather than "Sourdough starter s…").
///
/// Falls back to cutting between characters when there is no word break
/// (a long single word, or a script written without spaces), or when the
/// whole words would leave much less than a character cut keeps.
@visibleForTesting
String conduitTruncateAtWordBoundary(
  String text, {
  required double maxWidth,
  required double Function(String text) measure,
}) {
  if (text.isEmpty || measure(text) <= maxWidth) return text;
  const ellipsis = '\u2026';
  final chars = text.characters.toList();
  bool isSpace(String c) => c.trim().isEmpty;
  String cut(int count) {
    var prefix = chars.take(count).join().trimRight();
    while (prefix.isNotEmpty &&
        _kConduitTruncationTrailingMarks.contains(prefix.characters.last)) {
      prefix = prefix.characters.skipLast(1).toString().trimRight();
    }
    return prefix.isEmpty ? '' : '$prefix$ellipsis';
  }

  // The longest of [ends] (ascending prefix lengths) whose cut fits.
  String? longestFitting(List<int> ends) {
    String? best;
    var lo = 0;
    var hi = ends.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final candidate = cut(ends[mid]);
      if (candidate.isNotEmpty && measure(candidate) <= maxWidth) {
        best = candidate;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  final wordEnds = <int>[
    for (var i = 1; i < chars.length; i++)
      if (isSpace(chars[i]) && !isSpace(chars[i - 1])) i,
  ];
  final byWord = longestFitting(wordEnds);
  final byCharacter = longestFitting([
    for (var i = 1; i < chars.length; i++) i,
  ]);
  if (byWord != null &&
      (byCharacter == null || measure(byWord) >= 0.5 * measure(byCharacter))) {
    return byWord;
  }
  return byCharacter ?? ellipsis;
}

/// The titled pill's title line at [size] points: semibold, with the system
/// tracking for that size.
TextStyle _titledPillTitleStyle(TextStyle base, double size) => base.copyWith(
  fontSize: size,
  fontWeight: FontWeight.w600,
  letterSpacing: conduitSystemTextTracking(size),
  height: 1.2,
);

/// Bar titles stop growing with Dynamic Type well before body text does, as
/// UIKit's inline navigation titles do, so two lines still fit the pill and
/// a centred pill at large sizes still has room for whole words.
const double _kConduitTitledPillMaxTextScale = 1.2;

class _ConduitTitledModelSelectorState
    extends State<_ConduitTitledModelSelector>
    with SingleTickerProviderStateMixin {
  /// The spring's value, from 0 (the model alone) to 1 (the title over
  /// it), stepped by hand like the trailing glass's, so a long frame slows
  /// the change instead of skipping it.
  late final _BarSpring _spring = _BarSpring(
    _wantsTitle ? 1 : 0,
    tolerance: 0.001,
  );
  late final ValueNotifier<double> _progress = ValueNotifier<double>(
    _spring.value,
  );
  late final Ticker _ticker = createTicker(_onTick);
  Duration? _lastTick;
  late double _target = _spring.value;

  /// Under Reduce Motion the change is a 200 ms ease instead of the spring.
  static const double _reducedSeconds = 0.2;
  bool _reduced = false;
  double _reducedFrom = 0;
  double _reducedElapsed = 0;

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
    _ticker.dispose();
    _progress.dispose();
    super.dispose();
  }

  void _syncTarget() {
    if (!mounted) return;
    final target = _wantsTitle ? 1.0 : 0.0;
    if (target == _target) return;
    _target = target;
    _reduced = context.reduceMotion;
    if (_reduced) {
      _reducedFrom = _spring.value;
      _reducedElapsed = 0;
    }
    // Retargeted from the current value and velocity: no jump on a
    // reversal mid-way.
    _spring.target = target;
    if (!_ticker.isActive) {
      _lastTick = null;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final last = _lastTick;
    _lastTick = elapsed;
    if (last == null) return;
    final seconds = math.min(
      (elapsed - last).inMicroseconds / Duration.microsecondsPerSecond,
      _kBarMaxStep,
    );
    if (_reduced) {
      _reducedElapsed += seconds;
      final progress = (_reducedElapsed / _reducedSeconds).clamp(0.0, 1.0);
      _spring
        ..value = lerpDouble(
          _reducedFrom,
          _target,
          Curves.easeInOut.transform(progress),
        )!
        ..velocity = 0;
      if (progress >= 1) _spring.snap();
    } else {
      _spring.step(seconds, ConduitToolbarActionCluster.springOmega);
    }
    _progress.value = _spring.value;
    if (_spring.isSettled) {
      _spring.snap();
      _progress.value = _spring.value;
      _ticker.stop();
    }
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

  double _textHeight(
    String text,
    TextStyle style,
    TextScaler scaler, {
    TextHeightBehavior? textHeightBehavior,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textScaler: scaler,
      textHeightBehavior: textHeightBehavior,
      textDirection: Directionality.of(context),
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  ({String text, double size, double width})? _fittedTitle;
  Object? _fittedTitleKey;

  /// The title as the pill sets it within [available]: at 15 pt when it
  /// fits; else as large as lets the whole title fit, down to 13 pt; and
  /// when no size does, cut after its last whole word that fits, at the
  /// size that keeps the most of it (the larger on a tie).
  ({String text, double size, double width}) _fitTitle(
    String title,
    TextStyle baseStyle,
    TextScaler scaler,
    bool boldText,
    double available,
  ) {
    final key = (title, baseStyle, scaler, boldText, available);
    if (_fittedTitle case final fitted? when _fittedTitleKey == key) {
      return fitted;
    }
    TextStyle styleAt(double size) {
      final style = _titledPillTitleStyle(baseStyle, size);
      return boldText ? style.copyWith(fontWeight: FontWeight.w700) : style;
    }

    final sizes = <double>[
      for (
        var size = _kConduitTitledPillTitleSize;
        size >= _kConduitTitledPillMinTitleSize - 1e-6;
        size -= _kConduitTitledPillTitleSizeStep
      )
        size,
    ];
    ({String text, double size, double width})? fitted;
    for (final size in sizes) {
      final width = _textWidth(title, styleAt(size), scaler);
      if (width <= available) {
        fitted = (text: title, size: size, width: width);
        break;
      }
    }
    if (fitted == null) {
      var bestScore = (-1, -1);
      for (final size in sizes) {
        final style = styleAt(size);
        // A point of guard: the cut must not meet Text's own ellipsis.
        final text = conduitTruncateAtWordBoundary(
          title,
          maxWidth: math.max(0.0, available - 1),
          measure: (candidate) => _textWidth(candidate, style, scaler),
        );
        final kept = text.endsWith('\u2026')
            ? text.substring(0, text.length - 1)
            : text;
        final rest = title.startsWith(kept) ? title.substring(kept.length) : '';
        final atWord =
            rest.isEmpty ||
            rest.trimLeft().length != rest.length ||
            _kConduitTruncationTrailingMarks.contains(rest[0]);
        final score = (atWord ? 1 : 0, kept.length);
        if (score.$1 > bestScore.$1 ||
            (score.$1 == bestScore.$1 && score.$2 > bestScore.$2)) {
          bestScore = score;
          fitted = (
            text: text,
            size: size,
            width: _textWidth(text, style, scaler),
          );
        }
      }
    }
    final result = fitted!;
    _fittedTitle = result;
    _fittedTitleKey = key;
    return result;
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
    // Bold Text sets every Text bold; measure what will be drawn.
    final boldText = MediaQuery.boldTextOf(context);
    TextStyle drawn(TextStyle style) =>
        boldText ? style.copyWith(fontWeight: FontWeight.w700) : style;
    final subtitleStyle = widget.labelStyle.copyWith(
      fontSize: _kConduitTitledPillSubtitleSize,
      letterSpacing: conduitSystemTextTracking(_kConduitTitledPillSubtitleSize),
      color: theme.textSecondary,
      height: 1.2,
    );
    final chevronIcon = PlatformInfo.isIOS
        ? CupertinoIcons.chevron_down
        : Icons.keyboard_arrow_down;
    final rawTitle = widget.title?.trim() ?? '';
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
    final fittedTitle = rawTitle.isEmpty
        ? null
        : _fitTitle(
            rawTitle,
            widget.labelStyle,
            titleScaler,
            boldText,
            math.max(0.0, widget.maxWidth - _kConduitTitledPillInset * 2),
          );
    final title = fittedTitle?.text ?? '';
    final titleStyle = _titledPillTitleStyle(
      widget.labelStyle,
      fittedTitle?.size ?? _kConduitTitledPillTitleSize,
    );
    final titledWidth = fittedTitle == null
        ? modelWidth
        : clampWidth(
            math.max(
                  fittedTitle.width,
                  _textWidth(widget.label, drawn(subtitleStyle), titleScaler) +
                      (showChevron
                          ? _kConduitTitledPillSubtitleChevron + 3
                          : 0),
                ) +
                _kConduitTitledPillInset * 2,
          );

    double chevronGapAt(double size) => size < 12 ? 3.0 : 6.0;
    Widget line(
      String text,
      TextStyle style,
      double chevronSize, {
      TextScaler? textScaler,
      double? chevronGap,
    }) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            text,
            style: style,
            textScaler: textScaler,
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
          SizedBox(width: chevronGap ?? chevronGapAt(chevronSize)),
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

    // Vertical places. The titled pill stacks the title over the subtitle,
    // centred as one block; the model alone sits on the centre line.
    const noLeading = TextHeightBehavior(
      applyHeightToFirstAscent: false,
      applyHeightToLastDescent: false,
    );
    final modelFontSize = scaler.scale(labelStyle.fontSize!);
    final subtitleFontSize = titleScaler.scale(_kConduitTitledPillSubtitleSize);
    final modelLineHeight = _textHeight(
      widget.label,
      labelStyle,
      scaler,
      textHeightBehavior: noLeading,
    );
    final subtitleLineHeight = _textHeight(
      widget.label,
      subtitleStyle,
      titleScaler,
      textHeightBehavior: noLeading,
    );
    final titleLineHeight = title.isEmpty
        ? 0.0
        : _textHeight(title, titleStyle, titleScaler);
    final blockTop =
        (controlExtent - (titleLineHeight + 1 + subtitleLineHeight)) / 2;
    final centreY = controlExtent / 2;
    final titleCentreY = blockTop + titleLineHeight / 2;
    final subtitleCentreY =
        blockTop + titleLineHeight + 1 + subtitleLineHeight / 2;

    final reduceMotion = context.reduceMotion;
    final shape = ConduitTitledPillMotion(
      modelWidth: modelWidth,
      titledWidth: titledWidth,
      titleWidth: fittedTitle?.width ?? 0,
      reduceMotion: reduceMotion,
    );

    // The spring value from which the dropping model line's cap height stays
    // below the title line's descenders, the title drawn at its scale then.
    double linesClearAt() {
      const steps = 100;
      for (var step = steps; step >= 0; step--) {
        final t = step / steps;
        final morph = shape.modelMorphAt(t);
        final fontSize = lerpDouble(modelFontSize, subtitleFontSize, morph)!;
        final height = lerpDouble(modelLineHeight, subtitleLineHeight, morph)!;
        final centre = lerpDouble(centreY, subtitleCentreY, morph)!;
        // SF Pro's cap height sits about a quarter em below its ascent.
        final capTop = centre - height / 2 + 0.22 * fontSize;
        final titleBottom =
            titleCentreY + titleLineHeight / 2 * shape.titleScaleAt(t);
        if (capTop < titleBottom) return math.min(1.0, t + 1 / steps);
      }
      return 0;
    }

    final motion = ConduitTitledPillMotion(
      modelWidth: modelWidth,
      titledWidth: titledWidth,
      titleWidth: fittedTitle?.width ?? 0,
      linesClearAt: title.isEmpty ? 0.5 : linesClearAt(),
      reduceMotion: reduceMotion,
    );

    final titleContentWidth = contentWidth(
      titledWidth,
      showChevron ? _kConduitTitledPillSubtitleChevron + 3 : 0,
    );
    final stackWidth = math.max(
      titleContentWidth,
      contentWidth(
        modelWidth,
        showChevron ? kConduitModelSelectorChevronExtent + 6 : 0,
      ),
    );
    final morphFrom = labelStyle.copyWith(fontSize: modelFontSize);
    final morphTo = subtitleStyle.copyWith(fontSize: subtitleFontSize);

    // A line of [child] centred on [centre], measured from the pill's top.
    Widget placed(double centre, Widget child) => Positioned(
      left: 0,
      right: 0,
      top: centre - controlExtent,
      height: controlExtent * 2,
      child: Center(child: child),
    );

    final titleText = title.isEmpty
        ? null
        : MediaQuery.withClampedTextScaling(
            maxScaleFactor: _kConduitTitledPillMaxTextScale,
            child: SizedBox(
              width: titleContentWidth,
              child: Text(
                title,
                style: titleStyle,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          );

    final enabled = !widget.isLoading && showChevron;

    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final t = _progress.value.clamp(0.0, 1.0).toDouble();
        final semanticLabel = _target == 1 && titleText != null
            ? '$rawTitle, ${widget.semanticsLabel}'
            : widget.semanticsLabel;
        final width = motion.widthAt(t);
        final children = <Widget>[];

        if (widget.isLoading) {
          children.add(
            placed(
              centreY,
              Opacity(
                opacity: 1 - _smoothstep(0.15, 0.55, t),
                child: ConduitLoading.skeleton(
                  width: 80,
                  height: 14,
                  borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                ),
              ),
            ),
          );
        } else if (motion.reduceMotion) {
          final modelOpacity = motion.modelOpacityAt(t);
          if (modelOpacity > 0) {
            children.add(
              placed(
                centreY,
                Opacity(
                  opacity: modelOpacity,
                  child: SizedBox(
                    width: contentWidth(
                      width,
                      showChevron ? kConduitModelSelectorChevronExtent + 6 : 0,
                    ),
                    child: Center(
                      child: line(
                        widget.label,
                        labelStyle,
                        kConduitModelSelectorChevronExtent,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          final subtitleOpacity = titleText == null
              ? 0.0
              : motion.subtitleOpacityAt(t);
          if (subtitleOpacity > 0) {
            children.add(
              placed(
                subtitleCentreY,
                Opacity(
                  opacity: subtitleOpacity,
                  child: SizedBox(
                    width: titleContentWidth,
                    child: Center(
                      child: line(
                        widget.label,
                        morphTo,
                        _kConduitTitledPillSubtitleChevron,
                        textScaler: TextScaler.noScaling,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
        } else {
          // One model line throughout: it shrinks into the subtitle's place
          // as the capsule grows, so the pill is never empty.
          final morph = titleText == null ? 0.0 : motion.modelMorphAt(t);
          final style = TextStyle.lerp(morphFrom, morphTo, morph)!;
          final chevron = lerpDouble(
            kConduitModelSelectorChevronExtent,
            _kConduitTitledPillSubtitleChevron,
            morph,
          )!;
          children.add(
            placed(
              lerpDouble(centreY, subtitleCentreY, morph)!,
              SizedBox(
                width: contentWidth(width, showChevron ? chevron + 6 : 0),
                child: Center(
                  child: line(
                    widget.label,
                    style,
                    chevron,
                    textScaler: TextScaler.noScaling,
                    chevronGap: lerpDouble(6, 3, morph),
                  ),
                ),
              ),
            ),
          );
        }

        final titleOpacity = titleText == null ? 0.0 : motion.titleOpacityAt(t);
        if (titleText != null && titleOpacity > 0) {
          children.add(
            placed(
              titleCentreY,
              Opacity(
                opacity: titleOpacity,
                child: Transform.scale(
                  scale: motion.titleScaleAt(t),
                  child: titleText,
                ),
              ),
            ),
          );
        }

        final content = ClipRect(
          child: OverflowBox(
            minWidth: 0,
            maxWidth: math.max(width, stackWidth),
            child: SizedBox(
              width: math.max(width, stackWidth),
              height: controlExtent,
              child: Stack(clipBehavior: Clip.none, children: children),
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
