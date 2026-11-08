import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

// The symbol URL scheme lives beside the other model icon rules; re-exported
// so an avatar needs one import.
export 'package:conduit_core/utils/model_icon_utils.dart'
    show
        kAppleIntelligenceSymbol,
        kNativeSymbolUrlScheme,
        nativeSymbolNameFromUrl;

/// A symbol's size relative to the text it sits beside, as SF Symbols
/// defines it: the stroke weight stays matched to the point size, only the
/// artwork grows or shrinks. [small] lets a glyph that fills more of its box
/// than its neighbours match them in ink without looking thinner.
enum NativeSymbolScale { small, medium, large }

/// Renders one symbol at a point size, symbol scale and pixel density as PNG
/// bytes (white artwork on transparency, for the caller to tint), or null
/// when the platform has no such symbol.
typedef NativeSymbolRenderer = Future<Uint8List?> Function(
  String name,
  double pointSize,
  double scale,
  NativeSymbolScale symbolScale,
);

/// Rasterizes system symbols (SF Symbols) so avatars can paint Apple's glyphs
/// without bundling copies of them.
///
/// The app installs [hostRenderer] at startup: a UIKit method channel
/// (`lib/core/services/native_symbol_image_service.dart`). Where none is
/// installed
/// (Android, the daemon, tests) every load settles as "no such symbol" and
/// the avatar keeps its own mark.
///
/// Results are cached per name, point size, symbol scale and device pixel
/// ratio. A resolved
/// entry is readable synchronously, so repainting a list of avatars never
/// waits on the platform again.
class NativeSymbolImageService {
  /// Pass a [renderer] to stand in for the host. Doing so also marks the
  /// service as supported, so a test can drive the cache off an Apple device.
  NativeSymbolImageService({NativeSymbolRenderer? renderer})
    : _renderer = renderer;

  /// The host's renderer, installed once at startup. Null where the platform
  /// has no system symbols.
  static NativeSymbolRenderer? hostRenderer;

  static NativeSymbolImageService _instance = NativeSymbolImageService();

  static NativeSymbolImageService get instance => _instance;

  /// Swaps the shared service so a widget test can drive glyph timing.
  /// Passing null restores the host-backed default.
  @visibleForTesting
  static set debugInstance(NativeSymbolImageService? service) {
    _instance = service ?? NativeSymbolImageService();
  }

  final NativeSymbolRenderer? _renderer;
  final Map<String, Uint8List?> _resolved = <String, Uint8List?>{};
  final Map<String, Future<Uint8List?>> _pending =
      <String, Future<Uint8List?>>{};

  NativeSymbolRenderer? get _activeRenderer => _renderer ?? hostRenderer;

  String _keyFor(
    String name,
    double pointSize,
    double scale,
    NativeSymbolScale symbolScale,
  ) =>
      '$name|${pointSize.toStringAsFixed(2)}|${scale.toStringAsFixed(2)}'
      '|${symbolScale.name}';

  /// The cached rasterization, or null when it has not resolved yet. Callers
  /// paint their own fallback until [load] completes.
  Uint8List? cached(
    String name, {
    required double pointSize,
    required double scale,
    NativeSymbolScale symbolScale = NativeSymbolScale.medium,
  }) => _resolved[_keyFor(name, pointSize, scale, symbolScale)];

  /// Whether a previous [load] settled for these parameters, including the
  /// case where the platform had no such symbol.
  bool isResolved(
    String name, {
    required double pointSize,
    required double scale,
    NativeSymbolScale symbolScale = NativeSymbolScale.medium,
  }) => _resolved.containsKey(_keyFor(name, pointSize, scale, symbolScale));

  Future<Uint8List?> load(
    String name, {
    required double pointSize,
    required double scale,
    NativeSymbolScale symbolScale = NativeSymbolScale.medium,
  }) {
    final key = _keyFor(name, pointSize, scale, symbolScale);
    if (_resolved.containsKey(key)) {
      return Future<Uint8List?>.value(_resolved[key]);
    }
    final inFlight = _pending[key];
    if (inFlight != null) return inFlight;
    final render = _activeRenderer;
    if (render == null || name.isEmpty || pointSize <= 0 || scale <= 0) {
      _resolved[key] = null;
      return Future<Uint8List?>.value();
    }

    final request = render(name, pointSize, scale, symbolScale)
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

  @visibleForTesting
  void clearCache() {
    _resolved.clear();
    _pending.clear();
  }
}
