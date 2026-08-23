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

  /// Set once [applyDefaultSpeakerphoneRoute] has picked the loudspeaker but no
  /// configure pass has tried to move the route there yet. Until one does,
  /// nobody knows whether the platform will take it.
  bool _defaultRouteAwaitingConfirmation = false;

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
    _confirmDefaultSpeakerphoneRoute(
      await _configureVoiceRoute(phase: 'listening'),
    );
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
    _confirmDefaultSpeakerphoneRoute(
      await _configureVoiceRoute(phase: 'speaking'),
    );
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
    _confirmDefaultSpeakerphoneRoute(
      await _configureVoiceRoute(phase: 'barge-in-speaking'),
    );
    await _settleIosSpeakingRoute();
  }

  /// Puts the call on the current route for a configure pass, and reports
  /// whether both platforms took it.
  ///
  /// This queues behind the button and device-change reroutes because it makes
  /// the same platform calls off the same [_speakerphoneEnabled] flag. Run
  /// loose, a pass that started before a headset was pulled out can finish
  /// after the reroute and put the call back on the route it just left.
  Future<bool> _configureVoiceRoute({required String phase}) {
    return _serializeRouteChange(() async {
      final androidRouted = await _configureAndroidVoiceRoute(phase: phase);
      final iosRouted = await _configureIosVoiceRoute(phase: phase);
      return androidRouted && iosRouted;
    });
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
      _defaultRouteAwaitingConfirmation = false;
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

  /// Picks the speakerphone for a call that has no accessory to play through.
  ///
  /// Voice calls run the session in communication mode, so a phone with
  /// nothing attached routes playback to the earpiece — audible only with the
  /// handset against your head, which is not how this call is held. Start those
  /// calls on the loudspeaker instead, and leave calls with a headset, car or
  /// hearing aid connected routed to it.
  ///
  /// Only the routing preference is set here; the `configureFor*` pass that
  /// follows applies it, and [speakerphoneRouteChanges] carries the answer once
  /// it has. Call this before the first pass of a call, not after a manual
  /// toggle, or it would overwrite the user's choice.
  Future<void> applyDefaultSpeakerphoneRoute() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }
    final generation = _callGeneration;
    final attached = await _hasExternalAudioAccessory();
    if (generation != _callGeneration || _speakerphoneChosenByUser) {
      // The call ended, or the speaker button was pressed, while the scan was
      // out. Either way this answer is stale and must not resubscribe or move
      // the route.
      return;
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
      return;
    }
    _speakerphoneEnabled = true;
    _defaultRouteAwaitingConfirmation = true;
  }

  /// Reports the default route once a configure pass has tried to apply it.
  ///
  /// The session does not exist yet when the default is picked, so the route
  /// only moves on the next `configureFor*` pass. Announcing the loudspeaker
  /// before then would light the speaker button up for a route the platform
  /// still had the chance to refuse.
  void _confirmDefaultSpeakerphoneRoute(bool applied) {
    if (!_defaultRouteAwaitingConfirmation) return;
    _defaultRouteAwaitingConfirmation = false;
    if (_speakerphoneChosenByUser || _routeChangesStopped) return;
    if (!applied) {
      // The call is still on the earpiece, so the preference set above never
      // became a route. Putting the flag back lets the next device event try
      // the move again.
      _speakerphoneEnabled = false;
      return;
    }
    // A headset connected while the pass was on the wire has already moved the
    // call off the loudspeaker and said so. Announcing the default now would
    // talk over it.
    if (!_speakerphoneEnabled) return;
    if (!_speakerphoneRouteController.isClosed) {
      _speakerphoneRouteController.add(true);
    }
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

      final applied = await _applySpeakerphoneRoute(
        enabled,
        phase: 'device-change',
      );
      // The button can be pressed, the call can end, or the hardware can change
      // again while the platform calls above are still going. Publishing then
      // would leave the speaker control showing a route nobody chose; whoever
      // superseded this reroute gets to publish instead.
      if (_speakerphoneChosenByUser || _routeChangesStopped) return;
      if (_accessoryAttached != attached) return;
      if (!applied) {
        // Audio is still coming out of wherever it was. Saying otherwise would
        // point the speaker button at a route nobody is hearing, and the flag
        // is back where it was so the next device event gets another go.
        return;
      }
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
  Future<T> _serializeRouteChange<T>(Future<T> Function() change) {
    final queued = _routeSerial.then((_) => change());
    _routeSerial = queued.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'audio-route-change-failed',
          scope: 'chat/voice_audio',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
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

  /// Moves the call to [enabled] on the user's instruction and reports whether
  /// the platform took it.
  Future<bool> setSpeakerphoneEnabled(bool enabled) {
    if (_routeChangesStopped) {
      // The call is being torn down. Honouring a last-moment button press would
      // put communication mode back after the route was handed back.
      return Future<bool>.value(false);
    }
    // Set before queueing so an automatic reroute still waiting its turn sees
    // the choice and stands down.
    _speakerphoneChosenByUser = true;
    return _serializeRouteChange(
      () => _applySpeakerphoneRoute(enabled, phase: 'user-toggle'),
    );
  }

  /// Moves the call to [enabled] and reports whether the platform took it.
  ///
  /// Every route call here tolerates failure, so without an answer a refused
  /// route is indistinguishable from an applied one: the flag would read
  /// speaker while audio kept coming out of the earpiece, and the guard in
  /// [_handleAudioDevicesChanged] would drop the next identical device event as
  /// already handled rather than trying the move again.
  Future<bool> _applySpeakerphoneRoute(
    bool enabled, {
    required String phase,
  }) async {
    final previous = _speakerphoneEnabled;
    // The route configuration below reads this to pick its branch, so it has to
    // be set before the platform calls and put back if they refuse.
    _speakerphoneEnabled = enabled;
    var applied = true;
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
      applied = await _configureAndroidVoiceRoute(phase: phase);
    }
    if (!await _setIosSpeakerphoneEnabled(enabled, phase: phase)) {
      applied = false;
    }
    if (!applied) {
      _speakerphoneEnabled = previous;
    }
    return applied;
  }

  /// Points the Android call at the route [_speakerphoneEnabled] asks for, and
  /// reports whether it landed.
  Future<bool> _configureAndroidVoiceRoute({required String phase}) async {
    if (!Platform.isAndroid) {
      return true;
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

    final modeSet = await _safeAndroidRouteAction(
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
      if (routed) {
        return modeSet;
      }
      final legacyRouted = await _safeAndroidRouteAction(
        () => manager.setSpeakerphoneOn(true),
        operation: 'configure-speakerphone',
        phase: phase,
      );
      return modeSet && legacyRouted;
    }

    await _safeAndroidRouteCall(
      () => manager.setSpeakerphoneOn(false),
      operation: 'configure-speakerphone',
      phase: phase,
    );

    // Off the loudspeaker, the communication device was already cleared above,
    // so the system is sending the call to the headset or earpiece on its own.
    // Grabbing SCO is a preference on top of that, and failing to get it (a
    // wired headset, no Bluetooth at all) is not a failed reroute.
    final selected = await _selectAndroidCommunicationDevice(
      manager,
      AndroidAudioDeviceType.bluetoothSco,
      phase: phase,
    );
    if (selected) {
      return modeSet;
    }

    await _safeAndroidRouteCall(
      () async {
        await manager.startBluetoothSco();
        await manager.setBluetoothScoOn(true);
      },
      operation: 'start-bluetooth-sco',
      phase: phase,
    );
    return modeSet;
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

  /// [_safeAndroidRouteCall] for calls that answer with nothing, where a null
  /// result cannot tell a completed call from a failed one.
  Future<bool> _safeAndroidRouteAction(
    Future<void> Function() action, {
    required String operation,
    required String phase,
  }) async {
    final completed = await _safeAndroidRouteCall<bool>(
      () async {
        await action();
        return true;
      },
      operation: operation,
      phase: phase,
    );
    return completed ?? false;
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

  /// Puts the iOS session on the current route, and reports whether it took.
  Future<bool> _configureIosVoiceRoute({required String phase}) async {
    if (!Platform.isIOS) {
      return true;
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
      return _setIosSpeakerphoneEnabled(_speakerphoneEnabled, phase: phase);
    }

    final selected = payload['selected'] == true;
    DebugLogger.info(
      selected ? 'ios-bluetooth-hfp-selected' : 'ios-audio-route',
      scope: 'chat/voice_audio',
      data: _iosRouteLogData(payload, phase: phase),
    );
    return _setIosSpeakerphoneEnabled(_speakerphoneEnabled, phase: phase);
  }

  /// Overrides the iOS output port, and reports whether the session took it.
  Future<bool> _setIosSpeakerphoneEnabled(
    bool enabled, {
    required String phase,
  }) async {
    if (!Platform.isIOS) return true;
    final payload = await _safeIosRouteCall(
      () => _iosVoiceAudioRouteChannel.invokeMapMethod<Object?, Object?>(
        'setSpeakerphoneEnabled',
        <String, Object?>{'enabled': enabled},
      ),
      operation: 'set-speakerphone',
      phase: phase,
    );
    // The handler always answers with the current route and only carries an
    // `error` when overrideOutputAudioPort threw, so a missing payload means
    // the channel itself never got there.
    return payload != null && payload['error'] == null;
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
