import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class NativeTtsEvent {
  const NativeTtsEvent({
    required this.type,
    this.message,
    this.start,
    this.end,
  });

  final String type;
  final String? message;
  final int? start;
  final int? end;

  factory NativeTtsEvent.fromMap(Map<Object?, Object?> map) {
    return NativeTtsEvent(
      type: (map['type'] as String?) ?? 'unknown',
      message: map['message'] as String?,
      start: (map['start'] as num?)?.toInt(),
      end: (map['end'] as num?)?.toInt(),
    );
  }
}

class NativeTtsService {
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

  Future<bool> speak({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
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
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> stop() => _invokeBool('stop');

  Future<bool> pause() => _invokeBool('pause');

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
