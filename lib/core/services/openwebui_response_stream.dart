/// Reduces Open WebUI `response:completion` socket events onto the
/// accumulated `output` item list.
///
/// Open WebUI 0.11 streams per-token updates for socket-bound completions as
/// OpenAI Responses-style events (`response.output_text.delta`,
/// `response.reasoning_text.delta`, `response.output_item.added`, ...) instead
/// of cumulative `chat:completion` snapshots. This mirrors the web client's
/// `applyResponseStreamEvent` so the same `output` list the server persists
/// can be rebuilt locally while the response is still streaming.
List<Map<String, dynamic>> applyOpenWebUIResponseStreamEvent(
  List<Map<String, dynamic>> output,
  Map<dynamic, dynamic> event,
) {
  final eventType = event['type']?.toString() ?? '';
  if (!eventType.startsWith('response.')) return output;

  if (eventType == 'response.completed') {
    final response = event['response'];
    final completed = response is Map ? response['output'] : null;
    return completed is List ? _cloneItems(completed) : output;
  }

  final next = _cloneItems(output);
  final itemId = event['item_id']?.toString();
  final eventItemIndex = itemId == null || itemId.isEmpty
      ? -1
      : next.indexWhere(
          (item) =>
              item['id']?.toString() == itemId ||
              item['call_id']?.toString() == itemId,
        );
  final rawOutputIndex = event['output_index'];
  final outputIndex = eventItemIndex >= 0
      ? eventItemIndex
      : rawOutputIndex is int
      ? rawOutputIndex
      : (next.length - 1).clamp(0, 1 << 30);

  if (eventType == 'response.output_item.added' ||
      eventType == 'response.output_item.done') {
    final rawItem = event['item'];
    if (rawItem is! Map) return output;
    final item = _cloneMap(rawItem);
    final existingIndex = _findOutputItemIndex(next, item);
    if (existingIndex >= 0) {
      next[existingIndex] = item;
    } else if (outputIndex < next.length) {
      if (eventType == 'response.output_item.added') {
        next.insert(outputIndex, item);
      } else {
        next[outputIndex] = item;
      }
    } else {
      next.add(item);
    }
    return next;
  }

  if (!_updatesOutputItem(eventType)) return output;

  final item = _ensureOutputItem(next, outputIndex, <String, dynamic>{
    if (itemId != null && itemId.isNotEmpty) 'id': itemId,
    'type': eventType.contains('reasoning')
        ? 'reasoning'
        : eventType.contains('function_call')
        ? 'function_call'
        : 'message',
    'status': 'in_progress',
    'role': 'assistant',
    'content': <Map<String, dynamic>>[],
  });

  if (eventType == 'response.content_part.added') {
    final part = event['part'];
    if (item['type'] == 'reasoning' || part is! Map) return next;
    final parts = _partsOf(item, 'content');
    _setPart(
      parts,
      _intOr(event['content_index'], parts.length),
      _cloneMap(part),
    );
    return next;
  }

  if (eventType == 'response.reasoning_summary_part.added') {
    final part = event['part'];
    if (part is! Map) return next;
    final summary = _partsOf(item, 'summary');
    _setPart(
      summary,
      _intOr(event['summary_index'], summary.length),
      _cloneMap(part),
      fallback: const {'type': 'summary_text', 'text': ''},
    );
    return next;
  }

  final segments = eventType.split('.');
  final typeName = segments.length > 1 ? segments[1] : '';

  if (eventType.endsWith('.delta')) {
    final delta = event['delta'];
    if (typeName == 'function_call_arguments') {
      item['arguments'] = _appendDelta(item['arguments'] ?? '', delta);
      return next;
    }
    if (typeName == 'reasoning_summary_text') {
      final summary = _partsOf(item, 'summary');
      final part = _ensurePart(
        summary,
        _intOr(event['summary_index'], 0),
        fallback: const {'type': 'summary_text', 'text': ''},
      );
      part['text'] = _appendDelta(part['text'] ?? '', delta);
      return next;
    }
    final key = typeName == 'output_text' || typeName == 'reasoning_text'
        ? 'text'
        : typeName;
    final parts = _partsOf(item, 'content');
    final part = _ensurePart(parts, _intOr(event['content_index'], 0));
    part[key] = _appendDelta(part[key], delta);
    return next;
  }

  if (eventType.endsWith('.done')) {
    if (typeName == 'content_part' && event['part'] is Map) {
      final parts = _partsOf(item, 'content');
      _setPart(
        parts,
        _intOr(event['content_index'], (parts.length - 1).clamp(0, 1 << 30)),
        _cloneMap(event['part'] as Map),
      );
    } else if (typeName == 'function_call_arguments' &&
        event.containsKey('arguments')) {
      item['arguments'] = event['arguments'];
    } else if ((typeName == 'output_text' ||
            typeName == 'text' ||
            typeName == 'reasoning_text') &&
        event.containsKey('text')) {
      final parts = _partsOf(item, 'content');
      final part = _ensurePart(parts, _intOr(event['content_index'], 0));
      part['text'] = event['text'];
    }
  }

  return next;
}

/// Whether an event type mutates the accumulated output list at all. Marker
/// events such as `response.created` are ignored.
bool openWebUIResponseStreamEventTouchesOutput(String eventType) =>
    eventType == 'response.completed' ||
    eventType == 'response.output_item.added' ||
    eventType == 'response.output_item.done' ||
    _updatesOutputItem(eventType);

/// Structural transitions worth persisting immediately, as opposed to
/// per-token deltas that only need the visible projection.
bool openWebUIResponseStreamEventIsStructural(String eventType) =>
    eventType == 'response.completed' ||
    eventType == 'response.output_item.added' ||
    eventType == 'response.output_item.done' ||
    eventType.endsWith('.done');

bool _updatesOutputItem(String eventType) =>
    eventType == 'response.content_part.added' ||
    eventType == 'response.reasoning_summary_part.added' ||
    eventType.endsWith('.delta') ||
    eventType.endsWith('.done');

List<Map<String, dynamic>> _cloneItems(List<dynamic> items) => [
  for (final item in items)
    if (item is Map) _cloneMap(item),
];

Map<String, dynamic> _cloneMap(Map<dynamic, dynamic> map) => {
  for (final entry in map.entries) entry.key.toString(): entry.value,
};

int _intOr(Object? value, int fallback) => value is int ? value : fallback;

int _findOutputItemIndex(
  List<Map<String, dynamic>> output,
  Map<String, dynamic> item,
) {
  final id = item['id']?.toString();
  final callId = item['call_id']?.toString();
  return output.indexWhere(
    (existing) =>
        (id != null && id.isNotEmpty && existing['id']?.toString() == id) ||
        (callId != null &&
            callId.isNotEmpty &&
            existing['call_id']?.toString() == callId),
  );
}

Map<String, dynamic> _ensureOutputItem(
  List<Map<String, dynamic>> output,
  int outputIndex,
  Map<String, dynamic> fallback,
) {
  while (output.length <= outputIndex) {
    // Only the addressed slot takes the event's identity; filler slots must
    // not reuse its id.
    output.add(
      output.length == outputIndex
          ? Map<String, dynamic>.of(fallback)
          : <String, dynamic>{
              'type': 'message',
              'status': 'in_progress',
              'role': 'assistant',
              'content': <Map<String, dynamic>>[],
            },
    );
  }
  final item = Map<String, dynamic>.of(output[outputIndex]);
  output[outputIndex] = item;
  return item;
}

List<Map<String, dynamic>> _partsOf(Map<String, dynamic> item, String key) {
  final raw = item[key];
  final parts = raw is List ? _cloneItems(raw) : <Map<String, dynamic>>[];
  item[key] = parts;
  return parts;
}

Map<String, dynamic> _ensurePart(
  List<Map<String, dynamic>> parts,
  int index, {
  Map<String, dynamic> fallback = const {'type': 'output_text', 'text': ''},
}) {
  while (parts.length <= index) {
    parts.add(Map<String, dynamic>.of(fallback));
  }
  final part = Map<String, dynamic>.of(parts[index]);
  parts[index] = part;
  return part;
}

void _setPart(
  List<Map<String, dynamic>> parts,
  int index,
  Map<String, dynamic> part, {
  Map<String, dynamic> fallback = const {'type': 'output_text', 'text': ''},
}) {
  _ensurePart(parts, index, fallback: fallback);
  parts[index] = part;
}

Object _appendDelta(Object? current, Object? delta) {
  if (current is String || delta is String) {
    return '${current ?? ''}${delta ?? ''}';
  }
  if (current is Map && delta is Map) {
    return <String, dynamic>{..._cloneMap(current), ..._cloneMap(delta)};
  }
  return delta ?? current ?? '';
}
