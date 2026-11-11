/// Utilities for deep-cloning JSON-like structures without a JSON round trip.
library;

Object? normalizeJsonLikeValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Map) {
    return normalizeJsonLikeMap(value);
  }
  if (value is Iterable) {
    return value.map(normalizeJsonLikeValue).toList(growable: false);
  }
  return value;
}

Map<String, dynamic> normalizeJsonLikeMap(Map<dynamic, dynamic> value) {
  final normalized = <String, dynamic>{};
  value.forEach((key, entryValue) {
    normalized[key?.toString() ?? ''] = normalizeJsonLikeValue(entryValue);
  });
  return normalized;
}

/// A deep copy of [value] without null-valued map entries.
///
/// OpenAI-compatible servers often send optional fields as explicit nulls
/// (`"audio": null`, `"tool_usage": null`). `openai_dart` reads any present
/// optional key as a value of its type and rejects null, while an absent key
/// means "not set", which is what those servers mean. List elements are kept,
/// so indices do not move.
Map<String, dynamic> withoutNullJsonEntries(Map<dynamic, dynamic> value) {
  final stripped = <String, dynamic>{};
  value.forEach((key, entryValue) {
    if (entryValue == null) return;
    stripped[key?.toString() ?? ''] = _withoutNullJsonEntriesIn(entryValue);
  });
  return stripped;
}

Object? _withoutNullJsonEntriesIn(Object? value) => switch (value) {
  Map() => withoutNullJsonEntries(value),
  List() => [for (final item in value) _withoutNullJsonEntriesIn(item)],
  _ => value,
};
