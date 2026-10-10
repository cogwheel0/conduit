import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/server_speech/direct_server_speech.dart';
import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_http_client.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

final class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);

  final ResponseBody Function() reply;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    requests.add(options);
    return reply();
  }

  @override
  void close({bool force = false}) {}
}

const _settings = DirectVoiceProviderSettings(
  profileId: 'voice',
  transcriptionModel: 'gpt-4o-mini-transcribe',
  speechModel: 'gpt-4o-mini-tts',
  speechVoice: 'coral',
);

DirectServerSpeech _speech(
  _Adapter adapter, {
  DirectConnectionProfile? profile,
  DirectVoiceProviderSettings settings = _settings,
}) {
  final pool = DirectHttpClientPool(
    // The real configuration, so the key, headers and api-version are the
    // ones a chat request would carry.
    dioFactory: (profile) {
      final dio = Dio()..httpClientAdapter = adapter;
      const DirectHttpClientFactory().configure(dio, profile);
      return dio;
    },
  );
  addTearDown(pool.dispose);
  return DirectServerSpeech(
    profile:
        profile ??
        DirectConnectionProfile(
          id: 'voice',
          name: 'OpenAI',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'sk-test',
        ),
    settings: settings,
    clientPool: pool,
  );
}

void main() {
  test('transcribes through audio/transcriptions with the model', () async {
    final adapter = _Adapter(
      () => ResponseBody.fromString(
        '{"text":"Hello there"}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );

    final transcript = await _speech(adapter).transcribe(
      Uint8List.fromList([1, 2]),
      fileName: 'clip.wav',
      mimeType: 'audio/wav',
      language: 'en',
    );

    check(transcript).equals('Hello there');
    final request = adapter.requests.single;
    check(request.uri.toString())
        .equals('https://api.openai.com/v1/audio/transcriptions');
    check(request.headers['Authorization']).equals('Bearer sk-test');
    final form = request.data as FormData;
    check(Map.fromEntries(form.fields)).deepEquals({
      'model': 'gpt-4o-mini-transcribe',
      'language': 'en',
      'response_format': 'json',
    });
    check(form.files.single.value.filename).equals('clip.wav');
  });

  test('speaks through audio/speech with the chosen voice', () async {
    final adapter = _Adapter(
      () => ResponseBody.fromBytes(
        [7, 7, 7],
        200,
        headers: {
          Headers.contentTypeHeader: ['audio/mpeg'],
        },
      ),
    );

    final speech = await _speech(adapter)
        .synthesize('Hi.', preferredVoice: 'an-open-webui-voice', speed: 1.25);

    check(speech.bytes).deepEquals([7, 7, 7]);
    check(speech.mimeType).equals('audio/mpeg');
    final request = adapter.requests.single;
    check(request.uri.path).equals('/v1/audio/speech');
    check(request.headers['Accept']).equals('audio/mpeg');
    // The voice picked for another backend never reaches this one.
    check(request.data).isA<Map<String, dynamic>>().deepEquals({
      'model': 'gpt-4o-mini-tts',
      'input': 'Hi.',
      'voice': 'coral',
      'response_format': 'mp3',
      'speed': 1.25,
    });
  });

  test('an Azure connection keeps its key header and api-version', () async {
    final adapter = _Adapter(
      () => ResponseBody.fromString(
        '{"text":"ok"}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );

    await _speech(
      adapter,
      profile: DirectConnectionProfile(
        id: 'voice',
        name: 'Azure',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://example.openai.azure.com/openai/v1',
        apiKey: 'azure-key',
        apiKeyAuthMode: DirectApiKeyAuthMode.apiKeyHeader,
        apiVersion: 'preview',
      ),
    ).transcribe(
      Uint8List.fromList([1]),
      fileName: 'clip.wav',
      mimeType: 'audio/wav',
    );

    final request = adapter.requests.single;
    check(request.headers['api-key']).equals('azure-key');
    check(request.headers.containsKey('Authorization')).isFalse();
    check(request.uri.queryParameters).deepEquals({'api-version': 'preview'});
  });

  test('a direction without its models is not offered or sent', () async {
    final adapter = _Adapter(() => throw StateError('no request expected'));
    final speech = _speech(
      adapter,
      settings: const DirectVoiceProviderSettings(
        profileId: 'voice',
        transcriptionModel: 'whisper-1',
        speechModel: 'tts-1',
      ),
    );

    check(speech.canTranscribe).isTrue();
    check(speech.canSynthesize).isFalse();
    await check(speech.synthesize('Hi.')).throws<StateError>();
    check(adapter.requests).isEmpty();
  });

  test('choosing a connection fills OpenAI models and keeps edits', () {
    DirectConnectionProfile profile(String id, String url) =>
        DirectConnectionProfile(
          id: id,
          name: id,
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: url,
        );
    final openAi = profile('openai', 'https://api.openai.com/v1');
    final groq = profile('groq', 'https://api.groq.com/openai/v1');

    final filled = DirectVoiceProviderSettings.forConnection(openAi);
    check(filled.canTranscribe).isTrue();
    check(filled.canSynthesize).isTrue();

    // Another server's model names are its own to enter.
    final blank = DirectVoiceProviderSettings.forConnection(
      groq,
      current: filled,
    );
    check(blank).equals(const DirectVoiceProviderSettings(profileId: 'groq'));

    // Picking the same connection again keeps what was typed.
    final edited = blank.withField(
      DirectVoiceProviderField.transcriptionModel,
      '  whisper-large-v3 ',
    );
    check(edited.transcriptionModel).equals('whisper-large-v3');
    check(DirectVoiceProviderSettings.forConnection(groq, current: edited))
        .equals(edited);
    check(
      edited
          .withField(DirectVoiceProviderField.transcriptionModel, '  ')
          .transcriptionModel,
    ).isNull();
  });

  test('settings survive a round trip and need a connection', () {
    const settings = DirectVoiceProviderSettings(
      profileId: 'voice',
      transcriptionModel: 'whisper-1',
      realtimeModel: 'gpt-realtime',
      realtimeInstructions: '  Be brief.\n',
    );

    check(
      DirectVoiceProviderSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())),
      ),
    ).equals(settings);
    check(DirectVoiceProviderSettings.fromJson({'profile_id': ' '})).isNull();
    check(DirectVoiceProviderSettings.fromJson('garbage')).isNull();
  });
}
