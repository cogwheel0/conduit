@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/sandbox_port.dart';
import 'package:conduit_desktop_ui/src/widgets/markdown_view.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

/// Math in replies.
///
/// The delimiter rules are the substance here. A missed formula renders as
/// the LaTeX the model wrote, which is readable; a false positive turns a
/// sentence into a formula and loses it. The two errors do not cost the
/// same, so the tests are mostly about what must *not* match.
void main() {
  RecordingSandbox pump(ComponentTester tester, String markdown) {
    final sandbox = RecordingSandbox();
    tester.pumpComponent(
      ProviderScope(
        overrides: [sandboxProvider.overrideWithValue(sandbox)],
        child: MarkdownView(markdown, mathIdPrefix: 'm1'),
      ),
    );
    return sandbox;
  }

  group('delimiters', () {
    testComponents('renders inline dollar math', (tester) async {
      final sandbox = pump(tester, r'Let $x^2$ be.');
      await pumpEventQueue();
      expect(sandbox.rendered.single.payload.source, r'x^2');
      expect(sandbox.rendered.single.payload.display, isFalse);
    });

    testComponents('renders display math', (tester) async {
      final sandbox = pump(tester, r'$$\int_0^1 x\,dx$$');
      await pumpEventQueue();
      expect(sandbox.rendered.single.payload.display, isTrue);
    });

    testComponents('renders the backslash forms models also write', (
      tester,
    ) async {
      final inline = pump(tester, r'Then \(a+b\) holds.');
      await pumpEventQueue();
      expect(inline.rendered.single.payload.source, 'a+b');
      expect(inline.rendered.single.payload.display, isFalse);

      final block = pump(tester, r'\[a+b\]');
      await pumpEventQueue();
      expect(block.rendered.single.payload.display, isTrue);
    });
  });

  group('what must not become a formula', () {
    testComponents('prices stay prose', (tester) async {
      // "5 and 10" set as a formula is a sentence the reader loses.
      final sandbox = pump(tester, r'I paid $5 and $10 for it.');
      await pumpEventQueue();
      expect(sandbox.rendered, isEmpty);
      expect(find.text(r'I paid $5 and $10 for it.'), findsOneComponent);
    });

    testComponents('a dollar against a word opens nothing', (tester) async {
      final sandbox = pump(tester, r'Costs US$5, or EUR$4 today.');
      await pumpEventQueue();
      expect(sandbox.rendered, isEmpty);
    });

    testComponents('padded delimiters are prose', (tester) async {
      final sandbox = pump(tester, r'From $ 100 to $ 200 a month.');
      await pumpEventQueue();
      expect(sandbox.rendered, isEmpty);
    });

    testComponents('a shell variable in a code span is code', (tester) async {
      final sandbox = pump(tester, r'Run `echo $PATH` first.');
      await pumpEventQueue();
      expect(sandbox.rendered, isEmpty);
      expect(find.tag('code'), findsOneComponent);
    });

    testComponents('a fenced block is never math', (tester) async {
      final sandbox = pump(tester, '```sh\necho \$HOME\nexport \$X=1\n```');
      await pumpEventQueue();
      expect(sandbox.rendered, isEmpty);
    });
  });

  group('without a sandbox', () {
    testComponents('a formula degrades to its own source', (tester) async {
      // Unrendered LaTeX is still readable. A host with no sandbox should
      // land there rather than on nothing.
      tester.pumpComponent(
        ProviderScope(
          overrides: [sandboxProvider.overrideWithValue(RecordingSandbox())],
          child: const MarkdownView(r'Let $x^2$ be.'),
        ),
      );
      await pumpEventQueue();
      expect(find.text('x^2'), findsOneComponent);
      expect(find.tag('iframe'), findsNothing);
    });
  });

  group('drawable fences', () {
    test('only the fences that name a drawing', () {
      expect(MarkdownView.sandboxKindFor('mermaid'), 'mermaid');
      expect(MarkdownView.sandboxKindFor('chart'), 'chart');
      expect(MarkdownView.sandboxKindFor('chartjs'), 'chart');
      // Everything else stays a code block. Nothing gets a frame by
      // accident.
      expect(MarkdownView.sandboxKindFor('python'), isNull);
      expect(MarkdownView.sandboxKindFor('html'), isNull);
      expect(MarkdownView.sandboxKindFor(null), isNull);
    });

    testComponents('a mermaid fence becomes a frame, not a code block', (
      tester,
    ) async {
      final sandbox = pump(tester, '```mermaid\ngraph TD; A-->B;\n```');
      await pumpEventQueue();
      expect(sandbox.rendered.single.payload.kind, 'mermaid');
      expect(sandbox.rendered.single.payload.source, 'graph TD; A-->B;\n');
      expect(find.tag('pre'), findsNothing);
    });

    testComponents('a chart fence hands over its spec verbatim', (
      tester,
    ) async {
      const spec = '{"type":"bar","data":{"labels":["a"]}}';
      final sandbox = pump(tester, '```chart\n$spec\n```');
      await pumpEventQueue();
      expect(sandbox.rendered.single.payload.kind, 'chart');
      // Parsed inside the frame with `JSON.parse`, never here and never
      // with `eval`.
      expect(sandbox.rendered.single.payload.source.trim(), spec);
    });

    testComponents('without a sandbox a diagram stays readable source', (
      tester,
    ) async {
      tester.pumpComponent(
        ProviderScope(
          overrides: [sandboxProvider.overrideWithValue(RecordingSandbox())],
          child: const MarkdownView('```mermaid\ngraph TD; A-->B;\n```'),
        ),
      );
      await pumpEventQueue();
      expect(find.tag('pre'), findsOneComponent);
      expect(find.tag('iframe'), findsNothing);
    });
  });

  group('the frame', () {
    testComponents('is sandboxed to scripts alone', (tester) async {
      pump(tester, r'$x$');
      await pumpEventQueue();

      final frame = find
          .byComponentPredicate(
            (component) =>
                component is DomComponent && component.tag == 'iframe',
          )
          .evaluate()
          .whereType<DomElement>()
          .first;
      final attributes = frame.component.attributes ?? const <String, String>{};

      // Never with `allow-same-origin`: that pair lets a frame reach
      // through `parent` and strip its own sandbox attribute.
      expect(attributes['sandbox'], 'allow-scripts');
      expect(attributes['src'], '/sandbox.html');
    });

    testComponents('two formulas get two frames', (tester) async {
      // Sharing an id would make them draw into each other.
      final sandbox = pump(tester, r'$a$ and $b$');
      await pumpEventQueue();
      final ids = sandbox.rendered.map((r) => r.frameId).toSet();
      expect(ids, hasLength(2));
    });
  });
}
