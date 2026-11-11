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

Raw frame timings and presentation timestamps are not checked in; rerun the
harness to collect a new comparison.

## Results

These measurements compare upstream `0e2e000b`
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
guarantees. Each run's `CHAT_SCROLL_RESULT` line also reports raster
timings, maxima, and counts. The device was visually checked before the
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
100 batches. It runs both unpadded strings and strings with two spaces at each
end. The cached path stores only eligibility and still trims selected content.
`MARKDOWN_PREWARM_RESULT` reports each run's summary;
`MARKDOWN_PREWARM_SAMPLES` emits the raw batches in chunks indexed by run and
offset. `MARKDOWN_PREWARM_DONE` marks completion.

The 2,400 batch samples behind this table were collected on an Android arm64 emulator with Flutter 3.47.9 / Dart 3.13.7, with no
recording or concurrent builds. The ranges below span the two runs of each
variant. All values are **microseconds per twelve-message batch**.

| Payload per message | Padding | Uncached p50 | Cached p50 | Uncached p99 | Cached p99 |
| --- | --- | --- | --- | --- | --- |
| 8 KiB | None | 148.792–154.500 | 0.833–0.875 | 265.959–494.500 | 1.459–2.250 |
| 128 KiB | None | 2,434.458–2,436.500 | 0.584–0.625 | 3,026.750–3,373.792 | 0.875 |
| 1 MiB | None | 19,488.167–19,553.167 | 0.667–0.708 | 20,604.125–21,338.667 | 1.209–1.292 |
| 8 KiB | Two spaces | 170.375–191.459 | 25.792–55.458 | 214.500–583.167 | 70.042–99.125 |
| 128 KiB | Two spaces | 2,695.042–2,725.625 | 266.917–270.792 | 3,113.708–3,265.542 | 397.208–417.458 |
| 1 MiB | Two spaces | 22,174.708–22,296.875 | 3,008.584–3,091.875 | 23,484.250–24,459.875 | 3,502.958–3,578.625 |

The padded cases include temporary trimming allocations and GC. The second
cached 8 KiB run had a 394.083 µs maximum, versus 70.542 µs in its first run;
the `MARKDOWN_PREWARM_SAMPLES` output keeps these outliers. Percentiles use sorted sample indices
49, 94 and 98 for p50, p95 and p99 respectively.

This isolates eligibility and trimming, not Markdown compilation, first-use
scans, frame timing, or presentation. Every new immutable message still pays its
first scan; edits and streaming updates create new identities. Weak identity
keys allow departed messages to be collected. These measurements do not
establish a display frame-rate improvement.

## Prewarm retained memory

```sh
flutter run --profile -t tool/benchmarks/markdown_prewarm_memory.dart
```

The fixture creates 64 synthetic messages containing 1 MiB each, warms them,
and releases the messages. It forces two garbage collections after each phase
through its own VM service, then records retained Dart heap bytes. Three runs
cover each combination of padding and cache behavior. The comparison wrapper
reproduces the earlier cache's strong retention of trimmed strings under weak
identity keys; both paths use the production eligibility checks.

The measured phases include unpadded controls and the heap after releasing the messages. Padded messages previously
retained approximately **64 MiB** of additional text after warming. The
eligibility-only cache retains approximately **2.6 KiB** of metadata instead.
Trimming may still allocate temporarily, as measured above. This benchmark
measures retained Dart heap, not allocation rate, native memory, RSS, or FPS.
It connects only to its own process's VM service and never reads persisted chats
or connects to a server. `PREWARM_MEMORY_RESULT` emits each run;
`PREWARM_MEMORY_DONE` marks completion.
