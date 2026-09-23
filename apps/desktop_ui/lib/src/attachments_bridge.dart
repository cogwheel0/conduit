import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:web/web.dart' as web;

import 'attachments.dart';
import 'shell_bridge.dart';

/// [AttachmentPort] against the browser and the daemon (WP-3.3).
///
/// The picked `File` stays in the browser and is handed to `XMLHttpRequest`
/// as the request body, so the bytes never cross into Dart. That is the
/// whole reason this is not an RPC method: a JSON-RPC frame is a string,
/// and a base64 attachment inside one is a third larger, held whole on both
/// sides, and blocks the socket every other call shares.
///
/// `XMLHttpRequest` rather than `fetch` because only it reports upload
/// progress. A request body stream would work in newer engines, but not
/// while also telling the user how far along a 200 MB file is.
final class BrowserAttachments implements AttachmentPort {
  BrowserAttachments(this._bridge);

  final ShellBridge _bridge;
  final Map<String, web.File> _files = <String, web.File>{};
  int _nextHandle = 0;

  @override
  Future<List<PickedAttachment>> pick({String accept = ''}) {
    final element = web.document.createElement('input') as web.HTMLInputElement
      ..type = 'file'
      ..multiple = true
      ..accept = accept;

    final completer = Completer<List<PickedAttachment>>();
    // As with the PEM picker: `cancel` is not universally delivered, so a
    // dismissed dialog can legitimately never complete on an older engine.
    // Not a timeout -- a user reading their filesystem is not a stuck
    // request -- and the composer stays usable either way.
    element.onchange = (web.Event _) {
      if (completer.isCompleted) return;
      completer.complete(_hold(element.files));
    }.toJS;
    element.click();
    return completer.future;
  }

  @override
  Future<String> upload(
    String handle, {
    void Function(double fraction)? onProgress,
  }) {
    final file = _files[handle];
    if (file == null) {
      return Future<String>.error(StateError('no such attachment: $handle'));
    }

    final request = web.XMLHttpRequest();
    final completer = Completer<String>();
    request.open('POST', '${_bridge.httpBase}${ConduitHttpRoutes.upload}');
    // The daemon's own token, not the server's: the renderer never holds a
    // credential for Open WebUI, which is why the upload goes through here
    // at all.
    request.setRequestHeader('authorization', 'Bearer ${_bridge.token}');
    // Percent-encoded because a header is Latin-1 by definition, and an
    // attachment called `résumé.pdf` would otherwise be rejected by the
    // HTTP layer before any of our code ran.
    request.setRequestHeader(
      'x-conduit-filename',
      Uri.encodeComponent(file.name),
    );
    if (file.type.isNotEmpty) {
      request.setRequestHeader('content-type', file.type);
    }

    request.upload.onprogress = (web.ProgressEvent event) {
      if (!event.lengthComputable || event.total == 0) return;
      onProgress?.call(event.loaded / event.total);
    }.toJS;

    request.onload = (web.Event _) {
      if (completer.isCompleted) return;
      if (request.status != 200) {
        completer.completeError(
          RpcError(
            code: _codeFor(request.status),
            debugMessage: request.responseText,
          ),
        );
        return;
      }
      try {
        final decoded =
            jsonDecode(request.responseText) as Map<String, dynamic>;
        final uploaded = UploadedFile.fromJson(decoded);
        _files.remove(handle);
        completer.complete(uploaded.id);
      } on Object catch (error) {
        completer.completeError(error);
      }
    }.toJS;
    request.onerror = (web.Event _) {
      if (completer.isCompleted) return;
      completer.completeError(
        const RpcError(code: ConduitErrorCodes.connectionFailed),
      );
    }.toJS;

    request.send(file);
    return completer.future;
  }

  @override
  void discard(String handle) => _files.remove(handle);

  @override
  bool claimDrag(Object event) {
    final transfer = _transferOf(event as web.Event);
    // `files` is empty until the drop -- the browser withholds them while
    // dragging -- but `types` already says whether there are any.
    final carriesFiles =
        transfer?.types.toDart.any((type) => type.toDart == 'Files') ?? false;
    if (carriesFiles) event.preventDefault();
    return carriesFiles;
  }

  @override
  List<PickedAttachment> takeFiles(Object event) {
    final dom = event as web.Event;
    final picked = _hold(_transferOf(dom)?.files);
    if (picked.isNotEmpty) dom.preventDefault();
    return picked;
  }

  static web.DataTransfer? _transferOf(web.Event event) {
    if (event.isA<web.DragEvent>()) {
      return (event as web.DragEvent).dataTransfer;
    }
    if (event.isA<web.ClipboardEvent>()) {
      return (event as web.ClipboardEvent).clipboardData;
    }
    return null;
  }

  /// Keeps each file in the browser under a new handle.
  web.MediaRecorder? _recorder;
  web.MediaStream? _stream;
  final List<web.Blob> _chunks = <web.Blob>[];

  @override
  Future<bool> startRecording() async {
    if (_recorder != null) return true;
    try {
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(audio: true.toJS))
          .toDart;
      _stream = stream;
      _chunks.clear();
      final recorder = web.MediaRecorder(stream);
      recorder.ondataavailable = (web.BlobEvent event) {
        if (event.data.size > 0) _chunks.add(event.data);
      }.toJS;
      recorder.start();
      _recorder = recorder;
      return true;
    } on Object {
      // No microphone, or permission refused.
      return false;
    }
  }

  @override
  Future<PickedAttachment?> stopRecording() async {
    final recorder = _recorder;
    if (recorder == null) return null;
    final stopped = Completer<void>();
    recorder.onstop = (web.Event _) {
      if (!stopped.isCompleted) stopped.complete();
    }.toJS;
    recorder.stop();
    await stopped.future;
    _recorder = null;
    // Released, so the system's "recording" indicator goes out.
    for (final track
        in _stream?.getTracks().toDart ?? const <web.MediaStreamTrack>[]) {
      track.stop();
    }
    _stream = null;
    if (_chunks.isEmpty) return null;
    final type = recorder.mimeType.isEmpty ? 'audio/webm' : recorder.mimeType;
    final extension = type.contains('ogg') ? 'ogg' : 'webm';
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-');
    final file = web.File(
      _chunks.toJS,
      'Recording $stamp.$extension',
      web.FilePropertyBag(type: type),
    );
    _chunks.clear();
    final handle = 'a${_nextHandle++}';
    _files[handle] = file;
    return PickedAttachment(
      handle: handle,
      name: file.name,
      size: file.size,
      contentType: type,
    );
  }

  List<PickedAttachment> _hold(web.FileList? files) {
    final picked = <PickedAttachment>[];
    for (var i = 0; i < (files?.length ?? 0); i++) {
      final file = files!.item(i);
      if (file == null) continue;
      final handle = 'a${_nextHandle++}';
      _files[handle] = file;
      picked.add(
        PickedAttachment(
          handle: handle,
          name: file.name,
          size: file.size,
          // An empty type is what the browser reports when it cannot
          // tell, which the server copes with better than a guess.
          contentType: file.type,
        ),
      );
    }
    return picked;
  }

  static String _codeFor(int status) => switch (status) {
    401 => ConduitErrorCodes.unauthenticated,
    400 => ConduitErrorCodes.invalidParams,
    503 => ConduitErrorCodes.daemonUnavailable,
    _ => ConduitErrorCodes.serverError,
  };
}
