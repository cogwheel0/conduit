import 'package:conduit_core/utils/streaming_markdown_preparation.dart';
import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unwraps explanations and formatted bullets but preserves code', () {
    const prose =
        '```text\nFirst useful sentence.\nSecond useful sentence.\nThird useful sentence.\n```';
    expect(
      ConduitMarkdownPreprocessor.normalize(prose),
      isNot(contains('```')),
    );
    expect(
      ConduitMarkdownPreprocessor.normalize(
        '```\n- **Ready** to review\n- `config.set` changes a setting\n```',
      ),
      contains('**Ready**'),
    );
    for (final code in [
      '```python\nprint("first")\nprint("second")\nprint("third")\n```',
      '```json\n{\n  "enabled": true\n}\n```',
      '```text\nHost example\n    HostName 10.0.0.1\n    Port 22\n```',
      '```\nAPI_KEY=example\nPORT=8080\nDEBUG=true\n```',
    ]) {
      expect(ConduitMarkdownPreprocessor.normalize(code), code);
    }
  });

  test('preserves nested fences, tilde listings, and literal delimiters', () {
    for (final code in [
      '````markdown\n```js\nconst x = 1;\n```\n````',
      '~~~python\nprint("```")\n~~~',
      '```python\ndef fence(line):\n    return line.startswith("```")\n```',
    ]) {
      expect(ConduitMarkdownPreprocessor.normalize(code), code);
    }
    expect(
      ConduitMarkdownPreprocessor.normalize('~~~python\nprint(1)'),
      '~~~python\nprint(1)\n~~~',
    );
    expect(
      ConduitMarkdownPreprocessor.normalize('````md\n```js\nconst a = 1;'),
      endsWith('\n````'),
    );
  });

  test('recognizes localized prose and remains idempotent', () {
    const input =
        '```text\nPierwsze zdanie.\nDrugie zdanie.\nTrzecie zdanie.\n```';
    final prepared = ConduitMarkdownPreprocessor.normalize(input);
    expect(prepared, isNot(contains('```')));
    expect(ConduitMarkdownPreprocessor.normalize(prepared), prepared);
  });

  test('repairs live emphasis and code without changing completed text', () {
    for (final input in [
      'The update is **ready',
      'Use `config.set',
      '**Use `config.set',
    ]) {
      final repaired = prepareMarkdownContentCanonical(input, streaming: true);
      expect(repaired, isNot(input));
      expect(prepareMarkdownContentCanonical(input, streaming: false), input);
    }
    const literal = '```python\nvalue = "**literal"\n```';
    expect(prepareMarkdownContentCanonical(literal, streaming: true), literal);
    const escaped = r'The marker is \**literal';
    expect(prepareMarkdownContentCanonical(escaped, streaming: true), escaped);
  });

  test('incremental streaming converges without parity fallback', () {
    for (final content in [
      'Stable paragraph.\n\nThe update is **ready**. Use `config.set`.\n\n```text\nFirst sentence.\nSecond sentence.\nThird sentence.\n```',
      'Stable paragraph.\n\n~~~python\nprint("**literal")\n~~~\n\nDone.',
    ]) {
      final engine = StreamingMarkdownPreparationEngine();
      var prepared = const PreparedMarkdownText.empty();
      for (var length = 1; length <= content.length; length++) {
        final raw = content.substring(0, length);
        final patch = engine.prepare(
          MarkdownPreparationRequest(
            sessionId: 'synthetic',
            revision: length,
            expectedBaseRevision: length - 1,
            content: raw,
            streaming: true,
            verifyParity: false,
            collectMetrics: false,
          ),
        );
        prepared = prepared.applyPatch(patch);
        expect(
          prepared.materialize(),
          prepareMarkdownContentCanonical(raw, streaming: true),
          reason: 'prefix $length of $content',
        );
      }
      final terminal = engine.prepare(
        MarkdownPreparationRequest(
          sessionId: 'synthetic',
          revision: content.length + 1,
          expectedBaseRevision: content.length,
          content: content,
          streaming: false,
          verifyParity: false,
          collectMetrics: false,
        ),
      );
      expect(
        prepared.applyPatch(terminal).materialize(),
        prepareMarkdownContentCanonical(content, streaming: false),
      );
    }
  });
}
