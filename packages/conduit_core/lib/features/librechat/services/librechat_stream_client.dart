import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/librechat/models/librechat_message.dart';
import 'package:conduit_core/features/librechat/models/librechat_stream_event.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/services/sse_frame_scanner.dart';

/// The generation protocol Conduit speaks. v2 answers a duplicate start with
/// `settled` or `replaced` instead of a stream that may already be gone, and
/// ends a stream whose result moved with a `reconcile` frame.
const int kLibreChatGenerationProtocol = 2;

/// One turn to send: the body of `POST /api/agents/chat/:endpoint`.
@immutable
final class LibreChatTurnRequest {
  const LibreChatTurnRequest({
    required this.text,
    required this.endpoint,
    required this.clientRequestId,
    this.endpointType,
    this.model,
    this.agentId,
    this.spec,
    this.conversationId,
    this.parentMessageId,
    this.isRegenerate = false,
    this.overrideParentMessageId,
    this.files = const <Map<String, dynamic>>[],
    this.ephemeralAgent,
    this.parameters = const <String, dynamic>{},
  });

  final String text;

  /// The endpoint the turn runs on: `agents`, `openAI`, `anthropic`, a
  /// custom endpoint's name, ...
  final String endpoint;

  /// `custom` for a custom endpoint, else null.
  final String? endpointType;

  final String? model;

  /// The saved agent, when [endpoint] is `agents`.
  final String? agentId;

  /// The model spec, required when the server enforces specs.
  final String? spec;

  /// The conversation, or null to start one.
  final String? conversationId;

  /// The message this one answers; null for the first message.
  final String? parentMessageId;

  /// Makes the server treat retries of this turn as the same turn. LibreChat
  /// accepts 1 to 128 of `[A-Za-z0-9:_-]`.
  final String clientRequestId;

  /// Regenerates the reply to [overrideParentMessageId] instead of sending
  /// a new user message.
  final bool isRegenerate;
  final String? overrideParentMessageId;

  /// Uploaded files: `{file_id, filepath, filename, type, width, height}`.
  final List<Map<String, dynamic>> files;

  /// Tools for an ad-hoc run: `{web_search, execute_code, file_search, mcp}`.
  final Map<String, dynamic>? ephemeralAgent;

  /// Model parameters and anything else the endpoint reads.
  final Map<String, dynamic> parameters;

  static final RegExp _clientRequestIdPattern = RegExp(
    r'^[A-Za-z0-9:_-]{1,128}$',
  );

  Map<String, dynamic> toJson() {
    if (!_clientRequestIdPattern.hasMatch(clientRequestId)) {
      throw ArgumentError.value(clientRequestId, 'clientRequestId');
    }
    return <String, dynamic>{
      ...parameters,
      'text': text,
      'endpoint': endpoint,
      'endpointType': ?endpointType,
      'model': ?model,
      'agent_id': ?agentId,
      'spec': ?spec,
      'conversationId': conversationId,
      'parentMessageId': parentMessageId ?? kLibreChatRootParentId,
      'clientRequestId': clientRequestId,
      if (isRegenerate) 'isRegenerate': true,
      'overrideParentMessageId': ?overrideParentMessageId,
      if (files.isNotEmpty) 'files': files,
      'ephemeralAgent': ?ephemeralAgent,
      'generationProtocolVersion': kLibreChatGenerationProtocol,
    };
  }
}

/// How the server took a request to start a turn.
enum LibreChatStartOutcome {
  /// A new generation started.
  started,

  /// The same request is already generating; subscribe with resume.
  resumed,

  /// The same request already finished; fetch the saved result.
  settled,

  /// The same request was answered and then replaced by a newer turn;
  /// fetch the saved result.
  replaced,
}

/// A generation the server accepted.
@immutable
final class LibreChatGeneration {
  const LibreChatGeneration({
    required this.outcome,
    required this.streamId,
    required this.conversationId,
    this.createdAt,
  });

  final LibreChatStartOutcome outcome;

  /// The stream to subscribe to. LibreChat uses the conversation id.
  final String streamId;
  final String conversationId;

  /// Identifies this generation among the conversation's, so a subscription
  /// cannot attach to a later one.
  final int? createdAt;

  /// Whether there is a stream to follow, rather than a saved result.
  bool get isLive =>
      outcome == LibreChatStartOutcome.started ||
      outcome == LibreChatStartOutcome.resumed;
}

/// A turn the server refused outright, for a reason retrying does not cure:
/// moderation, a ban, a usage limit, an invalid request.
final class LibreChatTurnRefusedException extends LibreChatApiException {
  const LibreChatTurnRefusedException({
    required super.message,
    super.statusCode,
    super.code,
  });
}

/// A turn the server could not take yet: it is starting up, or the
/// conversation's previous turn has not been saved. [retryAfter] says how
/// long to wait, when the server said.
final class LibreChatTurnDeferredException extends LibreChatApiException {
  const LibreChatTurnDeferredException({
    required super.message,
    super.statusCode,
    super.code,
    this.retryAfter,
  });

  final Duration? retryAfter;
}

/// Starts, follows, stops and resumes LibreChat generations
/// (`/api/agents/chat/*`).
///
/// A LibreChat generation runs on the server independently of any client:
/// starting it returns at once, and its events stream from a separate
/// subscription that can drop and resume. Leaving a stream does not stop the
/// reply; only [abort] does.
final class LibreChatStreamClient {
  LibreChatStreamClient(
    this._client, {
    this.errorBodyTimeout = const Duration(seconds: 5),
  });

  final LibreChatHttpClient _client;

  /// How long a refusal's body is read for its reason. A stream has no
  /// receive timeout, and a server that stalls the body must not hold the
  /// turn: what arrived by then is what is told.
  final Duration errorBodyTimeout;

  Dio get _dio => _client.dio;

  static const Map<String, String> _protocolHeader = {
    'x-librechat-generation-protocol': '$kLibreChatGenerationProtocol',
  };

  /// Asks the server to run [request].
  Future<LibreChatGeneration> start(
    LibreChatTurnRequest request, {
    CancelToken? cancelToken,
  }) async {
    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        '/api/agents/chat/${Uri.encodeComponent(request.endpoint)}',
        data: request.toJson(),
        queryParameters: const {
          'generationProtocolVersion': kLibreChatGenerationProtocol,
        },
        cancelToken: cancelToken,
        options: Options(headers: _protocolHeader),
      );
    } on DioException catch (error) {
      throw _startError(error);
    }
    final data = response.data;
    _throwIfDenied(data);
    if (data is! Map) {
      throw const LibreChatApiException(
        message: 'The LibreChat server sent an unexpected reply.',
      );
    }
    final streamId = data['streamId'] ?? data['conversationId'];
    final conversationId = data['conversationId'] ?? streamId;
    if (streamId is! String || conversationId is! String) {
      throw const LibreChatApiException(
        message: 'The LibreChat server did not start the reply.',
      );
    }
    final createdAt = data['generationCreatedAt'];
    return LibreChatGeneration(
      outcome: switch (data['status']) {
        'resumed' => LibreChatStartOutcome.resumed,
        'settled' => LibreChatStartOutcome.settled,
        'replaced' => LibreChatStartOutcome.replaced,
        _ => LibreChatStartOutcome.started,
      },
      streamId: streamId,
      conversationId: conversationId,
      createdAt: createdAt is int ? createdAt : null,
    );
  }

  /// The events of the generation in [streamId]. With [resume], the first
  /// event is the server's snapshot of the reply so far.
  ///
  /// The stream ends after the final frame. It ends with a
  /// [LibreChatStreamFinal] whose `reconcile` is set when the generation is
  /// gone or was replaced, so the saved result must be fetched instead.
  Stream<LibreChatStreamEvent> subscribe(
    String streamId, {
    int? generationCreatedAt,
    bool resume = false,
    CancelToken? cancelToken,
  }) async* {
    final Response<ResponseBody> response;
    try {
      response = await _dio.get<ResponseBody>(
        '/api/agents/chat/stream/${Uri.encodeComponent(streamId)}',
        queryParameters: {
          'generationCreatedAt': ?generationCreatedAt,
          'generationProtocolVersion': kLibreChatGenerationProtocol,
          if (resume) 'resume': 'true',
        },
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: Duration.zero,
          headers: {..._protocolHeader, 'Accept': 'text/event-stream'},
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      // 404: the generation finished and was cleaned up; 409: a newer turn
      // replaced it. Either way the saved conversation has the answer.
      if (status == 404 || status == 409) {
        yield LibreChatStreamFinal(<String, dynamic>{
          'final': true,
          'reconcile': true,
          'reconcileReason': status == 404 ? 'not_found' : 'replaced',
        });
        return;
      }
      // Asked for as a stream, the refusal's body is still unread: the
      // server's reason is in it.
      throw libreChatErrorOf(await _withBodyRead(error, errorBodyTimeout));
    }

    final scanner = SseFrameScanner();
    final body = response.data!.stream.cast<List<int>>().transform(
      const Utf8Decoder(allowMalformed: true),
    );
    await for (final chunk in body) {
      for (final frame in scanner.addChunk(chunk)) {
        final event = LibreChatStreamEvent.fromFrame(
          event: frame.event,
          data: frame.data,
        );
        if (event == null) continue;
        yield event;
        if (event is LibreChatStreamFinal || event is LibreChatStreamFailed) {
          return;
        }
      }
    }
  }

  /// Stops the generation in [conversationId]. The server saves the reply
  /// so far and its subscribers get a final frame marked aborted.
  ///
  /// Throws a [LibreChatApiException] coded `ABORT_PERSISTENCE_FAILED` when
  /// the generation stopped but the reply so far could not be saved: the
  /// server keeps the run and settles it later, so the result is fetched
  /// again rather than trusted.
  Future<void> abort(String conversationId, {int? generationCreatedAt}) async {
    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        '/api/agents/chat/abort',
        data: {
          'conversationId': conversationId,
          'streamId': conversationId,
          'generationCreatedAt': ?generationCreatedAt,
          'generationProtocolVersion': kLibreChatGenerationProtocol,
        },
        options: Options(headers: _protocolHeader),
      );
    } on DioException catch (error) {
      // Nothing running there any more is what stopping wanted.
      if (error.response?.statusCode == 404) return;
      throw libreChatErrorOf(error);
    }
    final data = response.data;
    if (data is Map && data['persistenceFailed'] == true) {
      throw LibreChatApiException(
        message: 'The reply was stopped, but the server could not save it.',
        statusCode: response.statusCode,
        code: 'ABORT_PERSISTENCE_FAILED',
      );
    }
  }

  /// Whether [conversationId] has a generation running, with the snapshot
  /// a resume would start from: `{active, streamId, createdAt, status,
  /// resumeState, pendingAction}`, or `{active: false}`.
  Future<Map<String, dynamic>> status(String conversationId) async {
    try {
      final response = await _dio.get<dynamic>(
        '/api/agents/chat/status/${Uri.encodeComponent(conversationId)}',
        queryParameters: const {
          'generationProtocolVersion': kLibreChatGenerationProtocol,
        },
        options: Options(headers: _protocolHeader),
      );
      final data = response.data;
      return data is Map
          ? Map<String, dynamic>.from(data)
          : const <String, dynamic>{'active': false};
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return const <String, dynamic>{'active': false};
      }
      throw libreChatErrorOf(error);
    }
  }

  /// The conversations with a generation running for this user.
  Future<List<String>> activeConversations() async {
    try {
      final response = await _dio.get<dynamic>('/api/agents/chat/active');
      final ids = response.data is Map
          ? (response.data as Map)['activeJobIds']
          : null;
      return [
        if (ids is List)
          for (final id in ids)
            if (id is String) id,
      ];
    } on DioException catch (error) {
      throw libreChatErrorOf(error);
    }
  }

  /// Answers the approval or question a run paused on and lets it go on.
  /// The rest streams on the same stream id.
  ///
  /// [body] carries `conversationId`, `actionId`, `generationCreatedAt`,
  /// the turn's `endpoint` and `agent_id`, and either `decisions`
  /// (`[{tool_call_id, decision, editedArguments?, responseText?}]`) or
  /// `answers` (`{questionId: answer}`).
  ///
  /// Throws [LibreChatTurnRefusedException] when a middleware (moderation,
  /// a ban) refused the answer: the run stays paused.
  Future<void> resumeAfterAction(Map<String, dynamic> body) async {
    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        '/api/agents/chat/resume',
        data: {
          ...body,
          'generationProtocolVersion': kLibreChatGenerationProtocol,
        },
        options: Options(headers: _protocolHeader),
      );
    } on DioException catch (error) {
      throw libreChatErrorOf(error);
    }
    _throwIfDenied(response.data);
  }

  /// A middleware refused the request and answered in the stream's own
  /// format (LibreChat's denyRequest): moderation, a ban, a limit.
  static void _throwIfDenied(Object? data) {
    if (data is String && data.contains('event:')) {
      throw LibreChatTurnRefusedException(message: _deniedMessage(data));
    }
  }

  static LibreChatApiException _startError(DioException error) {
    final response = error.response;
    final base = libreChatErrorOf(error);
    final status = response?.statusCode;
    if (status == 503 || base.code == 'PARENT_NOT_READY') {
      return LibreChatTurnDeferredException(
        message: base.message,
        statusCode: status,
        code: base.code,
        retryAfter: _retryAfter(response?.headers.value('retry-after')),
      );
    }
    if (status != null &&
        status >= 400 &&
        status < 500 &&
        status != 401 &&
        status != 408 &&
        status != 409 &&
        status != 429) {
      return LibreChatTurnRefusedException(
        message: base.message,
        statusCode: status,
        code: base.code,
      );
    }
    return base;
  }

  static Duration? _retryAfter(String? value) {
    final seconds = int.tryParse(value?.trim() ?? '');
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  /// The readable reason in a denyRequest stream.
  static String _deniedMessage(String body) {
    final scanner = SseFrameScanner();
    String? text;
    for (final frame in scanner.addChunk('$body\n\n')) {
      if (frame.event != 'error') continue;
      try {
        final decoded = jsonDecode(frame.data);
        if (decoded is Map && decoded['text'] is String) {
          text = decoded['text'] as String;
        } else if (decoded is Map && decoded['message'] is String) {
          text = decoded['message'] as String;
        }
      } on FormatException {
        text = frame.data;
      }
    }
    if (text == null) return 'The LibreChat server refused the message.';
    try {
      final violation = jsonDecode(text);
      if (violation is Map) {
        return switch (violation['type']) {
          'ban' => LibreChatApiException.bannedMessage,
          'concurrent' =>
            'Too many replies are running at once. Wait for one to finish.',
          'message_limit' =>
            'You sent too many messages. Wait a moment and try again.',
          _ =>
            violation['message'] is String
                ? violation['message'] as String
                : 'The LibreChat server refused the message.',
        };
      }
    } on FormatException {
      // Plain text: moderation and other refusals explain themselves.
    }
    return text;
  }
}

/// [error] with its response body read into text, when it came as a stream,
/// so the server's reason can be told. Bounded in size, as an error page can
/// be large, and in time by [timeout], as the body can stall.
Future<DioException> _withBodyRead(DioException error, Duration timeout) async {
  final response = error.response;
  final data = response?.data;
  if (response == null || data is! ResponseBody) return error;
  const limit = 16 * 1024;
  final bytes = <int>[];
  final reading = Stopwatch()..start();
  try {
    await for (final chunk in data.stream.timeout(timeout)) {
      bytes.addAll(chunk.take(limit - bytes.length));
      if (bytes.length >= limit || reading.elapsed >= timeout) break;
    }
  } catch (_) {
    // What arrived before it broke off is what there is to tell.
  }
  return error.copyWith(
    response: Response<dynamic>(
      data: utf8.decode(bytes, allowMalformed: true),
      statusCode: response.statusCode,
      statusMessage: response.statusMessage,
      headers: response.headers,
      requestOptions: response.requestOptions,
    ),
  );
}
