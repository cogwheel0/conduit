import 'package:conduit_core/features/notes/utils/note_quill_delta.dart';
import 'package:test/test.dart';

void main() {
  test('markdown reaches Quill with Quill names for the formats', () {
    final ops = quillOpsFromMarkdown(
      '# Title\n\nSome **bold** and *italic* with `code`.\n\n'
      '- one\n- two\n\n1. first\n\n> quoted\n',
    );
    // The format of the line [text] ends: Quill keeps it on the newline
    // after it, and adjacent text shares one insert.
    Map<String, Object?>? lineAfter(String text) {
      final index = ops.indexWhere(
        (op) =>
            op['insert'] is String && (op['insert']! as String).endsWith(text),
      );
      return ops[index + 1]['attributes'] as Map<String, Object?>?;
    }

    expect(lineAfter('Title'), <String, Object?>{'header': 1});
    expect(
      ops.firstWhere((op) => op['insert'] == 'bold')['attributes'],
      <String, Object?>{'bold': true},
    );
    expect(
      ops.firstWhere((op) => op['insert'] == 'code')['attributes'],
      <String, Object?>{'code': true},
    );
    expect(lineAfter('one'), <String, Object?>{'list': 'bullet'});
    expect(lineAfter('first'), <String, Object?>{'list': 'ordered'});
    expect(lineAfter('quoted'), <String, Object?>{'blockquote': true});
  });

  test('what Quill edits comes back as the same markdown', () {
    const markdown =
        '## Plan\n\n'
        'Buy **milk** and [bread](https://example.com).\n\n'
        '- [ ] eggs\n- [x] flour\n';
    final roundTripped = markdownFromQuillOps(quillOpsFromMarkdown(markdown));
    expect(roundTripped, contains('## Plan'));
    expect(roundTripped, contains('**milk**'));
    expect(roundTripped, contains('[bread](https://example.com)'));
    expect(roundTripped, contains('- [ ] eggs'));
    // Parchment writes a checked box as `[X]`, which markdown reads the same.
    expect(roundTripped.toLowerCase(), contains('- [x] flour'));
  });

  test('a divider and an image survive the trip', () {
    final markdown = markdownFromQuillOps(<Object?>[
      <String, Object?>{'insert': 'Above\n'},
      <String, Object?>{
        'insert': <String, Object?>{'divider': true},
      },
      <String, Object?>{
        'insert': <String, Object?>{'image': 'https://example.com/a.png'},
      },
      <String, Object?>{'insert': 'Below\n'},
    ]);
    expect(markdown, contains('---'));
    expect(markdown, contains('![](https://example.com/a.png)'));
  });

  test('an empty editor is an empty note', () {
    expect(markdownFromQuillOps(<Object?>[]).trim(), isEmpty);
    expect(
      markdownFromQuillOps(<Object?>[
        <String, Object?>{'insert': '\n'},
      ]).trim(),
      isEmpty,
    );
  });
}
