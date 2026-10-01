import 'package:flutter/services.dart';

import 'package:conduit_core/utils/debug_logger.dart';

// The cache moved to conduit_core behind a host renderer; re-exported for
// this file's importers. This file keeps the Flutter renderer.
export 'package:conduit_core/services/native_symbol_image_service.dart';

const MethodChannel _channel = MethodChannel('conduit/native_symbol_image');

/// Renders a symbol through `NativeSymbolImageBridge.swift`. `lib/main.dart`
/// installs it as `NativeSymbolImageService.hostRenderer` on iOS.
Future<Uint8List?> renderNativeSymbolThroughChannel(
  String name,
  double pointSize,
  double scale,
) async {
  try {
    return await _channel.invokeMethod<Uint8List>('render', <String, Object>{
      'name': name,
      'pointSize': pointSize,
      'scale': scale,
    });
  } catch (error, stackTrace) {
    DebugLogger.error(
      'native-symbol-render-failed',
      scope: 'native-symbol/image',
      error: error,
      stackTrace: stackTrace,
      data: {'name': name},
    );
    return null;
  }
}
