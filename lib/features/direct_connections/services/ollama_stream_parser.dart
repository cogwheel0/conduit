import 'dart:convert';

/// Strictly frames Ollama's newline-delimited JSON response format before each
/// object is decoded by ollama_dart's typed event models.
///
/// The package's permissive stream helper intentionally skips malformed lines;
/// Conduit retains this small boundary shim so corrupted/truncated provider
/// output cannot silently become a successful completion. It also handles
/// arbitrary byte/UTF-8 boundaries and a final line without `\n`.
const int kMaxOllamaNdjsonLineCharacters = 4 * 1024 * 1024;

Stream<Map<String, dynamic>> parseOllamaNdjson(
  Stream<List<int>> chunks, {
  int maxLineCharacters = kMaxOllamaNdjsonLineCharacters,
}) async* {
  if (maxLineCharacters <= 0) {
    throw RangeError.value(maxLineCharacters, 'maxLineCharacters');
  }
  var pending = '';
  await for (final decoded in chunks.transform(utf8.decoder)) {
    pending += decoded;
    while (true) {
      final newline = pending.indexOf('\n');
      if (newline < 0) break;
      var line = pending.substring(0, newline);
      pending = pending.substring(newline + 1);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      final parsed = _decodeOllamaLine(line, maxLineCharacters);
      if (parsed != null) yield parsed;
    }
    if (pending.length > maxLineCharacters) {
      throw const FormatException('Ollama stream line is too large.');
    }
  }
  final parsed = _decodeOllamaLine(pending, maxLineCharacters);
  if (parsed != null) yield parsed;
}

Map<String, dynamic>? _decodeOllamaLine(String line, int maxLineCharacters) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > maxLineCharacters) {
    throw const FormatException('Ollama stream line is too large.');
  }
  final decoded = jsonDecode(trimmed);
  if (decoded is! Map) {
    throw const FormatException('Ollama stream line must be a JSON object.');
  }
  return decoded.cast<String, dynamic>();
}
