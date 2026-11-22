# Direct streaming projection benchmark

A Direct answer that has a backtick or a tilde in it can't be appended
fragment by fragment, because escaping depends on the whole answer's Markdown.
So the accumulator re-renders the whole answer instead. Before, it waited each
time for the answer to double in length, so a long answer with code froze for
longer and longer stretches. Now a full projection is also due once the
previous one has been shown for 100 ms, or for its length at 200,000
characters a second if that is longer. Doubling still bounds bursts.

## Method

```sh
dart compile exe tool/benchmarks/direct_streaming_projection.dart -o /path/to/bench
/path/to/bench
```

The harness streams a newly invented answer, in four-character deltas at
2,800 characters a second on a simulated clock. The answer is prose with inline
code and fenced Python, and its first backtick comes near character 1,900.
Each size runs three times. The harness times only `apply` and
`projectStreamingEvent`, on the real clock. It prints one
`DIRECT_STREAMING_PROJECTION` JSON line per run. The worst visible gap is the
longest simulated time between two updates.

Dart native AOT on an M-series Mac, with other builds running on the machine.
These are CPU measurements, not phone frame times. The range covers all three
runs.

## Results

| Answer | Build | Full projections | Characters rendered | Projection work | Worst single call | Worst visible gap |
| --- | --- | --- | --- | --- | --- | --- |
| 30,751 chars, 11.0 s | before | 5 | 30,064 | 10.4–12.9 ms | 5.5–5.9 ms | 2,863 ms |
| 30,751 chars, 11.0 s | after | 97 | 1,491,016 | 535–542 ms | 10.8–11.1 ms | 153 ms |
| 204,800 chars, 73.1 s | before | 8 | 254,512 | 89–94 ms | 44–46 ms | 22,903 ms |
| 204,800 chars, 73.1 s | after | 233 | 14,048,088 | 5,040–5,147 ms | 72.6–80.4 ms | 1,009 ms |

Rendering costs about 0.36 µs a character here, so the budget costs about 7%
of one core while a long answer with code streams. A single render of a
200,000-character answer takes 70–80 ms. In the app that runs on the UI
isolate.
