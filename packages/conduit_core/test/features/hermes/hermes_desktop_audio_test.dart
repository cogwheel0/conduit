import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:test/test.dart';

final class _AudioBridge implements HermesDashboardBridge {
  _AudioBridge(this.reply);

  final String reply;
  final List<({String method, Uri url, Map<String, dynamic>? body})> requests =
      [];

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
  }) async {
    requests.add((
      method: method,
      url: url,
      body: body == null ? null : jsonDecode(body) as Map<String, dynamic>,
    ));
    return (status: 200, body: reply);
  }

  @override
  Future<void> reload() async {}

  @override
  Future<void> close() async {}
}

HermesDesktopApiService _service(_AudioBridge bridge) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
      desktopProfile: 'work',
    ),
    dashboardBridgeFactory: ({required root, required accessHeaders}) => bridge,
  );
  addTearDown(service.close);
  return service;
}

void main() {
  test('speech is sent to the profile as a data URL', () async {
    final bridge = _AudioBridge(
      '{"ok":true,"transcript":"  what time is it ","provider":"openai"}',
    );
    final audio = Uint8List.fromList([1, 2, 3, 4]);

    final transcript = await _service(bridge)
        .transcribeAudio(audio, mimeType: 'audio/wav');

    check(transcript).equals('what time is it');
    final request = bridge.requests.single;
    check(request.method).equals('POST');
    check(request.url.path).equals('/api/audio/transcribe');
    check(request.url.queryParameters).deepEquals({'profile': 'work'});
    check(request.body).isNotNull().deepEquals({
      'data_url': 'data:audio/wav;base64,${base64Encode(audio)}',
      'mime_type': 'audio/wav',
    });
  });

  test('no speech heard is an empty transcript', () async {
    final bridge = _AudioBridge('{"ok":true,"transcript":"","provider":"x"}');

    final transcript = await _service(bridge)
        .transcribeAudio(Uint8List.fromList([0]), mimeType: 'audio/wav');

    check(transcript).isEmpty();
  });

  test('spoken audio is decoded from its data URL', () async {
    final bridge = _AudioBridge(
      jsonEncode({
        'ok': true,
        'data_url': 'data:audio/mpeg;base64,${base64Encode([9, 8, 7])}',
        'mime_type': 'audio/mpeg',
        'provider': 'edge',
      }),
    );

    final speech = await _service(bridge).speak('Hello.');

    check(speech.bytes).deepEquals([9, 8, 7]);
    check(speech.mimeType).equals('audio/mpeg');
    final request = bridge.requests.single;
    check(request.url.path).equals('/api/audio/speak');
    check(request.url.queryParameters).deepEquals({'profile': 'work'});
    check(request.body).isNotNull().deepEquals({'text': 'Hello.'});
  });

  test('a reply that is not audio is refused', () async {
    final bridge = _AudioBridge(
      jsonEncode({'ok': true, 'data_url': 'data:text/html;base64,PGh0bWw+'}),
    );

    await check(_service(bridge).speak('Hello.')).throws<StateError>();
  });

  test('voice-live status says whether calls run through GPT-Live', () async {
    final live = await _service(
      _AudioBridge(
        '{"ok":true,"mode":"gpt-live","available":true,"reason":null,'
        '"model":"gpt-live-1","voice":"marin"}',
      ),
    ).voiceLiveStatus();
    check(live.gptLive).isTrue();
    check(live.available).isTrue();
    check(live.model).equals('gpt-live-1');

    final chained = await _service(
      _AudioBridge('{"ok":true,"mode":"chained","available":false}'),
    ).voiceLiveStatus();
    check(chained.gptLive).isFalse();
    check(chained.available).isFalse();
  });

  test('a voice-live call is opened with the offer exactly as made', () async {
    final bridge = _AudioBridge(
      jsonEncode({
        'ok': true,
        'session': {'id': 'sess-1'},
        'transport': {'type': 'webrtc', 'sdp': 'v=0\r\nanswer\r\n'},
      }),
    );
    const offer = 'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n';

    final session = await _service(bridge).createVoiceLiveSession(
      sdp: offer,
      history: const [
        {'type': 'message', 'role': 'user', 'content': <Object>[]},
      ],
    );

    check(session.answerSdp).equals('v=0\r\nanswer\r\n');
    check(session.sessionId).equals('sess-1');
    final request = bridge.requests.single;
    check(request.url.path).equals('/api/audio/voice-live/session');
    check(request.url.queryParameters).deepEquals({'profile': 'work'});
    // The trailing CRLF matters: the provider refuses a trimmed offer.
    check(request.body!['sdp']).equals(offer);
    check(request.body!['history']).isA<List<Object?>>().length.equals(1);
  });

  test('a session without an answer is refused', () async {
    await check(
      _service(_AudioBridge('{"ok":true}')).createVoiceLiveSession(sdp: 'v=0'),
    ).throws<StateError>();
  });

  test('a voice-live turn tells Hermes where it came from', () {
    check(hermesPromptSubmitParams(runtimeId: 'rt-1', text: 'Hi'))
        .deepEquals({'session_id': 'rt-1', 'text': 'Hi'});

    final params = hermesPromptSubmitParams(
      runtimeId: 'rt-1',
      text: 'Weather in Oslo?',
      voiceContext: 'x' * 6100 + 'User: Weather in Oslo?',
    );
    check(params['surface']).equals('voice-live');
    final context = params['voice_context']! as String;
    check(context.length).equals(6000);
    // The newest of a long conversation is what is kept.
    check(context).endsWith('User: Weather in Oslo?');
  });
}
