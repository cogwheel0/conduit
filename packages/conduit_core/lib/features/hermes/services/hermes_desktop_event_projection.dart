part of 'hermes_desktop_api_service.dart';

List<String> _desktopDecisionChoices(Object? value) {
  if (value is! Iterable) return const <String>[];
  return [
    for (final item in value.take(8))
      ?validateHermesBoundedString(item, maxCharacters: 80),
  ];
}

/// Drops the text a re-sent `message.delta` repeats. Hermes 0.23 numbers
/// each reply segment's text by `turn_id`, `segment` and `offset` (UTF-16
/// code units, as Dart counts them), and sends a segment again on a replay,
/// a superseded attempt or a second socket.
final class HermesDeltaSegments {
  final Map<String, int> _received = {};

  /// The part of [text] not received yet: all of it for a delta without
  /// positions, null when it repeats text already received.
  String? unseen({
    required Object? turnId,
    required Object? segment,
    required Object? offset,
    required String text,
  }) {
    if (turnId == null || segment is! int || offset is! int || offset < 0) {
      return text;
    }
    final key = '$turnId\u0000$segment';
    final received = _received[key] ?? 0;
    final end = offset + text.length;
    if (end <= received) return null;
    if (!_received.containsKey(key) && _received.length >= 256) {
      _received.remove(_received.keys.first);
    }
    _received[key] = end;
    return offset >= received ? text : text.substring(received - offset);
  }
}

/// Why a finished tool failed, or null when it succeeded.
///
/// `tool.complete` has no `error` field: a failure sits in its `result` (a
/// decoded object, or text). This follows the checks Hermes itself uses to
/// mark a failed call: a refusal's `user_summary`, a terminal's non-zero
/// `exit_code`, an `error` key or `success: false`, a failed `status`, or a
/// batch whose every item failed.
String? _desktopToolFailure(String toolName, Object? result) {
  String text(Object? value) => value?.toString().trim() ?? '';
  var data = result;
  if (result is String) {
    try {
      data = jsonDecode(result.trim());
    } on FormatException {
      data = null;
    }
  }
  if (data is! Map) {
    if (result is! String) return null;
    // Last resort for plain text, as Hermes does: a non-empty "error" or
    // "failed" near the start, or a body that starts with "Error".
    final head = result.length > 600 ? result.substring(0, 600) : result;
    final marker = _desktopFailureMarker.firstMatch(head);
    if ((marker != null && marker.start < 500) || result.startsWith('Error')) {
      final line = result.trim().split('\n').first;
      return line.length > 200 ? '${line.substring(0, 200)}…' : line;
    }
    return null;
  }
  // The harness refused a repeated call: nothing failed.
  if (data['guardrail_refusal'] == true) return null;
  if (_desktopFileWriteLanded(toolName, data)) return null;
  final summary = text(data['user_summary']);
  if (summary.isNotEmpty) return summary;
  if (toolName == 'terminal') {
    final exitCode = data['exit_code'];
    if (exitCode == null || exitCode == 0) return null;
    final error = text(data['error']);
    return error.isNotEmpty ? error : 'exit $exitCode';
  }
  // Hermes reads `error or message` with Python truthiness, so a `false` or
  // `0` error falls through to the message instead of naming a failure.
  final reason = _truthy(data['error']) ? data['error'] : data['message'];
  final error = _truthy(reason) ? text(reason) : '';
  if (error.isNotEmpty &&
      (data['success'] == false || data.containsKey('error'))) {
    return error;
  }
  final status = text(data['status']).toLowerCase();
  if (status == 'failed' || status == 'error') return status;
  final items = data['results'];
  if (items is List &&
      items.isNotEmpty &&
      items.every((item) => item is Map && _truthy(item['error']))) {
    final first = (items.first as Map)['error'];
    return first is Map ? text(first['message'] ?? first) : text(first);
  }
  return null;
}

/// A quoted "error" or "failed" key whose value is not empty.
final RegExp _desktopFailureMarker = RegExp(
  r'"(?:error|failed)"'
  r'(?!\s*:\s*(?:null|false|0|""|\[\]|\{\})\s*(?:[,}\]]|$))',
  caseSensitive: false,
);

bool _truthy(Object? value) =>
    value != null &&
    value != false &&
    value != 0 &&
    !(value is String && value.isEmpty) &&
    !(value is Iterable && value.isEmpty) &&
    !(value is Map && value.isEmpty);

/// Whether a file write's result proves it landed, so text it reports is
/// not a failure.
bool _desktopFileWriteLanded(String toolName, Map data) {
  if (_truthy(data['error'])) return false;
  return switch (toolName) {
    'write_file' => data.containsKey('bytes_written'),
    'patch' => data['success'] == true,
    _ => false,
  };
}

/// Subagent states Hermes reports for a child that did not finish its task.
/// `interrupted` is a stop, not a failure.
const Set<String> _failedSubagentStatuses = {'failed', 'error', 'timeout'};

bool _projectHermesTurnEvent(
  HermesDesktopEvent event, {
  required void Function(HermesRunEvent) add,
  required String Function(String key) value,
  required String Function(Iterable<String> keys) firstValue,
}) {
  switch (event.type) {
    case 'message.delta':
      final delta = value('delta').isNotEmpty ? value('delta') : value('text');
      if (delta.isNotEmpty) add(HermesTokenDelta(delta));
    case 'message.interim':
      if (event.payload['already_streamed'] != true) {
        final text = value('text');
        if (text.isNotEmpty) add(HermesTokenDelta(text));
      }
    case 'thinking.delta':
      break;
    case 'reasoning.delta':
      final delta = value('delta').isNotEmpty ? value('delta') : value('text');
      if (delta.isNotEmpty) add(HermesReasoningDelta(delta));
    case 'tool.start':
    case 'tool.generating':
      add(
        HermesToolProgress(
          toolName: value('name').isEmpty ? 'tool' : value('name'),
          detail: value('detail'),
          arguments: firstValue(const ['args_text', 'args', 'arguments']),
          done: false,
        ),
      );
    case 'tool.progress':
      add(
        HermesToolProgress(
          toolName: value('name').isEmpty ? 'tool' : value('name'),
          detail: value('detail').isEmpty ? value('message') : value('detail'),
          done: false,
        ),
      );
    case 'tool.complete':
      final toolName = value('name').isEmpty ? 'tool' : value('name');
      // Older gateways may still name the failure in `error`.
      final failure = value('error').isNotEmpty
          ? value('error')
          : _desktopToolFailure(toolName, event.payload['result']);
      add(
        HermesToolProgress(
          toolName: toolName,
          detail: failure ?? '',
          result: firstValue(const ['result_text', 'result']),
          inlineDiff: value('inline_diff'),
          done: true,
          failed: failure != null,
        ),
      );
    case 'subagent.spawn_requested':
    case 'subagent.start':
    case 'subagent.thinking':
    case 'subagent.tool':
    case 'subagent.progress':
    case 'subagent.complete':
      final done = event.type == 'subagent.complete';
      final name = firstValue(const ['name', 'subagent_id']);
      add(
        HermesToolProgress(
          toolName: name.isEmpty ? 'subagent' : 'subagent: $name',
          detail: firstValue(const [
            'message',
            'preview',
            'summary',
            'text',
            'goal',
            'tool_preview',
            'tool_name',
            'result',
            'error',
          ]),
          result: done ? firstValue(const ['result', 'summary', 'text']) : null,
          subagent: true,
          done: done,
          failed:
              done &&
              (value('error').isNotEmpty ||
                  _failedSubagentStatuses.contains(
                    value('status').toLowerCase(),
                  )),
        ),
      );
    case 'review.summary':
      add(
        HermesToolProgress(
          toolName: 'review',
          detail: value('text').isEmpty ? value('summary') : value('text'),
          done: true,
          failed: false,
        ),
      );
    default:
      return false;
  }
  return true;
}
