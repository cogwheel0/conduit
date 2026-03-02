import 'package:conduit/features/chat/voice_call/domain/call_state_machine.dart';
import 'package:conduit/features/chat/voice_call/domain/voice_call_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CallStateMachine', () {
    test('allows expected transitions', () {
      expect(
        CallStateMachine.canTransition(CallPhase.idle, CallPhase.starting),
        isTrue,
      );
      expect(
        CallStateMachine.canTransition(
          CallPhase.starting,
          CallPhase.connecting,
        ),
        isTrue,
      );
      expect(
        CallStateMachine.canTransition(
          CallPhase.connecting,
          CallPhase.listening,
        ),
        isTrue,
      );
      expect(
        CallStateMachine.canTransition(CallPhase.listening, CallPhase.thinking),
        isTrue,
      );
      expect(
        CallStateMachine.canTransition(CallPhase.thinking, CallPhase.speaking),
        isTrue,
      );
      expect(
        CallStateMachine.canTransition(CallPhase.speaking, CallPhase.listening),
        isTrue,
      );
    });

    test('rejects invalid transitions', () {
      expect(
        CallStateMachine.canTransition(CallPhase.idle, CallPhase.speaking),
        isFalse,
      );
      expect(
        CallStateMachine.canTransition(
          CallPhase.connecting,
          CallPhase.speaking,
        ),
        isFalse,
      );
      expect(
        CallStateMachine.canTransition(CallPhase.ended, CallPhase.listening),
        isFalse,
      );
      expect(
        CallStateMachine.canTransition(CallPhase.failed, CallPhase.speaking),
        isFalse,
      );
    });
  });
}
