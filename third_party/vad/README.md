# vad 0.0.8, patched

A copy of [`vad` 0.0.8](https://pub.dev/packages/vad/versions/0.0.8)
(keyur2maru/vad, MIT, see `LICENSE`) with one fix. The upstream README is
`UPSTREAM_README.md`.

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
  `finally`.
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
