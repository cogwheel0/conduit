import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/services/direct_reasoning_tags.dart';
import 'package:test/test.dart';

/// Event-order guarantees of [splitInlineReasoningTags] that no adapter
/// produces on its own: tool calls, errors and an early close mid-tag.
void main() {
  test('releases held answer text before a tool call', () async {
    final events = await splitInlineReasoningTags(
      Stream<DirectStreamEvent>.fromIterable(<DirectStreamEvent>[
        const DirectContentDelta('Checking <thi'),
        DirectToolCallStarted(
          id: 'call_1',
          name: 'tide_lookup',
          arguments: const <String, dynamic>{},
        ),
        const DirectContentDelta('s harbour.'),
        const DirectStreamDone(),
      ]),
    ).toList();

    expect(events.map(_describe), <String>[
      'content:Checking ',
      'content:<thi',
      'tool',
      'content:s harbour.',
      'done',
    ]);
  });

  test('keeps a possible closing tag held across a tool call', () async {
    final events = await splitInlineReasoningTags(
      Stream<DirectStreamEvent>.fromIterable(<DirectStreamEvent>[
        const DirectContentDelta('<think>Plan</th'),
        DirectToolCallStarted(
          id: 'call_1',
          name: 'tide_lookup',
          arguments: const <String, dynamic>{},
        ),
        const DirectContentDelta('ink>Answer.'),
        const DirectStreamDone(),
      ]),
    ).toList();

    expect(events.map(_describe), <String>[
      'reasoning:Plan',
      'tool',
      'content:Answer.',
      'done',
    ]);
  });

  test('keeps a split opening tag held across usage and metadata', () async {
    final events = await splitInlineReasoningTags(
      Stream<DirectStreamEvent>.fromIterable(<DirectStreamEvent>[
        const DirectContentDelta('Weighing <thi'),
        DirectUsageUpdate(const <String, dynamic>{'completion_tokens': 3}),
        const DirectContentDelta('nk a="1"'),
        DirectProviderMetadataUpdate(const <String, dynamic>{
          'provider': 'Lantern',
        }),
        DirectFileAnnotationsUpdate(const <Map<String, dynamic>>[]),
        const DirectSourceFound(url: 'https://ferries.example/timetable'),
        const DirectContentDelta('>the ferry times</think>It leaves at noon.'),
        const DirectStreamDone(),
      ]),
    ).toList();

    expect(events.map(_describe), <String>[
      'content:Weighing ',
      'DirectUsageUpdate',
      'DirectProviderMetadataUpdate',
      'DirectFileAnnotationsUpdate',
      'DirectSourceFound',
      'reasoning:the ferry times',
      'content:It leaves at noon.',
      'done',
    ]);
  });

  test(
    'releases held text before an error and when the stream closes',
    () async {
      final failed = await splitInlineReasoningTags(
        Stream<DirectStreamEvent>.fromIterable(<DirectStreamEvent>[
          const DirectContentDelta('Partial <th'),
          const DirectStreamError('The provider stopped.'),
        ]),
      ).toList();
      expect(failed.map(_describe), <String>[
        'content:Partial ',
        'content:<th',
        'error',
      ]);

      final closed = await splitInlineReasoningTags(
        Stream<DirectStreamEvent>.fromIterable(<DirectStreamEvent>[
          const DirectContentDelta('<think>Cut off</thi'),
        ]),
      ).toList();
      expect(closed.map(_describe), <String>[
        'reasoning:Cut off',
        'reasoning:</thi',
      ]);
    },
  );

  test('passes a stream without tags through delta for delta', () async {
    final events = await splitInlineReasoningTags(
      Stream<DirectStreamEvent>.fromIterable(<DirectStreamEvent>[
        const DirectContentDelta('\n'),
        const DirectContentDelta('  indented'),
        const DirectStreamDone(),
      ]),
    ).toList();

    expect(events.map(_describe), <String>[
      'content:\n',
      'content:  indented',
      'done',
    ]);
  });
}

String _describe(DirectStreamEvent event) => switch (event) {
  DirectContentDelta(:final content) => 'content:$content',
  DirectReasoningDelta(:final content) => 'reasoning:$content',
  DirectToolCallStarted() => 'tool',
  DirectStreamError() => 'error',
  DirectStreamDone() => 'done',
  _ => event.runtimeType.toString(),
};
