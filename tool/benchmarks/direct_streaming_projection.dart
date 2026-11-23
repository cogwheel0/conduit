// Run with `dart run tool/benchmarks/direct_streaming_projection.dart`.
// For timing, compile to an executable with `dart compile exe` first.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';

const _prose =
    'The lighthouse keeper counts gulls on the north rocks each morning and '
    'writes the tally beside the tide table. ';
const _code =
    'Call `tally.add(count)` once per survey, then print the totals:\n\n'
    '```python\n'
    'def summarize(tallies: list[int]) -> dict[str, int]:\n'
    '    return {"max": max(tallies), "sum": sum(tallies)}\n'
    '\n'
    'if counts and counts[0] < 3 and "rocks" in notes:\n'
    '    print(summarize(counts))\n'
    '```\n\n';

// A tutorial-shaped section: a heading, a numbered list whose steps hold
// indented fences, nested bullets, a table with inline code, comparisons,
// links and an unmatched backtick.
const _tutorial =
    '## Counting gulls with `tally`\n\n'
    'Each survey adds one row. Keep `count < 500` per rock, see '
    '<https://example.test/tally?rock=north&day=1> for the format.\n\n'
    '1. Install the `tally` package:\n'
    '   ```sh\n'
    '   pip install tally --index <mirror>\n'
    '   ```\n'
    '2. Record the counts:\n\n'
    '   ```python\n'
    '   for rock in rocks:\n'
    '       tally.add(rock, counts[rock] & 0xff)\n'
    '   ```\n\n'
    '- Rocks to skip:\n'
    '    - `south` when the tide is > 2 m\n'
    '    - `east` after dusk\n\n'
    '| Rock | Call | Limit |\n'
    '|---|---|---|\n'
    '| north | `add(n)` | < 500 |\n'
    '| west | `add(w, late=True)` | <= 200 |\n\n'
    'Press the ` key to toggle the view, then compare a <b>bold</b> tally '
    'with ~~struck~~ ones & move on.\n\n';

/// A newly invented answer of [size] characters whose first code fence starts
/// near character 1,900, like the answer measured on the simulator. The
/// tutorial shape repeats [_tutorial] after the same plain opening.
String _answer(int size, {required bool tutorial}) {
  final out = StringBuffer();
  while (out.length < 1900) {
    out.write(_prose);
  }
  var unit = 0;
  while (out.length < size) {
    out.write(tutorial ? _tutorial : (unit.isEven ? _code : _prose * 6));
    unit += 1;
  }
  return out.toString().substring(0, size);
}

void main(List<String> args) {
  // About 2,800 characters a second, the steady rate measured on the
  // simulator, in four-character tokens.
  const charsPerSecond = 2800;
  const tokenLength = 4;
  final results = <Map<String, Object>>[];
  for (final (size, tutorial) in [
    (30751, false),
    (30751, true),
    (204800, false),
    (204800, true),
  ]) {
    final answer = _answer(size, tutorial: tutorial);
    for (var run = 0; run < 3; run++) {
      var simulatedMicros = 0;
      final accumulator = withClock(
        Clock(() => DateTime.fromMicrosecondsSinceEpoch(simulatedMicros)),
        DirectStreamingAccumulator.new,
      );
      final work = Stopwatch();
      var lastUpdateMicros = 0;
      var worstGapMicros = 0;
      var worstProjectionMicros = 0;
      var updates = 0;
      var first = true;
      for (var offset = 0; offset < answer.length; offset += tokenLength) {
        final end = offset + tokenLength > answer.length
            ? answer.length
            : offset + tokenLength;
        simulatedMicros = (end * 1000000) ~/ charsPerSecond;
        final event = DirectContentDelta(answer.substring(offset, end));
        withClock(
          Clock(() => DateTime.fromMicrosecondsSinceEpoch(simulatedMicros)),
          () {
            final before = work.elapsedMicroseconds;
            work.start();
            accumulator.apply(event);
            final projection = accumulator.projectStreamingEvent(
              event,
              forceReplace: first,
              canAppend: true,
            );
            work.stop();
            final spent = work.elapsedMicroseconds - before;
            if (spent > worstProjectionMicros) worstProjectionMicros = spent;
            first = false;
            if (projection != null) {
              updates += 1;
              final gap = simulatedMicros - lastUpdateMicros;
              if (gap > worstGapMicros) worstGapMicros = gap;
              lastUpdateMicros = simulatedMicros;
            }
          },
        );
      }
      results.add({
        'size': size,
        'shape': tutorial ? 'tutorial' : 'fences',
        'run': run,
        'updates': updates,
        'fullProjections': accumulator.fullProjectionCount,
        'appendProjections': accumulator.appendProjectionCount,
        'tailRewrites': accumulator.tailRewriteCount,
        'cursorRefusals': accumulator.cursorRefusalCount,
        'fullProjectionCharacters': accumulator.fullProjectionCharacterCount,
        'projectionWorkMs': work.elapsedMicroseconds / 1000,
        'worstSingleCallMs': worstProjectionMicros / 1000,
        'worstVisibleGapMs': worstGapMicros / 1000,
        'streamSeconds': simulatedMicros / 1000000,
      });
    }
  }
  for (final result in results) {
    print('DIRECT_STREAMING_PROJECTION ${jsonEncode(result)}');
  }
}
