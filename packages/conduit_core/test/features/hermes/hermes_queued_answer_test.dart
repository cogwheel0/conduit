import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/services/hermes_queued_answer.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

const _before = <Map<String, dynamic>>[
  {'role': 'user', 'content': 'Plan the tide walk'},
  {'role': 'assistant', 'content': 'Low tide is at four.'},
];
const _saved = <String, dynamic>{
  'role': 'user',
  'content': 'And the high tide?',
};
const _answer = <String, dynamic>{
  'role': 'assistant',
  'content': 'High tide is at ten.',
};

/// Follows [reads] one look at a time, on a fake clock, and returns what
/// came of it with the number of reads made.
(HermesQueuedAnswer?, int) _follow(
  List<Object> reads, {
  int? baseline,
  bool Function()? isCurrent,
}) {
  HermesQueuedAnswer? outcome;
  var count = 0;
  fakeAsync((async) {
    awaitHermesQueuedAnswer(
      readTranscript: () async {
        final read = reads[count < reads.length ? count : reads.length - 1];
        count++;
        if (read is Exception) throw read;
        return read as List<Map<String, dynamic>>;
      },
      isCurrent: isCurrent ?? () => true,
      baseline: baseline,
    ).then((value) => outcome = value);
    async.elapse(const Duration(minutes: 11));
  });
  return (outcome, count);
}

void main() {
  group('a saved message\'s answer', () {
    test('arrives once its rows end in the agent\'s reply', () {
      final (outcome, reads) = _follow([
        _before,
        [..._before, _saved],
        [..._before, _saved, _answer],
      ], baseline: _before.length);

      check(outcome)
          .isA<HermesQueuedAnswerArrived>()
          .has((it) => it.rows, 'rows')
          .deepEquals([_saved, _answer]);
      check(reads).equals(3);
    });

    test('is not a tool call still under way', () {
      final (outcome, _) = _follow([
        [
          ..._before,
          _saved,
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'call-1',
                'type': 'function',
                'function': {'name': 'tide_table', 'arguments': '{}'},
              },
            ],
          },
        ],
      ], baseline: _before.length);

      check(outcome).isA<HermesQueuedAnswerPending>();
    });

    test(
      'is waited for through reads that fail, from the first that works',
      () {
        final (outcome, _) = _follow([
          Exception('restarting'),
          _before,
          [..._before, _saved, _answer],
        ]);

        check(outcome)
            .isA<HermesQueuedAnswerArrived>()
            .has((it) => it.rows, 'rows')
            .deepEquals([_saved, _answer]);
      },
    );

    // Counting from the first read that worked missed an answer finished
    // before it: looks that far apart could come only after the answer.
    test('is seen when Hermes answers soon after it is back', () {
      HermesQueuedAnswer? outcome;
      fakeAsync((async) {
        awaitHermesQueuedAnswer(
          readTranscript: () async {
            final now = async.elapsed;
            if (now < const Duration(milliseconds: 10500)) {
              throw Exception('restarting');
            }
            return now < const Duration(milliseconds: 12500)
                ? _before
                : [..._before, _saved, _answer];
          },
          isCurrent: () => true,
        ).then((value) => outcome = value);
        async.elapse(const Duration(minutes: 11));
      });

      check(outcome)
          .isA<HermesQueuedAnswerArrived>()
          .has((it) => it.rows, 'rows')
          .deepEquals([_saved, _answer]);
    });

    test('is given up on after the time allowed', () {
      final (outcome, reads) = _follow([_before], baseline: _before.length);

      check(outcome).isA<HermesQueuedAnswerPending>();
      // Soon at first, then every half minute, for ten minutes.
      check(reads).isGreaterThan(15);
      check(reads).isLessThan(25);
    });

    test('is no longer looked for once the chat moved on', () {
      final (outcome, reads) = _follow(
        [_before],
        baseline: _before.length,
        isCurrent: () => false,
      );

      check(outcome).isA<HermesQueuedAnswerAbandoned>();
      check(reads).equals(0);
    });
  });
}
