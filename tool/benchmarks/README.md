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

[Full measurements](chat_scroll_results.json) compare upstream `0e2e000b`
with `66994833` on a 60 Hz Android arm64 emulator using hardware graphics and
Impeller OpenGLES, Flutter 3.47.9 / Dart 3.13.7. Run order was baseline,
candidate, candidate, baseline. No recording or other builds ran concurrently.
The ranges below are the two per-run measurements, in milliseconds.

| Warm scroll | Metric | Baseline | Candidate |
| --- | --- | --- | --- |
| 1,000 messages | Build p50 | 0.335–0.351 | 0.314–0.328 |
| 1,000 messages | Build p95 | 1.546–1.610 | 1.526–1.626 |
| 1,000 messages | Build p99 | 2.673–2.952 | 2.687–2.884 |
| 10,000 messages | Build p50 | 0.812–0.991 | 0.321–0.328 |
| 10,000 messages | Build p95 | 1.879–2.085 | 1.640–1.662 |
| 10,000 messages | Build p99 | 3.058–3.232 | 2.712–2.995 |

The 10,000-message warm scroll made 3.69–3.72 million height-estimation calls
before this change and 9,995 afterward. The remaining calls initialize the
extent index once following the harness's phase-header rebuild. A separate
steady-scroll regression test measures **373,640 → 0 calls** across 60 frames.
Both builds constructed 69 row widgets per benchmark phase. Resident memory
at the end of the warm 10,000-message phase was 312.6 MiB for baseline
and 314.8–314.9 MiB for candidate.

The CPU improvement does not establish a higher display frame rate. Emulator
raster timing varied widely in both builds: the 1,000-message warm phases had
195/236 frames over 16.67 ms in baseline runs 1/4 versus 0/0 in candidate runs
2/3, while the 10,000-message warm phases had 2/0 in baseline versus 52/143 in
candidate. Raster p95 ranged from 1.794 to 19.048 ms across these warm phases.
Separate SurfaceFlinger actual-presentation measurements found:

| 10,000-message cold scroll | Baseline | Candidate |
| --- | --- | --- |
| Present interval p50 | 16.676–16.678 ms | 16.647–16.691 ms |
| Present interval p95 | 18.647–19.504 ms | 19.585–20.755 ms |
| Present interval p99 | 21.319–23.036 ms | 21.214–23.195 ms |
| Maximum interval | 23.562–51.124 ms | 36.226–49.161 ms |
| Intervals over 25 ms | 0 / 2 | 1 / 4 |

Median and p99 presentation intervals overlap; candidate p95 is slightly higher
and maximum intervals are mixed. These samples do not demonstrate a sustained
frame-rate improvement. They are emulator measurements, not physical-device
guarantees. The JSON includes every run's
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
