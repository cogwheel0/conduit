import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

const _secretUrl = 'https://hooks.example.com/services/T000/B000/s3cr3t';

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

  group('requests', () {
    test('create sends the URL once, with the web client\'s body', () async {
      await api.createNotificationTarget(
        id: ' ops ',
        url: ' $_secretUrl ',
        enabled: true,
        events: const ['chat.finished', 'channel.message'],
        delivery: 'always',
        authSnapshot: api.captureAuthSnapshot(),
      );

      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/notifications/targets');
      check(request.headers['Authorization']).equals('Bearer session-a');
      check(request.data).isA<Map<String, dynamic>>().deepEquals({
        'id': 'ops',
        'type': 'webhook',
        'enabled': true,
        'events': ['chat.finished', 'channel.message'],
        'delivery': 'always',
        'config': {'url': _secretUrl},
      });
    });

    test('create leaves the id to the server when it is blank', () async {
      await api.createNotificationTarget(
        id: '  ',
        url: _secretUrl,
        enabled: true,
        events: const [],
        delivery: 'away',
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(adapter.requests.single.data)
          .isA<Map<String, dynamic>>()
          .not((body) => body.containsKey('id'));
    });

    // The server merges config and keeps the stored URL, so an edit that does
    // not replace the URL must not send config at all. Sending the masked form
    // back would overwrite the secret with a display string.
    test('an update sends only what changed and never a URL', () async {
      final cases = <String, ({Future<Object?> Function() call, Object body})>{
        'enabled': (
          call: () => api.updateNotificationTarget(
            'ops',
            enabled: false,
            authSnapshot: api.captureAuthSnapshot(),
          ),
          body: {'enabled': false},
        ),
        'events': (
          call: () => api.updateNotificationTarget(
            'ops',
            events: const ['chat.finished', 'future.event'],
            authSnapshot: api.captureAuthSnapshot(),
          ),
          body: {
            'events': ['chat.finished', 'future.event'],
          },
        ),
        'delivery': (
          call: () => api.updateNotificationTarget(
            'ops',
            delivery: 'always',
            authSnapshot: api.captureAuthSnapshot(),
          ),
          body: {'delivery': 'always'},
        ),
        'blank replacement': (
          call: () => api.updateNotificationTarget(
            'ops',
            enabled: true,
            replacementUrl: '   ',
            authSnapshot: api.captureAuthSnapshot(),
          ),
          body: {'enabled': true},
        ),
      };

      for (final MapEntry(:key, :value) in cases.entries) {
        adapter.requests.clear();
        await value.call();

        final request = adapter.requests.single;
        check(request.method, because: key).equals('PUT');
        check(
          request.path,
          because: key,
        ).equals('/api/v1/notifications/targets/ops');
        check(request.data, because: key)
            .isA<Map<String, dynamic>>()
            .deepEquals(value.body as Map<String, dynamic>);
      }
    });

    test('an explicit replacement is the only way config is sent', () async {
      await api.updateNotificationTarget(
        'ops',
        replacementUrl: ' $_secretUrl ',
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(adapter.requests.single.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({
            'config': {'url': _secretUrl},
          });
    });

    test(
      'default, test and delete are bodiless calls on an encoded id',
      () async {
        final snapshot = api.captureAuthSnapshot();
        await api.setDefaultNotificationTarget('a/b c', authSnapshot: snapshot);
        await api.testNotificationTarget('a/b c', authSnapshot: snapshot);
        await api.deleteNotificationTarget('a/b c', authSnapshot: snapshot);

        check(adapter.requests.map((r) => '${r.method} ${r.uri.path}').toList())
            .deepEquals([
              'PUT /api/v1/notifications/targets/a%2Fb%20c/default',
              'POST /api/v1/notifications/targets/a%2Fb%20c/test',
              'DELETE /api/v1/notifications/targets/a%2Fb%20c',
            ]);
        for (final request in adapter.requests) {
          check(request.data).isNull();
        }
      },
    );
  });

  group('responses', () {
    test('a target list keeps unknown events, config keys and nulls', () async {
      adapter.body = {
        'targets': [
          {
            'id': 'ops',
            'type': 'webhook',
            'is_default': true,
            'enabled': false,
            'events': ['chat.finished', 'future.event'],
            'delivery': 'always',
            'config': {
              'url_masked': 'https://hooks.example.com/...cret',
              'future_key': 7,
            },
            'created_at': 10,
            'updated_at': 11,
          },
          // An older server omits is_default; that is unknown, not false.
          {
            'id': 'bare',
            'type': 'webhook',
            'enabled': true,
            'events': [],
            'delivery': 'away',
            'config': {'url_masked': ''},
          },
        ],
      };

      final targets = await api.getNotificationTargets(
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(targets).length.equals(2);
      final ops = targets.first;
      check(ops.isDefault).equals(true);
      check(ops.enabled).isFalse();
      check(ops.events).deepEquals(['chat.finished', 'future.event']);
      check(ops.delivery).equals('always');
      check(ops.maskedUrl).equals('https://hooks.example.com/...cret');
      check(ops.config['future_key']).equals(7);
      check(targets.last.isDefault).isNull();
      check(targets.last.maskedUrl).isNull();
    });

    test('the event catalog is a wrapped list that is not history', () async {
      adapter.body = {
        'events': [
          {'event': 'chat.finished', 'label': 'Chat finished'},
          {
            'event': 'channel.message',
            'label': 'Channel message',
            'description': 'A message arrived',
          },
          {'event': 'unlabeled'},
          {'label': 'no event id'},
        ],
      };

      final events = await api.getNotificationEvents(
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(events.map((e) => e.event).toList())
          .deepEquals(['chat.finished', 'channel.message', 'unlabeled']);
      check(events[1].description).equals('A message arrived');
      check(events[2].label).equals('unlabeled');
    });

    test('a response outside the upstream contract is rejected', () async {
      final snapshot = api.captureAuthSnapshot();
      final cases = <String, ({Object body, Future<Object?> Function() call})>{
        'bare event list': (
          body: [
            {'event': 'chat.finished'},
          ],
          call: () => api.getNotificationEvents(authSnapshot: snapshot),
        ),
        'bare target list': (
          body: [
            {'id': 'ops'},
          ],
          call: () => api.getNotificationTargets(authSnapshot: snapshot),
        ),
        'unconfirmed test': (
          body: {'ok': false},
          call: () => api.testNotificationTarget('ops', authSnapshot: snapshot),
        ),
        'test without ok': (
          body: {'delivered': true},
          call: () => api.testNotificationTarget('ops', authSnapshot: snapshot),
        ),
        'default that is not a target': (
          body: [1],
          call: () =>
              api.setDefaultNotificationTarget('ops', authSnapshot: snapshot),
        ),
      };

      for (final MapEntry(:key, :value) in cases.entries) {
        adapter.body = value.body;
        await expectLater(
          value.call(),
          throwsA(isA<FormatException>()),
          reason: key,
        );
      }
    });
  });

  group('account fence', () {
    // The same ApiService serves the next account. Each request is bound to the
    // snapshot of the account that asked, so none can reach the server with the
    // credentials of the one that signed in afterwards.
    test(
      'every call stays bound to the account that captured the snapshot',
      () async {
        final accountA = api.captureAuthSnapshot();
        api.updateAuthToken('session-b');

        final operations = <String, Future<Object?> Function()>{
          'events': () => api.getNotificationEvents(authSnapshot: accountA),
          'list': () => api.getNotificationTargets(authSnapshot: accountA),
          'create': () => api.createNotificationTarget(
            url: _secretUrl,
            enabled: true,
            events: const [],
            delivery: 'away',
            authSnapshot: accountA,
          ),
          'update': () => api.updateNotificationTarget(
            'ops',
            enabled: false,
            authSnapshot: accountA,
          ),
          'delete': () =>
              api.deleteNotificationTarget('ops', authSnapshot: accountA),
          'default': () =>
              api.setDefaultNotificationTarget('ops', authSnapshot: accountA),
          'test': () =>
              api.testNotificationTarget('ops', authSnapshot: accountA),
        };
        for (final MapEntry(:key, :value) in operations.entries) {
          await expectLater(
            value(),
            throwsA(
              isA<DioException>().having(
                (error) => error.type,
                '$key type',
                DioExceptionType.cancel,
              ),
            ),
            reason: key,
          );
        }
        check(adapter.requests).isEmpty();
      },
    );

    test(
      'a snapshot from the current account is sent with its token',
      () async {
        api.updateAuthToken('session-b');

        await api.testNotificationTarget(
          'ops',
          authSnapshot: api.captureAuthSnapshot(),
        );

        check(adapter.requests.single.headers['Authorization'])
            .equals('Bearer session-b');
      },
    );
  });
}

/// Records every request that reaches the wire and answers each with [body].
final class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Object body = const <String, dynamic>{
    'id': 'ops',
    'type': 'webhook',
    'enabled': true,
    'events': <String>[],
    'delivery': 'away',
    'config': <String, dynamic>{},
    'ok': true,
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
