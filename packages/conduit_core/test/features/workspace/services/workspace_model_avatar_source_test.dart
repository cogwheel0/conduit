import 'dart:io' show HttpHeaders, HttpStatus;
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/workspace/services/workspace_model_avatar_source.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/ports/worker_port.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

const _server = 'https://harbour.example:8443';

/// Answers each request by its full address, and keeps what was asked
/// (with whether it carried the account's credential).
final class _Answers implements HttpClientAdapter {
  _Answers(this.answers);

  final Map<String, ResponseBody Function()> answers;
  final List<(String, bool)> asked = <(String, bool)>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.replace(query: '').toString().replaceAll('?', '');
    asked.add((url, options.headers[HttpHeaders.authorizationHeader] != null));
    return answers[url]?.call() ??
        ResponseBody.fromString('{"detail":"Not Found"}', HttpStatus.notFound);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _bytes(List<int> bytes) => ResponseBody.fromBytes(
  bytes,
  HttpStatus.ok,
  headers: {
    Headers.contentTypeHeader: ['image/png'],
  },
);

ResponseBody _redirect(String location) => ResponseBody.fromString(
  '',
  HttpStatus.found,
  headers: {
    HttpHeaders.locationHeader: [location],
  },
);

void main() {
  group('workspaceModelAvatarSource', () {
    test('a data URL is inline', () {
      check(
        workspaceModelAvatarSource(
          'data:image/png;base64,iVBORw0KGgo=',
          serverBaseUrl: _server,
        ),
      ).equals(WorkspaceModelAvatarSource.inline);
    });

    test('an address on the server, or none, is the server\'s', () {
      for (final url in <String?>[
        null,
        '',
        '/static/favicon.png',
        '$_server/api/v1/files/f1/content',
        'HTTPS://HARBOUR.example:8443/static/gull.png',
      ]) {
        check(
          because: '$url',
          workspaceModelAvatarSource(url, serverBaseUrl: _server),
        ).equals(WorkspaceModelAvatarSource.server);
      }
    });

    test('an address on another site, or another port, is remote', () {
      for (final url in <String>[
        'https://pictures.example/gull.png',
        'https://harbour.example/gull.png',
        'http://harbour.example:8443/gull.png',
      ]) {
        check(
          because: url,
          workspaceModelAvatarSource(url, serverBaseUrl: _server),
        ).equals(WorkspaceModelAvatarSource.remote);
      }
      // With no server to compare with, every web address is another site.
      check(workspaceModelAvatarSource('$_server/static/gull.png'))
          .equals(WorkspaceModelAvatarSource.remote);
    });
  });

  group('getWorkspaceModelAvatar', () {
    late ApiService api;
    late _Answers adapter;

    void serve(Map<String, ResponseBody Function()> answers) {
      adapter = _Answers(answers);
      api.dio.httpClientAdapter = adapter;
    }

    setUp(() {
      api = ApiService(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: _server,
        ),
        workerManager: WorkerManager(worker: const InlineWorkerPort()),
      );
      api.updateAuthToken('session-token');
    });

    test('the image the model keeps comes from the endpoint', () async {
      serve({
        '$_server/api/v1/models/model/profile/image': () => _bytes([1, 2, 3]),
      });

      check(await api.getWorkspaceModelAvatar('gull', imageUrl: 'data:x'))
          .isNotNull()
          .deepEquals([1, 2, 3]);
    });

    test('a picture on the server is fetched with the credential', () async {
      const picture = '$_server/static/gull.png';
      serve({
        '$_server/api/v1/models/model/profile/image': () => _redirect(picture),
        picture: () => _bytes([4, 5]),
      });

      check(await api.getWorkspaceModelAvatar('gull', imageUrl: picture))
          .isNotNull()
          .deepEquals([4, 5]);
      check(adapter.asked.last).equals((picture, true));
    });

    test('another site is never asked', () async {
      const picture = 'https://pictures.example/gull.png';
      serve({
        '$_server/api/v1/models/model/profile/image': () => _redirect(picture),
        picture: () => _bytes([6]),
      });

      check(await api.getWorkspaceModelAvatar('gull', imageUrl: picture))
          .isNull();
      check(adapter.asked.map((a) => a.$1)).not((it) => it.contains(picture));
    });

    test('the default image is no picture of the model\'s own', () async {
      serve({
        '$_server/api/v1/models/model/profile/image': () =>
            _redirect('/static/favicon.png'),
      });

      check(
        await api.getWorkspaceModelAvatar(
          'gull',
          imageUrl: '/static/favicon.png',
        ),
      ).isNull();
    });
  });
}
