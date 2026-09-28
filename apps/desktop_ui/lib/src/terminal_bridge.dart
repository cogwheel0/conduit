import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:web/web.dart' as web;

import 'shell_bridge.dart';
import 'terminal_port.dart';

/// xterm.js, loaded by index.html from the vendored copy.
@JS('Terminal')
extension type _XTerm._(JSObject _) implements JSObject {
  external factory _XTerm(JSAny options);

  external void open(web.HTMLElement host);
  external void write(JSAny data);
  external void loadAddon(JSObject addon);
  external void onData(JSFunction handler);
  external void onResize(JSFunction handler);
  external void attachCustomKeyEventHandler(JSFunction handler);
  external int get cols;
  external int get rows;
  external String getSelection();
  external bool hasSelection();
  external void paste(String text);
  external void focus();
  external void dispose();
}

@JS('FitAddon.FitAddon')
extension type _FitAddon._(JSObject _) implements JSObject {
  external factory _FitAddon();

  external void fit();
}

extension type _Size._(JSObject _) implements JSObject {
  external int get cols;
  external int get rows;
}

/// [TerminalViewPort] over xterm.js and the daemon's terminal tunnel.
final class XtermTerminal implements TerminalViewPort {
  const XtermTerminal(this._bridge);

  final ShellBridge _bridge;

  @override
  TerminalViewSession open(
    String hostId, {
    required String handle,
    required void Function(TerminalLinkState state) onState,
  }) {
    final host = web.document.getElementById(hostId) as web.HTMLElement?;
    if (host == null) {
      onState(TerminalLinkState.failed);
      return _NoSession();
    }
    while (host.firstChild != null) {
      host.removeChild(host.firstChild!);
    }
    final terminal = _XTerm(
      <String, Object?>{
        'cursorBlink': true,
        'fontFamily':
            'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
        'fontSize': 13,
        'scrollback': 5000,
        'theme': _theme(host),
      }.jsify()!,
    );
    final fit = _FitAddon();
    terminal.loadAddon(fit);
    terminal.open(host);
    fit.fit();

    // The daemon checks the same two things it checks on /rpc: the origin,
    // which the browser sets, and the session token, offered as a
    // subprotocol because a browser socket cannot carry a header.
    final socket = web.WebSocket(
      '${_bridge.httpBase.replace(scheme: 'ws')}'
      '${ConduitHttpRoutes.terminal(handle)}',
      buildSubprotocols(_bridge.token).map((p) => p.toJS).toList().toJS,
    )..binaryType = 'arraybuffer';
    final session = _XtermSession(terminal, fit, socket, host);
    onState(TerminalLinkState.connecting);

    void send(Map<String, Object> frame) {
      if (socket.readyState == web.WebSocket.OPEN) {
        socket.send(jsonEncode(frame).toJS);
      }
    }

    void resize() => send(<String, Object>{
      'type': 'resize',
      'cols': terminal.cols,
      'rows': terminal.rows,
    });

    socket.onopen = (web.Event _) {
      onState(TerminalLinkState.connected);
      resize();
      session._ping = Timer.periodic(
        const Duration(seconds: 25),
        (_) => send(const <String, Object>{'type': 'ping'}),
      );
      terminal.focus();
    }.toJS;
    socket.onmessage = (web.MessageEvent event) {
      final data = event.data;
      if (data.isA<JSArrayBuffer>()) {
        terminal.write((data! as JSArrayBuffer).toDart.asUint8List().toJS);
      } else if (data.isA<JSString>()) {
        terminal.write(data!);
      }
    }.toJS;
    var opened = false;
    socket.addEventListener(
      'open',
      (web.Event _) {
        opened = true;
      }.toJS,
    );
    socket.onclose = (web.CloseEvent _) {
      session._ping?.cancel();
      if (session._closed) return;
      terminal.write('\r\n[disconnected]\r\n'.toJS);
      onState(
        opened ? TerminalLinkState.disconnected : TerminalLinkState.failed,
      );
    }.toJS;

    // Keystrokes go up as bytes, which is what the shell reads.
    terminal.onData(
      (JSString data) {
        if (socket.readyState == web.WebSocket.OPEN) {
          socket.send(utf8.encode(data.toDart).toJS);
        }
      }.toJS,
    );
    terminal.onResize(
      (_Size _) {
        resize();
      }.toJS,
    );
    // Copy and paste on Ctrl+Shift+C and V, as terminals do: plain Ctrl+C
    // belongs to the shell.
    terminal.attachCustomKeyEventHandler(
      (web.KeyboardEvent event) {
        if (event.type != 'keydown' || !event.ctrlKey || !event.shiftKey) {
          return true;
        }
        final key = event.key.toLowerCase();
        if (key == 'c') {
          unawaited(session.copy());
          return false;
        }
        if (key == 'v') {
          unawaited(session.paste());
          return false;
        }
        return true;
      }.toJS,
    );
    // The app's shortcuts listen on the document. Keys typed into the
    // terminal are the shell's -- Ctrl+K, Ctrl+L, Ctrl+Shift+O -- so they
    // stop here.
    host.addEventListener(
      'keydown',
      (web.Event event) {
        event.stopPropagation();
      }.toJS,
    );
    session._observer = web.ResizeObserver(
      (JSArray<web.ResizeObserverEntry> _, web.ResizeObserver _) {
        fit.fit();
      }.toJS,
    )..observe(host);
    return session;
  }

  /// The palette's colours, which are CSS -- often `oklch()`, which xterm
  /// cannot read -- turned into `rgb()` through a canvas.
  static Map<String, String> _theme(web.HTMLElement host) {
    final style = web.window.getComputedStyle(host);
    String read(String variable, String fallback) {
      final value = style.getPropertyValue(variable).trim();
      return value.isEmpty ? fallback : _rgb(value) ?? fallback;
    }

    final background = read('--color-card', '#111111');
    final foreground = read('--color-foreground', '#eeeeee');
    return <String, String>{
      'background': background,
      'foreground': foreground,
      'cursor': foreground,
      'selectionBackground': read('--color-accent', '#555555'),
    };
  }

  static String? _rgb(String css) {
    final canvas = web.document.createElement('canvas') as web.HTMLCanvasElement
      ..width = 1
      ..height = 1;
    final context = canvas.getContext('2d') as web.CanvasRenderingContext2D?;
    if (context == null) return null;
    context
      ..fillStyle = css.toJS
      ..fillRect(0, 0, 1, 1);
    final pixel = context.getImageData(0, 0, 1, 1).data.toDart;
    return 'rgb(${pixel[0]}, ${pixel[1]}, ${pixel[2]})';
  }
}

final class _XtermSession implements TerminalViewSession {
  _XtermSession(this._terminal, this._fit, this._socket, this._host);

  final _XTerm _terminal;
  final _FitAddon _fit;
  final web.WebSocket _socket;
  final web.HTMLElement _host;
  Timer? _ping;
  web.ResizeObserver? _observer;
  bool _closed = false;

  @override
  void fit() => _fit.fit();

  @override
  void focus() => _terminal.focus();

  @override
  Future<bool> copy() async {
    if (!_terminal.hasSelection()) return false;
    await web.window.navigator.clipboard
        .writeText(_terminal.getSelection())
        .toDart;
    return true;
  }

  @override
  Future<void> paste() async {
    final text =
        (await web.window.navigator.clipboard.readText().toDart).toDart;
    if (text.isNotEmpty) _terminal.paste(text);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _ping?.cancel();
    _observer?.disconnect();
    _socket.close();
    _terminal.dispose();
    while (_host.firstChild != null) {
      _host.removeChild(_host.firstChild!);
    }
  }
}

final class _NoSession implements TerminalViewSession {
  @override
  void fit() {}

  @override
  void focus() {}

  @override
  Future<bool> copy() async => false;

  @override
  Future<void> paste() async {}

  @override
  void close() {}
}
