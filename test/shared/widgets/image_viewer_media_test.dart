import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:conduit/shared/widgets/image_viewer/image_viewer_media.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'conduit_image_export_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => temporary.path,
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await temporary.delete(recursive: true);
  });

  test('AVIF compatible brands beyond the initial prefix determine the staged extension', () async {
    final header = ByteData(8)..setUint32(0, 36);
    header.buffer.asUint8List().setRange(4, 8, ascii.encode('ftyp'));
    final bytes = Uint8List.fromList([
      ...header.buffer.asUint8List(),
      ...ascii.encode('mif1'),
      0,
      0,
      0,
      0,
      ...ascii.encode('mif1miafzzzzMA1Bavif'),
    ]);
    final cached = await File('${temporary.path}/cached-avif')
        .writeAsBytes(bytes);
    final memoryExport = await ImageViewerMedia.bytes(bytes).stage();
    final fileExport = await ImageViewerMedia.file(cached).stage();
    expect(
      [memoryExport.path.split('.').last, fileExport.path.split('.').last],
      ['avif', 'avif'],
    );

    // A later image payload must not be mistaken for a compatible brand.
    final heicHeader = ByteData(8)..setUint32(0, 20);
    heicHeader.buffer.asUint8List().setRange(4, 8, ascii.encode('ftyp'));
    final heic = Uint8List.fromList([
      ...heicHeader.buffer.asUint8List(),
      ...ascii.encode('heic'),
      0,
      0,
      0,
      0,
      ...ascii.encode('mif1'),
      ...ascii.encode('avif'),
    ]);
    final heicExport = await ImageViewerMedia.bytes(heic).stage();
    expect(heicExport.path.endsWith('.heic'), isTrue);
  });

  test('export preserves original bytes and gives cached files their actual image extension', () async {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    );
    final cacheFile = await File('${temporary.path}/opaque-cache-key')
        .writeAsBytes(bytes);
    final staged = await ImageViewerMedia.file(cacheFile).stage();
    check(staged.path.endsWith('/image.png')).isTrue();
    check(await staged.readAsBytes()).deepEquals(bytes);
    check(await cacheFile.exists()).isTrue();
  });

  test(
    'export prunes expired handoffs while retaining current files',
    () async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      final first = await ImageViewerMedia.bytes(bytes).stage();
      final second = await ImageViewerMedia.bytes(bytes).stage();
      check(await first.exists()).isTrue();
      check(await second.exists()).isTrue();
      expect(first.path, isNot(second.path));
      final fresh = await withClock(
        Clock.fixed(DateTime.now().add(const Duration(days: 2))),
        () => ImageViewerMedia.bytes(bytes).stage(),
      );
      check(await first.exists()).isFalse();
      check(await second.exists()).isFalse();
      check(await fresh.exists()).isTrue();
    },
  );
}
