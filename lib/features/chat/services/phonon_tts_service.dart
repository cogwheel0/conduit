import 'package:flutter/services.dart';

import 'native_tts_service.dart';

/// Phonon has a separate channel and identity so Android/system TTS can never
/// satisfy a Zoey request or finish one of its chunks.
class PhononTtsService extends NativeTtsService {
  static const voiceId = 'phonon:31m-en:NbpkqMVS3CJeq2j8';
  static const _methods = MethodChannel('app.cogwheel.conduit/phonon_tts');
  static const _events = EventChannel('app.cogwheel.conduit/phonon_tts/events');
  int _counter = 0;
  int? _activeRequest;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _methods.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Stream<NativeTtsEvent> get events => _events
      .receiveBroadcastStream()
      .where(
        (entry) =>
            entry is Map &&
            entry['backend'] == 'phonon' &&
            entry['voice'] == voiceId &&
            entry['requestId'] == _activeRequest,
      )
      .map(
        (entry) =>
            NativeTtsEvent.fromMap((entry as Map).cast<Object?, Object?>()),
      );

  @override
  Future<bool> speak({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
    bool voiceCall = false,
  }) async {
    final id = ++_counter;
    _activeRequest = id;
    try {
      return await _methods.invokeMethod<bool>('speak', {
            'text': text,
            'voiceIdentifier': voiceId,
            'requestId': id,
            'volume': volume,
            'voiceCall': voiceCall,
          }) ??
          false;
    } catch (_) {
      if (_activeRequest == id) _activeRequest = null;
      rethrow;
    }
  }

  @override
  Future<bool> stop() async {
    _activeRequest = null;
    try {
      return await _methods.invokeMethod<bool>('stop') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> pause() async =>
      await _methods.invokeMethod<bool>('pause') ?? false;

  @override
  Future<bool> resume() async =>
      await _methods.invokeMethod<bool>('resume') ?? false;
}
