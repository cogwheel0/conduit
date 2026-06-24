import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/debug_logger.dart';

class ChatVoiceAudioSessionCoordinator {
  static const Duration _iosSpeakingRouteSettleDelay = Duration(
    milliseconds: 160,
  );
  static const MethodChannel _iosVoiceAudioRouteChannel = MethodChannel(
    'app.cogwheel.conduit/voice_audio_route',
  );

  AudioSession? _session;
  AndroidAudioManager? _androidAudioManager;
  AndroidAudioHardwareMode? _previousAndroidMode;
  bool? _previousAndroidSpeakerphone;

  Future<AudioSession> _ensureSession() async {
    final session = _session;
    if (session != null) {
      return session;
    }
    final created = await AudioSession.instance;
    _session = created;
    return created;
  }

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
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
        androidWillPauseWhenDucked: false,
      ),
      'listening',
    );
    await _setActive(session, active: true, phase: 'listening');
    await _configureAndroidVoiceRoute(phase: 'listening');
    await _configureIosVoiceRoute(phase: 'listening');
  }

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
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
        androidWillPauseWhenDucked: false,
      ),
      'speaking',
    );
    await _setActive(session, active: true, phase: 'speaking');
    await _configureAndroidVoiceRoute(phase: 'speaking');
    await _configureIosVoiceRoute(phase: 'speaking');
    await _settleIosSpeakingRoute();
  }

  Future<void> configureForBargeInSpeaking() async {
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
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
        androidWillPauseWhenDucked: false,
      ),
      'barge-in-speaking',
    );
    await _setActive(session, active: true, phase: 'barge-in-speaking');
    await _configureAndroidVoiceRoute(phase: 'barge-in-speaking');
    await _configureIosVoiceRoute(phase: 'barge-in-speaking');
    await _settleIosSpeakingRoute();
  }

  Future<void> deactivate() async {
    final session = _session;
    try {
      await _clearIosVoiceRoute();
      if (session != null) {
        await _setActive(session, active: false, phase: 'deactivate');
      }
    } finally {
      await _restoreAndroidVoiceRoute();
    }
  }

  Future<void> _configureAndroidVoiceRoute({required String phase}) async {
    if (!Platform.isAndroid) {
      return;
    }

    final manager = _androidAudioManager ??= AndroidAudioManager();

    _previousAndroidMode ??= await _safeAndroidRouteCall(
      () => manager.getMode(),
      operation: 'get-mode',
      phase: phase,
    );
    _previousAndroidSpeakerphone ??= await _safeAndroidRouteCall(
      () => manager.isSpeakerphoneOn(),
      operation: 'get-speakerphone',
      phase: phase,
    );

    await _safeAndroidRouteCall(
      () => manager.setMode(AndroidAudioHardwareMode.inCommunication),
      operation: 'set-in-communication',
      phase: phase,
    );
    await _safeAndroidRouteCall(
      () => manager.setSpeakerphoneOn(false),
      operation: 'disable-speakerphone',
      phase: phase,
    );

    final selected = await _selectBluetoothScoCommunicationDevice(
      manager,
      phase: phase,
    );
    if (selected) {
      return;
    }

    await _safeAndroidRouteCall(
      () async {
        await manager.startBluetoothSco();
        await manager.setBluetoothScoOn(true);
      },
      operation: 'start-bluetooth-sco',
      phase: phase,
    );
  }

  Future<bool> _selectBluetoothScoCommunicationDevice(
    AndroidAudioManager manager, {
    required String phase,
  }) async {
    final devices = await _safeAndroidRouteCall(
      () => manager.getAvailableCommunicationDevices(),
      operation: 'get-communication-devices',
      phase: phase,
    );
    if (devices == null) {
      return false;
    }

    for (final device in devices) {
      if (device.type != AndroidAudioDeviceType.bluetoothSco) {
        continue;
      }

      final selected = await _safeAndroidRouteCall(
        () => manager.setCommunicationDevice(device),
        operation: 'set-communication-device',
        phase: phase,
        data: {'deviceId': device.id, 'deviceType': device.type.toString()},
      );
      if (selected == true) {
        return true;
      }
    }
    return false;
  }

  Future<void> _restoreAndroidVoiceRoute() async {
    if (!Platform.isAndroid) {
      return;
    }

    final manager = _androidAudioManager;
    if (manager == null) {
      return;
    }

    await _safeAndroidRouteCall(
      () => manager.clearCommunicationDevice(),
      operation: 'clear-communication-device',
      phase: 'deactivate',
    );
    await _safeAndroidRouteCall(
      () async {
        await manager.setBluetoothScoOn(false);
        await manager.stopBluetoothSco();
      },
      operation: 'stop-bluetooth-sco',
      phase: 'deactivate',
    );

    final previousSpeakerphone = _previousAndroidSpeakerphone;
    if (previousSpeakerphone != null) {
      await _safeAndroidRouteCall(
        () => manager.setSpeakerphoneOn(previousSpeakerphone),
        operation: 'restore-speakerphone',
        phase: 'deactivate',
      );
    }

    final previousMode = _previousAndroidMode;
    if (previousMode != null) {
      await _safeAndroidRouteCall(
        () => manager.setMode(previousMode),
        operation: 'restore-mode',
        phase: 'deactivate',
      );
    }

    _previousAndroidMode = null;
    _previousAndroidSpeakerphone = null;
  }

  Future<T?> _safeAndroidRouteCall<T>(
    Future<T> Function() action, {
    required String operation,
    required String phase,
    Map<String, Object?> data = const <String, Object?>{},
  }) async {
    try {
      return await action();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'android-audio-route-$operation-failed',
        scope: 'chat/voice_audio',
        error: error,
        stackTrace: stackTrace,
        data: {'phase': phase, ...data},
      );
      return null;
    }
  }

  Future<void> _configureIosVoiceRoute({required String phase}) async {
    if (!Platform.isIOS) {
      return;
    }

    final payload = await _safeIosRouteCall(
      () => _iosVoiceAudioRouteChannel.invokeMapMethod<Object?, Object?>(
        'preferBluetoothHfpInput',
      ),
      operation: 'prefer-bluetooth-hfp-input',
      phase: phase,
    );
    if (payload == null) {
      return;
    }

    final selected = payload['selected'] == true;
    DebugLogger.info(
      selected ? 'ios-bluetooth-hfp-selected' : 'ios-audio-route',
      scope: 'chat/voice_audio',
      data: _iosRouteLogData(payload, phase: phase),
    );
  }

  Future<void> _clearIosVoiceRoute() async {
    if (!Platform.isIOS) {
      return;
    }

    final payload = await _safeIosRouteCall(
      () => _iosVoiceAudioRouteChannel.invokeMapMethod<Object?, Object?>(
        'clearPreferredInput',
      ),
      operation: 'clear-preferred-input',
      phase: 'deactivate',
    );
    if (payload == null) {
      return;
    }

    DebugLogger.info(
      'ios-audio-route-cleared',
      scope: 'chat/voice_audio',
      data: _iosRouteLogData(payload, phase: 'deactivate'),
    );
  }

  Future<void> _settleIosSpeakingRoute() async {
    if (!Platform.isIOS) {
      return;
    }
    await Future<void>.delayed(_iosSpeakingRouteSettleDelay);
  }

  Future<Map<Object?, Object?>?> _safeIosRouteCall(
    Future<Map<Object?, Object?>?> Function() action, {
    required String operation,
    required String phase,
  }) async {
    try {
      return await action();
    } on MissingPluginException {
      DebugLogger.warning(
        'ios-audio-route-bridge-missing',
        scope: 'chat/voice_audio',
        data: {'operation': operation, 'phase': phase},
      );
      return null;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'ios-audio-route-$operation-failed',
        scope: 'chat/voice_audio',
        error: error,
        stackTrace: stackTrace,
        data: {'phase': phase},
      );
      return null;
    }
  }

  Map<String, Object?> _iosRouteLogData(
    Map<Object?, Object?> payload, {
    required String phase,
  }) {
    return {
      'phase': phase,
      'selected': payload['selected'],
      'cleared': payload['cleared'],
      'reason': payload['reason'],
      'error': payload['error'],
      'category': payload['category'],
      'mode': payload['mode'],
      'preferred': _iosPortSummary(payload['preferredInput']),
      'inputs': _iosPortsSummary(payload['currentInputs']),
      'outputs': _iosPortsSummary(payload['currentOutputs']),
      'available': _iosPortsSummary(payload['availableInputs']),
    };
  }

  String _iosPortsSummary(Object? ports) {
    if (ports is! List) {
      return '';
    }
    return ports
        .map(_iosPortSummary)
        .where((port) => port.isNotEmpty)
        .join(',');
  }

  String _iosPortSummary(Object? port) {
    if (port is! Map) {
      return '';
    }
    final type = port['type']?.toString() ?? 'unknown';
    return type;
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
          'Ignoring iOS audio session configure failure during $phase: $error',
          name: 'chat_voice_audio_session',
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
          name: 'chat_voice_audio_session',
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
}

final chatVoiceAudioSessionCoordinatorProvider =
    Provider<ChatVoiceAudioSessionCoordinator>((ref) {
      return ChatVoiceAudioSessionCoordinator();
    });
