import 'package:markdown/markdown.dart' as md;

/// `[1]`, `[1,2]` and `[1][2]` as citations of an answer's sources (WP-3.2).
///
/// The same shapes Open WebUI's `citation-extension.ts` recognises, and the
/// same ones `CitationParser` in `conduit_markdown` does for mobile. Only
/// installed when the message has sources: without them a bracketed number
/// is just text the model wrote.
///
/// Not followed by `(`, so a markdown link whose text is a number stays a
/// link.
class CitationSyntax extends md.InlineSyntax {
  CitationSyntax()
    : super(r'(?:\[\d+(?:#[^,\]\s]+)?(?:,\s*\d+(?:#[^,\]\s]+)?)*\])+(?!\()');

  static final RegExp _number = RegExp(r'\d+');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final raw = match[0]!;
    // `#fragment` suffixes point inside a source; the source is what the
    // chip links to, so they are dropped here.
    final ids = <int>[
      for (final group in raw.substring(1, raw.length - 1).split(']['))
        for (final part in group.split(','))
          if (_number.firstMatch(part) case final number?)
            int.parse(number[0]!),
    ];
    parser.addNode(
      md.Element('cite', <md.Node>[md.Text(raw)])
        ..attributes['ids'] = ids.toSet().join(','),
    );
    return true;
  }
}
