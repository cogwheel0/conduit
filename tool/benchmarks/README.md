# Chat scrolling benchmark

Run the production timeline viewport and Markdown renderer with newly generated
synthetic messages, without connecting to a server:

```sh
flutter run --profile -t tool/benchmarks/chat_scroll.dart
```

The harness scrolls 20 viewports in each direction through 1,000 and 10,000
messages containing short paragraphs, lists, and code blocks. Each direction
lasts six seconds. It repeats each route after visiting its rows, and emits
`CHAT_SCROLL_RESULT` JSON with frame build/raster p50, p95, p99, maximum,
frame counts, height-estimation calls, row builds, and resident memory.
`CHAT_SCROLL_DONE` marks completion; the viewport remains available afterward.

Use profile mode for timings. Debug simulator builds are useful for visual
verification only. This measures the production scrolling components, not
network latency or every part of the chat page.

## Results

[Full measurements](chat_scroll_results.json) compare upstream `030a1823`
with this change on a 60 Hz Android arm64 emulator using hardware graphics and
Impeller OpenGLES, Flutter 3.47.9 / Dart 3.13.7. Run order was baseline,
candidate, candidate, baseline. No recording or other builds ran concurrently.
The ranges below are the two per-run measurements, in milliseconds.

| Warm scroll | Metric | Baseline | Candidate |
| --- | --- | --- | --- |
| 1,000 messages | Build p50 | 0.487–0.502 | 0.329–0.343 |
| 1,000 messages | Build p95 | 1.826–1.849 | 1.601–1.676 |
| 1,000 messages | Build p99 | 2.831–3.071 | 2.836–2.850 |
| 10,000 messages | Build p50 | 1.771–1.818 | 0.353–0.365 |
| 10,000 messages | Build p95 | 2.698–2.740 | 1.470–1.585 |
| 10,000 messages | Build p99 | 3.480–3.605 | 2.808–3.010 |

The 10,000-message warm scroll made 3.72–3.73 million height-estimation calls
before this change and 9,995 afterward. The remaining calls initialize the
extent index once following the harness's phase-header rebuild. A separate
steady-scroll regression test measures **373,640 → 0 calls** across 60 frames.
Both builds constructed 69 row widgets per benchmark phase. Resident memory
at the end of the warm 10,000-message phase was 312.5–313.1 MiB for baseline
and 313.3 MiB for candidate.

The CPU improvement does not establish a higher display frame rate. Emulator
raster timing varied widely in both builds, including values near one refresh
interval. Separate SurfaceFlinger actual-presentation measurements found:

| 10,000-message cold scroll | Baseline | Candidate |
| --- | --- | --- |
| Present interval p50 | 16.639–16.671 ms | 16.649–16.708 ms |
| Present interval p95 | 19.331–19.791 ms | 19.279–20.106 ms |
| Present interval p99 | 21.387–21.600 ms | 20.994–21.735 ms |
| Maximum interval | 43.217–49.225 ms | 22.522–23.856 ms |
| Intervals over 25 ms | 2 in each run | 0 in each run |

Presentation cadence and p95/p99 were broadly comparable; the candidate avoided
the baseline's longest stalls in these samples. These are emulator measurements,
not a guarantee about physical-device frame rates. The JSON includes every run's
raster timings, maxima, and counts. The device was visually checked before the
runs, and no Android ANR events occurred during any reported run.

For presentation measurements, sample `adb shell dumpsys SurfaceFlinger --latency`
for the app's SurfaceView layer once per second during an eight-second interval
inside the 10,000-message cold phase. Deduplicate the actual-present timestamps
(the second column) and compute consecutive differences, excluding phase changes.
Run this separately from recordings and the FrameTiming comparison.

## Correctness reproduction

`chat_timeline_viewport_test.dart` drives the actual painted native scrollbar
through 300 synthetic rows with deliberately inaccurate height estimates. The
upstream implementation reverses direction four times while scrolling steadily
in either direction (largest reverse movement: 24 px during an upward scroll and 16.75 px during a downward scroll).
The candidate records zero reversals in both directions.

Further regressions cover complete-history exposure in `ChatPage`, lazy row
construction, Material and Cupertino thumb dragging across 10,000 messages,
continuous dragging within one tall message, chat changes during a held drag,
animated navigation to both ends, and the existing streaming/anchor/resize
behavior.
