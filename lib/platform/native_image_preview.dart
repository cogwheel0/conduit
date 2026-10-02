import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native code accepts only files in Conduit's image preview staging folder.
abstract final class NativeImagePreview {
  static const _channel = MethodChannel('app.cogwheel.conduit/image_preview');

  /// iOS completes after dismissal. Android completes after handing the file
  /// to the selected app, which may still be reading it asynchronously.
  static Future<void> open(List<File> files, {int initialIndex = 0}) async {
    await _channel.invokeMethod<void>('open', {
      'path': files[initialIndex].path,
      if (defaultTargetPlatform == TargetPlatform.iOS) ...{
        'paths': [for (final file in files) file.path],
        'initialIndex': initialIndex,
      },
    });
  }

  /// Closes an iOS preview when its originating account or route is invalidated.
  static Future<void> dismiss() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _channel.invokeMethod<void>('dismiss');
    }
  }
}
