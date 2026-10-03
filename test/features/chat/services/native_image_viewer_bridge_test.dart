import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/native_image_viewer_bridge.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockViewerApi extends Mock implements NativeImageViewerHostApi {}

class _MockGalleryApi extends Mock implements ImageGalleryHostApi {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      PlatformImageViewerRequest(items: const [], initialIndex: 0),
    );
  });

  const files = [
    NativeImageFile(path: '/tmp/a.png', title: '1 of 2'),
    NativeImageFile(path: '/tmp/b.jpg', title: '2 of 2'),
  ];

  test('iOS sends every file, a clamped index, and the source rect', () async {
    final api = _MockViewerApi();
    when(() => api.present(any())).thenAnswer((_) async {});
    final bridge = NativeImageViewerBridge.forTesting(
      viewerApi: api,
      isIOS: true,
    );

    final presented = await bridge.present(
      files: files,
      initialIndex: 7,
      sourceRect: const Rect.fromLTWH(10, 20, 30, 40),
    );

    check(presented).isTrue();
    final request =
        verify(() => api.present(captureAny())).captured.single
            as PlatformImageViewerRequest;
    check(request.items.map((item) => item.path))
        .deepEquals(['/tmp/a.png', '/tmp/b.jpg']);
    check(request.items.map((item) => item.title))
        .deepEquals(['1 of 2', '2 of 2']);
    check(request.initialIndex).equals(1);
    check(request.sourceRect!.x).equals(10);
    check(request.sourceRect!.y).equals(20);
    check(request.sourceRect!.width).equals(30);
    check(request.sourceRect!.height).equals(40);
  });

  test(
    'a presentation failure reports false for the Flutter fallback',
    () async {
      final api = _MockViewerApi();
      when(() => api.present(any()))
          .thenThrow(PlatformException(code: 'PRESENTATION_FAILED'));
      final bridge = NativeImageViewerBridge.forTesting(
        viewerApi: api,
        isIOS: true,
      );

      check(await bridge.present(files: files, initialIndex: 0)).isFalse();
    },
  );

  test('a viewer already on screen does not trigger the fallback', () async {
    final api = _MockViewerApi();
    when(() => api.present(any()))
        .thenThrow(PlatformException(code: 'ALREADY_PRESENTING'));
    final bridge = NativeImageViewerBridge.forTesting(
      viewerApi: api,
      isIOS: true,
    );

    check(await bridge.present(files: files, initialIndex: 0)).isTrue();
  });

  test('other platforms never call the native viewer', () async {
    final api = _MockViewerApi();
    final bridge = NativeImageViewerBridge.forTesting(
      viewerApi: api,
      isAndroid: true,
    );

    check(bridge.supportsNativeViewer).isFalse();
    check(await bridge.present(files: files, initialIndex: 0)).isFalse();
    verifyNever(() => api.present(any()));
  });

  test('gallery saving is asked once and only on Android', () async {
    final gallery = _MockGalleryApi();
    when(gallery.canSaveImages).thenAnswer((_) async => true);
    final android = NativeImageViewerBridge.forTesting(
      galleryApi: gallery,
      isAndroid: true,
    );
    check(await android.canSaveImages()).isTrue();
    check(await android.canSaveImages()).isTrue();
    verify(gallery.canSaveImages).called(1);

    final ios = NativeImageViewerBridge.forTesting(
      galleryApi: gallery,
      isIOS: true,
    );
    check(await ios.canSaveImages()).isFalse();
    verifyNever(gallery.canSaveImages);
  });
}
