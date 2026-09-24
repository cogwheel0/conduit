import 'dart:async';

import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import 'sandbox_port.dart';

/// The two messages the sandbox sends back.
///
/// An extension type rather than `dart:js_interop_unsafe`, for the same
/// reason the preload bridge is one: string-keyed access is untyped, and a
/// field renamed on the other side should be a compile error here rather
/// than a silent null.
extension type _SandboxMessage._(JSObject _) implements JSObject {
  external String? get conduit;
  external int? get height;
}

/// [SandboxPort] against real frames.
///
/// One `message` listener on the window for every frame, rather than one
/// each: the listener has to identify the sender by `event.source`, and a
/// sandboxed frame's origin is the opaque string "null" -- so an
/// origin-based filter would let any sandboxed frame on the page speak for
/// any other. Window identity is the only real check, and it needs the
/// whole registry to resolve.
final class DocumentSandbox implements SandboxPort {
  DocumentSandbox() {
    _listener = ((web.Event event) => _onMessage(
      event as web.MessageEvent,
    )).toJS;
    web.window.addEventListener('message', _listener);
  }

  final Map<String, _Frame> _frames = <String, _Frame>{};
  final StreamController<({String frameId, int height})> _heights =
      StreamController<({String frameId, int height})>.broadcast();
  late final web.EventListener _listener;

  @override
  Stream<({String frameId, int height})> get heights => _heights.stream;

  @override
  void render(String frameId, SandboxPayload payload) {
    final frame = _frames.putIfAbsent(frameId, () => _Frame(frameId));
    frame.pending = payload;
    if (frame.ready) _post(frameId, frame);
  }

  @override
  void release(String frameId) => _frames.remove(frameId);

  void dispose() {
    web.window.removeEventListener('message', _listener);
    unawaited(_heights.close());
  }

  void _onMessage(web.MessageEvent event) {
    final source = event.source;
    if (source == null) return;
    // Find whose window this is. A sandboxed frame is cross-origin, so the
    // only readable property is identity -- which is enough, and is the
    // property that actually matters.
    String? frameId;
    for (final entry in _frames.entries) {
      if (entry.value.window == source) {
        frameId = entry.key;
        break;
      }
    }
    if (frameId == null) return;

    final data = event.data;
    if (data == null || !data.isA<JSObject>()) return;
    final message = data as _SandboxMessage;
    switch (message.conduit) {
      case 'ready':
        final frame = _frames[frameId]!;
        frame.ready = true;
        if (frame.pending != null) _post(frameId, frame);
      case 'size':
        if (message.height case final height?) {
          _heights.add((frameId: frameId, height: height));
        }
    }
  }

  void _post(String frameId, _Frame frame) {
    final payload = frame.pending;
    final target = frame.window;
    if (payload == null || target == null) return;
    // `'*'` because the frame's origin is opaque and cannot be named. The
    // payload carries nothing secret -- it is the model's own words, on
    // their way to being drawn -- and the frame cannot reach anything.
    target.postMessage(payload.toJson().jsify(), '*'.toJS);
  }
}

/// One embedded frame.
///
/// The frame id *is* the element's `id` attribute -- [SandboxedRender] sets
/// it -- so there is nothing to register. An earlier version had the
/// component call an `attach` method to associate the two, and nothing
/// ever did: every message was dropped because the registry had no element
/// to look a window up from, and the frame sat at its placeholder height
/// forever. One source for the association is why that cannot recur.
final class _Frame {
  _Frame(this.id);

  final String id;
  bool ready = false;
  SandboxPayload? pending;

  /// Read on every use rather than cached: `contentWindow` is null until
  /// the frame has navigated, and the element itself is replaced whenever
  /// the component remounts.
  web.Window? get window {
    final element = web.document.getElementById(id);
    if (!element.isA<web.HTMLIFrameElement>()) return null;
    return (element! as web.HTMLIFrameElement).contentWindow;
  }
}
