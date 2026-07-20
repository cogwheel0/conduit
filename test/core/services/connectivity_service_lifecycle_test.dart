import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(ConnectivityService.debugResetTrafficSignals);

  test('a probe settling after dispose cannot install a new timer', () async {
    final connectivity = _OnlineConnectivity();
    final adapter = _BlockingHealthAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final serviceProvider = Provider<ConnectivityService>(
      (ref) => ConnectivityService(dio, ref, connectivity),
    );
    final container = ProviderContainer(
      overrides: [
        activeServerProvider.overrideWith(
          (_) async => const ServerConfig(
            id: 'server',
            name: 'Server',
            url: 'https://server.example',
          ),
        ),
        apiServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(connectivity.dispose);
    addTearDown(dio.close);

    await container.read(activeServerProvider.future);
    final service = container.read(serviceProvider);
    addTearDown(service.dispose);
    await adapter.started.future.timeout(const Duration(seconds: 1));

    service.dispose();
    adapter.release.complete();
    await adapter.completed.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);

    check(service.debugHasScheduledHealthCheck).isFalse();
    check(adapter.requestCount).equals(1);
  });

  test('forced checkNow awaits the active health probe', () async {
    final connectivity = _OnlineConnectivity();
    final adapter = _BlockingHealthAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final serviceProvider = Provider<ConnectivityService>(
      (ref) => ConnectivityService(dio, ref, connectivity),
    );
    final container = ProviderContainer(
      overrides: [
        activeServerProvider.overrideWith(
          (_) async => const ServerConfig(
            id: 'server',
            name: 'Server',
            url: 'https://server.example',
          ),
        ),
        apiServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(connectivity.dispose);
    addTearDown(dio.close);

    await container.read(activeServerProvider.future);
    final service = container.read(serviceProvider);
    addTearDown(service.dispose);
    await adapter.started.future.timeout(const Duration(seconds: 1));

    var forcedSettled = false;
    final forced = service.checkNow().whenComplete(() => forcedSettled = true);
    await Future<void>.delayed(Duration.zero);
    check(forcedSettled).isFalse();
    check(adapter.requestCount).equals(1);

    adapter.release.complete();
    check(await forced.timeout(const Duration(seconds: 1))).isTrue();
    check(adapter.requestCount).equals(1);
  });

  test(
    'credential-bearing client without an origin never probes active server',
    () async {
      final connectivity = _OnlineConnectivity();
      final adapter = _ImmediateHealthAdapter();
      final dio = Dio(
        BaseOptions(headers: const {'Cookie': 'proxy_session=secret'}),
      )..httpClientAdapter = adapter;
      final serviceProvider = Provider<ConnectivityService>(
        (ref) => ConnectivityService(dio, ref, connectivity),
      );
      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (_) async => const ServerConfig(
              id: 'server',
              name: 'Server',
              url: 'https://server.example',
            ),
          ),
          apiServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(connectivity.dispose);
      addTearDown(dio.close);
      await container.read(activeServerProvider.future);

      final service = container.read(serviceProvider);
      addTearDown(service.dispose);
      await service.debugCheckServerHealth();

      check(adapter.requestCount).equals(0);
    },
  );

  test(
    'forced checkNow follows an overlapping recent-traffic fast path',
    () async {
      final connectivity = _OnlineConnectivity();
      final adapter = _ImmediateHealthAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final serviceProvider = Provider<ConnectivityService>(
        (ref) => ConnectivityService(dio, ref, connectivity),
      );
      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (_) async => const ServerConfig(
              id: 'server',
              name: 'Server',
              url: 'https://server.example',
            ),
          ),
          apiServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(connectivity.dispose);
      addTearDown(dio.close);

      await container.read(activeServerProvider.future);
      final service = container.read(serviceProvider);
      addTearDown(service.dispose);
      await _waitForRequestCount(adapter, 1);

      ConnectivityService.noteSuccessfulTraffic(
        Uri.parse('https://server.example/api/v1/chats'),
      );
      final skipped = service.debugCheckServerHealth();
      final forced = service.checkNow();
      await skipped;
      check(await forced).isTrue();

      // The non-forced overlap skips due to recent traffic; checkNow must still
      // perform exactly one subsequent network probe.
      check(adapter.requestCount).equals(2);
    },
  );

  test('health client does not follow credentialed redirects', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final redirected = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      addTearDown(() => redirected.close(force: true));
      var redirectedRequests = 0;
      String? redirectedCookie;
      redirected.listen((request) async {
        redirectedRequests++;
        redirectedCookie = request.headers.value(HttpHeaders.cookieHeader);
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      origin.listen((request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://${InternetAddress.loopbackIPv4.address}:${redirected.port}/health',
          );
        await request.response.close();
      });
      final config = ServerConfig(
        id: 'redirect-server',
        name: 'Redirect server',
        url: 'http://${InternetAddress.loopbackIPv4.address}:${origin.port}',
        customHeaders: const <String, String>{'Cookie': 'proxy_session=secret'},
      );
      final dio = createConnectivityHealthClient(config);
      addTearDown(dio.close);

      final response = await dio.get<void>('/health');

      check(response.statusCode).equals(HttpStatus.found);
      check(dio.options.followRedirects).isFalse();
      check(dio.options.maxRedirects).equals(0);
      check(redirectedRequests).equals(0);
      check(redirectedCookie).isNull();
    }, _RealHttpOverrides());
  });

  test(
    'health client normalizes a scheme-less server with the shared parser',
    () async {
      final adapter = _RecordingHeadersAdapter();
      final dio = createConnectivityHealthClient(
        const ServerConfig(
          id: 'scheme-less-server',
          name: 'Scheme-less server',
          url: 'server.example',
          customHeaders: <String, String>{
            'X-Proxy-Credential': 'same-origin-secret',
          },
        ),
      )..httpClientAdapter = adapter;
      addTearDown(dio.close);

      await dio.getUri<void>(Uri.parse('https://server.example/health'));

      check(dio.options.baseUrl).equals('https://server.example');
      check(
        adapter.headers.single['X-Proxy-Credential'],
      ).equals('same-origin-secret');
    },
  );

  test(
    'health client suppresses a configured Cookie at request time',
    () async {
      var suppressCookie = false;
      final adapter = _RecordingHeadersAdapter();
      final dio = createConnectivityHealthClient(
        const ServerConfig(
          id: 'runtime-cookie-server',
          name: 'Runtime Cookie server',
          url: 'https://server.example',
          customHeaders: <String, String>{
            'cOoKiE': 'proxy_session=secret',
            'X-Proxy-Credential': 'still-required',
          },
        ),
        suppressCustomCookieHeader: () => suppressCookie,
      )..httpClientAdapter = adapter;
      addTearDown(dio.close);

      await dio.get<void>('/health');
      suppressCookie = true;
      await dio.get<void>('/health');

      check(adapter.headers).length.equals(2);
      check(
        adapter.headers.first.entries
            .singleWhere((entry) => entry.key.toLowerCase() == 'cookie')
            .value,
      ).equals('proxy_session=secret');
      check(
        adapter.headers.last.keys.any((name) => name.toLowerCase() == 'cookie'),
      ).isFalse();
      check(
        adapter.headers.last['X-Proxy-Credential'],
      ).equals('still-required');
    },
  );

  test(
    'health client strips configured credentials from a foreign origin',
    () async {
      final adapter = _RecordingHeadersAdapter();
      final dio = createConnectivityHealthClient(
        const ServerConfig(
          id: 'origin-bound-server',
          name: 'Origin-bound server',
          url: 'https://server.example',
          customHeaders: <String, String>{
            'cOoKiE': 'proxy_session=secret',
            'X-Proxy-Credential': 'secret',
          },
        ),
      )..httpClientAdapter = adapter;
      addTearDown(dio.close);

      await dio.getUri<void>(Uri.parse('https://foreign.example/health'));

      final headers = adapter.headers.single;
      check(
        headers.keys.any((name) => name.toLowerCase() == 'cookie'),
      ).isFalse();
      check(
        headers.keys.any((name) => name.toLowerCase() == 'x-proxy-credential'),
      ).isFalse();
    },
  );

  test('repeated transport failures retain the first probe deadline', () async {
    final connectivity = _OnlineConnectivity();
    final adapter = _ImmediateHealthAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final serviceProvider = Provider<ConnectivityService>(
      (ref) => ConnectivityService(dio, ref, connectivity),
    );
    final container = ProviderContainer(
      overrides: [
        activeServerProvider.overrideWith(
          (_) async => const ServerConfig(
            id: 'server',
            name: 'Server',
            url: 'https://server.example',
          ),
        ),
        apiServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(connectivity.dispose);
    addTearDown(dio.close);

    await container.read(activeServerProvider.future);
    final service = container.read(serviceProvider);
    addTearDown(service.dispose);
    await _waitForRequestCount(adapter, 1);

    for (var index = 0; index < 4; index += 1) {
      ConnectivityService.reportTransportFailure(
        Uri.parse('https://server.example'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    // A reset-on-every-event debounce would still have made only the startup
    // request. Fixed-window coalescing fires one forced probe near the first
    // failure's deadline even while the burst continues.
    await _waitForRequestCount(
      adapter,
      2,
      timeout: const Duration(milliseconds: 400),
    );
    service.dispose();
  });

  test(
    'transport failure upgrades a retained resume timer to forced',
    () async {
      final connectivity = _OnlineConnectivity();
      final adapter = _ImmediateHealthAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final serviceProvider = Provider<ConnectivityService>(
        (ref) => ConnectivityService(dio, ref, connectivity),
      );
      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (_) async => const ServerConfig(
              id: 'server',
              name: 'Server',
              url: 'https://server.example',
            ),
          ),
          apiServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(connectivity.dispose);
      addTearDown(dio.close);

      await container.read(activeServerProvider.future);
      final service = container.read(serviceProvider);
      addTearDown(service.dispose);
      await _waitForRequestCount(adapter, 1);

      // Recent successful traffic makes an ordinary health timer skip its HTTP
      // probe. Resume installs that ordinary timer first; the subsequent
      // transport failure must upgrade it without moving its earlier deadline.
      ConnectivityService.noteSuccessfulTraffic(
        Uri.parse('https://server.example'),
      );
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      ConnectivityService.reportTransportFailure(
        Uri.parse('https://server.example'),
      );

      await _waitForRequestCount(adapter, 2);
      service.dispose();
    },
  );

  test(
    'matching successful traffic immediately restores healthy state',
    () async {
      final connectivity = _OnlineConnectivity();
      final adapter = _FailingHealthAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final serviceProvider = Provider<ConnectivityService>(
        (ref) => ConnectivityService(dio, ref, connectivity),
      );
      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (_) async => const ServerConfig(
              id: 'server',
              name: 'Server',
              url: 'https://server.example',
            ),
          ),
          apiServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(connectivity.dispose);
      addTearDown(dio.close);

      await container.read(activeServerProvider.future);
      final service = container.read(serviceProvider);
      addTearDown(service.dispose);
      await _waitForRequestCount(adapter, 1);
      while (service.debugConsecutiveFailures < 3) {
        await service.checkNow();
      }
      check(service.currentStatus).equals(ConnectivityStatus.offline);

      ConnectivityService.noteSuccessfulTraffic(
        Uri.parse('https://other.example'),
      );
      check(service.currentStatus).equals(ConnectivityStatus.offline);
      ConnectivityService.noteSuccessfulTraffic(
        Uri.parse('https://server.example/api/v1/chats'),
      );

      check(service.currentStatus).equals(ConnectivityStatus.online);
      check(service.debugConsecutiveFailures).equals(0);
      check(service.debugHasScheduledHealthCheck).isTrue();
      service.dispose();
    },
  );
}

Future<void> _waitForRequestCount(
  _RequestCountingAdapter adapter,
  int expected, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (adapter.requestCount < expected && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  check(adapter.requestCount).isGreaterOrEqual(expected);
}

final class _OnlineConnectivity implements Connectivity {
  final StreamController<List<ConnectivityResult>> _changes =
      StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => const [
    ConnectivityResult.wifi,
  ];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes.stream;

  Future<void> dispose() => _changes.close();
}

abstract interface class _RequestCountingAdapter implements HttpClientAdapter {
  int get requestCount;
}

final class _BlockingHealthAdapter implements _RequestCountingAdapter {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  final Completer<void> completed = Completer<void>();
  @override
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount += 1;
    if (!started.isCompleted) started.complete();
    await release.future;
    if (!completed.isCompleted) completed.complete();
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}

final class _ImmediateHealthAdapter implements _RequestCountingAdapter {
  @override
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount += 1;
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}

final class _RecordingHeadersAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> headers = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    headers.add(Map<String, dynamic>.from(options.headers));
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}

final class _FailingHealthAdapter implements _RequestCountingAdapter {
  @override
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount += 1;
    return ResponseBody.fromString('', 503);
  }

  @override
  void close({bool force = false}) {}
}

final class _RealHttpOverrides extends HttpOverrides {}
