import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  late _Adapter adapter;
  late ApiService api;

  setUp(() {
    adapter = _Adapter();
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server',
        name: 'Server',
        url: 'https://server.example',
      ),
      workerManager: WorkerManager(),
      authToken: 'session-a',
    );
    api.dio.httpClientAdapter = adapter;
  });

  tearDown(() => api.dispose());

  group('openChatLibraryExport', () {
    test('asks for NDJSON and hands the bytes over unparsed', () async {
      adapter.chunks = [
        utf8.encode('{"id":"a","chat":{}}\n{"id":"b",'),
        utf8.encode('"chat":{}}'),
      ];

      final stream = await api.openChatLibraryExport();
      final received = <int>[];
      var pieces = 0;
      await for (final chunk in stream) {
        pieces++;
        received.addAll(chunk);
      }

      final request = adapter.requests.single;
      check(request.method).equals('GET');
      check(request.path).equals('/api/v1/chats/all');
      check(request.headers['Accept']).equals('application/x-ndjson');
      check(request.responseType).equals(ResponseType.stream);
      check(pieces).equals(2);
      check(utf8.decode(received))
          .equals('{"id":"a","chat":{}}\n{"id":"b","chat":{}}');
    });

    test('a refusal is thrown with its status, and is not retried', () async {
      adapter.status = 401;

      await expectLater(
        api.openChatLibraryExport(),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            401,
          ),
        ),
      );
      check(adapter.requests).length.equals(1);
    });

    test('is cancelled before the wire once the account changed', () async {
      final accountA = api.captureAuthSnapshot();
      api.updateAuthToken('session-b');

      await expectLater(
        api.openChatLibraryExport(authSnapshot: accountA),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      check(adapter.requests).isEmpty();
    });

    test('a snapshot of the current account is sent with its token', () async {
      api.updateAuthToken('session-b');

      await api.openChatLibraryExport(authSnapshot: api.captureAuthSnapshot());

      check(adapter.requests.single.headers['Authorization'])
          .equals('Bearer session-b');
    });
  });

  group('importChatsRaw', () {
    final body = Uint8List.fromList(
      utf8.encode('{"chats":[{"chat":{"title":"é","futureKey":1.50}}]}'),
    );

    test('posts the prepared body byte for byte, exactly once', () async {
      adapter.responseBody = jsonEncode([
        {'id': 'new-1', 'chat': <String, dynamic>{}, 'futureKey': 'kept'},
      ]);

      final created = await api.importChatsRaw(body);

      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/chats/import');
      check(request.headers['Content-Type']).equals('application/json');
      check(adapter.bodies.single).deepEquals(body);
      check(created.single['id']).equals('new-1');
      check(created.single['futureKey']).equals('kept');
    });

    test('an answer that is not a list of chats is an error', () async {
      adapter.responseBody = jsonEncode({'detail': 'nope'});

      await expectLater(api.importChatsRaw(body), throwsFormatException);
    });

    test('a refusal is thrown with its status and never repeated', () async {
      for (final status in [400, 403, 500]) {
        adapter.status = status;
        adapter.responseBody = jsonEncode({'detail': 'refused'});
        await expectLater(
          api.importChatsRaw(body),
          throwsA(
            isA<DioException>().having(
              (e) => e.response?.statusCode,
              'status',
              status,
            ),
          ),
          reason: '$status',
        );
      }
      check(adapter.requests).length.equals(3);
    });

    test('an unanswered request is thrown once, not sent again', () async {
      adapter.failure = DioException(
        requestOptions: RequestOptions(path: '/api/v1/chats/import'),
        type: DioExceptionType.receiveTimeout,
      );

      await expectLater(
        api.importChatsRaw(body),
        throwsA(
          isA<DioException>().having((e) => e.response, 'response', isNull),
        ),
      );
      check(adapter.requests).length.equals(1);
    });

    test('is cancelled before the wire once the account changed', () async {
      final accountA = api.captureAuthSnapshot();
      api.updateAuthToken('session-b');

      await expectLater(
        api.importChatsRaw(body, authSnapshot: accountA),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      check(adapter.requests).isEmpty();
    });
  });

  group('account-wide changes', () {
    final routes =
        <
          (
            String,
            String,
            String,
            Future<bool> Function(ApiService, {ApiAuthSnapshot? authSnapshot}),
          )
        >[
          (
            'archive all',
            'POST',
            '/api/v1/chats/archive/all',
            (api, {authSnapshot}) =>
                api.archiveAllChatsRaw(authSnapshot: authSnapshot),
          ),
          (
            'unarchive all',
            'POST',
            '/api/v1/chats/unarchive/all',
            (api, {authSnapshot}) =>
                api.unarchiveAllChatsRaw(authSnapshot: authSnapshot),
          ),
          (
            'unshare all',
            'DELETE',
            '/api/v1/chats/share/all',
            (api, {authSnapshot}) =>
                api.unshareAllChatsRaw(authSnapshot: authSnapshot),
          ),
          (
            'delete all',
            'DELETE',
            '/api/v1/chats/',
            (api, {authSnapshot}) =>
                api.deleteAllChatsRaw(authSnapshot: authSnapshot),
          ),
        ];

    for (final (name, method, path, call) in routes) {
      test('$name sends $method $path once and reads the boolean', () async {
        adapter.responseBody = 'true';
        check(await call(api)).isTrue();

        final request = adapter.requests.single;
        check(request.method).equals(method);
        check(request.path).equals(path);
      });

      test('$name is only done when the server says true', () async {
        // The routes answer a 200 with `false` when the change failed inside
        // the server; that must not read as success.
        adapter.responseBody = 'false';
        check(await call(api)).isFalse();
      });

      test(
        '$name is cancelled before the wire once the account changed',
        () async {
          final accountA = api.captureAuthSnapshot();
          api.updateAuthToken('session-b');

          await expectLater(
            call(api, authSnapshot: accountA),
            throwsA(
              isA<DioException>().having(
                (e) => e.type,
                'type',
                DioExceptionType.cancel,
              ),
            ),
          );
          check(adapter.requests).isEmpty();
        },
      );

      test('$name rethrows a refusal for the caller to classify', () async {
        adapter.status = 403;
        adapter.responseBody = jsonEncode({'detail': 'no'});

        await expectLater(
          call(api),
          throwsA(
            isA<DioException>().having(
              (e) => e.response?.statusCode,
              'status',
              403,
            ),
          ),
        );
        check(adapter.requests).length.equals(1);
      });
    }
  });
}

/// Records every request that reaches the wire, with its body bytes.
final class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <Uint8List>[];
  int status = 200;
  String responseBody = '[]';
  List<List<int>>? chunks;
  DioException? failure;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
      bodies.add(builder.takeBytes());
    }
    final error = failure;
    if (error != null) throw error;
    final headers = {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    };
    final pieces = chunks;
    if (pieces != null) {
      return ResponseBody(
        Stream.fromIterable([for (final c in pieces) Uint8List.fromList(c)]),
        status,
        headers: headers,
      );
    }
    return ResponseBody.fromBytes(
      utf8.encode(responseBody),
      status,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}
