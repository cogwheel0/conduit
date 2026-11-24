import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/services/api_service.dart'
    show FileContentTooLargeException;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:stream_channel/stream_channel.dart';

import 'files_service.dart';
import 'in_process_host.dart' show InProcessProtocolHost;
import 'media_service.dart';
import 'protocol_services.dart';

/// A request on one of the protocol's byte routes, whatever carried it.
final class ByteRequest {
  const ByteRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.read,
  });

  final String method;

  /// The path, without its leading slash, and the query.
  final Uri url;

  /// By lower-case name.
  final Map<String, String> headers;

  /// The body, read once.
  ///
  /// A chunk handed over is the route's: the host never writes to its bytes
  /// again, so a route may keep chunks without copying them (`_collect`
  /// does). `conduitd`'s are `dart:io`'s views of each socket read, which
  /// it never reuses; [InProcessProtocolHost] copies each frame's payload.
  final Stream<List<int>> Function() read;
}

/// What a byte route answers. [body] is a [String] or bytes.
final class ByteResponse {
  const ByteResponse(
    this.status, {
    this.body,
    this.headers = const <String, String>{},
    this.failure,
  });

  final int status;
  final Object? body;
  final Map<String, String> headers;

  /// An error nothing expected, for the host's log.
  final ByteFailure? failure;
}

final class ByteFailure {
  const ByteFailure(this.what, this.error, this.stack);

  final String what;
  final Object error;
  final StackTrace stack;
}

/// A tunnel route's answer: [refusal] before the channel opens, or [join]
/// with it.
final class ByteTunnel {
  const ByteTunnel._({this.refusal, this.join});

  final ByteResponse? refusal;
  final Future<void> Function(StreamChannel<dynamic> channel)? join;
}

/// What a window may send to the byte routes, and nothing wider.
///
/// The origin is named rather than `*`: `app://conduit` is the only page
/// that may reach the routes at all, and a wildcard would additionally let
/// any website's script read the responses if one ever found the port.
const Map<String, String> byteRouteCorsHeaders = <String, String>{
  'access-control-allow-origin': kConduitAppOrigin,
  'access-control-allow-methods': 'POST, GET, OPTIONS',
  'access-control-allow-headers':
      'authorization, content-type, '
      'x-conduit-filename, x-conduit-terminal, x-conduit-directory',
  'access-control-max-age': '600',
};

/// The routes beside JSON-RPC that carry bytes: uploads, files, media,
/// transcription, recordings and speech, and the two tunnels (a terminal's
/// shell, a call's audio).
///
/// What each does is here; how it arrives is the host's. Authorisation of
/// the caller is the host's too: the daemon checks its token and origin
/// before a request reaches these.
final class ProtocolByteRoutes {
  ProtocolByteRoutes({
    required ProtocolServices? Function() services,
    required MediaService media,
  }) : _services = services,
       _media = media;

  /// The services once built; none while the core starts.
  final ProtocolServices? Function() _services;
  final MediaService _media;

  /// Whether [path] names a tunnel, whatever its handle, without reading
  /// any service: a host that carries none answers it by this alone.
  static bool isTunnel(String path) =>
      path.startsWith('/terminal/') || path.startsWith('/calls/');

  /// The tunnel at [path] (`/terminal/{handle}`, `/calls/{handle}`), or
  /// null when [path] is not one. An unknown handle is refused before the
  /// channel opens.
  ByteTunnel? tunnel(String path) {
    if (path.startsWith('/terminal/')) {
      final terminals = _services()?.terminals;
      final handle = path.substring('/terminal/'.length);
      if (terminals == null || !terminals.knows(handle)) {
        return const ByteTunnel._(
          refusal: ByteResponse(404, body: 'no such terminal'),
        );
      }
      return ByteTunnel._(join: (channel) => terminals.tunnel(handle, channel));
    }
    if (path.startsWith('/calls/')) {
      final calls = _services()?.calls;
      final handle = path.substring('/calls/'.length);
      if (calls == null || !calls.knowsAudio(handle)) {
        return const ByteTunnel._(
          refusal: ByteResponse(404, body: 'no such call'),
        );
      }
      return ByteTunnel._(join: (channel) => calls.tunnel(handle, channel));
    }
    return null;
  }

  /// The answer to [request], or null when its path is none of these
  /// routes.
  Future<ByteResponse>? handle(ByteRequest request) {
    final path = '/${request.url.path}';
    if (path == ConduitHttpRoutes.upload) return _upload(request);
    if (path == ConduitHttpRoutes.terminalUpload) {
      return _terminalUpload(request);
    }
    if (path.startsWith('/files/')) return _file(request);
    if (path.startsWith('${ConduitHttpRoutes.media}/')) {
      return _mediaFetch(request, path);
    }
    if (path == ConduitHttpRoutes.transcribe) return _transcribe(request);
    if (path.startsWith('/recordings/')) return _recording(request, path);
    if (path.startsWith('/tts/')) return _speech(request, path);
    return null;
  }

  /// `POST /terminal-upload` -- a file into a terminal's machine.
  /// The same body as `/upload`; the handle and directory come in headers.
  Future<ByteResponse> _terminalUpload(ByteRequest request) async {
    final terminals = _services()?.terminals;
    if (terminals == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'POST') {
      return const ByteResponse(405, body: 'POST only');
    }
    final String name;
    final String directory;
    try {
      name = Uri.decodeComponent(request.headers['x-conduit-filename'] ?? '');
      directory = Uri.decodeComponent(
        request.headers['x-conduit-directory'] ?? '',
      );
    } on FormatException {
      return _problem(400, ConduitErrorCodes.invalidParams, 'bad headers');
    }
    final handle = request.headers['x-conduit-terminal'] ?? '';
    if (name.trim().isEmpty || directory.isEmpty || handle.isEmpty) {
      return _problem(
        400,
        ConduitErrorCodes.invalidParams,
        'needs x-conduit-filename, -terminal and -directory',
      );
    }
    try {
      final bytes = await _collect(request.read());
      await terminals.upload(
        handle: handle,
        directory: directory,
        name: name,
        bytes: bytes,
      );
      // An UploadedFile, as /upload answers; the id is where it went.
      return ByteResponse(
        200,
        body: jsonEncode(
          UploadedFile(
            id: '$directory$name',
            name: name,
            size: bytes.length,
          ).toJson(),
        ),
        headers: const <String, String>{
          'content-type': 'application/json',
          ...byteRouteCorsHeaders,
        },
      );
    } on RpcError catch (error) {
      final status = switch (error.code) {
        ConduitErrorCodes.notFound => 404,
        ConduitErrorCodes.unauthenticated => 401,
        _ => 502,
      };
      return _problem(status, error.code, error.debugMessage);
    } on Object catch (error, stack) {
      return _problem(
        502,
        ConduitErrorCodes.serverError,
        'upload failed',
        failure: ByteFailure('terminal upload failed', error, stack),
      );
    }
  }

  /// `POST /upload` -- an attachment on its way to the server.
  ///
  /// The body is the file's bytes and nothing else. No multipart parsing
  /// here: both ends of this request are ours, the daemon re-wraps the
  /// bytes for Open WebUI anyway, and a parser is a surface that would earn
  /// its keep only if some other client were posting to us.
  ///
  /// The name travels in a header because a body that is *only* bytes is
  /// what lets the whole thing stream. It is percent-encoded: a header is
  /// Latin-1 by definition, and an attachment called `résumé.pdf` would
  /// otherwise be rejected by the HTTP layer before this code ran.
  Future<ByteResponse> _upload(ByteRequest request) async {
    final files = _services()?.files;
    if (files == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'POST') {
      return const ByteResponse(405, body: 'POST only');
    }

    final rawName = request.headers['x-conduit-filename'];
    if (rawName == null || rawName.trim().isEmpty) {
      return _problem(
        400,
        ConduitErrorCodes.invalidParams,
        'missing x-conduit-filename',
      );
    }
    final String name;
    try {
      name = Uri.decodeComponent(rawName);
    } on FormatException {
      return _problem(
        400,
        ConduitErrorCodes.invalidParams,
        'x-conduit-filename is not percent-encoded',
      );
    }

    // Which try this is, for the core's retry rules (1 for the first).
    final attempt =
        int.tryParse(request.headers['x-conduit-attempt'] ?? '') ?? 1;
    // The account the request began under: a body still arriving when
    // another signs in never goes to the next account's server.
    final session = files.session();
    try {
      final bytes = await _collect(request.read());
      final uploaded = await files.upload(
        name: name,
        bytes: bytes,
        session: session,
        contentType: request.headers['content-type'],
        // A channel's attachment: filed under the channel so its members
        // may read it.
        channelId: request.headers['x-conduit-channel'],
      );
      return ByteResponse(
        200,
        body: jsonEncode(uploaded.toJson()),
        headers: const <String, String>{
          'content-type': 'application/json',
          ...byteRouteCorsHeaders,
        },
      );
    } on RpcError catch (error) {
      final status = switch (error.code) {
        ConduitErrorCodes.unauthenticated => 401,
        ConduitErrorCodes.invalidParams => 400,
        _ => 502,
      };
      return _problem(status, error.code, error.debugMessage);
    } on Object catch (error, stack) {
      return _problem(
        502,
        ConduitErrorCodes.serverError,
        'upload failed',
        args: uploadRetryArgs(error, attempt),
        failure: ByteFailure('upload failed', error, stack),
      );
    }
  }

  /// `GET /files/{serverId}/{fileId}` -- an attachment's bytes, for an image
  /// in a message; `GET /files/{serverId}/models/{modelId}` -- a model's
  /// profile image.
  Future<ByteResponse> _file(ByteRequest request) async {
    final files = _services()?.files;
    if (files == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'GET') {
      return const ByteResponse(405, body: 'GET only');
    }
    final segments = request.url.pathSegments;
    final modelImage = segments.length == 4 && segments[2] == 'models';
    if (segments.length != 3 && !modelImage) {
      return _problem(404, ConduitErrorCodes.notFound, 'no such file');
    }
    try {
      // `/files/{server}/models/{model}`: a model's profile image.
      final file = modelImage
          ? await files.modelImage(segments[1], segments[3])
          : await files.download(segments[1], segments[2]);
      return ByteResponse(
        200,
        body: file.bytes,
        headers: <String, String>{
          'content-type': file.contentType,
          // Taken as given: a file claiming to be bytes must never be read
          // as HTML because its first line looks like some.
          'x-content-type-options': 'nosniff',
          'content-disposition': 'inline',
          // Private: it is the user's file. An hour: the same image is drawn
          // every time the conversation is opened.
          'cache-control': 'private, max-age=3600',
          ...byteRouteCorsHeaders,
        },
      );
    } on RpcError catch (error) {
      final status = switch (error.code) {
        ConduitErrorCodes.invalidParams => 400,
        ConduitErrorCodes.unauthenticated => 401,
        ConduitErrorCodes.notFound => 404,
        _ => 502,
      };
      return _problem(status, error.code, error.debugMessage);
    } on FileContentTooLargeException {
      return _problem(413, ConduitErrorCodes.invalidParams, 'file too large');
    } on Object catch (error, stack) {
      return _problem(
        502,
        ConduitErrorCodes.serverError,
        'download failed',
        failure: ByteFailure('file download failed', error, stack),
      );
    }
  }

  /// `GET /media/{image|pdf}?url=` -- a picture or a PDF on another site,
  /// for the window (see [MediaService] for what is and is not sent).
  /// Answered with its bytes and type, or a problem whose code says why
  /// not (`media.tooLarge`, `media.wrongType`, `media.timedOut`, ...).
  Future<ByteResponse> _mediaFetch(ByteRequest request, String path) async {
    if (request.method != 'GET') {
      return const ByteResponse(405, body: 'GET only');
    }
    final kind = switch (path.substring(ConduitHttpRoutes.media.length + 1)) {
      'image' => MediaKind.image,
      'pdf' => MediaKind.pdf,
      _ => null,
    };
    final url = request.url.queryParameters['url'];
    if (kind == null || url == null) {
      return _problem(404, ConduitErrorCodes.notFound, 'no such media');
    }
    try {
      final media = await _media.fetch(url, kind);
      return ByteResponse(
        200,
        body: media.bytes,
        headers: <String, String>{
          'content-type': media.contentType,
          'x-content-type-options': 'nosniff',
          'content-disposition': 'inline',
          // The window keeps what it drew; nothing here outlives the reply.
          'cache-control': 'no-store',
          ...byteRouteCorsHeaders,
        },
      );
    } on MediaFetchException catch (error) {
      // The failure only: the address is the chat's, not the log's.
      DebugLogger.info(
        'media ${kind.name}: ${error.failure.name}',
        scope: 'daemon/media',
      );
      return _problem(
        error.failure.status,
        error.failure.code,
        error.failure.name,
      );
    }
  }

  /// `POST /transcribe` -- a recording, as text. The body is the
  /// recording and nothing else; its type is the content type. The query
  /// may name the engine (`engine=server|local`) and the chat's model
  /// (`model=`), whose backend transcribes on the server.
  Future<ByteResponse> _transcribe(ByteRequest request) async {
    final dictation = _services()?.dictation;
    if (dictation == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'POST') {
      return const ByteResponse(405, body: 'POST only');
    }
    final query = request.url.queryParameters;
    // The account the request began under: audio still arriving when
    // another signs in never goes to the next account's backend.
    final session = dictation.session();
    try {
      final transcript = await dictation.transcribe(
        await _collect(request.read()),
        contentType: request.headers['content-type'],
        engine: _nonEmpty(query['engine']),
        modelId: _nonEmpty(query['model']),
        session: session,
      );
      return ByteResponse(
        200,
        body: jsonEncode(transcript.toJson()),
        headers: const <String, String>{
          'content-type': 'application/json',
          ...byteRouteCorsHeaders,
        },
      );
    } on RpcError catch (error) {
      return _problem(_statusFor(error), error.code, error.debugMessage);
    } on Object catch (error, stack) {
      return _problem(
        502,
        ConduitErrorCodes.serverError,
        'transcribe failed',
        failure: ByteFailure('transcription failed', error, stack),
      );
    }
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// `GET /recordings/{id}?chatId=&folderId=` -- a saved recording of a
  /// draft as 16 kHz mono WAV; `GET /recordings/{id}?noteId=` -- a note's
  /// recording still waiting to upload, as recorded.
  Future<ByteResponse> _recording(ByteRequest request, String path) async {
    final services = _services();
    final recordings = services?.recordings;
    if (recordings == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'GET') {
      return const ByteResponse(405, body: 'GET only');
    }
    final query = request.url.queryParameters;
    final id = Uri.decodeComponent(path.substring('/recordings/'.length));
    // `?noteId=`: one of a note's recordings still waiting to upload.
    if (_nonEmpty(query['noteId']) case final noteId?) {
      final notes = services?.notes;
      if (notes == null) {
        return _problem(
          503,
          ConduitErrorCodes.daemonUnavailable,
          'core starting',
        );
      }
      try {
        final audio = await notes.waitingRecording(noteId, id);
        return ByteResponse(
          200,
          body: audio.bytes,
          headers: <String, String>{
            'content-type': audio.contentType,
            'x-content-type-options': 'nosniff',
            'cache-control': 'no-store',
            ...byteRouteCorsHeaders,
          },
        );
      } on RpcError catch (error) {
        return _problem(_statusFor(error), error.code, error.debugMessage);
      } on Object catch (error, stack) {
        return _problem(
          500,
          ConduitErrorCodes.serverError,
          'read failed',
          failure: ByteFailure('note recording read failed', error, stack),
        );
      }
    }
    try {
      final wav = await recordings.wav(
        RecordingRef(
          id: id,
          chatId: _nonEmpty(query['chatId']),
          folderId: _nonEmpty(query['folderId']),
        ),
      );
      return ByteResponse(
        200,
        body: wav,
        headers: const <String, String>{
          'content-type': 'audio/wav',
          'x-content-type-options': 'nosniff',
          'cache-control': 'no-store',
          ...byteRouteCorsHeaders,
        },
      );
    } on RpcError catch (error) {
      return _problem(_statusFor(error), error.code, error.debugMessage);
    } on Object catch (error, stack) {
      return _problem(
        500,
        ConduitErrorCodes.serverError,
        'recording failed',
        failure: ByteFailure('recording read failed', error, stack),
      );
    }
  }

  /// `GET /tts/{jobId}` -- a `voice.speak` job's audio.
  Future<ByteResponse> _speech(ByteRequest request, String path) async {
    final voice = _services()?.voice;
    if (voice == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'GET') {
      return const ByteResponse(405, body: 'GET only');
    }
    try {
      final audio = await voice.audio(path.substring('/tts/'.length));
      return ByteResponse(
        200,
        body: audio.bytes,
        headers: <String, String>{
          'content-type': audio.contentType,
          'x-content-type-options': 'nosniff',
          'cache-control': 'private, max-age=3600',
          ...byteRouteCorsHeaders,
        },
      );
    } on RpcError catch (error) {
      return _problem(_statusFor(error), error.code, error.debugMessage);
    } on Object catch (error, stack) {
      return _problem(
        502,
        ConduitErrorCodes.serverError,
        'speech failed',
        failure: ByteFailure('speech failed', error, stack),
      );
    }
  }

  static int _statusFor(RpcError error) => switch (error.code) {
    ConduitErrorCodes.unauthenticated ||
    ConduitErrorCodes.sessionExpired => 401,
    ConduitErrorCodes.unauthorized => 403,
    ConduitErrorCodes.notFound => 404,
    ConduitErrorCodes.invalidParams => 400,
    _ => 502,
  };

  /// The same error shape RPC uses, so the window has one thing to read.
  static ByteResponse _problem(
    int status,
    String code,
    String? message, {
    Map<String, String>? args,
    ByteFailure? failure,
  }) => ByteResponse(
    status,
    body: jsonEncode(<String, Object?>{
      'code': code,
      'args': ?args,
      'debugMessage': ?message,
    }),
    headers: const <String, String>{
      'content-type': 'application/json',
      // On the error path too, or the window sees an opaque CORS failure
      // instead of the reason the upload was refused.
      ...byteRouteCorsHeaders,
    },
    failure: failure,
  );

  static Future<Uint8List> _collect(Stream<List<int>> body) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in body) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
