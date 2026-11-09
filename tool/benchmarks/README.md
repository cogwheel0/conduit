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

## Reproduce the comparison

The baseline predates this harness. The measurements used the same harness and
dependencies for both builds, restoring the two upstream chat files for the
baseline and then restoring the candidate files. Use a disposable worktree:

```sh
git fetch https://github.com/cogwheel0/conduit.git pull/993/head
git worktree add --detach ../conduit-scroll-benchmark 66994833
cd ../conduit-scroll-benchmark
git submodule update --init --recursive third_party/katex third_party/mermaid
flutter pub get
(cd packages/conduit_core && dart run build_runner build)
dart run build_runner build
flutter gen-l10n

git restore --source=0e2e000b -- \
  lib/features/chat/views/chat_page.dart \
  lib/features/chat/widgets/chat_timeline_viewport.dart
flutter build apk --profile --target-platform android-arm64 --no-pub \
  -t tool/benchmarks/chat_scroll.dart
cp build/app/outputs/flutter-apk/app-profile.apk ../conduit-scroll-baseline.apk

git restore --source=66994833 -- \
  lib/features/chat/views/chat_page.dart \
  lib/features/chat/widgets/chat_timeline_viewport.dart
flutter build apk --profile --target-platform android-arm64 --no-pub \
  -t tool/benchmarks/chat_scroll.dart
cp build/app/outputs/flutter-apk/app-profile.apk ../conduit-scroll-candidate.apk
```

Install each APK with `adb install -r`, then force-stop and relaunch
`app.cogwheel.conduit/.MainActivity` for each run. Capture the four
`CHAT_SCROLL_RESULT` records from `adb logcat` through `CHAT_SCROLL_DONE`.
Use baseline/candidate/candidate/baseline order on the same device, with no
recording, builds, or tests running alongside the measurements. The presentation
sampling procedure below runs separately from the FrameTiming comparison.

The checked-in JSON contains per-run summaries. Historical raw frame timings
and presentation timestamps were not retained, so its percentiles cannot be
recomputed from that file; rerun the harness to collect a new comparison.

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

## Repeated Markdown prewarm lookup

Run the production content cache against the previous eligibility check in one
profile-mode process, using newly invented strings without a server connection:

```sh
flutter run --profile -t tool/benchmarks/markdown_prewarm.dart
```

For each payload size, the harness checks twelve immutable assistant messages in
uncached/cached/cached/uncached order. Each run warms its lookup once, then times
100 batches. The strings have no surrounding whitespace, so this comparison
measures repeated image-marker scans without an additional trimming allocation.
`MARKDOWN_PREWARM_RESULT` reports each run's summary;
`MARKDOWN_PREWARM_SAMPLES` emits the raw batches in chunks indexed by run and
offset. `MARKDOWN_PREWARM_DONE` marks completion.

[All 1,200 raw batch samples and summaries](markdown_prewarm_results.json) were
collected on an Android arm64 emulator with Flutter 3.47.9 / Dart 3.13.7, with no
recording or concurrent builds. The ranges below span the two runs of each
variant. All values are **microseconds per twelve-message batch**.

| Payload per message | Uncached p50 | Cached p50 | Uncached p99 | Cached p99 |
| --- | --- | --- | --- | --- |
| 8 KiB | 140.125–154.000 | 0.708 | 203.334–565.375 | 0.958–1.084 |
| 128 KiB | 2,383.500–2,393.875 | 0.459 | 2,913.084–2,972.917 | 0.709–1.083 |
| 1 MiB | 19,159.917–19,261.833 | 0.459 | 19,930.250–40,619.875 | 1.000–1.125 |

The final uncached 1 MiB run had a 54,216.584 µs maximum; the preceding uncached
run's maximum was 20,728.917 µs. The raw values retain these outliers. Percentiles
use sorted sample indices 49, 94 and 98 for p50, p95 and p99 respectively.

This isolates eligibility and trimmed-content reuse, not Markdown compilation,
first-use scans, frame timing, or presentation. Every new immutable message still
pays its first scan; edits and streaming updates create new identities. Weak
identity keys allow departed messages and their cached contents to be collected.
These measurements do not establish a display frame-rate improvement.
