import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'adaptive_controls.dart';
import 'platform_ui_capabilities.dart';

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
