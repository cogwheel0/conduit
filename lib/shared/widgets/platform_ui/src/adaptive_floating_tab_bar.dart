import 'dart:math' as math;

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'adaptive_controls.dart';
import 'adaptive_floating_action_button.dart';
import 'adaptive_glass_controls.dart';
import 'platform_ui_capabilities.dart';

/// Default height of an [AdaptiveFloatingTabBar]: the minimum touch target,
/// which toolbar buttons use too.
const double kAdaptiveFloatingBarDefaultExtent = 44;

/// How UIKit lays out the iOS 26 tab bar: the height of the glass platter
/// holding the tabs, and of the strip it leaves below the platter inside
/// the bar. Measured on iOS 26 and 27; the bar keeps them at every text
/// size.
typedef _NativeTabBarMetrics = ({double platter, double below});

/// The layouts UIKit gives the tab bar.
enum _NativeTabBarLayout {
  /// Room for an icon above a label, as on an iPhone, in portrait and
  /// landscape.
  stacked,

  /// Room for an icon beside a label, as in a full-width iPad window.
  inline,
}

/// A stacked tab bar at the size UIKit gives it, before it is given a
/// height.
const _NativeTabBarMetrics _kStackedTabBar = (platter: 62, below: 21);

/// A stacked tab bar given [_kCompactTabBarHeight]: its icons need no room
/// for a label, and it is as tall as the window's other glass buttons.
const _NativeTabBarMetrics _kCompactTabBar = (platter: 44, below: 21);

/// An inline tab bar, which is already no taller than [_kCompactTabBar].
const _NativeTabBarMetrics _kInlineTabBar = (platter: 44, below: 20);

/// Point size of a tab's mark.
const double _kTabIconSize = 22;

/// Point size of a tab's mark on [_kCompactTabBar].
const double _kCompactTabIconSize = 20;

/// How UIKit lays the platter out across the tab bar, for tabs that show
/// only their icons: the least room it leaves on each side of the platter,
/// and the platter's width, [ends] plus [pitch] for each tab. A wider bar
/// centres the platter; a narrower one shrinks it to the bar less that
/// room. Measured on iOS 27.2 from the tab frames of a two-tab bar.
typedef _NativeTabBarSpan = ({double margin, double ends, double pitch});

/// Tabs 94 points wide, overlapping by 8, with 4 points at each end.
const _NativeTabBarSpan _kStackedTabBarSpan = (margin: 21, ends: 16, pitch: 86);

/// Tabs 66 points wide, 4 points apart and from each end.
const _NativeTabBarSpan _kInlineTabBarSpan = (margin: 38, ends: 4, pitch: 70);

/// Room `CNTabBar` keeps above its bar for the selection pill, which its
/// box includes.
const double _kTabBarPillRoom = 14;

/// Height of the `CNTabBar` box that gives a stacked bar [_kCompactTabBar].
final double _kCompactTabBarHeight =
    _kTabBarPillRoom + _kCompactTabBar.platter + _kCompactTabBar.below;

/// Shortest window side from which the tab bar is taken to be laid out
/// inline, until it has measured itself: an iPad's.
const double _kInlineTabBarShortestSide = 600;

/// Platter height at which the action's symbol takes
/// [AdaptiveFloatingTabBar.actionSymbolSize]: that of the window's other
/// glass buttons. A taller platter scales the symbol up with it.
const double _kActionSymbolScaleExtent = 44;

/// One destination in an [AdaptiveFloatingTabBar].
class AdaptiveFloatingTab {
  const AdaptiveFloatingTab({
    required this.label,
    required this.icon,
    required this.nativeAsset,
  });

  /// The tab's name: what screen readers read for it, on the iOS 26 tab bar
  /// too, whose tabs show only their icons, and the Material tooltip.
  final String label;

  /// Drawn by Flutter, tinted through the ambient [IconTheme].
  final Widget icon;

  /// Bitmap asset of the iOS 26 tab. The tab bar fits it in its icon box and
  /// tints it as a template, so only its alpha shows.
  final String nativeAsset;
}

/// The round action at the trailing end of an [AdaptiveFloatingTabBar].
class AdaptiveFloatingBarAction {
  const AdaptiveFloatingBarAction({
    required this.label,
    required this.icon,
    required this.sfSymbol,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final String sfSymbol;
  final VoidCallback onPressed;
}

/// Tabs at the leading edge and a round [action] at the trailing edge,
/// floating over scrolling content at the bottom of the window.
///
/// Place it flush with the bottom of the window across its container, and
/// keep [extentOf] clear below scrolling content.
///
/// On iOS 26 the tabs are the system tab bar, showing their icons only, and
/// the action a Liquid Glass button as tall as the tab bar's platter, lined
/// up with it. The platter is 44 points on a phone, and UIKit's inline one,
/// as tall, on an iPad; it keeps that size at every text size. Like the
/// Flutter-drawn bar, both sit on the bottom safe area, or
/// [minimumBottomInset] above the bottom of the window when that is less.
/// Screen readers read each tab by its label, and the action as a button of
/// its own, so it never takes the selection. Elsewhere the
/// tabs are a Material navigation bar in a pill beside a floating action
/// button of [controlExtent]. Fewer than two [tabs] leave only the action.
class AdaptiveFloatingTabBar extends StatelessWidget {
  const AdaptiveFloatingTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onTap,
    required this.action,
    required this.itemWidth,
    this.selectedItemColor,
    this.unselectedItemColor,
    this.actionForegroundColor,
    this.actionBackgroundColor,
    this.backgroundColor,
    this.borderColor,
    this.tabsKey,
    this.actionKey,
    this.controlExtent = kAdaptiveFloatingBarDefaultExtent,
    this.edgeInset = 16,
    this.minimumBottomInset = 16,
    this.actionSymbolSize = 18,
  }) : assert(tabs.length <= 5);

  final List<AdaptiveFloatingTab> tabs;
  final int selectedIndex;

  /// Called with the tab chosen, including the selected tab chosen again.
  final ValueChanged<int> onTap;
  final AdaptiveFloatingBarAction action;

  /// Width of each Material tab.
  final double itemWidth;

  /// Colour of the selected tab.
  final Color? selectedItemColor;

  /// Colour of the other Material tabs. The iOS 26 tab bar draws its own.
  final Color? unselectedItemColor;

  /// Icon colour of the action.
  final Color? actionForegroundColor;

  /// Fill of the Material action. The glass action of iOS has none.
  final Color? actionBackgroundColor;

  /// Fill of the Material pill. The iOS 26 tab bar draws its own glass.
  final Color? backgroundColor;

  /// Outline of the Material pill.
  final Color? borderColor;

  /// Keys for the tabs and the action.
  final Key? tabsKey;
  final Key? actionKey;

  /// Height of the Flutter-drawn tabs and the action's diameter: the size of
  /// the window's other toolbar buttons, so the bar matches them. The iOS 26
  /// tab bar keeps the size UIKit gives it.
  final double controlExtent;

  /// Inset of the action, and of the Flutter-drawn tabs, from the sides of
  /// the window, as the window's toolbar insets its buttons. The iOS 26 tab
  /// bar centres its platter in the room beside the action.
  final double edgeInset;

  /// Least gap below the bar, on a window whose bottom safe area is smaller.
  /// The bar otherwise sits on the safe area.
  final double minimumBottomInset;

  /// Point size of the glass action's SF Symbol beside a 44 point bar, as
  /// the window's other glass buttons draw theirs. It scales with the iOS 26
  /// tab bar's platter.
  final double actionSymbolSize;

  /// Room the bar takes from the bottom of the window.
  ///
  /// The bar is [controlExtent] tall, or the iOS 26 tab bar's platter as
  /// UIKit lays it out in a window of this size, with at least
  /// [minimumBottomInset] below it.
  static double extentOf(
    BuildContext context, {
    double controlExtent = kAdaptiveFloatingBarDefaultExtent,
    double minimumBottomInset = 16,
  }) {
    final height = PlatformUiCapabilities.usesNativeIOS26
        ? _nativeMetrics(_guessNativeLayout(context)).platter
        : controlExtent;
    return _bottomInset(context, minimumBottomInset) + height;
  }

  /// Gap between the bar and the bottom of the window.
  static double _bottomInset(BuildContext context, double minimum) =>
      math.max(MediaQuery.viewPaddingOf(context).bottom, minimum);

  /// The iOS 26 tab bar's layout in this window, before it has measured
  /// itself.
  static _NativeTabBarLayout _guessNativeLayout(BuildContext context) =>
      MediaQuery.sizeOf(context).shortestSide >= _kInlineTabBarShortestSide
      ? _NativeTabBarLayout.inline
      : _NativeTabBarLayout.stacked;

  static _NativeTabBarMetrics _nativeMetrics(_NativeTabBarLayout layout) =>
      switch (layout) {
        _NativeTabBarLayout.inline => _kInlineTabBar,
        _NativeTabBarLayout.stacked => _kCompactTabBar,
      };

  static _NativeTabBarSpan _nativeSpan(_NativeTabBarLayout layout) =>
      switch (layout) {
        _NativeTabBarLayout.inline => _kInlineTabBarSpan,
        _NativeTabBarLayout.stacked => _kStackedTabBarSpan,
      };

  @override
  Widget build(BuildContext context) {
    if (PlatformUiCapabilities.usesNativeIOS26) {
      return _NativeFloatingTabBar(bar: this);
    }
    return _buildFlutter(context);
  }

  Widget _buildFlutter(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        edgeInset,
        0,
        edgeInset,
        _bottomInset(context, minimumBottomInset),
      ),
      child: SizedBox(
        height: controlExtent,
        child: Row(
          children: [
            if (tabs.length >= 2) _buildPill(context),
            const Spacer(),
            _buildAction(),
          ],
        ),
      ),
    );
  }

  Widget _buildPill(BuildContext context) {
    final borderRadius = BorderRadius.circular(controlExtent / 2);
    final selectedColor =
        selectedItemColor ?? Theme.of(context).colorScheme.primary;
    final unselectedColor =
        unselectedItemColor ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      key: tabsKey,
      width: itemWidth * tabs.length,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: borderRadius,
          border: borderColor == null ? null : Border.all(color: borderColor!),
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          // The bar floats above the system insets, which its SafeArea would
          // otherwise add again.
          child: MediaQuery.removePadding(
            context: context,
            removeLeft: true,
            removeTop: true,
            removeRight: true,
            removeBottom: true,
            child: NavigationBarTheme(
              data: NavigationBarTheme.of(context).copyWith(
                iconTheme: WidgetStateProperty.resolveWith(
                  (states) => IconThemeData(
                    color: states.contains(WidgetState.selected)
                        ? selectedColor
                        : unselectedColor,
                    size: 24,
                  ),
                ),
              ),
              child: NavigationBar(
                height: controlExtent,
                selectedIndex: selectedIndex,
                onDestinationSelected: onTap,
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                indicatorColor: selectedColor.withValues(alpha: 0.12),
                labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
                destinations: [
                  for (final tab in tabs)
                    NavigationDestination(
                      icon: tab.icon,
                      label: tab.label,
                      tooltip: tab.label,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAction() {
    if (!PlatformUiCapabilities.isIOS) {
      return SizedBox.square(
        key: actionKey,
        dimension: controlExtent,
        child: AdaptiveFloatingActionButton(
          onPressed: action.onPressed,
          semanticLabel: action.label,
          // Round, as the toolbar's buttons and the pill's ends are.
          shape: const CircleBorder(),
          backgroundColor: actionBackgroundColor,
          foregroundColor: actionForegroundColor,
          child: Icon(action.icon),
        ),
      );
    }
    // The glass fallback has no label of its own; announce one control.
    return Semantics(
      key: actionKey,
      label: action.label,
      button: true,
      excludeSemantics: true,
      onTap: action.onPressed,
      child: NativeGlassIconButton(
        onPressed: action.onPressed,
        symbol: SFSymbol(
          action.sfSymbol,
          size: actionSymbolSize,
          color: actionForegroundColor,
        ),
        dimension: controlExtent,
      ),
    );
  }
}

/// The iOS 26 bar: the system tab bar, and the action as a glass button
/// lined up with the tab bar's platter.
///
/// The bar takes the action's size and place from the tab bar as laid out:
/// stacked on a phone, where it is given the 44 point platter, and inline in
/// a full-width iPad window, where UIKit gives it its own, as tall.
class _NativeFloatingTabBar extends StatefulWidget {
  const _NativeFloatingTabBar({required this.bar});

  final AdaptiveFloatingTabBar bar;

  @override
  State<_NativeFloatingTabBar> createState() => _NativeFloatingTabBarState();
}

class _NativeFloatingTabBarState extends State<_NativeFloatingTabBar> {
  /// The tab bar's layout, once it has measured itself. Only a tab bar left
  /// to its own height measures itself: given one, it reports that height.
  _NativeTabBarLayout? _measured;

  /// The layout guessed from the window when [_measured] was taken. A window
  /// of another class lays the tab bar out again.
  _NativeTabBarLayout? _guessed;

  /// The tab bar's box before it has measured itself is at most this tall.
  static const double _unmeasuredTabBarExtent = 50;

  void _onTabBarSize(Size size) {
    if (size.height <= _unmeasuredTabBarExtent) return;
    final bar = size.height - _kTabBarPillRoom;
    // Only a tab bar at its own height reports, so a stacked one is the
    // full-size platter; halfway to an inline bar leaves room either side.
    final stacked = _kStackedTabBar.platter + _kStackedTabBar.below;
    final inline = _kInlineTabBar.platter + _kInlineTabBar.below;
    final layout = bar >= (stacked + inline) / 2
        ? _NativeTabBarLayout.stacked
        : _NativeTabBarLayout.inline;
    if (layout != _measured) setState(() => _measured = layout);
  }

  @override
  Widget build(BuildContext context) {
    final bar = widget.bar;
    final guessed = AdaptiveFloatingTabBar._guessNativeLayout(context);
    if (guessed != _guessed) {
      // A measurement from a window of another class no longer holds.
      _guessed = guessed;
      _measured = null;
    }
    // Only a mounted tab bar reports its layout, so without one a window
    // resize would otherwise leave the action sized for the old layout.
    final layout = bar.tabs.length >= 2 ? (_measured ?? guessed) : guessed;
    final metrics = AdaptiveFloatingTabBar._nativeMetrics(layout);
    final action = bar.action;
    final bottomInset = AdaptiveFloatingTabBar._bottomInset(
      context,
      bar.minimumBottomInset,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: bar.tabs.length < 2
              ? const SizedBox.shrink()
              // UIKit keeps its strip below the platter inside the tab bar,
              // so the bar is moved by the rest of the inset.
              : _tabBar(layout, lift: bottomInset - metrics.below),
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(
            end: bar.edgeInset,
            bottom: bottomInset,
          ),
          // The glass button has no label of its own; announce one control.
          child: Semantics(
            key: bar.actionKey,
            label: action.label,
            button: true,
            excludeSemantics: true,
            onTap: action.onPressed,
            child: NativeGlassIconButton(
              onPressed: action.onPressed,
              symbol: SFSymbol(
                action.sfSymbol,
                size:
                    bar.actionSymbolSize *
                    metrics.platter /
                    _kActionSymbolScaleExtent,
                color: bar.actionForegroundColor,
              ),
              dimension: metrics.platter,
            ),
          ),
        ),
      ],
    );
  }
}

extension on _NativeFloatingTabBarState {
  /// The tab bar, its platter's leading edge [AdaptiveFloatingTabBar.edgeInset]
  /// from the start of the window, as the header's leading button is, and any
  /// room left over between it and the action. The bar is raised by [lift],
  /// or lowered when it is negative, so the platter's bottom lands where the
  /// action's does.
  ///
  /// UIKit centres the platter in the bar, so the bar is made as wide as the
  /// platter and the room UIKit keeps on each side of it, and starts that
  /// room before the edge inset.
  Widget _tabBar(_NativeTabBarLayout layout, {required double lift}) {
    final bar = widget.bar;
    final span = AdaptiveFloatingTabBar._nativeSpan(layout);
    // The package sizes an icon-only bar on iOS 26 as from iOS 27.
    final height = layout == _NativeTabBarLayout.stacked
        ? _kCompactTabBarHeight
        : null;
    final start = bar.edgeInset - span.margin;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(
          span.ends + span.pitch * bar.tabs.length + 2 * span.margin,
          // A narrower room shrinks the platter, which keeps its edge.
          constraints.maxWidth - start,
        );
        return Padding(
          padding: EdgeInsets.only(bottom: math.max(0, lift)),
          child: Align(
            alignment: AlignmentDirectional.bottomStart,
            child: Transform.translate(
              offset: Offset(rtl ? -start : start, math.max(0, -lift)),
              child: SizedBox(
                width: width,
                child: _SizeObserver(
                  // A tab bar given its height reports only that height. One
                  // that stops being given it, as when the window lays it out
                  // inline, measures itself again.
                  onSize: height == null ? _onTabBarSize : null,
                  child: CNTabBar(
                    key: bar.tabsKey,
                    items: [
                      for (final tab in bar.tabs)
                        CNTabBarItem(
                          imageAsset: CNImageAsset(tab.nativeAsset),
                          // The name screen readers give a tab that shows
                          // only its icon.
                          semanticLabel: tab.label,
                        ),
                    ],
                    currentIndex: bar.selectedIndex,
                    onTap: bar.onTap,
                    tint: bar.selectedItemColor,
                    shrinkCentered: false,
                    iconSize: height == null
                        ? _kTabIconSize
                        : _kCompactTabIconSize,
                    height: height,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Reports the size of [child] after each layout that changes it.
class _SizeObserver extends SingleChildRenderObjectWidget {
  const _SizeObserver({required this.onSize, required super.child});

  /// Null reports nothing.
  final ValueChanged<Size>? onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeObserver(onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderSizeObserver renderObject,
  ) {
    renderObject.onSize = onSize;
  }
}

class _RenderSizeObserver extends RenderProxyBox {
  _RenderSizeObserver(this._onSize);

  ValueChanged<Size>? _onSize;
  Size? _reported;

  set onSize(ValueChanged<Size>? value) {
    if (value != null && _onSize == null) {
      // Report again to a listener that has missed the size so far.
      _reported = null;
      markNeedsLayout();
    }
    _onSize = value;
  }

  @override
  void performLayout() {
    super.performLayout();
    if (_onSize == null || size == _reported) return;
    _reported = size;
    final reported = size;
    // Tell after this frame: layout cannot rebuild the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) _onSize?.call(reported);
    });
  }
}
