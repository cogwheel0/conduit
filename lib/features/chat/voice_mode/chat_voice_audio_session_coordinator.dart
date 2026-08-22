// audio_session marks its device-enumeration API experimental; it is the only
// way to see what is plugged in without a second native bridge.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
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

  /// Device types that give a call somewhere to play other than the phone
  /// itself. Built-in earpiece, speaker and microphone are deliberately absent.
  ///
  /// So are A2DP and AirPlay. A voice call runs the session in communication
  /// mode, which cannot route to either, so a device offering only those is not
  /// somewhere the call can play. Headsets that also speak HFP still show up
  /// here as [AudioDeviceType.bluetoothSco].
  static const Set<AudioDeviceType> _externalAudioAccessoryTypes = {
    AudioDeviceType.wiredHeadset,
    AudioDeviceType.wiredHeadphones,
    AudioDeviceType.headsetMic,
    AudioDeviceType.bluetoothSco,
    AudioDeviceType.bluetoothLe,
    AudioDeviceType.usbAudio,
    AudioDeviceType.hearingAid,
    AudioDeviceType.carAudio,
    AudioDeviceType.dock,
    AudioDeviceType.lineAnalog,
    AudioDeviceType.lineDigital,
    AudioDeviceType.hdmi,
    AudioDeviceType.hdmiArc,
  };

  AudioSession? _session;
  AndroidAudioManager? _androidAudioManager;
  AndroidAudioHardwareMode? _previousAndroidMode;
  bool? _previousAndroidSpeakerphone;
  bool _speakerphoneEnabled = false;
  bool _speakerphoneChosenByUser = false;
  bool? _accessoryAttached;
  bool _routeChangesStopped = false;

  /// Bumped by every teardown so work started for an earlier call can tell that
  /// it came back too late.
  int _callGeneration = 0;
  Future<void> _routeSerial = Future<void>.value();
  StreamSubscription<Set<AudioDevice>>? _devicesSub;
  final StreamController<bool> _speakerphoneRouteController =
      StreamController<bool>.broadcast();

  /// Speakerphone changes this coordinator made on its own, so callers can keep
  /// their own view of the route in step. Manual toggles are not reported: the
  /// caller already knows about those.
  Stream<bool> get speakerphoneRouteChanges =>
      _speakerphoneRouteController.stream;

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
            AVAudioSessionCategoryOptions.allowBluetooth,
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
            AVAudioSessionCategoryOptions.allowBluetooth,
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
            AVAudioSessionCategoryOptions.allowBluetooth,
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
    _callGeneration++;
    final session = _session;
    final devicesSub = _devicesSub;
    _devicesSub = null;
    _routeChangesStopped = true;
    try {
      await devicesSub?.cancel();
      // Let any reroute already on the wire finish before tearing the route
      // down, so the teardown is not the thing that gets interleaved.
      await _routeSerial;
      await _clearIosVoiceRoute();
      if (session != null) {
        await _setActive(session, active: false, phase: 'deactivate');
      }
    } finally {
      await _restoreAndroidVoiceRoute();
      _speakerphoneEnabled = false;
      _speakerphoneChosenByUser = false;
      _accessoryAttached = null;
      _routeChangesStopped = false;
    }
  }

  Future<void> dispose() async {
    _callGeneration++;
    final devicesSub = _devicesSub;
    _devicesSub = null;
    _routeChangesStopped = true;
    await devicesSub?.cancel();
    await _routeSerial;
    await _speakerphoneRouteController.close();
  }

  /// Whether the call can play through [device] in preference to the phone's
  /// own speaker. A plugged-in microphone is not somewhere to play.
  static bool _isPlayableAccessory(AudioDevice device) =>
      device.isOutput && _externalAudioAccessoryTypes.contains(device.type);

  /// Whether [type] is an accessory a call should play through in preference
  /// to the phone's own speaker.
  @visibleForTesting
  static bool isExternalAudioAccessory(AudioDeviceType type) =>
      _externalAudioAccessoryTypes.contains(type);

  /// Picks the speakerphone for a call that has no accessory to play through,
  /// and reports whether it did.
  ///
  /// Voice calls run the session in communication mode, so a phone with
  /// nothing attached routes playback to the earpiece — audible only with the
  /// handset against your head, which is not how this call is held. Start those
  /// calls on the loudspeaker instead, and leave calls with a headset, car or
  /// hearing aid connected routed to it.
  ///
  /// Only the routing preference is set here; the `configureFor*` pass that
  /// follows applies it. Call this before the first pass of a call, not after a
  /// manual toggle, or it would overwrite the user's choice.
  Future<bool> applyDefaultSpeakerphoneRoute() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return false;
    }
    final generation = _callGeneration;
    final attached = await _hasExternalAudioAccessory();
    if (generation != _callGeneration || _speakerphoneChosenByUser) {
      // The call ended, or the speaker button was pressed, while the scan was
      // out. Either way this answer is stale and must not resubscribe or move
      // the route.
      return false;
    }

    _accessoryAttached = attached;
    // Subscribing re-reads the device list and delivers it, so anything plugged
    // in or pulled out during the scan above arrives as the first event and
    // corrects this snapshot.
    _watchAudioDevices();
    if (attached != false) {
      // A failed scan says nothing about what is plugged in, and playing an
      // answer out of the loudspeaker over someone's headset is worse than
      // leaving the route alone.
      return false;
    }
    _speakerphoneEnabled = true;
    return true;
  }

  /// Keeps the default following the hardware for the rest of the call:
  /// headphones pulled out mid-answer should not drop the call back to the
  /// earpiece, and a headset connected mid-call should take playback back off
  /// the loudspeaker.
  void _watchAudioDevices() {
    if (_devicesSub != null) {
      return;
    }
    final session = _session;
    if (session == null) {
      return;
    }
    _devicesSub = session.devicesStream.listen(
      (devices) => unawaited(_handleAudioDevicesChanged(devices)),
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'audio-device-watch-failed',
          scope: 'chat/voice_audio',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  @visibleForTesting
  Future<void> handleAudioDevicesChangedForTesting(Set<AudioDevice> devices) =>
      _handleAudioDevicesChanged(devices);

  Future<void> _handleAudioDevicesChanged(Set<AudioDevice> devices) async {
    if (_speakerphoneChosenByUser || _routeChangesStopped) {
      // Someone pressed the speaker button, or the call is over. Either way the
      // hardware no longer gets a vote.
      return;
    }

    final attached = devices.any(_isPlayableAccessory);
    if (attached == _accessoryAttached) {
      return;
    }
    // Claim the transition before the first await so a burst of events (a
    // headset announcing its A2DP and SCO ends separately) reroutes once.
    _accessoryAttached = attached;

    final enabled = !attached;

    DebugLogger.info(
      'audio-accessory-changed',
      scope: 'chat/voice_audio',
      data: {'attached': attached, 'speakerphone': enabled},
    );
    await _serializeRouteChange(() async {
      // Re-read everything this reroute assumed: while it waited its turn the
      // user may have pressed the speaker button, the call may have ended, or a
      // later event may have already put the route where it belongs.
      if (_speakerphoneChosenByUser || _routeChangesStopped) return;
      if (_accessoryAttached != attached) return;
      if (enabled == _speakerphoneEnabled) return;

      await _applySpeakerphoneRoute(enabled, phase: 'device-change');
      // The button can be pressed, or the call can end, while the platform
      // calls above are still going. Publishing then would leave the speaker
      // control showing a route nobody chose.
      if (_speakerphoneChosenByUser || _routeChangesStopped) return;
      if (!_speakerphoneRouteController.isClosed) {
        _speakerphoneRouteController.add(enabled);
      }
    });
  }

  /// Runs route changes one at a time.
  ///
  /// Rerouting is several platform calls deep, so two of them running together
  /// interleave and the loser gets the last word. Queueing keeps the newest
  /// decision the one that sticks.
  Future<void> _serializeRouteChange(Future<void> Function() change) {
    final queued = _routeSerial.then((_) => change());
    _routeSerial = queued.catchError((Object error, StackTrace stackTrace) {
      DebugLogger.error(
        'audio-route-change-failed',
        scope: 'chat/voice_audio',
        error: error,
        stackTrace: stackTrace,
      );
    });
    return queued;
  }

  /// Whether an audio accessory is attached, or null when the scan failed.
  Future<bool?> _hasExternalAudioAccessory() async {
    try {
      final session = await _ensureSession();
      final devices = await session.getDevices();
      final accessories = devices
          .where(_isPlayableAccessory)
          .map((device) => device.type.name)
          .toSet();
      DebugLogger.info(
        'audio-accessory-scan',
        scope: 'chat/voice_audio',
        data: {
          'accessories': accessories.join(','),
          'deviceCount': devices.length,
        },
      );
      return accessories.isNotEmpty;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'audio-accessory-scan-failed',
        scope: 'chat/voice_audio',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> setSpeakerphoneEnabled(bool enabled) {
    if (_routeChangesStopped) {
      // The call is being torn down. Honouring a last-moment button press would
      // put communication mode back after the route was handed back.
      return Future<void>.value();
    }
    // Set before queueing so an automatic reroute still waiting its turn sees
    // the choice and stands down.
    _speakerphoneChosenByUser = true;
    return _serializeRouteChange(
      () => _applySpeakerphoneRoute(enabled, phase: 'user-toggle'),
    );
  }

  Future<void> _applySpeakerphoneRoute(
    bool enabled, {
    required String phase,
  }) async {
    _speakerphoneEnabled = enabled;
    if (Platform.isAndroid) {
      final manager = _androidAudioManager ??= AndroidAudioManager();
      // Release the currently selected communication device before re-routing:
      // setCommunicationDevice replaces the route, but leaving SCO running
      // keeps the headset owning playback after switching to the speaker.
      await _safeAndroidRouteCall(
        () => manager.clearCommunicationDevice(),
        operation: 'clear-communication-device',
        phase: phase,
      );
      await _safeAndroidRouteCall(
        () async {
          await manager.setBluetoothScoOn(false);
          await manager.stopBluetoothSco();
        },
        operation: 'stop-bluetooth-sco',
        phase: phase,
      );
      await _configureAndroidVoiceRoute(phase: phase);
    }
    await _setIosSpeakerphoneEnabled(enabled, phase: phase);
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
    if (_speakerphoneEnabled) {
      // setSpeakerphoneOn is deprecated and is a no-op on Android 12+ once a
      // communication device is selected, so route to the built-in speaker
      // explicitly and keep the legacy call only as the pre-31 fallback.
      final routed = await _selectAndroidCommunicationDevice(
        manager,
        AndroidAudioDeviceType.builtInSpeaker,
        phase: phase,
      );
      if (!routed) {
        await _safeAndroidRouteCall(
          () => manager.setSpeakerphoneOn(true),
          operation: 'configure-speakerphone',
          phase: phase,
        );
      }
      return;
    }

    await _safeAndroidRouteCall(
      () => manager.setSpeakerphoneOn(false),
      operation: 'configure-speakerphone',
      phase: phase,
    );

    final selected = await _selectAndroidCommunicationDevice(
      manager,
      AndroidAudioDeviceType.bluetoothSco,
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

  Future<bool> _selectAndroidCommunicationDevice(
    AndroidAudioManager manager,
    AndroidAudioDeviceType type, {
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
      if (device.type != type) {
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

    final payload = _speakerphoneEnabled
        ? null
        : await _safeIosRouteCall(
            () => _iosVoiceAudioRouteChannel.invokeMapMethod<Object?, Object?>(
              'preferBluetoothHfpInput',
            ),
            operation: 'prefer-bluetooth-hfp-input',
            phase: phase,
          );
    if (payload == null) {
      await _setIosSpeakerphoneEnabled(_speakerphoneEnabled, phase: phase);
      return;
    }

    final selected = payload['selected'] == true;
    DebugLogger.info(
      selected ? 'ios-bluetooth-hfp-selected' : 'ios-audio-route',
      scope: 'chat/voice_audio',
      data: _iosRouteLogData(payload, phase: phase),
    );
    await _setIosSpeakerphoneEnabled(_speakerphoneEnabled, phase: phase);
  }

  Future<void> _setIosSpeakerphoneEnabled(
    bool enabled, {
    required String phase,
  }) async {
    if (!Platform.isIOS) return;
    await _safeIosRouteCall(
      () => _iosVoiceAudioRouteChannel.invokeMapMethod<Object?, Object?>(
        'setSpeakerphoneEnabled',
        <String, Object?>{'enabled': enabled},
      ),
      operation: 'set-speakerphone',
      phase: phase,
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
      final coordinator = ChatVoiceAudioSessionCoordinator();
      ref.onDispose(() => unawaited(coordinator.dispose()));
      return coordinator;
    });
