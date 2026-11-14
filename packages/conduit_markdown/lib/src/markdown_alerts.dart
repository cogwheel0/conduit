import 'message_blocks.dart';

/// The line that opens a GitHub-style alert, as the `markdown` package's
/// `AlertBlockSyntax` (which the mobile app renders with) reads it: a block
/// quote whose first line is only `[!TYPE]`, in any case.
final RegExp _alertOpener = RegExp(
  r'^ {0,3}> {0,3}\\?\[!(note|tip|important|caution|warning)\\?\]\s*$',
  caseSensitive: false,
);

/// A block quote line: up to three spaces, then `>`.
final RegExp _quoteLine = RegExp(r'^ {0,3}>');

/// What a line of a block quote holds once its marker is taken off: `>`
/// and one space, if there is one.
final RegExp _quoteMarker = RegExp(r'^ {0,3}> ?');

/// Lines that start a block of their own, so they end an alert rather
/// than continue its last paragraph lazily.
final RegExp _blockStart = RegExp(
  r'^ {0,3}(?:#{1,6}(?:\s|$)|`{3,}|~{3,}|[-*+]\s|\d{1,9}[.)]\s|'
  r'(?:-\s*){3,}$|(?:\*\s*){3,}$|(?:_\s*){3,}$|\||\$\$)',
);

final RegExp _fenceOpener = RegExp(r'^ {0,3}(`{3,}|~{3,})');

/// [blocks] with every GitHub-style alert at the top level of a text block
/// lifted out into an [AlertMessageBlock] of its own, in place: the text
/// before it, the alert, the text after it.
///
/// For a renderer that does not know the syntax (the desktop app's), so it
/// shows what the mobile app shows. An alert is a block quote whose first
/// line is only `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]` or
/// `[!CAUTION]`; it runs over the quote's lines and the lazy continuation
/// of its last paragraph. Alerts in code fences, display math, lists or
/// other quotes stay text, as does a marker with more on its line. Text
/// that is only whitespace either side of an alert is dropped.
List<MessageBlock> liftMarkdownAlerts(List<MessageBlock> blocks) {
  if (!blocks.any(
    (block) => block is TextMessageBlock && block.markdown.contains('[!'),
  )) {
    return blocks;
  }
  return List<MessageBlock>.unmodifiable([
    for (final block in blocks)
      if (block is TextMessageBlock && block.markdown.contains('[!'))
        ..._liftFromText(block.markdown)
      else
        block,
  ]);
}

List<MessageBlock> _liftFromText(String markdown) {
  final lines = markdown.split('\n');
  final out = <MessageBlock>[];
  final text = StringBuffer();
  var textLines = 0;

  // Text either side of an alert loses the blank lines that set it apart,
  // as the segmenter's text blocks have none at their ends, so a streamed
  // answer cut at an alert reads the same as the whole.
  var afterAlert = false;
  void flushText({bool beforeAlert = false}) {
    if (textLines == 0) return;
    var value = text.toString();
    text.clear();
    textLines = 0;
    if (afterAlert) value = value.replaceFirst(RegExp(r'^(?:[ \t]*\n)+'), '');
    if (beforeAlert) value = value.replaceFirst(RegExp(r'(?:\n[ \t]*)+$'), '');
    afterAlert = false;
    if (value.trim().isNotEmpty) out.add(TextMessageBlock(value));
  }

  void addTextLine(String line, {required bool last}) {
    text.write(line);
    if (!last) text.write('\n');
    textLines++;
  }

  String? fence;
  var math = false;
  // Whether the line before belongs to a block quote, a list or a
  // paragraph that a `>` line would continue rather than start anew.
  var inQuote = false;
  var inList = false;
  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    final last = index == lines.length - 1;
    final trimmed = line.trimLeft();

    if (fence != null) {
      if (trimmed.startsWith(fence) &&
          trimmed.replaceAll(fence[0], '').trim().isEmpty) {
        fence = null;
      }
      addTextLine(line, last: last);
      index++;
      continue;
    }
    if (math) {
      if (trimmed.startsWith(r'$$')) math = false;
      addTextLine(line, last: last);
      index++;
      continue;
    }
    if (_fenceOpener.firstMatch(line) case final opener?) {
      fence = opener.group(1)!.substring(0, 3);
      addTextLine(line, last: last);
      inQuote = false;
      index++;
      continue;
    }
    if (trimmed.startsWith(r'$$') && !trimmed.substring(2).contains(r'$$')) {
      math = true;
      addTextLine(line, last: last);
      index++;
      continue;
    }

    final blank = trimmed.isEmpty;
    // Inside a quote, or indented under a list item, it is part of that.
    final opens =
        !inQuote &&
        !(inList && line.startsWith(' ')) &&
        _alertOpener.firstMatch(line) != null;
    if (opens) {
      final type = _alertOpener.firstMatch(line)!.group(1)!.toLowerCase();
      final body = <String>[];
      var lastContentBlank = true;
      index++;
      while (index < lines.length) {
        final next = lines[index];
        if (_quoteLine.hasMatch(next)) {
          final content = next.replaceFirst(_quoteMarker, '');
          body.add(content);
          lastContentBlank = content.trim().isEmpty;
          index++;
          continue;
        }
        // Lazy continuation of the alert's last paragraph.
        if (next.trim().isNotEmpty &&
            !lastContentBlank &&
            !_blockStart.hasMatch(next)) {
          body.add(next);
          index++;
          continue;
        }
        break;
      }
      flushText(beforeAlert: true);
      out.add(AlertMessageBlock(type: type, markdown: body.join('\n').trim()));
      afterAlert = true;
      inQuote = false;
      inList = false;
      // What follows starts on its own line, as it did.
      continue;
    }

    addTextLine(line, last: last);
    if (blank) {
      inQuote = false;
      // A list goes on over blank lines while its items are indented.
    } else {
      inQuote = _quoteLine.hasMatch(line) || (inQuote && !blank);
      if (RegExp(r'^ {0,3}(?:[-*+]|\d{1,9}[.)])\s').hasMatch(line)) {
        inList = true;
      } else if (!line.startsWith(' ') && !line.startsWith('\t')) {
        inList = false;
      }
    }
    index++;
  }
  flushText();
  return out;
}
