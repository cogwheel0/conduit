/// The voice-mode controller moved to `conduit_core`, behind host ports.
/// Re-exported here so callers keep their imports; the Flutter bindings for its ports are in
/// `voice_mode_host_ports.dart` and are installed by `lib/main.dart`.
library;

export 'package:conduit_core/features/chat/voice_mode/chat_voice_mode_controller.dart';

export 'voice_mode_host_ports.dart';
