import 'package:conduit_core/voice/voice_session.dart';
import 'package:test/test.dart';

/// These predicates decide what the voice UI offers the user, and until the
/// model moved into the core they could only be exercised through a Flutter
/// controller. Pinned exhaustively over every phase, so a phase added later
/// has to make a deliberate choice about each one rather than inheriting
/// whatever the `_ =>` arm happens to do.
void main() {
  group('isActive', () {
    test('every phase is active except idle, ended and error', () {
      const inactive = {
        ChatVoiceModePhase.idle,
        ChatVoiceModePhase.ended,
        ChatVoiceModePhase.error,
      };

      for (final phase in ChatVoiceModePhase.values) {
        final snapshot = ChatVoiceModeSnapshot(phase: phase);
        expect(snapshot.isActive, !inactive.contains(phase), reason: '$phase');
      }
    });

    test('ending still counts as active', () {
      // Teardown is in progress but the session has not finished, so the UI
      // must keep showing it. The `_ =>` arm is what makes this true, which
      // is exactly why it is pinned.
      const snapshot = ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.ending);
      expect(snapshot.isActive, isTrue);
    });
  });

  group('canPause / canResume', () {
    test('only a turn in flight can be paused', () {
      const pausable = {
        ChatVoiceModePhase.listening,
        ChatVoiceModePhase.sending,
        ChatVoiceModePhase.speaking,
      };

      for (final phase in ChatVoiceModePhase.values) {
        expect(
          ChatVoiceModeSnapshot(phase: phase).canPause,
          pausable.contains(phase),
          reason: '$phase',
        );
      }
    });

    test('only a paused or muted session can be resumed', () {
      const resumable = {ChatVoiceModePhase.paused, ChatVoiceModePhase.muted};

      for (final phase in ChatVoiceModePhase.values) {
        expect(
          ChatVoiceModeSnapshot(phase: phase).canResume,
          resumable.contains(phase),
          reason: '$phase',
        );
      }
    });

    test('no phase is both pausable and resumable', () {
      for (final phase in ChatVoiceModePhase.values) {
        final snapshot = ChatVoiceModeSnapshot(phase: phase);
        expect(
          snapshot.canPause && snapshot.canResume,
          isFalse,
          reason: '$phase offers both, so the UI has no single action',
        );
      }
    });

    test('starting offers neither, so the UI has nothing to toggle', () {
      const snapshot = ChatVoiceModeSnapshot(
        phase: ChatVoiceModePhase.starting,
      );
      expect(snapshot.canPause, isFalse);
      expect(snapshot.canResume, isFalse);
      expect(snapshot.isActive, isTrue);
    });
  });

  group('copyWith', () {
    test('carries every field through untouched', () {
      final original = ChatVoiceModeSnapshot(
        phase: ChatVoiceModePhase.speaking,
        transcript: 'what the user said',
        assistantPreview: 'what it is saying',
        spokenResponse: 'spoken so far',
        spokenWordStart: 3,
        spokenWordEnd: 7,
        intensity: 42,
        elapsed: const Duration(seconds: 9),
        startedAt: DateTime.utc(2026, 1, 1),
        activeCallId: 'call-1',
        errorMessage: 'boom',
        isCollapsed: true,
        isMuted: true,
        isSpeakerphoneEnabled: true,
      );

      final copy = original.copyWith();

      expect(copy.phase, original.phase);
      expect(copy.transcript, original.transcript);
      expect(copy.assistantPreview, original.assistantPreview);
      expect(copy.spokenResponse, original.spokenResponse);
      expect(copy.spokenWordStart, original.spokenWordStart);
      expect(copy.spokenWordEnd, original.spokenWordEnd);
      expect(copy.intensity, original.intensity);
      expect(copy.elapsed, original.elapsed);
      expect(copy.startedAt, original.startedAt);
      expect(copy.activeCallId, original.activeCallId);
      expect(copy.errorMessage, original.errorMessage);
      expect(copy.isCollapsed, original.isCollapsed);
      expect(copy.isMuted, original.isMuted);
      expect(copy.isSpeakerphoneEnabled, original.isSpeakerphoneEnabled);
    });

    test('a phase change leaves the rest of the session alone', () {
      const original = ChatVoiceModeSnapshot(
        phase: ChatVoiceModePhase.listening,
        transcript: 'half a sentence',
        isMuted: true,
      );

      final next = original.copyWith(phase: ChatVoiceModePhase.sending);

      expect(next.phase, ChatVoiceModePhase.sending);
      expect(next.transcript, 'half a sentence');
      expect(next.isMuted, isTrue);
    });
  });
}
