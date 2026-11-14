import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Mirrors the three Open WebUI-aligned notification prefs (the master
/// toggle, sound, sound always) to the server for cross-device parity. Only
/// the values passed are written.
///
/// Call it after the local setting was stored: a failed sync only loses the
/// parity, not the setting, so it is logged and never thrown. Does nothing
/// without an Open WebUI account ([api] null).
Future<void> syncNotificationPrefsToServer(
  ApiService? api, {
  bool? enabled,
  bool? sound,
  bool? soundAlways,
}) async {
  if (api == null) return;
  if (enabled == null && sound == null && soundAlways == null) return;
  try {
    await api.updateUserNotificationSettings(
      notificationEnabled: enabled,
      notificationSound: sound,
      notificationSoundAlways: soundAlways,
    );
  } catch (e, st) {
    DebugLogger.error(
      'failed to sync notification prefs to server',
      error: e,
      stackTrace: st,
      scope: 'notifications/settings',
    );
  }
}
