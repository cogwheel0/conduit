import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit_core/features/chat/read_aloud/device_speech_engine.dart';
import 'package:flutter/services.dart';

export 'package:conduit_core/features/chat/read_aloud/device_speech_engine.dart'
    show NativeTtsAudio, NativeTtsEvent;

/// The phone's engine: AVSpeechSynthesizer on iOS, TextToSpeech on Android,
/// over platform channels.
class NativeTtsService implements DeviceSpeechEngine {
  static const MethodChannel _iosMethodChannel = MethodChannel(
    'app.cogwheel.conduit/native_ios_tts',
  );
  static const EventChannel _iosEventChannel = EventChannel(
    'app.cogwheel.conduit/native_ios_tts/events',
  );
  static const MethodChannel _androidMethodChannel = MethodChannel(
    'app.cogwheel.conduit/native_android_tts',
  );
  static const EventChannel _androidEventChannel = EventChannel(
    'app.cogwheel.conduit/native_android_tts/events',
  );

  bool get isSupportedPlatform => Platform.isIOS || Platform.isAndroid;

  @override
  String get engineName => Platform.isIOS ? 'AVSpeech' : 'AndroidTTS';

  /// A new utterance is queued or replaces the last with a cancel; a
  /// reading never relies on either.
  @override
  bool get replacesOnSpeak => false;

  MethodChannel? get _methodChannel {
    if (Platform.isIOS) return _iosMethodChannel;
    if (Platform.isAndroid) return _androidMethodChannel;
    return null;
  }

  EventChannel? get _eventChannel {
    if (Platform.isIOS) return _iosEventChannel;
    if (Platform.isAndroid) return _androidEventChannel;
    return null;
  }

  @override
  Stream<NativeTtsEvent> get events {
    final channel = _eventChannel;
    if (!isSupportedPlatform || channel == null) {
      return const Stream<NativeTtsEvent>.empty();
    }
    return channel.receiveBroadcastStream().where((entry) => entry is Map).map((
      entry,
    ) {
      return NativeTtsEvent.fromMap((entry as Map).cast<Object?, Object?>());
    });
  }

  @override
  Future<bool> isAvailable() async {
    final channel = _methodChannel;
    if (!isSupportedPlatform || channel == null) {
      return false;
    }
    try {
      return await channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getVoices() async {
    final channel = _methodChannel;
    if (!isSupportedPlatform || channel == null) {
      return const <Map<String, dynamic>>[];
    }
    try {
      final raw = await channel.invokeListMethod<Object?>('getVoices');
      if (raw == null) {
        return const <Map<String, dynamic>>[];
      }
      return raw
          .whereType<Map>()
          .map(_normalizeVoiceEntry)
          .where((voice) => voice.isNotEmpty)
          .toList(growable: false);
    } on MissingPluginException {
      return const <Map<String, dynamic>>[];
    } on PlatformException {
      return const <Map<String, dynamic>>[];
    }
  }

  /// Speaks [text] on the device engine.
  ///
  /// [voiceCall] keeps playback on the active call route. Android uses the
  /// voice-communication stream; iOS activates the shared call audio session.
  @override
  Future<bool> speak({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
    bool voiceCall = false,
  }) async {
    final channel = _methodChannel;
    if (!isSupportedPlatform || channel == null) {
      return false;
    }
    try {
      return await channel.invokeMethod<bool>('speak', {
            'text': text,
            'voiceIdentifier': voiceIdentifier,
            'rate': rate,
            'pitch': pitch,
            'volume': volume,
            'voiceCall': voiceCall,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Renders device speech to a local file so read-aloud can seek by time.
  @override
  Future<NativeTtsAudio> synthesize({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
  }) async {
    final response = await _methodChannel?.invokeMapMethod<String, Object?>(
      'synthesize',
      {
        'text': text,
        'voiceIdentifier': voiceIdentifier,
        'rate': rate,
        'pitch': pitch,
        'volume': volume,
      },
    );
    final path = response?['path'] as String?;
    final milliseconds = (response?['durationMs'] as num?)?.round();
    if (path == null || milliseconds == null || milliseconds <= 0) {
      throw StateError('Device speech did not produce audio');
    }
    return NativeTtsAudio(path, Duration(milliseconds: milliseconds));
  }

  @override
  Future<bool> cancelSynthesis() => _invokeBool('cancelSynthesis');

  @override
  Future<bool> stop() => _invokeBool('stop');

  @override
  Future<bool> pause() => _invokeBool('pause');

  @override
  Future<bool> resume() => _invokeBool('resume');

  Future<bool> _invokeBool(String method) async {
    final channel = _methodChannel;
    if (!isSupportedPlatform || channel == null) {
      return false;
    }
    try {
      return await channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Map<String, dynamic> _normalizeVoiceEntry(Map<dynamic, dynamic> entry) {
    final normalized = <String, dynamic>{};
    entry.forEach((key, value) {
      if (key != null) {
        normalized[key.toString()] = value;
      }
    });
    return normalized;
  }
}
