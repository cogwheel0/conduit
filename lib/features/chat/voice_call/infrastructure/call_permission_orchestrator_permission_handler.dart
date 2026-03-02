import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../domain/voice_call_interfaces.dart';

/// Permission handler-based call permission preflight.
class CallPermissionOrchestratorPermissionHandler
    implements CallPermissionOrchestrator {
  const CallPermissionOrchestratorPermissionHandler();

  @override
  Future<void> ensureCallPermissions(VoiceInputEngine input) async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      throw StateError('Microphone permission is required for voice calls.');
    }

    if (Platform.isIOS) {
      final speechStatus = await Permission.speech.request();
      if (!speechStatus.isGranted) {
        throw StateError('Speech recognition permission is required on iOS.');
      }
    }

    final hasInputPermission = await input.checkPermissions();
    if (!hasInputPermission) {
      final granted = await input.requestMicrophonePermission();
      if (!granted) {
        throw StateError('Microphone permission was not granted.');
      }
    }
  }
}

final callPermissionOrchestratorProvider = Provider<CallPermissionOrchestrator>(
  (ref) {
    return const CallPermissionOrchestratorPermissionHandler();
  },
);
