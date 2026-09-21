import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'shell_bridge.dart';

export 'shell_bridge.dart';

/// Everything Electron's preload script exposes on `window.conduit`.
///
/// `contextBridge` hands over a frozen plain object, so this is a view over
/// it rather than a class we construct. Reading it is the only way the
/// renderer learns the daemon's port and session token — neither is ever
/// baked into the bundle.
@JS('conduit')
external _PreloadBridge? get _preloadBridge;

extension type _PreloadBridge._(JSObject _) implements JSObject {
  external int? get rpcPort;
  external String? get token;
  external String? get platform;
  external String? get windowKind;
}

/// Reads the preload bridge, falling back to query parameters.
///
/// The fallback exists so the UI can be developed against a hand-started
/// daemon in an ordinary browser. It cannot be a security hole in production:
/// the daemon rejects any socket whose `Origin` is not `app://conduit`, which
/// a browser will not let a page forge.
ShellBridge? resolveShellBridge() {
  final bridge = _preloadBridge;
  final port = bridge?.rpcPort;
  final token = bridge?.token;
  if (bridge != null && port != null && token != null && token.isNotEmpty) {
    return ShellBridge(
      rpcPort: port,
      token: token,
      platform: bridge.platform ?? 'unknown',
      windowKind: ShellBridge.parseWindowKind(bridge.windowKind),
      isElectron: true,
    );
  }

  final query = Uri.parse(web.window.location.href).queryParameters;
  final devPort = int.tryParse(query['port'] ?? '');
  final devToken = query['token'];
  if (devPort != null && devToken != null && devToken.isNotEmpty) {
    return ShellBridge(
      rpcPort: devPort,
      token: devToken,
      platform: 'dev',
      windowKind: ShellBridge.parseWindowKind(query['window']),
      isElectron: false,
    );
  }
  return null;
}
