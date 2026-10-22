/// Content-based fence policy, adapted from Hermes Desktop's markdown-code.ts.
/// See THIRD_PARTY_NOTICES.md for the upstream MIT notice.
class MarkdownCodePolicy {
  const MarkdownCodePolicy._();

  static final _language = RegExp(
    r'^[a-z0-9][a-z0-9+#-]{0,15}$',
    caseSensitive: false,
  );
  static final _codeSignals = [
    RegExp(
      r'(^|\s)(const|let|var|function|class|import|export|return|if|for|while|switch)\b',
      multiLine: true,
      caseSensitive: false,
    ),
    RegExp(r'=>|==|!=|\{|\}|;|<\/?[a-z][^>]*>', caseSensitive: false),
    RegExp(
      r'^\s*(#include|SELECT|INSERT|UPDATE|DELETE|CREATE|DROP)\b',
      multiLine: true,
      caseSensitive: false,
    ),
  ];
  static final _configSeparator = RegExp(r'^[A-Za-z0-9_][\w.-]*\s*[:=]\s*\S');
  static final _identifier = RegExp(r'^[A-Za-z0-9_][\w.-]*$');
  static final _sentence = RegExp(r'[.!?](?:\s|$)');
  static final _bullet = RegExp(r'^\s*[-*]\s+\S+', multiLine: true);
  static final _inlineMarkup = RegExp(r'\*\*[^*]+\*\*|`[^`\n]+`');
  static const _proseLanguages = {
    '',
    'text',
    'plain',
    'plaintext',
    'md',
    'markdown',
  };

  static String sanitizeLanguage(String info) {
    final token = info.trim().split(RegExp(r'\s+')).first.toLowerCase();
    return _language.hasMatch(token) ? token : '';
  }

  static bool isStructuredText(String body) {
    final lines = body
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) return false;
    if (lines.any((line) => RegExp(r'^\s+\S').hasMatch(line))) return true;
    if (lines.any((line) => _sentence.hasMatch(line.trim()))) return false;
    final configLines = lines.where((line) {
      final text = line.trim();
      if (_configSeparator.hasMatch(text)) return true;
      final tokens = text.split(RegExp(r'\s+'));
      return tokens.length >= 2 &&
          tokens.length <= 3 &&
          _identifier.hasMatch(tokens.first);
    }).length;
    return configLines >= 2 && configLines >= (lines.length * .6).ceil();
  }

  static bool isProseFence(String info, String body) {
    if (body.trim().isEmpty) return false;
    final tag = info.trim();
    if (RegExp(r'^[-*+]\s|^https?://', caseSensitive: false).hasMatch(tag)) {
      return true;
    }
    final signals = _codeSignals.fold<int>(
      0,
      (sum, pattern) => sum + pattern.allMatches(body).length,
    );
    // Count letters in all languages, rather than only Hermes's ASCII prose.
    final proseLines = body.split('\n').where((line) {
      final text = line.trim();
      return text.isNotEmpty && !RegExp(r'^[{}\[\]<>]').hasMatch(text);
    }).length;
    final bulletLines = _bullet.allMatches(body).length;
    final hasInfoTail = tag.isNotEmpty && tag.split(RegExp(r'\s+')).length > 1;
    if (hasInfoTail &&
        signals <= 2 &&
        (proseLines >= 2 ||
            bulletLines > 0 ||
            RegExp(r'^\s*https?://\S+\s*$', multiLine: true).hasMatch(body))) {
      return true;
    }
    if (!_proseLanguages.contains(sanitizeLanguage(tag)) ||
        isStructuredText(body)) {
      return false;
    }
    return (bulletLines >= 2 && _inlineMarkup.hasMatch(body) && signals <= 2) ||
        (proseLines >= 3 && signals == 0);
  }
}

final _fenceLine = RegExp(r'^[ \t]*(`{3,}|~{3,})([^\n]*)$');
final _listFence = RegExp(r'^(\s*(?:[*+-]|\d+\.)\s+)(`{3,}|~{3,})([^\n]*)$');

/// Repairs only fence boundaries. Literal fence examples and indentation in a
/// code body are preserved. Synthesized closing fences are display-only.
String normalizeContextAwareFences(String input) {
  final lines = input.split('\n');
  final output = <String>[];
  var index = 0;
  while (index < lines.length) {
    var line = lines[index];
    final list = _listFence.firstMatch(line);
    if (list != null) {
      output.add(list[1]!);
      line = '${list[2]}${list[3]}';
    }
    final opener = _fenceLine.firstMatch(line);
    if (opener == null) {
      output.add(line);
      index++;
      continue;
    }
    final marker = opener[1]!;
    final info = opener[2]!.trim();
    // Backticks in an info string cannot start a CommonMark backtick fence.
    if (marker.startsWith('`') && info.contains('`')) {
      output.add(line);
      index++;
      continue;
    }
    final body = <String>[];
    String? close;
    index++;
    while (index < lines.length) {
      final candidate = _fenceLine.firstMatch(lines[index]);
      if (candidate != null &&
          candidate[1]![0] == marker[0] &&
          candidate[1]!.length >= marker.length &&
          candidate[2]!.trim().isEmpty) {
        close = candidate[1];
        index++;
        break;
      }
      // Legacy LLM repair: a closing triple fence attached to the final line.
      // Do not apply it to longer fences or a quoted literal in source code.
      if (marker == '```' &&
          lines[index].endsWith('```') &&
          !lines[index].contains('"') &&
          !lines[index].contains("'")) {
        body.add(lines[index].substring(0, lines[index].length - 3));
        close = marker;
        index++;
        break;
      }
      body.add(lines[index]);
      index++;
    }
    if (body.join('\n').trim().isEmpty) continue;
    if (MarkdownCodePolicy.isProseFence(info, body.join('\n'))) {
      // A language tag describes presentation, and is not answer content.
      if (info.contains(' ') || RegExp(r'^[-*+]\s|^https?://').hasMatch(info)) {
        output.add(info);
      }
      output.addAll(body);
      output.add('');
    } else {
      output.add('$marker$info');
      output.addAll(body);
      output.add(close ?? marker);
    }
  }
  return output.join('\n');
}

/// Conservative tail repair for live Markdown. Completed messages retain their
/// authored markup. Never repair source code or identifier underscores.
String repairStreamingInlineTail(String input) {
  final boundary = input.lastIndexOf('\n\n');
  final start = boundary < 0 ? 0 : boundary + 2;
  final tail = input.substring(start);
  if (tail.length > 4096 ||
      _fenceLine.allMatches(tail).isNotEmpty ||
      input.trimRight().endsWith('```') ||
      input.trimRight().endsWith('~~~')) {
    return input;
  }
  final stack = <String>[];
  var inCode = false;
  for (var index = 0; index < tail.length; index++) {
    if (tail[index] == '\\') {
      index++;
      continue;
    }
    if (tail[index] == '`') {
      if (inCode) {
        stack.removeLast();
      } else {
        stack.add('`');
      }
      inCode = !inCode;
      continue;
    }
    if (inCode) continue;
    final marker = tail.startsWith('**', index)
        ? '**'
        : tail.startsWith('~~', index)
        ? '~~'
        : null;
    if (marker == null) continue;
    if (stack.isNotEmpty && stack.last == marker) {
      stack.removeLast();
    } else if (index + 2 < tail.length &&
        !RegExp(r'\s').hasMatch(tail[index + 2])) {
      stack.add(marker);
    }
    index++;
  }
  return stack.isEmpty ? input : '$input${stack.reversed.join()}';
}
