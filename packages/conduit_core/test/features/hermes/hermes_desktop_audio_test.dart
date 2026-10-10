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
}
