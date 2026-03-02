import 'voice_call_models.dart';

/// Pure transition helpers used by the controller and unit tests.
class CallStateMachine {
  const CallStateMachine._();

  static bool canTransition(CallPhase from, CallPhase to) {
    switch (from) {
      case CallPhase.idle:
        return to == CallPhase.starting;
      case CallPhase.starting:
        return to == CallPhase.connecting || to == CallPhase.failed;
      case CallPhase.connecting:
        return to == CallPhase.listening || to == CallPhase.failed;
      case CallPhase.listening:
        return to == CallPhase.thinking ||
            to == CallPhase.paused ||
            to == CallPhase.muted ||
            to == CallPhase.ending ||
            to == CallPhase.failed;
      case CallPhase.thinking:
        return to == CallPhase.speaking ||
            to == CallPhase.listening ||
            to == CallPhase.paused ||
            to == CallPhase.ending ||
            to == CallPhase.failed;
      case CallPhase.speaking:
        return to == CallPhase.listening ||
            to == CallPhase.paused ||
            to == CallPhase.muted ||
            to == CallPhase.ending ||
            to == CallPhase.failed;
      case CallPhase.paused:
        return to == CallPhase.listening ||
            to == CallPhase.muted ||
            to == CallPhase.ending ||
            to == CallPhase.failed;
      case CallPhase.muted:
        return to == CallPhase.listening ||
            to == CallPhase.paused ||
            to == CallPhase.ending ||
            to == CallPhase.failed;
      case CallPhase.ending:
        return to == CallPhase.ended;
      case CallPhase.ended:
        return to == CallPhase.starting;
      case CallPhase.failed:
        return to == CallPhase.starting || to == CallPhase.ending;
    }
  }
}
