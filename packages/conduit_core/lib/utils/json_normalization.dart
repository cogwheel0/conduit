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
