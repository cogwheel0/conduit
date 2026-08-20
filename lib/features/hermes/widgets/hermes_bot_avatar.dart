import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/model_avatar.dart';

/// Renders Hermes' synced shape face, or its uploaded/photo avatar.
class HermesBotAvatar extends StatefulWidget {
  const HermesBotAvatar({
    required this.size,
    required this.label,
    required this.shape,
    required this.color,
    this.imageUrl,
    this.imageKind,
    this.active = false,
    super.key,
  });

  final double size;
  final String label;
  final String shape;
  final String color;
  final String? imageUrl;
  final String? imageKind;
  final bool active;

  @override
  State<HermesBotAvatar> createState() => _HermesBotAvatarState();
}

class _HermesBotAvatarState extends State<HermesBotAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AnimationDuration.extended,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(HermesBotAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  void _syncMotion() {
    if (!widget.active || context.reduceMotion) {
      _controller
        ..stop()
        ..value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Hermes backfills shape/blobatar faces into the profile avatar asset.
    // Prefer that exact render so its face and palette match the dashboard.
    final hasHermesAvatar = widget.imageUrl != null;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Transform.translate(
        offset: Offset(
          0,
          widget.active && !context.reduceMotion
              ? -widget.size *
                    0.03 *
                    (1 - math.cos(2 * math.pi * _controller.value))
              : 0,
        ),
        child: child,
      ),
      child: hasHermesAvatar
          ? ModelAvatar(
              size: widget.size,
              imageUrl: widget.imageUrl,
              label: widget.label,
            )
          : RepaintBoundary(
              child: CustomPaint(
                size: Size.square(widget.size),
                painter: _HermesBotFacePainter(
                  shape: widget.shape,
                  color: _parseColor(widget.color),
                ),
              ),
            ),
    );
  }
}

Color _parseColor(String hex) {
  final value = hex.length == 7 && hex.startsWith('#')
      ? int.tryParse(hex.substring(1), radix: 16)
      : null;
  return Color(0xff000000 | (value ?? 0x8b5cf6));
}

class _HermesBotFacePainter extends CustomPainter {
  const _HermesBotFacePainter({required this.shape, required this.color});

  final String shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final body = Paint()..color = color;
    canvas.drawPath(_shapePath(_classicShape(shape), size), body);

    final luminance = color.computeLuminance();
    final eyeColor = luminance < 0.22
        ? const Color(0xffe8dcc3)
        : const Color(0xd9000000);
    final highlight = luminance < 0.22
        ? const Color(0x99000000)
        : const Color(0xd9ffffff);
    final eyeY = shape.contains('cloud')
        ? size.height * 0.55
        : size.height * 0.43;
    final eyePaint = Paint()..color = eyeColor;
    final shinePaint = Paint()..color = highlight;

    for (final x in [0.385, 0.615]) {
      final center = Offset(size.width * x, eyeY);
      canvas.drawOval(
        Rect.fromCenter(
          center: center,
          width: size.width * 0.11,
          height: size.height * 0.125,
        ),
        eyePaint,
      );
      canvas.drawCircle(
        center.translate(-size.width * 0.014, -size.height * 0.018),
        size.width * 0.016,
        shinePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_HermesBotFacePainter oldDelegate) =>
      shape != oldDelegate.shape || color != oldDelegate.color;
}

String _classicShape(String shape) {
  if (!shape.startsWith('blobatar')) return shape;
  final kind = shape.split(':').last;
  return switch (kind) {
    'capsule' => 'pill',
    'cloud' => 'cloud',
    'droplet' => 'drop',
    'hexagon' => 'hexagon',
    'triangle' => 'triangle',
    'round' || 'sun' => 'circle',
    _ => 'squircle',
  };
}

Path _shapePath(String shape, Size size) {
  final w = size.width;
  final h = size.height;
  switch (shape) {
    case 'squircle':
      return Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.075, h * 0.075, w * 0.85, h * 0.85),
          Radius.circular(w * 0.275),
        ),
      );
    case 'pill':
      return Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.05, h * 0.175, w * 0.9, h * 0.65),
          Radius.circular(h * 0.325),
        ),
      );
    case 'triangle':
      return Path()
        ..moveTo(w * 0.5, h * 0.06)
        ..lineTo(w * 0.93, h * 0.87)
        ..lineTo(w * 0.07, h * 0.87)
        ..close();
    case 'hexagon':
      return Path()
        ..moveTo(w * 0.5, h * 0.04)
        ..lineTo(w * 0.87, h * 0.25)
        ..lineTo(w * 0.87, h * 0.75)
        ..lineTo(w * 0.5, h * 0.96)
        ..lineTo(w * 0.13, h * 0.75)
        ..lineTo(w * 0.13, h * 0.25)
        ..close();
    case 'cloud':
      return Path()
        ..moveTo(w * 0.27, h * 0.8)
        ..cubicTo(w * 0.02, h * 0.8, w * 0.02, h * 0.45, w * 0.25, h * 0.43)
        ..cubicTo(w * 0.3, h * 0.12, w * 0.72, h * 0.14, w * 0.75, h * 0.38)
        ..cubicTo(w * 0.98, h * 0.36, w, h * 0.8, w * 0.73, h * 0.8)
        ..close();
    case 'drop':
      return Path()
        ..moveTo(w * 0.5, h * 0.04)
        ..cubicTo(w * 0.5, h * 0.04, w * 0.15, h * 0.5, w * 0.15, h * 0.68)
        ..cubicTo(w * 0.15, h, w * 0.85, h, w * 0.85, h * 0.68)
        ..cubicTo(w * 0.85, h * 0.5, w * 0.5, h * 0.04, w * 0.5, h * 0.04)
        ..close();
    default:
      return Path()
        ..addOval(Rect.fromLTWH(w * 0.06, h * 0.06, w * 0.88, h * 0.88));
  }
}
