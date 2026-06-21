import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'notification_sound_service.g.dart';

/// Foreground notification cue.
///
/// Open WebUI plays a bundled `notification.mp3`; Conduit ships no such asset
/// yet, so v1 uses a haptic cue (system-notification sound is handled by the
/// Android channel / iOS `presentSound` on the background path). Swapping in a
/// designer-provided sound via `just_audio` (already a dependency) is a
/// follow-up — keep this the single place that owns the foreground cue.
class NotificationSoundService {
  const NotificationSoundService();

  Future<void> play() async {
    await HapticFeedback.mediumImpact();
  }
}

@Riverpod(keepAlive: true)
NotificationSoundService notificationSoundService(Ref ref) =>
    const NotificationSoundService();
