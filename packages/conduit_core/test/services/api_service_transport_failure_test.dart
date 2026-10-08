import 'dart:async';
import 'dart:io' show HttpHeaders, HttpStatus;
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
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

/// Upgrades a plain-HTTP request to HTTPS on the same host, where nothing
/// answers.
final class _UpgradingToNothing implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.scheme == 'http') {
      return _redirect(options.uri.replace(scheme: 'https').toString());
    }
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'Connection refused',
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Upgrades a plain-HTTP request to HTTPS on the same host, where the proxy
/// refuses it with its sign-in page.
final class _UpgradingProxy implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => options.uri.scheme == 'http'
      ? _redirect(options.uri.replace(scheme: 'https').toString())
      : _page(HttpStatus.unauthorized);

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

  test('a request upgraded to HTTPS that cannot reach the server is '
      'reported for its address', () async {
    final workerManager = WorkerManager(worker: const InlineWorkerPort());
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server',
        name: 'Server',
        url: 'http://chat.example',
      ),
      workerManager: workerManager,
    );
    api.dio.httpClientAdapter = _UpgradingToNothing();
    api.updateAuthToken('session-token');
    final reported = <Uri>[];
    final reports = ConnectivityService.transportFailures.listen(reported.add);
    addTearDown(() async {
      await reports.cancel();
      api.dispose();
      workerManager.dispose();
    });

    await check(api.dio.get<dynamic>('/api/v1/auths/')).throws<DioException>();

    check(reported).deepEquals([Uri.parse('http://chat.example')]);
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
        reportsRouteRefusals: true,
      );
      api.updateAuthToken('session-token');
      rejected = [];
      unreachable = [];
      final rejections = ConnectivityService.routeRejections.listen(
        (rejection) => rejected.add(rejection.server),
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

    test('with a page sent with its content type twice is reported, and '
        'the request keeps its own error', () async {
      api.dio.httpClientAdapter = _Proxy({
        '/api/v1/auths/': () => ResponseBody.fromString(
          '<html><body>Sign in</body></html>',
          HttpStatus.unauthorized,
          headers: {
            Headers.contentTypeHeader: [
              'text/html; charset=utf-8',
              'text/html',
            ],
          },
        ),
      });

      await check(api.dio.get<dynamic>('/api/v1/auths/')).throws<DioException>(
        (error) => error
            .has((error) => error.response?.statusCode, 'status')
            .equals(HttpStatus.unauthorized),
      );
      check(rejected).deepEquals([Uri.parse(server)]);
    });

    // A client checking an address, or signing in another account, carries
    // a session of its own, or none: the account in use is not refused.
    test('to a client other than the app\'s own is not reported', () async {
      final workerManager = WorkerManager(worker: const InlineWorkerPort());
      final checking = ApiService(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: server,
        ),
        workerManager: workerManager,
      );
      addTearDown(() {
        checking.dispose();
        workerManager.dispose();
      });
      checking.updateAuthToken('session-token');
      checking.dio.httpClientAdapter = _Proxy({
        '/api/v1/auths/': () => _redirect('https://sso.example/login'),
      });

      try {
        await checking.dio.get<dynamic>('/api/v1/auths/');
      } on DioException {
        // Refused; only what was reported matters here.
      }

      check(rejected).isEmpty();
    });

    test("to the app's own client is reported", () async {
      PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
      await PreferencesStore.ensureInitialized();
      addTearDown(PreferencesStore.debugReset);
      final workerManager = WorkerManager(worker: const InlineWorkerPort());
      addTearDown(workerManager.dispose);
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          workerManagerProvider.overrideWithValue(workerManager),
          activeServerProvider.overrideWith(
            (ref) async =>
                const ServerConfig(id: 'server', name: 'Server', url: server),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(activeServerProvider.future);
      container.read(apiAuthTokenMirrorProvider.notifier).set('session-token');
      final app = container.read(apiServiceProvider)!;
      app.dio.httpClientAdapter = _Proxy({
        '/api/v1/auths/': () => _redirect('https://sso.example/login'),
      });
      final sentOver = <ServerConfig?>[];
      final connections = ConnectivityService.routeRejections.listen(
        (rejection) => sentOver.add(rejection.connection),
      );
      addTearDown(connections.cancel);

      try {
        await app.dio.get<dynamic>('/api/v1/auths/');
      } on DioException {
        // Refused; only what was reported matters here.
      }

      check(rejected).deepEquals([Uri.parse(server)]);
      // With the connection it was sent over, for the route it came from.
      check(sentOver).deepEquals([app.serverConfig]);
    });

    test('on an address the server upgraded to HTTPS is reported', () async {
      final workerManager = WorkerManager(worker: const InlineWorkerPort());
      final plain = ApiService(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'http://chat.example',
        ),
        workerManager: workerManager,
        reportsRouteRefusals: true,
      );
      addTearDown(() {
        plain.dispose();
        workerManager.dispose();
      });
      plain.updateAuthToken('session-token');
      plain.dio.httpClientAdapter = _UpgradingProxy();

      try {
        await plain.dio.get<dynamic>('/api/v1/auths/');
      } on DioException {
        // Refused; only what was reported matters here.
      }

      check(rejected).deepEquals([Uri.parse('http://chat.example')]);
    });

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

    // A model with no image of its own: Open WebUI redirects to its default.
    test("Open WebUI redirecting a model's image is not reported", () async {
      api.dio.httpClientAdapter = _Proxy({
        '/api/v1/models/model/profile/image': () =>
            _redirect('/static/favicon.png'),
      });

      await api.getWorkspaceModelProfileImage('model');

      check(rejected).isEmpty();
    });

    // A chat request accepts every status only to read an error's body.
    test('a request accepting any status for its error is still reported',
        () async {
      api.dio.httpClientAdapter = _Proxy({
        '/api/chat/completions': () => _redirect('https://sso.example/login'),
      });

      await api.dio.post<dynamic>(
        '/api/chat/completions',
        options: Options(
          validateStatus: (status) => status != null && status < 600,
        ),
      );

      check(rejected).deepEquals([Uri.parse(server)]);
    });
  });
}
