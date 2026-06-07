import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/providers/app_providers.dart';
import '../../../../../core/services/navigation_service.dart';
import '../../../auth/providers/unified_auth_providers.dart';
import '../../voice_mode/chat_voice_mode_controller.dart';

/// Unified launcher for all voice-call entry points.
class VoiceCallLauncher {
  VoiceCallLauncher(this._ref);

  final Ref _ref;

  Future<void> launch({required bool startNewConversation}) async {
    final navState = _ref.read(authNavigationStateProvider);
    if (navState != AuthNavigationState.authenticated) {
      throw StateError('Sign in to start a voice call.');
    }

    final model = _ref.read(selectedModelProvider);
    if (model == null) {
      throw StateError('Choose a model before starting a voice call.');
    }

    final socketService = _ref.read(socketServiceProvider);
    if (socketService != null && !socketService.isConnected) {
      unawaited(socketService.connect());
    }

    if (NavigationService.currentRoute != Routes.chat) {
      await NavigationService.navigateToChat();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    await _ref
        .read(chatVoiceModeControllerProvider.notifier)
        .start(startNewConversation: startNewConversation);
  }
}

final voiceCallLauncherProvider = Provider<VoiceCallLauncher>((ref) {
  return VoiceCallLauncher(ref);
});
