import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/native_sheet_avatar_bytes_hydrator.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NativeSheetAvatarBytesHydrator', () {
    test('withholds same-server custom-TLS URLs from native presentation', () {
      final api = _buildApi(
        const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://chat.example.test',
          mtlsCertificateChainPem: _certificatePem,
          mtlsPrivateKeyPem: _privateKeyPem,
        ),
        _BytesAdapter([1, 2, 3]),
      );
      final options = const [
        NativeSheetModelOption(
          id: 'server-model',
          name: 'Server model',
          avatarUrl:
              'https://chat.example.test/api/v1/models/model/profile/image?id=secret',
          avatarHeaders: {'Authorization': 'Bearer secret'},
        ),
        NativeSheetModelOption(
          id: 'external-model',
          name: 'External model',
          avatarUrl: 'https://cdn.example.test/logo.png',
        ),
      ];

      final prepared = NativeSheetAvatarBytesHydrator()
          .prepareForNativePresentation(api: api, options: options);

      check(prepared[0].avatarUrl).isNull();
      check(prepared[0].avatarHeaders).isEmpty();
      check(prepared[1].avatarUrl).equals('https://cdn.example.test/logo.png');
    });

    test('hydrates same-server avatar URLs when custom TLS is configured', () async {
      final adapter = _BytesAdapter([1, 2, 3]);
      final api = _buildApi(
        const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://chat.example.test',
          mtlsCertificateChainPem: _certificatePem,
          mtlsPrivateKeyPem: _privateKeyPem,
        ),
        adapter,
      );

      final hydrated = await NativeSheetAvatarBytesHydrator().hydrateModelOptions(
        api: api,
        options: const [
          NativeSheetModelOption(
            id: 'server-model',
            name: 'Server model',
            avatarUrl:
                'https://chat.example.test/api/v1/models/model/profile/image?id=server-model',
          ),
          NativeSheetModelOption(
            id: 'external-model',
            name: 'External model',
            avatarUrl: 'https://cdn.example.test/logo.png',
          ),
        ],
      );

      check(hydrated[0].avatarBytes!.toList()).deepEquals([1, 2, 3]);
      check(hydrated[1].avatarBytes).isNull();
      check(adapter.requestedUris).deepEquals([
        'https://chat.example.test/api/v1/models/model/profile/image?id=server-model',
      ]);
    });

    test('leaves avatar URLs untouched for standard TLS servers', () async {
      final adapter = _BytesAdapter([1, 2, 3]);
      final api = _buildApi(
        const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://chat.example.test',
        ),
        adapter,
      );

      final hydrated = await NativeSheetAvatarBytesHydrator().hydrateModelOptions(
        api: api,
        options: const [
          NativeSheetModelOption(
            id: 'server-model',
            name: 'Server model',
            avatarUrl:
                'https://chat.example.test/api/v1/models/model/profile/image?id=server-model',
          ),
        ],
      );

      check(hydrated.single.avatarBytes).isNull();
      check(adapter.requestedUris).isEmpty();
    });

    test('rejects oversized custom-TLS avatar responses', () async {
      final adapter = _BytesAdapter(List<int>.filled(1024 * 1024 + 1, 7));
      final api = _buildApi(
        const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://chat.example.test',
          mtlsCertificateChainPem: _certificatePem,
          mtlsPrivateKeyPem: _privateKeyPem,
        ),
        adapter,
      );

      final hydrated = await NativeSheetAvatarBytesHydrator().hydrateModelOptions(
        api: api,
        options: const [
          NativeSheetModelOption(
            id: 'large-avatar',
            name: 'Large avatar',
            avatarUrl:
                'https://chat.example.test/api/v1/models/model/profile/image?id=large-avatar',
          ),
        ],
      );

      check(hydrated.single.avatarBytes).isNull();
    });

    test('returns promptly when prefetch exceeds the presentation budget', () async {
      final adapter = _PendingAdapter();
      final api = _buildApi(
        const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://chat.example.test',
          mtlsCertificateChainPem: _certificatePem,
          mtlsPrivateKeyPem: _privateKeyPem,
        ),
        adapter,
      );

      final stopwatch = Stopwatch()..start();
      final hydrated = await NativeSheetAvatarBytesHydrator().hydrateModelOptions(
        api: api,
        maxWait: const Duration(milliseconds: 10),
        options: const [
          NativeSheetModelOption(
            id: 'server-model',
            name: 'Server model',
            avatarUrl:
                'https://chat.example.test/api/v1/models/model/profile/image?id=server-model',
          ),
        ],
      );
      stopwatch.stop();

      check(stopwatch.elapsed).isLessThan(const Duration(seconds: 1));
      check(hydrated.single.avatarBytes).isNull();
      check(adapter.requestedUris).deepEquals([
        'https://chat.example.test/api/v1/models/model/profile/image?id=server-model',
      ]);
    });

    test('one subscriber timeout does not cancel a shared request', () async {
      final adapter = _ControlledAdapter();
      final api = _buildApi(
        const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://chat.example.test',
          mtlsCertificateChainPem: _certificatePem,
          mtlsPrivateKeyPem: _privateKeyPem,
        ),
        adapter,
      );
      final hydrator = NativeSheetAvatarBytesHydrator();
      const option = NativeSheetModelOption(
        id: 'server-model',
        name: 'Server model',
        avatarUrl:
            'https://chat.example.test/api/v1/models/model/profile/image?id=server-model',
      );

      final first = hydrator.hydrateModelOptions(
        api: api,
        options: const [option],
        maxWait: const Duration(milliseconds: 30),
      );
      await _waitForRequestCount(adapter, 1);
      final longerSubscriber = hydrator.hydrateModelOptions(
        api: api,
        options: const [option],
        maxWait: const Duration(seconds: 1),
      );
      check((await first).single.avatarBytes).isNull();
      check(adapter.requests.single.cancelled.isCompleted).isFalse();

      adapter.requests.single.complete([7, 8, 9]);
      check(
        (await longerSubscriber).single.avatarBytes!.toList(),
      ).deepEquals([7, 8, 9]);

      final cached = await hydrator.hydrateModelOptions(
        api: api,
        options: const [option],
      );
      check(cached.single.avatarBytes!.toList()).deepEquals([7, 8, 9]);
      check(adapter.requests).length.equals(1);
    });

    test(
      'authentication epoch rotation invalidates cached avatar bytes',
      () async {
        final adapter = _SequentialBytesAdapter(<List<int>>[
          const [1, 2, 3],
          const [7, 8, 9],
        ]);
        final api = _buildApi(
          const ServerConfig(
            id: 'server',
            name: 'Server',
            url: 'https://chat.example.test',
            mtlsCertificateChainPem: _certificatePem,
            mtlsPrivateKeyPem: _privateKeyPem,
          ),
          adapter,
        );
        api.updateAuthToken('account-a');
        final hydrator = NativeSheetAvatarBytesHydrator();
        const option = NativeSheetModelOption(
          id: 'server-model',
          name: 'Server model',
          avatarUrl:
              'https://chat.example.test/api/v1/models/model/profile/image?id=server-model',
        );

        final first = await hydrator.hydrateModelOptions(
          api: api,
          options: const [option],
        );
        api.updateAuthToken('account-b');
        final second = await hydrator.hydrateModelOptions(
          api: api,
          options: const [option],
        );

        check(first.single.avatarBytes!.toList()).deepEquals([1, 2, 3]);
        check(second.single.avatarBytes!.toList()).deepEquals([7, 8, 9]);
        check(adapter.requestCount).equals(2);
      },
    );

    test(
      'keeps fast avatar bytes when another request in the batch times out',
      () async {
        final adapter = _MixedLatencyAdapter([4, 5, 6]);
        final api = _buildApi(
          const ServerConfig(
            id: 'server',
            name: 'Server',
            url: 'https://chat.example.test',
            mtlsCertificateChainPem: _certificatePem,
            mtlsPrivateKeyPem: _privateKeyPem,
          ),
          adapter,
        );

        final hydrated = await NativeSheetAvatarBytesHydrator().hydrateModelOptions(
          api: api,
          maxWait: const Duration(milliseconds: 10),
          options: const [
            NativeSheetModelOption(
              id: 'fast',
              name: 'Fast model',
              avatarUrl:
                  'https://chat.example.test/api/v1/models/model/profile/image?id=fast',
            ),
            NativeSheetModelOption(
              id: 'slow',
              name: 'Slow model',
              avatarUrl:
                  'https://chat.example.test/api/v1/models/model/profile/image?id=slow',
            ),
          ],
        );

        check(hydrated[0].avatarBytes!.toList()).deepEquals([4, 5, 6]);
        check(hydrated[1].avatarBytes).isNull();
        check(adapter.requestedUris).deepEquals([
          'https://chat.example.test/api/v1/models/model/profile/image?id=fast',
          'https://chat.example.test/api/v1/models/model/profile/image?id=slow',
        ]);
      },
    );

    test('progress emits only options that gained avatar bytes', () async {
      final adapter = _BytesAdapter([4, 5, 6]);
      final api = _buildApi(
        const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://chat.example.test',
          mtlsCertificateChainPem: _certificatePem,
          mtlsPrivateKeyPem: _privateKeyPem,
        ),
        adapter,
      );
      final progress = <List<NativeSheetModelOption>>[];

      await NativeSheetAvatarBytesHydrator().hydrateModelOptions(
        api: api,
        options: [
          NativeSheetModelOption(
            id: 'already-hydrated',
            name: 'Already hydrated',
            avatarUrl:
                'https://chat.example.test/api/v1/models/model/profile/image?id=already',
            avatarBytes: Uint8List.fromList([9]),
          ),
          const NativeSheetModelOption(
            id: 'newly-hydrated',
            name: 'Newly hydrated',
            avatarUrl:
                'https://chat.example.test/api/v1/models/model/profile/image?id=new',
          ),
        ],
        onProgress: progress.add,
      );

      check(progress).length.equals(1);
      check(
        progress.single.map((option) => option.id).toList(),
      ).deepEquals(['newly-hydrated']);
    });

    test('inactive hydration does not launch later batches', () async {
      final adapter = _ControlledAdapter();
      final api = _buildApi(
        const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://chat.example.test',
          mtlsCertificateChainPem: _certificatePem,
          mtlsPrivateKeyPem: _privateKeyPem,
        ),
        adapter,
      );
      var active = true;
      final progress = <List<NativeSheetModelOption>>[];
      final hydration = NativeSheetAvatarBytesHydrator().hydrateModelOptions(
        api: api,
        options: List<NativeSheetModelOption>.generate(
          8,
          (index) => NativeSheetModelOption(
            id: 'model-$index',
            name: 'Model $index',
            avatarUrl:
                'https://chat.example.test/api/v1/models/model/profile/image?id=$index',
          ),
        ),
        maxWait: const Duration(seconds: 1),
        onProgress: progress.add,
        isActive: () => active,
      );

      await _waitForRequestCount(adapter, 4);
      check(adapter.requests).length.equals(4);
      active = false;
      for (final request in adapter.requests) {
        request.complete([1, 2, 3]);
      }
      await hydration;

      check(adapter.requests).length.equals(4);
      check(progress).isEmpty();
    });

    test(
      'one stalled avatar cannot hold later requests behind its batch',
      () async {
        final adapter = _ControlledAdapter();
        final api = _buildApi(
          const ServerConfig(
            id: 'server',
            name: 'Server',
            url: 'https://chat.example.test',
            mtlsCertificateChainPem: _certificatePem,
            mtlsPrivateKeyPem: _privateKeyPem,
          ),
          adapter,
        );
        final hydration = NativeSheetAvatarBytesHydrator().hydrateModelOptions(
          api: api,
          maxWait: const Duration(seconds: 5),
          options: List<NativeSheetModelOption>.generate(
            8,
            (index) => NativeSheetModelOption(
              id: 'model-$index',
              name: 'Model $index',
              avatarUrl:
                  'https://chat.example.test/api/v1/models/model/profile/image?id=$index',
            ),
          ),
        );

        await _waitForRequestCount(adapter, 4);
        // Keep request zero stalled while the other three workers advance.
        for (final request in adapter.requests.skip(1).take(3)) {
          request.complete([1, 2, 3]);
        }
        await _waitForRequestCount(adapter, 7);
        for (final request in adapter.requests.skip(4).take(3)) {
          request.complete([4, 5, 6]);
        }
        await _waitForRequestCount(adapter, 8);

        check(adapter.requests).length.equals(8);
        adapter.requests.last.complete([7, 8, 9]);
        adapter.requests.first.complete([9, 8, 7]);
        final hydrated = await hydration;

        check(hydrated.every((option) => option.avatarBytes != null)).isTrue();
      },
    );

    test('an evicted stale request cannot remove its replacement', () async {
      final adapter = _ControlledAdapter();
      final api = _buildApi(
        const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://chat.example.test',
          mtlsCertificateChainPem: _certificatePem,
          mtlsPrivateKeyPem: _privateKeyPem,
        ),
        adapter,
      );
      final hydrator = NativeSheetAvatarBytesHydrator();
      NativeSheetModelOption option(int index) => NativeSheetModelOption(
        id: 'model-$index',
        name: 'Model $index',
        avatarUrl:
            'https://chat.example.test/api/v1/models/model/profile/image?id=model-$index',
      );

      // Fill beyond the 32-entry cache while every original request remains
      // unresolved. The first request is evicted, then the same key is fetched
      // again with a new ownership token.
      final initialHydrations =
          List<Future<List<NativeSheetModelOption>>>.generate(
            33,
            (index) => hydrator.hydrateModelOptions(
              api: api,
              options: [option(index)],
              maxWait: const Duration(milliseconds: 100),
            ),
          );
      await _waitForRequestCount(adapter, 33);
      await Future.wait(initialHydrations);
      final replacementHydration = hydrator.hydrateModelOptions(
        api: api,
        options: [option(0)],
        maxWait: const Duration(seconds: 2),
      );
      await _waitForRequestCount(adapter, 34);
      adapter.requests.last.complete([9, 8, 7]);
      await replacementHydration;
      check(adapter.requests).length.equals(34);

      adapter.requests.first.fail(StateError('stale request failed'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final hydrated = await hydrator.hydrateModelOptions(
        api: api,
        options: [option(0)],
      );

      check(hydrated.single.avatarBytes!.toList()).deepEquals([9, 8, 7]);
      check(adapter.requests).length.equals(34);
    });

    test('failure logs retain only an origin and opaque URL hash', () {
      const url =
          'https://user:password@chat.example.test:8443/avatar/model.png?token=secret#private';
      final redacted = redactedNativeAvatarUrlForLogForTest(url);
      final hash = nativeAvatarUrlHashForLogForTest(url);

      check(redacted).equals('https://chat.example.test:8443');
      check(redacted).not((it) => it.contains('avatar'));
      check(redacted).not((it) => it.contains('secret'));
      check(redacted).not((it) => it.contains('password'));
      check(hash).length.equals(64);
      check(hash).not((it) => it.contains('secret'));
    });
  });
}

ApiService _buildApi(ServerConfig serverConfig, HttpClientAdapter adapter) {
  final workerManager = WorkerManager();
  final api = ApiService(
    serverConfig: serverConfig,
    workerManager: workerManager,
  );
  api.dio.httpClientAdapter = adapter;
  api.dio.interceptors.clear();
  addTearDown(workerManager.dispose);
  return api;
}

class _BytesAdapter implements HttpClientAdapter {
  _BytesAdapter(this.bytes);

  final List<int> bytes;
  final requestedUris = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedUris.add(options.uri.toString());
    return ResponseBody(
      Stream.value(Uint8List.fromList(bytes)),
      200,
      headers: {
        'content-type': ['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _SequentialBytesAdapter implements HttpClientAdapter {
  _SequentialBytesAdapter(this.responses);

  final List<List<int>> responses;
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = responses[requestCount++];
    return ResponseBody(
      Stream.value(Uint8List.fromList(bytes)),
      200,
      headers: {
        'content-type': ['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _PendingAdapter implements HttpClientAdapter {
  final requestedUris = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requestedUris.add(options.uri.toString());
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}

class _MixedLatencyAdapter implements HttpClientAdapter {
  _MixedLatencyAdapter(this.bytes);

  final List<int> bytes;
  final requestedUris = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedUris.add(options.uri.toString());
    if (options.uri.queryParameters['id'] == 'fast') {
      return ResponseBody(
        Stream.value(Uint8List.fromList(bytes)),
        200,
        headers: {
          'content-type': ['image/png'],
        },
      );
    }
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}

class _ControlledAdapter implements HttpClientAdapter {
  final requests = <_ControlledRequest>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final request = _ControlledRequest(options, cancelFuture);
    requests.add(request);
    return request.response.future;
  }

  @override
  void close({bool force = false}) {}
}

class _ControlledRequest {
  _ControlledRequest(RequestOptions options, Future<void>? cancelFuture)
    : uri = options.uri,
      _options = options {
    cancelFuture?.then<void>(
      (_) => _cancel(),
      onError: (Object _, StackTrace _) => _cancel(),
    );
  }

  final Uri uri;
  final RequestOptions _options;
  final response = Completer<ResponseBody>();
  final cancelled = Completer<void>();

  void _cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
    if (!response.isCompleted) {
      response.completeError(
        DioException(requestOptions: _options, type: DioExceptionType.cancel),
      );
    }
  }

  void complete(List<int> bytes) {
    if (response.isCompleted) return;
    response.complete(
      ResponseBody(
        Stream.value(Uint8List.fromList(bytes)),
        200,
        headers: {
          'content-type': ['image/png'],
        },
      ),
    );
  }

  void fail(Object error) {
    if (!response.isCompleted) response.completeError(error);
  }
}

Future<void> _waitForRequestCount(_ControlledAdapter adapter, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (adapter.requests.length < count && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  if (adapter.requests.length < count) {
    fail(
      'Timed out waiting for $count avatar requests; '
      'observed ${adapter.requests.length}.',
    );
  }
}

const _certificatePem = '''
-----BEGIN CERTIFICATE-----
invalid
-----END CERTIFICATE-----
''';

const _privateKeyPem = '''
-----BEGIN PRIVATE KEY-----
invalid
-----END PRIVATE KEY-----
''';
