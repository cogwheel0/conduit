## 0.0.8

* Add `onLog` callback to `VadHandler.create` for routing production log lines to consumer-side telemetry (Crashlytics, Sentry, Bugsnag, etc.) without zone or `debugPrint` overrides
  - API: Add optional `VadLogCallback? onLog` parameter to `VadHandler.create`
  - API: Add `VadLogCallback` typedef (`void Function(String message)`) exported from `package:vad/vad.dart`
  - Core: Thread `onLog` through `VadIterator.create` → `VadInference.create` → native/web inference factories → Silero v4/v5 models
  - Coverage: Route all non-debug failure log lines through the callback when provided — model session-creation errors (native + web), inference errors, frame-processing errors, audio-stream and microphone-permission failures
  - Behavior: When `onLog` is null, log lines continue to go to `print`/logcat as before. Verbose `if (isDebug) print(...)` state-transition logs are intentionally **not** routed through the callback
* Add always-on breadcrumb log immediately before each ONNX Runtime session creation on native platforms
  - Native: Emit `VadModel: creating OrtSession (model=... path=... bytes=... sampleRate=... intraOp=... interOp=... os=... osVersion=...)` from both `SileroV4Model.create` and `SileroV5Model.create`
  - Diagnostics: Lands in logcat as the last line before any native crash inside `libonnxruntime.so`, so crash reports always carry the context needed to diagnose device-specific failures (especially on low-end 32-bit `armeabi-v7a` Android devices)
  - Enrich the catch-block error message with the same context fields and stack trace
* Documentation
  - README: Document the new `onLog` parameter on `VadHandler.create`
  - README: Add a "Reporting Issues" troubleshooting section with `adb logcat` capture instructions and a Crashlytics/Sentry/Bugsnag wiring example for `onLog`

## 0.0.7+1

* Apply dart format to all files to meet pub.dev static analysis requirements

## 0.0.7

* Add Android 16KB page size support
  - Android: Bump ONNX Runtime to 1.22.0 which includes native 16KB page size support
  - Android: All native libraries (`libonnxruntime.so`, `libonnxruntime4j_jni.so`) are now properly aligned for 16KB page sizes
  - Android: Plugin is now fully compatible with Android 15+ devices and Google Play's 16KB page size requirement
* **BREAKING CHANGE:** Asset management changes - models now loaded from CDN by default
  - Core: Remove bundled assets from package to reduce package size
  - Core: Introduce companion NPM package `@keyurmaru/vad` to host ONNX model files via jsDelivr CDN
  - Core: Update `baseAssetPath` and `onnxWASMBasePath` parameters to default to CDN URLs (can be overridden for offline/self-hosted use)
  - Core: Delete `lib/assets` directory and its contents
  - Migration: For offline support, download model files and set `baseAssetPath` parameter in `startListening()`
* **BREAKING CHANGE:** Model identifier renamed from 'legacy' to 'v4'
  - API: Rename model parameter value from 'legacy' to 'v4' for clarity
  - Migration: Update `model: 'legacy'` to `model: 'v4'` in `startListening()` calls
* Internal architectural refactor to unify cross-platform implementation
  - Internal: Remove platform-specific internal classes (`VadHandlerWeb`, `VadHandlerNonWeb`, `VadIteratorWeb`, `VadIteratorNonWeb`)
  - Internal: Remove internal abstract base classes (`VadHandlerBase`, `VadIteratorBase`)
  - Internal: Introduce `VadInference` abstraction layer as platform split point
  - Core: Use `record` package for cross-platform audio capture, replacing custom web audio implementation
  - Example: Rename `RecordingModel` enum to `VadModel` in example app
* Internal native implementation overhauled with FFI for better performance
  - Internal: Replace `onnxruntime` package dependency with direct FFI-based implementation
  - Internal: Add ONNX Runtime C API headers and generate Dart bindings using `ffigen`
  - Internal: Create Dart wrappers for ONNX structs (`OrtEnv`, `OrtSession`, `OrtValue`)
  - Internal: Implement `OrtIsolateSession` to run native inference in separate isolate
  - Internal: Restructure `lib/` into `core` and `platform` directories
  - Internal: Introduce abstract `VadModel` class to unify inference logic
* Add desktop platform support (Windows, macOS, Linux)
  - Platform: Add build configurations for Windows, macOS, and Linux desktop applications
  - Platform: Bundle pre-compiled x64 and arm64 ONNX Runtime binaries for Windows and Linux
  - Platform: Add CMakeLists.txt for each desktop platform to handle binary packaging
  - Platform: Add macOS podspec with dependency on `onnxruntime-objc` pod
  - Platform: Update Dart FFI bindings to dynamically detect OS and CPU architecture at runtime
  - Example: Add macOS example app
  - Example: Add Linux example app
* Rewrite web VAD implementation in pure Dart
  - Web: Remove pre-compiled JavaScript bridge (vad_web.js, bundle.min.js)
  - Web: Implement pure Dart web support using `dart:js_interop` to directly communicate with onnxruntime-web
  - Web: Add `MicVAD` class in `lib/src/web/audio_node_vad.dart` to manage audio pipeline using `AudioContext` and dynamically generated `AudioWorkletProcessor`
  - Web: Add typed wrappers for `onnxruntime-web` in `lib/src/web/onnx_runtime_web.dart`
  - Web: Add ScriptProcessorNode fallback from AudioWorklet for better browser compatibility (older browsers and non-secure contexts)
* **BREAKING CHANGE:** `onEmitChunk` stream type changed to include `isFinal` flag
  - API: Change `onEmitChunk` from `Stream<List<double>>` to `Stream<({List<double> samples, bool isFinal})>`
  - API: Add `onEmitChunk` stream for real-time audio chunk emission during active speech
  - API: Add `isFinal` flag to mark the last chunk of a speech utterance
  - API: Add `numFramesToEmit` parameter to `startListening()` to enable chunking (default: 0, disabled)
  - API: Add `endSpeechPadFrames` parameter to `startListening()` to control audio padding at speech end (default: 1 for v4, 3 for v5)
  - Core: Update `VadIterator` implementations to manage frame buffers and emit chunk events periodically and at speech end
  - Example: Update example app to demonstrate chunk emission feature with playback UI for individual chunks
  - Migration: Update listeners from `vadHandler.onEmitChunk.listen((samples) { ... })` to `vadHandler.onEmitChunk.listen((chunk) { final samples = chunk.samples; final isFinal = chunk.isFinal; ... })`
* Network model loading support
  - Core: Update native implementation to support loading models from network URLs using `HttpClient`
* Fix Android audio playback interference with VAD detection
  - Example: Change audio player configuration to use `AndroidUsageType.media` instead of `voiceCommunication`
  - Example: Add `AndroidAudioFocus.gainTransientMayDuck` to prevent recorder from receiving `AUDIOFOCUS_LOSS` when playing back recordings
  - Example: Allow continuous speech detection during playback without requiring manual stop/start
* Fix iOS minimum version requirement
  - Platform: Correct minimum iOS version from 16.0 to 15.1 in `vad.podspec` to align with `onnxruntime-objc` dependency support
  - Example: Update iOS example app configuration to match 15.1 minimum deployment target
* Use forked `record` dependency for macOS echo cancellation fix
  - Dependencies: Temporarily override `record` and `record_macos` packages to point to git repository with echo cancellation fix
  - Dependencies: Will be removed once fix is merged into official release
* Modernize example app build configurations
  - Example: Migrate Android Gradle scripts from Groovy to Kotlin DSL (.kts)
  - Example: Upgrade Gradle wrapper from 8.3 to 8.12
  - Example: Bump Java compatibility to version 11
  - Example: Update Android package name to `com.example.vad_example`
  - Example: Clean up iOS Podfile, removing obsolete settings
  - Example: Update Xcode project files to match new dependencies
* Update package metadata
  - Pubspec: Add `homepage` and `issue_tracker` fields
* Example: Expose `RecordConfig` from `record` package for detailed audio input configuration
* Example: Update dependencies
  - Bump `permission_handler` to latest version
  - Bump `audioplayers` to latest version
* Add support for custom audio streams
  - API: Add optional `Stream<Uint8List>? audioStream` parameter to `startListening()` method
  - Core: Allow users to provide their own audio stream instead of using the built-in recorder
  - Core: When custom stream is provided, VadHandler bypasses internal AudioRecorder setup
  - Core: Custom stream should provide PCM16 audio data at 16kHz sample rate, mono channel
  - Example: Add `CustomAudioStreamProvider` demonstration class using the `record` library
  - Example: Add "Use Custom Audio Stream" toggle in settings dialog
  - Example: Automatically configure `manageAudioSession: false` when custom stream is used
  - Use case: Enables advanced scenarios like custom recording configurations, audio from non-microphone sources, or integration with existing audio pipelines
* Fix AudioRecorder disposal and recreation issue
  - Core: Change `_audioRecorder` from final to nullable field to allow recreation after disposal
  - Core: Add logic to recreate AudioRecorder instance in `startListening()` if it was previously disposed
  - Core: Prevent "Recorder has already been disposed" error when restarting after stop
  - Core: Properly set `_audioRecorder` to null after disposal in both `stopListening()` and `dispose()` methods

## 0.0.6

* **BREAKING CHANGE:** Convert all VAD APIs to async Future-based methods for better async/await support
  - API: Convert `startListening()`, `stopListening()`, `pauseListening()`, and `dispose()` methods in `VadHandlerBase` to return `Future<void>`
  - Web: Update `VadHandlerWeb` implementation to use async method signatures
  - Non-Web: Update `VadHandlerNonWeb` implementation to use async method signatures and properly await internal async operations
  - Example: Update example app to use async/await pattern when calling VAD methods
* introduce `pauseListening` feature
  - API: Add `pauseListening()` to `VadHandlerBase`.
  - Web: implement `pauseListeningImpl()` in `vad_web.js` and expose via JS bindings.
  - Non-Web: add `_isPaused` flag in `VadHandlerNonWeb`; ignore incoming frames when paused; if `submitUserSpeechOnPause` is true, call `forceEndSpeech()`.
  - Start/Stop: reset `_isPaused` in `startListening()`; guard `vadInstance` in `stopListeningImpl()` with null-check and log.
* Add pause/resume UI functionality to example app
  - Example: Add dynamic pause button that appears only while actively listening
  - Example: Transform start button to "Resume" when paused, calling `startListening()` to resume
  - Example: Hide pause button when paused state is active
  - Example: Add separate stop button (red) available in both listening and paused states
  - Example: Implement proper state management for `isListening` and `isPaused` tracking
* Add support for custom `RecordConfig` parameter in `startListening()` for non-web platforms
  - API: Add optional `RecordConfig? recordConfig` parameter to `startListening()` in `VadHandlerBase`.
  - Non-Web: Use custom `RecordConfig` if provided, otherwise fall back to default configuration with 16kHz sample rate, PCM16 encoding, echo cancellation, auto gain, and noise suppression.
  - Web: Accept the parameter for compatibility but ignore it (not applicable for web platform).
* Bump `record` package to version 6.0.0
* Example: Bump `permission_handler` package to version 12.0.0+1
* Example: Bump `audioplayers` package to version 6.5.0

## 0.0.5

* Add support for Silero VAD v5 model. (Default model is set to v4)
* Automatically upsample audio to 16kHz if the input audio is not 16kHz (fixes model load failures due to lower sample rates).
* Expose `onRealSpeechStart` event to notify when the number of speech positive frames exceeds the minimum speech frames (i.e. not a misfire event).
* Expose `onFrameProcessed` event to track VAD decisions by exposing speech probabilities and frame data for real-time processing.
* Update example app to show the `onRealSpeechStart` callback in action and introduce VAD Settings dialog to change the VAD model and other settings at runtime.
* For web platform, bundle the required files within the package to avoid download failures when fetching from CDNs and to ensure offline support.
* Update example app to log `onFrameProcessed` details for debugging.

## 0.0.4

* Fixed a bug where default `modelPath` was not picked up, resulting in silent failure if `modelPath` was not provided.
* Export `VadIterator` class for manual control over the VAD process for non-streaming use cases. Only available on iOS/Android.
* Added comments for all public methods and classes.

## 0.0.3

* Switch to `onnxruntime` package for inference on a separate isolate on iOS and Android to avoid using a full browser in the background, overall reducing the app size and improving performance.
* Example app will show audio track slider with controls while speech segment is being played and it will reflect a misfire event on the UI if occurred.

## 0.0.2

* Fix broken LICENSE hyperlink in README.md and add topics to pubspec.yaml

## 0.0.1

* Initial release
