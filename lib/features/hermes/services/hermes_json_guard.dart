/// Default structural ceilings for JSON received from a Hermes server.
const int kMaxHermesJsonDepth = 128;
const int kMaxHermesJsonNodes = 100000;
const int kMaxHermesJsonTokens = 400000;

enum HermesJsonLimit { depth, nodes, tokens }

/// A structural JSON limit exceeded before the source reached `jsonDecode`.
final class HermesJsonGuardException implements FormatException {
  const HermesJsonGuardException(this.limit);

  final HermesJsonLimit limit;

  @override
  String get message => switch (limit) {
    HermesJsonLimit.depth => 'Hermes JSON exceeds the nesting limit.',
    HermesJsonLimit.nodes => 'Hermes JSON exceeds the value limit.',
    HermesJsonLimit.tokens => 'Hermes JSON exceeds the token limit.',
  };

  @override
  int? get offset => null;

  @override
  Object? get source => null;

  @override
  String toString() => 'FormatException: $message';
}

/// Scans untrusted JSON without constructing its decoded object graph.
///
/// Strings are scanned in place so structural characters inside them do not
/// affect nesting. Allocation-bearing value tokens (including object keys)
/// count toward [maxNodes], while punctuation and values both count toward
/// [maxTokens]. JSON syntax remains the responsibility of `jsonDecode`; this
/// preflight only guarantees that malformed or valid input has finite lexical
/// and structural complexity before decoding begins.
void validateHermesJsonSource(
  String source, {
  int maxDepth = kMaxHermesJsonDepth,
  int maxNodes = kMaxHermesJsonNodes,
  int maxTokens = kMaxHermesJsonTokens,
}) {
  if (maxDepth <= 0) throw RangeError.value(maxDepth, 'maxDepth');
  if (maxNodes <= 0) throw RangeError.value(maxNodes, 'maxNodes');
  if (maxTokens <= 0) throw RangeError.value(maxTokens, 'maxTokens');

  var depth = 0;
  var nodes = 0;
  var tokens = 0;
  var index = 0;

  void addToken({required bool allocationBearing}) {
    tokens++;
    if (tokens > maxTokens) {
      throw const HermesJsonGuardException(HermesJsonLimit.tokens);
    }
    if (!allocationBearing) return;
    nodes++;
    if (nodes > maxNodes) {
      throw const HermesJsonGuardException(HermesJsonLimit.nodes);
    }
  }

  while (index < source.length) {
    final codeUnit = source.codeUnitAt(index);
    if (_isJsonWhitespace(codeUnit)) {
      index++;
      continue;
    }

    if (codeUnit == _quote) {
      addToken(allocationBearing: true);
      index++;
      var escaped = false;
      while (index < source.length) {
        final stringCodeUnit = source.codeUnitAt(index++);
        if (escaped) {
          escaped = false;
        } else if (stringCodeUnit == _backslash) {
          escaped = true;
        } else if (stringCodeUnit == _quote) {
          break;
        }
      }
      continue;
    }

    if (codeUnit == _openBrace || codeUnit == _openBracket) {
      addToken(allocationBearing: true);
      depth++;
      if (depth > maxDepth) {
        throw const HermesJsonGuardException(HermesJsonLimit.depth);
      }
      index++;
      continue;
    }

    if (codeUnit == _closeBrace || codeUnit == _closeBracket) {
      addToken(allocationBearing: false);
      if (depth > 0) depth--;
      index++;
      continue;
    }

    if (codeUnit == _colon || codeUnit == _comma) {
      addToken(allocationBearing: false);
      index++;
      continue;
    }

    // Numbers, true, false, null, and malformed bare lexemes are each one
    // allocation-bearing token. `jsonDecode` validates their exact spelling.
    addToken(allocationBearing: true);
    index++;
    while (index < source.length) {
      final next = source.codeUnitAt(index);
      if (_isJsonWhitespace(next) || _isJsonDelimiter(next)) break;
      index++;
    }
  }
}

bool _isJsonWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

bool _isJsonDelimiter(int codeUnit) =>
    codeUnit == _openBrace ||
    codeUnit == _closeBrace ||
    codeUnit == _openBracket ||
    codeUnit == _closeBracket ||
    codeUnit == _colon ||
    codeUnit == _comma ||
    codeUnit == _quote;

const int _quote = 0x22;
const int _comma = 0x2C;
const int _colon = 0x3A;
const int _openBracket = 0x5B;
const int _backslash = 0x5C;
const int _closeBracket = 0x5D;
const int _openBrace = 0x7B;
const int _closeBrace = 0x7D;
