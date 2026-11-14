// The read-aloud manager lives in conduit_core
// (features/chat/read_aloud/tts_manager.dart), so the desktop's daemon runs
// the same sessions, queue and state machine. The app installs its device
// engine, temporary directory and background lease at startup (main.dart).
export 'package:conduit_core/features/chat/read_aloud/tts_manager.dart';
