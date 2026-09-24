import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

import 'package:conduit_core/utils/debug_logger.dart';

/// Prefix marking an avatar URL that resolves to a system symbol rather than
/// an image. Mirrors the `asset:` scheme handled alongside it.
const String kNativeSymbolUrlScheme = 'symbol:';

/// Apple's own mark for Apple Intelligence, used to attribute the Foundation
/// Models running on device and on Private Cloud Compute. Available since
/// iOS 18, well below the iOS 26 those models require.
const String kAppleIntelligenceSymbol = 'apple.intelligence';

/// Returns the symbol name in [url] when it uses [kNativeSymbolUrlScheme].
String? nativeSymbolNameFromUrl(String? url) {
  final trimmed = url?.trim();
  if (trimmed == null || !trimmed.startsWith(kNativeSymbolUrlScheme)) {
    return null;
  }
  final name = trimmed.substring(kNativeSymbolUrlScheme.length);
  return name.isEmpty ? null : name;
}

/// Renders one symbol at a point size and pixel density, or null when the
/// platform has no such symbol.
typedef NativeSymbolRenderer =
    Future<Uint8List?> Function(String name, double pointSize, double scale);

/// Rasterizes SF Symbols through UIKit so Flutter-drawn surfaces can paint
/// Apple's glyphs without bundling copies of them.
///
/// Results are cached per name, point size, and device pixel ratio. A resolved
/// entry is readable synchronously, so repainting a list of avatars never waits
/// on the platform again.
class NativeSymbolImageService {
  /// Pass a [renderer] to stand in for the platform. Doing so also marks the
  /// service as supported, so a test can drive the cache off an Apple device.
  NativeSymbolImageService({NativeSymbolRenderer? renderer})
    : _renderer = renderer;

  static NativeSymbolImageService _instance = NativeSymbolImageService();

  static NativeSymbolImageService get instance => _instance;

  /// Swaps the shared service so a widget test can drive glyph timing.
  /// Passing null restores the platform-backed default.
  @visibleForTesting
  static set debugInstance(NativeSymbolImageService? service) {
    _instance = service ?? NativeSymbolImageService();
  }

  static const MethodChannel _channel = MethodChannel(
    'conduit/native_symbol_image',
  );

  final NativeSymbolRenderer? _renderer;
  final Map<String, Uint8List?> _resolved = <String, Uint8List?>{};
  final Map<String, Future<Uint8List?>> _pending = <String, Future<Uint8List?>>{};

  bool get _supported =>
      _renderer != null ||
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  String _keyFor(String name, double pointSize, double scale) =>
      '$name|${pointSize.toStringAsFixed(2)}|${scale.toStringAsFixed(2)}';

  /// The cached rasterization, or null when it has not resolved yet. Callers
  /// paint their own fallback until [load] completes.
  Uint8List? cached(String name, {required double pointSize, required double scale}) =>
      _resolved[_keyFor(name, pointSize, scale)];

  /// Whether a previous [load] settled for these parameters, including the
  /// case where the platform had no such symbol.
  bool isResolved(String name, {required double pointSize, required double scale}) =>
      _resolved.containsKey(_keyFor(name, pointSize, scale));

  Future<Uint8List?> load(
    String name, {
    required double pointSize,
    required double scale,
  }) {
    final key = _keyFor(name, pointSize, scale);
    if (_resolved.containsKey(key)) {
      return Future<Uint8List?>.value(_resolved[key]);
    }
    final inFlight = _pending[key];
    if (inFlight != null) return inFlight;
    if (!_supported || name.isEmpty || pointSize <= 0 || scale <= 0) {
      _resolved[key] = null;
      return Future<Uint8List?>.value();
    }

    final render = _renderer ?? _renderThroughPlatform;
    final request = render(name, pointSize, scale)
        .then((bytes) {
          _resolved[key] = bytes;
          return bytes;
        })
        // A block body matters here: returning the removed entry would hand
        // `whenComplete` the very future it is completing, and wait on it.
        .whenComplete(() {
          _pending.remove(key);
        });
    _pending[key] = request;
    return request;
  }

  static Future<Uint8List?> _renderThroughPlatform(
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

  @visibleForTesting
  void clearCache() {
    _resolved.clear();
    _pending.clear();
  }
}
