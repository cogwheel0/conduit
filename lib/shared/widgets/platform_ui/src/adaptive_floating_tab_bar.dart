import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'adaptive_controls.dart';
import 'adaptive_floating_action_button.dart';
import 'adaptive_glass_controls.dart';
import 'platform_ui_capabilities.dart';

/// Native view type registered by the iOS app delegate.
const String _kNativeViewType = 'conduit/floating_tab_bar';

/// Room above the native bar for its selection lens, and for the tabs to
/// swell while pressed.
const double _kNativeTabBarHeadroom = 24;

/// Default height of an [AdaptiveFloatingTabBar]: the minimum touch target,
/// which toolbar buttons use too.
const double kAdaptiveFloatingBarDefaultExtent = 44;

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

  /// Bitmap asset the iOS 26 tab bar tints as a template, so only its alpha
  /// shows.
  final String nativeAsset;

  /// Longest side of [nativeAsset] on screen, in points. The native bar
  /// shrinks to [AdaptiveFloatingTabBar.controlExtent] and draws the icon for
  /// that scale, so it matches glyphs of the same size elsewhere.
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
/// by one native view so UIKit lines them up, and scaled so both are
/// [controlExtent] tall. Elsewhere it is a Material navigation bar in a pill
/// beside a floating action button of the same height. Fewer than two [tabs]
/// leave only the action.
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
    this.controlExtent = kAdaptiveFloatingBarDefaultExtent,
    this.edgeInset = 16,
    this.minimumBottomInset = 16,
    this.actionSymbolSize = 18,
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

  /// Height of the tabs and the action's diameter: the size of the window's
  /// other toolbar buttons, so the bar matches them.
  final double controlExtent;

  /// Inset of the tabs and the action from the sides of the window, as the
  /// window's toolbar insets its buttons.
  final double edgeInset;

  /// Least gap below the bar, on a window whose bottom safe area is smaller.
  /// The bar otherwise sits on the safe area.
  final double minimumBottomInset;

  /// Point size of the action's SF Symbol on iOS, as the window's other glass
  /// buttons draw theirs.
  final double actionSymbolSize;

  /// Room the bar takes from the bottom of the window, for a bar
  /// [controlExtent] tall with at least [minimumBottomInset] below it.
  static double extentOf(
    BuildContext context, {
    double controlExtent = kAdaptiveFloatingBarDefaultExtent,
    double minimumBottomInset = 16,
  }) => _bottomInset(context, minimumBottomInset) + controlExtent;

  /// Gap between the bar and the bottom of the window.
  static double _bottomInset(BuildContext context, double minimum) =>
      math.max(MediaQuery.viewPaddingOf(context).bottom, minimum);

  /// Renders the native bar's tab icons. Widget tests, which run inside fake
  /// async, swap in a synchronous renderer.
  @visibleForTesting
  static AdaptiveFloatingTabIconRenderer debugIconRenderer = renderNativeIcon;

  /// Restores [debugIconRenderer] and forgets icons rendered so far.
  @visibleForTesting
  static void debugReset() {
    debugIconRenderer = renderNativeIcon;
    _renderedIcons.clear();
  }

  static final Map<String, Uint8List> _renderedIcons = {};

  /// Renders the bitmap [asset] as a PNG whose longest side is [size] points
  /// at [scale], because UIKit draws a bitmap at its own size.
  static Future<Uint8List> renderNativeIcon(
    AssetBundle bundle,
    String asset,
    double size,
    double scale,
  ) async {
    final pixels = (size * scale).round();
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
    final ui.Image image;
    try {
      image = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  @override
  State<AdaptiveFloatingTabBar> createState() => _AdaptiveFloatingTabBarState();
}

/// Renders one tab icon for the native bar; see
/// [AdaptiveFloatingTabBar.renderNativeIcon].
typedef AdaptiveFloatingTabIconRenderer =
    Future<Uint8List> Function(
      AssetBundle bundle,
      String asset,
      double size,
      double scale,
    );

class _AdaptiveFloatingTabBarState extends State<AdaptiveFloatingTabBar> {
  MethodChannel? _channel;
  String? _iconsKey;

  /// Icons for the tabs named by [_iconsKey], once all have rendered.
  List<Uint8List>? _icons;
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
    final keys = [for (final tab in widget.tabs) _iconKey(bundle, tab, scale)];
    final key = keys.join('|');
    if (key == _iconsKey) return;
    _iconsKey = key;
    _icons = null;
    final rendered = AdaptiveFloatingTabBar._renderedIcons;
    // Icons rendered before, by this bar or another, appear in the first
    // frame instead of after a blank one.
    if (keys.every(rendered.containsKey)) {
      _icons = [for (final key in keys) rendered[key]!];
      return;
    }
    Future.wait([for (final tab in widget.tabs) _icon(bundle, tab, scale)])
        .then((icons) {
          if (!mounted || _iconsKey != key) return;
          setState(() => _icons = icons);
        });
  }

  /// Keyed by bundle too: another bundle can hold a different image at the
  /// same asset path.
  static String _iconKey(
    AssetBundle bundle,
    AdaptiveFloatingTab tab,
    double scale,
  ) =>
      '${identityHashCode(bundle)}:${tab.nativeAsset}@${tab.nativeIconSize}x'
      '$scale';

  /// A tab's rendered icon, or no image when it cannot be rendered, so the
  /// bar still appears with its labelled tabs.
  static Future<Uint8List> _icon(
    AssetBundle bundle,
    AdaptiveFloatingTab tab,
    double scale,
  ) async {
    final key = _iconKey(bundle, tab, scale);
    final rendered = AdaptiveFloatingTabBar._renderedIcons;
    if (rendered[key] case final icon?) return icon;
    try {
      final icon = await AdaptiveFloatingTabBar.debugIconRenderer(
        bundle,
        tab.nativeAsset,
        tab.nativeIconSize,
        scale,
      );
      return rendered[key] = icon;
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'platform_ui',
          context: ErrorDescription('rendering the tab icon ${tab.nativeAsset}'),
        ),
      );
      return Uint8List(0);
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
      // Sent even when unset, so clearing a color restores the system's.
      'tint': widget.selectedItemColor?.toARGB32(),
      'unselectedTint': widget.unselectedItemColor?.toARGB32(),
      'controlExtent': widget.controlExtent,
      'edgeInset': widget.edgeInset,
      'bottomInset': AdaptiveFloatingTabBar._bottomInset(
        context,
        widget.minimumBottomInset,
      ),
      'actionSymbol': widget.action.sfSymbol,
      'actionSymbolSize': widget.actionSymbolSize,
      'actionLabel': widget.action.label,
      'actionTint': widget.actionForegroundColor?.toARGB32(),
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
        AdaptiveFloatingTabBar.extentOf(
          context,
          controlExtent: widget.controlExtent,
          minimumBottomInset: widget.minimumBottomInset,
        ) +
        _kNativeTabBarHeadroom;
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    // While new tabs' icons render, the view keeps showing the tabs it has.
    if (_icons case final icons?) _sendUpdate(_nativeParams(icons, isDark));
    return SizedBox(
      height: height,
      child: _sentParams == null
          ? null
          : UiKitView(
              viewType: _kNativeViewType,
              creationParams: _sentParams,
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _onPlatformViewCreated,
              gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
                Factory<TapGestureRecognizer>(() => TapGestureRecognizer()),
              },
            ),
    );
  }

  Widget _buildFlutter(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        widget.edgeInset,
        0,
        widget.edgeInset,
        AdaptiveFloatingTabBar._bottomInset(context, widget.minimumBottomInset),
      ),
      child: SizedBox(
        height: widget.controlExtent,
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
    final borderRadius = BorderRadius.circular(widget.controlExtent / 2);
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
                height: widget.controlExtent,
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
        dimension: widget.controlExtent,
        child: AdaptiveFloatingActionButton(
          onPressed: action.onPressed,
          semanticLabel: action.label,
          // Round, as the toolbar's buttons and the pill's ends are.
          shape: const CircleBorder(),
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
          size: widget.actionSymbolSize,
          color: widget.actionForegroundColor,
        ),
        dimension: widget.controlExtent,
      ),
    );
  }
}
