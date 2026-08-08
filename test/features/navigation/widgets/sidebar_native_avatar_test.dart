import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:conduit/features/navigation/widgets/sidebar_user_pill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native avatar raster keeps a 28pt image inside a 44pt canvas',
    () async {
      final source = await _solidPng();
      final raster = await rasterizeSidebarNativeAvatar(
        source,
        devicePixelRatio: 3,
      );
      expect(raster, isNotNull);

      final codec = await ui.instantiateImageCodec(raster!);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      expect(image.width, 132);
      expect(image.height, 132);

      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(data, isNotNull);
      final pixels = data!.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      var minX = image.width;
      var minY = image.height;
      var maxX = -1;
      var maxY = -1;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          if (pixels[((y * image.width) + x) * 4 + 3] == 0) continue;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
      expect(maxX - minX + 1, 84);
      expect(maxY - minY + 1, 84);
      expect(minX, 24);
      expect(minY, 24);

      image.dispose();
      codec.dispose();
    },
  );
}

Future<Uint8List> _solidPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 2, 2),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final image = await recorder.endRecording().toImage(2, 2);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
