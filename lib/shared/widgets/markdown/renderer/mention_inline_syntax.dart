import 'package:markdown/markdown.dart' as md;

/// Parses OpenWebUI mention tags as first-class inline nodes.
class MentionInlineSyntax extends md.InlineSyntax {
  MentionInlineSyntax()
    : super(r'<@([A-Z]):([^|>]+)\|([^>]+)>', startCharacter: '<'.codeUnitAt(0));

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final element = md.Element.text('mention', '@${match.group(3) ?? ''}');
    element.attributes['type'] = match.group(1) ?? '';
    element.attributes['id'] = match.group(2) ?? '';
    parser.addNode(element);
    return true;
  }
}
