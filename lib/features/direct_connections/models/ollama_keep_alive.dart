/// Normalizes one Ollama `keep_alive` value for secure profile persistence.
///
/// Ollama accepts either an integer number of seconds or a Go-style duration
/// string such as `5m`, `1h30m`, or `-1m`. A negative value keeps the model
/// loaded indefinitely, while zero unloads it after the request.
String normalizeOllamaKeepAlive(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty || normalized.length > 64) {
    throw const FormatException('Ollama keep-alive value is invalid.');
  }

  final seconds = int.tryParse(normalized);
  if (seconds != null) return seconds.toString();

  final durationPattern = RegExp(
    r'^-?(?:\d+(?:\.\d+)?(?:ns|us|µs|ms|s|m|h))+$',
  );
  if (!durationPattern.hasMatch(normalized)) {
    throw const FormatException('Ollama keep-alive value is invalid.');
  }
  return normalized;
}

/// Converts a persisted value into the native JSON type expected by Ollama.
Object ollamaKeepAliveApiValue(String value) {
  final normalized = normalizeOllamaKeepAlive(value);
  return int.tryParse(normalized) ?? normalized;
}

/// Validates and freezes per-model Ollama keep-alive values.
Map<String, String> normalizeOllamaKeepAliveByModel(
  Map<String, String> values,
) {
  if (values.length > 1000) {
    throw const FormatException('Too many Ollama keep-alive settings.');
  }
  final normalized = <String, String>{};
  for (final entry in values.entries) {
    final modelId = entry.key.trim();
    if (modelId.isEmpty ||
        modelId.length > 512 ||
        modelId.contains('\r') ||
        modelId.contains('\n') ||
        modelId.contains('\u0000')) {
      throw const FormatException('Ollama model id is invalid.');
    }
    normalized[modelId] = normalizeOllamaKeepAlive(entry.value);
  }
  return Map.unmodifiable(normalized);
}
