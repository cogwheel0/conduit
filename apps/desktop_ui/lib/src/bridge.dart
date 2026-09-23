import 'package:conduit_protocol/conduit_protocol.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'desktop_shell.dart';
import 'external_sign_in.dart';
import 'file_picker.dart';
import 'file_saver.dart';
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
  external String? get appVersion;
  external JSPromise<JSObject>? openAuthWindow(JSObject request);
  external JSPromise<JSAny?>? shellSettings(JSAny? patch);
  external JSPromise<JSBoolean>? notify(JSAny request);
  external void onOpen(JSFunction callback);
  external void openInMain(JSAny request);
  external void hideWindow();
  external void windowControl(String action);
  external void onWindowState(JSFunction callback);
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
/// Two attributes and a variable on `<html>`, which is the entire
/// mechanism: `theme.css` carries a `[data-palette][data-mode]` rule for
/// every combination, so a palette change is an attribute write and a
/// repaint.
final class DocumentThemeApplier implements ThemeApplierPort {
  const DocumentThemeApplier();

  @override
  void apply({
    required String paletteId,
    required AppThemeMode mode,
    int uiFontSize = kDefaultUiFontSize,
  }) {
    final root = web.document.documentElement;
    if (root == null) return;
    root.setAttribute('data-palette', paletteId);
    root.setAttribute('data-mode', mode.name);
    (root as web.HTMLElement).style.setProperty(
      '--ui-font-size',
      '${uiFontSize}px',
    );
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

  @override
  Future<String?> pickImageDataUrl({int size = 250}) {
    final element = web.document.createElement('input') as web.HTMLInputElement
      ..type = 'file'
      ..accept = 'image/*';
    final completer = Completer<String?>();
    element.onchange = (web.Event _) {
      final file = element.files?.item(0);
      if (file == null) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      final url = web.URL.createObjectURL(file);
      final image = web.HTMLImageElement();
      image.onload = (web.Event _) {
        // Covering the square, cropped to its middle: a model's picture
        // is shown in a circle, which a letterboxed image would not fill.
        final width = image.naturalWidth;
        final height = image.naturalHeight;
        final scale = [
          size / (width == 0 ? 1 : width),
          size / (height == 0 ? 1 : height),
        ].reduce((a, b) => a > b ? a : b);
        final canvas =
            web.document.createElement('canvas') as web.HTMLCanvasElement
              ..width = size
              ..height = size;
        final context =
            canvas.getContext('2d')! as web.CanvasRenderingContext2D;
        final drawnWidth = width * scale;
        final drawnHeight = height * scale;
        context.drawImage(
          image,
          (size - drawnWidth) / 2,
          (size - drawnHeight) / 2,
          drawnWidth,
          drawnHeight,
        );
        web.URL.revokeObjectURL(url);
        if (!completer.isCompleted) {
          completer.complete(canvas.toDataURL('image/png'));
        }
      }.toJS;
      image.onerror = (web.Event _) {
        web.URL.revokeObjectURL(url);
        if (!completer.isCompleted) completer.complete(null);
      }.toJS;
      image.src = url;
    }.toJS;
    element.oncancel = (web.Event _) {
      if (!completer.isCompleted) completer.complete(null);
    }.toJS;
    element.click();
    return completer.future;
  }
}

/// [FileSaverPort] as a download: a `Blob` behind a detached `<a download>`,
/// which Electron turns into its Save dialog.
final class BrowserFileSaver implements FileSaverPort {
  const BrowserFileSaver();

  @override
  void save({
    required String filename,
    required String mimeType,
    String? text,
    String? base64,
  }) {
    final JSAny part = base64 != null
        ? base64Decode(base64).toJS
        : (text ?? '').toJS;
    final blob = web.Blob(
      <JSAny>[part].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final url = web.URL.createObjectURL(blob);
    (web.document.createElement('a') as web.HTMLAnchorElement)
      ..href = url
      ..download = filename
      ..click();
    // After the click has handed the file over, not before.
    Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
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
      appVersion: bridge.appVersion ?? '0.0.0',
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

/// [DesktopShellPort] over the preload bridge (M9). Requests cross as
/// plain JSON objects, which the main process checks again.
final class ElectronDesktopShell implements DesktopShellPort {
  const ElectronDesktopShell();

  _PreloadBridge get _bridge => _preloadBridge!;

  @override
  bool get available => _preloadBridge != null;

  @override
  bool get focused => web.document.hasFocus();

  @override
  Future<ShellSettings> settings([Map<String, Object?>? patch]) async {
    final result = await _bridge.shellSettings(patch?.jsify())?.toDart;
    final json = result?.dartify();
    return ShellSettings.fromJson(
      json is Map ? json.cast<String, dynamic>() : const <String, dynamic>{},
    );
  }

  @override
  Future<bool> notify({
    required String title,
    String body = '',
    OpenRequest? open,
  }) async {
    final shown = await _bridge
        .notify(
          <String, Object?>{
            'title': title,
            'body': body,
            'open': ?open?.toJson(),
          }.jsify()!,
        )
        ?.toDart;
    return shown?.toDart ?? false;
  }

  @override
  void onOpen(void Function(OpenRequest request) handler) {
    _bridge.onOpen(
      ((JSAny? raw) {
        final json = raw.dartify();
        if (json is! Map) return;
        final request = OpenRequest.fromJson(json.cast<String, dynamic>());
        if (request != null) handler(request);
      }).toJS,
    );
  }

  @override
  void openInMain(OpenRequest request) =>
      _bridge.openInMain(request.toJson().jsify()!);

  @override
  void hideWindow() => _bridge.hideWindow();

  @override
  void windowControl(WindowControl control) =>
      _bridge.windowControl(control.name);

  @override
  void onWindowState(void Function(WindowFrameState state) handler) {
    _bridge.onWindowState(
      ((JSAny? raw) {
        final json = raw.dartify();
        if (json is! Map) return;
        handler(WindowFrameState.fromJson(json.cast<String, dynamic>()));
      }).toJS,
    );
  }
}
