import 'dart:async';
import 'dart:convert';

import 'package:openai_dart/openai_dart.dart' as openai;

import '../../../core/services/openai_responses_codec.dart';
import '../../../core/services/sse_frame_scanner.dart';
import '../models/hermes_run_event.dart';

/// Parses a Hermes runs SSE byte stream into typed [HermesRunEvent]s.
///
/// Reuses the shared [SseFrameScanner] for byte-level framing (split frames,
/// CRLF, multibyte UTF-8) and layers Hermes-specific decoding on top.
Stream<HermesRunEvent> parseHermesRunStream(Stream<List<int>> chunks) =>
    _parseHermesStream(chunks, parseHermesRunFrame);

/// Parses the OpenAI-compatible `/v1/responses` stream with `openai_dart`.
///
/// Hermes versions predating the strict Responses schema can emit sparse
/// lifecycle envelopes or custom aliases. Those frames fall back to the
/// narrow, tolerant Hermes mapper while valid standard frames stay SDK-owned.
Stream<HermesRunEvent> parseHermesResponseStream(Stream<List<int>> chunks) =>
    _parseHermesStream(chunks, parseHermesResponseFrame);

Stream<HermesRunEvent> _parseHermesStream(
  Stream<List<int>> chunks,
  Iterable<HermesRunEvent> Function(SseFrame frame) decodeFrame,
) async* {
  final scanner = SseFrameScanner();
  final textChunks = chunks.transform(utf8.decoder);

  await for (final chunk in textChunks) {
    for (final frame in scanner.addChunk(chunk)) {
      for (final event in decodeFrame(frame)) {
        yield event;
      }
    }
  }
  for (final frame in scanner.close()) {
    for (final event in decodeFrame(frame)) {
      yield event;
    }
  }
}

/// Decodes one Responses SSE frame using the SDK before applying Hermes-only
/// compatibility handling.
Iterable<HermesRunEvent> parseHermesResponseFrame(SseFrame frame) sync* {
  final raw = frame.data.trim();
  if (raw.isEmpty) return;
  if (raw == '[DONE]') {
    yield const HermesRunDone();
    return;
  }

  Map<String, dynamic> payload;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    payload = decoded.cast<String, dynamic>();
  } catch (_) {
    return;
  }

  final declaredType = frame.event?.trim();
  if (payload['type'] == null &&
      declaredType != null &&
      declaredType.isNotEmpty) {
    payload = <String, dynamic>{...payload, 'type': declaredType};
  } else if (payload['type'] == null && payload['event'] is String) {
    payload = <String, dynamic>{...payload, 'type': payload['event']};
  }
  final type = payload['type']?.toString().trim().toLowerCase();
  if (type == null || type.isEmpty) {
    yield* parseHermesRunFrame(frame);
    return;
  }

  // Hermes exposes tool results as output items for progress rendering. The
  // OpenAI SDK correctly models function-call results as subsequent *input*
  // items, so this Hermes extension is intentionally ignored here; the
  // matching function_call.done frame already closes the visible tool row.
  if ((type == 'response.output_item.added' ||
          type == 'response.output_item.done') &&
      payload['item'] is Map &&
      (payload['item'] as Map)['type'] == 'function_call_output') {
    return;
  }

  if (type == 'error' || type.startsWith('response.')) {
    try {
      final event = OpenAiResponsesCodec.decodeStreamEvent(payload);
      yield* _mapOpenAiResponseEvent(event);
      return;
    } catch (_) {
      // Current and older Hermes servers sometimes omit SDK-required response
      // or item metadata. Preserve that wire compatibility without weakening
      // strict direct OpenAI-compatible adapters.
      yield* parseHermesRunFrame(frame);
      return;
    }
  }

  yield* parseHermesRunFrame(frame);
}

Iterable<HermesRunEvent> _mapOpenAiResponseEvent(
  openai.ResponseStreamEvent event,
) sync* {
  switch (event) {
    case openai.ResponseCreatedEvent(:final response):
      yield HermesResponseCreated(response.id);
      yield const HermesLifecycle('created');

    case openai.ResponseQueuedEvent(:final response):
      yield HermesResponseCreated(response.id);
      yield const HermesLifecycle('queued');

    case openai.ResponseInProgressEvent(:final response):
      yield HermesResponseCreated(response.id);
      yield const HermesLifecycle('in_progress');

    case openai.OutputTextDeltaEvent(:final delta):
      if (delta.isNotEmpty) yield HermesTokenDelta(delta);

    case openai.RefusalDeltaEvent(:final delta):
      if (delta.isNotEmpty) yield HermesTokenDelta(delta);

    case openai.ReasoningTextDeltaEvent(:final delta):
      if (delta.isNotEmpty) yield HermesReasoningDelta(delta);

    case openai.ReasoningSummaryTextDeltaEvent(:final delta):
      if (delta.isNotEmpty) yield HermesReasoningDelta(delta);

    case openai.OutputItemAddedEvent(:final item):
      final progress = _sdkToolProgress(item, done: false);
      if (progress != null) yield progress;

    case openai.OutputItemDoneEvent(:final item):
      final progress = _sdkToolProgress(item, done: true);
      if (progress != null) yield progress;

    case openai.ResponseCompletedEvent(:final response):
      yield* _mapTerminalResponse(response);

    case openai.ResponseFailedEvent(:final response):
      yield HermesResponseCreated(response.id);
      yield HermesRunError(
        OpenAiResponsesCodec.statusError(
              response,
              subject: 'Hermes response',
            ) ??
            'Hermes response failed.',
      );
      yield const HermesRunDone();

    case openai.ResponseIncompleteEvent(:final response):
      yield HermesResponseCreated(response.id);
      yield HermesRunError(
        OpenAiResponsesCodec.statusError(
              response,
              subject: 'Hermes response',
            ) ??
            'The Hermes response was incomplete.',
      );
      yield const HermesRunDone();

    case openai.ErrorEvent(:final message):
      yield HermesRunError(message);

    case openai.UnknownEvent(:final type, :final rawJson)
        when type == 'response.reasoning.delta' ||
            type == 'response.reasoning_summary.delta':
      final delta = rawJson['delta'] ?? rawJson['text'];
      if (delta is String && delta.isNotEmpty) {
        yield HermesReasoningDelta(delta);
      }

    default:
      break;
  }
}

Iterable<HermesRunEvent> _mapTerminalResponse(openai.Response response) sync* {
  yield HermesResponseCreated(response.id);
  final statusError = OpenAiResponsesCodec.statusError(
    response,
    subject: 'Hermes response',
  );
  if (statusError != null) {
    yield HermesRunError(statusError);
    yield const HermesRunDone();
    return;
  }
  final content = OpenAiResponsesCodec.content(response);
  if (content.reasoning.isNotEmpty) {
    yield HermesReasoningDelta(content.reasoning);
  }
  if (content.text.isNotEmpty) yield HermesFinalOutput(content.text);
  yield const HermesRunDone();
}

HermesToolProgress? _sdkToolProgress(
  openai.OutputItem item, {
  required bool done,
}) {
  if (item is! openai.FunctionCallOutputItemResponse) return null;
  return HermesToolProgress(
    toolName: item.name.isEmpty ? 'tool' : item.name,
    detail: item.arguments.isEmpty ? null : item.arguments,
    done: done,
  );
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

  // Responses lifecycle envelopes keep their identity, final output, and
  // errors under `response`. Preserve those details before the generic
  // lifecycle fallback reduces the frame to a status string.
  if (eventType == 'response.created') {
    final response = data['response'];
    final responseMap = response is Map ? response : null;
    final responseId = _str(responseMap?['id']) ?? _str(data['id']);
    if (responseId != null && responseId.isNotEmpty) {
      yield HermesResponseCreated(responseId);
    }
    yield const HermesLifecycle('created');
    return;
  }
  if (eventType == 'response.completed') {
    final response = data['response'];
    final responseMap = response is Map ? response : null;
    final responseId = _str(responseMap?['id']) ?? _str(data['id']);
    if (responseId != null && responseId.isNotEmpty) {
      yield HermesResponseCreated(responseId);
    }
    final status = _str(
      responseMap?['status'] ?? data['status'],
    )?.toLowerCase();
    final statusError = _fallbackResponseStatusError(
      status,
      responseMap ?? data,
    );
    if (statusError != null) {
      yield HermesRunError(statusError);
      yield const HermesRunDone();
      return;
    }
    final output = extractHermesOutputText(
      responseMap?['output'] ?? data['output'],
    );
    if (output.isNotEmpty) yield HermesFinalOutput(output);
    yield const HermesRunDone();
    return;
  }
  if (eventType == 'response.failed') {
    final response = data['response'];
    final responseMap = response is Map ? response : null;
    final responseId = _str(responseMap?['id']) ?? _str(data['id']);
    if (responseId != null && responseId.isNotEmpty) {
      yield HermesResponseCreated(responseId);
    }
    yield HermesRunError(
      _failureMessage(responseMap?['error'] ?? data['error']),
    );
    yield const HermesRunDone();
    return;
  }
  if (eventType == 'response.incomplete') {
    final response = data['response'];
    final responseMap = response is Map ? response : null;
    final responseId = _str(responseMap?['id']) ?? _str(data['id']);
    if (responseId != null && responseId.isNotEmpty) {
      yield HermesResponseCreated(responseId);
    }
    yield HermesRunError(
      _fallbackResponseStatusError('incomplete', responseMap ?? data) ??
          'The Hermes response was incomplete.',
    );
    yield const HermesRunDone();
    return;
  }

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
  // non-error events (e.g. `tool.completed` carries `error: "False"`). Tool
  // failures remain scoped to their tool row; they do not fail the whole run.
  final error = data['error'];
  final isToolLifecycle = eventType?.contains('tool') ?? false;
  if (_isTruthyError(error) && !isToolLifecycle) {
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
  // `run.canceled` / `run.stopped`). `run.completed` carries the full `output`
  // as a fallback.
  if (eventType != null && eventType.startsWith('run.')) {
    final status = eventType.substring('run.'.length);
    if (status == 'completed' ||
        status == 'failed' ||
        status == 'cancelled' ||
        status == 'canceled' ||
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
  final failed =
      (eventType?.contains('failed') ?? false) ||
      statusStr == 'failed' ||
      statusStr == 'error' ||
      _isTruthyError(data['error']);
  final done =
      (eventType?.contains('completed') ?? false) ||
      (eventType?.contains('failed') ?? false) ||
      (eventType?.contains('error') ?? false) ||
      (eventType?.contains('cancelled') ?? false) ||
      (eventType?.contains('canceled') ?? false) ||
      (eventType?.contains('stopped') ?? false) ||
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
    failed: failed,
    detail:
        _str(data['preview']) ??
        _str(data['detail']) ??
        _str(data['summary']) ??
        _str(data['message']) ??
        _str(data['arguments']) ??
        (_isTruthyError(data['error']) ? _errorMessage(data['error']) : null),
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
  if (eventType == 'reasoning.delta' ||
      eventType == 'response.reasoning.delta' ||
      eventType == 'response.reasoning_text.delta' ||
      eventType == 'response.reasoning_summary_text.delta') {
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
    case 'response.incomplete':
      return 'incomplete';
    case 'run.cancelled':
      return 'cancelled';
    case 'run.canceled':
      return 'canceled';
    case 'done':
      return 'completed';
    default:
      return null;
  }
}

bool _isTerminal(String status) =>
    status == 'completed' ||
    status == 'failed' ||
    status == 'incomplete' ||
    status == 'cancelled' ||
    status == 'canceled' ||
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

String? _fallbackResponseStatusError(String? status, Map response) {
  switch (status) {
    case null:
    case 'completed':
      return null;
    case 'failed':
      final error = response['error'];
      return _isTruthyError(error)
          ? _errorMessage(error)
          : 'Hermes response failed.';
    case 'incomplete':
      final details = response['incomplete_details'];
      final reason = details is Map ? _str(details['reason']) : null;
      return reason == null || reason.isEmpty
          ? 'The Hermes response was incomplete.'
          : 'The Hermes response was incomplete: $reason.';
    case 'cancelled':
    case 'canceled':
      return 'The Hermes response was cancelled.';
    case 'queued':
    case 'in_progress':
      return 'The Hermes response is not complete.';
    default:
      return 'The Hermes response has an unsupported status.';
  }
}

String? _str(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}
