import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import 'adaptive_controls.dart';
import 'adaptive_floating_action_button.dart';
import 'adaptive_glass_controls.dart';
import 'platform_ui_capabilities.dart';

/// Native view type registered by the iOS app delegate.
const String _kNativeViewType = 'conduit/floating_tab_bar';

/// Height of a phone tab bar above the bottom safe area.
const double _kNativeTabBarHeight = 49;

/// Room above the native bar for its selection lens and round action.
const double _kNativeTabBarHeadroom = 24;

/// How far the native round action rises above the bar's platter.
const double _kNativeTabBarActionOverhang = 4;

const double _kMaterialBarHeight = 56;
const double _kMaterialBarMargin = 16;

/// One icon-only destination in an [AdaptiveFloatingTabBar].
class AdaptiveFloatingTab {
  const AdaptiveFloatingTab({
    required this.label,
    required this.icon,
    required this.nativeAsset,
    this.nativeIconSize = 24,
  });

  /// Read by screen readers, and shown as the Material tooltip.
  final String label;

  /// Drawn by Flutter, tinted through the ambient [IconTheme].
  final Widget icon;

  /// SVG or bitmap asset the iOS 26 tab bar tints as a template.
  final String nativeAsset;

  /// Longest side of [nativeAsset] in the native tab bar, in points.
  final double nativeIconSize;
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
/// On iOS 26 this is the system tab bar beside a Liquid Glass button, drawn
/// by one native view so UIKit lines them up. Elsewhere it is a Material
/// navigation bar in a pill beside a floating action button. Fewer than two
/// [tabs] leave only the action.
class AdaptiveFloatingTabBar extends StatefulWidget {
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
  }) : assert(tabs.length <= 5);

  final List<AdaptiveFloatingTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onTap;
  final AdaptiveFloatingBarAction action;
  final double itemWidth;
  final Color? selectedItemColor;
  final Color? unselectedItemColor;

  /// Icon colour of the action.
  final Color? actionForegroundColor;

  /// Fill of the Material action. The iOS 26 action is glass.
  final Color? actionBackgroundColor;

  /// Fill of the Material pill. The iOS 26 bar draws its own glass.
  final Color? backgroundColor;

  /// Outline of the Material pill.
  final Color? borderColor;

  /// Keys for the Flutter-drawn tabs and action, which the native bar draws
  /// in one view.
  final Key? tabsKey;
  final Key? actionKey;

  /// Room the bar takes from the bottom of the window.
  static double extentOf(BuildContext context) {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    if (PlatformUiCapabilities.usesNativeIOS26) {
      return safeBottom + _kNativeTabBarHeight + _kNativeTabBarActionOverhang;
    }
    return _materialBottomInset(safeBottom) + _kMaterialBarHeight;
  }

  static double _materialBottomInset(double safeBottom) =>
      safeBottom > 0 ? safeBottom : _kMaterialBarMargin;

  @override
  State<AdaptiveFloatingTabBar> createState() => _AdaptiveFloatingTabBarState();
}

class _AdaptiveFloatingTabBarState extends State<AdaptiveFloatingTabBar> {
  static final Map<String, Future<Uint8List>> _iconCache = {};

  MethodChannel? _channel;
  Future<List<Uint8List>>? _icons;
  String? _iconsKey;
  Map<String, Object?>? _sentParams;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (PlatformUiCapabilities.usesNativeIOS26) _loadIcons();
  }

  @override
  void didUpdateWidget(covariant AdaptiveFloatingTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (PlatformUiCapabilities.usesNativeIOS26) _loadIcons();
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _loadIcons() {
    final bundle = DefaultAssetBundle.of(context);
    final scale = MediaQuery.devicePixelRatioOf(context);
    final key = [
      for (final tab in widget.tabs) '${tab.nativeAsset}@${tab.nativeIconSize}',
      '$scale',
    ].join('|');
    if (key == _iconsKey) return;
    _iconsKey = key;
    _icons = Future.wait([
      for (final tab in widget.tabs) _icon(bundle, tab, scale),
    ]);
  }

  /// A tab's rendered icon, or no image when it cannot be rendered, so the
  /// bar still appears with its labelled tabs.
  static Future<Uint8List> _icon(
    AssetBundle bundle,
    AdaptiveFloatingTab tab,
    double scale,
  ) {
    final key = '${tab.nativeAsset}@${tab.nativeIconSize}x$scale';
    return _iconCache.putIfAbsent(
      key,
      () => _rasterize(bundle, tab.nativeAsset, tab.nativeIconSize, scale)
          .catchError((Object _) {
            _iconCache.remove(key);
            return Uint8List(0);
          }),
    );
  }

  /// Renders an asset at the size the native bar draws it, since UIKit
  /// reads neither SVG nor a bitmap's intended point size.
  static Future<Uint8List> _rasterize(
    AssetBundle bundle,
    String asset,
    double size,
    double scale,
  ) async {
    final pixels = (size * scale).round();
    ui.Image image;
    if (asset.endsWith('.svg')) {
      final info = await vg.loadPicture(
        SvgAssetLoader(asset, assetBundle: bundle),
        null,
      );
      try {
        final recorder = ui.PictureRecorder();
        final factor = pixels / info.size.longestSide;
        ui.Canvas(recorder)
          ..scale(factor)
          ..drawPicture(info.picture);
        final picture = recorder.endRecording();
        try {
          image = await picture.toImage(
            (info.size.width * factor).round(),
            (info.size.height * factor).round(),
          );
        } finally {
          picture.dispose();
        }
      } finally {
        info.picture.dispose();
      }
    } else {
      final data = await bundle.load(asset);
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final landscape = descriptor.width >= descriptor.height;
      final codec = await descriptor.instantiateCodec(
        targetWidth: landscape ? pixels : null,
        targetHeight: landscape ? null : pixels,
      );
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
        descriptor.dispose();
        buffer.dispose();
      }
    }
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  Map<String, Object?> _nativeParams(List<Uint8List> icons, bool isDark) {
    final scale = MediaQuery.devicePixelRatioOf(context);
    return {
      'tabs': [
        for (var index = 0; index < widget.tabs.length; index++)
          {
            'label': widget.tabs[index].label,
            'image': icons[index],
            'imageScale': scale,
            'iconSize': widget.tabs[index].nativeIconSize,
          },
      ],
      'selectedIndex': widget.selectedIndex,
      'itemWidth': widget.itemWidth,
      'isDark': isDark,
      'tint': ?widget.selectedItemColor?.toARGB32(),
      'unselectedTint': ?widget.unselectedItemColor?.toARGB32(),
      'actionSymbol': widget.action.sfSymbol,
      'actionLabel': widget.action.label,
      'actionTint': ?widget.actionForegroundColor?.toARGB32(),
    };
  }

  void _onPlatformViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final channel = MethodChannel('${_kNativeViewType}_$id');
    _channel = channel;
    // Catch up on anything that changed while the view was being created.
    if (_sentParams case final params?) {
      channel.invokeMethod<void>('update', params).catchError((_) {});
    }
    channel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'select':
          final index = call.arguments as int?;
          if (index != null && index >= 0 && index < widget.tabs.length) {
            widget.onTap(index);
          }
        case 'action':
          widget.action.onPressed();
      }
    });
  }

  void _sendUpdate(Map<String, Object?> params) {
    final sent = _sentParams;
    _sentParams = params;
    if (sent == null || _channel == null || _sameParams(sent, params)) return;
    _channel!.invokeMethod<void>('update', params).catchError((_) {});
  }

  static bool _sameParams(Map<String, Object?> a, Map<String, Object?> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      final value = entry.value;
      if (value is List && other is List) {
        if (value.length != other.length) return false;
        for (var i = 0; i < value.length; i++) {
          final x = value[i];
          final y = other[i];
          if (x is Map && y is Map) {
            if (!mapEquals(x, y)) return false;
          } else if (x != y) {
            return false;
          }
        }
      } else if (value != other) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformUiCapabilities.usesNativeIOS26) return _buildNative(context);
    return _buildFlutter(context);
  }

  Widget _buildNative(BuildContext context) {
    final height =
        MediaQuery.viewPaddingOf(context).bottom +
        _kNativeTabBarHeight +
        _kNativeTabBarHeadroom;
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return SizedBox(
      height: height,
      child: FutureBuilder<List<Uint8List>>(
        future: _icons,
        builder: (context, snapshot) {
          final icons = snapshot.data;
          if (icons == null) return const SizedBox.expand();
          final params = _nativeParams(icons, isDark);
          _sendUpdate(params);
          return UiKitView(
            viewType: _kNativeViewType,
            creationParams: _sentParams,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _onPlatformViewCreated,
            gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
              Factory<TapGestureRecognizer>(() => TapGestureRecognizer()),
            },
          );
        },
      ),
    );
  }

  Widget _buildFlutter(BuildContext context) {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _kMaterialBarMargin,
        0,
        _kMaterialBarMargin,
        AdaptiveFloatingTabBar._materialBottomInset(safeBottom),
      ),
      child: SizedBox(
        height: _kMaterialBarHeight,
        child: Row(
          children: [
            if (widget.tabs.length >= 2) _buildPill(context),
            const Spacer(),
            _buildAction(),
          ],
        ),
      ),
    );
  }

  Widget _buildPill(BuildContext context) {
    final borderRadius = BorderRadius.circular(_kMaterialBarHeight / 2);
    final selectedColor =
        widget.selectedItemColor ?? Theme.of(context).colorScheme.primary;
    final unselectedColor =
        widget.unselectedItemColor ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      key: widget.tabsKey,
      width: widget.itemWidth * widget.tabs.length,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.backgroundColor,
          borderRadius: borderRadius,
          border: widget.borderColor == null
              ? null
              : Border.all(color: widget.borderColor!),
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
                height: _kMaterialBarHeight,
                selectedIndex: widget.selectedIndex,
                onDestinationSelected: widget.onTap,
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                indicatorColor: selectedColor.withValues(alpha: 0.12),
                labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
                destinations: [
                  for (final tab in widget.tabs)
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
    final action = widget.action;
    if (!PlatformUiCapabilities.isIOS) {
      return SizedBox.square(
        key: widget.actionKey,
        dimension: _kMaterialBarHeight,
        child: AdaptiveFloatingActionButton(
          onPressed: action.onPressed,
          semanticLabel: action.label,
          backgroundColor: widget.actionBackgroundColor,
          foregroundColor: widget.actionForegroundColor,
          child: Icon(action.icon),
        ),
      );
    }
    // The glass fallback has no label of its own; announce one control.
    return Semantics(
      key: widget.actionKey,
      label: action.label,
      button: true,
      excludeSemantics: true,
      onTap: action.onPressed,
      child: NativeGlassIconButton(
        onPressed: action.onPressed,
        symbol: SFSymbol(
          action.sfSymbol,
          size: 18,
          color: widget.actionForegroundColor,
        ),
        dimension: _kMaterialBarHeight,
      ),
    );
  }
}
