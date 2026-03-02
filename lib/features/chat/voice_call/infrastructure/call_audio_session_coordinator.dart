import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/voice_call_interfaces.dart';

/// Coordinates audio-session transitions between listening and speaking.
class CallAudioSessionCoordinatorDefault
    implements CallAudioSessionCoordinator {
  AudioSession? _session;

  Future<AudioSession> _ensureSession() async {
    final session = _session;
    if (session != null) {
      return session;
    }
    final created = await AudioSession.instance;
    _session = created;
    return created;
  }

  Future<void> _configureSession(
    AudioSession session,
    AudioSessionConfiguration configuration,
    String phase,
  ) async {
    try {
      await session.configure(configuration);
    } catch (error, stackTrace) {
      if (_shouldIgnoreAudioSessionError(error)) {
        developer.log(
          'Ignoring iOS audio session configure failure during $phase: '
          '$error',
          name: 'voice_call_audio_session',
          level: 900,
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> _setActive(
    AudioSession session, {
    required bool active,
    required String phase,
  }) async {
    try {
      await session.setActive(active);
    } catch (error, stackTrace) {
      if (_shouldIgnoreAudioSessionError(error)) {
        developer.log(
          'Ignoring iOS audio session activation failure during $phase '
          '(active=$active): $error',
          name: 'voice_call_audio_session',
          level: 900,
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }
      rethrow;
    }
  }

  bool _shouldIgnoreAudioSessionError(Object error) {
    if (!Platform.isIOS || error is! PlatformException) {
      return false;
    }
    final code = error.code.toString();
    final message = (error.message ?? '').toLowerCase();
    return code == '-12988' ||
        message.contains('session activation failed') ||
        message.contains('session deactivation failed');
  }

  @override
  Future<void> configureForListening() async {
    final session = await _ensureSession();
    await _configureSession(
      session,
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.defaultToSpeaker,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions:
            AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
        androidWillPauseWhenDucked: false,
      ),
      'listening',
    );
    await _setActive(session, active: true, phase: 'listening');
  }

  @override
  Future<void> configureForSpeaking() async {
    final session = await _ensureSession();
    await _configureSession(
      session,
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.defaultToSpeaker,
        avAudioSessionMode: AVAudioSessionMode.spokenAudio,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions:
            AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType:
            AndroidAudioFocusGainType.gainTransientMayDuck,
        androidWillPauseWhenDucked: false,
      ),
      'speaking',
    );
    await _setActive(session, active: true, phase: 'speaking');
  }

  @override
  Future<void> deactivate() async {
    final session = _session;
    if (session == null) {
      return;
    }
    await _setActive(session, active: false, phase: 'deactivate');
  }
}

final callAudioSessionCoordinatorProvider =
    Provider<CallAudioSessionCoordinator>((ref) {
      return CallAudioSessionCoordinatorDefault();
    });
