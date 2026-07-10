import 'dart:async';
import 'dart:convert';

import '../../../core/services/sse_frame_scanner.dart';
import '../models/hermes_run_event.dart';

/// Parses a Hermes runs SSE byte stream into typed [HermesRunEvent]s.
///
/// Reuses the shared [SseFrameScanner] for byte-level framing (split frames,
/// CRLF, multibyte UTF-8) and layers Hermes-specific decoding on top.
Stream<HermesRunEvent> parseHermesRunStream(Stream<List<int>> chunks) async* {
  final scanner = SseFrameScanner();
  final textChunks = chunks.transform(utf8.decoder);

  await for (final chunk in textChunks) {
    for (final frame in scanner.addChunk(chunk)) {
      for (final event in parseHermesRunFrame(frame)) {
        yield event;
      }
    }
  }
  for (final frame in scanner.close()) {
    for (final event in parseHermesRunFrame(frame)) {
      yield event;
    }
  }
}

/// Decodes a single SSE [frame] into zero or more [HermesRunEvent]s.
///
/// Decoding is intentionally tolerant: the Hermes runs API mixes OpenAI
/// chat-completion chunks, Responses-API event types, and bespoke
/// `tool.*` / `approval.*` events depending on version. Unrecognized frames
/// yield nothing rather than throwing.
Iterable<HermesRunEvent> parseHermesRunFrame(SseFrame frame) sync* {
  final raw = frame.data.trim();
  final declaredEvent = frame.event?.trim().toLowerCase();
  final frameEventType = declaredEvent == null || declaredEvent.isEmpty
      ? null
      : declaredEvent;
  // Unlike OpenWebUI heartbeats, Hermes may encode terminal lifecycle state in
  // the SSE event field with an explicitly empty data payload.
  if (raw.isEmpty) {
    final emptyStatus =
        frameEventType != null && frameEventType.startsWith('run.')
        ? frameEventType.substring('run.'.length)
        : _lifecycleStatus(frameEventType, const <String, dynamic>{});
    if (emptyStatus == null || !_isTerminal(emptyStatus)) return;
  }
  if (raw == '[DONE]') {
    yield const HermesRunDone();
    return;
  }

  Map<String, dynamic> data = const <String, dynamic>{};
  if (raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      data = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }
  }

  final eventType =
      (frameEventType ?? _str(data['type']) ?? _str(data['event']))
          ?.toLowerCase();

  // Documented Responses-style error events carry `type: "error"` and put
  // their code/message at the top level rather than under an `error` field.
  if (eventType == 'error') {
    final error = data['error'] ?? data['message'] ?? data['detail'];
    yield HermesRunError(
      _isTruthyError(error) ? _errorMessage(error) : 'Hermes run failed.',
    );
    return;
  }

  // Errors first — terminal. Guard against falsy `error` fields that appear on
  // non-error events (e.g. `tool.completed` carries `error: "False"`).
  final error = data['error'];
  if (_isTruthyError(error)) {
    yield HermesRunError(_errorMessage(error));
    return;
  }

  // Human-approval gate.
  if ((eventType?.contains('approval') ?? false) ||
      data.containsKey('approval_id') ||
      data.containsKey('approvalId')) {
    final approvalId =
        _str(data['approval_id']) ??
        _str(data['approvalId']) ??
        _str(data['id']);
    if (approvalId != null) {
      yield HermesApprovalRequested(
        approvalId: approvalId,
        summary:
            _str(data['summary']) ??
            _str(data['description']) ??
            _str(data['prompt']) ??
            _str(data['message']),
        raw: data,
      );
      return;
    }
  }

  // Terminal lifecycle (`run.completed` / `run.failed` / `run.cancelled` /
  // `run.stopped`). `run.completed` carries the full `output` as a fallback.
  if (eventType != null && eventType.startsWith('run.')) {
    final status = eventType.substring('run.'.length);
    if (status == 'completed' ||
        status == 'failed' ||
        status == 'cancelled' ||
        status == 'stopped') {
      if (status == 'failed') {
        yield HermesRunError(_failureMessage(data['error']));
      } else {
        final output = extractHermesOutputText(data['output']);
        if (output.isNotEmpty) {
          yield HermesFinalOutput(output);
        }
      }
      yield const HermesRunDone();
      return;
    }
    // run.started / other non-terminal lifecycle.
    yield HermesLifecycle(status);
    return;
  }

  // Tool progress.
  final toolEvent = _maybeToolProgress(eventType, data);
  if (toolEvent != null) {
    yield toolEvent;
    return;
  }

  // Token / reasoning deltas.
  var emitted = false;
  for (final delta in _textDeltas(eventType, data)) {
    emitted = true;
    yield delta;
  }
  if (emitted) return;

  // Generic lifecycle fallback (explicit status field / Responses-API events).
  final status = _lifecycleStatus(eventType, data);
  if (status != null) {
    // A failed terminal lifecycle (e.g. `response.failed`) must surface an
    // error; a bare HermesLifecycle is treated downstream as an advisory no-op.
    if (status == 'failed') {
      yield HermesRunError(_failureMessage(data['error']));
    } else {
      yield HermesLifecycle(status);
    }
    if (_isTerminal(status)) {
      yield const HermesRunDone();
    }
  }
}

/// Extracts visible assistant text from a terminal/recovered Hermes output.
/// Function-call items are deliberately omitted from the rendered answer.
String extractHermesOutputText(dynamic output) {
  if (output == null) return '';
  if (output is String) return output;
  final buffer = StringBuffer();
  if (output is List) {
    for (final item in output) {
      if (item is String) {
        buffer.write(item);
      } else if (item is Map) {
        final type = item['type']?.toString();
        if (type != null && type.contains('function')) continue;
        buffer.write(extractHermesOutputText(item['content'] ?? item['text']));
      }
    }
  } else if (output is Map) {
    buffer.write(extractHermesOutputText(output['text'] ?? output['content']));
  }
  return buffer.toString();
}

HermesToolProgress? _maybeToolProgress(
  String? eventType,
  Map<String, dynamic> data,
) {
  final isToolEvent =
      (eventType != null &&
          (eventType.contains('tool') ||
              eventType == 'response.output_item.added' ||
              eventType == 'response.output_item.done')) ||
      data.containsKey('tool') ||
      data.containsKey('tool_name');
  if (!isToolEvent) return null;

  // Responses-API items wrap the tool under `item`.
  final item = data['item'];
  final itemMap = item is Map ? item.cast<String, dynamic>() : null;
  if (eventType != null &&
      eventType.startsWith('response.output_item') &&
      (itemMap?['type']?.toString().contains('function') != true)) {
    return null;
  }

  final toolName =
      _str(data['tool']) ??
      _str(data['tool_name']) ??
      _str(data['name']) ??
      _str(itemMap?['name']) ??
      'tool';

  final statusStr = _str(data['status'])?.toLowerCase();
  final done =
      (eventType?.contains('completed') ?? false) ||
      (eventType?.contains('failed') ?? false) ||
      (eventType?.endsWith('.done') ?? false) ||
      data['done'] == true ||
      statusStr == 'completed' ||
      statusStr == 'done' ||
      statusStr == 'success' ||
      // Failed/cancelled/stopped tool runs are terminal too — otherwise the
      // tool row spins forever.
      statusStr == 'failed' ||
      statusStr == 'cancelled' ||
      statusStr == 'canceled' ||
      statusStr == 'stopped' ||
      statusStr == 'error';

  return HermesToolProgress(
    toolName: toolName,
    done: done,
    detail:
        _str(data['preview']) ??
        _str(data['detail']) ??
        _str(data['summary']) ??
        _str(data['message']) ??
        _str(data['arguments']),
  );
}

Iterable<HermesRunEvent> _textDeltas(
  String? eventType,
  Map<String, dynamic> data,
) sync* {
  // OpenAI chat-completion chunk shape.
  final choices = data['choices'];
  if (choices is List && choices.isNotEmpty) {
    final first = choices.first;
    if (first is Map) {
      final delta = first['delta'];
      if (delta is Map) {
        final reasoning = _str(delta['reasoning_content']);
        if (reasoning != null && reasoning.isNotEmpty) {
          yield HermesReasoningDelta(reasoning);
        }
        final content = _str(delta['content']);
        if (content != null && content.isNotEmpty) {
          yield HermesTokenDelta(content);
        }
      }
    }
    return;
  }

  // Hermes runs token deltas (`message.delta`), Responses-API
  // (`response.output_text.delta`), and Sessions (`assistant.delta`).
  if (eventType == 'message.delta' ||
      eventType == 'response.output_text.delta' ||
      eventType == 'assistant.delta') {
    final text =
        _str(data['delta']) ?? _str(data['content']) ?? _str(data['text']);
    if (text != null && text.isNotEmpty) {
      yield HermesTokenDelta(text);
    }
    return;
  }

  // Incremental reasoning. `reasoning.available` carries the full reasoning
  // (often mirroring the answer), so only stream explicit deltas to avoid
  // duplicating content.
  if (eventType == 'reasoning.delta') {
    final text = _str(data['delta']) ?? _str(data['text']);
    if (text != null && text.isNotEmpty) {
      yield HermesReasoningDelta(text);
    }
    return;
  }

  // Generic fallback: a bare token-bearing field on a delta-shaped event.
  if (eventType != null &&
      eventType.contains('delta') &&
      !eventType.contains('reasoning')) {
    final text =
        _str(data['delta']) ?? _str(data['content']) ?? _str(data['text']);
    if (text != null && text.isNotEmpty) {
      yield HermesTokenDelta(text);
    }
  }
}

String? _lifecycleStatus(String? eventType, Map<String, dynamic> data) {
  final explicit = _str(data['status']);
  if (explicit != null) return explicit.toLowerCase();
  switch (eventType) {
    case 'response.created':
    case 'run.created':
      return 'created';
    case 'response.completed':
    case 'run.completed':
      return 'completed';
    case 'response.failed':
    case 'run.failed':
      return 'failed';
    case 'run.cancelled':
      return 'cancelled';
    case 'done':
      return 'completed';
    default:
      return null;
  }
}

bool _isTerminal(String status) =>
    status == 'completed' ||
    status == 'failed' ||
    status == 'cancelled' ||
    status == 'stopped';

/// Whether an `error` field represents a real failure (vs. a falsy marker like
/// `false` / `"False"` / `"None"` that some events include).
bool _isTruthyError(dynamic error) {
  if (error == null) return false;
  if (error is bool) return error;
  // Python servers often send `error: 0` (int) as a non-error marker.
  if (error is num) return error != 0;
  if (error is Map) return error.isNotEmpty;
  if (error is String) {
    final v = error.trim().toLowerCase();
    return v.isNotEmpty &&
        v != 'false' &&
        v != 'none' &&
        v != 'null' &&
        v != '0';
  }
  return true;
}

String _errorMessage(dynamic error) {
  if (error is Map) {
    return _str(error['message']) ?? _str(error['detail']) ?? error.toString();
  }
  return error.toString();
}

/// Failure message for a terminal error event, falling back to a generic
/// message when the `error` field is a falsy marker (`"False"` / `0` / null)
/// rather than a real description.
String _failureMessage(dynamic error) =>
    _isTruthyError(error) ? _errorMessage(error) : 'Hermes run failed.';

String? _str(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}
