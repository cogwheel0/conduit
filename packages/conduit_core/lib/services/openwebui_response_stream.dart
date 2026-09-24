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

  if (_isTerminalResponseEvent(eventType)) {
    // completed, failed, and incomplete all carry the final output list; the
    // consumer reports failure, the output still replaces the local list.
    final response = event['response'];
    final completed = response is Map ? response['output'] : null;
    // An empty terminal list is not authoritative: a failure or cut-off can
    // report no output even though items already streamed, and dropping
    // them would blank a partial answer the user has already seen.
    if (completed is! List || completed.isEmpty) return output;
    return mergeOpenWebUIReasoningTiming(output, _cloneItems(completed));
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
      next[existingIndex] = _withPreservedTiming(next[existingIndex], item);
    } else if (outputIndex < next.length) {
      if (eventType == 'response.output_item.added') {
        next.insert(outputIndex, item);
      } else {
        next[outputIndex] = _withPreservedTiming(next[outputIndex], item);
      }
    } else {
      next.add(item);
    }
    _stampReasoningTiming(next);
    return next;
  }

  if (!_updatesOutputItem(eventType)) return output;

  final itemCountBefore = next.length;
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
  if (next.length != itemCountBefore) {
    _stampReasoningTiming(next);
  }

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
    _isTerminalResponseEvent(eventType) ||
    eventType == 'response.output_item.added' ||
    eventType == 'response.output_item.done' ||
    _updatesOutputItem(eventType);

/// Structural transitions worth persisting immediately, as opposed to
/// per-token deltas that only need the visible projection.
bool openWebUIResponseStreamEventIsStructural(String eventType) =>
    _isTerminalResponseEvent(eventType) ||
    eventType == 'response.output_item.added' ||
    eventType == 'response.output_item.done' ||
    eventType.endsWith('.done');

bool _isTerminalResponseEvent(String eventType) =>
    eventType == 'response.completed' ||
    eventType == 'response.failed' ||
    eventType == 'response.incomplete';

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

/// The server records `started_at` when a reasoning item is created and
/// `duration` once the next item starts, but per-token streams never send
/// that transition. Stamp the same timing locally so the visible block can
/// read "Thought for N seconds" instead of waiting for the terminal snapshot.
void _stampReasoningTiming(List<Map<String, dynamic>> output) {
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  for (var index = 0; index < output.length; index++) {
    final item = output[index];
    if (item['type'] != 'reasoning') continue;
    final startedAt = item['started_at'];
    if (startedAt is! num) {
      item['started_at'] = now;
    }
    final isLast = index == output.length - 1;
    if (isLast || item['duration'] != null) continue;
    final start = item['started_at'];
    final elapsed = start is num ? (now - start).floor() : 0;
    item['ended_at'] = now;
    item['duration'] = elapsed < 0 ? 0 : elapsed;
  }
}

/// Carries locally stamped reasoning timing onto an authoritative snapshot.
///
/// Responses-API providers never report how long a model thought, and the
/// server only records `ended_at` for such items, so a cumulative `output`
/// snapshot would otherwise erase the duration the client measured while the
/// stream was live. Items are matched by id, falling back to position.
List<Map<String, dynamic>> mergeOpenWebUIReasoningTiming(
  List<Map<String, dynamic>> previous,
  List<Map<String, dynamic>> next,
) {
  if (previous.isEmpty || next.isEmpty) return next;
  var changed = false;
  final merged = <Map<String, dynamic>>[];
  for (var index = 0; index < next.length; index++) {
    final item = next[index];
    if (item['type'] != 'reasoning' || item['duration'] != null) {
      merged.add(item);
      continue;
    }
    final id = item['id']?.toString();
    Map<String, dynamic>? source;
    if (id != null && id.isNotEmpty) {
      for (final candidate in previous) {
        if (candidate['type'] == 'reasoning' &&
            candidate['id']?.toString() == id) {
          source = candidate;
          break;
        }
      }
    }
    if (source == null &&
        index < previous.length &&
        previous[index]['type'] == 'reasoning') {
      source = previous[index];
    }
    if (source == null) {
      merged.add(item);
      continue;
    }
    final copy = Map<String, dynamic>.of(item);
    for (final key in const ['started_at', 'ended_at', 'duration']) {
      if (copy[key] == null && source[key] != null) {
        copy[key] = source[key];
        changed = true;
      }
    }
    if (copy['duration'] == null) {
      final start = copy['started_at'];
      final end = copy['ended_at'];
      if (start is num && end is num) {
        final elapsed = (end - start).floor();
        copy['duration'] = elapsed < 0 ? 0 : elapsed;
        changed = true;
      }
    }
    merged.add(copy);
  }
  return changed ? merged : next;
}

/// The server's copy of an item (from `output_item.done` or a snapshot)
/// never carries the client's timing, so keep whatever was measured locally.
Map<String, dynamic> _withPreservedTiming(
  Map<String, dynamic> previous,
  Map<String, dynamic> replacement,
) {
  if (previous['type'] != 'reasoning' || replacement['type'] != 'reasoning') {
    return replacement;
  }
  for (final key in const ['started_at', 'ended_at', 'duration']) {
    if (replacement[key] == null && previous[key] != null) {
      replacement[key] = previous[key];
    }
  }
  return replacement;
}
