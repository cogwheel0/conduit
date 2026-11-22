# vad 0.0.8, patched

A copy of [`vad` 0.0.8](https://pub.dev/packages/vad/versions/0.0.8)
(keyur2maru/vad, MIT, see `LICENSE`) with a few fixes, listed below. The
upstream README is `UPSTREAM_README.md`.

## What changed

`SileroV5Model.process` (native) now gives Silero v5 the last 64 samples of
the previous frame in front of each 512-sample frame, and `resetState`
forgets them. The new `SileroV5Context` in
`lib/src/platform/native/inference/silero_v5_context.dart` holds them.

Smaller changes:

- Native memory leaked on every frame (about 2.2 KB, or 4 MB per minute of
  listening). `SileroV5Model.process` and `SileroV4Model.process` now
  release the output tensors `OrtSession.run` hands them, after copying
  their values, and `run` frees the name strings it allocates, in a
  `finally`. Native handles across `SileroV5Model`, `SileroV4Model`,
  `OrtSession`, `OrtValueTensor`, `OrtTensorTypeAndShapeInfo`, `OrtStatus`,
  and `OrtEnv.init` (`logId` UTF-8 string) are released in `try/finally`
  blocks so error paths cannot leak native allocations
  (cogwheel0/conduit#895).
- Per-frame Dart and FFI allocation churn on the hot path is eliminated:
  `VadIterator` buffers PCM16 bytes in a reusable `Uint8List`, decodes
  straight into `Float32List`, emits an unmodifiable `Float32List` view on
  `frameProcessed`, and skips per-frame timestamp string formatting unless
  `isDebug` is true. `OrtEnv` caches `.asFunction()` FFI bindings and the
  default allocator's `OrtMemoryInfo`, `OrtValueTensor` adds typed
  `Float32List`/`Int64List` input and flat float output paths, and
  `SileroV5Model`/`SileroV4Model` reuse flat `Float32List` state tensors,
  the sample-rate tensor, and `OrtPreparedRun` (`OrtRunOptions` and native
  UTF-8 name arrays) across frames (cogwheel0/conduit#895).
- `VadIterator.withInference` (and exporting `VadInference`/`VadModel` from
  `lib/vad.dart`) exposes dependency injection so pure-Dart unit tests can
  exercise framing and lifecycle without loading native ONNX Runtime.
- `VadIterator._combineFrames` and `VadHandler`'s speech-end and chunk
  events convert audio straight into typed lists (`Int16List`,
  `Float64List`) instead of through boxed lists, which for a ten-minute
  recording cost hundreds of MB at once.
- `pubspec.yaml` declares `record: ^7.1.1`, the version Conduit builds
  against, so the app no longer needs a `record` override.

## Why

Silero v5 expects that context: the reference implementation
(snakers4/silero-vad, `OnnxWrapper`) prepends it on every call. 0.0.8 sends
bare frames. Without the context the model's scores fall with input level,
so quiet speech reads as silence. Server dictation then stopped while people
were still talking and cut their last words from the recording
(cogwheel0/conduit#752). Conduit bundles the official v5.1 model
(`assets/vad/silero_vad_v5.onnx`).

## What was left out

Only what Conduit builds from is here: `lib/`, and the Android and iOS
plugin files. The pub package's prebuilt onnxruntime libraries for Linux and
Windows (about 60 MB), its macOS podspec, example, images, model copies and
ffigen headers are not copied, and `pubspec.yaml` declares only Android,
iOS and web. The web model (`lib/src/platform/web/`) is unchanged; Conduit
does not build for the web.

## Updating

If upstream ships the context fix, delete this directory and depend on the
published package again.
