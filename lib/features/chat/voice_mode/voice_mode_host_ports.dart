import 'dart:io' show Platform;

import 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/services/background_streaming_handler.dart';

/// The Flutter app's voice-call background lease, over the Pigeon
/// `BackgroundStreamingHandler` (iOS microphone/audio lease, Android
/// foreground service).
class ChatVoiceModeBackgroundCoordinator implements VoiceBackgroundPort {
  @override
  Future<void> startVoiceLease({
    required String leaseId,
    required bool requiresMicrophone,
  }) {
    return BackgroundStreamingHandler.instance.startBackgroundExecution(
      [leaseId],
      requiresMicrophone: requiresMicrophone,
      kind: BackgroundStreamKind.voice,
    );
  }

  @override
  Future<void> stopVoiceLease(String leaseId) {
    return BackgroundStreamingHandler.instance.stopBackgroundExecution([
      leaseId,
    ]);
  }

  @override
  Future<bool> keepAlive() {
    return BackgroundStreamingHandler.instance.keepAlive();
  }

  @override
  Future<void> setExternalAudioSessionOwner(bool isExternal) {
    return BackgroundStreamingHandler.instance.setExternalAudioSessionOwner(
      isExternal,
    );
  }
}

/// `dart:io`'s platform, and permission_handler for the Android 12+
/// `BLUETOOTH_CONNECT` prompt a call needs to route audio to headsets.
class FlutterVoiceModePlatform implements VoiceModePlatformPort {
  const FlutterVoiceModePlatform();

  @override
  bool get isIOS => Platform.isIOS;

  @override
  bool get isAndroid => Platform.isAndroid;

  @override
  Future<void> requestCallRoutingPermission() async {
    final status = await Permission.bluetoothConnect.status;
    if (status.isGranted) {
      return;
    }

    final requested = await Permission.bluetoothConnect.request();
    if (!requested.isGranted) {
      DebugLogger.warning(
        'bluetooth-connect-denied',
        scope: 'chat/voice_mode',
        data: {'status': requested.name},
      );
    }
  }
}
