import 'package:conduit/shared/widgets/markdown/renderer/details_block_syntax.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

void main() {
  md.Element parseDetails(String content) {
    final document = md.Document(blockSyntaxes: const [DetailsBlockSyntax()]);
    final nodes = document.parse(content);

    expect(nodes, hasLength(1));
    expect(nodes.single, isA<md.Element>());

    return nodes.single as md.Element;
  }

  Iterable<md.Element> bodyElements(md.Element details) {
    return (details.children ?? const <md.Node>[])
        .whereType<md.Element>()
        .where((child) => child.tag != 'summary');
  }

  bool containsTag(md.Node node, String tag) {
    if (node is md.Element) {
      if (node.tag == tag) {
        return true;
      }
      return (node.children ?? const <md.Node>[]).any(
        (child) => containsTag(child, tag),
      );
    }
    return false;
  }

  String flattenText(md.Node node) {
    if (node is md.Text) {
      return node.text;
    }
    if (node is md.Element) {
      final buffer = StringBuffer();
      for (final child in node.children ?? const <md.Node>[]) {
        if (child is md.Element && child.tag == 'br') {
          buffer.write('\n');
          continue;
        }
        buffer.write(flattenText(child));
      }
      return buffer.toString();
    }
    return '';
  }

  test('reasoning bodies keep paragraph-separated line normalization', () {
    final details = parseDetails('''
<details type="reasoning">
<summary>Thinking…</summary>
First step
Second step
</details>
''');

    final body = bodyElements(details).toList(growable: false);

    expect(body, hasLength(2));
    expect(flattenText(body[0]), 'First step');
    expect(flattenText(body[1]), 'Second step');
  });

  test('code_interpreter bodies preserve line boundaries with hard breaks', () {
    final details = parseDetails('''
<details type="code_interpreter">
<summary>Analyzing…</summary>
stdout: line 1
stdout: line 2
</details>
''');

    final body = bodyElements(details).toList(growable: false);

    expect(body, hasLength(1));
    expect(containsTag(body.single, 'br'), isTrue);
    expect(flattenText(body.single), 'stdout: line 1\nstdout: line 2');
  });
}
