import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/providers/app_providers.dart';
import '../../../../../core/services/navigation_service.dart';
import '../../voice_mode/chat_voice_mode_controller.dart';
import '../voice_call_eligibility.dart';

/// Unified launcher for all voice-call entry points.
class VoiceCallLauncher {
  VoiceCallLauncher(this._ref);

  final Ref _ref;

  Future<void> launch({required bool startNewConversation}) async {
    final eligibility = await resolveVoiceCallEligibility(_ref);
    if (!eligibility.canStart) {
      throw StateError(eligibility.errorMessage!);
    }

    final socketService = _ref.read(socketServiceProvider);
    if (socketService != null && !socketService.isConnected) {
      unawaited(socketService.connect());
    }

    if (NavigationService.currentRoute != Routes.chat) {
      await NavigationService.navigateToChat();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final result = await _ref
        .read(chatVoiceModeControllerProvider.notifier)
        .start(
          startNewConversation: startNewConversation,
          admittedModel: eligibility.model!,
        );
    final snapshot = _ref.read(chatVoiceModeControllerProvider);
    if (result == ChatVoiceModeStartResult.failed || !snapshot.isActive) {
      throw StateError(
        snapshot.errorMessage ?? 'Unable to start a voice call.',
      );
    }
  }
}

final voiceCallLauncherProvider = Provider<VoiceCallLauncher>((ref) {
  return VoiceCallLauncher(ref);
});
