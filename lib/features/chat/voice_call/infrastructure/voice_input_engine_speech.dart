import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/settings_service.dart';
import '../../services/voice_input_service.dart';
import '../domain/voice_call_interfaces.dart';

/// Adapter that exposes [VoiceInputService] through [VoiceInputEngine].
class VoiceInputEngineSpeech implements VoiceInputEngine {
  VoiceInputEngineSpeech(this._service);

  final VoiceInputService _service;

  @override
  bool get hasLocalStt => _service.hasLocalStt;

  @override
  bool get hasServerStt => _service.hasServerStt;

  @override
  bool get prefersServerOnly => _service.prefersServerOnly;

  @override
  bool get prefersDeviceOnly => _service.prefersDeviceOnly;

  @override
  SttPreference get preference => _service.preference;

  @override
  Stream<int> get intensityStream => _service.intensityStream;

  @override
  Future<bool> initialize() => _service.initialize();

  @override
  Future<bool> checkPermissions() => _service.checkPermissions();

  @override
  Future<bool> requestMicrophonePermission() =>
      _service.requestMicrophonePermission();

  @override
  Future<Stream<String>> beginListening() => _service.beginListening();

  @override
  Future<void> stopListening() => _service.stopListening();

  @override
  Future<void> dispose() => _service.dispose();
}

final voiceInputEngineProvider = Provider<VoiceInputEngine>((ref) {
  final service = ref.watch(voiceInputServiceProvider);
  return VoiceInputEngineSpeech(service);
});
