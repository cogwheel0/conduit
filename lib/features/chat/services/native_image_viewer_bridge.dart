import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../../../platform/conduit_platform_apis.g.dart';

/// A local image file handed to the platform.
class NativeImageFile {
  const NativeImageFile({required this.path, this.title});

  final String path;
  final String? title;
}

/// Dart side of the platform image viewer and gallery-save APIs.
///
/// iOS presents Quick Look. Android saves into the shared Pictures
/// collection; its viewer stays in Flutter.
class NativeImageViewerBridge {
  NativeImageViewerBridge._({
    NativeImageViewerHostApi? viewerApi,
    ImageGalleryHostApi? galleryApi,
    bool? isIOS,
    bool? isAndroid,
  }) : _viewerApi = viewerApi ?? NativeImageViewerHostApi(),
       _galleryApi = galleryApi ?? ImageGalleryHostApi(),
       _isIOS = isIOS ?? Platform.isIOS,
       _isAndroid = isAndroid ?? Platform.isAndroid;

  @visibleForTesting
  factory NativeImageViewerBridge.forTesting({
    NativeImageViewerHostApi? viewerApi,
    ImageGalleryHostApi? galleryApi,
    bool isIOS = false,
    bool isAndroid = false,
  }) => NativeImageViewerBridge._(
    viewerApi: viewerApi,
    galleryApi: galleryApi,
    isIOS: isIOS,
    isAndroid: isAndroid,
  );

  static NativeImageViewerBridge instance = NativeImageViewerBridge._();

  final NativeImageViewerHostApi _viewerApi;
  final ImageGalleryHostApi _galleryApi;
  final bool _isIOS;
  final bool _isAndroid;
  Future<bool>? _canSaveImages;

  bool get supportsNativeViewer => _isIOS;

  /// Presents [files] natively and completes once the viewer is dismissed.
  ///
  /// Returns `false` when the viewer could not be shown, so the caller can
  /// fall back to the Flutter viewer. A viewer that is already on screen
  /// counts as shown: a fallback would sit underneath it and appear when it
  /// closes.
  Future<bool> present({
    required List<NativeImageFile> files,
    required int initialIndex,
    Rect? sourceRect,
  }) async {
    if (!supportsNativeViewer || files.isEmpty) return false;
    try {
      await _viewerApi.present(
        PlatformImageViewerRequest(
          items: [
            for (final file in files)
              PlatformImageViewerItem(path: file.path, title: file.title),
          ],
          initialIndex: initialIndex.clamp(0, files.length - 1),
          sourceRect: sourceRect == null
              ? null
              : PlatformRect(
                  x: sourceRect.left,
                  y: sourceRect.top,
                  width: sourceRect.width,
                  height: sourceRect.height,
                ),
        ),
      );
      return true;
    } on PlatformException catch (error, stackTrace) {
      if (error.code == 'ALREADY_PRESENTING') return true;
      DebugLogger.error(
        'native-image-viewer-present-failed',
        scope: 'chat/image-viewer',
        error: error,
        stackTrace: stackTrace,
        data: {'count': files.length},
      );
      return false;
    }
  }

  /// Whether [saveImage] can write to the device gallery without asking for
  /// a storage permission.
  Future<bool> canSaveImages() {
    if (!_isAndroid) return Future.value(false);
    return _canSaveImages ??= _galleryApi.canSaveImages().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      DebugLogger.error(
        'image-gallery-capability-failed',
        scope: 'chat/image-viewer',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    });
  }

  /// Saves the image at [path] to the device gallery. Throws on failure.
  Future<void> saveImage({
    required String path,
    required String mimeType,
    required String displayName,
  }) => _galleryApi.saveImage(path, mimeType, displayName);
}
