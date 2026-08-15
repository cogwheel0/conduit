import 'dart:typed_data';
import 'dart:ui' as ui;

/// Bounds workspace-model avatars before they are embedded in model JSON.
abstract final class WorkspaceModelAvatarCodec {
  static const int maxEdge = 512;

  /// Returns the original bytes when no resize is needed or decoding fails.
  static Future<Uint8List> bound(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      final longest = width > height ? width : height;
      if (longest <= maxEdge) return bytes;

      final scale = maxEdge / longest;
      codec = await descriptor.instantiateCodec(
        targetWidth: (width * scale).round(),
        targetHeight: (height * scale).round(),
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List() ?? bytes;
    } catch (_) {
      return bytes;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
