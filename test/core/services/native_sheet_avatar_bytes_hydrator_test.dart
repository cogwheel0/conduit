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

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      check(hydrated.single.avatarBytes).isNull();
      check(adapter.requestedUris).deepEquals([
        'https://chat.example.test/api/v1/models/model/profile/image?id=server-model',
      ]);
    });

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
