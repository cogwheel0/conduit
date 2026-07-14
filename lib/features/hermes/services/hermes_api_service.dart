import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/services/openai_responses_codec.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/hermes_chat_input.dart';
import '../models/hermes_config.dart';
import '../models/hermes_run_event.dart';
import 'hermes_identifier.dart';
import 'hermes_stream_parser.dart';

export 'hermes_identifier.dart'
    show kMaxHermesOpaqueIdentifierCharacters, validateHermesOpaqueIdentifier;

const Duration kHermesStreamIdleTimeout = Duration(minutes: 5);
const Duration kHermesStreamMaxDuration = Duration(minutes: 30);
const int kMaxHermesStreamBytes = 64 * 1024 * 1024;
const int kMaxHermesStreamRawFrames = 100000;
const int kMaxHermesStreamCharacters = 8 * 1024 * 1024;
const int kMaxHermesStreamEvents = 100000;
const int kMaxHermesRecoveryBytes = 16 * 1024 * 1024;
const int kMaxHermesRecoveryJsonDepth = 128;
const int kMaxHermesRecoveryJsonNodes = 100000;
const int kMaxHermesCreateResponseBytes = 64 * 1024;
const int kMaxHermesCreateResponseCharacters = 32 * 1024;
const Duration kHermesCreateResponseTimeout = Duration(seconds: 60);

/// Resource and liveness ceilings for one Hermes SSE request.
final class HermesStreamLimits {
  const HermesStreamLimits({
    this.idleTimeout = kHermesStreamIdleTimeout,
    this.maxDuration = kHermesStreamMaxDuration,
    this.maxBytes = kMaxHermesStreamBytes,
    this.maxRawFrames = kMaxHermesStreamRawFrames,
    this.maxCharacters = kMaxHermesStreamCharacters,
    this.maxEvents = kMaxHermesStreamEvents,
  });

  final Duration idleTimeout;
  final Duration maxDuration;
  final int maxBytes;
  final int maxRawFrames;
  final int maxCharacters;
  final int maxEvents;

  void validate() {
    if (idleTimeout <= Duration.zero) {
      throw ArgumentError.value(idleTimeout, 'idleTimeout');
    }
    if (maxDuration <= Duration.zero) {
      throw ArgumentError.value(maxDuration, 'maxDuration');
    }
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes');
    }
    if (maxRawFrames <= 0) {
      throw ArgumentError.value(maxRawFrames, 'maxRawFrames');
    }
    if (maxCharacters <= 0) {
      throw ArgumentError.value(maxCharacters, 'maxCharacters');
    }
    if (maxEvents <= 0) {
      throw ArgumentError.value(maxEvents, 'maxEvents');
    }
  }
}

/// Bounds the provider-controlled transport before UTF-8 and JSON decoding.
///
/// Typed-event limits cannot see comments, malformed JSON, unknown events, or
/// other frames that the tolerant Hermes parser intentionally drops. Counting
/// bytes and SSE blank-line boundaries here keeps that compatibility while
/// ensuring ignored input still consumes a finite request-wide budget.
Stream<List<int>> _guardHermesRawStream(
  Stream<List<int>> source, {
  required CancelToken cancelToken,
  required HermesStreamLimits limits,
}) async* {
  limits.validate();
  final budget = _HermesRawStreamBudget(limits);
  final iterator = StreamIterator<List<int>>(source);
  var endedCleanly = false;
  var sourceFailed = false;
  var guardFailed = false;

  try {
    while (await iterator.moveNext()) {
      final chunk = iterator.current;
      budget.add(chunk);
      yield chunk;
    }
    endedCleanly = true;
  } on HermesStreamGuardException {
    guardFailed = true;
    rethrow;
  } catch (_) {
    sourceFailed = true;
    rethrow;
  } finally {
    // Preserve the token on clean EOF/source failure so transport recovery can
    // still call getRun/getResponse. A local budget failure or downstream
    // cancellation owns teardown and must signal Dio before detached cleanup.
    final consumerCancelled = !endedCleanly && !sourceFailed && !guardFailed;
    if (guardFailed || consumerCancelled) {
      _signalHermesStreamCancellation(cancelToken);
    }
    _cancelHermesStreamIterator(iterator);
  }
}

final class _HermesRawStreamBudget {
  _HermesRawStreamBudget(this.limits);

  final HermesStreamLimits limits;
  int _bytes = 0;
  int _frames = 0;
  bool _lineHasBytes = false;
  bool _skipLineFeed = false;

  void add(List<int> chunk) {
    _bytes += chunk.length;
    if (_bytes > limits.maxBytes) {
      throw const HermesStreamGuardException(
        'The Hermes stream exceeded Conduit\'s transfer limit.',
      );
    }

    // SSE framing is ASCII-delimited, so CR/LF bytes can be counted before
    // decoding without confusing UTF-8 continuation bytes. Count every blank
    // line, including comment-only and empty frames the parser later discards.
    for (final byte in chunk) {
      if (_skipLineFeed) {
        _skipLineFeed = false;
        if (byte == _lineFeed) continue;
      }
      if (byte == _lineFeed) {
        _finishLine();
      } else if (byte == _carriageReturn) {
        _finishLine();
        _skipLineFeed = true;
      } else {
        _lineHasBytes = true;
      }
    }
  }

  void _finishLine() {
    if (!_lineHasBytes) {
      _frames++;
      if (_frames > limits.maxRawFrames) {
        throw const HermesStreamGuardException(
          'The Hermes stream exceeded Conduit\'s frame limit.',
        );
      }
    }
    _lineHasBytes = false;
  }
}

const int _lineFeed = 0x0A;
const int _carriageReturn = 0x0D;

/// A fixed, provider-independent stream failure that is safe to show in UI.
final class HermesStreamGuardException implements Exception {
  const HermesStreamGuardException(this.message);

  final String message;

  @override
  String toString() => 'HermesStreamGuardException: $message';
}

/// Bounds typed events even when a peer sends an endless sequence of valid,
/// individually small SSE frames. Parsed-event idle time intentionally ignores
/// comment heartbeats so they cannot keep a non-progressing run alive forever.
Stream<HermesRunEvent> guardHermesEventStream(
  Stream<HermesRunEvent> source, {
  required CancelToken cancelToken,
  required HermesStreamLimits limits,
}) async* {
  limits.validate();
  final elapsed = Stopwatch()..start();
  final iterator = StreamIterator(source);
  var characters = 0;
  var events = 0;
  var sawTerminal = false;
  var endedWithoutTerminal = false;
  var sourceFailed = false;
  var guardFailed = false;

  try {
    while (true) {
      final remaining = limits.maxDuration - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw const HermesStreamGuardException(
          'The Hermes stream exceeded Conduit\'s time limit.',
        );
      }
      final enforcingAbsoluteLimit =
          remaining.compareTo(limits.idleTimeout) <= 0;
      final wait = enforcingAbsoluteLimit ? remaining : limits.idleTimeout;
      bool hasNext;
      try {
        hasNext = await iterator.moveNext().timeout(wait);
      } on TimeoutException {
        if (enforcingAbsoluteLimit) {
          throw const HermesStreamGuardException(
            'The Hermes stream exceeded Conduit\'s time limit.',
          );
        }
        throw const HermesStreamGuardException(
          'The Hermes stream was idle for too long.',
        );
      }
      if (!hasNext) {
        endedWithoutTerminal = true;
        break;
      }

      final event = iterator.current;
      events++;
      if (events > limits.maxEvents) {
        throw const HermesStreamGuardException(
          'The Hermes stream exceeded Conduit\'s event limit.',
        );
      }
      characters += _hermesEventCharacters(event);
      if (characters > limits.maxCharacters) {
        throw const HermesStreamGuardException(
          'The Hermes stream exceeded Conduit\'s size limit.',
        );
      }

      final terminal = event is HermesRunDone || event is HermesRunError;
      if (terminal) sawTerminal = true;
      yield event;
      if (terminal) break;
    }
  } on HermesStreamGuardException {
    guardFailed = true;
    rethrow;
  } catch (_) {
    sourceFailed = true;
    rethrow;
  } finally {
    elapsed.stop();
    // A clean premature EOF (or a recoverable source error) must leave the
    // token usable for getRun/getResponse reconciliation. Terminal events,
    // local guard failures, and consumer cancellation own transport teardown.
    final consumerCancelled =
        !sawTerminal && !endedWithoutTerminal && !sourceFailed && !guardFailed;
    if (sawTerminal || guardFailed || consumerCancelled) {
      _signalHermesStreamCancellation(cancelToken);
    }
    _cancelHermesStreamIterator(iterator);
  }
}

int _hermesEventCharacters(HermesRunEvent event) => switch (event) {
  HermesResponseCreated(:final responseId) => responseId.length,
  HermesTokenDelta(:final content) => content.length,
  HermesReasoningDelta(:final content) => content.length,
  HermesToolProgress(:final toolName, :final detail) =>
    toolName.length + (detail?.length ?? 0),
  HermesApprovalRequested(:final approvalId, :final summary) =>
    approvalId.length + (summary?.length ?? 0),
  HermesLifecycle(:final status) => status.length,
  HermesFinalOutput(:final text) => text.length,
  HermesRunError(:final message) => message.length,
  HermesRunDone() => 0,
};

final Object _hermesInternalCancellationReason = Object();

/// Whether Hermes' own stream/recovery guard cancelled [cancelToken].
///
/// The first cancellation wins in Dio. If the caller stopped the request
/// first, this remains false even when parser teardown later observes an
/// invalid frame; transport code can therefore avoid surfacing a protocol
/// error onto a deliberately stopped message.
bool hermesCancellationWasInternal(CancelToken cancelToken) => identical(
  cancelToken.cancelError?.error,
  _hermesInternalCancellationReason,
);

/// Signals parser/guard teardown while retaining cancellation provenance.
/// Exposed so injected Hermes transports used by tests can preserve the same
/// contract as the built-in Dio/parser path.
void signalHermesInternalCancellation(CancelToken cancelToken) {
  _signalHermesStreamCancellation(cancelToken);
}

void _signalHermesStreamCancellation(CancelToken cancelToken) {
  if (!cancelToken.isCancelled) {
    cancelToken.cancel(_hermesInternalCancellationReason);
  }
}

void _cancelHermesStreamIterator<T>(StreamIterator<T> iterator) {
  try {
    unawaited(
      iterator.cancel().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  } catch (_) {
    // Provider-owned source teardown is best effort. It must never replace or
    // indefinitely delay the successful terminal event or guard failure.
  }
}

Future<Map<String, dynamic>> _decodeHermesRecoveryObject(
  Object? data, {
  required CancelToken cancelToken,
  required HermesStreamLimits limits,
  required _HermesRecoveryBudget recoveryBudget,
}) async {
  final byteLimit = limits.maxBytes < kMaxHermesRecoveryBytes
      ? limits.maxBytes
      : kMaxHermesRecoveryBytes;

  try {
    recoveryBudget.requireRemainingDuration();
    Object? decoded;
    if (data is ResponseBody) {
      final advertisedLength = int.tryParse(
        data.headers[Headers.contentLengthHeader]?.first ?? '',
      );
      if (advertisedLength != null &&
          (advertisedLength > byteLimit ||
              advertisedLength > recoveryBudget.remainingBytes)) {
        throw const HermesStreamGuardException(
          'The Hermes recovery response exceeded Conduit\'s transfer limit.',
        );
      }
      final bytes = await _readHermesRecoveryBytes(
        data.stream.cast<List<int>>(),
        maxBytes: byteLimit,
        idleTimeout: limits.idleTimeout,
        recoveryBudget: recoveryBudget,
      );
      recoveryBudget.requireRemainingDuration();
      final source = utf8.decode(bytes, allowMalformed: false);
      _validateHermesJsonNesting(source);
      decoded = jsonDecode(source);
    } else if (data is String) {
      final bytes = utf8.encode(data);
      if (bytes.length > byteLimit) {
        throw const HermesStreamGuardException(
          'The Hermes recovery response exceeded Conduit\'s transfer limit.',
        );
      }
      recoveryBudget.consume(bytes.length);
      _validateHermesJsonNesting(data);
      decoded = jsonDecode(data);
    } else {
      // Interceptors used by tests and embedders can resolve an already-decoded
      // body even when ResponseType.stream was requested. They are trusted for
      // transport allocation, but their value still must pass the same shape,
      // depth, node, and aggregate-string ceilings before Conduit uses it.
      decoded = data;
    }

    final valueSize = _validateHermesRecoveryValue(
      decoded,
      maxCharacters: limits.maxCharacters,
    );
    if (data is! ResponseBody && data is! String) {
      recoveryBudget.consume(valueSize.characters + valueSize.nodes * 8);
    }
    recoveryBudget.requireRemainingDuration();
    if (decoded is! Map) {
      throw const FormatException('Hermes recovery payload is not an object');
    }
    return Map<String, dynamic>.from(decoded);
  } on HermesStreamGuardException {
    _signalHermesStreamCancellation(cancelToken);
    rethrow;
  } on FormatException {
    _signalHermesStreamCancellation(cancelToken);
    rethrow;
  }
}

Future<Uint8List> _readHermesRecoveryBytes(
  Stream<List<int>> source, {
  required int maxBytes,
  required Duration idleTimeout,
  required _HermesRecoveryBudget recoveryBudget,
}) async {
  final iterator = StreamIterator<List<int>>(source);
  final builder = BytesBuilder(copy: false);
  var total = 0;
  try {
    while (true) {
      final remaining = recoveryBudget.requireRemainingDuration();
      final wait = remaining < idleTimeout ? remaining : idleTimeout;
      bool hasNext;
      try {
        hasNext = await iterator.moveNext().timeout(wait);
      } on TimeoutException {
        throw HermesStreamGuardException(
          remaining <= idleTimeout
              ? 'The Hermes recovery response exceeded Conduit\'s time limit.'
              : 'The Hermes recovery response was idle for too long.',
        );
      }
      if (!hasNext) break;
      recoveryBudget.requireRemainingDuration();
      final chunk = iterator.current;
      total += chunk.length;
      if (total > maxBytes) {
        throw const HermesStreamGuardException(
          'The Hermes recovery response exceeded Conduit\'s transfer limit.',
        );
      }
      recoveryBudget.consume(chunk.length);
      builder.add(chunk);
    }
    recoveryBudget.requireRemainingDuration();
    return builder.takeBytes();
  } finally {
    _cancelHermesStreamIterator(iterator);
  }
}

final class _HermesRecoveryDeadline {
  _HermesRecoveryDeadline({
    required this.maxDuration,
    required Duration Function() clock,
  }) : _clock = clock,
       _startedAt = clock();

  final Duration maxDuration;
  final Duration Function() _clock;
  final Duration _startedAt;

  Duration get remainingDuration {
    final now = _clock();
    // Production uses Stopwatch and cannot move backwards. If an injected
    // clock violates that contract, fail closed instead of extending a
    // provider-controlled recovery operation indefinitely.
    if (now < _startedAt) return Duration.zero;
    return maxDuration - (now - _startedAt);
  }

  Duration requireRemainingDuration() {
    final remaining = remainingDuration;
    if (remaining <= Duration.zero) {
      throw const HermesStreamGuardException(
        'The Hermes recovery response exceeded Conduit\'s time limit.',
      );
    }
    return remaining;
  }
}

final class _HermesRecoveryBudget {
  _HermesRecoveryBudget({
    required this.remainingBytes,
    required Duration maxDuration,
    required Duration Function() clock,
  }) : _deadline = _HermesRecoveryDeadline(
         maxDuration: maxDuration,
         clock: clock,
       );

  _HermesRecoveryBudget.forDeadline({
    required this.remainingBytes,
    required _HermesRecoveryDeadline deadline,
  }) : _deadline = deadline;

  int remainingBytes;
  final _HermesRecoveryDeadline _deadline;

  Duration get remainingDuration => _deadline.remainingDuration;

  Duration requireRemainingDuration() => _deadline.requireRemainingDuration();

  void consume(int count) {
    requireRemainingDuration();
    if (count < 0 || count > remainingBytes) {
      throw const HermesStreamGuardException(
        'The Hermes recovery response exceeded Conduit\'s transfer limit.',
      );
    }
    remainingBytes -= count;
  }
}

Duration Function() _createHermesRecoveryClock() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}

void _validateHermesJsonNesting(String source) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (final codeUnit in source.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (codeUnit == 0x5C) {
        escaped = true;
      } else if (codeUnit == 0x22) {
        inString = false;
      }
      continue;
    }
    if (codeUnit == 0x22) {
      inString = true;
    } else if (codeUnit == 0x7B || codeUnit == 0x5B) {
      depth++;
      if (depth > kMaxHermesRecoveryJsonDepth) {
        throw const HermesStreamGuardException(
          'The Hermes recovery response exceeded Conduit\'s nesting limit.',
        );
      }
    } else if (codeUnit == 0x7D || codeUnit == 0x5D) {
      depth--;
    }
  }
}

({int characters, int nodes}) _validateHermesRecoveryValue(
  Object? root, {
  required int maxCharacters,
}) {
  final stack = <({Object? value, int depth})>[(value: root, depth: 0)];
  final visited = <Object>{};
  var nodes = 0;
  var scheduledNodes = 1;
  var characters = 0;

  void scheduleChildren(Iterable<Object?> children, int depth) {
    for (final child in children) {
      scheduledNodes++;
      if (scheduledNodes > kMaxHermesRecoveryJsonNodes) {
        throw const HermesStreamGuardException(
          'The Hermes recovery response exceeded Conduit\'s value limit.',
        );
      }
      stack.add((value: child, depth: depth));
    }
  }

  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    nodes++;
    if (nodes > kMaxHermesRecoveryJsonNodes) {
      throw const HermesStreamGuardException(
        'The Hermes recovery response exceeded Conduit\'s value limit.',
      );
    }

    final value = current.value;
    if (value is String) {
      characters += value.length;
      if (characters > maxCharacters) {
        throw const HermesStreamGuardException(
          'The Hermes recovery response exceeded Conduit\'s size limit.',
        );
      }
      continue;
    }
    if (value == null || value is num || value is bool) continue;
    if (value is Map) {
      if (!visited.add(value)) {
        throw const FormatException('Hermes recovery payload contains a cycle');
      }
      if (current.depth >= kMaxHermesRecoveryJsonDepth && value.isNotEmpty) {
        throw const HermesStreamGuardException(
          'The Hermes recovery response exceeded Conduit\'s nesting limit.',
        );
      }
      if (value.length > kMaxHermesRecoveryJsonNodes - scheduledNodes) {
        throw const HermesStreamGuardException(
          'The Hermes recovery response exceeded Conduit\'s value limit.',
        );
      }
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw const FormatException(
            'Hermes recovery payload contains a non-string key',
          );
        }
        characters += key.length;
        if (characters > maxCharacters) {
          throw const HermesStreamGuardException(
            'The Hermes recovery response exceeded Conduit\'s size limit.',
          );
        }
      }
      scheduleChildren(value.values, current.depth + 1);
      continue;
    }
    if (value is List) {
      if (!visited.add(value)) {
        throw const FormatException('Hermes recovery payload contains a cycle');
      }
      if (current.depth >= kMaxHermesRecoveryJsonDepth && value.isNotEmpty) {
        throw const HermesStreamGuardException(
          'The Hermes recovery response exceeded Conduit\'s nesting limit.',
        );
      }
      if (value.length > kMaxHermesRecoveryJsonNodes - scheduledNodes) {
        throw const HermesStreamGuardException(
          'The Hermes recovery response exceeded Conduit\'s value limit.',
        );
      }
      scheduleChildren(value, current.depth + 1);
      continue;
    }
    throw const FormatException(
      'Hermes recovery payload contains an unsupported value',
    );
  }
  return (characters: characters, nodes: nodes);
}

/// An established Responses SSE request. Headers are available before event
/// consumption so callers can bind the server-created Hermes session.
final class HermesResponseStream {
  const HermesResponseStream({required this.events, this.sessionId});

  final Stream<HermesRunEvent> events;
  final String? sessionId;
}

Future<bool> testHermesDraftConnection(
  HermesConfig config, {
  Future<bool> Function(HermesConfig probeConfig)? probe,
}) async {
  // Enabling a backend and verifying its draft are separate operations.
  final probeConfig = config.copyWith(enabled: true);
  if (probe != null) return probe(probeConfig);

  final service = HermesApiService(config: probeConfig);
  try {
    return await service.health();
  } finally {
    service.close();
  }
}

/// Thin client for the direct Hermes Agent API server.
///
/// Deliberately separate from the ~6000-line OpenWebUI `ApiService`: Hermes is a
/// different backend with its own bearer auth and `X-Hermes-*` headers, and
/// reusing the OpenWebUI auth interceptor (with its public-endpoint list and
/// 401/403 escalation) would be wrong here.
class HermesApiService {
  HermesApiService({
    required this.config,
    Dio? dio,
    this.streamLimits = const HermesStreamLimits(),
    Duration Function()? recoveryClock,
  }) : _root = _normalizeRoot(config.baseUrl),
       _recoveryClock = recoveryClock ?? _createHermesRecoveryClock(),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               // Regular endpoints get a finite timeout so they can't hang
               // forever; SSE requests use their explicit idle limit below.
               receiveTimeout: const Duration(seconds: 60),
               followRedirects: false,
               headers: {
                 if ((config.apiKey ?? '').isNotEmpty)
                   'Authorization': 'Bearer ${config.apiKey}',
               },
             ),
           ) {
    streamLimits.validate();
    // Injected clients are used by tests and embedders. Enforce the same
    // boundary there: Dio preserves custom headers across redirects, so an
    // automatic cross-origin redirect could leak bearer/session credentials.
    _dio.options.followRedirects = false;
  }

  final HermesConfig config;
  final HermesStreamLimits streamLimits;
  final Dio _dio;
  final String _root;
  final Duration Function() _recoveryClock;
  final Expando<_HermesRecoveryDeadline> _recoveryDeadlines =
      Expando<_HermesRecoveryDeadline>('hermesRecoveryDeadline');

  _HermesRecoveryBudget _recoveryBudget(CancelToken cancelToken) {
    var deadline = _recoveryDeadlines[cancelToken];
    if (deadline == null) {
      deadline = _HermesRecoveryDeadline(
        maxDuration: streamLimits.maxDuration,
        clock: _recoveryClock,
      );
      _recoveryDeadlines[cancelToken] = deadline;
    }
    // One CancelToken identifies a recovery operation and therefore shares its
    // absolute deadline across polls. Each HTTP response gets a fresh transfer
    // allowance so a normally-sized `running` result cannot exhaust later
    // reconciliation polls merely by being requested repeatedly.
    return _HermesRecoveryBudget.forDeadline(
      remainingBytes: streamLimits.maxBytes,
      deadline: deadline,
    );
  }

  List<String> get _identifierSensitiveValues => <String>[
    if ((config.apiKey ?? '').isNotEmpty) config.apiKey!,
    if ((config.sessionKey ?? '').isNotEmpty) config.sessionKey!,
  ];

  String _requireOpaqueIdentifier(Object? value) {
    final validated = validateHermesOpaqueIdentifier(
      value,
      sensitiveValues: _identifierSensitiveValues,
    );
    if (validated == null) {
      throw const FormatException('Hermes returned an invalid identifier.');
    }
    return validated;
  }

  String? _validatedOptionalSessionId(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return null;
    return _requireOpaqueIdentifier(sessionId);
  }

  Future<Map<String, dynamic>> _postBoundedCreateObject(
    String path, {
    required Object? data,
    CancelToken? cancelToken,
    Map<String, String>? headers,
  }) async {
    final requestCancelToken = cancelToken ?? CancelToken();
    final maxBytes = streamLimits.maxBytes < kMaxHermesCreateResponseBytes
        ? streamLimits.maxBytes
        : kMaxHermesCreateResponseBytes;
    final maxCharacters =
        streamLimits.maxCharacters < kMaxHermesCreateResponseCharacters
        ? streamLimits.maxCharacters
        : kMaxHermesCreateResponseCharacters;
    var timeout = kHermesCreateResponseTimeout;
    if (streamLimits.idleTimeout < timeout) {
      timeout = streamLimits.idleTimeout;
    }
    if (streamLimits.maxDuration < timeout) {
      timeout = streamLimits.maxDuration;
    }
    final limits = HermesStreamLimits(
      idleTimeout: timeout,
      maxDuration: timeout,
      maxBytes: maxBytes,
      maxRawFrames: 1,
      maxCharacters: maxCharacters,
      maxEvents: 1,
    );
    final budget = _HermesRecoveryBudget(
      remainingBytes: maxBytes,
      maxDuration: timeout,
      clock: _recoveryClock,
    );

    try {
      final response = await _dio
          .post<dynamic>(
            path,
            cancelToken: requestCancelToken,
            data: data,
            options: Options(
              responseType: ResponseType.stream,
              receiveTimeout: timeout,
              headers: headers,
            ),
          )
          .timeout(
            budget.requireRemainingDuration(),
            onTimeout: () {
              _signalHermesStreamCancellation(requestCancelToken);
              throw const HermesStreamGuardException(
                'The Hermes create response exceeded Conduit\'s time limit.',
              );
            },
          );
      return await _decodeHermesRecoveryObject(
        response.data,
        cancelToken: requestCancelToken,
        limits: limits,
        recoveryBudget: budget,
      );
    } on HermesStreamGuardException {
      _signalHermesStreamCancellation(requestCancelToken);
      throw const FormatException('Hermes returned an invalid response.');
    } on FormatException {
      _signalHermesStreamCancellation(requestCancelToken);
      throw const FormatException('Hermes returned an invalid response.');
    }
  }

  Future<Response<dynamic>> _getRecoveryResponse(
    String path, {
    required CancelToken cancelToken,
    required _HermesRecoveryBudget recoveryBudget,
  }) async {
    late final Duration remaining;
    try {
      remaining = recoveryBudget.requireRemainingDuration();
    } on HermesStreamGuardException {
      _signalHermesStreamCancellation(cancelToken);
      rethrow;
    }
    final receiveTimeout = remaining < streamLimits.idleTimeout
        ? remaining
        : streamLimits.idleTimeout;
    final deadlineConstrainsReceive = receiveTimeout == remaining;
    try {
      final response = await _dio
          .get<dynamic>(
            path,
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              receiveTimeout: receiveTimeout,
            ),
          )
          .timeout(
            remaining,
            onTimeout: () {
              _signalHermesStreamCancellation(cancelToken);
              throw const HermesStreamGuardException(
                'The Hermes recovery response exceeded Conduit\'s time limit.',
              );
            },
          );
      recoveryBudget.requireRemainingDuration();
      return response;
    } on HermesStreamGuardException {
      _signalHermesStreamCancellation(cancelToken);
      rethrow;
    } on DioException catch (error) {
      if (recoveryBudget.remainingDuration <= Duration.zero ||
          (deadlineConstrainsReceive &&
              error.type == DioExceptionType.receiveTimeout)) {
        _signalHermesStreamCancellation(cancelToken);
        throw const HermesStreamGuardException(
          'The Hermes recovery response exceeded Conduit\'s time limit.',
        );
      }
      rethrow;
    }
  }

  /// Strips a trailing slash and optional `/v1` so endpoints can be composed
  /// uniformly as `<root>/v1/...` and `<root>/health`.
  static String _normalizeRoot(String baseUrl) {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/v1')) {
      url = url.substring(0, url.length - '/v1'.length);
    }
    return url;
  }

  Map<String, String> _sessionHeaders({String? sessionId}) {
    final validatedSessionId = _validatedOptionalSessionId(sessionId);
    return {
      'X-Hermes-Session-Id': ?validatedSessionId,
      if ((config.sessionKey ?? '').isNotEmpty)
        'X-Hermes-Session-Key': config.sessionKey!,
    };
  }

  /// Returns true when the server answers `GET /health` with a 2xx.
  Future<bool> health() async {
    try {
      final resp = await _dio.get<dynamic>(
        '$_root/health',
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      final code = resp.statusCode ?? 0;
      return code >= 200 && code < 300;
    } catch (_) {
      // The peer controls Dio's rejection object and may reflect bearer or
      // session headers. Health diagnostics intentionally stay value-free.
      DebugLogger.warning('health-check-failed', scope: 'hermes/api');
      return false;
    }
  }

  /// Lists models exposed by the Hermes server (`GET /v1/models`).
  Future<List<Map<String, dynamic>>> getModels() async {
    final resp = await _dio.get<dynamic>('$_root/v1/models');
    final data = resp.data;
    final list = data is Map ? data['data'] : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Lists the agent's skills (`GET /v1/skills`), the slash-commands invokable
  /// in chat input as `/skill-name args`. Read-only, bearer-gated.
  Future<List<Map<String, dynamic>>> listSkills() async {
    final resp = await _dio.get<dynamic>('$_root/v1/skills');
    final data = resp.data;
    final list = data is Map ? (data['skills'] ?? data['data']) : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Creates a run (`POST /v1/runs`) and returns its `run_id`.
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    CancelToken? cancelToken,
  }) async {
    final validatedSessionId = _validatedOptionalSessionId(sessionId);
    final data = await _postBoundedCreateObject(
      '$_root/v1/runs',
      cancelToken: cancelToken,
      data: {
        'input': input,
        'session_id': ?validatedSessionId,
        'instructions': ?instructions,
        'previous_response_id': ?previousResponseId,
      },
      headers: _sessionHeaders(sessionId: validatedSessionId),
    );
    return _requireOpaqueIdentifier(data['run_id'] ?? data['id']);
  }

  /// Opens the run event stream (`GET /v1/runs/{id}/events`) and decodes it into
  /// typed [HermesRunEvent]s. The caller owns the returned subscription.
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) async* {
    final streamCancelToken = cancelToken ?? CancelToken();
    final encodedRunId = Uri.encodeComponent(runId);
    final resp = await _dio.get<ResponseBody>(
      '$_root/v1/runs/$encodedRunId/events',
      cancelToken: streamCancelToken,
      options: Options(
        responseType: ResponseType.stream,
        // The typed-event guard also enforces inactivity, but a finite Dio
        // timeout bounds a peer that stalls below the response-stream layer.
        receiveTimeout: streamLimits.idleTimeout,
        headers: {
          'Accept': 'text/event-stream',
          ..._sessionHeaders(sessionId: sessionId),
        },
      ),
    );
    final body = resp.data;
    if (body == null) return;
    // Dio yields a Stream<Uint8List>; cast to Stream<List<int>> so the UTF-8
    // decoder's StreamTransformer<List<int>, String> binds without a runtime
    // variance error.
    yield* guardHermesEventStream(
      parseHermesRunStream(
        _guardHermesRawStream(
          body.stream.cast<List<int>>(),
          cancelToken: streamCancelToken,
          limits: streamLimits,
        ),
      ),
      cancelToken: streamCancelToken,
      limits: streamLimits,
    );
  }

  /// Fetches the current state of a run (`GET /v1/runs/{id}`) — used to recover
  /// a final result when the events stream drops before a terminal event.
  Future<Map<String, dynamic>> getRun(
    String runId, {
    CancelToken? cancelToken,
  }) async {
    final recoveryCancelToken = cancelToken ?? CancelToken();
    final recoveryBudget = _recoveryBudget(recoveryCancelToken);
    final encodedRunId = Uri.encodeComponent(runId);
    final resp = await _getRecoveryResponse(
      '$_root/v1/runs/$encodedRunId',
      cancelToken: recoveryCancelToken,
      recoveryBudget: recoveryBudget,
    );
    final map = await _decodeHermesRecoveryObject(
      resp.data,
      cancelToken: recoveryCancelToken,
      limits: streamLimits,
      recoveryBudget: recoveryBudget,
    );
    for (final key in const ['run', 'data', 'result']) {
      final nested = map[key];
      if (nested is Map) return Map<String, dynamic>.from(nested);
    }
    return map;
  }

  /// Stops a run (`POST /v1/runs/{id}/stop`).
  Future<void> stopRun(String runId, {CancelToken? cancelToken}) async {
    try {
      final encodedRunId = Uri.encodeComponent(runId);
      await _dio.post<dynamic>(
        '$_root/v1/runs/$encodedRunId/stop',
        cancelToken: cancelToken,
      );
    } catch (_) {
      // Remote run ids, rejection objects, and stacks are provider-controlled.
      DebugLogger.warning('stop-run-failed', scope: 'hermes/api');
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Sessions API (`/api/sessions/*`) — server-side transcript persistence.
  // ---------------------------------------------------------------------------

  /// Creates a session (`POST /api/sessions`) and returns its id.
  Future<String> createSession({
    String? title,
    CancelToken? cancelToken,
  }) async {
    final data = await _postBoundedCreateObject(
      '$_root/api/sessions',
      cancelToken: cancelToken,
      data: {'title': ?title},
    );
    return _requireOpaqueIdentifier(_sessionId(data));
  }

  /// Lists sessions (`GET /api/sessions`).
  Future<List<Map<String, dynamic>>> listSessions() async {
    final resp = await _dio.get<dynamic>('$_root/api/sessions');
    final data = resp.data;
    final list = data is Map
        ? (data['sessions'] ?? data['data'] ?? data['items'])
        : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Fetches a session's message history (`GET /api/sessions/{id}/messages`).
  Future<List<Map<String, dynamic>>> getSessionMessages(String id) async {
    final encodedId = Uri.encodeComponent(_requireOpaqueIdentifier(id));
    final resp = await _dio.get<dynamic>(
      '$_root/api/sessions/$encodedId/messages',
    );
    final data = resp.data;
    final list = data is Map ? (data['messages'] ?? data['data']) : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Starts one turn through Hermes's existing Responses SSE endpoint.
  ///
  /// Unlike `/v1/runs`, Responses accepts multimodal content on current Hermes
  /// servers and persists a response chain for client-managed conversations.
  Future<HermesResponseStream> streamResponse(
    HermesChatInput input, {
    String? instructions,
    String? sessionId,
    String? conversation,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async {
    if ((conversation?.isNotEmpty ?? false) &&
        (previousResponseId?.isNotEmpty ?? false)) {
      throw ArgumentError(
        'conversation and previousResponseId are mutually exclusive',
      );
    }
    final streamCancelToken = cancelToken ?? CancelToken();
    final resp = await _dio.post<ResponseBody>(
      '$_root/v1/responses',
      cancelToken: streamCancelToken,
      data: <String, dynamic>{
        ...OpenAiResponsesCodec.createRequestBody(
          // Hermes documents this model id and treats the field as cosmetic;
          // the configured server-side agent still selects the actual model.
          model: 'hermes-agent',
          input: input.toResponseInput(),
          instructions: instructions,
          previousResponseId: previousResponseId,
          // Response chaining and stream-drop recovery retrieve this result.
          store: true,
        ),
        'conversation': ?conversation,
        if (conversationHistory != null && conversationHistory.isNotEmpty)
          'conversation_history': conversationHistory,
      },
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: streamLimits.idleTimeout,
        headers: {
          'Accept': 'text/event-stream',
          ..._sessionHeaders(sessionId: sessionId),
        },
      ),
    );
    final body = resp.data;
    if (body == null) {
      throw StateError('Hermes Responses returned no event stream');
    }
    return HermesResponseStream(
      sessionId: resp.headers.value('x-hermes-session-id'),
      events: guardHermesEventStream(
        parseHermesResponseStream(
          _guardHermesRawStream(
            body.stream.cast<List<int>>(),
            cancelToken: streamCancelToken,
            limits: streamLimits,
          ),
        ),
        cancelToken: streamCancelToken,
        limits: streamLimits,
      ),
    );
  }

  /// Retrieves a stored Responses result for stream-drop reconciliation.
  Future<Map<String, dynamic>> getResponse(
    String responseId, {
    CancelToken? cancelToken,
  }) async {
    final recoveryCancelToken = cancelToken ?? CancelToken();
    final recoveryBudget = _recoveryBudget(recoveryCancelToken);
    final encoded = Uri.encodeComponent(responseId);
    final resp = await _getRecoveryResponse(
      '$_root/v1/responses/$encoded',
      cancelToken: recoveryCancelToken,
      recoveryBudget: recoveryBudget,
    );
    return _decodeHermesRecoveryObject(
      resp.data,
      cancelToken: recoveryCancelToken,
      limits: streamLimits,
      recoveryBudget: recoveryBudget,
    );
  }

  /// Renames a session (`PATCH /api/sessions/{id}`).
  Future<void> renameSession(String id, String title) async {
    final encodedId = Uri.encodeComponent(_requireOpaqueIdentifier(id));
    await _dio.patch<dynamic>(
      '$_root/api/sessions/$encodedId',
      data: {'title': title},
    );
  }

  /// Deletes a session (`DELETE /api/sessions/{id}`).
  Future<void> deleteSession(String id, {CancelToken? cancelToken}) async {
    final encodedId = Uri.encodeComponent(_requireOpaqueIdentifier(id));
    await _dio.delete<dynamic>(
      '$_root/api/sessions/$encodedId',
      cancelToken: cancelToken,
    );
  }

  /// Forks a session via lineage (`POST /api/sessions/{id}/fork`) and returns
  /// the new session id.
  Future<String> forkSession(String id) async {
    final encodedId = Uri.encodeComponent(_requireOpaqueIdentifier(id));
    final data = await _postBoundedCreateObject(
      '$_root/api/sessions/$encodedId/fork',
      data: null,
    );
    return _requireOpaqueIdentifier(_sessionId(data));
  }

  // ---------------------------------------------------------------------------
  // Discovery (`/v1/capabilities`, `/v1/toolsets`, `/health/detailed`).
  // ---------------------------------------------------------------------------

  /// Machine-readable server capabilities (`GET /v1/capabilities`).
  Future<Map<String, dynamic>> getCapabilities() async {
    final resp = await _dio.get<dynamic>('$_root/v1/capabilities');
    final data = resp.data;
    return data is Map ? data.cast<String, dynamic>() : const {};
  }

  /// Resolved toolsets and their concrete tools (`GET /v1/toolsets`).
  Future<List<Map<String, dynamic>>> listToolsets() async {
    final resp = await _dio.get<dynamic>('$_root/v1/toolsets');
    final data = resp.data;
    final list = data is Map ? (data['toolsets'] ?? data['data']) : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Extended health (`GET /health/detailed`): active sessions, running agents,
  /// resource usage. Returns an empty map on any failure.
  Future<Map<String, dynamic>> healthDetailed() async {
    try {
      final resp = await _dio.get<dynamic>('$_root/health/detailed');
      final data = resp.data;
      return data is Map ? data.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  // ---------------------------------------------------------------------------
  // Jobs API (`/api/jobs/*`) — scheduled/background agent runs.
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> listJobs() async {
    final resp = await _dio.get<dynamic>('$_root/api/jobs');
    final data = resp.data;
    final list = data is Map ? (data['jobs'] ?? data['data']) : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Creates a scheduled job. [schedule] is a cron expression.
  Future<Map<String, dynamic>> createJob({
    required String prompt,
    required String schedule,
    bool enabled = true,
  }) async {
    final resp = await _dio.post<dynamic>(
      '$_root/api/jobs',
      data: {'prompt': prompt, 'schedule': schedule, 'enabled': enabled},
    );
    final data = resp.data;
    return data is Map ? data.cast<String, dynamic>() : const {};
  }

  /// Partially updates a job (any of prompt / schedule / enabled).
  Future<void> updateJob(
    String id, {
    String? prompt,
    String? schedule,
    bool? enabled,
  }) async {
    final encodedId = Uri.encodeComponent(_requireOpaqueIdentifier(id));
    await _dio.patch<dynamic>(
      '$_root/api/jobs/$encodedId',
      data: {'prompt': ?prompt, 'schedule': ?schedule, 'enabled': ?enabled},
    );
  }

  Future<void> deleteJob(String id) async {
    final encodedId = Uri.encodeComponent(_requireOpaqueIdentifier(id));
    await _dio.delete<dynamic>('$_root/api/jobs/$encodedId');
  }

  Future<void> pauseJob(String id) async {
    final encodedId = Uri.encodeComponent(_requireOpaqueIdentifier(id));
    await _dio.post<dynamic>('$_root/api/jobs/$encodedId/pause');
  }

  Future<void> resumeJob(String id) async {
    final encodedId = Uri.encodeComponent(_requireOpaqueIdentifier(id));
    await _dio.post<dynamic>('$_root/api/jobs/$encodedId/resume');
  }

  /// Triggers an immediate run outside the schedule (`POST /api/jobs/{id}/run`).
  Future<void> runJob(String id) async {
    final encodedId = Uri.encodeComponent(_requireOpaqueIdentifier(id));
    await _dio.post<dynamic>('$_root/api/jobs/$encodedId/run');
  }

  static Object? _sessionId(Object? data) {
    if (data is! Map) return null;
    final direct = data['id'] ?? data['session_id'];
    if (direct != null) return direct;
    final session = data['session'];
    if (session is Map) {
      final nested = session['id'] ?? session['session_id'];
      if (nested != null) return nested;
    }
    return null;
  }

  /// Resolves a pending approval gate (`POST /v1/runs/{id}/approval`).
  Future<void> resolveApproval(
    String runId, {
    required String approvalId,
    required bool approved,
  }) async {
    final encodedRunId = Uri.encodeComponent(runId);
    await _dio.post<dynamic>(
      '$_root/v1/runs/$encodedRunId/approval',
      data: {
        'choice': approved ? 'once' : 'deny',
        'approval_id': approvalId,
        'approved': approved,
        'decision': approved ? 'approve' : 'deny',
      },
    );
  }

  void close() => _dio.close(force: true);
}
