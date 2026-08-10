import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'adaptive_controls.dart';
import 'platform_ui_capabilities.dart';

enum ToolbarSpacerType { none, fixed, flexible }

class AdaptiveAppBarAction {
  const AdaptiveAppBarAction({
    this.iosSymbol,
    this.icon,
    this.title,
    required this.onPressed,
    this.spacerAfter = ToolbarSpacerType.none,
    this.prominent = false,
    this.tintColor,
  }) : assert(iosSymbol != null || icon != null || title != null);

  final String? iosSymbol;
  final IconData? icon;
  final String? title;
  final VoidCallback onPressed;
  final ToolbarSpacerType spacerAfter;
  final bool prominent;
  final Color? tintColor;

  Map<String, dynamic> toNativeMap() => {
    if (iosSymbol != null) 'icon': iosSymbol,
    if (title != null) 'title': title,
    'spacerAfter': spacerAfter.index,
    if (prominent) 'prominent': true,
    if (tintColor != null) 'tint': tintColor!.toARGB32(),
  };
}

class AdaptiveAppBar {
  const AdaptiveAppBar({
    this.title,
    this.subtitle,
    this.actions,
    this.leading,
    this.useNativeToolbar = true,
    this.tintColor,
    this.titleWidget,
    this.cupertinoNavigationBar,
    this.appBar,
  });

  final String? title;
  final String? subtitle;
  final List<AdaptiveAppBarAction>? actions;
  final Widget? leading;
  final bool useNativeToolbar;
  final Color? tintColor;
  final Widget? titleWidget;
  final ObstructingPreferredSizeWidget? cupertinoNavigationBar;
  final PreferredSizeWidget? appBar;

  AdaptiveAppBar copyWith({
    String? title,
    String? subtitle,
    List<AdaptiveAppBarAction>? actions,
    Widget? leading,
    bool? useNativeToolbar,
    Color? tintColor,
    Widget? titleWidget,
    ObstructingPreferredSizeWidget? cupertinoNavigationBar,
    PreferredSizeWidget? appBar,
  }) {
    return AdaptiveAppBar(
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      actions: actions ?? this.actions,
      leading: leading ?? this.leading,
      useNativeToolbar: useNativeToolbar ?? this.useNativeToolbar,
      tintColor: tintColor ?? this.tintColor,
      titleWidget: titleWidget ?? this.titleWidget,
      cupertinoNavigationBar:
          cupertinoNavigationBar ?? this.cupertinoNavigationBar,
      appBar: appBar ?? this.appBar,
    );
  }
}

class AdaptiveNavigationDestination {
  const AdaptiveNavigationDestination({
    required this.icon,
    required this.label,
    this.selectedIcon,
    this.isSearch = false,
    this.badgeCount,
    this.addSpacerAfter = false,
  });

  final dynamic icon;
  final String label;
  final dynamic selectedIcon;
  final bool isSearch;
  final int? badgeCount;
  final bool addSpacerAfter;
}

class AdaptiveBottomNavigationBar {
  const AdaptiveBottomNavigationBar({
    this.items,
    this.selectedIndex,
    this.onTap,
    this.useNativeBottomBar = true,
    this.nativeFullWidth = false,
    this.cupertinoTabBar,
    this.bottomNavigationBar,
    this.selectedItemColor,
    this.unselectedItemColor,
  });

  final List<AdaptiveNavigationDestination>? items;
  final int? selectedIndex;
  final ValueChanged<int>? onTap;
  final bool useNativeBottomBar;
  final bool nativeFullWidth;
  final CupertinoTabBar? cupertinoTabBar;
  final Widget? bottomNavigationBar;
  final Color? selectedItemColor;
  final Color? unselectedItemColor;
}

class AdaptiveScaffold extends StatelessWidget {
  const AdaptiveScaffold({
    super.key,
    this.appBar,
    this.bottomNavigationBar,
    this.body,
    this.resizeToAvoidBottomInset,
    this.floatingActionButton,
    this.extendBodyBehindAppBar = false,
    this.drawer,
    this.endDrawer,
    this.drawerScrimColor,
    this.onDrawerChanged,
    this.onEndDrawerChanged,
    this.drawerEnableOpenDragGesture = true,
    this.endDrawerEnableOpenDragGesture = true,
    this.scaffoldKey,
    this.tabBarHidden = false,
  });

  final AdaptiveAppBar? appBar;
  final AdaptiveBottomNavigationBar? bottomNavigationBar;
  final Widget? body;
  final bool? resizeToAvoidBottomInset;
  final Widget? floatingActionButton;
  final bool extendBodyBehindAppBar;
  final Widget? drawer;
  final Widget? endDrawer;
  final Color? drawerScrimColor;
  final DrawerCallback? onDrawerChanged;
  final DrawerCallback? onEndDrawerChanged;
  final bool drawerEnableOpenDragGesture;
  final bool endDrawerEnableOpenDragGesture;
  final GlobalKey<ScaffoldState>? scaffoldKey;
  final bool tabBarHidden;

  @override
  Widget build(BuildContext context) {
    return PlatformUiCapabilities.isIOS
        ? _buildCupertino(context)
        : _buildMaterial(context);
  }

  Widget _buildCupertino(BuildContext context) {
    final navigationBar = _cupertinoNavigationBar(context);
    final navigation = bottomNavigationBar;
    final items = navigation?.items ?? const <AdaptiveNavigationDestination>[];
    final hasNavigation =
        items.isNotEmpty &&
        navigation?.selectedIndex != null &&
        navigation?.onTap != null;
    final useNativeTabBar =
        hasNavigation &&
        !tabBarHidden &&
        navigation!.useNativeBottomBar &&
        PlatformUiCapabilities.usesNativeIOS26 &&
        !navigation.nativeFullWidth &&
        items.length >= 2 &&
        items.length <= 5;

    Widget content = body ?? const SizedBox.shrink();
    Widget? bottomBar;
    if (hasNavigation && !tabBarHidden) {
      if (useNativeTabBar) {
        bottomBar = CNTabBar(
          items: [for (final item in items) _nativeTabItem(item)],
          currentIndex: navigation.selectedIndex!,
          onTap: navigation.onTap!,
          tint: navigation.selectedItemColor,
          iconSize: kCupertinoNativeControlSymbolExtent,
        );
      } else {
        bottomBar =
            navigation!.cupertinoTabBar ??
            CupertinoTabBar(
              currentIndex: navigation.selectedIndex!,
              onTap: navigation.onTap!,
              activeColor: navigation.selectedItemColor,
              inactiveColor:
                  navigation.unselectedItemColor ??
                  CupertinoColors.inactiveGray,
              items: [
                for (final item in items)
                  BottomNavigationBarItem(
                    icon: _flutterNavigationIcon(item.icon),
                    activeIcon: _flutterNavigationIcon(
                      item.selectedIcon ?? item.icon,
                    ),
                    label: item.label,
                  ),
              ],
            );
      }
    }

    if (bottomBar != null) {
      content = useNativeTabBar
          ? Stack(
              children: [
                Positioned.fill(child: content),
                Positioned(left: 0, right: 0, bottom: 0, child: bottomBar),
              ],
            )
          : Column(
              children: [
                Expanded(child: content),
                bottomBar,
              ],
            );
    }
    if (floatingActionButton != null) {
      content = Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            right: 16,
            bottom: bottomBar == null ? 16 : 96,
            child: floatingActionButton!,
          ),
        ],
      );
    }
    content = DefaultTextStyle(
      style: CupertinoTheme.of(context).textTheme.textStyle,
      child: content,
    );

    Widget page = CupertinoPageScaffold(
      resizeToAvoidBottomInset: resizeToAvoidBottomInset ?? !useNativeTabBar,
      navigationBar: navigationBar,
      child: content,
    );
    if (drawer != null || endDrawer != null) {
      page = Scaffold(
        key: scaffoldKey,
        backgroundColor: Colors.transparent,
        body: page,
        drawer: drawer,
        endDrawer: endDrawer,
        drawerScrimColor: drawerScrimColor,
        onDrawerChanged: onDrawerChanged,
        onEndDrawerChanged: onEndDrawerChanged,
        drawerEnableOpenDragGesture: drawerEnableOpenDragGesture,
        endDrawerEnableOpenDragGesture: endDrawerEnableOpenDragGesture,
      );
    }
    return page;
  }

  ObstructingPreferredSizeWidget? _cupertinoNavigationBar(
    BuildContext context,
  ) {
    final custom = appBar?.cupertinoNavigationBar;
    if (custom != null) return custom;
    if (appBar == null) return null;
    final title =
        appBar!.titleWidget ??
        (appBar!.title == null
            ? null
            : appBar!.subtitle?.isNotEmpty == true
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(appBar!.title!),
                  Text(appBar!.subtitle!, style: const TextStyle(fontSize: 12)),
                ],
              )
            : Text(appBar!.title!));
    return CupertinoNavigationBar(
      middle: title,
      leading: appBar!.leading,
      trailing: appBar!.actions?.isEmpty != false
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final action in appBar!.actions!)
                  _cupertinoAction(action, appBar!.tintColor),
              ],
            ),
    );
  }

  Widget _cupertinoAction(AdaptiveAppBarAction action, Color? fallbackTint) {
    if (PlatformUiCapabilities.usesNativeIOS26 &&
        action.iosSymbol != null &&
        action.title == null) {
      return AdaptiveButton.sfSymbol(
        onPressed: action.onPressed,
        sfSymbol: SFSymbol(
          action.iosSymbol!,
          color: action.tintColor ?? fallbackTint,
        ),
        style: action.prominent
            ? AdaptiveButtonStyle.prominentGlass
            : AdaptiveButtonStyle.glass,
        minSize: const Size.square(36),
        padding: EdgeInsets.zero,
        useSmoothRectangleBorder: false,
      );
    }
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      onPressed: action.onPressed,
      child: action.title != null
          ? Text(action.title!)
          : Icon(action.icon ?? CupertinoIcons.circle),
    );
  }

  Widget _buildMaterial(BuildContext context) {
    final actions = appBar?.actions;
    final materialAppBar =
        appBar?.appBar ??
        (appBar == null
            ? null
            : AppBar(
                title: appBar!.titleWidget ?? _materialAppBarTitle(appBar!),
                leading: appBar!.leading,
                actions: actions
                    ?.map(
                      (action) => action.title != null
                          ? TextButton(
                              onPressed: action.onPressed,
                              child: Text(action.title!),
                            )
                          : IconButton(
                              onPressed: action.onPressed,
                              icon: Icon(action.icon ?? Icons.circle),
                            ),
                    )
                    .toList(),
              ));
    final navigation = bottomNavigationBar;
    final items = navigation?.items ?? const <AdaptiveNavigationDestination>[];
    final bottomBar =
        navigation?.bottomNavigationBar ??
        (items.isEmpty || navigation?.selectedIndex == null
            ? null
            : NavigationBar(
                selectedIndex: navigation!.selectedIndex!,
                onDestinationSelected: navigation.onTap,
                indicatorColor: navigation.selectedItemColor,
                destinations: [
                  for (final item in items)
                    NavigationDestination(
                      icon: _flutterNavigationIcon(item.icon),
                      selectedIcon: _flutterNavigationIcon(
                        item.selectedIcon ?? item.icon,
                      ),
                      label: item.label,
                    ),
                ],
              ));
    return Scaffold(
      key: scaffoldKey,
      appBar: materialAppBar,
      body: body,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: tabBarHidden ? null : bottomBar,
      extendBodyBehindAppBar: extendBodyBehindAppBar,
      drawer: drawer,
      endDrawer: endDrawer,
      drawerScrimColor: drawerScrimColor,
      onDrawerChanged: onDrawerChanged,
      onEndDrawerChanged: onEndDrawerChanged,
      drawerEnableOpenDragGesture: drawerEnableOpenDragGesture,
      endDrawerEnableOpenDragGesture: endDrawerEnableOpenDragGesture,
    );
  }

  Widget? _materialAppBarTitle(AdaptiveAppBar bar) {
    final title = bar.title;
    if (title == null) return null;
    if (bar.subtitle?.isNotEmpty != true) return Text(title);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title),
        Text(bar.subtitle!, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  CNTabBarItem _nativeTabItem(AdaptiveNavigationDestination item) {
    final icon = item.icon;
    final selected = item.selectedIcon;
    return CNTabBarItem(
      label: item.label,
      icon: icon is String ? CNSymbol(icon) : null,
      activeIcon: selected is String ? CNSymbol(selected) : null,
      customIcon: _iconData(icon),
      activeCustomIcon: _iconData(selected),
      imageAsset: _imageAsset(icon),
      activeImageAsset: _imageAsset(selected),
      badge: item.badgeCount == null || item.badgeCount == 0
          ? null
          : '${item.badgeCount}',
    );
  }

  IconData? _iconData(dynamic value) {
    if (value is IconData) return value;
    if (value is Icon) return value.icon;
    return null;
  }

  CNImageAsset? _imageAsset(dynamic value) {
    if (value is ImageIcon && value.image is AssetImage) {
      return CNImageAsset((value.image as AssetImage).assetName);
    }
    if (value is AssetImage) return CNImageAsset(value.assetName);
    return null;
  }

  Widget _flutterNavigationIcon(dynamic value) {
    if (value is Widget) return value;
    if (value is IconData) {
      return Icon(value, size: kCupertinoNativeControlSymbolExtent);
    }
    if (value is String) {
      return Icon(
        cupertinoIconForSFSymbol(value) ?? CupertinoIcons.circle,
        size: kCupertinoNativeControlSymbolExtent,
      );
    }
    if (value is ImageProvider) {
      return Image(
        image: value,
        width: kCupertinoNativeControlSymbolExtent,
        height: kCupertinoNativeControlSymbolExtent,
      );
    }
    return const Icon(Icons.circle, size: kCupertinoNativeControlSymbolExtent);
  }
}

class AdaptiveCard extends StatelessWidget {
  const AdaptiveCard({
    super.key,
    this.color,
    this.elevation,
    this.shape,
    this.borderOnForeground = true,
    this.margin,
    this.clipBehavior,
    this.semanticContainer = true,
    required this.child,
    this.padding,
    this.borderRadius,
  });

  final Color? color;
  final double? elevation;
  final ShapeBorder? shape;
  final bool borderOnForeground;
  final EdgeInsetsGeometry? margin;
  final Clip? clipBehavior;
  final bool semanticContainer;
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final content = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    if (!PlatformUiCapabilities.isIOS) {
      return Card(
        color: color,
        elevation: elevation,
        shape:
            shape ??
            (borderRadius == null
                ? null
                : RoundedRectangleBorder(borderRadius: borderRadius!)),
        borderOnForeground: borderOnForeground,
        margin: margin,
        clipBehavior: clipBehavior,
        semanticContainer: semanticContainer,
        child: content,
      );
    }
    return Semantics(
      container: semanticContainer,
      child: Container(
        margin: margin,
        clipBehavior: clipBehavior ?? Clip.none,
        decoration: BoxDecoration(
          color:
              color ??
              CupertinoColors.secondarySystemBackground.resolveFrom(context),
          borderRadius: borderRadius ?? BorderRadius.circular(12),
        ),
        child: content,
      ),
    );
  }
}

class AdaptiveListTile extends StatelessWidget {
  const AdaptiveListTile({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.selected = false,
    this.hideBottomDivider = false,
    this.backgroundColor,
    this.separatorColor,
    this.padding,
  });

  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final bool selected;
  final bool hideBottomDivider;
  final Color? backgroundColor;
  final Color? separatorColor;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    if (!PlatformUiCapabilities.isIOS) {
      return ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        onTap: enabled ? onTap : null,
        onLongPress: enabled ? onLongPress : null,
        enabled: enabled,
        selected: selected,
        tileColor: backgroundColor,
        contentPadding: padding,
      );
    }
    Widget tile = Container(
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color:
            backgroundColor ??
            (selected
                ? CupertinoColors.systemGrey6.resolveFrom(context)
                : CupertinoColors.systemBackground.resolveFrom(context)),
        border: hideBottomDivider
            ? null
            : Border(
                bottom: BorderSide(
                  color:
                      separatorColor ??
                      CupertinoColors.separator.resolveFrom(context),
                  width: 0.5,
                ),
              ),
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ?title,
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  DefaultTextStyle(
                    style: TextStyle(
                      fontSize: 14,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
    if (enabled && (onTap != null || onLongPress != null)) {
      tile = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: tile,
      );
    }
    return tile;
  }
}

class AdaptiveTooltip extends StatelessWidget {
  const AdaptiveTooltip({
    super.key,
    required this.message,
    this.preferBelow = true,
    this.verticalOffset,
    this.padding,
    this.margin,
    this.height,
    this.decoration,
    this.textStyle,
    this.waitDuration,
    this.showDuration,
    required this.child,
  });

  final String message;
  final bool preferBelow;
  final double? verticalOffset;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? height;
  final Decoration? decoration;
  final TextStyle? textStyle;
  final Duration? waitDuration;
  final Duration? showDuration;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: message,
    preferBelow: preferBelow,
    verticalOffset: verticalOffset,
    padding: padding,
    margin: margin,
    constraints: height == null ? null : BoxConstraints(minHeight: height!),
    decoration: decoration,
    textStyle: textStyle,
    waitDuration: waitDuration,
    showDuration: showDuration,
    child: child,
  );
}

class AdaptiveContextMenuAction {
  const AdaptiveContextMenuAction({
    required this.title,
    required this.onPressed,
    this.icon,
    this.isDestructive = false,
    this.isDisabled = false,
  });

  final String title;
  final VoidCallback onPressed;
  final dynamic icon;
  final bool isDestructive;
  final bool isDisabled;
}

class AdaptiveContextMenu extends StatelessWidget {
  const AdaptiveContextMenu({
    super.key,
    required this.child,
    required this.actions,
    this.previewBuilder,
  });

  final Widget child;
  final List<AdaptiveContextMenuAction> actions;
  final Widget Function(BuildContext)? previewBuilder;

  @override
  Widget build(BuildContext context) {
    if (PlatformUiCapabilities.isIOS) {
      return CupertinoContextMenu.builder(
        actions: [
          for (final action in actions)
            CupertinoContextMenuAction(
              onPressed: action.isDisabled
                  ? null
                  : () {
                      Navigator.of(context, rootNavigator: true).pop();
                      Future.microtask(action.onPressed);
                    },
              isDestructiveAction: action.isDestructive,
              trailingIcon: action.icon is IconData
                  ? action.icon as IconData
                  : null,
              child: Text(action.title),
            ),
        ],
        builder: (context, animation) => previewBuilder?.call(context) ?? child,
      );
    }
    return GestureDetector(
      onLongPress: () async {
        final renderObject = context.findRenderObject();
        final overlayObject = Overlay.of(context).context.findRenderObject();
        if (renderObject is! RenderBox ||
            overlayObject is! RenderBox ||
            !renderObject.attached ||
            !overlayObject.attached) {
          return;
        }
        final topLeft = renderObject.localToGlobal(
          Offset.zero,
          ancestor: overlayObject,
        );
        final bottomRight = renderObject.localToGlobal(
          renderObject.size.bottomRight(Offset.zero),
          ancestor: overlayObject,
        );
        final selected = await showMenu<int>(
          context: context,
          position: RelativeRect.fromRect(
            Rect.fromPoints(topLeft, bottomRight),
            Offset.zero & overlayObject.size,
          ),
          items: [
            for (var index = 0; index < actions.length; index++)
              PopupMenuItem<int>(
                value: index,
                enabled: !actions[index].isDisabled,
                child: Text(
                  actions[index].title,
                  style: actions[index].isDestructive
                      ? const TextStyle(color: Colors.red)
                      : null,
                ),
              ),
          ],
        );
        if (selected != null) actions[selected].onPressed();
      },
      child: child,
    );
  }
}

class AdaptiveExpansionTile extends StatefulWidget {
  const AdaptiveExpansionTile({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.children,
    this.onExpansionChanged,
    this.initiallyExpanded = false,
    this.maintainState = false,
    this.tilePadding,
    this.childrenPadding,
    this.backgroundColor,
    this.collapsedBackgroundColor,
    this.textColor,
    this.collapsedTextColor,
    this.iconColor,
    this.collapsedIconColor,
    this.shape,
    this.collapsedShape,
    this.enabled = true,
    this.clipBehavior = Clip.none,
    this.expandedAlignment,
    this.expandedCrossAxisAlignment,
  });

  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final List<Widget> children;
  final ValueChanged<bool>? onExpansionChanged;
  final bool initiallyExpanded;
  final bool maintainState;
  final EdgeInsetsGeometry? tilePadding;
  final EdgeInsetsGeometry? childrenPadding;
  final Color? backgroundColor;
  final Color? collapsedBackgroundColor;
  final Color? textColor;
  final Color? collapsedTextColor;
  final Color? iconColor;
  final Color? collapsedIconColor;
  final ShapeBorder? shape;
  final ShapeBorder? collapsedShape;
  final bool enabled;
  final Clip clipBehavior;
  final Alignment? expandedAlignment;
  final CrossAxisAlignment? expandedCrossAxisAlignment;

  @override
  State<AdaptiveExpansionTile> createState() => _AdaptiveExpansionTileState();
}

class _AdaptiveExpansionTileState extends State<AdaptiveExpansionTile> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant AdaptiveExpansionTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _expanded = widget.initiallyExpanded;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformUiCapabilities.isIOS) {
      return ExpansionTile(
        leading: widget.leading,
        title: widget.title,
        subtitle: widget.subtitle,
        trailing: widget.trailing,
        initiallyExpanded: widget.initiallyExpanded,
        maintainState: widget.maintainState,
        onExpansionChanged: widget.onExpansionChanged,
        tilePadding: widget.tilePadding,
        childrenPadding: widget.childrenPadding,
        backgroundColor: widget.backgroundColor,
        collapsedBackgroundColor: widget.collapsedBackgroundColor,
        textColor: widget.textColor,
        collapsedTextColor: widget.collapsedTextColor,
        iconColor: widget.iconColor,
        collapsedIconColor: widget.collapsedIconColor,
        shape: widget.shape,
        collapsedShape: widget.collapsedShape,
        enabled: widget.enabled,
        clipBehavior: widget.clipBehavior,
        expandedAlignment: widget.expandedAlignment,
        expandedCrossAxisAlignment: widget.expandedCrossAxisAlignment,
        children: widget.children,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled
              ? () {
                  setState(() => _expanded = !_expanded);
                  widget.onExpansionChanged?.call(_expanded);
                }
              : null,
          child: Padding(
            padding:
                widget.tilePadding ??
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                if (widget.leading != null) ...[
                  widget.leading!,
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      widget.title,
                      if (widget.subtitle != null) widget.subtitle!,
                    ],
                  ),
                ),
                widget.trailing ??
                    Icon(
                      _expanded
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 18,
                      color: _expanded
                          ? widget.iconColor
                          : widget.collapsedIconColor,
                    ),
              ],
            ),
          ),
        ),
        if (_expanded || widget.maintainState)
          Offstage(
            offstage: !_expanded,
            child: Padding(
              padding: widget.childrenPadding ?? EdgeInsets.zero,
              child: Column(
                crossAxisAlignment:
                    widget.expandedCrossAxisAlignment ??
                    CrossAxisAlignment.center,
                children: widget.children,
              ),
            ),
          ),
      ],
    );
  }
}
