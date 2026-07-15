import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/utils/debug_logger.dart';
import '../models/direct_completion.dart';
import '../models/direct_connection_profile.dart';
import 'direct_adapter_helpers.dart';
import 'direct_http_client.dart';

typedef OpenWebUiDirectChannelEmitter =
    bool Function(String channel, Object payload);
typedef OpenWebUiDirectRpcAcknowledgement = void Function(Object? payload);

/// Executes Open WebUI's client-side half of a direct chat completion RPC.
///
/// Open WebUI sends the provider-ready form through `request:chat:completion`.
/// The client calls the provider, acknowledges once its streaming response is
/// open, and relays the provider's raw non-empty response lines back through a
/// per-request Socket.IO channel. Provider credentials never transit through
/// the Open WebUI server.
final class OpenWebUiDirectCompletionRelay {
  OpenWebUiDirectCompletionRelay({
    required OpenWebUiDirectChannelEmitter emitChannel,
    DirectDioFactory? dioFactory,
    this.closeClients = true,
    this.streamIdleTimeout = kDirectStreamIdleTimeout,
    this.streamMaxDuration = kDirectStreamMaxDuration,
    this.maxStreamBytes = kMaxDirectStreamBytes,
    this.maxStreamCharacters = kMaxDirectStreamCharacters,
    this.maxStreamEvents = kMaxDirectStreamEvents,
    this.maxLineCharacters = 4 * 1024 * 1024,
    this.maxJsonResponseBytes = kMaxDirectJsonResponseBytes,
  }) : _emitChannel = emitChannel,
       _dioFactory = dioFactory ?? const DirectHttpClientFactory().create {
    validateDirectCompletionStreamLimits(
      idleTimeout: streamIdleTimeout,
      maxDuration: streamMaxDuration,
      maxBytes: maxStreamBytes,
      maxCharacters: maxStreamCharacters,
      maxEvents: maxStreamEvents,
    );
    if (maxLineCharacters <= 0) {
      throw ArgumentError.value(maxLineCharacters, 'maxLineCharacters');
    }
    if (maxJsonResponseBytes <= 0) {
      throw ArgumentError.value(maxJsonResponseBytes, 'maxJsonResponseBytes');
    }
  }

  final OpenWebUiDirectChannelEmitter _emitChannel;
  final DirectDioFactory _dioFactory;
  final bool closeClients;
  final Duration streamIdleTimeout;
  final Duration streamMaxDuration;
  final int maxStreamBytes;
  final int maxStreamCharacters;
  final int maxStreamEvents;
  final int maxLineCharacters;
  final int maxJsonResponseBytes;

  /// Starts one trusted direct-completion RPC.
  ///
  /// [payload] is the nested `data` object from Open WebUI's
  /// `request:chat:completion` event. The profile, model id, URL index, and
  /// socket session are trusted runtime bindings supplied by Conduit, rather
  /// than values inferred from that server-controlled payload.
  OpenWebUiDirectCompletionRelayRun start({
    required DirectConnectionProfile profile,
    required String trustedRemoteModelId,
    required int trustedUrlIndex,
    required String expectedAccountId,
    required String expectedSessionId,
    required Map<String, dynamic> payload,
    required OpenWebUiDirectRpcAcknowledgement acknowledge,
  }) {
    profile.validate();
    if (profile.adapterKey != kOpenAiCompatibleAdapterKey) {
      throw ArgumentError.value(profile.adapterKey, 'profile.adapterKey');
    }
    if (trustedRemoteModelId.trim().isEmpty) {
      throw ArgumentError.value(trustedRemoteModelId, 'trustedRemoteModelId');
    }
    if (trustedUrlIndex < 0) {
      throw RangeError.value(trustedUrlIndex, 'trustedUrlIndex');
    }
    _validateExpectedAccountId(expectedAccountId);
    _validateExpectedSessionId(expectedSessionId);

    final cancelToken = CancelToken();
    final transportCancelToken = CancelToken();
    final settled = Completer<void>();
    unawaited(
      cancelToken.whenCancel.then<void>((error) {
        if (!transportCancelToken.isCancelled) {
          transportCancelToken.cancel(error.error ?? 'relay cancelled');
        }
      }),
    );
    unawaited(
      Future<void>(() async {
        try {
          await _run(
            profile: profile,
            trustedRemoteModelId: trustedRemoteModelId,
            trustedUrlIndex: trustedUrlIndex,
            expectedAccountId: expectedAccountId,
            expectedSessionId: expectedSessionId,
            payload: payload,
            acknowledge: acknowledge,
            cancelToken: transportCancelToken,
          );
        } catch (_) {
          // The relay reports bounded failures through the RPC acknowledgement
          // and always settles its run; it never leaks a fire-and-forget error.
        } finally {
          if (!settled.isCompleted) settled.complete();
        }
      }),
    );

    return OpenWebUiDirectCompletionRelayRun(
      cancelToken: cancelToken,
      done: settled.future,
    );
  }

  Future<void> _run({
    required DirectConnectionProfile profile,
    required String trustedRemoteModelId,
    required int trustedUrlIndex,
    required String expectedAccountId,
    required String expectedSessionId,
    required Map<String, dynamic> payload,
    required OpenWebUiDirectRpcAcknowledgement acknowledge,
    required CancelToken cancelToken,
  }) async {
    Dio? dio;
    String? trustedChannel;
    var acknowledged = false;
    final sensitiveValues = directProfileSensitiveValues(profile);
    try {
      trustedChannel = _validateRpcChannel(
        payload,
        expectedAccountId: expectedAccountId,
        expectedSessionId: expectedSessionId,
      );
      final request = _validateRpcPayload(
        payload,
        trustedUrlIndex: trustedUrlIndex,
        trustedChannel: trustedChannel,
      );

      dio = _dioFactory(profile);
      const DirectHttpClientFactory().configure(dio, profile);
      final response = await dio.post<ResponseBody>(
        'chat/completions',
        cancelToken: cancelToken,
        data: <String, dynamic>{
          ...request.formData,
          'model': trustedRemoteModelId,
        },
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: streamIdleTimeout,
          headers: <String, String>{
            'Accept': request.stream ? 'text/event-stream' : 'application/json',
          },
        ),
      );
      final body = response.data;
      if (body == null) {
        throw const FormatException('Provider returned an empty body.');
      }

      if (request.stream) {
        // Match Open WebUI: the server may construct its StreamingResponse
        // only after the provider request itself has opened successfully.
        _acknowledge(acknowledge, const <String, dynamic>{'status': true});
        acknowledged = true;
        await _relayRawLines(
          body,
          channel: trustedChannel,
          cancelToken: cancelToken,
        );
      } else {
        final value = await _decodeJson(body, cancelToken: cancelToken);
        _acknowledge(acknowledge, value);
        acknowledged = true;
      }
    } catch (error) {
      final normalized = normalizeDirectProviderError(error);
      final safeMessage = sanitizeDirectProviderErrorMessage(
        normalized.message,
        sensitiveValues: sensitiveValues,
      );
      if (!acknowledged) {
        _acknowledge(acknowledge, <String, dynamic>{
          'status': false,
          'error': safeMessage,
        });
      } else if (!cancelToken.isCancelled && trustedChannel != null) {
        try {
          // The admission ACK has already completed, so later failures must
          // travel through the per-request channel. Open WebUI forwards maps
          // from this channel as SSE JSON, where this is its standard error
          // shape.
          _emit(trustedChannel, <String, dynamic>{
            'error': <String, dynamic>{'message': safeMessage},
          });
        } catch (_) {
          // If the socket itself failed, there is no remaining path on which
          // to report the provider error. Cleanup still emits done best-effort.
        }
      }
      if (!cancelToken.isCancelled) {
        DebugLogger.error(
          'completion-relay-failed',
          scope: 'direct-connections/openwebui-relay',
          error: safeMessage,
        );
      }
    } finally {
      if (trustedChannel != null) {
        try {
          _emit(trustedChannel, const <String, dynamic>{'done': true});
        } catch (_) {
          // A disconnected socket cannot receive the terminal marker. Cleanup
          // and run settlement must still proceed.
        }
      }
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('completion relay settled');
      }
      // Dio observes cancellation through a future callback. Let that callback
      // abort the underlying request before the run reports settled.
      await Future<void>.delayed(Duration.zero);
      if (closeClients) dio?.close(force: true);
    }
  }

  Future<void> _relayRawLines(
    ResponseBody body, {
    required String channel,
    required CancelToken cancelToken,
  }) async {
    final scanner = _BoundedRawLineScanner(
      maxLineCharacters: maxLineCharacters,
    );
    final budget = DirectStreamBudget(
      maxCharacters: maxStreamCharacters,
      maxEvents: maxStreamEvents,
    );
    final bytes = directStreamingResponseBytes(
      body,
      idleTimeout: streamIdleTimeout,
      maxDuration: streamMaxDuration,
      maxBytes: maxStreamBytes,
    ).transform(utf8.decoder);

    await for (final chunk in _cancelableText(bytes, cancelToken)) {
      for (final line in scanner.addChunk(chunk)) {
        _relayLine(line, channel: channel, budget: budget);
      }
    }
    for (final line in scanner.close()) {
      _relayLine(line, channel: channel, budget: budget);
    }
  }

  Future<Object?> _decodeJson(
    ResponseBody body, {
    required CancelToken cancelToken,
  }) async {
    final chunks = <int>[];
    final bytes = directStreamingResponseBytes(
      body,
      idleTimeout: streamIdleTimeout,
      maxDuration: streamMaxDuration,
      maxBytes: maxStreamBytes,
    );
    await for (final chunk in _cancelableBytes(bytes, cancelToken)) {
      if (chunks.length + chunk.length > maxJsonResponseBytes) {
        throw const FormatException('Provider response is too large.');
      }
      chunks.addAll(chunk);
    }
    return jsonDecode(utf8.decode(chunks));
  }

  void _relayLine(
    String line, {
    required String channel,
    required DirectStreamBudget budget,
  }) {
    if (line.trim().isEmpty) return;
    budget.addEvent();
    budget.add(line);
    _emit(channel, line);
  }

  void _emit(String channel, Object payload) {
    try {
      if (!_emitChannel(channel, payload)) {
        throw StateError('Socket session changed.');
      }
    } catch (error) {
      throw DirectProviderException(
        'The Open WebUI socket disconnected during the direct request.',
        cause: error,
      );
    }
  }
}

/// One cancellable Open WebUI direct relay operation.
final class OpenWebUiDirectCompletionRelayRun {
  OpenWebUiDirectCompletionRelayRun({
    required CancelToken cancelToken,
    required this.done,
  }) : _cancelToken = cancelToken;

  final CancelToken _cancelToken;
  final Future<void> done;

  bool get isCancelled => _cancelToken.isCancelled;

  Future<void> cancel([String reason = 'stopped']) async {
    if (!_cancelToken.isCancelled) _cancelToken.cancel(reason);
    await done;
  }
}

final class _ValidatedRelayRequest {
  const _ValidatedRelayRequest({
    required this.channel,
    required this.formData,
    required this.stream,
  });

  final String channel;
  final Map<String, dynamic> formData;
  final bool stream;
}

_ValidatedRelayRequest _validateRpcPayload(
  Map<String, dynamic> payload, {
  required int trustedUrlIndex,
  required String trustedChannel,
}) {
  final model = payload['model'];
  if (model is! Map ||
      model['direct'] != true ||
      _parseUrlIndex(model['urlIdx']) != trustedUrlIndex) {
    throw const DirectProviderException(
      'Open WebUI sent an invalid direct-completion request.',
    );
  }

  final rawFormData = payload['form_data'];
  if (rawFormData is! Map) {
    throw const DirectProviderException(
      'Open WebUI sent an invalid direct-completion request.',
    );
  }
  Map<String, dynamic> formData;
  try {
    formData = Map<String, dynamic>.from(rawFormData);
  } catch (_) {
    throw const DirectProviderException(
      'Open WebUI sent an invalid direct-completion request.',
    );
  }
  if (formData['model'] is! String ||
      (formData['model'] as String).trim().isEmpty) {
    throw const DirectProviderException(
      'Open WebUI sent an invalid direct-completion request.',
    );
  }
  if (model['id']?.toString() != formData['model']) {
    throw const DirectProviderException(
      'Open WebUI sent an invalid direct-completion request.',
    );
  }
  final stream = formData['stream'];
  if (stream != null && stream is! bool) {
    throw const DirectProviderException(
      'Open WebUI sent an invalid direct-completion request.',
    );
  }

  return _ValidatedRelayRequest(
    channel: trustedChannel,
    formData: formData,
    stream: stream == true,
  );
}

String _validateRpcChannel(
  Map<String, dynamic> payload, {
  required String expectedAccountId,
  required String expectedSessionId,
}) {
  final sessionId = payload['session_id'];
  if (sessionId is! String || sessionId != expectedSessionId) {
    throw const DirectProviderException(
      'Open WebUI sent an invalid direct-completion request.',
    );
  }

  final channel = payload['channel'];
  if (channel is! String ||
      !_isSessionBoundChannel(
        channel,
        accountId: expectedAccountId,
        sessionId: expectedSessionId,
      )) {
    throw const DirectProviderException(
      'Open WebUI sent an invalid direct-completion request.',
    );
  }
  return channel;
}

void _validateExpectedAccountId(String accountId) {
  if (accountId.isEmpty ||
      accountId.length > 256 ||
      accountId.contains(':') ||
      _containsControlCharacter(accountId)) {
    throw ArgumentError.value(accountId, 'expectedAccountId');
  }
}

void _validateExpectedSessionId(String sessionId) {
  if (sessionId.isEmpty ||
      sessionId.length > 256 ||
      sessionId.contains(':') ||
      _containsControlCharacter(sessionId)) {
    throw ArgumentError.value(sessionId, 'expectedSessionId');
  }
}

bool _isSessionBoundChannel(
  String channel, {
  required String accountId,
  required String sessionId,
}) {
  if (channel.isEmpty ||
      channel.length > 1024 ||
      _containsControlCharacter(channel)) {
    return false;
  }
  final prefix = '$accountId:$sessionId:';
  return channel.startsWith(prefix) && channel.length > prefix.length;
}

bool _containsControlCharacter(String value) => value.codeUnits.any(
  (codeUnit) => codeUnit < 0x20 || (codeUnit >= 0x7f && codeUnit <= 0x9f),
);

int? _parseUrlIndex(Object? value) {
  if (value is int) return value >= 0 ? value : null;
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    final parsed = value.toInt();
    return parsed >= 0 ? parsed : null;
  }
  if (value is String && RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
    return int.tryParse(value);
  }
  return null;
}

void _acknowledge(
  OpenWebUiDirectRpcAcknowledgement acknowledge,
  Object? payload,
) {
  try {
    acknowledge(payload);
  } catch (_) {
    // SocketService's acknowledgement wrapper is best effort. A disconnected
    // callback must not skip provider cleanup or the terminal channel signal.
  }
}

Stream<String> _cancelableText(
  Stream<String> source,
  CancelToken cancelToken,
) => _cancelableStream(source, cancelToken);

Stream<List<int>> _cancelableBytes(
  Stream<List<int>> source,
  CancelToken cancelToken,
) => _cancelableStream(source, cancelToken);

Stream<T> _cancelableStream<T>(
  Stream<T> source,
  CancelToken cancelToken,
) async* {
  final iterator = _SingleCancellationStreamIterator<T>(source, cancelToken);
  try {
    while (await iterator.moveNext()) {
      yield iterator.current;
    }
  } finally {
    await iterator.cancel();
  }
}

/// Races every source read against one shared [CancelToken] listener.
///
/// Registering `whenCancel.then` inside `moveNext` retains one callback for
/// every completed chunk until the token eventually settles. This wrapper
/// keeps only the current read's ephemeral cancellation completer reachable.
final class _SingleCancellationStreamIterator<T> {
  _SingleCancellationStreamIterator(Stream<T> source, this._cancelToken)
    : _iterator = StreamIterator<T>(source) {
    unawaited(_cancelToken.whenCancel.then<void>(_handleCancellation));
  }

  final StreamIterator<T> _iterator;
  final CancelToken _cancelToken;
  Completer<bool>? _pendingMoveCancellation;

  T get current => _iterator.current;

  Future<bool> moveNext() async {
    final existingCancellation = _cancelToken.cancelError;
    if (existingCancellation != null) {
      Error.throwWithStackTrace(
        existingCancellation,
        existingCancellation.stackTrace,
      );
    }

    final moveCancellation = Completer<bool>();
    _pendingMoveCancellation = moveCancellation;
    try {
      return await Future.any<bool>(<Future<bool>>[
        _iterator.moveNext(),
        moveCancellation.future,
      ]);
    } finally {
      if (identical(_pendingMoveCancellation, moveCancellation)) {
        _pendingMoveCancellation = null;
      }
    }
  }

  void _handleCancellation(DioException error) {
    final pending = _pendingMoveCancellation;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error, error.stackTrace);
    }
  }

  Future<void> cancel() async {
    try {
      await _iterator.cancel();
    } catch (_) {
      // Source teardown must not mask the run's actual outcome.
    }
  }
}

final class _BoundedRawLineScanner {
  _BoundedRawLineScanner({required this.maxLineCharacters});

  final int maxLineCharacters;
  final StringBuffer _buffer = StringBuffer();
  bool _skipLeadingLineFeed = false;

  Iterable<String> addChunk(String chunk) sync* {
    for (var index = 0; index < chunk.length; index++) {
      final codeUnit = chunk.codeUnitAt(index);
      if (_skipLeadingLineFeed) {
        _skipLeadingLineFeed = false;
        if (codeUnit == 0x0a) continue;
      }
      if (codeUnit == 0x0a) {
        yield _finishLine();
        continue;
      }
      if (codeUnit == 0x0d) {
        yield _finishLine();
        _skipLeadingLineFeed = true;
        continue;
      }
      if (_buffer.length >= maxLineCharacters) {
        throw const DirectProviderException(
          'The provider response exceeded Conduit\'s size limit.',
        );
      }
      _buffer.writeCharCode(codeUnit);
    }
  }

  Iterable<String> close() sync* {
    _skipLeadingLineFeed = false;
    if (_buffer.isNotEmpty) yield _finishLine();
  }

  String _finishLine() {
    final value = _buffer.toString();
    _buffer.clear();
    return value;
  }
}
