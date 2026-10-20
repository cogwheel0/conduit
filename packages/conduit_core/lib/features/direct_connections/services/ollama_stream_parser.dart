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
  var pending = StringBuffer();
  var pendingCharacters = 0;
  var pendingCarriageReturn = false;

  void append(String value) {
    pendingCharacters += value.length;
    if (pendingCharacters > maxLineCharacters) {
      throw const FormatException('Ollama stream line is too large.');
    }
    pending.write(value);
  }

  await for (final decoded in chunks.transform(utf8.decoder)) {
    var start = 0;
    while (start < decoded.length) {
      final newline = decoded.indexOf('\n', start);
      var end = newline < 0 ? decoded.length : newline;

      // Defer exactly one trailing CR until the next character establishes
      // whether it is CRLF framing or bounded line content.
      if (pendingCarriageReturn) {
        if (newline == start) {
          pendingCarriageReturn = false;
        } else {
          append('\r');
          pendingCarriageReturn = false;
        }
      }
      if (end > start && decoded.codeUnitAt(end - 1) == 0x0D) {
        end--;
        pendingCarriageReturn = true;
      }
      if (end > start) append(decoded.substring(start, end));
      if (newline < 0) break;

      // A deferred CR immediately before LF is delimiter overhead.
      pendingCarriageReturn = false;
      final line = pending.toString();
      pending = StringBuffer();
      pendingCharacters = 0;
      final parsed = _decodeOllamaLine(line, maxLineCharacters);
      if (parsed != null) yield parsed;
      start = newline + 1;
    }
  }
  if (pendingCarriageReturn) append('\r');
  final parsed = _decodeOllamaLine(pending.toString(), maxLineCharacters);
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
