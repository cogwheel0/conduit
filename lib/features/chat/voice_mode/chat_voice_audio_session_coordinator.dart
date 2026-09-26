// audio_session marks its device-enumeration API experimental; it is the only
// way to see what is plugged in without a second native bridge.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/utils/debug_logger.dart';

/// What a route change got from the platform: whether it took, and whether
/// the call is on the built-in loudspeaker as far as the platform says. The
/// read-back is null when the platform could not be asked.
typedef _RouteOutcome = ({bool applied, bool? loudspeaker});

class ChatVoiceAudioSessionCoordinator {
  static const Duration _iosSpeakingRouteSettleDelay = Duration(
    milliseconds: 160,
  );
  static const MethodChannel _iosVoiceAudioRouteChannel = MethodChannel(
    'app.cogwheel.conduit/voice_audio_route',
  );
  static ChatVoiceAudioSessionCoordinator? _iosFailureHandlerOwner;

  /// The configuration the shared session goes back to once a call is over.
  ///
  /// It is the fallback audio_session hands just_audio when nothing has
  /// configured the session, so everything that plays after a call finds the
  /// session as it was before the first one. Leaving the call configuration in
  /// place kept iOS in play-and-record, whose default output is the earpiece,
  /// and kept just_audio on Android copying voice-communication attributes:
  /// read-aloud, server TTS and the notes player all came out of the earpiece
  /// until the app restarted (issue #716).
  @visibleForTesting
  static const AudioSessionConfiguration idleSessionConfiguration =
      AudioSessionConfiguration.music();

  /// Bumped every time any coordinator puts a call configuration on the shared
  /// session. Teardown only restores [idleSessionConfiguration] when nothing
  /// has configured a call since it started, so a slow teardown cannot pull
  /// the session out from under a call that began in the meantime.
  static int _callConfigurationEpoch = 0;

  /// The coordinator whose call the Android route belongs to. A replacement
  /// call can configure while the previous one is still putting the route
  /// back; claiming the route stops that teardown from pulling it out from
  /// under the new call.
  static ChatVoiceAudioSessionCoordinator? _androidRouteOwner;

  ChatVoiceAudioSessionCoordinator() {
    if (Platform.isIOS) {
      _iosFailureHandlerOwner = this;
      _iosVoiceAudioRouteChannel.setMethodCallHandler(
        _handleIosVoiceAudioRouteCall,
      );
    }
  }

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

  /// The session mode of the call phase last configured, or null when no call
  /// has configured the session. The speaker button re-applies the phase's
  /// configuration with it, since the iOS category options follow the route.
  AVAudioSessionMode? _callSessionMode;
  bool _routeChangesStopped = false;

  /// Set once this coordinator has been disposed. There is no next call for it
  /// to route after that, so a `deactivate` arriving late must not lift the
  /// shutter [dispose] put down.
  bool _disposed = false;

  /// Set once [applyDefaultSpeakerphoneRoute] has picked the loudspeaker but no
  /// configure pass has tried to move the route there yet. Until one does,
  /// nobody knows whether the platform will take it.
  bool _defaultRouteAwaitingConfirmation = false;

  /// How many speaker-button presses are queued or on the wire.
  int _pendingSpeakerphoneRequests = 0;

  /// How many teardowns are part-way through. Hanging up and disposal can
  /// overlap, and the first to finish must not lift the shutter while the other
  /// is still putting the platform route back.
  int _teardownsRunning = 0;

  /// Whether the hardware has lost its vote over the route.
  ///
  /// A press counts from the moment it is queued, so an automatic reroute
  /// waiting behind it stands down rather than undoing it. It only becomes
  /// permanent once the platform takes the move: a press that was refused
  /// changed nothing, and should not leave the call deaf to headsets for the
  /// rest of its life.
  bool get _manualRouteHeld =>
      _speakerphoneChosenByUser || _pendingSpeakerphoneRequests > 0;

  /// Makes every route change report refusal. A test host has no platform to
  /// turn a move down, and refusal is the interesting half of the behaviour.
  @visibleForTesting
  bool debugRefuseRouteChanges = false;

  /// Runs the Android route calls on a test host, where the audio manager
  /// channel is mocked. The real platform check still wins on a device.
  @visibleForTesting
  bool debugTreatAsAndroid = false;

  bool get _isAndroid => Platform.isAndroid || debugTreatAsAndroid;

  /// The phases teardown has run for, in order. A test host has no audio route
  /// to watch come back, so this is the only trace teardown leaves behind.
  /// Only filled in when asserts are on.
  @visibleForTesting
  final List<String> debugRouteTeardowns = <String>[];

  /// Bumped by every teardown so work started for an earlier call can tell that
  /// it came back too late.
  int _callGeneration = 0;
  Future<void> _routeSerial = Future<void>.value();
  StreamSubscription<Set<AudioDevice>>? _devicesSub;
  StreamSubscription<AVAudioSessionRouteChange>? _iosRouteChangeSub;
  final StreamController<bool> _speakerphoneRouteController =
      StreamController<bool>.broadcast();
  final StreamController<Object> _responseCaptureFailureController =
      StreamController<Object>.broadcast();

  /// Whether the call is on the loudspeaker, whenever the platform says so:
  /// after every configure pass, after a reroute this coordinator made on its
  /// own, and when the platform moves the route itself. Callers use it to keep
  /// the speaker control showing the route people actually hear. The answer to
  /// a manual toggle comes back from [setSpeakerphoneEnabled] instead.
  Stream<bool> get speakerphoneRouteChanges =>
      _speakerphoneRouteController.stream;
  Stream<Object> get responseCaptureFailures =>
      _responseCaptureFailureController.stream;

  Future<Object?> _handleIosVoiceAudioRouteCall(MethodCall call) async {
    if (call.method != 'responseWaitCaptureFailed') {
      throw MissingPluginException('Unknown voice audio route callback');
    }
    if (_disposed || _responseCaptureFailureController.isClosed) {
      return false;
    }
    final arguments = call.arguments;
    final message = arguments is Map ? arguments['message'] as String? : null;
    _responseCaptureFailureController.add(
      StateError(
        message?.trim().isNotEmpty == true
            ? message!.trim()
            : 'iOS response-wait audio capture stopped unexpectedly.',
      ),
    );
    return true;
  }

  Future<AudioSession> _ensureSession() async {
    final session = _session;
    if (session != null) {
      return session;
    }
    final created = await AudioSession.instance;
    _session = created;
    return created;
  }

  Future<void> configureForListening() =>
      _configureCallPhase(AVAudioSessionMode.voiceChat, phase: 'listening');

  Future<void> configureForSpeaking() => _configureCallPhase(
    AVAudioSessionMode.spokenAudio,
    phase: 'speaking',
    settleIosRoute: true,
  );

  Future<void> configureForBargeInSpeaking() => _configureCallPhase(
    AVAudioSessionMode.voiceChat,
    phase: 'barge-in-speaking',
    settleIosRoute: true,
  );

  Future<void> _configureCallPhase(
    AVAudioSessionMode mode, {
    required String phase,
    bool settleIosRoute = false,
  }) async {
    final generation = _callGeneration;
    if (_routeChangesStopped) {
      // The call is being torn down, or this coordinator is gone. Putting the
      // call configuration back now would undo the idle one teardown restores.
      return;
    }
    final session = await _ensureSession();
    if (_routeChangesStopped || generation != _callGeneration) {
      return;
    }
    _callSessionMode = mode;
    await _applyCallSessionConfiguration(session, phase: phase);
    await _activateVoiceRoute(session, phase: phase, generation: generation);
    if (settleIosRoute) {
      await _settleIosSpeakingRoute();
    }
  }

  /// The call configuration for [mode] on the route [_speakerphoneEnabled]
  /// asks for.
  ///
  /// On iOS the loudspeaker choice lives in the category options as well as in
  /// the output override: CallKit activation and route changes reset the
  /// override, and `.defaultToSpeaker` keeps the call on the loudspeaker
  /// through them. It is only set while the loudspeaker is chosen, and the
  /// speaker button re-applies the configuration when the choice changes.
  /// Leaving it on for the whole call is what #643 removed: with it set,
  /// clearing the override falls back to the loudspeaker, so the button could
  /// never reach the earpiece.
  AudioSessionConfiguration _callSessionConfiguration(AVAudioSessionMode mode) {
    var options = AVAudioSessionCategoryOptions.allowBluetooth;
    if (_speakerphoneEnabled) {
      options = options | AVAudioSessionCategoryOptions.defaultToSpeaker;
    }
    return AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: options,
      avAudioSessionMode: mode,
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
    );
  }

  Future<void> _applyCallSessionConfiguration(
    AudioSession session, {
    required String phase,
  }) async {
    final mode = _callSessionMode;
    if (mode == null) return;
    _callConfigurationEpoch++;
    await _configureSession(session, _callSessionConfiguration(mode), phase);
  }

  /// Re-applies the current phase's iOS configuration so `.defaultToSpeaker`
  /// follows a route change made between configure passes. Failing here only
  /// costs the category option: the output override still moves the route.
  Future<void> _reapplyIosCallSessionOptions({required String phase}) async {
    // Once teardown has started, the idle configuration is what belongs on the
    // session, and a call configuration applied now would also stop teardown
    // from restoring it.
    if (!Platform.isIOS || _routeChangesStopped) return;
    final session = _session;
    if (session == null || _callSessionMode == null) return;
    try {
      await _applyCallSessionConfiguration(session, phase: phase);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'ios-call-session-options-failed',
        scope: 'voice/audio-route',
        error: error,
        stackTrace: stackTrace,
        data: {'phase': phase, 'speakerphone': _speakerphoneEnabled},
      );
    }
  }

  Future<void> setActiveCallKitCallId(String callId) async {
    if (!Platform.isIOS) return;
    final accepted = await _iosVoiceAudioRouteChannel.invokeMethod<bool>(
      'setActiveCallKitCallId',
      <String, Object?>{'callId': callId},
    );
    if (accepted != true) {
      throw StateError('iOS CallKit audio ownership registration failed');
    }
  }

  Future<void> beginResponseWaitCapture({String? callKitCallId}) async {
    if (!Platform.isIOS) return;
    final accepted = await _iosVoiceAudioRouteChannel.invokeMethod<bool>(
      'beginResponseWaitCapture',
      <String, Object?>{'callKitCallId': callKitCallId},
    );
    if (accepted != true) {
      throw StateError('iOS response-wait audio capture failed to start');
    }
  }

  Future<void> endResponseWaitCapture() async {
    if (!Platform.isIOS) return;
    try {
      final stopped = await _iosVoiceAudioRouteChannel.invokeMethod<bool>(
        'endResponseWaitCapture',
      );
      if (stopped != true) {
        throw StateError('iOS response-wait audio capture failed to stop');
      }
    } on MissingPluginException {
      DebugLogger.warning(
        'ios-response-wait-bridge-missing',
        scope: 'chat/voice_audio',
      );
    }
  }

  /// Activates the session, puts the call on the current route, and settles
  /// what the platforms made of it (see [_settleConfiguredRoute]).
  ///
  /// The whole step queues behind the button and device-change reroutes because
  /// it makes the same platform calls off the same [_speakerphoneEnabled] flag.
  /// Run loose, a pass that started before a headset was pulled out can finish
  /// after the reroute and put the call back on the route it just left.
  ///
  /// Teardown drains the same queue, so queueing is also what stops a pass that
  /// started before the call ended from reactivating the session or putting the
  /// phone back into communication mode after the route was handed back.
  ///
  /// [generation] is the call this pass was started for, read before the
  /// session configuration it follows. A teardown that both began and finished
  /// during that configuration leaves the shutter up again, so the generation
  /// is what tells this pass the call it belongs to is over.
  Future<void> _activateVoiceRoute(
    AudioSession session, {
    required String phase,
    required int generation,
  }) {
    return _serializeRouteChange(() async {
      if (_routeChangesStopped || generation != _callGeneration) {
        return;
      }
      await _setActive(session, active: true, phase: phase);
      _watchIosRouteChanges();
      final android = await _configureAndroidVoiceRoute(phase: phase);
      final ios = await _configureIosVoiceRoute(phase: phase);
      if (_routeChangesStopped || generation != _callGeneration) {
        // The call ended while the platform calls were out. Whatever they
        // found belongs to a call nobody is on.
        return;
      }
      _settleConfiguredRoute(
        applied: android.applied && ios.applied,
        loudspeaker: android.loudspeaker ?? ios.loudspeaker,
      );
    });
  }

  Future<void> deactivate() => _tearDownRoute(phase: 'deactivate');

  Future<void> dispose() async {
    // Riverpod does not promise to dispose this coordinator after the
    // controller that drives it, so disposal cannot assume `deactivate` has
    // already run. Running it again is cheap and leaves nothing behind; not
    // running it can leave the phone in communication mode after the call.
    _disposed = true;
    if (Platform.isIOS && identical(_iosFailureHandlerOwner, this)) {
      _iosFailureHandlerOwner = null;
      _iosVoiceAudioRouteChannel.setMethodCallHandler(null);
    }
    await _tearDownRoute(phase: 'dispose');
    await _speakerphoneRouteController.close();
    await _responseCaptureFailureController.close();
  }

  /// Hands the route back to whatever had it before the call.
  ///
  /// Safe to run twice, in either order, and overlapping: every step either
  /// restores state it captured or clears state that is already clear, and the
  /// shutter stays down until the last teardown is done.
  Future<void> _tearDownRoute({required String phase}) async {
    assert(() {
      debugRouteTeardowns.add(phase);
      return true;
    }());
    _teardownsRunning++;
    _callGeneration++;
    final configurationEpoch = _callConfigurationEpoch;
    final session = _session;
    final devicesSub = _devicesSub;
    _devicesSub = null;
    final iosRouteChangeSub = _iosRouteChangeSub;
    _iosRouteChangeSub = null;
    _routeChangesStopped = true;
    try {
      await devicesSub?.cancel();
      await iosRouteChangeSub?.cancel();
      // Let any reroute already on the wire finish before tearing the route
      // down, so the teardown is not the thing that gets interleaved.
      await _routeSerial;
      await _clearIosVoiceRoute();
      if (session != null) {
        await _setActive(session, active: false, phase: phase);
      }
    } finally {
      await _restoreAndroidVoiceRoute();
      await _restoreIdleSessionConfiguration(
        session,
        configurationEpoch: configurationEpoch,
        phase: phase,
      );
      _speakerphoneEnabled = false;
      _speakerphoneChosenByUser = false;
      _pendingSpeakerphoneRequests = 0;
      _accessoryAttached = null;
      _defaultRouteAwaitingConfirmation = false;
      _teardownsRunning--;
      if (_teardownsRunning == 0) {
        _routeChangesStopped = _disposed;
      }
    }
  }

  /// Puts [idleSessionConfiguration] back on the shared session after a call.
  ///
  /// Deactivating is not enough on its own: the next player to activate the
  /// session gets whatever configuration was left on it (see
  /// [idleSessionConfiguration]). Skipped when this coordinator never
  /// configured a call, and when a call configured the session again since
  /// this teardown began, since that configuration is not ours to undo.
  Future<void> _restoreIdleSessionConfiguration(
    AudioSession? session, {
    required int configurationEpoch,
    required String phase,
  }) async {
    if (session == null || _callSessionMode == null) return;
    _callSessionMode = null;
    if (configurationEpoch != _callConfigurationEpoch) return;
    try {
      await _configureSession(session, idleSessionConfiguration, phase);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'idle-session-restore-failed',
        scope: 'voice/audio-route',
        error: error,
        stackTrace: stackTrace,
        data: {'phase': phase},
      );
    }
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
    if (!_isAndroid && !Platform.isIOS) {
      return;
    }
    if (_routeChangesStopped) {
      // A teardown is part-way through. Its generation bump has already
      // happened, so the check below would wave this scan through.
      return;
    }
    final generation = _callGeneration;
    final attached = await _hasExternalAudioAccessory();
    if (generation != _callGeneration ||
        _routeChangesStopped ||
        _manualRouteHeld) {
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

  /// Settles what a configure pass found, from inside the route queue.
  ///
  /// The session does not exist yet when the default is picked, so the default
  /// only becomes a route on the first `configureFor*` pass, and only gets
  /// announced once that pass has tried it: lighting the speaker button up
  /// earlier would promise a route the platform still had the chance to
  /// refuse.
  ///
  /// Every pass then reports the route it read back, whichever way it points
  /// and whoever chose it. The platform can move the call between passes (the
  /// Android mode owner lapsing, an iOS route change resetting the override),
  /// and a button that only hears about moves this coordinator made drifts away
  /// from what people hear, then fights them when they press it (issue #716).
  /// [_speakerphoneEnabled] keeps the route that was asked for, so the next
  /// pass tries it again.
  void _settleConfiguredRoute({
    required bool applied,
    required bool? loudspeaker,
  }) {
    if (_defaultRouteAwaitingConfirmation) {
      _defaultRouteAwaitingConfirmation = false;
      if (!applied && !_manualRouteHeld) {
        // The call is still on the earpiece, so the preference picked by
        // [applyDefaultSpeakerphoneRoute] never became a route. Put the flag
        // back, and drop the "nothing attached" snapshot with it: a phone that
        // stays bare repeats the same device list rather than sending a fresh
        // transition, and the snapshot would make that repeat look like old
        // news and skip the retry.
        _speakerphoneEnabled = false;
        if (_accessoryAttached == false) {
          _accessoryAttached = null;
        }
      }
    }
    // A read-back that failed outright says nothing, so a pass the platform
    // took reports the route it asked for, and a refused one stays quiet.
    final route = loudspeaker ?? (applied ? _speakerphoneEnabled : null);
    if (route != null) {
      _publishRoute(route);
    }
  }

  void _publishRoute(bool loudspeaker) {
    if (_routeChangesStopped || _speakerphoneRouteController.isClosed) return;
    _speakerphoneRouteController.add(loudspeaker);
  }

  /// Reads the route back outside a configure pass and reports it, so the
  /// speaker button follows moves the platform made on its own.
  ///
  /// Queued with the route changes so it reads the route they settled on
  /// rather than one of their intermediate steps.
  Future<void> _syncObservedRoute({required String phase}) {
    final generation = _callGeneration;
    return _serializeRouteChange(() async {
      if (_routeChangesStopped || generation != _callGeneration) return;
      final loudspeaker = await _readLoudspeakerRoute(phase: phase);
      if (loudspeaker == null ||
          _routeChangesStopped ||
          generation != _callGeneration) {
        return;
      }
      _publishRoute(loudspeaker);
    });
  }

  Future<bool?> _readLoudspeakerRoute({required String phase}) async {
    if (_isAndroid) {
      final manager = _androidAudioManager;
      // No configure pass has touched the route yet, so there is nothing of
      // this call's to read back.
      if (manager == null) return null;
      return _readAndroidLoudspeaker(manager, phase: phase);
    }
    if (Platform.isIOS) {
      final payload = await _safeIosRouteCall(
        () => _iosVoiceAudioRouteChannel.invokeMapMethod<Object?, Object?>(
          'currentRoute',
        ),
        operation: 'current-route',
        phase: phase,
      );
      return _iosLoudspeakerFromPayload(payload);
    }
    return null;
  }

  /// Follows iOS route changes for the rest of the call: CallKit activating
  /// the session, a category change or another app can move the output
  /// without any of this coordinator's calls being involved.
  void _watchIosRouteChanges() {
    if (!Platform.isIOS || _iosRouteChangeSub != null || _routeChangesStopped) {
      return;
    }
    _iosRouteChangeSub = AVAudioSession().routeChangeStream.listen(
      (change) => unawaited(
        _syncObservedRoute(phase: 'route-change-${change.reason.name}'),
      ),
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'ios-route-change-watch-failed',
          scope: 'voice/audio-route',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
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
    if (_routeChangesStopped) {
      // The call is over. The hardware no longer gets a vote.
      return;
    }
    if (_manualRouteHeld) {
      // Someone pressed the speaker button, so the hardware no longer gets a
      // vote. It can still have moved the call, though.
      await _syncAndroidRouteAfterDeviceChange();
      return;
    }

    final attached = devices.any(_isPlayableAccessory);
    if (attached == _accessoryAttached) {
      await _syncAndroidRouteAfterDeviceChange();
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
      if (_manualRouteHeld || _routeChangesStopped) return;
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
      if (_manualRouteHeld || _routeChangesStopped) return;
      if (_accessoryAttached != attached) return;
      if (!applied) {
        // Audio is still coming out of wherever it was, so saying otherwise
        // would point the speaker button at a route nobody is hearing. Drop the
        // accessory snapshot claimed above as well: the hardware never moved,
        // and leaving the claim standing would make the next notification about
        // the same hardware look like old news and skip the retry.
        _accessoryAttached = null;
        return;
      }
      _publishRoute(enabled);
    });
  }

  /// Re-reads the Android route after a device event that did not call for a
  /// reroute. Android has no callback for the communication device moving, but
  /// hardware coming or going is when it usually does. iOS follows its own
  /// route-change notifications instead (see [_watchIosRouteChanges]).
  Future<void> _syncAndroidRouteAfterDeviceChange() async {
    if (!_isAndroid) return;
    await _syncObservedRoute(phase: 'device-change');
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
    // Counted before queueing so an automatic reroute still waiting its turn
    // sees the press and stands down.
    _pendingSpeakerphoneRequests++;
    return _serializeRouteChange(() async {
      var applied = false;
      try {
        if (_routeChangesStopped) {
          // Teardown started while this press waited its turn. The route is on
          // its way back to whatever had it before the call, so moving it now
          // is platform work for a call that is over.
          return false;
        }
        applied = await _applySpeakerphoneRoute(enabled, phase: 'user-toggle');
      } finally {
        _pendingSpeakerphoneRequests--;
      }
      if (_routeChangesStopped) {
        // Same again, for a teardown that started while the platform calls were
        // out. Answering `true` here would light the speaker button up as the
        // call ends.
        return false;
      }
      if (applied) {
        _speakerphoneChosenByUser = true;
      } else {
        // The press never became a route, so the hardware keeps its vote. The
        // platform calls above may still have torn the old route down on the
        // way, so drop the accessory snapshot and let the next device event
        // work the route out from scratch.
        _accessoryAttached = null;
      }
      return applied;
    });
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
    if (_isAndroid) {
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
      applied = (await _configureAndroidVoiceRoute(phase: phase)).applied;
    }
    await _reapplyIosCallSessionOptions(phase: phase);
    if (!(await _setIosSpeakerphoneEnabled(enabled, phase: phase)).applied) {
      applied = false;
    }
    if (debugRefuseRouteChanges) {
      applied = false;
    }
    if (!applied) {
      _speakerphoneEnabled = previous;
      if (previous != enabled) {
        await _reapplyIosCallSessionOptions(phase: phase);
      }
    }
    return applied;
  }

  /// Points the Android call at the route [_speakerphoneEnabled] asks for, and
  /// reports whether it landed and where the platform says the call is.
  Future<_RouteOutcome> _configureAndroidVoiceRoute({
    required String phase,
  }) async {
    if (!_isAndroid) {
      return (applied: true, loudspeaker: null);
    }

    final manager = _androidAudioManager ??= AndroidAudioManager();

    _claimAndroidRoute();
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
      final loudspeaker = await _routeAndroidToLoudspeaker(
        manager,
        phase: phase,
      );
      return (
        applied: modeSet && loudspeaker.applied,
        loudspeaker: loudspeaker.loudspeaker,
      );
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
    if (!selected) {
      await _safeAndroidRouteCall(
        () async {
          await manager.startBluetoothSco();
          await manager.setBluetoothScoOn(true);
        },
        operation: 'start-bluetooth-sco',
        phase: phase,
      );
    }

    // Leaving the loudspeaker is no more certain than reaching it: the platform
    // can keep the call there (a phone with no earpiece, another app's route
    // winning). Trusting the calls above let the button show the earpiece over
    // a call still on the speaker, and then refuse the press that would have
    // matched it (issue #716). A read-back that fails outright says nothing,
    // so that case trusts the calls as before.
    final loudspeaker = await _readAndroidLoudspeaker(manager, phase: phase);
    if (loudspeaker == true) {
      DebugLogger.warning(
        'android-earpiece-route-refused',
        scope: 'voice/audio-route',
        data: {'phase': phase, 'bluetoothSco': selected},
      );
    }
    return (applied: modeSet && loudspeaker != true, loudspeaker: loudspeaker);
  }

  /// Whether the platform reports the Android call on the built-in speaker, or
  /// null when neither read-back answered.
  Future<bool?> _readAndroidLoudspeaker(
    AndroidAudioManager manager, {
    required String phase,
  }) async {
    final selected = await _safeAndroidRouteCall(
      () async => (device: await manager.getCommunicationDevice()),
      operation: 'get-communication-device',
      phase: phase,
    );
    final device = selected?.device;
    if (device != null) {
      return device.type == AndroidAudioDeviceType.builtInSpeaker;
    }
    // No communication device to go on (Android 11 and older, or nothing
    // selected), so fall back to the legacy flag.
    return _safeAndroidRouteCall(
      () => manager.isSpeakerphoneOn(),
      operation: 'get-speakerphone',
      phase: phase,
    );
  }

  /// Puts the call on the built-in speaker and reports whether it is there.
  ///
  /// Neither route call answers honestly on its own: `setSpeakerphoneOn` is
  /// void, and `setCommunicationDevice` can say yes and still be overridden
  /// (issue #716). The route is read back after each and only counts as
  /// applied when the read-back shows the loudspeaker. A read-back that fails
  /// outright says nothing, so that case trusts the set call as before.
  Future<_RouteOutcome> _routeAndroidToLoudspeaker(
    AndroidAudioManager manager, {
    required String phase,
  }) async {
    // setSpeakerphoneOn is deprecated and is a no-op on Android 12+ once a
    // communication device is selected, so route to the built-in speaker
    // explicitly and keep the legacy call as the pre-31 fallback.
    final routed = await _selectAndroidCommunicationDevice(
      manager,
      AndroidAudioDeviceType.builtInSpeaker,
      phase: phase,
    );
    var loudspeaker = false;
    // What the platform last said about the route, if it said anything.
    bool? readBack;
    String? deviceReadBack;
    bool? speakerphoneReadBack;
    if (routed) {
      final selected = await _safeAndroidRouteCall(
        () async => (device: await manager.getCommunicationDevice()),
        operation: 'get-communication-device',
        phase: phase,
      );
      if (selected == null) {
        loudspeaker = true;
      } else {
        loudspeaker =
            selected.device?.type == AndroidAudioDeviceType.builtInSpeaker;
        readBack = loudspeaker;
        deviceReadBack = selected.device?.type.name ?? 'none';
      }
    }
    if (!loudspeaker) {
      if (routed) {
        // The platform accepted the speaker but the read-back disagrees.
        // Release that selection first: setSpeakerphoneOn is ignored while a
        // communication device stays selected, so the fallback would not
        // move the route either.
        await _safeAndroidRouteCall(
          () => manager.clearCommunicationDevice(),
          operation: 'clear-rejected-communication-device',
          phase: phase,
        );
      }
      final legacyRouted = await _safeAndroidRouteAction(
        () => manager.setSpeakerphoneOn(true),
        operation: 'configure-speakerphone',
        phase: phase,
      );
      if (legacyRouted) {
        final speakerphoneOn = await _safeAndroidRouteCall(
          () => manager.isSpeakerphoneOn(),
          operation: 'get-speakerphone',
          phase: phase,
        );
        loudspeaker = speakerphoneOn ?? true;
        speakerphoneReadBack = speakerphoneOn;
        // The fallback may have moved the route since the device read-back.
        readBack = speakerphoneOn;
      }
    }
    final data = <String, Object?>{
      'phase': phase,
      'communicationDevice': routed,
      'deviceReadBack': deviceReadBack,
      'speakerphoneReadBack': speakerphoneReadBack,
    };
    if (loudspeaker) {
      DebugLogger.info(
        'android-loudspeaker-route-applied',
        scope: 'voice/audio-route',
        data: data,
      );
    } else {
      DebugLogger.warning(
        'android-loudspeaker-route-refused',
        scope: 'voice/audio-route',
        data: data,
      );
    }
    return (applied: loudspeaker, loudspeaker: readBack);
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

  /// Takes the Android call route over from any coordinator still holding
  /// it. That coordinator's call is ending, and the state it saved from before
  /// its call is what to hand back when this call ends, not the call mode it
  /// leaves behind.
  void _claimAndroidRoute() {
    final owner = _androidRouteOwner;
    if (identical(owner, this)) return;
    if (owner != null) {
      _previousAndroidMode ??= owner._previousAndroidMode;
      _previousAndroidSpeakerphone ??= owner._previousAndroidSpeakerphone;
    }
    _androidRouteOwner = this;
  }

  Future<void> _restoreAndroidVoiceRoute() async {
    if (!_isAndroid) {
      return;
    }

    final manager = _androidAudioManager;
    if (manager == null) {
      return;
    }

    // A replacement call that claims the route meanwhile has inherited what
    // to restore, so stop before touching its route. A call already on the
    // wire reaches the platform ahead of anything the replacement sends.
    bool ownsRoute() => identical(_androidRouteOwner, this);
    try {
      if (!ownsRoute()) return;
      await _safeAndroidRouteCall(
        () => manager.clearCommunicationDevice(),
        operation: 'clear-communication-device',
        phase: 'deactivate',
      );
      if (!ownsRoute()) return;
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
        if (!ownsRoute()) return;
        await _safeAndroidRouteCall(
          () => manager.setSpeakerphoneOn(previousSpeakerphone),
          operation: 'restore-speakerphone',
          phase: 'deactivate',
        );
      }

      final previousMode = _previousAndroidMode;
      if (previousMode != null) {
        if (!ownsRoute()) return;
        await _safeAndroidRouteCall(
          () => manager.setMode(previousMode),
          operation: 'restore-mode',
          phase: 'deactivate',
        );
      }
    } finally {
      if (ownsRoute()) _androidRouteOwner = null;
      _previousAndroidMode = null;
      _previousAndroidSpeakerphone = null;
    }
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

  /// Puts the iOS session on the current route, and reports whether it took
  /// and where the call is now.
  Future<_RouteOutcome> _configureIosVoiceRoute({required String phase}) async {
    if (!Platform.isIOS) {
      return (applied: true, loudspeaker: null);
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

  /// Overrides the iOS output port, and reports whether the session took it
  /// and where the call is now.
  Future<_RouteOutcome> _setIosSpeakerphoneEnabled(
    bool enabled, {
    required String phase,
  }) async {
    if (!Platform.isIOS) return (applied: true, loudspeaker: null);
    final payload = await _safeIosRouteCall(
      () => _iosVoiceAudioRouteChannel.invokeMapMethod<Object?, Object?>(
        'setSpeakerphoneEnabled',
        <String, Object?>{'enabled': enabled},
      ),
      operation: 'set-speakerphone',
      phase: phase,
    );
    return (
      applied: iosSpeakerphoneChangeApplied(payload, enabled: enabled),
      loudspeaker: _iosLoudspeakerFromPayload(payload),
    );
  }

  /// Whether an iOS `setSpeakerphoneEnabled` answer shows the call where
  /// [enabled] asked for it.
  ///
  /// The handler always answers with the current route and only carries an
  /// `error` when overrideOutputAudioPort threw, so a missing payload means
  /// the channel itself never got there. A successful override can still
  /// leave the call elsewhere, as on a device with no receiver to fall back
  /// to, so the route read back decides; a payload listing no outputs says
  /// nothing, and the override is trusted (issue #716).
  @visibleForTesting
  static bool iosSpeakerphoneChangeApplied(
    Map<Object?, Object?>? payload, {
    required bool enabled,
  }) {
    if (payload == null || payload['error'] != null) return false;
    final loudspeaker = _iosLoudspeakerFromPayload(payload);
    return loudspeaker == null || loudspeaker == enabled;
  }

  /// Whether an iOS route payload has the call on the built-in speaker, or
  /// null when it lists no outputs to go on.
  static bool? _iosLoudspeakerFromPayload(Map<Object?, Object?>? payload) {
    final outputs = payload?['currentOutputs'];
    if (outputs is! List || outputs.isEmpty) return null;
    // AVAudioSession.Port.builtInSpeaker's raw value.
    return outputs.any((port) => port is Map && port['type'] == 'Speaker');
  }

  Future<void> _clearIosVoiceRoute() async {
    if (!Platform.isIOS) {
      return;
    }

    // Drop the loudspeaker override before handing the session back. It only
    // lapses on its own at the next route change, and until then it is one
    // more piece of the call left on a session other audio is about to use.
    await _setIosSpeakerphoneEnabled(false, phase: 'deactivate');

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
