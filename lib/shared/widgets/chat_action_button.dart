import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/core/services/native_symbol_image_service.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

class ChatActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// The SF Symbol drawn in place of [icon] on iOS, rasterized by UIKit so a
  /// row of buttons shares Apple's own weight and optical size, and matches
  /// native buttons beside it. [icon] stays the fallback elsewhere.
  final String? sfSymbol;

  /// The square hit target.
  final double size;

  /// The glyph's point size.
  final double iconSize;

  /// The SF Symbol's scale at [iconSize]: [NativeSymbolScale.small] draws a
  /// glyph that fills more of its box than its neighbours at their ink size
  /// without thinning its strokes.
  final NativeSymbolScale symbolScale;

  /// The glyph's colour; defaults to the label colour at 80%.
  final Color? color;

  /// Whether a tap plays the selection haptic. Turn it off when the action
  /// plays a feedback of its own, such as Copy's confirmation.
  final bool hapticFeedback;

  const ChatActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.sfSymbol,
    this.size = 32,
    this.iconSize = IconSize.sm + 2,
    this.symbolScale = NativeSymbolScale.medium,
    this.color,
    this.hapticFeedback = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final handleTap = onTap == null
        ? null
        : () {
            if (hapticFeedback) ConduitHaptics.selectionClick();
            onTap!();
          };

    final base = color ?? theme.textPrimary.withValues(alpha: 0.8);
    final foreground = handleTap == null
        ? base.withValues(alpha: base.a * 0.45)
        : base;
    final symbol = sfSymbol;
    final glyph = symbol != null && NativeSymbolGlyph.isAvailable
        ? NativeSymbolGlyph(
            symbol: symbol,
            fallbackIcon: icon,
            pointSize: iconSize,
            symbolScale: symbolScale,
            color: foreground,
          )
        : Icon(icon, size: iconSize, color: foreground);

    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 600),
      // The button below names itself; the tooltip would read it twice.
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        enabled: handleTap != null,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: handleTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: AnimatedSwitcher(
                duration: context.motionDuration(
                  const Duration(milliseconds: 160),
                ),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.8, end: 1).animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey<Object>(symbol ?? icon),
                  child: glyph,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An SF Symbol drawn by UIKit at [pointSize], [symbolScale] and regular
/// weight, cached as an image and tinted with [color]. Shows [fallbackIcon]
/// where the system has no such symbol.
class NativeSymbolGlyph extends StatefulWidget {
  const NativeSymbolGlyph({
    super.key,
    required this.symbol,
    required this.fallbackIcon,
    required this.pointSize,
    required this.color,
    this.symbolScale = NativeSymbolScale.medium,
  });

  final String symbol;
  final IconData fallbackIcon;
  final double pointSize;
  final Color color;
  final NativeSymbolScale symbolScale;

  /// Whether this platform rasterizes SF Symbols (iOS, with the host
  /// renderer installed at startup).
  static bool get isAvailable =>
      PlatformUiCapabilities.isIOS &&
      NativeSymbolImageService.hostRenderer != null;

  /// Starts rasterizing [symbol] ahead of need, so a glyph that is about to
  /// replace another (Stop taking Send's place as a message goes) is drawn
  /// on its first frame rather than a frame later.
  static void prewarm(BuildContext context, String symbol, double pointSize) {
    if (!isAvailable) return;
    final scale = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3;
    final service = NativeSymbolImageService.instance;
    if (service.isResolved(symbol, pointSize: pointSize, scale: scale)) {
      return;
    }
    unawaited(service.load(symbol, pointSize: pointSize, scale: scale));
  }

  @override
  State<NativeSymbolGlyph> createState() => _NativeSymbolGlyphState();
}

class _NativeSymbolGlyphState extends State<NativeSymbolGlyph> {
  Uint8List? _bytes;
  bool _failed = false;
  ({String name, double size, double scale, NativeSymbolScale symbolScale})?
  _requested;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant NativeSymbolGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.symbol != widget.symbol ||
        oldWidget.pointSize != widget.pointSize ||
        oldWidget.symbolScale != widget.symbolScale) {
      _resolve();
    }
  }

  void _resolve() {
    final scale = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3;
    final request = (
      name: widget.symbol,
      size: widget.pointSize,
      scale: scale,
      symbolScale: widget.symbolScale,
    );
    if (request == _requested) return;
    _requested = request;
    final service = NativeSymbolImageService.instance;
    final cached = service.cached(
      request.name,
      pointSize: request.size,
      scale: request.scale,
      symbolScale: request.symbolScale,
    );
    if (cached != null ||
        service.isResolved(
          request.name,
          pointSize: request.size,
          scale: request.scale,
          symbolScale: request.symbolScale,
        )) {
      _bytes = cached;
      _failed = cached == null;
      return;
    }
    _bytes = null;
    _failed = false;
    service
        .load(
          request.name,
          pointSize: request.size,
          scale: request.scale,
          symbolScale: request.symbolScale,
        )
        .then((bytes) {
          // A newer request owns the glyph now.
          if (!mounted || _requested != request) return;
          setState(() {
            _bytes = bytes;
            _failed = bytes == null;
          });
        });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        scale: _requested?.scale ?? 3,
        color: widget.color,
        colorBlendMode: BlendMode.srcIn,
        gaplessPlayback: true,
        excludeFromSemantics: true,
      );
    }
    if (_failed) {
      return Icon(
        widget.fallbackIcon,
        size: widget.pointSize,
        color: widget.color,
      );
    }
    // The first request takes a frame; keep the slot empty rather than flash
    // a different glyph.
    return SizedBox.square(dimension: widget.pointSize);
  }
}
