import 'dart:async';
import 'dart:typed_data';

import 'package:conduit_core/features/chat/server_speech/server_speech.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart'
    show currentPreferenceAccountId;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'models_service.dart';
import 'settled.dart';
import 'voice_service.dart';

/// `dictation.status` and `POST /transcribe`: what dictation can use, and
/// a recording as text.
///
/// The window listens, records and finds the pauses; this is where audio
/// is turned into text off this computer's own recognizer. On the server
/// that is the chat's own backend, as the phone's core picks it
/// ([serverSpeechProviderFor]): an Open WebUI server for its models, the
/// Voice Provider for Direct and Apple models, a Hermes Desktop Gateway for
/// Hermes, a LibreChat server for its own. Audio never goes to a backend
/// the chat does not belong to. Locally it is whisper ([VoiceService]).
final class DictationService {
  DictationService(this._container, {required VoiceService voice})
    : _voice = voice;

  final ProviderContainer _container;
  final VoiceService _voice;

  /// Which engine dictation uses now (Settings › Audio), and what each can
  /// do for [target]'s model.
  Future<DictationStatus> status(DictationTarget target) async {
    final stored = _container.read(appSettingsProvider);
    final speech = await _serverSpeech(target.modelId);
    return DictationStatus(
      engine: stored.sttPreference == SttPreference.deviceOnly
          ? 'device'
          : _voice.sttEngine,
      serverAvailable: await _transcribes(speech),
      serverSource: speech?.source.name,
      localAvailable: _voice.localAvailable,
      localReady: _voice.localReady,
      localModel: _voice.localModelId,
      language: SettingsService.normalizeSttLanguageCode(
        stored.sttLanguageCode,
      ),
      silenceMs: stored.voiceSilenceDuration,
    );
  }

  /// The signed-in session and the account in use, read when a
  /// transcription's request begins: its audio can take a while to arrive,
  /// and the chat's model to be read.
  Object session() => (
    epoch: _container.read(openWebUiAuthSessionEpochProvider),
    account: currentPreferenceAccountId(),
  );

  bool _stillSession(Object began) {
    final now = session() as ({Object epoch, String? account});
    return began is ({Object epoch, String? account}) &&
        identical(began.epoch, now.epoch) &&
        began.account == now.account;
  }

  /// [bytes] as text, in the saved language.
  ///
  /// [engine] is `server` or `local`; without one the saved engine, falling
  /// back to the server while whisper has no model (a download under way is
  /// no reason to go deaf). Asked for by name, whisper must be ready.
  /// [session]: the [session] its request began under, if not now.
  Future<VoiceTranscript> transcribe(
    Uint8List bytes, {
    String? contentType,
    String? engine,
    String? modelId,
    Object? session,
  }) async {
    if (bytes.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'an empty recording',
      );
    }
    final type = (contentType ?? 'audio/wav').split(';').first.trim();
    final chosen = engine ?? _voice.sttEngine;
    if (chosen != 'server' && chosen != 'local') {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'no engine "$chosen"',
      );
    }
    if (chosen == 'local' && (engine != null || _voice.localReady)) {
      return _voice.transcribeHere(bytes, type);
    }
    final speech = await _serverSpeech(modelId);
    if (speech == null || !await _transcribes(speech)) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: "this chat's backend does not transcribe",
      );
    }
    // Another account signed in since the request began: its audio goes to
    // no backend of that account's. No await between this and the send.
    if (session != null && !_stillSession(session)) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed during the transcription',
        // The recording stays: Try Again sends it under the account now.
        retryable: true,
      );
    }
    final language = SettingsService.normalizeSttLanguageCode(
      _container.read(appSettingsProvider).sttLanguageCode,
    );
    try {
      final text = await speech.transcribe(
        bytes,
        fileName: 'dictation.${_extensionFor(type)}',
        mimeType: type,
        language: language,
      );
      return VoiceTranscript(text: text.trim());
    } on DioException catch (error) {
      throw VoiceService.rpcErrorFromDio(error);
    } on RpcError {
      rethrow;
    } on Object catch (error) {
      DebugLogger.warning(
        'transcription-failed',
        scope: 'daemon/dictation',
        data: <String, Object?>{
          'source': speech.source.name,
          'error': error.runtimeType.toString(),
        },
      );
      throw const RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: 'the server could not transcribe it',
        retryable: true,
      );
    }
  }

  /// Whether [speech] transcribes: set up for it, and for an Open WebUI
  /// server, its STT engine is not the browser's.
  Future<bool> _transcribes(ServerSpeechProvider? speech) async {
    if (speech == null || !speech.canTranscribe) return false;
    if (speech.source != ServerSpeechSource.openWebUi) return true;
    return _voice.openWebUiTranscribes();
  }

  Future<ServerSpeechProvider?> _serverSpeech(String? modelId) async {
    final model = await _model(modelId);
    if (model == null && modelId != null && modelId.trim().isNotEmpty) {
      return null;
    }
    if (model != null && isLibreChatModel(model)) {
      // Its engines load once per account; wait for that read.
      try {
        await readSettled(
          _container,
          libreChatServerSpeechProvider.future,
        ).timeout(const Duration(seconds: 10));
      } on Object {
        return null;
      }
    }
    return serverSpeechProviderFor(_container.read, model);
  }

  /// The model [id] names, as the core minted it (Direct, Hermes and
  /// LibreChat models are known by identity); the account's default for
  /// none; null for a Direct or Hermes id that is not available.
  Future<Model?> _model(String? id) async {
    final wanted = id?.trim();
    if (wanted == null || wanted.isEmpty) return currentModel(_container);
    List<Model> models;
    try {
      models = await readSettled(_container, modelsProvider.future);
    } on Object {
      models = _container.read(modelsProvider).value ?? const <Model>[];
    }
    final known = models.where((m) => m.id == wanted).firstOrNull;
    if (known != null) return known;
    if (DirectModelId.decode(wanted) != null) {
      try {
        final state = await readSettled(
          _container,
          directModelDiscoveryProvider.future,
        );
        return state.models.where((m) => m.id == wanted).firstOrNull;
      } on Object {
        return null;
      }
    }
    if (wanted.startsWith(kHermesModelIdPrefix)) return null;
    // An Open WebUI model the list has not loaded yet.
    return Model(id: wanted, name: wanted);
  }

  static String _extensionFor(String type) => switch (type) {
    'audio/ogg' => 'ogg',
    'audio/wav' || 'audio/x-wav' || 'audio/wave' => 'wav',
    'audio/mp4' || 'audio/m4a' || 'audio/x-m4a' => 'm4a',
    'audio/mpeg' || 'audio/mp3' => 'mp3',
    _ => 'webm',
  };
}
