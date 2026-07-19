import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy ServerConfig apiKey is never used as an auth token', () async {
    final workerManager = WorkerManager(debugIsWebOverride: true);
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server',
        name: 'Server',
        url: 'https://server.example',
        apiKey: 'legacy-config-bearer',
      ),
      workerManager: workerManager,
    );
    final adapter = _RecordingAdapter();
    api.dio.httpClientAdapter = adapter;
    addTearDown(() {
      api.dispose();
      workerManager.dispose();
    });

    await api.dio.get<void>('/api/config');
    check(
      adapter.requests.single.headers.keys.map(
        (header) => header.toLowerCase(),
      ),
    ).not((headers) => headers.contains('authorization'));

    api.updateAuthToken('owned-session-token');
    await api.dio.get<void>('/api/config');
    check(
      adapter.requests.last.headers['Authorization'],
    ).equals('Bearer owned-session-token');
  });

  test(
    'credentialed API client never follows a cross-origin redirect',
    () async {
      final destination = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      var destinationRequests = 0;
      destination.listen((request) async {
        destinationRequests++;
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });

      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? sourceProxyCredential;
      String? sourceAuthorization;
      source.listen((request) async {
        sourceProxyCredential = request.headers.value('x-proxy-credential');
        sourceAuthorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://${destination.address.host}:${destination.port}/collect',
        );
        await request.response.close();
      });

      final workerManager = WorkerManager(debugIsWebOverride: true);
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'redirect-source',
          name: 'Redirect source',
          url: 'http://${source.address.host}:${source.port}',
          customHeaders: const {'X-Proxy-Credential': 'proxy-secret'},
        ),
        workerManager: workerManager,
        authToken: 'session-secret',
      );
      addTearDown(() async {
        api.dispose();
        workerManager.dispose();
        await source.close(force: true);
        await destination.close(force: true);
      });

      await expectLater(
        api.dio.get<void>('/redirect'),
        throwsA(isA<DioException>()),
      );
      await Future<void>.delayed(Duration.zero);

      check(sourceProxyCredential).equals('proxy-secret');
      check(sourceAuthorization).equals('Bearer session-secret');
      check(destinationRequests).equals(0);
    },
  );

  test('logout uses POST and remains bound to its auth snapshot', () async {
    final workerManager = WorkerManager(debugIsWebOverride: true);
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server',
        name: 'Server',
        url: 'https://server.example',
      ),
      workerManager: workerManager,
      authToken: 'original-session',
    );
    final adapter = _RecordingAdapter();
    api.dio.httpClientAdapter = adapter;
    addTearDown(() {
      api.dispose();
      workerManager.dispose();
    });

    final original = api.captureAuthSnapshot();
    await api.logout(authSnapshot: original);
    final request = adapter.requests.single;
    check(request.method).equals('POST');
    check(request.path).equals('/api/v1/auths/signout');
    check(
      request.headers[HttpHeaders.authorizationHeader],
    ).equals('Bearer original-session');

    api.updateAuthToken('newer-session');
    await expectLater(
      api.logout(authSnapshot: original),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    check(adapter.requests.length).equals(1);
  });
}

final class _RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
