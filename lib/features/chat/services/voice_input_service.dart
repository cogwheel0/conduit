import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:vad/vad.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/background_streaming_handler.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/debug_logger.dart';
import 'native_stt_service.dart';

part 'voice_input_service.g.dart';

/// Lightweight locale representation used across the UI.
class LocaleName {
  final String localeId;
  final String name;
  const LocaleName(this.localeId, this.name);
}

class VoiceTranscriptEvent {
  const VoiceTranscriptEvent({required this.text, required this.isFinal});

  final String text;
  final bool isFinal;
}

class VoiceInputService {
  static const int _vadSampleRate = 16000;
  static const int _vadFrameSamples = 512;
  static const int _minVadRedemptionFrames = 4;
  static const int _maxVadRedemptionFrames =
      ((SettingsService.maxVoiceSilenceDurationMs * _vadSampleRate) +
          (_vadFrameSamples * 1000) -
          1) ~/
      (_vadFrameSamples * 1000);
  static const int _vadPreSpeechPadFrames = 16;
  static const int _vadMinSpeechFrames = 8;
  static const int _vadEndSpeechPadFrames = 6;
  static const double _vadPositiveSpeechThreshold = 0.6;
  static const double _vadNegativeSpeechThreshold = 0.35;
  static const Duration _localeFetchTimeout = Duration(seconds: 2);
  static const String _backgroundSttStreamId = 'voice-input-stt';
  static const Duration _vadDisposeCooldown = Duration(milliseconds: 140);
  static const Duration _localRecognitionMaxDuration = Duration(minutes: 5);
  static const Duration _nativeDictationFinalSettleDelay = Duration(
    milliseconds: 900,
  );
  static const String _bundledVadAssetBasePath = 'assets/vad/';
  static const List<IosAudioCategoryOption> _iosServerVadCategoryOptions = [
    // A2DP is output-only on iOS and can break duplex mic capture when the
    // recorder is trying to open a microphone stream.
    IosAudioCategoryOption.defaultToSpeaker,
    IosAudioCategoryOption.allowBluetooth,
  ];
  static const IosRecordConfig _iosStandaloneServerVadRecordConfig =
      IosRecordConfig(categoryOptions: _iosServerVadCategoryOptions);
  static const IosRecordConfig _iosManagedServerVadRecordConfig =
      IosRecordConfig(
        categoryOptions: _iosServerVadCategoryOptions,
        // The voice-call path already coordinates AVAudioSession through
        // audio_session and the native background manager.
        // ignore: deprecated_member_use
        manageAudioSession: false,
      );

  @visibleForTesting
  static AndroidRecordConfig androidServerVadRecordConfigForTesting({
    required bool voiceCallSession,
  }) => _androidServerVadRecordConfig(voiceCallSession: voiceCallSession);

  static AndroidRecordConfig _androidServerVadRecordConfig({
    required bool voiceCallSession,
  }) {
    return AndroidRecordConfig(
      audioSource: voiceCallSession
          ? AndroidAudioSource.voiceCommunication
          : AndroidAudioSource.voiceRecognition,
      audioManagerMode: voiceCallSession
          ? AudioManagerMode.modeInCommunication
          : AudioManagerMode.modeNormal,
      speakerphone: false,
      manageBluetooth: true,
      useLegacy: false,
    );
  }

  VadHandler? _vadHandler;
  final NativeSttService _nativeStt;
  final ApiService? _api;
  final Ref? _ref;
  bool _isInitialized = false;
  bool _didAttemptLocalInitialization = false;
  bool _isListening = false;
  bool _localSttAvailable = false;
  bool _nativeLocalSttAvailable = false;
  bool _localSttActive = false;
  SttPreference _preference = SttPreference.deviceOnly;
  bool _usingServerStt = false;
  bool _usingNativeLocalStt = false;
  bool _nativeAccumulateResultsForCurrentListen = true;
  String? _selectedLocaleId;
  List<LocaleName> _locales = const [];
  bool _usingFallbackLocales = false;
  Future<void>? _startingLocalStt;
  Future<Stream<String>>? _startListeningInFlight;
  StreamController<String>? _textStreamController;
  StreamController<VoiceTranscriptEvent>? _transcriptEventController;
  String _currentText = '';
  bool _receivedFinalResult = false;
  bool _completedTranscriptIsSendable = false;
  StreamController<int>? _intensityController;
  Stream<int> get intensityStream =>
      _intensityController?.stream ?? const Stream<int>.empty();
  int _lastIntensity = 0;
  Timer? _intensityDecayTimer;
  List<double>? _vadPendingSamples;
  bool _backgroundMicPinned = false;

  Stream<String> get textStream =>
      _textStreamController?.stream ?? const Stream<String>.empty();
  Stream<VoiceTranscriptEvent> get transcriptEvents =>
      _transcriptEventController?.stream ??
      const Stream<VoiceTranscriptEvent>.empty();
  Timer? _autoStopTimer;
  StreamSubscription<List<double>>? _vadSpeechEndSub;
  StreamSubscription<({double isSpeech, double notSpeech, List<double> frame})>?
  _vadFrameSub;
  StreamSubscription<String>? _vadErrorSub;
  StreamSubscription<NativeSttEvent>? _nativeSttSub;
  Timer? _nativeDictationSettleTimer;

  bool get isSupportedPlatform => Platform.isAndroid || Platform.isIOS;
  bool get hasServerStt => _api != null;
  SttPreference get preference => _preference;
  bool get prefersServerOnly => _preference == SttPreference.serverOnly;
  bool get prefersDeviceOnly => _preference == SttPreference.deviceOnly;
  bool get _isIosSimulator =>
      Platform.isIOS &&
      Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');

  VoiceInputService({ApiService? api, Ref? ref, NativeSttService? nativeStt})
    : _api = api,
      _ref = ref,
      _nativeStt = nativeStt ?? NativeSttService();

  void updatePreference(SttPreference preference) {
    _preference = preference;
  }

  Future<bool> initialize({bool forceLocalStt = false}) async {
    if (!isSupportedPlatform) return false;
    final deviceTag = WidgetsBinding.instance.platformDispatcher.locale
        .toLanguageTag();
    _ensureFallbackLocale(deviceTag);

    if (_isIosSimulator) {
      _localSttAvailable = false;
      _didAttemptLocalInitialization = true;
      _isInitialized = true;
      return true;
    }

    final shouldPrepareLocalStt =
        forceLocalStt || _preference != SttPreference.serverOnly;
    if (shouldPrepareLocalStt && !_didAttemptLocalInitialization) {
      await _loadLocales(deviceTag);
      await _initializeNativeLocalStt(deviceTag);
      _localSttAvailable = _nativeLocalSttAvailable;
      _didAttemptLocalInitialization = true;
    }

    _isInitialized = true;
    return true;
  }

  Future<void> _initializeNativeLocalStt(String deviceTag) async {
    if (!_nativeStt.isSupportedPlatform) {
      _nativeLocalSttAvailable = false;
      return;
    }

    try {
      final availability = await _nativeStt.checkAvailability(
        localeId: _selectedLocaleId ?? deviceTag,
        allowOnlineFallback: false,
      );
      _nativeLocalSttAvailable = availability.available;
      if (availability.available) {
        DebugLogger.info(
          'native-stt-available',
          scope: 'voice/stt',
          data: {'engine': availability.engine ?? 'unknown'},
        );
      } else if (availability.reason != null) {
        DebugLogger.info(
          'native-stt-unavailable',
          scope: 'voice/stt',
          data: {'reason': availability.reason},
        );
      }
    } catch (error) {
      DebugLogger.warning(
        'native-stt-availability-failed',
        scope: 'voice/stt',
        data: {'error': error},
      );
      _nativeLocalSttAvailable = false;
    }
  }

  Future<bool> checkPermissions() async {
    final micGranted = await _ensureMicrophonePermission();
    if (!micGranted) {
      return false;
    }
    return true;
  }

  bool get isListening => _isListening;
  bool get isAvailable =>
      _isInitialized && (_localSttAvailable || hasServerStt);
  bool get hasLocalStt => _localSttAvailable;
  bool get isUsingNativeLocalStt => _usingNativeLocalStt;
  bool get lastCompletedTranscriptSendable => _completedTranscriptIsSendable;
  bool get localeMetadataIncomplete => _usingFallbackLocales;

  /// Checks if on-device STT is properly supported.
  Future<bool> checkOnDeviceSupport() async {
    if (!isSupportedPlatform) return false;
    if (!_isInitialized || !_didAttemptLocalInitialization) {
      final initialized = await initialize(forceLocalStt: true);
      if (!initialized) return false;
    }
    return _nativeLocalSttAvailable;
  }

  /// Test method to verify on-device STT functionality.
  Future<String> testOnDeviceStt() async {
    try {
      // First ensure we're initialized
      await initialize(forceLocalStt: true);

      if (!_localSttAvailable) {
        return 'Local STT not available. Available: $_localSttAvailable';
      }

      final hasMic = await checkPermissions();
      if (!hasMic) {
        return 'Microphone permission not granted';
      }

      final availability = await _nativeStt.checkAvailability(
        localeId: _selectedLocaleId,
        allowOnlineFallback: false,
      );
      if (!availability.available) {
        return 'Native on-device STT unavailable: '
            '${availability.reason ?? 'unknown reason'}';
      }

      await _nativeStt.startListening(
        localeId: _selectedLocaleId,
        emitPartialResults: false,
        accumulateResults: false,
        allowOnlineFallback: false,
      );
      await Future.delayed(const Duration(milliseconds: 100));
      await _nativeStt.stopListening();

      return 'On-device STT test completed successfully. '
          'Engine: ${availability.engine ?? 'unknown'}, '
          'Selected locale: $_selectedLocaleId';
    } catch (e) {
      return 'On-device STT test failed: $e';
    }
  }

  String? get selectedLocaleId => _selectedLocaleId;
  List<LocaleName> get locales => _locales;

  void setLocale(String? localeId) {
    _selectedLocaleId = localeId;
  }

  Future<void> _loadLocales(String deviceTag) async {
    _ensureFallbackLocale(deviceTag);
    try {
      final nativeLocales = await _nativeStt
          .getLocales(deviceLocaleId: deviceTag)
          .timeout(
            _localeFetchTimeout,
            onTimeout: () =>
                const NativeSttLocales(locales: <NativeSttLocale>[]),
          );
      if (nativeLocales.locales.isEmpty) {
        return;
      }

      _locales = nativeLocales.locales
          .map((loc) => LocaleName(loc.localeId, loc.name))
          .toList();
      _usingFallbackLocales = false;

      final systemTag = nativeLocales.systemLocaleId;
      final tagForMatch = (systemTag != null && systemTag.isNotEmpty)
          ? systemTag
          : deviceTag;

      final match = _matchLocale(tagForMatch);
      _selectedLocaleId = match.localeId;

      debugPrint(
        'VoiceInputService: deviceTag=$deviceTag, '
        'systemLocale=$systemTag, '
        'selectedLocaleId=$_selectedLocaleId',
      );
    } catch (_) {
      // Some engines may not support locale listing
    }
  }

  void _ensureFallbackLocale(String deviceTag) {
    if (_locales.isNotEmpty && _selectedLocaleId != null) {
      return;
    }
    _usingFallbackLocales = true;
    if (deviceTag.isEmpty) {
      _locales = const [LocaleName('en_US', 'en_US')];
      _selectedLocaleId = 'en_US';
      return;
    }
    _locales = [LocaleName(deviceTag, deviceTag)];
    _selectedLocaleId = deviceTag;
  }

  LocaleName _matchLocale(String deviceTag) {
    if (_locales.isEmpty) {
      return const LocaleName('en_US', 'en_US');
    }
    final normalizedDevice = deviceTag.toLowerCase();
    for (final locale in _locales) {
      if (locale.localeId.toLowerCase() == normalizedDevice) {
        return locale;
      }
    }
    final parts = normalizedDevice.split(RegExp('[-_]'));
    final primary = parts.isNotEmpty ? parts.first : normalizedDevice;
    for (final locale in _locales) {
      if (locale.localeId.toLowerCase().startsWith('$primary-')) {
        return locale;
      }
    }
    return _locales.first;
  }

  void _handleLocalRecognizerError(Object? error) {
    if (!_isListening) {
      return;
    }
    // Don't permanently disable _localSttAvailable on transient errors
    // The next session should still try local STT
    final message = error?.toString().trim();
    final exception = Exception(
      (message == null || message.isEmpty)
          ? 'Speech recognition failed'
          : message,
    );
    _textStreamController?.addError(exception);
    unawaited(_stopListening());
  }

  Future<bool> _ensureMicrophonePermission() async {
    try {
      final status = await Permission.microphone.status;
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Requests microphone permission if not already granted.
  /// Returns true if permission is granted, false otherwise.
  Future<bool> requestMicrophonePermission() async {
    try {
      final status = await Permission.microphone.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startLocalRecognition({
    required bool allowOnlineFallback,
    bool iosAudioSessionManagedExternally = false,
    bool nativeAccumulateResults = true,
  }) async {
    if (_startingLocalStt != null) {
      await _startingLocalStt;
    }
    final completer = Completer<void>();
    _startingLocalStt = completer.future;
    _localSttActive = false;

    if (_usingNativeLocalStt || _localSttActive) {
      await _ensureLocalSttReset();
      await Future.delayed(const Duration(milliseconds: 100));
    }

    try {
      if (!_nativeLocalSttAvailable) {
        throw Exception('On-device speech recognition unavailable');
      }
      await _startNativeLocalRecognition(
        preserveAudioSession: iosAudioSessionManagedExternally,
        accumulateResults: nativeAccumulateResults,
        allowOnlineFallback: allowOnlineFallback,
      );
      _localSttActive = true;
    } catch (error) {
      _localSttActive = false;
      await _ensureLocalSttReset();
      rethrow;
    } finally {
      completer.complete();
      _startingLocalStt = null;
    }
  }

  Future<void> _startNativeLocalRecognition({
    required bool preserveAudioSession,
    required bool accumulateResults,
    required bool allowOnlineFallback,
  }) async {
    await _nativeSttSub?.cancel();
    _nativeSttSub = null;
    _usingNativeLocalStt = true;
    final stream = await _nativeStt.startListening(
      localeId: _selectedLocaleId,
      preserveAudioSession: preserveAudioSession,
      emitPartialResults: true,
      accumulateResults: accumulateResults,
      allowOnlineFallback: allowOnlineFallback,
    );
    _nativeSttSub = stream.listen(
      _handleNativeSttEvent,
      onError: (Object error, StackTrace stackTrace) {
        if (!_isListening || !_usingNativeLocalStt) return;
        _handleLocalRecognizerError(error);
      },
      onDone: () {
        if (_isListening && _usingNativeLocalStt && !_usingServerStt) {
          unawaited(_stopListening());
        }
      },
    );
  }

  void _handleNativeSttEvent(NativeSttEvent event) {
    if (!_isListening || !_usingNativeLocalStt) return;

    switch (event.type) {
      case 'status':
        if (event.message == 'listening') {
          _localSttActive = true;
        }
      case 'result':
        final text = event.text;
        if (text == null) return;
        _handleNativeSttResult(text, event.isFinal);
      case 'error':
        _handleLocalRecognizerError(
          NativeSttException(
            event.message ?? 'Native speech recognition failed',
            code: event.code,
          ),
        );
      case 'done':
        if (_isListening && !_usingServerStt) {
          unawaited(_stopListening());
        }
    }
  }

  void _handleNativeSttResult(String text, bool isFinal) {
    final prevLen = _currentText.length;
    _currentText = text;
    if (_currentText.isNotEmpty) {
      _textStreamController?.add(_currentText);
      _transcriptEventController?.add(
        VoiceTranscriptEvent(text: _currentText, isFinal: isFinal),
      );
    }
    if (isFinal) {
      _receivedFinalResult = true;
      if (_shouldSettleNativeDictation(
        isFinal: true,
        nativeAccumulateResults: _nativeAccumulateResultsForCurrentListen,
        usingServerStt: _usingServerStt,
      )) {
        _scheduleNativeDictationSettle();
      }
    } else {
      _cancelNativeDictationSettle();
    }
    final delta = (_currentText.length - prevLen).clamp(0, 50);
    final mapped = (delta / 5.0).ceil();
    _lastIntensity = mapped.clamp(0, 10);
    try {
      _intensityController?.add(_lastIntensity);
    } catch (_) {}
  }

  void _scheduleNativeDictationSettle() {
    _nativeDictationSettleTimer?.cancel();
    _nativeDictationSettleTimer = Timer(_nativeDictationFinalSettleDelay, () {
      if (!_isListening ||
          !_usingNativeLocalStt ||
          !_nativeAccumulateResultsForCurrentListen ||
          _usingServerStt) {
        return;
      }
      unawaited(_stopListening());
    });
  }

  void _cancelNativeDictationSettle() {
    _nativeDictationSettleTimer?.cancel();
    _nativeDictationSettleTimer = null;
  }

  Future<Stream<String>> startListening({
    bool iosAudioSessionManagedExternally = false,
    bool nativeAccumulateResults = true,
  }) async {
    final inFlight = _startListeningInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final startFuture = _startListeningInternal(
      iosAudioSessionManagedExternally: iosAudioSessionManagedExternally,
      nativeAccumulateResults: nativeAccumulateResults,
    );
    _startListeningInFlight = startFuture;
    try {
      return await startFuture;
    } finally {
      if (identical(_startListeningInFlight, startFuture)) {
        _startListeningInFlight = null;
      }
    }
  }

  Future<Stream<String>> _startListeningInternal({
    required bool iosAudioSessionManagedExternally,
    required bool nativeAccumulateResults,
  }) async {
    if (!_isInitialized) {
      throw Exception('Voice input not initialized');
    }

    if (_startingLocalStt != null) {
      try {
        await _startingLocalStt;
      } catch (_) {}
    }

    if (_isListening) {
      await stopListening();
    }

    _textStreamController = StreamController<String>.broadcast();
    _transcriptEventController =
        StreamController<VoiceTranscriptEvent>.broadcast();
    _currentText = '';
    _isListening = true;
    _receivedFinalResult = false;
    _completedTranscriptIsSendable = false;
    _cancelNativeDictationSettle();
    _intensityController = StreamController<int>.broadcast();
    _lastIntensity = 0;
    _usingServerStt = false;
    _nativeAccumulateResultsForCurrentListen = nativeAccumulateResults;

    // Optional haptic feedback when listening starts
    final hapticsEnabled = _ref?.read(hapticEnabledProvider) ?? false;
    if (hapticsEnabled) {
      try {
        ConduitHaptics.heavyImpact();
      } catch (_) {}
    }

    _startIntensityDecayTimer();

    final bool canUseLocal = _localSttAvailable;
    final bool serverAvailable = hasServerStt;
    final bool shouldUseLocal =
        canUseLocal && _preference != SttPreference.serverOnly;
    final bool shouldUseServer =
        serverAvailable &&
        (_preference == SttPreference.serverOnly ||
            (!shouldUseLocal && _preference != SttPreference.deviceOnly));

    if (shouldUseLocal) {
      _autoStopTimer?.cancel();
      _autoStopTimer = Timer(_localRecognitionMaxDuration, () {
        if (_isListening) {
          unawaited(_stopListening());
        }
      });
      try {
        debugPrint('Starting local recognition...');
        await _startLocalRecognition(
          allowOnlineFallback: !prefersDeviceOnly,
          iosAudioSessionManagedExternally: iosAudioSessionManagedExternally,
          nativeAccumulateResults: nativeAccumulateResults,
        );
        debugPrint('Local recognition started');
      } catch (error) {
        debugPrint('Failed to start local recognition: $error');
        if (!_isListening) {
          return _textStreamController!.stream;
        }
        _textStreamController?.addError(error);
        await _stopListening();
      }
    } else if (shouldUseServer) {
      _usingServerStt = true;
      _autoStopTimer?.cancel();
      _autoStopTimer = Timer(const Duration(seconds: 90), () {
        if (_isListening) {
          unawaited(_stopListening());
        }
      });
      Future(() async {
        try {
          await _startServerRecording(
            iosAudioSessionManagedExternally: iosAudioSessionManagedExternally,
          );
        } catch (error) {
          if (!_isListening) return;
          _textStreamController?.addError(error);
          await _stopListening();
        }
      });
    } else {
      final Exception error;
      if (prefersDeviceOnly) {
        error = Exception(
          'On-device speech recognition required but unavailable',
        );
      } else if (prefersServerOnly) {
        error = Exception('Server speech-to-text is not configured');
      } else {
        error = Exception('Speech recognition not available on this device');
      }
      Future.microtask(() {
        _textStreamController?.addError(error);
        unawaited(_stopListening());
      });
    }

    return _textStreamController?.stream ?? const Stream<String>.empty();
  }

  /// Centralized entry point to begin voice recognition.
  /// Ensures initialization and microphone permission before starting.
  Future<Stream<String>> beginListening({
    bool iosAudioSessionManagedExternally = false,
    bool nativeAccumulateResults = true,
  }) async {
    await initialize();
    // For on-device STT we preflight the microphone permission so we can
    // fail fast with a clear error before starting any recognition.
    //
    // For server-only STT we skip the preflight check and let the VAD /
    // recording pipeline request or validate permissions as needed. This
    // avoids false negatives from the lightweight probe and prevents
    // blocking server STT when the platform would otherwise allow it.
    if (!prefersServerOnly) {
      final hasMic = await checkPermissions();
      if (!hasMic) {
        throw Exception('Microphone permission not granted');
      }
    }
    return await startListening(
      iosAudioSessionManagedExternally: iosAudioSessionManagedExternally,
      nativeAccumulateResults: nativeAccumulateResults,
    );
  }

  Future<Stream<VoiceTranscriptEvent>> beginListeningEvents({
    bool iosAudioSessionManagedExternally = false,
  }) async {
    await beginListening(
      iosAudioSessionManagedExternally: iosAudioSessionManagedExternally,
      nativeAccumulateResults: false,
    );
    return transcriptEvents;
  }

  Future<void> stopListening() async {
    await _stopListening();
  }

  Future<void> _stopListening() async {
    if (!_isListening) {
      return;
    }

    _autoStopTimer?.cancel();
    _autoStopTimer = null;
    _cancelNativeDictationSettle();

    if (_usingServerStt) {
      _isListening = false;
      await _stopVadRecording();
      final samples = _vadPendingSamples;
      _vadPendingSamples = null;
      final hasActiveTextConsumer = _textStreamController?.hasListener ?? false;
      if (samples != null && samples.isNotEmpty && hasActiveTextConsumer) {
        await _processVadSamples(samples);
      }
    } else {
      final wasUsingNativeLocalStt = _usingNativeLocalStt;
      await _stopNativeLocalStt();
      _completedTranscriptIsSendable =
          _currentText.trim().isNotEmpty && _receivedFinalResult;
      _isListening = false;
      if (_currentText.isNotEmpty &&
          (!wasUsingNativeLocalStt || !_receivedFinalResult)) {
        _textStreamController?.add(_currentText);
      }
    }

    _intensityDecayTimer?.cancel();
    _intensityDecayTimer = null;
    _lastIntensity = 0;

    await _closeControllers();

    _usingServerStt = false;
    await _releaseBackgroundMicrophone();
  }

  Future<void> _stopNativeLocalStt() async {
    final pendingStart = _startingLocalStt;
    if (pendingStart != null) {
      try {
        await pendingStart;
      } catch (_) {}
    }

    _localSttActive = false;
    _usingNativeLocalStt = false;
    final subscription = _nativeSttSub;
    _nativeSttSub = null;
    await subscription?.cancel();
    try {
      await _nativeStt.stopListening();
    } catch (_) {}
  }

  Future<void> _releaseBackgroundMicrophone() async {
    if (!Platform.isIOS || !_backgroundMicPinned) return;
    _backgroundMicPinned = false;
    try {
      await BackgroundStreamingHandler.instance.stopBackgroundExecution(const [
        _backgroundSttStreamId,
      ]);
    } catch (_) {}
  }

  Future<void> _ensureLocalSttReset() async {
    _cancelNativeDictationSettle();
    _localSttActive = false;
    _usingNativeLocalStt = false;
    final subscription = _nativeSttSub;
    _nativeSttSub = null;
    await subscription?.cancel();
    try {
      await _nativeStt.stopListening();
    } catch (_) {}
  }

  Future<void> _startServerRecording({
    required bool iosAudioSessionManagedExternally,
  }) async {
    // Make sure any previous recorder session is fully stopped before we
    // dispose/create handlers. This avoids Android VAD races where internal
    // frame callbacks outlive immediate dispose().
    await _stopVadRecording();
    await _disposeVadHandler();
    _vadPendingSamples = null;

    // Create a fresh VadHandler for this session to avoid reusing any
    // internal AudioRecorder that may be in a bad state after errors.
    final vad = VadHandler.create();
    _vadHandler = vad;
    await _setupVadStreams(vad);
    final settings = _ref?.read(appSettingsProvider);
    final silenceMs =
        settings?.voiceSilenceDuration ??
        SettingsService.defaultVoiceSilenceDurationMs;
    final redemptionFrames = silenceDurationToVadFrames(
      silenceMs,
      frameSamples: _vadFrameSamples,
    );

    try {
      await vad.startListening(
        frameSamples: _vadFrameSamples,
        model: 'v5',
        baseAssetPath: _bundledVadAssetBasePath,
        minSpeechFrames: _vadMinSpeechFrames,
        preSpeechPadFrames: _vadPreSpeechPadFrames,
        redemptionFrames: redemptionFrames,
        endSpeechPadFrames: _vadEndSpeechPadFrames,
        positiveSpeechThreshold: _vadPositiveSpeechThreshold,
        negativeSpeechThreshold: _vadNegativeSpeechThreshold,
        submitUserSpeechOnPause: true,
        recordConfig: RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _vadSampleRate,
          numChannels: 1,
          bitRate: 16,
          echoCancel: true,
          autoGain: false,
          noiseSuppress: true,
          androidConfig: _androidServerVadRecordConfig(
            voiceCallSession:
                Platform.isAndroid && iosAudioSessionManagedExternally,
          ),
          iosConfig: iosAudioSessionManagedExternally
              ? _iosManagedServerVadRecordConfig
              : _iosStandaloneServerVadRecordConfig,
        ),
      );
    } catch (error) {
      // If starting the audio stream fails (e.g. recorder disposed),
      // drop this handler so the next session gets a clean instance.
      if (identical(_vadHandler, vad)) {
        _vadHandler = null;
        try {
          await vad.dispose();
        } catch (_) {}
      }

      // Known Android issue: the underlying AudioRecorder can be in a bad
      // state after audio focus changes triggered by TTS playback. When
      // this happens and local STT is available, transparently fall back
      // to on-device STT instead of failing the entire voice turn.
      final canFallbackToLocal = _localSttAvailable && !prefersServerOnly;
      if (error is PlatformException &&
          error.code == 'record' &&
          (error.message ?? '').contains(
            'Recorder has not yet been created or has already been disposed.',
          ) &&
          canFallbackToLocal &&
          _isListening) {
        debugPrint(
          'VadHandler.startListening failed due to recorder error – '
          'falling back to local STT.',
        );
        _usingServerStt = false;
        try {
          await _stopVadRecording();
        } catch (_) {}
        try {
          await _startLocalRecognition(
            allowOnlineFallback: !prefersDeviceOnly,
            iosAudioSessionManagedExternally: iosAudioSessionManagedExternally,
            nativeAccumulateResults: _nativeAccumulateResultsForCurrentListen,
          );
          return;
        } catch (fallbackError) {
          _textStreamController?.addError(fallbackError);
          rethrow;
        }
      }

      _textStreamController?.addError(error);
      rethrow;
    }
  }

  Future<void> _setupVadStreams(VadHandler vad) async {
    await _vadSpeechEndSub?.cancel();
    _vadSpeechEndSub = vad.onSpeechEnd.listen((samples) {
      if (!_isListening || !_usingServerStt) return;
      if (samples.isEmpty) return;
      _vadPendingSamples = samples;
      if (_isListening) {
        unawaited(_stopListening());
      }
    });

    await _vadFrameSub?.cancel();
    _vadFrameSub = vad.onFrameProcessed.listen((frameData) {
      if (!_isListening) return;
      final intensity = _intensityFromVadFrame(frameData.frame);
      _lastIntensity = intensity;
      try {
        _intensityController?.add(_lastIntensity);
      } catch (_) {}
    });

    await _vadErrorSub?.cancel();
    _vadErrorSub = vad.onError.listen((message) {
      _textStreamController?.addError(Exception(message));
      if (_isListening) {
        unawaited(_stopListening());
      }
    });
  }

  Future<void> _stopVadRecording() async {
    final vad = _vadHandler;
    if (vad != null) {
      try {
        await vad.stopListening();
      } catch (_) {}
    }
    await _vadSpeechEndSub?.cancel();
    _vadSpeechEndSub = null;
    await _vadFrameSub?.cancel();
    _vadFrameSub = null;
    await _vadErrorSub?.cancel();
    _vadErrorSub = null;
  }

  Future<void> _disposeVadHandler() async {
    final vad = _vadHandler;
    _vadHandler = null;
    if (vad != null) {
      try {
        // Give the recorder callback loop a brief window to quiesce before
        // disposing internal stream controllers.
        await Future<void>.delayed(_vadDisposeCooldown);
        await vad.dispose();
      } catch (_) {}
    }
  }

  Future<void> _processVadSamples(List<double> samples) async {
    final api = _api;
    if (api == null) return;

    try {
      final wavBytes = _samplesToWav(samples);
      final fileName =
          'conduit_voice_${DateTime.now().millisecondsSinceEpoch}.wav';

      final response = await api.transcribeSpeech(
        audioBytes: wavBytes,
        fileName: fileName,
        mimeType: 'audio/wav',
        language: _languageForServer(),
      );

      final transcript = _extractTranscriptionText(response);
      if (transcript != null && transcript.trim().isNotEmpty) {
        _currentText = transcript.trim();
        _completedTranscriptIsSendable = true;
        _textStreamController?.add(_currentText);
        _transcriptEventController?.add(
          VoiceTranscriptEvent(text: _currentText, isFinal: true),
        );
      } else {
        throw StateError('Empty transcription result');
      }
    } catch (error) {
      _textStreamController?.addError(error);
    }
  }

  /// Converts a silence timeout into VAD frames without shortening the pause.
  @visibleForTesting
  static int silenceDurationToVadFrames(
    int milliseconds, {
    int frameSamples = _vadFrameSamples,
  }) {
    final frameDurationMs = (frameSamples / _vadSampleRate) * 1000;
    final frames = (milliseconds / frameDurationMs).ceil();
    return frames.clamp(_minVadRedemptionFrames, _maxVadRedemptionFrames);
  }

  @visibleForTesting
  static String? resolveServerLanguageHint({String? configuredLanguageCode}) {
    // Open WebUI auto-detects speech language only when the language form
    // field is omitted. A null setting must therefore stay null.
    return SettingsService.normalizeSttLanguageCode(configuredLanguageCode);
  }

  @visibleForTesting
  static bool shouldSettleNativeDictationForTesting({
    required bool isFinal,
    required bool nativeAccumulateResults,
    required bool usingServerStt,
  }) {
    return _shouldSettleNativeDictation(
      isFinal: isFinal,
      nativeAccumulateResults: nativeAccumulateResults,
      usingServerStt: usingServerStt,
    );
  }

  static bool _shouldSettleNativeDictation({
    required bool isFinal,
    required bool nativeAccumulateResults,
    required bool usingServerStt,
  }) {
    return isFinal && nativeAccumulateResults && !usingServerStt;
  }

  int _intensityFromVadFrame(List<double> frame) {
    if (frame.isEmpty) return 0;
    double peak = 0;
    for (final sample in frame) {
      final value = sample.abs();
      if (value > peak) {
        peak = value;
      }
    }
    final scaled = (peak * 12).round();
    return scaled.clamp(0, 10);
  }

  Uint8List _samplesToWav(List<double> samples) {
    if (samples.isEmpty) {
      return Uint8List(0);
    }
    final dataLength = samples.length * 2; // 2 bytes per sample (16-bit)
    final bytesPerSample = 2;
    final numChannels = 1;
    final byteRate = _vadSampleRate * numChannels * bytesPerSample;
    final blockAlign = numChannels * bytesPerSample;
    const headerSize = 44;

    final totalSize = headerSize + dataLength;
    final buffer = Uint8List(totalSize);
    final view = ByteData.view(buffer.buffer);

    // RIFF chunk
    buffer.setRange(0, 4, ascii.encode('RIFF'));
    view.setUint32(4, 36 + dataLength, Endian.little);
    buffer.setRange(8, 12, ascii.encode('WAVE'));

    // fmt chunk
    buffer.setRange(12, 16, ascii.encode('fmt '));
    view.setUint32(16, 16, Endian.little); // PCM chunk size
    view.setUint16(20, 1, Endian.little); // AudioFormat (1 = PCM)
    view.setUint16(22, numChannels, Endian.little);
    view.setUint32(24, _vadSampleRate, Endian.little);
    view.setUint32(28, byteRate, Endian.little);
    view.setUint16(32, blockAlign, Endian.little);
    view.setUint16(34, 16, Endian.little); // BitsPerSample

    // data chunk
    buffer.setRange(36, 40, ascii.encode('data'));
    view.setUint32(40, dataLength, Endian.little);

    // Write samples
    var offset = 44;
    for (var i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      // Convert float to 16-bit PCM
      final pcm = (clamped * 32767).round().clamp(-32768, 32767);
      view.setInt16(offset, pcm, Endian.little);
      offset += 2;
    }

    return buffer;
  }

  String? _languageForServer() {
    final settings = _ref?.read(appSettingsProvider);
    return resolveServerLanguageHint(
      configuredLanguageCode: settings?.sttLanguageCode,
    );
  }

  String? _extractTranscriptionText(Map<String, dynamic> data) {
    final direct = data['text'];
    if (direct is String && direct.trim().isNotEmpty) {
      return direct;
    }

    final display = data['display_text'] ?? data['DisplayText'];
    if (display is String && display.trim().isNotEmpty) {
      return display;
    }

    final result = data['result'];
    if (result is Map<String, dynamic>) {
      final resultText = result['text'];
      if (resultText is String && resultText.trim().isNotEmpty) {
        return resultText;
      }
    }

    final combined = data['combinedRecognizedPhrases'];
    if (combined is List && combined.isNotEmpty) {
      final first = combined.first;
      if (first is Map<String, dynamic>) {
        final candidate =
            first['display'] ??
            first['Display'] ??
            first['transcript'] ??
            first['text'];
        if (candidate is String && candidate.trim().isNotEmpty) {
          return candidate;
        }
      } else if (first is String && first.trim().isNotEmpty) {
        return first;
      }
    }

    final results = data['results'];
    if (results is Map<String, dynamic>) {
      final channels = results['channels'];
      if (channels is List && channels.isNotEmpty) {
        final channel = channels.first;
        if (channel is Map<String, dynamic>) {
          final alternatives = channel['alternatives'];
          if (alternatives is List && alternatives.isNotEmpty) {
            final alternative = alternatives.first;
            if (alternative is Map<String, dynamic>) {
              final transcript =
                  alternative['transcript'] ?? alternative['text'];
              if (transcript is String && transcript.trim().isNotEmpty) {
                return transcript;
              }
            }
          }
        }
      }
    }

    final segments = data['segments'];
    if (segments is List && segments.isNotEmpty) {
      final buffer = StringBuffer();
      for (final segment in segments) {
        if (segment is Map<String, dynamic>) {
          final text = segment['text'];
          if (text is String && text.trim().isNotEmpty) {
            buffer.write(text.trim());
            buffer.write(' ');
          }
        } else if (segment is String && segment.trim().isNotEmpty) {
          buffer.write(segment.trim());
          buffer.write(' ');
        }
      }
      final combinedText = buffer.toString().trim();
      if (combinedText.isNotEmpty) {
        return combinedText;
      }
    }

    return null;
  }

  Future<void> _closeControllers() async {
    if (_textStreamController != null) {
      try {
        await _textStreamController?.close();
      } catch (_) {}
      _textStreamController = null;
    }
    if (_transcriptEventController != null) {
      try {
        await _transcriptEventController?.close();
      } catch (_) {}
      _transcriptEventController = null;
    }
    if (_intensityController != null) {
      try {
        await _intensityController?.close();
      } catch (_) {}
      _intensityController = null;
    }
  }

  void _startIntensityDecayTimer() {
    _intensityDecayTimer?.cancel();
    _intensityDecayTimer = Timer.periodic(const Duration(milliseconds: 120), (
      _,
    ) {
      if (!_isListening) return;
      if (_lastIntensity <= 0) return;
      _lastIntensity = (_lastIntensity - 1).clamp(0, 10);
      try {
        _intensityController?.add(_lastIntensity);
      } catch (_) {}
    });
  }

  Future<void> dispose() async {
    await stopListening();
    _cancelNativeDictationSettle();
    await _disposeVadHandler();
    await _nativeSttSub?.cancel();
    _nativeSttSub = null;
    try {
      await _nativeStt.stopListening();
    } catch (_) {}
  }
}

final voiceInputServiceProvider = Provider<VoiceInputService>((ref) {
  final api = ref.watch(apiServiceProvider);
  final service = VoiceInputService(api: api, ref: ref);
  final currentSettings = ref.read(appSettingsProvider);
  service.updatePreference(currentSettings.sttPreference);
  ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
    if (previous?.sttPreference != next.sttPreference) {
      service.updatePreference(next.sttPreference);
    }
  });
  ref.onDispose(service.dispose);
  return service;
});

@Riverpod(keepAlive: true)
Future<bool> voiceInputAvailable(Ref ref) async {
  final service = ref.watch(voiceInputServiceProvider);
  if (!service.isSupportedPlatform) return false;

  // IMPORTANT:
  // Do NOT initialize STT or request microphone/speech permissions here.
  // This provider is watched by the chat UI during app startup; calling
  // initialize() or checkPermissions() would trigger permission dialogs
  // before the user explicitly opts into voice features.
  //
  // Instead, treat voice input as "available" based on platform support
  // and configuration only. The actual initialization + permission flow
  // happens on-demand via VoiceInputService.beginListening().

  // If the user prefers server-only STT, only expose voice input when a
  // server STT backend is configured.
  if (service.preference == SttPreference.serverOnly) {
    return service.hasServerStt;
  }

  // For device-only (or mixed) preferences, assume voice input is
  // potentially available on supported platforms. Any missing
  // permissions or lack of local STT support will be handled when
  // beginListening() is called.
  return true;
}

final voiceInputStreamProvider = StreamProvider<String>((ref) {
  final service = ref.watch(voiceInputServiceProvider);
  return service.textStream;
});

/// Stream of crude voice intensity for waveform visuals
final voiceIntensityStreamProvider = StreamProvider<int>((ref) {
  final service = ref.watch(voiceInputServiceProvider);
  return service.intensityStream;
});

final localVoiceRecognitionAvailableProvider = FutureProvider<bool>((
  ref,
) async {
  final service = ref.watch(voiceInputServiceProvider);
  final initialized = await service.initialize(forceLocalStt: true);
  if (!initialized) return false;
  if (service.hasLocalStt) return true;
  return service.checkOnDeviceSupport();
});

final serverVoiceRecognitionAvailableProvider = Provider<bool>((ref) {
  final service = ref.watch(voiceInputServiceProvider);
  return service.hasServerStt;
});
