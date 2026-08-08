import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:flutter/cupertino.dart';

import 'adaptive_toolbar_components.dart';

const double _nativeTabBarPlaceholderHeight = 50;

/// iOS 26 sidebar shell backed by cupertino_native_better chrome.
class SidebarIos26Scaffold extends StatelessWidget {
  const SidebarIos26Scaffold({
    super.key,
    this.bottomNavigationBar,
    required this.body,
    this.leading,
    this.actions,
    this.showNativeView = true,
  });

  final AdaptiveBottomNavigationBar? bottomNavigationBar;
  final Widget body;
  final Widget? leading;
  final List<AdaptiveAppBarAction>? actions;
  final bool showNativeView;

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final routeAllowsNativeView =
        (route?.isCurrent ?? true) ||
        route?.animation?.status == AnimationStatus.reverse;
    final composeNativeViews = showNativeView && routeAllowsNativeView;
    final navigation = bottomNavigationBar;
    final destinations =
        navigation?.items ?? const <AdaptiveNavigationDestination>[];
    final hasBottomNavigation =
        destinations.length >= 2 &&
        destinations.length <= 5 &&
        navigation?.selectedIndex != null &&
        navigation?.onTap != null;
    final safePadding = MediaQuery.paddingOf(context);
    final textColor = CupertinoColors.label.resolveFrom(context);
    final hasNavigationBar = leading != null || actions?.isNotEmpty == true;
    final toolbarActions = actions ?? const <AdaptiveAppBarAction>[];
    final toolbarActionsWidth = toolbarActions.isEmpty
        ? 0.0
        : (toolbarActions.length * TouchTarget.minimum) +
              ((toolbarActions.length - 1) * Spacing.sm);

    return CupertinoPageScaffold(
      resizeToAvoidBottomInset: !hasBottomNavigation,
      navigationBar: hasNavigationBar
          ? ConduitAdaptiveCupertinoNavigationBar(
              textScaler: MediaQuery.textScalerOf(context),
              leading: leading ?? const SizedBox.shrink(),
              trailing: toolbarActions.isEmpty
                  ? null
                  : SizedBox(
                      width: toolbarActionsWidth,
                      height: TouchTarget.minimum,
                      child: composeNativeViews
                          ? _NativeToolbarActions(actions: toolbarActions)
                          : null,
                    ),
            )
          : null,
      child: Stack(
        children: [
          DefaultTextStyle(
            style: TextStyle(color: textColor, fontSize: 17),
            child: body,
          ),
          if (hasBottomNavigation)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: composeNativeViews
                  ? CNTabBar(
                      items: [
                        for (final destination in destinations)
                          _nativeTabItem(destination),
                      ],
                      currentIndex: navigation!.selectedIndex!,
                      onTap: navigation.onTap!,
                      tint:
                          navigation.selectedItemColor ??
                          CupertinoTheme.of(context).primaryColor,
                      iconSize: kCupertinoNativeControlSymbolExtent,
                    )
                  : SizedBox(
                      height:
                          safePadding.bottom + _nativeTabBarPlaceholderHeight,
                    ),
            ),
        ],
      ),
    );
  }

  static CNTabBarItem _nativeTabItem(
    AdaptiveNavigationDestination destination,
  ) {
    return CNTabBarItem(
      label: destination.label,
      icon: destination.icon is String
          ? CNSymbol(destination.icon as String)
          : null,
      activeIcon: destination.selectedIcon is String
          ? CNSymbol(destination.selectedIcon as String)
          : null,
      customIcon: _iconData(destination.icon),
      activeCustomIcon: _iconData(destination.selectedIcon),
      imageAsset: _imageAsset(destination.icon),
      activeImageAsset: _imageAsset(destination.selectedIcon),
      badge: destination.badgeCount == null || destination.badgeCount == 0
          ? null
          : '${destination.badgeCount}',
    );
  }

  static IconData? _iconData(dynamic icon) {
    if (icon is IconData) return icon;
    if (icon is Icon) return icon.icon;
    return null;
  }

  static CNImageAsset? _imageAsset(dynamic icon) {
    if (icon is ImageIcon && icon.image is AssetImage) {
      return CNImageAsset((icon.image as AssetImage).assetName);
    }
    if (icon is AssetImage) return CNImageAsset(icon.assetName);
    return null;
  }
}

class _NativeToolbarActions extends StatelessWidget {
  const _NativeToolbarActions({required this.actions});

  final List<AdaptiveAppBarAction> actions;

  @override
  Widget build(BuildContext context) {
    return CNGlassButtonGroup.fromWidgets(
      spacing: 8,
      spacingForGlass: 36,
      buttonWidgets: [
        for (final action in actions)
          if (action.title case final title?)
            CNButton(
              label: title,
              onPressed: action.onPressed,
              tint: action.tintColor,
              config: CNButtonConfig(
                minHeight: TouchTarget.minimum,
                shrinkWrap: true,
                style: action.prominent
                    ? CNButtonStyle.prominentGlass
                    : CNButtonStyle.glass,
              ),
            )
          else
            CNButton.icon(
              icon: action.iosSymbol == null
                  ? null
                  : CNSymbol(
                      action.iosSymbol!,
                      size: kCupertinoNativeControlSymbolExtent,
                    ),
              customIcon: action.iosSymbol == null ? action.icon : null,
              onPressed: action.onPressed,
              tint: action.tintColor,
              config: CNButtonConfig(
                minHeight: TouchTarget.minimum,
                width: TouchTarget.minimum,
                style: action.prominent
                    ? CNButtonStyle.prominentGlass
                    : CNButtonStyle.glass,
              ),
            ),
      ],
    );
  }
}
