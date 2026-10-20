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
  if (seconds != null) {
    if (BigInt.from(seconds).abs() > _maxGoDurationNanoseconds ~/ _billion) {
      throw const FormatException('Ollama keep-alive value is out of range.');
    }
    return seconds.toString();
  }

  final durationPattern = RegExp(
    r'^-?(?:\d+(?:\.\d+)?(?:ns|us|µs|ms|s|m|h))+$',
  );
  if (!durationPattern.hasMatch(normalized)) {
    throw const FormatException('Ollama keep-alive value is invalid.');
  }
  _validateGoDurationRange(normalized);
  return normalized;
}

final BigInt _maxGoDurationNanoseconds = BigInt.parse('9223372036854775807');
final BigInt _billion = BigInt.from(1000000000);
final Map<String, BigInt> _goDurationUnitNanoseconds = <String, BigInt>{
  'ns': BigInt.one,
  'us': BigInt.from(1000),
  'µs': BigInt.from(1000),
  'ms': BigInt.from(1000000),
  's': _billion,
  'm': BigInt.from(60) * _billion,
  'h': BigInt.from(3600) * _billion,
};
final RegExp _goDurationSegment = RegExp(r'(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)');

void _validateGoDurationRange(String value) {
  var totalNanoseconds = BigInt.zero;
  final unsigned = value.startsWith('-') ? value.substring(1) : value;
  for (final match in _goDurationSegment.allMatches(unsigned)) {
    final number = match.group(1)!;
    final unitScale = _goDurationUnitNanoseconds[match.group(2)!]!;
    final dot = number.indexOf('.');
    final digits = dot < 0 ? number : number.replaceFirst('.', '');
    final fractionalDigits = dot < 0 ? 0 : number.length - dot - 1;
    final denominator = BigInt.from(10).pow(fractionalDigits);
    totalNanoseconds += (BigInt.parse(digits) * unitScale) ~/ denominator;
    if (totalNanoseconds > _maxGoDurationNanoseconds) {
      throw const FormatException('Ollama keep-alive value is out of range.');
    }
  }
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
