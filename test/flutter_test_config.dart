import 'dart:async';

import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit/platform/flutter_flush_scheduler.dart';
import 'package:conduit/platform/flutter_post_frame_scheduler.dart';
import 'package:conduit/platform/just_audio_playback.dart';
import 'package:conduit/platform/record_audio_capture.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/platform/flutter_log_sink.dart';
import 'package:conduit_core/conduit_core.dart';

/// Runs before every `flutter test` file.
///
/// `DebugLogger` has no destination of its own — the host
/// installs one. `main.dart` does that for the app; without this, tests would
/// silently stop logging, and the ones that assert on throttled log output
/// (chat_timeline_render_model_test) would have nothing to observe.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  DebugLogger.sink = const FlutterLogSink();
  // PreferencesStore takes its backing store from the host.
  // Tests used to get `SharedPreferences.getInstance()` implicitly, served by
  // the plugin's own mock; installing the adapter here keeps that true
  // everywhere instead of in each of the 30-odd files that rely on it.
  PreferencesStore.installLoader(FlutterKeyValueStore.load);
  // Streaming flushes go through a FlushScheduler. The test
  // binding does have frames, so tests get the app's frame-callback version
  // rather than the core's default: several of them pin the fact that a
  // flush lands inside the pump that requested it, and would pass for the
  // wrong reason under a microtask.
  FlushScheduler.hostDefault = const FlutterFlushScheduler();
  // Same reasoning: a socket connect deferred to a microtask instead of a
  // post-frame callback lands before any pump, which tests can observe.
  PostFrameScheduler.hostDefault = const FlutterPostFrameScheduler();
  // TtsManager is a process-lifetime singleton, so its player is built
  // once from this factory. Installing the real one keeps the suite on
  // the same code path the app uses.
  AudioPlaybackPort.hostFactory = JustAudioPlayback.new;
  // This one is load-bearing: VoiceInputService used to default to the
  // record-backed client, and the core's default reports no microphone
  // at all, which would take every voice test down a 'cannot listen'
  // path it was never meant to exercise.
  AudioCapturePort.hostFactory = RecordAudioCapture.new;
  await testMain();
}
