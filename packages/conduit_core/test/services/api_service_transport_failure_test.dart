import 'dart:async';
import 'dart:io' show HttpHeaders, HttpStatus;
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Every request fails before reaching a server, as when the address in use
/// stopped answering.
final class _Unreachable implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw DioException.connectionError(
    requestOptions: options,
    reason: 'Connection refused',
  );

  @override
  void close({bool force = false}) {}
}

/// What answers each path.
typedef _Answers = Map<String, ResponseBody Function()>;

/// Answers each request by its path, as a proxy in front of the server
/// does; Open WebUI's own not-found for any other.
final class _Proxy implements HttpClientAdapter {
  _Proxy(this.answers);

  final _Answers answers;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      answers[options.uri.path]?.call() ??
      _json(HttpStatus.notFound, '{"detail":"Not Found"}');

  @override
  void close({bool force = false}) {}
}

ResponseBody _page(int status) => ResponseBody.fromString(
  '<html><body>Sign in</body></html>',
  status,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=utf-8'],
  },
);

ResponseBody _json(int status, String body) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody _redirect(String location) => ResponseBody.fromString(
  '',
  HttpStatus.found,
  headers: {
    HttpHeaders.locationHeader: [location],
  },
);

/// A request that cannot reach the server is what tells the app the address
/// in use may be gone: connectivity checks the server, and the route
/// resolver tries its other addresses. So is a proxy in front of the server
/// turning requests away, once its session there expired.
void main() {
  test('a request that cannot reach the server is reported', () async {
    final workerManager = WorkerManager(worker: const InlineWorkerPort());
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server',
        name: 'Server',
        url: 'http://10.0.0.2:3000',
      ),
      workerManager: workerManager,
    );
    api.dio.httpClientAdapter = _Unreachable();
    api.updateAuthToken('session-token');
    final reported = <Uri>[];
    final reports = ConnectivityService.transportFailures.listen(reported.add);
    addTearDown(() async {
      await reports.cancel();
      api.dispose();
      workerManager.dispose();
    });

    await check(api.getCurrentUser()).throws<DioException>();

    check(reported).deepEquals([Uri.parse('http://10.0.0.2:3000')]);
  });

  group('a proxy turning a request away', () {
    const server = 'https://chat.example';
    late ApiService api;
    late List<Uri> rejected;
    late List<Uri> unreachable;

    setUp(() {
      final workerManager = WorkerManager(worker: const InlineWorkerPort());
      api = ApiService(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: server,
        ),
        workerManager: workerManager,
      );
      api.updateAuthToken('session-token');
      rejected = [];
      unreachable = [];
      final rejections = ConnectivityService.routeRejections.listen(
        rejected.add,
      );
      final failures = ConnectivityService.transportFailures.listen(
        unreachable.add,
      );
      addTearDown(() async {
        await rejections.cancel();
        await failures.cancel();
        api.dispose();
        workerManager.dispose();
      });
    });

    Future<void> request(String url, _Answers answers) async {
      api.dio.httpClientAdapter = _Proxy(answers);
      try {
        await api.dio.get<dynamic>(url);
      } on DioException {
        // Refused or not; only what was reported matters here.
      }
    }

    for (final (how, answers) in <(String, _Answers)>[
      (
        'with a redirect to its sign-in elsewhere',
        {'/api/v1/auths/': () => _redirect('https://sso.example/login')},
      ),
      (
        'with its sign-in page on the same address',
        {
          '/api/v1/auths/': () => _redirect('/login'),
          '/login': () => _page(HttpStatus.ok),
        },
      ),
      (
        'with a page refusing access',
        {'/api/v1/auths/': () => _page(HttpStatus.unauthorized)},
      ),
      (
        'with a page forbidding access',
        {'/api/v1/auths/': () => _page(HttpStatus.forbidden)},
      ),
    ]) {
      test('$how is reported', () async {
        await request('/api/v1/auths/', answers);

        check(rejected).deepEquals([Uri.parse(server)]);
        // The address answered; connectivity hears nothing of it.
        check(unreachable).isEmpty();
      });
    }

    for (final (what, url, answers) in <(String, String, _Answers)>[
      (
        'Open WebUI refusing access',
        '/api/v1/auths/',
        {
          '/api/v1/auths/': () =>
              _json(HttpStatus.unauthorized, '{"detail":"Not authenticated"}'),
        },
      ),
      (
        'Open WebUI forbidding access',
        '/api/v1/auths/',
        {
          '/api/v1/auths/': () =>
              _json(HttpStatus.forbidden, '{"detail":"Forbidden"}'),
        },
      ),
      // As an older server answers an endpoint it does not have.
      (
        "the server's web app answering an address it does not know",
        '/api/v1/calendar/',
        {'/api/v1/calendar/': () => _page(HttpStatus.ok)},
      ),
      (
        'a redirect from another address',
        'https://cdn.example/image.png',
        {'/image.png': () => _redirect('https://sso.example/login')},
      ),
    ]) {
      test('$what is not reported', () async {
        await request(url, answers);

        check(rejected).isEmpty();
      });
    }
  });
}
