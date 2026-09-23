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

  Future<VoiceModels> models() =>
      _call(ConduitMethods.voiceModels, null, VoiceModels.fromJson);

  Future<VoiceModels> downloadModel(String id) => _call(
    ConduitMethods.voiceDownloadModel,
    VoiceModelRef(id: id).toJson(),
    VoiceModels.fromJson,
  );

  Future<VoiceModels> deleteModel(String id) async {
    final models = await _call(
      ConduitMethods.voiceDeleteModel,
      VoiceModelRef(id: id).toJson(),
      VoiceModels.fromJson,
    );
    _ref.invalidate(voiceSettingsProvider);
    return models;
  }

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

/// The whisper models (M11): listed once, then kept current by
/// `voice.changed` as downloads move. A finished one changes what the
/// settings say is ready, so they are asked again.
final voiceModelsProvider = StreamProvider<VoiceModels>((ref) async* {
  ref.watch(coreConnectionProvider);
  final client = ref.watch(rpcClientProvider);
  final changes = client.events
      .where((envelope) => envelope.event == ConduitEvents.voiceChanged)
      .map((envelope) => VoiceModels.fromJson(envelope.payload));
  var downloaded = <String>{};
  Set<String> ready(VoiceModels models) => <String>{
    for (final model in models.models)
      if (model.downloaded) model.id,
  };
  final first = await ref.read(voiceActionsProvider).models();
  downloaded = ready(first);
  yield first;
  await for (final models in changes) {
    final now = ready(models);
    if (now.length != downloaded.length || !now.containsAll(downloaded)) {
      downloaded = now;
      ref.invalidate(voiceSettingsProvider);
    }
    yield models;
  }
});
