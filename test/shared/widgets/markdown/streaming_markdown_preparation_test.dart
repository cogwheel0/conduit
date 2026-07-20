import 'package:conduit/shared/widgets/markdown/streaming_markdown_preparation.dart';
import 'package:flutter_test/flutter_test.dart';

MarkdownPreparationRequest _request({
  required String sessionId,
  required int revision,
  required int baseRevision,
  required String content,
  bool streaming = true,
  bool collectMetrics = true,
  bool verifyParity = true,
}) {
  return MarkdownPreparationRequest(
    sessionId: sessionId,
    revision: revision,
    expectedBaseRevision: baseRevision,
    content: content,
    streaming: streaming,
    collectMetrics: collectMetrics,
    verifyParity: verifyParity,
  );
}

void main() {
  test('first request returns a full patch and establishes a session', () {
    final engine = StreamingMarkdownPreparationEngine();

    final patch = engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 1,
        baseRevision: 0,
        content: 'First paragraph.\n\nSecond',
      ),
    );

    expect(patch.mode, MarkdownPreparationMode.full);
    expect(patch.preparedRetainLength, 0);
    expect(
      patch.replacementTail,
      prepareMarkdownContentCanonical(
        'First paragraph.\n\nSecond',
        streaming: true,
      ),
    );
    expect(engine.sessionCount, 1);
  });

  test('append after a completed block processes only the mutable tail', () {
    final engine = StreamingMarkdownPreparationEngine();
    var prepared = const PreparedMarkdownText.empty();

    final first = engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 1,
        baseRevision: 0,
        content: 'First paragraph.\n\nSecond',
      ),
    );
    prepared = prepared.applyPatch(first);

    final secondContent = 'First paragraph.\n\nSecond grows';
    final second = engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 2,
        baseRevision: 1,
        content: secondContent,
      ),
    );
    prepared = prepared.applyPatch(second);

    expect(second.mode, MarkdownPreparationMode.incremental);
    expect(second.rawRetainLength, 'First paragraph.\n\n'.length);
    expect(second.metrics.processedCharacters, 'Second grows'.length);
    expect(
      prepared.materialize(),
      prepareMarkdownContentCanonical(secondContent, streaming: true),
    );
  });

  test('replacement inside the mutable tail preserves the prepared prefix', () {
    final engine = StreamingMarkdownPreparationEngine();
    var prepared = const PreparedMarkdownText.empty();

    final first = engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 1,
        baseRevision: 0,
        content: 'Stable paragraph.\n\nDraft ending',
      ),
    );
    prepared = prepared.applyPatch(first);

    const replacement = 'Stable paragraph.\n\nDifferent ending';
    final second = engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 2,
        baseRevision: 1,
        content: replacement,
      ),
    );
    prepared = prepared.applyPatch(second);

    expect(second.mode, MarkdownPreparationMode.incremental);
    expect(second.preparedRetainLength, 'Stable paragraph.\n\n'.length);
    expect(
      prepared.materialize(),
      prepareMarkdownContentCanonical(replacement, streaming: true),
    );
  });

  test(
    'hidden incomplete tool call trims retained whitespace without parity checks',
    () {
      final engine = StreamingMarkdownPreparationEngine();
      var prepared = const PreparedMarkdownText.empty();

      final first = engine.prepare(
        _request(
          sessionId: 'message-1',
          revision: 1,
          baseRevision: 0,
          content: 'Visible\n\nDraft',
          verifyParity: false,
        ),
      );
      prepared = prepared.applyPatch(first);

      const content = 'Visible\n\n<details type="tool_calls" name="search">';
      final second = engine.prepare(
        _request(
          sessionId: 'message-1',
          revision: 2,
          baseRevision: 1,
          content: content,
          verifyParity: false,
        ),
      );
      prepared = prepared.applyPatch(second);

      expect(second.mode, MarkdownPreparationMode.incremental);
      expect(prepared.materialize(), 'Visible');
      expect(
        prepared.materialize(),
        prepareMarkdownContentCanonical(content, streaming: true),
      );
    },
  );

  test('completed tool call restores its separator without parity checks', () {
    final engine = StreamingMarkdownPreparationEngine();
    var prepared = const PreparedMarkdownText.empty();

    final first = engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 1,
        baseRevision: 0,
        content: 'Visible\n\nDraft',
        verifyParity: false,
      ),
    );
    prepared = prepared.applyPatch(first);

    const incomplete = 'Visible\n\n<details type="tool_calls" name="search">';
    final second = engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 2,
        baseRevision: 1,
        content: incomplete,
        verifyParity: false,
      ),
    );
    prepared = prepared.applyPatch(second);
    expect(prepared.materialize(), 'Visible');

    const completed = '''Visible

<details type="tool_calls" name="search">
<summary>Search</summary>
result
</details>''';
    final third = engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 3,
        baseRevision: 2,
        content: completed,
        verifyParity: false,
      ),
    );
    prepared = prepared.applyPatch(third);

    expect(third.mode, MarkdownPreparationMode.incremental);
    expect(
      prepared.materialize(),
      prepareMarkdownContentCanonical(completed, streaming: true),
    );
  });

  test('mixed-case incomplete tool call details stay hidden', () {
    const content = 'Visible\n\n<DETAILS TYPE="tool_calls" name="search">';

    expect(
      prepareMarkdownContentCanonical(content, streaming: true),
      'Visible',
    );
  });

  test('base revision mismatch returns a full reset patch', () {
    final engine = StreamingMarkdownPreparationEngine();
    engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 1,
        baseRevision: 0,
        content: 'First paragraph.\n\nTail',
      ),
    );

    final patch = engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 2,
        baseRevision: 0,
        content: 'First paragraph.\n\nNew tail',
      ),
    );

    expect(patch.mode, MarkdownPreparationMode.resetFull);
    expect(patch.fallbackReason, 'baseRevisionMismatch');
    expect(patch.preparedRetainLength, 0);
  });

  test('duplicate or decreasing revisions are reported as stale', () {
    final engine = StreamingMarkdownPreparationEngine();
    engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 2,
        baseRevision: 0,
        content: 'Current',
      ),
    );

    final stale = engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 1,
        baseRevision: 0,
        content: 'Old',
      ),
    );

    expect(stale.mode, MarkdownPreparationMode.stale);
    expect(stale.fallbackReason, 'staleRevision');
  });

  test('release removes session state', () {
    final engine = StreamingMarkdownPreparationEngine();
    engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 1,
        baseRevision: 0,
        content: 'Current',
      ),
    );

    expect(engine.release('message-1'), isTrue);
    expect(engine.sessionCount, 0);

    final reset = engine.prepare(
      _request(
        sessionId: 'message-1',
        revision: 2,
        baseRevision: 1,
        content: 'Current grows',
      ),
    );
    expect(reset.mode, MarkdownPreparationMode.resetFull);
    expect(reset.fallbackReason, 'missingSession');
  });

  test('session map is bounded by least-recently-used eviction', () {
    final engine = StreamingMarkdownPreparationEngine(maxSessions: 2);
    for (var index = 0; index < 3; index += 1) {
      engine.prepare(
        _request(
          sessionId: 'message-$index',
          revision: 1,
          baseRevision: 0,
          content: 'Message $index',
        ),
      );
    }

    expect(engine.sessionCount, 2);
    final reset = engine.prepare(
      _request(
        sessionId: 'message-0',
        revision: 2,
        baseRevision: 1,
        content: 'Message 0 grows',
      ),
    );
    expect(reset.mode, MarkdownPreparationMode.resetFull);
    expect(reset.fallbackReason, 'missingSession');
  });

  test('patch application rejects a UTF-16 surrogate split', () {
    final prepared = PreparedMarkdownText.fromString('A😀B');
    final patch = MarkdownPreparationPatch(
      sessionId: 'message-1',
      revision: 2,
      baseRevision: 1,
      rawRetainLength: 2,
      preparedRetainLength: 2,
      replacementTail: 'tail',
      logicalPreparedLength: 6,
      mode: MarkdownPreparationMode.incremental,
      metrics: const MarkdownPreparationMetrics.empty(),
    );

    expect(() => prepared.applyPatch(patch), throwsArgumentError);
  });

  test('incremental preparation matches canonical output across fixtures', () {
    final fixtures = <String>[
      'First paragraph.\n\nSecond paragraph grows over time.',
      'Title\n---\n\nBody text.',
      '```dart\nprint("hello");\n```\n\nAfter code.',
      '<details type="tool_calls" name="search">\n'
          '<summary>Tool</summary>\nbody\n</details>\n\nVisible.',
      'Emoji 😀 and CJK 物語.\n\nCombining é text.',
      'A [link](https://example.com)  \n\nNext paragraph.',
    ];

    for (
      var fixtureIndex = 0;
      fixtureIndex < fixtures.length;
      fixtureIndex += 1
    ) {
      final fixture = fixtures[fixtureIndex];
      final engine = StreamingMarkdownPreparationEngine();
      var prepared = const PreparedMarkdownText.empty();
      var revision = 0;
      for (var end = 1; end <= fixture.length; end += 1) {
        if (end < fixture.length &&
            fixture.codeUnitAt(end - 1) >= 0xD800 &&
            fixture.codeUnitAt(end - 1) <= 0xDBFF) {
          continue;
        }
        revision += 1;
        final patch = engine.prepare(
          _request(
            sessionId: 'fixture-$fixtureIndex',
            revision: revision,
            baseRevision: revision - 1,
            content: fixture.substring(0, end),
          ),
        );
        prepared = prepared.applyPatch(patch);
        expect(
          prepared.materialize(),
          prepareMarkdownContentCanonical(
            fixture.substring(0, end),
            streaming: true,
          ),
          reason: 'fixture=$fixtureIndex end=$end mode=${patch.mode}',
        );
      }
    }
  });
}
