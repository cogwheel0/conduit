import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:cupertino_ui/cupertino_ui.dart';

import 'adaptive_toolbar_components.dart';
import 'chrome_gradient_fade.dart';

const double _nativeTabBarPlaceholderHeight = 50;

/// iOS 26 sidebar shell backed by cupertino_native_better chrome.
class SidebarIos26Scaffold extends StatelessWidget {
  const SidebarIos26Scaffold({
    super.key,
    this.bottomNavigationBar,
    required this.body,
    this.leading,
    this.middle,
    this.actions,
    this.showNativeView = true,
  });

  final AdaptiveBottomNavigationBar? bottomNavigationBar;
  final Widget body;
  final Widget? leading;

  /// Centred between [leading] and [actions], in the room they leave.
  final Widget? middle;

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
    final safePadding = MediaQuery.paddingOf(context);
    final renderedBottomNavigation = switch (navigation) {
      final navigation?
          when navigation.items.length >= 2 && navigation.items.length <= 5 =>
        navigation.renderer == AdaptiveBottomNavigationRenderer.fullWidth
            ? buildAdaptiveCupertinoTabBar(navigation)
            : composeNativeViews
            ? buildAdaptiveNativeTabBar(
                navigation,
                tint:
                    navigation.selectedItemColor ??
                    CupertinoTheme.of(context).primaryColor,
              )
            : SizedBox(
                height: safePadding.bottom + _nativeTabBarPlaceholderHeight,
              ),
      _ => null,
    };
    final hasBottomNavigation = renderedBottomNavigation != null;
    final textColor = context.conduitTheme.textPrimary;
    final hasNavigationBar = leading != null || actions?.isNotEmpty == true;
    final toolbarActions = actions ?? const <AdaptiveAppBarAction>[];
    final clusterItems = sidebarToolbarClusterItems(toolbarActions);
    final toolbarActionsWidth = toolbarActions.isEmpty
        ? 0.0
        : clusterItems != null
        ? conduitToolbarClusterWidth(context, clusterItems.length)
        : (toolbarActions.length * TouchTarget.minimum) +
              ((toolbarActions.length - 1) * Spacing.sm);

    return CupertinoPageScaffold(
      resizeToAvoidBottomInset: !hasBottomNavigation,
      navigationBar: hasNavigationBar
          ? ConduitAdaptiveCupertinoNavigationBar(
              textScaler: MediaQuery.textScalerOf(context),
              leading: leading ?? const SizedBox.shrink(),
              middle: middle,
              trailing: toolbarActions.isEmpty
                  ? null
                  : composeNativeViews && clusterItems != null
                  // The chat header's glass group: one capsule, the same
                  // glyph size, and one reshape when the actions change.
                  ? ConduitToolbarActionCluster(
                      key: const ValueKey<String>('sidebar-toolbar-actions'),
                      items: clusterItems,
                    )
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
          if (hasNavigationBar)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: ConduitChromeGradientFade.top(
                contentHeight:
                    safePadding.top + conduitAdaptiveToolbarHeightOf(context),
              ),
            ),
          if (renderedBottomNavigation != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: renderedBottomNavigation,
            ),
        ],
      ),
    );
  }
}

/// [actions] as the items of a [ConduitToolbarActionCluster], or null when
/// one of them cannot be a plain glyph in it (a titled or prominent action,
/// or more than three).
///
/// Each item is keyed by its symbol, unique in one bar, so a change of
/// actions (search opening, a tab with its own create action) reshapes the
/// glass once instead of rebuilding every control.
@visibleForTesting
List<ConduitToolbarClusterItem>? sidebarToolbarClusterItems(
  List<AdaptiveAppBarAction> actions,
) {
  if (actions.isEmpty || actions.length > 3) return null;
  final symbols = <String>{};
  final items = <ConduitToolbarClusterItem>[];
  for (final action in actions) {
    final symbol = action.iosSymbol;
    if (symbol == null ||
        action.title != null ||
        action.prominent ||
        !symbols.add(symbol)) {
      return null;
    }
    items.add(
      ConduitToolbarClusterItem(
        id: symbol,
        fallbackIcon: action.icon,
        action: ConduitNativeToolbarAction(
          iosSymbol: symbol,
          accessibilityLabel: action.semanticLabel ?? symbol,
          onPressed: action.onPressed,
          enabled: action.onPressed != null,
          tintColor: action.tintColor,
        ),
      ),
    );
  }
  return items;
}

class _NativeToolbarActions extends StatelessWidget {
  const _NativeToolbarActions({required this.actions});

  final List<AdaptiveAppBarAction> actions;

  @override
  Widget build(BuildContext context) {
    // The group updates its brightness and each changed button's tint in
    // place, so a theme or palette switch keeps the same native view.
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
                      size: kConduitNativeSingleActionSymbolExtent,
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
