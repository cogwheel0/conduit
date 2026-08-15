import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:checks/checks.dart';
import 'package:conduit/features/navigation/widgets/sidebar_user_pill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native avatar raster keeps a circular 28pt image inside a 44pt canvas',
    () async {
      final source = await _solidPng();
      final raster = await rasterizeSidebarNativeAvatar(
        source,
        devicePixelRatio: 3,
      );
      check(raster).isNotNull();

      final codec = await ui.instantiateImageCodec(raster!);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      check(image.width).equals(132);
      check(image.height).equals(132);

      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      check(data).isNotNull();
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
      check(maxX - minX + 1).equals(84);
      check(maxY - minY + 1).equals(84);
      check(minX).equals(24);
      check(minY).equals(24);

      int alphaAt(int x, int y) => pixels[((y * image.width) + x) * 4 + 3];
      check(alphaAt(24, 24)).equals(0);
      check(alphaAt(66, 66)).equals(255);

      image.dispose();
      codec.dispose();
    },
  );

  test(
    'native avatar center-crops rectangular sources without stretching',
    () async {
      final source = await _stripedPng();
      final raster = await rasterizeSidebarNativeAvatar(
        source,
        devicePixelRatio: 1,
      );
      check(raster).isNotNull();

      final codec = await ui.instantiateImageCodec(raster!);
      final image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      check(data).isNotNull();
      final pixels = data!.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );

      ui.Color pixelAt(int x, int y) {
        final offset = ((y * image.width) + x) * 4;
        return ui.Color.fromARGB(
          pixels[offset + 3],
          pixels[offset],
          pixels[offset + 1],
          pixels[offset + 2],
        );
      }

      // The 6x2 source has red and blue outer thirds with a green center.
      // A centered square crop contains only the green middle two columns.
      for (final x in [10, 22, 33]) {
        final pixel = pixelAt(x, 22);
        check(pixel.g).isGreaterThan(pixel.r);
        check(pixel.g).isGreaterThan(pixel.b);
      }

      image.dispose();
      codec.dispose();
    },
  );

  test('avatar raster requests use their stable cache key', () {
    final first = SidebarNativeAvatarRasterRequest(
      cacheKey: 'avatar:1',
      bytes: Uint8List.fromList([1, 2, 3]),
      devicePixelRatio: 3,
    );
    final rebuilt = SidebarNativeAvatarRasterRequest(
      cacheKey: 'avatar:1',
      bytes: Uint8List.fromList([1, 2, 3]),
      devicePixelRatio: 3,
    );
    final changed = SidebarNativeAvatarRasterRequest(
      cacheKey: 'avatar:2',
      bytes: Uint8List.fromList([1, 2, 3]),
      devicePixelRatio: 3,
    );

    check(rebuilt).equals(first);
    check(changed == first).isFalse();
  });
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

Future<Uint8List> _stripedPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 2, 2),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(2, 0, 2, 2),
    ui.Paint()..color = const ui.Color(0xFF00FF00),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(4, 0, 2, 2),
    ui.Paint()..color = const ui.Color(0xFF0000FF),
  );
  final image = await recorder.endRecording().toImage(6, 2);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
