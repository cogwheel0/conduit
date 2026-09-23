import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../voice_port.dart';
import 'rpc_providers.dart';

/// The window's audio, overridden in `main.dart` (M8).
final voicePortProvider = Provider<VoicePort>((ref) => RecordingVoice());

/// Every `voice.*` call the window makes, in one place so a test replaces
/// the daemon by overriding this.
final voiceActionsProvider = Provider<VoiceActions>(VoiceActions.new);

class VoiceActions {
  VoiceActions(this._ref);

  final Ref _ref;

  Future<T> _call<T>(
    String method,
    Map<String, dynamic>? params,
    T Function(Map<String, dynamic>) decode,
  ) =>
      _ref.read(rpcClientProvider).call(method, params: params, decode: decode);

  Future<VoiceSettings> settings() =>
      _call(ConduitMethods.voiceSettings, null, VoiceSettings.fromJson);

  Future<VoiceSettings> save(VoiceSettingsEdit edit) async {
    final saved = await _call(
      ConduitMethods.voiceSaveSettings,
      edit.toJson(),
      VoiceSettings.fromJson,
    );
    _ref.invalidate(voiceSettingsProvider);
    return saved;
  }

  Future<VoiceVoices> voices() =>
      _call(ConduitMethods.voiceVoices, null, VoiceVoices.fromJson);

  Future<VoiceSpeech> speak(String text) => _call(
    ConduitMethods.voiceSpeak,
    VoiceSpeak(text: text).toJson(),
    VoiceSpeech.fromJson,
  );
}

/// The saved voice settings, and what the active server can do. Asked
/// again when the server or the account changes.
final voiceSettingsProvider = FutureProvider<VoiceSettings>((ref) {
  ref.watch(coreConnectionProvider);
  ref.watch(capabilitiesProvider);
  return ref.read(voiceActionsProvider).settings();
});

final serverVoicesProvider = FutureProvider<VoiceVoices>((ref) {
  ref.watch(capabilitiesProvider);
  return ref.read(voiceActionsProvider).voices();
});

final deviceVoicesProvider = FutureProvider<List<DeviceVoice>>(
  (ref) => ref.read(voicePortProvider).deviceVoices(),
);
