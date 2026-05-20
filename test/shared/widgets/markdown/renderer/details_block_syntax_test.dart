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

  String flattenText(md.Node node) {
    if (node is md.Text) {
      return node.text;
    }
    if (node is! md.Element) {
      return '';
    }
    final buffer = StringBuffer();
    for (final child in node.children ?? const <md.Node>[]) {
      buffer.write(flattenText(child));
    }
    return buffer.toString();
  }

  test('reasoning bodies keep paragraph-separated line normalization', () {
    final details = parseDetails('''
<details type="reasoning">
<summary>Thinking…</summary>
First step
Second step
</details>
''');

    expect(details.attributes['body_markdown'], 'First step\n\nSecond step');
  });

  test('code_interpreter bodies preserve line boundaries with hard breaks', () {
    final details = parseDetails('''
<details type="code_interpreter">
<summary>Analyzing…</summary>
stdout: line 1
stdout: line 2
</details>
''');

    expect(
      details.attributes['body_markdown'],
      'stdout: line 1  \nstdout: line 2',
    );
  });

  test('preserves trailing content after a closing details tag', () {
    final document = md.Document(blockSyntaxes: const [DetailsBlockSyntax()]);
    final nodes = document.parse('''
<details type="reasoning">
<summary>Thinking…</summary>
Reasoning body
</details>Visible response
''');

    expect(nodes, hasLength(1));
    expect(nodes.single, isA<md.Element>());

    final root = nodes.single as md.Element;
    expect(root.tag, 'div');

    final children = (root.children ?? const <md.Node>[])
        .whereType<md.Element>()
        .toList(growable: false);
    expect(children, hasLength(2));
    expect(children.first.tag, 'details');
    expect(children.last.tag, 'p');
    expect(flattenText(children.last), 'Visible response');
  });
}
