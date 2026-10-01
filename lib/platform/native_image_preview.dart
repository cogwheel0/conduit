import 'dart:io';

import 'package:flutter/services.dart';

/// Native code accepts only files in Conduit's image preview staging folder.
abstract final class NativeImagePreview {
  static const _channel = MethodChannel('app.cogwheel.conduit/image_preview');

  /// iOS completes after dismissal. Android completes after handing the file
  /// to the selected app, which may still be reading it asynchronously.
  static Future<void> open(File file) async {
    await _channel.invokeMethod<void>('open', {'path': file.path});
  }

  static Future<void> dismiss() async {
    if (Platform.isIOS) await _channel.invokeMethod<void>('dismiss');
  }
}
