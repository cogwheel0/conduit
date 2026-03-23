import 'package:html_unescape/html_unescape.dart';
import 'package:markdown/markdown.dart' as md;

final _detailsHtmlUnescape = HtmlUnescape();

/// Parses Open WebUI-style `<details>` blocks as first-class markdown nodes.
///
/// This mirrors the upstream frontend's custom marked extension closely:
/// complete `<details>` blocks are lifted into a dedicated block node so the
/// renderer can treat tool calls and reasoning sections semantically instead of
/// as opaque HTML.
class DetailsBlockSyntax extends md.BlockSyntax {
  const DetailsBlockSyntax();

  static final RegExp _blockStartPattern = RegExp(
    r'^\s{0,3}<details(?:\s+[^>]*)?>',
    caseSensitive: false,
  );
  static final RegExp _openingTagPattern = RegExp(
    r'<details(?:\s+[^>]*)?>',
    caseSensitive: false,
  );
  static final RegExp _closingTagPattern = RegExp(
    r'</details>',
    caseSensitive: false,
  );
  static final RegExp _attributePattern = RegExp(r'(\w+)="(.*?)"');
  static final RegExp _summaryPattern = RegExp(
    r'^\s*<summary>(.*?)</summary>\s*',
    caseSensitive: false,
    dotAll: true,
  );

  @override
  RegExp get pattern => _blockStartPattern;

  @override
  bool canParse(md.BlockParser parser) =>
      pattern.hasMatch(parser.current.content);

  @override
  md.Node parse(md.BlockParser parser) {
    final lines = <String>[];
    var depth = 0;
    var sawOpeningTag = false;

    while (!parser.isDone) {
      final line = parser.current.content;
      final openingCount = _openingTagPattern.allMatches(line).length;
      final closingCount = _closingTagPattern.allMatches(line).length;

      if (!sawOpeningTag && openingCount == 0) {
        break;
      }

      sawOpeningTag = sawOpeningTag || openingCount > 0;
      lines.add(line);
      depth += openingCount - closingCount;
      parser.advance();

      if (sawOpeningTag && depth <= 0) {
        break;
      }
    }

    final rawBlock = lines.join('\n');
    final openingMatch = _openingTagPattern.firstMatch(rawBlock);
    final closingIndex = rawBlock.toLowerCase().lastIndexOf('</details>');

    if (openingMatch == null || closingIndex == -1) {
      return md.Element('p', [md.Text(rawBlock)]);
    }

    final openingTag = openingMatch.group(0)!;
    final attributes = <String, String>{};
    for (final match in _attributePattern.allMatches(openingTag)) {
      attributes[match.group(1)!] = match.group(2) ?? '';
    }

    var innerContent = rawBlock.substring(openingMatch.end, closingIndex);
    String? summaryText;
    final summaryMatch = _summaryPattern.firstMatch(innerContent);
    if (summaryMatch != null) {
      summaryText = _decode(summaryMatch.group(1) ?? '').trim();
      innerContent = innerContent.substring(summaryMatch.end);
    }

    final decodedContent = _decode(innerContent).trim();
    final childNodes = decodedContent.isEmpty
        ? const <md.Node>[]
        : md.BlockParser(
            decodedContent.split('\n').map(md.Line.new).toList(growable: false),
            parser.document,
          ).parseLines();

    final element = md.Element('details', [
      if (summaryText != null && summaryText.isNotEmpty)
        md.Element('summary', [md.Text(summaryText)]),
      ...childNodes,
    ]);
    element.attributes.addAll(attributes);
    return element;
  }

  static String _decode(String input) => _detailsHtmlUnescape.convert(input);
}
