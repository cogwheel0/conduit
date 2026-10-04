import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:conduit_core/features/workspace/services/workspace_model_avatar_bounds.dart';

export 'package:conduit_core/features/workspace/services/workspace_model_avatar_bounds.dart'
    show WorkspaceModelAvatarImage;

/// Bounds workspace-model avatars before they are embedded in model JSON.
///
/// The bounding is conduit_core's pure-Dart [WorkspaceModelAvatarBounds];
/// Flutter's engine codecs decode what `package:image` cannot (HEIC).
abstract final class WorkspaceModelAvatarCodec {
  static const int maxEdge = WorkspaceModelAvatarBounds.maxEdge;

  /// Returns the original bytes when no resize is needed or decoding fails.
  static Future<Uint8List> bound(Uint8List bytes) =>
      WorkspaceModelAvatarBounds.bound(bytes, platformResize: _engineResize);

  /// The bounded avatar with its mime type (see
  /// [WorkspaceModelAvatarBounds.prepare]).
  static Future<WorkspaceModelAvatarImage> prepare(
    Uint8List bytes, {
    String? extension,
  }) => WorkspaceModelAvatarBounds.prepare(
    bytes,
    extension: extension,
    platformResize: _engineResize,
  );

  static Future<Uint8List?> _engineResize(Uint8List bytes, int maxEdge) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final target = WorkspaceModelAvatarBounds.targetSize(
        descriptor.width,
        descriptor.height,
      );
      // Already within the limit: nothing to shrink, and not a failure.
      if (target == null) return bytes;
      codec = await descriptor.instantiateCodec(
        targetWidth: target.width,
        targetHeight: target.height,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
