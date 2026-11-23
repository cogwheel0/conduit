# Direct streaming projection benchmark

A Direct answer that has a backtick or a tilde in it can't be appended
fragment by fragment, because escaping depends on the whole answer's Markdown.
The accumulator renders it in full once, at the first code delimiter. After
that, the answer tail cursor (`packages/conduit_core/lib/services/answer_tail_cursor.dart`)
extends it wherever it proves a delta renders the same as the full escaper
would. A delta it refuses waits for the next full projection. One is due once
the payload has doubled, or once the previous one has been shown for 100 ms,
or for its length at 200,000 characters a second if that is longer. Before,
only doubling applied, so a long answer with code froze for longer and longer
stretches.

## Method

```sh
dart compile exe tool/benchmarks/direct_streaming_projection.dart -o /path/to/bench
/path/to/bench
```

The harness streams newly invented answers, in four-character deltas at 2,800
characters a second on a simulated clock. Each answer opens with plain prose,
and its first backtick comes near character 1,900. There are two shapes:

- **fences**: prose with inline code and fenced Python.
- **tutorial**: headings, numbered steps that hold indented fences, nested
  bullets, a table with inline code, comparisons, an autolink and an unmatched
  backtick.

Each case runs three times. The harness times only `apply` and
`projectStreamingEvent`, on the real clock, and prints one
`DIRECT_STREAMING_PROJECTION` JSON line per run. The worst visible gap is the
longest simulated time between two updates.

Dart native AOT on an M-series Mac, with other builds running on the machine.
These are CPU measurements, not phone frame times. Ranges cover the three
runs. The three builds are main before the fix (`6c935585ca`), the time
ceiling alone (`186a1f316c`), and the time ceiling plus the cursor.

## Results

| Answer | Build | Full projections | Appends | Characters rendered | Projection work | Worst single call | Worst visible gap |
| --- | --- | --- | --- | --- | --- | --- | --- |
| fences, 30,751 chars | before | 5 | 499 | 30,064 | 12.1–13.1 ms | 6.5–6.6 ms | 2,863 ms |
| fences, 30,751 chars | time ceiling | 97 | 499 | 1,491,016 | 564–604 ms | 11.5–12.0 ms | 153 ms |
| fences, 30,751 chars | with cursor | 2 | 7,686 | 2,008 | 7.4–9.3 ms | 0.17–0.40 ms | 1.4 ms |
| tutorial, 30,751 chars | before | 5 | 504 | 31,221 | 18.3–20.9 ms | 11.2–12.2 ms | 2,891 ms |
| tutorial, 30,751 chars | time ceiling | 95 | 504 | 1,486,526 | 934–937 ms | 20.3–21.8 ms | 156 ms |
| tutorial, 30,751 chars | with cursor | 84 | 4,488 | 1,320,764 | 792–797 ms | 17.7–18.1 ms | 156 ms |
| fences, 204,800 chars | before | 8 | 499 | 254,512 | 96–99 ms | 47–48 ms | 22,903 ms |
| fences, 204,800 chars | time ceiling | 233 | 499 | 14,048,088 | 5,244–5,438 ms | 77–94 ms | 1,009 ms |
| fences, 204,800 chars | with cursor | 2 | 51,198 | 2,008 | 48.9–49.3 ms | 0.17–0.18 ms | 1.4 ms |
| tutorial, 204,800 chars | before | 8 | 504 | 266,509 | 172–176 ms | 87–91 ms | 23,131 ms |
| tutorial, 204,800 chars | time ceiling | 227 | 504 | 14,098,310 | 9,427–10,087 ms | 141–170 ms | 1,049 ms |
| tutorial, 204,800 chars | with cursor | 215 | 14,033 | 13,774,184 | 8,725–9,671 ms | 135–167 ms | 994 ms |

The tutorial answers with the cursor also spliced their last line 78 and 207
times. The cursor refused 83 and 214 deltas. All the refusals come from one
construct: a nested bullet indented four spaces outside a fence that has `<`,
`>` or `&` in it, such as `    - south when the tide is > 2 m`. The cursor
can't tell whether the parser keeps that line as indented code or as list
text. So each such line costs a full render at the next ceiling, and on that
shape the work stays near the time ceiling's budget. That is about 0.6 µs a
character, or 7–13% of one core.
