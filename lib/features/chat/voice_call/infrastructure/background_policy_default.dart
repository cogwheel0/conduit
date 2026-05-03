import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../../core/services/background_streaming_handler.dart';
import '../../services/voice_call_notification_service.dart';
import '../domain/voice_call_interfaces.dart';

/// Default implementation of [CallBackgroundPolicy].
class CallBackgroundPolicyDefault implements CallBackgroundPolicy {
  static const String _voiceCallStreamId = 'voice-call';

  final VoiceCallNotificationService _notifications;

  CallBackgroundPolicyDefault({VoiceCallNotificationService? notifications})
    : _notifications = notifications ?? VoiceCallNotificationService();

  @override
  Future<void> initialize() => _notifications.initialize();

  @override
  Future<void> requestNotificationPermissionIfNeeded() async {
    final enabled = await _notifications.areNotificationsEnabled();
    if (!enabled) {
      await _notifications.requestPermissions();
    }
  }

  @override
  Future<void> startBackgroundExecution({required bool requiresMicrophone}) {
    return BackgroundStreamingHandler.instance.startBackgroundExecution(
      const [_voiceCallStreamId],
      requiresMicrophone: requiresMicrophone,
      kind: BackgroundStreamKind.voice,
    );
  }

  @override
  Future<void> stopBackgroundExecution() {
    return BackgroundStreamingHandler.instance.stopBackgroundExecution(const [
      _voiceCallStreamId,
    ]);
  }

  @override
  Future<bool> keepAlive() => BackgroundStreamingHandler.instance.keepAlive();

  @override
  Future<void> setScreenAwake(bool enabled) {
    return enabled ? WakelockPlus.enable() : WakelockPlus.disable();
  }

  @override
  Future<void> updateOngoingCallNotification({
    required String modelName,
    required bool isMuted,
    required bool isSpeaking,
    required bool isPaused,
    required bool show,
  }) {
    if (!show) {
      return cancelCallNotification();
    }
    return _notifications.updateCallStatus(
      modelName: modelName,
      isMuted: isMuted,
      isSpeaking: isSpeaking,
      isPaused: isPaused,
    );
  }

  @override
  Future<void> cancelCallNotification() => _notifications.cancelNotification();
}

final callBackgroundPolicyProvider = Provider<CallBackgroundPolicy>((ref) {
  return CallBackgroundPolicyDefault();
});
