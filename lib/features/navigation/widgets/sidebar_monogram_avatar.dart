import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../../../shared/theme/theme_extensions.dart';

/// Neutral gradient and ink of a monogram avatar, as iOS draws a contact
/// without a photo: grey in both appearances, never a hue.
///
/// The greys are dark enough that the white initials reach 4.5:1 against
/// every part of the gradient, in both appearances. The native Settings card
/// (`nativeMonogramUIImage` in NativeSheetBridge.swift) draws the same
/// colours, so the sidebar and Settings show one monogram.
@immutable
class SidebarMonogramColors {
  const SidebarMonogramColors({
    required this.top,
    required this.bottom,
    required this.foreground,
  });

  /// The light-appearance monogram.
  static const light = SidebarMonogramColors(
    top: Color(0xFF737378),
    bottom: Color(0xFF5A5A5F),
    foreground: Color(0xFFFFFFFF),
  );

  /// The dark-appearance monogram, a step darker so it does not glare.
  static const dark = SidebarMonogramColors(
    top: Color(0xFF6A6A6F),
    bottom: Color(0xFF4E4E53),
    foreground: Color(0xFFFFFFFF),
  );

  static SidebarMonogramColors of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  final Color top;
  final Color bottom;
  final Color foreground;
}

/// Paints [initials] centred on a grey gradient disc filling [rect].
void paintSidebarMonogram(
  Canvas canvas,
  Rect rect,
  String initials,
  SidebarMonogramColors colors,
) {
  final disc = Paint()
    ..isAntiAlias = true
    ..shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [colors.top, colors.bottom],
    ).createShader(rect);
  canvas.drawOval(rect, disc);
  if (initials.isEmpty) return;
  final painter = TextPainter(
    text: TextSpan(
      text: initials,
      style: TextStyle(
        color: colors.foreground,
        fontSize: rect.height * 0.4,
        fontWeight: FontWeight.w600,
        height: 1,
        letterSpacing: rect.height * 0.01,
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout(maxWidth: rect.width);
  painter.paint(
    canvas,
    rect.center - Offset(painter.width / 2, painter.height / 2),
  );
  painter.dispose();
}

/// The user's initials on a neutral disc, for an account without a photo.
class SidebarMonogramAvatar extends StatelessWidget {
  const SidebarMonogramAvatar({
    super.key,
    required this.initials,
    required this.size,
  });

  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: _MonogramPainter(
          initials: initials,
          colors: context.conduitTheme.isDark
              ? SidebarMonogramColors.dark
              : SidebarMonogramColors.light,
        ),
      ),
    );
  }
}

class _MonogramPainter extends CustomPainter {
  const _MonogramPainter({required this.initials, required this.colors});

  final String initials;
  final SidebarMonogramColors colors;

  @override
  void paint(Canvas canvas, Size size) =>
      paintSidebarMonogram(canvas, Offset.zero & size, initials, colors);

  @override
  bool shouldRepaint(_MonogramPainter oldDelegate) =>
      initials != oldDelegate.initials || colors != oldDelegate.colors;
}

/// A monogram for the native glass profile button: [diameter] points centred
/// in a [canvasExtent] square, like the photo that button otherwise shows.
typedef SidebarMonogramRasterRequest = ({
  String initials,
  double canvasExtent,
  double diameter,
  double devicePixelRatio,
  Brightness brightness,
});

/// PNG bytes of a [SidebarMonogramRasterRequest], or null if drawing fails.
Future<Uint8List?> rasterizeSidebarMonogram(
  SidebarMonogramRasterRequest request,
) async {
  final scale = request.devicePixelRatio.isFinite
      ? request.devicePixelRatio.clamp(1.0, 4.0)
      : 1.0;
  final canvasPixels = (request.canvasExtent * scale).round();
  if (canvasPixels <= 0) return null;
  ui.Image? image;
  try {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale);
    final center = Offset(request.canvasExtent / 2, request.canvasExtent / 2);
    paintSidebarMonogram(
      canvas,
      Rect.fromCenter(
        center: center,
        width: request.diameter,
        height: request.diameter,
      ),
      request.initials,
      SidebarMonogramColors.of(request.brightness),
    );
    final picture = recorder.endRecording();
    try {
      image = await picture.toImage(canvasPixels, canvasPixels);
    } finally {
      picture.dispose();
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'Failed to draw sidebar monogram',
      error: error,
      stackTrace: stackTrace,
      scope: 'navigation/sidebar/monogram',
    );
    return null;
  } finally {
    image?.dispose();
  }
}

/// Cached [rasterizeSidebarMonogram] results, one per initials, size and
/// appearance.
final sidebarMonogramRasterProvider =
    FutureProvider.family<Uint8List?, SidebarMonogramRasterRequest>(
      (ref, request) => rasterizeSidebarMonogram(request),
    );
