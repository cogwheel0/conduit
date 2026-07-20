import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/utils/sensitive_value_utils.dart';
import '../../../core/utils/unicode_prefix.dart';
import '../models/direct_completion.dart';
import '../models/direct_connection_profile.dart';

/// Applies the common direct-provider message policy at the adapter boundary.
///
/// Images are prompt inputs and therefore remain attached only to user turns.
/// A non-user turn that contained only images has no serializable content after
/// that filtering, so omit it rather than emitting an invalid empty protocol
/// message. The neutral chat builder applies the same policy, but adapters keep
/// this guard because they are also callable directly and through runtime
/// registries.
List<DirectChatMessage> requireSerializableDirectMessages(
  Iterable<DirectChatMessage> messages,
) {
  final result = <DirectChatMessage>[];
  for (final message in messages) {
    final parts = message.role == 'user'
        ? message.parts
        : message.parts.whereType<DirectTextPart>().toList(growable: false);
    if (parts.isEmpty) continue;
    result.add(DirectChatMessage(role: message.role, parts: parts));
  }
  if (result.isEmpty) {
    throw const DirectProviderException(
      'The direct request has no serializable messages.',
    );
  }
  return List<DirectChatMessage>.unmodifiable(result);
}

const String kDirectToolCallingUnsupportedMessage =
    'Direct tool calling is not supported yet.';

/// Rejects provider tool configuration before a built-in adapter sends it.
///
/// Conduit cannot safely treat a tool-call-only response as assistant text and
/// does not yet have a normalized permission/execution path for direct tools.
/// `none` remains valid because it explicitly disables tool selection.
void rejectUnsupportedDirectToolParameters(Map<String, dynamic> parameters) {
  bool populated(Object? value) => switch (value) {
    null => false,
    String value => value.trim().isNotEmpty,
    Iterable value => value.isNotEmpty,
    Map value => value.isNotEmpty,
    _ => true,
  };

  bool selectsTool(Object? value) {
    if (!populated(value)) return false;
    if (value is String && value.trim().toLowerCase() == 'none') return false;
    return true;
  }

  if (populated(parameters['tools']) ||
      populated(parameters['functions']) ||
      selectsTool(parameters['tool_choice']) ||
      selectsTool(parameters['function_call']) ||
      parameters['parallel_tool_calls'] == true) {
    throw const DirectProviderException(kDirectToolCallingUnsupportedMessage);
  }
}

Stream<List<int>> directResponseBytes(ResponseBody body) =>
    body.stream.cast<List<int>>();

const Duration kDirectStreamIdleTimeout = Duration(minutes: 5);
const Duration kDirectStreamMaxDuration = Duration(minutes: 30);
const Duration kDirectSuccessDrainTimeout = Duration(milliseconds: 500);
const int kMaxDirectStreamBytes = 64 * 1024 * 1024;
const int kMaxDirectSuccessDrainBytes = 256 * 1024;
const int kMaxDirectStreamCharacters = 8 * 1024 * 1024;
const int kMaxDirectStreamEvents = 100000;
const int kMaxDirectStreamWorkUnits = 1024 * 1024;

/// Provider-independent limits for normalized direct stream events.
///
/// Protocol adapters still enforce raw transfer, frame, and decoded-payload
/// limits. The chat dispatcher applies these limits again to the normalized
/// event stream so a future/runtime adapter cannot bypass Conduit's memory and
/// liveness bounds.
final class DirectNormalizedStreamLimits {
  const DirectNormalizedStreamLimits({
    this.idleTimeout = kDirectStreamIdleTimeout,
    this.maxDuration = kDirectStreamMaxDuration,
    this.maxCharacters = kMaxDirectStreamCharacters,
    this.maxEvents = kMaxDirectStreamEvents,
    this.maxWorkUnits = kMaxDirectStreamWorkUnits,
  });

  final Duration idleTimeout;
  final Duration maxDuration;
  final int maxCharacters;
  final int maxEvents;
  final int maxWorkUnits;
}

const int kMaxDirectUsageDepth = 8;
const int kMaxDirectUsageContainerEntries = 128;
const int kMaxDirectUsageNodes = 512;
const int kMaxDirectUsageStringCharacters = 16 * 1024;
const int kMaxDirectUsageIntegerBitLength = 63;

/// Validates immutable completion limits before an adapter can create a
/// client, controller, or fire-and-forget transport task. Keeping this at the
/// adapter construction boundary prevents invalid injected test/runtime
/// configuration from producing a run whose event stream or `done` future can
/// never settle.
void validateDirectCompletionStreamLimits({
  required Duration idleTimeout,
  required Duration maxDuration,
  required int maxBytes,
  required int maxCharacters,
  required int maxEvents,
}) {
  if (idleTimeout <= Duration.zero) {
    throw ArgumentError.value(idleTimeout, 'idleTimeout');
  }
  if (maxDuration <= Duration.zero) {
    throw ArgumentError.value(maxDuration, 'maxDuration');
  }
  if (maxBytes <= 0) throw RangeError.value(maxBytes, 'maxBytes');
  if (maxCharacters <= 0) {
    throw ArgumentError.value(maxCharacters, 'maxCharacters');
  }
  if (maxEvents <= 0) {
    throw ArgumentError.value(maxEvents, 'maxEvents');
  }
}

Stream<List<int>> directStreamingResponseBytes(
  ResponseBody body, {
  Duration idleTimeout = kDirectStreamIdleTimeout,
  Duration maxDuration = kDirectStreamMaxDuration,
  int maxBytes = kMaxDirectStreamBytes,
  bool Function()? successfulProtocolTerminal,
  Duration successDrainTimeout = kDirectSuccessDrainTimeout,
  int maxSuccessDrainBytes = kMaxDirectSuccessDrainBytes,
}) async* {
  if (idleTimeout <= Duration.zero) {
    throw ArgumentError.value(idleTimeout, 'idleTimeout');
  }
  if (maxDuration <= Duration.zero) {
    throw ArgumentError.value(maxDuration, 'maxDuration');
  }
  if (maxBytes <= 0) throw RangeError.value(maxBytes, 'maxBytes');
  if (successDrainTimeout <= Duration.zero) {
    throw ArgumentError.value(successDrainTimeout, 'successDrainTimeout');
  }
  if (maxSuccessDrainBytes <= 0) {
    throw RangeError.value(maxSuccessDrainBytes, 'maxSuccessDrainBytes');
  }

  final elapsed = Stopwatch()..start();
  Stopwatch? successDrainElapsed;
  final iterator = StreamIterator(directResponseBytes(body));
  var receivedBytes = 0;
  var drainedBytes = 0;
  var reachedEof = false;
  try {
    while (true) {
      final drainingSuccess = successfulProtocolTerminal?.call() == true;
      final remaining = maxDuration - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        if (drainingSuccess) {
          throw const DirectStreamDrainException();
        }
        throw const DirectProviderException(
          'The provider stream exceeded Conduit\'s time limit.',
        );
      }
      final drainRemaining = drainingSuccess
          ? successDrainTimeout -
                ((successDrainElapsed ??= Stopwatch()..start()).elapsed)
          : null;
      if (drainRemaining != null && drainRemaining <= Duration.zero) {
        throw const DirectStreamDrainException();
      }
      final enforcingAbsoluteLimit = remaining.compareTo(idleTimeout) <= 0;
      final normalWait = enforcingAbsoluteLimit ? remaining : idleTimeout;
      final wait =
          drainRemaining != null && drainRemaining.compareTo(normalWait) < 0
          ? drainRemaining
          : normalWait;
      bool hasNext;
      try {
        hasNext = await iterator.moveNext().timeout(wait);
      } on TimeoutException catch (error) {
        if (drainingSuccess) {
          throw DirectStreamDrainException(cause: error);
        }
        if (enforcingAbsoluteLimit) {
          throw DirectProviderException(
            'The provider stream exceeded Conduit\'s time limit.',
            cause: error,
          );
        }
        throw DirectProviderException(
          'The provider stream timed out while waiting for data.',
          cause: error,
        );
      } catch (error, stackTrace) {
        if (drainingSuccess) {
          Error.throwWithStackTrace(
            DirectStreamDrainException(cause: error),
            stackTrace,
          );
        }
        rethrow;
      }
      if (!hasNext) {
        reachedEof = true;
        break;
      }
      final chunk = iterator.current;
      receivedBytes += chunk.length;
      if (receivedBytes > maxBytes) {
        if (drainingSuccess) {
          throw const DirectStreamDrainException();
        }
        throw const DirectProviderException(
          'The provider stream exceeded Conduit\'s transfer limit.',
        );
      }
      if (drainingSuccess) {
        drainedBytes += chunk.length;
        if (drainedBytes > maxSuccessDrainBytes) {
          throw const DirectStreamDrainException();
        }
        // Bytes received after the protocol terminal exist only to drain the
        // HTTP body for keep-alive reuse. Feeding them back into the protocol
        // parser could turn an already-successful completion into duplicate
        // content or an error from hostile trailing frames.
        continue;
      }
      yield chunk;
    }
  } finally {
    elapsed.stop();
    successDrainElapsed?.stop();
    if (!reachedEof) _initiateDirectStreamCancellation(iterator);
  }
}

/// The provider emitted a successful protocol terminal but did not finish its
/// HTTP body within the small keep-alive drain budget.
///
/// Callers retain the already-emitted successful completion while cancelling
/// this non-reusable transport instead of waiting for the normal stream limits.
final class DirectStreamDrainException implements Exception {
  const DirectStreamDrainException({this.cause});

  final Object? cause;

  @override
  String toString() => 'The completed provider response could not be drained.';
}

/// Starts source teardown without letting a provider-controlled cancellation
/// future replace or indefinitely delay the stream's actual outcome.
///
/// Some HTTP stream implementations return a future from `onCancel`. A hostile
/// or broken peer can leave that future pending forever even after Conduit has
/// detected an idle, duration, or transfer-limit failure. The adapter still
/// needs to receive that failure so its own transport `finally` can run.
void _initiateDirectStreamCancellation(StreamIterator<List<int>> iterator) {
  try {
    unawaited(
      iterator.cancel().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  } catch (_) {
    // Cancellation is best-effort cleanup. A synchronous teardown failure must
    // not mask the provider error (or successful EOF) already being delivered.
  }
}

/// Bounds both aggregate output and decoded payloads for one provider run.
/// Raw transfer and line limits alone are insufficient because a peer can send
/// an excessive sequence of individually tiny, valid frames.
final class DirectStreamBudget {
  DirectStreamBudget({
    this.maxCharacters = kMaxDirectStreamCharacters,
    this.maxEvents = kMaxDirectStreamEvents,
    this.maxWorkUnits = kMaxDirectStreamWorkUnits,
  }) {
    if (maxCharacters <= 0) {
      throw ArgumentError.value(maxCharacters, 'maxCharacters');
    }
    if (maxEvents <= 0) {
      throw ArgumentError.value(maxEvents, 'maxEvents');
    }
    if (maxWorkUnits <= 0) {
      throw ArgumentError.value(maxWorkUnits, 'maxWorkUnits');
    }
  }

  final int maxCharacters;
  final int maxEvents;
  final int maxWorkUnits;
  int _characters = 0;
  int _events = 0;
  int _workUnits = 0;

  /// Counts decoded provider protocol payloads, including payloads that emit
  /// no text. The raw-byte ceiling alone still permits millions of tiny JSON
  /// frames to monopolize the isolate before a useful completion arrives.
  void addEvent() {
    _events += 1;
    if (_events > maxEvents) {
      throw const DirectProviderException(
        'The provider response exceeded Conduit\'s resource limit.',
      );
    }
  }

  void add(String value) => addCharacters(value.length);

  void addCharacters(int characters) {
    if (characters < 0) throw RangeError.value(characters, 'characters');
    _characters += characters;
    if (_characters > maxCharacters) {
      throw const DirectProviderException(
        'The provider response exceeded Conduit\'s size limit.',
      );
    }
  }

  /// Charges bounded normalization work that is not represented by text or
  /// by the top-level event count, such as nodes in usage metadata.
  void addWork(int units) {
    if (units < 0) throw RangeError.value(units, 'units');
    _workUnits += units;
    if (_workUnits > maxWorkUnits) {
      throw const DirectProviderException(
        'The provider response exceeded Conduit\'s resource limit.',
      );
    }
  }
}

/// A deeply frozen usage payload and the resources spent normalizing it.
///
/// The dispatcher charges both costs to the run-wide budget. Per-event usage
/// limits alone are insufficient because an adapter can otherwise emit many
/// individually valid maps and force unbounded aggregate allocation/work.
final class DirectNormalizedUsageMetadata {
  const DirectNormalizedUsageMetadata({
    required this.usage,
    required this.stringCharacters,
    required this.nodes,
  });

  final Map<String, dynamic> usage;
  final int stringCharacters;
  final int nodes;
}

/// Validates and deeply freezes provider-supplied usage metadata without
/// recursively walking or serializing an untrusted object graph.
///
/// Usage is persisted with the assistant message, so accepting cycles,
/// excessive nesting, or non-JSON values here would defer a provider-controlled
/// crash to the database encoder. Container and aggregate ceilings also keep a
/// single normalized event from bypassing the stream's event/character budget.
Map<String, dynamic> normalizeDirectUsageMetadata(
  Map<String, dynamic> usage, {
  int maxDepth = kMaxDirectUsageDepth,
  int maxContainerEntries = kMaxDirectUsageContainerEntries,
  int maxNodes = kMaxDirectUsageNodes,
  int maxStringCharacters = kMaxDirectUsageStringCharacters,
}) => normalizeDirectUsageMetadataWithCost(
  usage,
  maxDepth: maxDepth,
  maxContainerEntries: maxContainerEntries,
  maxNodes: maxNodes,
  maxStringCharacters: maxStringCharacters,
).usage;

DirectNormalizedUsageMetadata normalizeDirectUsageMetadataWithCost(
  Map<String, dynamic> usage, {
  int maxDepth = kMaxDirectUsageDepth,
  int maxContainerEntries = kMaxDirectUsageContainerEntries,
  int maxNodes = kMaxDirectUsageNodes,
  int maxStringCharacters = kMaxDirectUsageStringCharacters,
}) {
  if (maxDepth <= 0) throw RangeError.value(maxDepth, 'maxDepth');
  if (maxContainerEntries <= 0) {
    throw RangeError.value(maxContainerEntries, 'maxContainerEntries');
  }
  if (maxNodes <= 0) throw RangeError.value(maxNodes, 'maxNodes');
  if (maxStringCharacters <= 0) {
    throw RangeError.value(maxStringCharacters, 'maxStringCharacters');
  }

  Object? normalized;
  var nodes = 0;
  var stringCharacters = 0;
  final activeContainers = HashSet<Object>.identity();
  final tasks = <_DirectUsageWalkTask>[
    _DirectUsageVisit(usage, 0, (value) => normalized = value),
  ];

  Never reject() => throw const DirectProviderException(
    'The provider returned invalid or excessive usage metadata.',
  );

  void countString(String value) {
    stringCharacters += value.length;
    if (stringCharacters > maxStringCharacters) reject();
  }

  while (tasks.isNotEmpty) {
    final task = tasks.removeLast();
    if (task is _DirectUsageFinish) {
      activeContainers.remove(task.container);
      task.assign(task.freeze());
      continue;
    }

    final visit = task as _DirectUsageVisit;
    nodes += 1;
    if (nodes > maxNodes) reject();
    final value = visit.value;
    if (value == null || value is bool) {
      visit.assign(value);
      continue;
    }
    if (value is int) {
      if (value.bitLength > kMaxDirectUsageIntegerBitLength) reject();
      visit.assign(value);
      continue;
    }
    if (value is num) {
      if (!value.isFinite) reject();
      visit.assign(value);
      continue;
    }
    if (value is String) {
      countString(value);
      visit.assign(value);
      continue;
    }
    if (value is List) {
      if (visit.depth >= maxDepth ||
          value.length > maxContainerEntries ||
          !activeContainers.add(value)) {
        reject();
      }
      final mutable = List<Object?>.filled(value.length, null);
      tasks.add(
        _DirectUsageFinish(
          value,
          () => List<Object?>.unmodifiable(mutable),
          visit.assign,
        ),
      );
      for (var index = value.length - 1; index >= 0; index--) {
        final targetIndex = index;
        tasks.add(
          _DirectUsageVisit(
            value[targetIndex],
            visit.depth + 1,
            (child) => mutable[targetIndex] = child,
          ),
        );
      }
      continue;
    }
    if (value is Map) {
      if (visit.depth >= maxDepth ||
          value.length > maxContainerEntries ||
          !activeContainers.add(value)) {
        reject();
      }
      final entries = value.entries.toList(growable: false);
      final mutable = <String, Object?>{};
      tasks.add(
        _DirectUsageFinish(
          value,
          () => Map<String, Object?>.unmodifiable(mutable),
          visit.assign,
        ),
      );
      for (var index = entries.length - 1; index >= 0; index--) {
        final entry = entries[index];
        final key = entry.key;
        if (key is! String) reject();
        countString(key);
        tasks.add(
          _DirectUsageVisit(
            entry.value,
            visit.depth + 1,
            (child) => mutable[key] = child,
          ),
        );
      }
      continue;
    }
    reject();
  }

  return DirectNormalizedUsageMetadata(
    usage: (normalized as Map).cast<String, dynamic>(),
    stringCharacters: stringCharacters,
    nodes: nodes,
  );
}

typedef _DirectUsageAssign = void Function(Object? value);

sealed class _DirectUsageWalkTask {
  const _DirectUsageWalkTask();
}

final class _DirectUsageVisit extends _DirectUsageWalkTask {
  const _DirectUsageVisit(this.value, this.depth, this.assign);

  final Object? value;
  final int depth;
  final _DirectUsageAssign assign;
}

final class _DirectUsageFinish extends _DirectUsageWalkTask {
  const _DirectUsageFinish(this.container, this.freeze, this.assign);

  final Object container;
  final Object? Function() freeze;
  final _DirectUsageAssign assign;
}

const int kMaxDirectJsonResponseBytes = 10 * 1024 * 1024;

Future<Object?> decodeDirectJsonValue(
  ResponseBody body, {
  int maxBytes = kMaxDirectJsonResponseBytes,
  Duration idleTimeout = kDirectStreamIdleTimeout,
  Duration maxDuration = kDirectStreamMaxDuration,
  int maxTransferBytes = kMaxDirectStreamBytes,
}) async {
  if (maxBytes <= 0) throw RangeError.value(maxBytes, 'maxBytes');
  final bytes = <int>[];
  await for (final chunk in directStreamingResponseBytes(
    body,
    idleTimeout: idleTimeout,
    maxDuration: maxDuration,
    maxBytes: maxTransferBytes,
  )) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const FormatException('Provider response is too large.');
    }
    bytes.addAll(chunk);
  }
  return jsonDecode(utf8.decode(bytes));
}

Future<Map<String, dynamic>> decodeDirectJsonBody(
  ResponseBody body, {
  int maxBytes = kMaxDirectJsonResponseBytes,
  Duration idleTimeout = kDirectStreamIdleTimeout,
  Duration maxDuration = kDirectStreamMaxDuration,
  int maxTransferBytes = kMaxDirectStreamBytes,
}) async {
  final decoded = await decodeDirectJsonValue(
    body,
    maxBytes: maxBytes,
    idleTimeout: idleTimeout,
    maxDuration: maxDuration,
    maxTransferBytes: maxTransferBytes,
  );
  if (decoded is! Map) {
    throw const FormatException('Provider response must be a JSON object.');
  }
  return decoded.cast<String, dynamic>();
}

DirectProviderException normalizeDirectProviderError(Object error) {
  if (error is DirectProviderException) return error;
  if (error is TimeoutException) {
    return DirectProviderException(
      'The provider stream timed out while waiting for data.',
      cause: error,
    );
  }
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status != null) {
      return DirectProviderException(
        'The provider returned HTTP $status.',
        statusCode: status,
        cause: error,
      );
    }
    return DirectProviderException(switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => 'The provider request timed out.',
      DioExceptionType.cancel => 'The provider request was cancelled.',
      _ => 'Could not connect to the provider.',
    }, cause: error);
  }
  if (error is FormatException) {
    return DirectProviderException(
      'The provider returned an invalid response.',
      cause: error,
    );
  }
  return DirectProviderException('The provider request failed.', cause: error);
}

const int kMaxDirectProviderErrorCharacters = 512;
const String _redactedProviderValue = '[REDACTED]';
const int _maxProviderErrorSecretPatterns = 128;
const int _maxProviderErrorSecretPatternCharacters = 8 * 1024;
const int _maxProviderErrorSecretPatternTotalCharacters = 64 * 1024;
final String _invalidProviderSensitiveValuesSentinel = List<String>.filled(
  _maxProviderErrorSecretPatternCharacters + 1,
  'x',
).join();

/// Every profile value that must be treated as confidential when a provider or
/// runtime adapter can reflect request configuration in an error.
List<String> directProfileSensitiveValues(DirectConnectionProfile profile) {
  final values = <String>{};
  var totalCharacters = 0;
  var invalid = false;

  void addCandidate(String candidate) {
    if (invalid || candidate.isEmpty || values.contains(candidate)) return;
    if (candidate.length > _maxProviderErrorSecretPatternCharacters ||
        values.length >= _maxProviderErrorSecretPatterns ||
        totalCharacters + candidate.length >
            _maxProviderErrorSecretPatternTotalCharacters) {
      invalid = true;
      values.clear();
      return;
    }
    values.add(candidate);
    totalCharacters += candidate.length;
  }

  void add(String? raw, {bool normalizePem = false}) {
    if (invalid || raw == null || raw.isEmpty) return;
    // Check before trim/line-ending normalization so an imported oversized
    // profile cannot force multiple unbounded copies merely by failing closed.
    if (raw.length > _maxProviderErrorSecretPatternCharacters) {
      invalid = true;
      values.clear();
      return;
    }
    addCandidate(raw);
    addCandidate(raw.trim());
    if (invalid) return;
    if (normalizePem) {
      final lf = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      final trimmedLf = lf.trim();
      addCandidate(lf);
      addCandidate(trimmedLf);
      addCandidate(lf.replaceAll('\n', '\r\n'));
      addCandidate(trimmedLf.replaceAll('\n', '\r\n'));
      // TLS stacks often report the offending PEM line instead of replaying
      // the complete document. Treat each bounded line as sensitive too.
      for (final line in lf.split('\n')) {
        addCandidate(line.trim());
        if (invalid) return;
      }
    }
  }

  add(profile.apiKey);
  for (final value in profile.customHeaders.values) {
    final variants = boundedSensitiveValueVariants(
      value,
      maxCharacters: _maxProviderErrorSecretPatternCharacters,
      maxVariants: _maxProviderErrorSecretPatterns,
    );
    if (variants == null) {
      invalid = true;
      values.clear();
      break;
    }
    for (final candidate in variants) {
      addCandidate(candidate);
      if (invalid) break;
    }
    if (invalid) break;
  }
  add(profile.mtlsCertificateChainPem, normalizePem: true);
  add(profile.mtlsCertificateLabel);
  add(profile.mtlsPrivateKeyPem, normalizePem: true);
  add(profile.mtlsPrivateKeyLabel);
  add(profile.mtlsPrivateKeyPassword);
  if (invalid) {
    return List<String>.unmodifiable([_invalidProviderSensitiveValuesSentinel]);
  }
  return List<String>.unmodifiable(values);
}

/// Extracts a provider protocol error without allowing it to become a secret
/// exfiltration or control-character injection channel when persisted in chat.
String directErrorMessage(
  Object? raw, {
  Iterable<String> sensitiveValues = const <String>[],
  int maxCharacters = kMaxDirectProviderErrorCharacters,
}) {
  var current = raw;
  final visited = <Object>{};
  for (var depth = 0; depth < 8; depth++) {
    if (current is String && current.trim().isNotEmpty) {
      return sanitizeDirectProviderErrorMessage(
        current,
        sensitiveValues: sensitiveValues,
        maxCharacters: maxCharacters,
      );
    }
    if (current is! Map || !visited.add(current)) break;
    final nested = current['message'] ?? current['detail'] ?? current['error'];
    if (nested == null || identical(nested, current)) break;
    current = nested;
  }
  return 'The provider reported an error.';
}

String sanitizeDirectProviderErrorMessage(
  String raw, {
  Iterable<String> sensitiveValues = const <String>[],
  int maxCharacters = kMaxDirectProviderErrorCharacters,
}) {
  if (maxCharacters <= 0) {
    throw RangeError.value(maxCharacters, 'maxCharacters');
  }

  final secrets = <String>{};
  var secretCharacters = 0;
  for (final value in sensitiveValues) {
    if (value.isEmpty) continue;
    // A provider may reflect any substring of a configured credential. There
    // is no bounded pattern that can safely redact every substring of an
    // oversized value, so fail closed instead of exposing an unmatched tail.
    if (value.length > _maxProviderErrorSecretPatternCharacters) {
      return 'The provider reported an error.';
    }
    if (!secrets.add(value)) continue;
    secretCharacters += value.length;
    if (secrets.length > _maxProviderErrorSecretPatterns ||
        secretCharacters > _maxProviderErrorSecretPatternTotalCharacters) {
      // A pathological imported profile must not turn an untrusted provider
      // error into either an amplification attack or a partially redacted log.
      return 'The provider reported an error.';
    }
  }
  final orderedSecrets = secrets.toList(growable: false)
    ..sort((a, b) => b.length.compareTo(a.length));
  // Bound by Unicode scalar rather than UTF-16 code unit. Otherwise preceding
  // supplementary characters can make this prefix end inside a configured
  // secret, leaving a fragment that the exact-secret pass cannot recognize.
  var safe = redactSensitiveValuesInUnicodePrefix(
    raw,
    sensitiveValues: orderedSecrets,
    maxVisibleScalars: maxCharacters,
  );

  // Authorization values can contain a scheme followed by whitespace-rich
  // credentials (for example Digest parameters). Redact the complete header
  // value before applying the narrower single-token rules below.
  safe = safe.replaceAllMapped(
    RegExp(
      r'\b(authorization|proxy-authorization)\b\s*[:=]\s*[^\r\n]*',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}: $_redactedProviderValue',
  );

  // Redact common credential labels even when a compatible provider reflects
  // a value that was not part of the configured profile.
  safe = safe.replaceAllMapped(
    RegExp(
      r'\b(api[-_ ]?key|access[-_ ]?token|password|secret)\b\s*[:=]\s*(?:bearer\s+)?[^\s,;]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}: $_redactedProviderValue',
  );
  safe = safe.replaceAllMapped(
    RegExp(r'\bbearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    (_) => 'Bearer $_redactedProviderValue',
  );

  safe = safe
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (safe.isEmpty) return 'The provider reported an error.';

  final iterator = safe.runes.iterator;
  final prefix = <int>[];
  while (prefix.length < maxCharacters && iterator.moveNext()) {
    prefix.add(iterator.current);
  }
  if (!iterator.moveNext()) return String.fromCharCodes(prefix);
  if (maxCharacters == 1) return '…';
  return '${String.fromCharCodes(prefix.take(maxCharacters - 1))}…';
}
