// Open WebUI 0.12.1 channel endpoints: the mute setting
// (`POST /channels/{id}/members/mute`, routers/channels.py) and app button
// presses (`POST /apps/{id}/interactions`, routers/apps.py).
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';

void main() {
  test('mute sends is_channel_muted and returns what the server stored',
      () async {
    final harness = _Harness({'is_channel_muted': true});

    final stored = await harness.api.updateMemberMuteStatus(
      'channel-1',
      isChannelMuted: true,
    );

    check(stored).isTrue();
    final request = harness.requests.single;
    check('${request.method} ${request.path}')
        .equals('POST /api/v1/channels/channel-1/members/mute');
    check(request.data as Map<String, dynamic>)
        .deepEquals({'is_channel_muted': true});
  });

  test('a button press sends the message and action ids', () async {
    final harness = _Harness({
      'type': 'message',
      'visibility': 'private',
      'content': 'Only you',
    });

    final reply = await harness.api.createAppInteraction(
      'app/1',
      messageId: 'message-1',
      actionId: 'redeploy',
    );

    check(reply['content']).equals('Only you');
    final request = harness.requests.single;
    check(request.method).equals('POST');
    // The app id is a path segment, encoded as the web client does.
    check(request.uri.path).equals('/api/v1/apps/app%2F1/interactions');
    // AppInteractionForm forbids any other field.
    check(request.data as Map<String, dynamic>).deepEquals({
      'message_id': 'message-1',
      'action_id': 'redeploy',
    });
  });
}

class _Harness {
  _Harness(Object response) {
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'test',
        name: 'Test',
        url: 'http://localhost:0',
      ),
      workerManager: WorkerManager(),
      authToken: 'token-a',
    );
    api.dio.httpClientAdapter = _Adapter(requests, response);
    addTearDown(api.dispose);
  }

  late final ApiService api;
  final List<RequestOptions> requests = [];
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.requests, this.response);

  final List<RequestOptions> requests;
  final Object response;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(response)))),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
