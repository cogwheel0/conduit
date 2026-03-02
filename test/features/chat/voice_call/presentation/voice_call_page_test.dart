import 'package:conduit/features/chat/views/voice_call_page.dart';
import 'package:conduit/features/chat/voice_call/application/voice_call_controller.dart';
import 'package:conduit/features/chat/voice_call/domain/voice_call_models.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows listening controls with mute and end actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceCallControllerProvider.overrideWith(
            _FakeVoiceCallController.new,
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const VoiceCallPage(),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('Mute'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.pause_fill), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.phone_down_fill), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class _FakeVoiceCallController extends VoiceCallController {
  @override
  VoiceCallSnapshot build() {
    return const VoiceCallSnapshot(phase: CallPhase.listening);
  }

  @override
  Future<void> start({required bool startNewConversation}) async {}

  @override
  Future<void> stop({CallEndReason reason = CallEndReason.user}) async {}

  @override
  Future<void> pause({CallPauseReason reason = CallPauseReason.user}) async {
    state = state.copyWith(phase: CallPhase.paused);
  }

  @override
  Future<void> resume({CallPauseReason reason = CallPauseReason.user}) async {
    state = state.copyWith(phase: CallPhase.listening);
  }

  @override
  Future<void> toggleMute() async {
    final muted = !state.isMuted;
    state = state.copyWith(
      isMuted: muted,
      phase: muted ? CallPhase.muted : CallPhase.listening,
    );
  }

  @override
  Future<void> cancelAssistantSpeech() async {}
}
