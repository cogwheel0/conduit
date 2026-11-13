import 'package:conduit_core/features/chat/read_aloud/device_speech_engine.dart';
import 'package:conduit_core/features/chat/read_aloud/tts_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../core/services/background_streaming_handler.dart';
import '../features/chat/services/native_tts_service.dart';

/// Gives the core's read-aloud manager what only the app can reach: the
/// device engine over platform channels, `path_provider`'s temporary
/// directory for server speech, and the background task that keeps it
/// playing. Installed before the manager is first used, by `main.dart` and
/// `test/flutter_test_config.dart`.
void installReadAloudHost() {
  DeviceSpeechEngine.hostFactory = NativeTtsService.new;
  TemporaryFileClipStore.temporaryDirectory = getTemporaryDirectory;
  TtsManager.beginBackgroundLease = (leaseId) =>
      BackgroundStreamingHandler.instance.startBackgroundExecution([leaseId]);
  TtsManager.endBackgroundLease = (leaseId) =>
      BackgroundStreamingHandler.instance.stopBackgroundExecution([leaseId]);
}
