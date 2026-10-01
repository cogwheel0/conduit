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
