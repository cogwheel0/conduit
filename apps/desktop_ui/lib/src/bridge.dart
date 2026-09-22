import 'package:conduit_protocol/conduit_protocol.dart';

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'external_sign_in.dart';
import 'file_picker.dart';
import 'shell_bridge.dart';
import 'theme_applier.dart';

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
  external JSPromise<JSObject>? openAuthWindow(JSObject request);
}

/// The request object literal the preload bridge expects.
///
/// An `external factory` rather than building a [JSObject] by hand: it avoids
/// `dart:js_interop_unsafe` -- which is untyped string-keyed access -- and
/// makes a renamed field a compile error on this side.
extension type _AuthWindowRequest._(JSObject _) implements JSObject {
  external factory _AuthWindowRequest({
    required String startUrl,
    required String serverUrl,
    String? title,
  });
}

extension type _AuthWindowResult._(JSObject _) implements JSObject {
  external String get status;
  external String? get origin;
  external JSAny? get cookies;
  external String? get token;
}

/// [ExternalSignInPort] backed by the preload bridge.
final class ElectronExternalSignIn implements ExternalSignInPort {
  const ElectronExternalSignIn();

  @override
  Future<ExternalSignIn> run({
    required String startUrl,
    required String serverUrl,
    String? title,
  }) async {
    final pending = _preloadBridge?.openAuthWindow(
      _AuthWindowRequest(
        startUrl: startUrl,
        serverUrl: serverUrl,
        title: title,
      ),
    );
    if (pending == null) {
      throw UnsupportedError('the preload bridge exposes no auth window');
    }
    final result = _AuthWindowResult._(await pending.toDart);

    return switch (result.status) {
      'completed' => ExternalSignInCaptured(
        origin: result.origin ?? serverUrl,
        cookies: _readCookies(result.cookies),
        token: result.token,
      ),
      'timeout' => const ExternalSignInAbandoned(timedOut: true),
      _ => const ExternalSignInAbandoned(timedOut: false),
    };
  }

  /// The captured jar is a plain JS object, so it converts to a
  /// `Map<Object?, Object?>` rather than to anything typed. Non-string values
  /// are dropped rather than coerced: a cookie value is a string, and
  /// anything else means this is not the object we think it is.
  static Map<String, String> _readCookies(JSAny? raw) {
    final converted = raw?.dartify();
    if (converted is! Map) return const <String, String>{};
    return <String, String>{
      for (final entry in converted.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }
}

/// [ThemeApplierPort] writing to the document element.
///
/// Two attributes on `<html>`, which is the entire mechanism: `theme.css`
/// carries a `[data-palette][data-mode]` rule for every combination, so a
/// palette change is an attribute write and a repaint.
final class DocumentThemeApplier implements ThemeApplierPort {
  const DocumentThemeApplier();

  @override
  void apply({required String paletteId, required AppThemeMode mode}) {
    final root = web.document.documentElement;
    if (root == null) return;
    root.setAttribute('data-palette', paletteId);
    root.setAttribute('data-mode', mode.name);
  }
}

/// [FilePickerPort] using a detached `<input type="file">`.
///
/// Detached, and never attached to the document: the picker only needs the
/// element to exist and be clicked, so building one per call avoids a hidden
/// input sitting in the tree collecting focus and screen-reader attention for
/// the rest of the session.
final class BrowserFilePicker implements FilePickerPort {
  const BrowserFilePicker();

  @override
  Future<PickedTextFile?> pickText({required String accept}) {
    final element = web.document.createElement('input') as web.HTMLInputElement
      ..type = 'file'
      ..accept = accept;

    final completer = Completer<PickedTextFile?>();
    // `cancel` is not universally delivered, so this can legitimately never
    // complete if the user dismisses the dialog on an older engine. The
    // caller's busy state is cleared by the change event or by the page being
    // left; deliberately not a timeout, because a user reading their
    // filesystem is not a stuck request.
    element.onchange = (web.Event _) {
      final files = element.files;
      if (files == null || files.length == 0) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      final file = files.item(0)!;
      final reader = web.FileReader();
      reader.onload = (web.Event _) {
        if (completer.isCompleted) return;
        final result = reader.result;
        completer.complete(
          result.isA<JSString>()
              ? (name: file.name, content: (result! as JSString).toDart)
              : null,
        );
      }.toJS;
      reader.onerror = (web.Event _) {
        if (!completer.isCompleted) completer.complete(null);
      }.toJS;
      reader.readAsText(file);
    }.toJS;

    element.oncancel = (web.Event _) {
      if (!completer.isCompleted) completer.complete(null);
    }.toJS;

    element.click();
    return completer.future;
  }
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
