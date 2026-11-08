import 'dart:math' as math;

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:material_ui/material_ui.dart';

import 'adaptive_controls.dart';
import 'adaptive_floating_action_button.dart';
import 'adaptive_glass_controls.dart';
import 'platform_ui_capabilities.dart';

/// Default height of an [AdaptiveFloatingTabBar]: the minimum touch target,
/// which toolbar buttons use too.
const double kAdaptiveFloatingBarDefaultExtent = 44;

/// Height of the iOS 26 system toolbar, which keeps it at every text size.
const double _kNativeToolbarExtent = 44;

/// Ids of the iOS 26 toolbar's items, so each is updated in place.
const String _kTabsItemId = 'tabs';
const String _kSpaceItemId = 'space';
const String _kActionItemId = 'action';

/// One icon-only destination in an [AdaptiveFloatingTabBar].
class AdaptiveFloatingTab {
  const AdaptiveFloatingTab({
    required this.label,
    required this.icon,
    required this.nativeAsset,
  });

  /// Read by screen readers, and shown as the Material tooltip.
  final String label;

  /// Drawn by Flutter, tinted through the ambient [IconTheme].
  final Widget icon;

  /// Bitmap asset of the iOS 26 segment. The segmented control fits it in
  /// its icon box and tints it as a template, so only its alpha shows.
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

/// Icon-only tabs at the leading edge and a round [action] at the trailing
/// edge, floating over scrolling content at the bottom of the window.
///
/// Place it flush with the bottom of the window across its container, and
/// keep [extentOf] clear below scrolling content.
///
/// On iOS 26 this is the system bottom toolbar: the tabs are a segmented
/// control and the action a prominent button, on Liquid Glass. The toolbar
/// is 44 points high at every text size. Elsewhere it is a Material
/// navigation bar in a pill beside a floating action button of
/// [controlExtent]. Fewer than two [tabs] leave only the action.
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

  /// Called with the tab chosen. The iOS 26 segmented control reports only
  /// a change of tab; the Material bar reports the selected tab again.
  final ValueChanged<int> onTap;
  final AdaptiveFloatingBarAction action;

  /// Width of each Material tab.
  final double itemWidth;

  /// Colour of the selected Material tab, and the iOS 26 toolbar's tint.
  final Color? selectedItemColor;
  final Color? unselectedItemColor;

  /// Icon colour of the action.
  final Color? actionForegroundColor;

  /// Fill of the action: the Material button's, and the iOS 26 prominent
  /// button's tint. The glass action of earlier iOS has none.
  final Color? actionBackgroundColor;

  /// Fill of the Material pill. The iOS 26 toolbar draws its own glass.
  final Color? backgroundColor;

  /// Outline of the Material pill.
  final Color? borderColor;

  /// Keys for the Flutter-drawn tabs and action, which the iOS 26 toolbar
  /// draws in one native view.
  final Key? tabsKey;
  final Key? actionKey;

  /// Height of the Flutter-drawn tabs and the action's diameter: the size of
  /// the window's other toolbar buttons, so the bar matches them. The iOS 26
  /// toolbar keeps its own height.
  final double controlExtent;

  /// Inset of the Flutter-drawn tabs and action from the sides of the
  /// window, as the window's toolbar insets its buttons. The iOS 26 toolbar
  /// keeps its own margins.
  final double edgeInset;

  /// Least gap below the bar, on a window whose bottom safe area is smaller.
  /// The bar otherwise sits on the safe area.
  final double minimumBottomInset;

  /// Point size of the glass action's SF Symbol before iOS 26, as the
  /// window's other glass buttons draw theirs. The iOS 26 toolbar sizes its
  /// own symbols.
  final double actionSymbolSize;

  /// Room the bar takes from the bottom of the window, for a bar
  /// [controlExtent] tall, or the iOS 26 toolbar's height, with at least
  /// [minimumBottomInset] below it.
  static double extentOf(
    BuildContext context, {
    double controlExtent = kAdaptiveFloatingBarDefaultExtent,
    double minimumBottomInset = 16,
  }) =>
      _bottomInset(context, minimumBottomInset) +
      (PlatformUiCapabilities.usesNativeIOS26
          ? _kNativeToolbarExtent
          : controlExtent);

  /// Gap between the bar and the bottom of the window.
  static double _bottomInset(BuildContext context, double minimum) =>
      math.max(MediaQuery.viewPaddingOf(context).bottom, minimum);

  @override
  Widget build(BuildContext context) {
    if (PlatformUiCapabilities.usesNativeIOS26) return _buildNative(context);
    return _buildFlutter(context);
  }

  Widget _buildNative(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: _bottomInset(context, minimumBottomInset),
      ),
      child: CNToolbar(
        tint: selectedItemColor,
        items: [
          if (tabs.length >= 2)
            CNToolbarSegmentedGroup(
              id: _kTabsItemId,
              // VoiceOver reads each segment's own label.
              label: '',
              segments: [
                for (final tab in tabs)
                  CNToolbarSegment(
                    label: tab.label,
                    imageAsset: CNImageAsset(tab.nativeAsset),
                  ),
              ],
              selectedIndices: {selectedIndex},
              onSelected: onTap,
            ),
          const CNToolbarSpace.flexible(id: _kSpaceItemId),
          CNToolbarButton(
            id: _kActionItemId,
            label: action.label,
            icon: CNSymbol(action.sfSymbol, color: actionForegroundColor),
            style: CNToolbarItemStyle.prominent,
            tint: actionBackgroundColor,
            onPressed: action.onPressed,
          ),
        ],
      ),
    );
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
