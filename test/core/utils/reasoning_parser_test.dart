import 'package:checks/checks.dart';
import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatDuration', () {
    test('returns "less than a second" for 0', () {
      check(ReasoningParser.formatDuration(0)).equals('less than a second');
    });

    test('returns "1 second" for 1', () {
      check(ReasoningParser.formatDuration(1)).equals('1 second');
    });

    test('returns "30 seconds" for 30', () {
      check(ReasoningParser.formatDuration(30)).equals('30 seconds');
    });

    test('returns "a minute" for 60', () {
      check(ReasoningParser.formatDuration(60)).equals('a minute');
    });

    test('returns "2 minutes" for 120', () {
      check(ReasoningParser.formatDuration(120)).equals('2 minutes');
    });

    test('returns "about an hour" for 3600', () {
      check(ReasoningParser.formatDuration(3600)).equals('about an hour');
    });
  });

  group('hasReasoningContent', () {
    test('detects type="reasoning"', () {
      const content =
          '<details type="reasoning"><summary>Thought</summary>'
          'inner</details>';
      check(ReasoningParser.hasReasoningContent(content)).isTrue();
    });

    test('detects <think> tag', () {
      check(ReasoningParser.hasReasoningContent('<think>some thought</think>'))
          .isTrue();
    });

    test('detects <thinking> tag', () {
      check(ReasoningParser.hasReasoningContent('<thinking>hmm</thinking>'))
          .isTrue();
    });

    test('detects unicode think tag', () {
      check(ReasoningParser.hasReasoningContent('◁think▷reasoning◁/think▷'))
          .isTrue();
    });

    test('detects type="code_interpreter"', () {
      const content =
          '<details type="code_interpreter">'
          '<summary>Code</summary>code</details>';
      check(ReasoningParser.hasReasoningContent(content)).isTrue();
    });

    test('returns false for plain text', () {
      check(ReasoningParser.hasReasoningContent('Hello, world!')).isFalse();
    });
  });

  group('segments', () {
    test('returns null for empty string', () {
      check(ReasoningParser.segments('')).isNull();
    });

    test('returns text-only segment for plain text', () {
      final segs = ReasoningParser.segments('Hello, world!');
      check(segs).isNotNull();
      check(segs!.length).equals(1);
      check(segs.first.isReasoning).isFalse();
      check(segs.first.text).equals('Hello, world!');
    });

    test('parses complete <think> block', () {
      const content = 'Before <think>reasoning here</think> After';
      final segs = ReasoningParser.segments(content);
      check(segs).isNotNull();
      final s = segs!;
      check(s.length).equals(3);

      // Text before
      check(s[0].isReasoning).isFalse();
      check(s[0].text).isNotNull();
      check(s[0].text!).contains('Before');

      // Reasoning entry
      check(s[1].isReasoning).isTrue();
      check(s[1].entry!.reasoning).equals('reasoning here');
      check(s[1].entry!.isDone).isTrue();

      // Text after
      check(s[2].isReasoning).isFalse();
      check(s[2].text).isNotNull();
      check(s[2].text!).contains('After');
    });

    test('parses incomplete streaming block', () {
      const content = '<think>partial reasoning';
      final segs = ReasoningParser.segments(content);
      check(segs).isNotNull();
      final s = segs!;
      check(s.length).equals(1);
      check(s[0].isReasoning).isTrue();
      check(s[0].entry!.reasoning).equals('partial reasoning');
      check(s[0].entry!.isDone).isFalse();
    });

    test('parses details with summary and duration', () {
      const content =
          '<details type="reasoning" done="true" duration="45">'
          '<summary>Thought</summary>'
          'deep thinking'
          '</details>';
      final segs = ReasoningParser.segments(content);
      check(segs).isNotNull();
      final entry = segs!.first.entry!;
      check(entry.summary).equals('Thought');
      check(entry.reasoning).equals('deep thinking');
      check(entry.duration).equals(45);
      check(entry.isDone).isTrue();
    });

    test('parses tag with attributes', () {
      const content = '<think foo="bar">attributed</think>';
      final segs = ReasoningParser.segments(content);
      check(segs).isNotNull();
      check(segs!.first.entry!.reasoning).equals('attributed');
    });

    test('extracts duration from summary "(2m 30s)"', () {
      const content =
          '<details type="reasoning">'
          '<summary>Thinking (2m 30s)</summary>'
          'content'
          '</details>';
      final segs = ReasoningParser.segments(content);
      check(segs).isNotNull();
      check(segs!.first.entry!.duration).equals(150);
    });

    test('handles nested details', () {
      const content =
          '<details type="reasoning">'
          '<summary>Outer</summary>'
          '<details><summary>Inner</summary>inner</details>'
          'outer content'
          '</details>';
      final segs = ReasoningParser.segments(content);
      check(segs).isNotNull();
      // Should parse outer block as a single reasoning entry
      final entry = segs!.first.entry!;
      check(entry.summary).equals('Outer');
    });

    test('treats non-reasoning details as text', () {
      const content =
          '<details><summary>Notes</summary>'
          'stuff</details>';
      final segs = ReasoningParser.segments(content);
      check(segs).isNotNull();
      // "Notes" does not match Thought|Thinking|Reasoning
      check(segs!.first.isReasoning).isFalse();
      check(segs.first.text).isNotNull();
    });

    test('supports custom tag pairs', () {
      const content = '<custom>inside</custom>';
      final segs = ReasoningParser.segments(
        content,
        customTagPairs: [('<custom>', '</custom>')],
        detectDefaultTags: false,
      );
      check(segs).isNotNull();
      check(segs!.first.entry!.reasoning).equals('inside');
    });

    test('identifies code_interpreter blockType', () {
      const content =
          '<details type="code_interpreter">'
          '<summary>Code</summary>'
          'code here'
          '</details>';
      final segs = ReasoningParser.segments(content);
      check(segs).isNotNull();
      check(segs!.first.entry!.blockType)
          .equals(CollapsibleBlockType.codeInterpreter);
    });

    test('handles multiple consecutive blocks', () {
      const content =
          '<think>first</think>'
          'middle text'
          '<think>second</think>';
      final segs = ReasoningParser.segments(content);
      check(segs).isNotNull();
      final s = segs!;
      check(s.length).equals(3);
      check(s[0].entry!.reasoning).equals('first');
      check(s[1].text).isNotNull();
      check(s[1].text!).contains('middle');
      check(s[2].entry!.reasoning).equals('second');
    });
  });

  group('parseReasoningContent', () {
    test('returns null for no reasoning', () {
      check(ReasoningParser.parseReasoningContent('plain text')).isNull();
    });

    test('extracts first block and mainContent', () {
      const content = 'Hello <think>my reasoning</think> world';
      final result = ReasoningParser.parseReasoningContent(content);
      check(result).isNotNull();
      check(result!.reasoning).equals('my reasoning');
      check(result.mainContent).equals('Hello  world');
      check(result.originalContent).equals(content);
    });
  });

  group('ReasoningEntry', () {
    test('cleanedReasoning removes "> " blockquote markers', () {
      const entry = ReasoningEntry(
        reasoning: '> line one\n> line two\n>no space',
        summary: '',
        duration: 0,
        isDone: true,
      );
      check(entry.cleanedReasoning).equals('line one\nline two\nno space');
    });

    test('formattedDuration delegates to formatDuration', () {
      const entry = ReasoningEntry(
        reasoning: '',
        summary: '',
        duration: 30,
        isDone: true,
      );
      check(entry.formattedDuration).equals('30 seconds');
    });
  });

  group('StreamingReasoningTagSplitter', () {
    List<Object> collect(Iterable<RawReasoningTagEvent> events) => [
      for (final event in events)
        switch (event) {
          RawReasoningTagText(:final text) => 'text:$text',
          RawReasoningTagReasoning(:final text) => 'reason:$text',
          RawReasoningTagEnd() => 'end',
        },
    ];

    test('splits tags that arrive across chunks and keeps text order', () {
      final splitter = StreamingReasoningTagSplitter();
      final events = <RawReasoningTagEvent>[
        ...splitter.feed('Klar!<thi'),
        ...splitter.feed('nk>\nDer Benutzer'),
        ...splitter.feed(' fragt.</th'),
        ...splitter.feed('ink>\n\nMorgen 24°.'),
      ];
      check(collect(events)).deepEquals([
        'text:Klar!',
        'reason:\nDer Benutzer',
        'reason: fragt.',
        'end',
        'text:\n\nMorgen 24°.',
      ]);
      check(splitter.isInsideReasoning).isFalse();
    });

    test('holds a possible tag prefix back and releases it on flush', () {
      final splitter = StreamingReasoningTagSplitter();
      check(collect(splitter.feed('a <'))).deepEquals(['text:a ']);
      check(collect(splitter.feed('b'))).deepEquals(['text:<b']);
      check(collect(splitter.feed('<think>open'))).deepEquals(['reason:open']);
      check(collect(splitter.flush())).deepEquals([]);
      check(collect(splitter.feed(' more'))).deepEquals(['reason: more']);
      check(splitter.isInsideReasoning).isTrue();
    });

    test('matches attributed XML tags, also when split across chunks', () {
      final splitter = StreamingReasoningTagSplitter();
      final events = <RawReasoningTagEvent>[
        ...splitter.feed('Hi <thinking source="mo'),
        ...splitter.feed('del">deep</thinking> bye'),
      ];
      check(collect(events))
          .deepEquals(['text:Hi ', 'reason:deep', 'end', 'text: bye']);
    });

    test('releases an over-long unterminated attributed tag as prose', () {
      final splitter = StreamingReasoningTagSplitter();
      final prose =
          '<think ${'a' * StreamingReasoningTagSplitter.maxHeldLength}';
      check(collect(splitter.feed(prose))).deepEquals(['text:$prose']);
    });

    test('handles several reasoning blocks and non-XML tags', () {
      final splitter = StreamingReasoningTagSplitter();
      final events = splitter.feed(
        '<think>one</think>mid◁think▷two◁/think▷end',
      );
      check(collect(events)).deepEquals([
        'reason:one',
        'end',
        'text:mid',
        'reason:two',
        'end',
        'text:end',
      ]);
    });

    group('ignoreTagsInCode', () {
      String answerOf(
        StreamingReasoningTagSplitter splitter,
        List<String> chunks,
      ) {
        final events = <RawReasoningTagEvent>[
          for (final chunk in chunks) ...splitter.feed(chunk),
          ...splitter.flush(),
        ];
        check(events.whereType<RawReasoningTagReasoning>()).isEmpty();
        return events
            .whereType<RawReasoningTagText>()
            .map((event) => event.text)
            .join();
      }

      /// [collect] for [chunks], with neighbouring text or reasoning pieces
      /// joined, so one text gives the same list however it is cut.
      List<String> joined(List<String> chunks) {
        final splitter = StreamingReasoningTagSplitter(ignoreTagsInCode: true);
        final pieces = <String>[];
        for (final piece in collect([
          for (final chunk in chunks) ...splitter.feed(chunk),
          ...splitter.flush(),
        ]).cast<String>()) {
          final kind = piece.substring(0, piece.indexOf(':') + 1);
          if (kind.isNotEmpty &&
              pieces.isNotEmpty &&
              pieces.last.startsWith(kind)) {
            pieces.last += piece.substring(kind.length);
          } else {
            pieces.add(piece);
          }
        }
        return pieces;
      }

      List<String> characters(String text) => [
        for (var index = 0; index < text.length; index++) text[index],
      ];

      test('leaves tags in inline code spans as text', () {
        const text = 'Use `<think>` or `` <thinking> `` there.';
        check(
          answerOf(StreamingReasoningTagSplitter(ignoreTagsInCode: true), [
            text,
          ]),
        ).equals(text);
      });

      test('leaves tags in backtick and tilde fences as text', () {
        const text =
            'Example:\n'
            '   ```xml\n'
            '<think>draft</think>\n'
            '```\n'
            '~~~~\n'
            '<thought>x</thought>\n'
            '~~~\n'
            '~~~~\n';
        check(
          answerOf(StreamingReasoningTagSplitter(ignoreTagsInCode: true), [
            text,
          ]),
        ).equals(text);
      });

      test('reads backtick runs and tags cut across chunks', () {
        const text = 'A ```` `` <think> ```` span, then\n``\n`<think>`';
        final chunks = <String>[];
        for (var index = 0; index < text.length; index++) {
          chunks.add(text[index]);
        }
        check(
          answerOf(
            StreamingReasoningTagSplitter(ignoreTagsInCode: true),
            chunks,
          ),
        ).equals(text);
      });

      test('splits tags outside code, before and after it', () {
        final splitter = StreamingReasoningTagSplitter(ignoreTagsInCode: true);
        final events = <RawReasoningTagEvent>[
          ...splitter.feed('<think>first</think>`<think>` and\n'),
          ...splitter.feed('```\n<think>\n```\n<think>second</think>end'),
        ];
        check(collect(events)).deepEquals([
          'reason:first',
          'end',
          'text:`<think>',
          'text:` and\n',
          'text:```\n<think>',
          'text:\n```\n',
          'reason:second',
          'end',
          'text:end',
        ]);
      });

      test('keeps a fence open past a marker line with text after it', () {
        const text =
            '```\n'
            '```js\n'
            '<think>sample</think>\n'
            '```<think>\n'
            '```\n'
            '~~~\n'
            '~~~xml\n'
            '<thought>sample</thought>\n'
            '~~~ \n'
            '<think>real</think>after';
        const expected = [
          'text:```\n```js\n<think>sample</think>\n```<think>\n```\n'
              '~~~\n~~~xml\n<thought>sample</thought>\n~~~ \n',
          'reason:real',
          'end',
          'text:after',
        ];
        check(joined([text])).deepEquals(expected);
        check(joined(characters(text))).deepEquals(expected);
      });

      test('reads a backslash-escaped backtick outside code as text', () {
        const text =
            r'Type \` for a tick. <think>real</think>'
            r'A \\`<think>` span, and `a\`<think>also real</think>';
        const expected = [
          r'text:Type \` for a tick. ',
          'reason:real',
          'end',
          r'text:A \\`<think>` span, and `a\`',
          'reason:also real',
          'end',
        ];
        check(joined([text])).deepEquals(expected);
        check(joined(characters(text))).deepEquals(expected);
      });

      test('ends an unclosed inline span at a blank line', () {
        final splitter = StreamingReasoningTagSplitter(ignoreTagsInCode: true);
        final events = splitter.feed('a stray ` tick\n\n<think>real</think>');
        check(collect(events))
            .deepEquals(['text:a stray ` tick\n\n', 'reason:real', 'end']);
      });

      test('is off by default, as Open WebUI splits tags anywhere', () {
        final splitter = StreamingReasoningTagSplitter();
        check(collect(splitter.feed('`<think>x</think>`')))
            .deepEquals(['text:`', 'reason:x', 'end', 'text:`']);
      });
    });
  });
}
