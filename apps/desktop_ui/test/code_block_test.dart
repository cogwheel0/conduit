@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/widgets/code_block.dart';
import 'package:conduit_desktop_ui/src/widgets/code_languages.dart';
import 'package:conduit_desktop_ui/src/widgets/markdown_view.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_test/jaspr_test.dart';

void main() {
  group('resolveLanguage', () {
    test('an exact name resolves to itself', () {
      expect(resolveLanguage('python'), 'python');
    });

    test('the names people actually write resolve', () {
      // A block tagged `js` rendering plain reads as a broken highlighter
      // rather than an unasked one.
      expect(resolveLanguage('js'), 'javascript');
      expect(resolveLanguage('sh'), 'bash');
      expect(resolveLanguage('yml'), 'yaml');
      expect(resolveLanguage('c++'), 'cpp');
      expect(resolveLanguage('c'), 'cpp');
      expect(resolveLanguage('html'), 'xml');
    });

    test('case and attributes on the fence do not matter', () {
      expect(resolveLanguage('Dockerfile'), 'dockerfile');
      expect(resolveLanguage('js title="a.js"'), 'javascript');
    });

    test('an unregistered language is null rather than a guess', () {
      // Highlighting Brainfuck as Bash is worse than not highlighting it.
      expect(resolveLanguage('brainfuck'), isNull);
      expect(resolveLanguage(''), isNull);
      expect(resolveLanguage(null), isNull);
    });

    test('every alias points at something registered', () {
      for (final MapEntry(:key, :value) in languageAliases.entries) {
        expect(
          codeLanguages.containsKey(value),
          isTrue,
          reason: "alias '$key' points at unregistered '$value'",
        );
      }
    });
  });

  group('CodeBlock', () {
    testComponents('tokenises a known language', (tester) async {
      tester.pumpComponent(
        const CodeBlock(source: 'final x = 1;', language: 'dart'),
      );
      // Built as components, never as `innerHTML`: the source of a code
      // block is model output and this origin holds the preload bridge.
      expect(find.text('final'), findsOneComponent);
      expect(find.tag('pre'), findsOneComponent);
    });

    testComponents('an unknown language keeps the source intact', (
      tester,
    ) async {
      tester.pumpComponent(
        const CodeBlock(source: 'not really code', language: 'sanskrit'),
      );
      // Unhighlighted, but complete. A block that loses characters to a
      // failed parse is worse than a grey one.
      expect(find.text('not really code'), findsOneComponent);
    });

    testComponents('a half-streamed block does not throw', (tester) async {
      // Every code block is malformed for as long as it is arriving.
      tester.pumpComponent(
        const CodeBlock(source: 'class Half {\n  void f(', language: 'dart'),
      );
      expect(find.tag('pre'), findsOneComponent);
    });

    testComponents('the copy button appears only with somewhere to copy to', (
      tester,
    ) async {
      tester.pumpComponent(const CodeBlock(source: 'x', language: 'dart'));
      expect(find.text(t.app.copy), findsNothing);
    });

    testComponents('copying hands over the source, not the rendered tokens', (
      tester,
    ) async {
      final copied = <String>[];
      tester.pumpComponent(
        CodeBlock(source: 'final x = 1;', language: 'dart', onCopy: copied.add),
      );
      await tester.click(
        find.ancestor(of: find.text(t.app.copy), matching: find.tag('button')),
      );

      expect(copied, <String>['final x = 1;']);
    });
  });

  group('preview', () {
    test('the label is what the author wrote', () {
      // `html` and `svg` both highlight as xml; labelling them "xml" reads
      // as the app having misunderstood the fence.
      expect(CodeBlock.fenceLabel('html'), 'html');
      expect(CodeBlock.fenceLabel('JS title="a.js"'), 'js');
      expect(CodeBlock.fenceLabel('  '), isNull);
      expect(CodeBlock.fenceLabel(null), isNull);
    });

    test('only markup is previewable', () {
      // The list of fences that get an `<iframe>` built for them.
      expect(CodeBlock.isPreviewable('html'), isTrue);
      expect(CodeBlock.isPreviewable('svg'), isTrue);
      expect(CodeBlock.isPreviewable('python'), isFalse);
      expect(CodeBlock.isPreviewable('bash'), isFalse);
      expect(CodeBlock.isPreviewable(null), isFalse);
    });

    testComponents('the frame exists only once it is asked for', (
      tester,
    ) async {
      tester.pumpComponent(
        const CodeBlock(source: '<b>hi</b>', language: 'html'),
      );
      // Receiving a reply must never render anything but text.
      expect(find.tag('iframe'), findsNothing);

      await tester.click(
        find.ancestor(
          of: find.text(t.desktop.desktopPreview),
          matching: find.tag('button'),
        ),
      );
      expect(find.tag('iframe'), findsOneComponent);
    });

    testComponents('the frame is sandboxed with nothing allowed', (
      tester,
    ) async {
      tester.pumpComponent(
        const CodeBlock(source: '<script>alert(1)</script>', language: 'html'),
      );
      await tester.click(
        find.ancestor(
          of: find.text(t.desktop.desktopPreview),
          matching: find.tag('button'),
        ),
      );

      final frame = find
          .byComponentPredicate(
            (component) =>
                component is DomComponent && component.tag == 'iframe',
          )
          .evaluate()
          .whereType<DomElement>()
          .first;
      final attributes = frame.component.attributes ?? const <String, String>{};

      // Empty, not absent: an absent `sandbox` is no sandbox at all. And
      // never `allow-scripts allow-same-origin` together, which lets a
      // frame reach out and remove its own sandbox attribute.
      expect(attributes['sandbox'], '');
      expect(attributes['srcdoc'], '<script>alert(1)</script>');
    });
  });

  group('through markdown', () {
    testComponents('a fence reaches the block with its language', (
      tester,
    ) async {
      final copied = <String>[];
      tester.pumpComponent(
        MarkdownView('```python\nprint("hi")\n```', onCopyCode: copied.add),
      );
      expect(find.text('python'), findsOneComponent);

      await tester.click(
        find.ancestor(of: find.text(t.app.copy), matching: find.tag('button')),
      );
      // The fence's contents, and nothing of the fence itself.
      expect(copied, <String>['print("hi")\n']);
    });
  });
}
