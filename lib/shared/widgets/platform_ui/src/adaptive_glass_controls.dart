import 'dart:ui' as ui;

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'adaptive_controls.dart';
import 'platform_ui_capabilities.dart';

/// Image-and-label variant of the package's native popup menu control.
///
/// Its UIKit view supports both, while the package's Flutter constructors
/// currently expose separate label-only and image-only variants.
class NativeGlassMenuButton extends StatefulWidget {
  const NativeGlassMenuButton({
    super.key,
    required this.label,
    required this.assetName,
    required this.options,
    required this.selectedIndex,
    required this.onSelected,
    required this.foregroundColor,
    required this.height,
    this.imageTint,
  });

  final String label;
  final String assetName;
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Color foregroundColor;
  final Color? imageTint;
  final double height;

  @override
  State<NativeGlassMenuButton> createState() => _NativeGlassMenuButtonState();
}

class _NativeGlassMenuButtonState extends State<NativeGlassMenuButton> {
  static const _iconSize = 24.0;

  MethodChannel? _channel;
  AssetBundle? _bundle;
  double? _imageScale;
  late Future<Uint8List> _image;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bundle = DefaultAssetBundle.of(context);
    final scale = MediaQuery.devicePixelRatioOf(context);
    if (identical(bundle, _bundle) && scale == _imageScale) return;
    _bundle = bundle;
    _imageScale = scale;
    _image = _loadImage();
  }

  @override
  void didUpdateWidget(covariant NativeGlassMenuButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetName != widget.assetName) _image = _loadImage();
  }

  Future<Uint8List> _loadImage() async {
    final pixels = (_iconSize * _imageScale!).round();
    final data = await _bundle!.load(widget.assetName);
    // UIKit's asset-path loader does not resize raster images. Keep both their
    // intrinsic 24-point size and original colors by supplying scaled pixels.
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      targetWidth: pixels,
      targetHeight: pixels,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final png = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        return png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _image,
      builder: (context, snapshot) =>
          snapshot.connectionState == ConnectionState.done
          ? _buildButton(context, snapshot.data)
          : SizedBox(height: widget.height),
    );
  }

  Widget _buildButton(BuildContext context, Uint8List? image) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return SizedBox(
      height: widget.height,
      child: UiKitView(
        key: ValueKey((
          widget.label,
          widget.assetName,
          widget.options.join('\u0000'),
          widget.selectedIndex,
          widget.foregroundColor,
          widget.imageTint,
          _imageScale,
          _bundle,
          isDark,
        )),
        viewType: 'CupertinoNativePopupMenuButton',
        creationParams: <String, Object?>{
          'buttonTitle': widget.label,
          'buttonImageData': ?image,
          'buttonIconSize': _iconSize,
          if (widget.imageTint != null)
            'buttonIconColor': widget.imageTint!.toARGB32(),
          'buttonStyle': CNButtonStyle.glass.name,
          'labels': widget.options,
          'checked': [
            for (var i = 0; i < widget.options.length; i++)
              i == widget.selectedIndex,
          ],
          'isDark': isDark,
          'style': {'tint': widget.foregroundColor.toARGB32()},
          'preserveTopToBottomOrder': true,
        },
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<TapGestureRecognizer>(() => TapGestureRecognizer()),
        },
      ),
    );
  }

  void _onPlatformViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final channel = MethodChannel('CupertinoNativePopupMenuButton_$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted || call.method != 'itemSelected') return;
      final index = ((call.arguments as Map?)?['index'] as num?)?.toInt();
      if (index != null && index >= 0 && index < widget.options.length) {
        widget.onSelected(index);
      }
    });
  }
}

/// An icon-only native glass button whose system halo may paint beyond its
/// layout bounds while retaining a bounded hit target.
class NativeGlassIconButton extends StatefulWidget {
  const NativeGlassIconButton({
    super.key,
    required this.onPressed,
    required this.symbol,
    required this.dimension,
  });

  final VoidCallback onPressed;
  final SFSymbol symbol;
  final double dimension;

  @override
  State<NativeGlassIconButton> createState() => _NativeGlassIconButtonState();
}

class _NativeGlassIconButtonState extends State<NativeGlassIconButton> {
  MethodChannel? _channel;
  bool? _lastIsDark;
  String? _lastSymbolName;
  double? _lastSymbolSize;
  int? _lastSymbolColor;

  bool get _isDark => CupertinoTheme.brightnessOf(context) == Brightness.dark;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isDark = _isDark;
    if (_lastIsDark != isDark) {
      _lastIsDark = isDark;
      _channel
          ?.invokeMethod<void>('setBrightness', {'isDark': isDark})
          .catchError((_) {});
    }
    _syncSymbol();
  }

  @override
  void didUpdateWidget(covariant NativeGlassIconButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSymbol();
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformUiCapabilities.usesNativeIOS26) {
      return AdaptiveButton.sfSymbol(
        onPressed: widget.onPressed,
        sfSymbol: widget.symbol,
        style: AdaptiveButtonStyle.glass,
        minSize: Size.square(widget.dimension),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(widget.dimension),
        useSmoothRectangleBorder: false,
        useNative: false,
      );
    }

    final symbolColor = widget.symbol.color;
    final creationParams = <String, Object?>{
      'buttonIconName': widget.symbol.name,
      'buttonIconSize': widget.symbol.size,
      if (symbolColor != null) 'buttonIconColor': symbolColor.toARGB32(),
      'round': true,
      'buttonStyle': CNButtonStyle.glass.name,
      'enabled': true,
      'isDark': _isDark,
      'imagePlacement': CNImagePlacement.leading.name,
      'minHeight': widget.dimension,
      'borderRadius': widget.dimension / 2,
      'glassEffectInteractive': true,
      'interaction': true,
    };

    return SizedBox.square(
      dimension: widget.dimension,
      child: UiKitView(
        viewType: 'CupertinoNativeButton',
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<TapGestureRecognizer>(() => TapGestureRecognizer()),
        },
      ),
    );
  }

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('CupertinoNativeButton_$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'pressed' && mounted) widget.onPressed();
    });
    _lastSymbolName = null;
    _lastSymbolSize = null;
    _lastSymbolColor = null;
    _syncSymbol();
  }

  void _syncSymbol() {
    final channel = _channel;
    if (channel == null) return;

    final name = widget.symbol.name;
    final size = widget.symbol.size;
    final color = widget.symbol.color?.toARGB32();
    if (_lastSymbolName == name &&
        _lastSymbolSize == size &&
        _lastSymbolColor == color) {
      return;
    }

    _lastSymbolName = name;
    _lastSymbolSize = size;
    _lastSymbolColor = color;
    channel
        .invokeMethod<void>('setButtonIcon', {
          'buttonIconName': name,
          'buttonIconSize': size,
          'buttonIconColor': ?color,
        })
        .catchError((_) {});
  }
}

/// A non-interactive Liquid Glass backdrop for Flutter-owned content.
///
/// On iOS 26 and later this stretches the package's native
/// [LiquidGlassContainer] across the available bounds so Flutter widgets can
/// be composited above authentic system glass. Other platforms intentionally
/// receive no surface; callers should provide their own Cupertino or Material
/// fallback decoration.
class AdaptiveGlassBackdrop extends StatelessWidget {
  const AdaptiveGlassBackdrop({
    super.key,
    required this.borderRadius,
    this.prominent = false,
    this.autoHideOnModal = true,
  });

  final BorderRadius borderRadius;
  final bool prominent;
  final bool autoHideOnModal;

  @override
  Widget build(BuildContext context) {
    if (!PlatformUiCapabilities.usesNativeIOS26) {
      return const SizedBox.expand();
    }

    final radius = borderRadius.resolve(Directionality.of(context)).topLeft.x;

    return ExcludeSemantics(
      child: LiquidGlassContainer(
        config: LiquidGlassConfig(
          effect: prominent ? CNGlassEffect.prominent : CNGlassEffect.regular,
          shape: CNGlassEffectShape.rect,
          cornerRadius: radius,
          interactive: false,
        ),
        autoHideOnModal: autoHideOnModal,
        child: const SizedBox.expand(),
      ),
    );
  }
}
