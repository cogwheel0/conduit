import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/services/openwebui_push_backend.dart';
import 'package:conduit_core/features/push/services/push_backend.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

const _bundledSource = '''"""
title: Conduit Push
author: cogwheel0
version: 1.2.0
required_open_webui_version: 0.11.0
description: End-to-end encrypted push notifications for the Conduit app.
conduit_protocol: 1
"""

class Event:
    pass
''';

const _notFound = "We could not find what you're looking for :/";

void main() {
  late _OpenWebUi server;
  late OpenWebUiPushBackend backend;
  OpenWebUiFunctionSource? bundled;

  OpenWebUiPushBackend build() => OpenWebUiPushBackend(
    dio: Dio(BaseOptions(baseUrl: 'https://owui.test'))
      ..httpClientAdapter = server,
    bundledFunction: () async => bundled,
    clock: () => DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000),
  );

  setUp(() {
    server = _OpenWebUi();
    bundled = OpenWebUiFunctionSource.parse(_bundledSource);
    backend = build();
  });

  PushServerSubscription subscription({
    String sid = 'AAAAAAAAAAAAAAAAAAAAAA',
    String did = 'device-1',
    String endpoint = 'https://relay.test/v1/push/one',
    PushOrigin origin = PushOrigin.conduit,
  }) => PushServerSubscription(
    sid: sid,
    did: did,
    endpoint: endpoint,
    p256dh: 'BPUBLIC',
    auth: 'AUTH',
    events: const ['reply', 'reply_failed', 'channel'],
    label: 'iOS',
    platform: 'ios',
    origin: origin,
  );

  group('function source', () {
    test('reads version and description from the frontmatter', () {
      check(bundled).isNotNull()
        ..has((s) => s.version, 'version').equals('1.2.0')
        ..has((s) => s.description, 'description').equals(
          'End-to-end encrypted push notifications for the Conduit app.',
        );
      check(OpenWebUiFunctionSource.parse('print(1)')).isNull();
    });

    test('compares versions numerically', () {
      check(comparePushVersions('0.9.5', '0.10.0')).isLessThan(0);
      check(comparePushVersions('0.10.0', '0.10.0')).equals(0);
      check(comparePushVersions('v0.11.4', '0.10.0')).isGreaterThan(0);
      check(comparePushVersions('0.10.0-dev.2', '0.10.0')).equals(0);
      check(comparePushVersions('1.0', '1.0.1')).isLessThan(0);
    });
  });

  group('probe', () {
    test('a server older than 0.11.0 is too old', () async {
      // It has Event functions, but no reply events to send pushes for.
      server.version = '0.10.6';
      final probe = await backend.probe();
      check(probe.outcome).equals(PushProbeOutcome.serverTooOld);
      check(probe.serverVersion).equals('0.10.6');
    });

    test('0.11.0 is new enough', () async {
      server.version = '0.11.0';
      check((await backend.probe()).outcome).not(
        (it) => it.equals(PushProbeOutcome.serverTooOld),
      );
    });

    test('plugins switched off', () async {
      server.enablePlugins = false;
      check((await backend.probe()).outcome)
          .equals(PushProbeOutcome.pluginsDisabled);
    });

    test('a missing function: admins can install it', () async {
      server.role = 'admin';
      final probe = await backend.probe();
      check(probe.outcome).equals(PushProbeOutcome.canInstall);
      check(probe.bundledVersion).equals('1.2.0');
    });

    test('a missing function: other users need their admin', () async {
      check((await backend.probe()).outcome)
          .equals(PushProbeOutcome.needsAdminSetup);
    });

    test('a missing function without a bundled copy needs the admin', () async {
      server.role = 'admin';
      bundled = null;
      backend = build();
      check((await backend.probe()).outcome)
          .equals(PushProbeOutcome.needsAdminSetup);
    });

    test('an inactive function needs the admin too', () async {
      server.function = _function(active: false);
      check((await backend.probe()).outcome)
          .equals(PushProbeOutcome.needsAdminSetup);
    });

    test('an older active function works, and admins may update it', () async {
      server.function = _function(version: '1.0.0');
      server.role = 'admin';
      final probe = await backend.probe();
      check(probe.isReady).isTrue();
      check(probe.updateAvailable).isTrue();
      check(probe.pluginVersion).equals('1.0.0');
    });

    test('an older active function works for other users as is', () async {
      server.function = _function(version: '1.0.0');
      final probe = await backend.probe();
      check(probe.isReady).isTrue();
      check(probe.updateAvailable).isFalse();
    });

    test('a current active function is ready', () async {
      server.function = _function(version: '1.2.0');
      server.role = 'admin';
      final probe = await backend.probe();
      check(probe.isReady).isTrue();
      check(probe.updateAvailable).isFalse();
    });

    test('an expired session needs sign-in', () async {
      server.authFailure = true;
      check((await backend.probe()).outcome)
          .equals(PushProbeOutcome.signInNeeded);
    });
  });

  group('install', () {
    test('creates the function, then switches it on', () async {
      server.role = 'admin';
      await backend.install();

      check(server.paths(write: true)).deepEquals([
        '/api/v1/functions/create',
        '/api/v1/functions/id/conduit_push/toggle',
      ]);
      final created = server.bodies.first as Map;
      check(created['id']).equals('conduit_push');
      check(created['name']).equals('Conduit Push');
      check(created['content']).equals(_bundledSource);
      check(created['meta'] as Map).deepEquals({
        'description':
            'End-to-end encrypted push notifications for the Conduit app.',
        'manifest': <String, Object?>{},
      });
      check(server.function!['is_active']).equals(true);
    });

    test('only switches on a current, inactive function', () async {
      server.function = _function(version: '1.2.0', active: false);
      await backend.install();
      check(server.paths(write: true))
          .deepEquals(['/api/v1/functions/id/conduit_push/toggle']);
    });

    test('updates an older active function without toggling it', () async {
      server.function = _function(version: '1.0.0');
      await backend.install();
      check(server.paths(write: true))
          .deepEquals(['/api/v1/functions/id/conduit_push/update']);
      check(server.function!['is_active']).equals(true);
    });

    test('a non-admin is told so, not signed out', () async {
      server.adminOnlyWrites = true;
      final error = await _backendError(backend.install());
      check(error.signInNeeded).isFalse();
      check(error.failure)
        ..has((f) => f.reason, 'reason').equals(PushFailureReason.installFailed)
        ..has((f) => f.detail, 'detail').equals('not_admin');
    });
  });

  group('subscribe', () {
    setUp(() => server.function = _function(version: '1.2.0'));

    test('writes only subscriptions, and reads it back', () async {
      final dispatch = await backend.subscribe(subscription());

      check(dispatch).isNull();
      check(server.writes).length.equals(1);
      final write = server.writes.single;
      check(write.keys.toList()).deepEquals(['subscriptions']);
      final entries = jsonDecode(write['subscriptions'] as String) as List;
      check(entries.single as Map).deepEquals({
        'sid': 'AAAAAAAAAAAAAAAAAAAAAA',
        'did': 'device-1',
        'endpoint': 'https://relay.test/v1/push/one',
        'p256dh': 'BPUBLIC',
        'auth': 'AUTH',
        'events': ['reply', 'reply_failed', 'channel'],
        'label': 'iOS',
        'platform': 'ios',
        'proto': 1,
        'origin': 'conduit',
        'seen': 1760000000,
      });
      // Read, write, read back.
      check(server.paths()).deepEquals([
        '/api/v1/functions/id/conduit_push/valves/user',
        '/api/v1/functions/id/conduit_push/valves/user/update',
        '/api/v1/functions/id/conduit_push/valves/user',
      ]);
    });

    test("keeps other devices' entries and replaces this device's", () async {
      final other = {
        'sid': 'BBBBBBBBBBBBBBBBBBBBBB',
        'did': 'device-2',
        'endpoint': 'https://relay.test/v1/push/two',
        'p256dh': 'X',
        'auth': 'Y',
        'seen': 1,
        'future_field': {'kept': true},
      };
      final older = {
        'sid': 'CCCCCCCCCCCCCCCCCCCCCC',
        'did': 'device-1',
        'endpoint': 'https://relay.test/v1/push/old',
      };
      server.valves = {
        'subscriptions': jsonEncode([other, older]),
        'status': '{"CCCCCCCCCCCCCCCCCCCCCC":{"err":"gone"}}',
      };

      await backend.subscribe(subscription(origin: PushOrigin.any));

      final entries =
          jsonDecode(server.valves!['subscriptions'] as String) as List;
      check(entries).length.equals(2);
      check(entries.first as Map).deepEquals(other);
      check(entries.last as Map)
        ..has((e) => e['sid'], 'sid').equals('AAAAAAAAAAAAAAAAAAAAAA')
        ..has((e) => e['origin'], 'origin').equals('any');
      // The function's status goes back as it was read: the update replaces
      // every valve, and the function tells sent tests apart by it.
      check(server.valves!['status'])
          .equals('{"CCCCCCCCCCCCCCCCCCCCCC":{"err":"gone"}}');
    });

    test('replaces an entry with the same sid from another did', () {
      final merged = mergeOpenWebUiSubscriptions(
        [
          {'sid': 'S', 'did': 'old-did'},
          {'sid': 'T', 'did': 'other'},
          'not a map',
        ],
        {'sid': 'S', 'did': 'new-did'},
      );
      check(merged).deepEquals([
        {'sid': 'T', 'did': 'other'},
        'not a map',
        {'sid': 'S', 'did': 'new-did'},
      ]);
    });

    test('carries a test nonce in the same write', () async {
      final dispatch = await backend.subscribe(
        subscription(),
        testNonce: 'nonce-123456',
      );
      check(dispatch)
          .isNotNull()
          .has((d) => d.diagnostics, 'diagnostics')
          .isNull();
      final entry =
          (jsonDecode(
                server.writes.single['subscriptions'] as String,
              ) as List).single
              as Map;
      check(entry['test'] as Map)
          .deepEquals({'nonce': 'nonce-123456', 'at': 1760000000});
    });

    test('writes again when another device dropped this entry', () async {
      server.dropWrites = 1;
      await backend.subscribe(subscription());
      check(server.writes).length.equals(2);
    });

    test('gives up when the entry never sticks', () async {
      server.dropWrites = 5;
      final error = await _backendError(backend.subscribe(subscription()));
      check(error.failure.reason).equals(PushFailureReason.subscriptionLost);
    });

    test('a deleted function is reported, not a sign-out', () async {
      server.function = null;
      final error = await _backendError(backend.subscribe(subscription()));
      check(error.signInNeeded).isFalse();
      check(error.failure.detail).equals('function_missing');
    });

    test('a switched-off function is reported', () async {
      server.function = _function(version: '1.2.0', active: false);
      final error = await _backendError(backend.subscribe(subscription()));
      check(error.failure.detail).equals('function_inactive');
    });
  });

  group('unsubscribe and diagnose', () {
    setUp(() => server.function = _function(version: '1.2.0'));

    test('removes only that sid', () async {
      server.valves = {
        'subscriptions': jsonEncode([
          {'sid': 'A', 'did': 'd'},
          {'sid': 'B', 'did': 'e'},
        ]),
        'status': '{"B":{"code":201,"nonce":"n1"}}',
      };
      await backend.unsubscribe('A');
      check(jsonDecode(server.valves!['subscriptions'] as String) as List)
          .deepEquals([
            {'sid': 'B', 'did': 'e'},
          ]);
      check(server.valves!['status']).equals('{"B":{"code":201,"nonce":"n1"}}');
    });

    test('writes nothing for an unknown sid', () async {
      server.valves = {'subscriptions': '[]'};
      await backend.unsubscribe('A');
      check(server.writes).isEmpty();
    });

    test("reads the function's delivery status for a sid", () async {
      server.valves = {
        'subscriptions': '[]',
        'status': jsonEncode({
          'A': {
            'code': null,
            'at': 1760000000,
            'err': 'blocked',
            'nonce': 'n1',
          },
        }),
      };
      final diagnostics = await backend.diagnose('A');
      check(diagnostics).isNotNull()
        ..has((d) => d.error, 'error').equals('blocked')
        ..has((d) => d.code, 'code').isNull()
        ..has((d) => d.nonce, 'nonce').equals('n1');
      check(await backend.diagnose('B')).isNull();
    });
  });
}

Map<String, dynamic> _function({
  String version = '1.2.0',
  bool active = true,
}) => {
  'id': 'conduit_push',
  'name': 'Conduit Push',
  'type': 'event',
  'is_active': active,
  'meta': {
    'description': 'x',
    'manifest': {'version': version},
  },
};

Future<PushBackendException> _backendError(Future<Object?> future) async {
  try {
    await future;
  } on PushBackendException catch (error) {
    return error;
  }
  throw StateError('expected a PushBackendException');
}

final class _OpenWebUi implements HttpClientAdapter {
  String version = '0.11.4';
  bool? enablePlugins = true;
  String role = 'user';
  Map<String, dynamic>? function;
  Map<String, dynamic>? valves;
  bool authFailure = false;
  bool adminOnlyWrites = false;
  int dropWrites = 0;
  final requests = <RequestOptions>[];
  final bodies = <Object?>[];
  final writes = <Map<String, dynamic>>[];

  List<String> paths({bool write = false}) => [
    for (final request in requests)
      if (!write || request.method != 'GET') request.uri.path,
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.method != 'GET') bodies.add(options.data);
    final path = options.uri.path;
    if (authFailure) {
      return _json({
        'detail': 'Your session has expired or the token is invalid. Please sign in again.',
      }, 401);
    }
    const base = '/api/v1/functions/id/conduit_push';
    switch ((options.method, path)) {
      case ('GET', '/api/config'):
        return _json({
          'version': version,
          'features': {'enable_plugins': ?enablePlugins},
        });
      case ('GET', '/api/v1/auths/'):
        return _json({'id': 'u1', 'role': role});
      case ('GET', '/api/v1/functions/'):
        return _json([?function]);
      case ('POST', '/api/v1/functions/create'):
        if (adminOnlyWrites) return _prohibited();
        final form = options.data as Map;
        function = {
          ..._function(
            version: OpenWebUiFunctionSource.parse(form['content'] as String)!
                .version,
            active: false,
          ),
        };
        return _json(function!);
      case ('POST', '$base/update'):
        if (adminOnlyWrites) return _prohibited();
        if (function == null) return _json({'detail': _notFound}, 401);
        final form = options.data as Map;
        function = {
          ...function!,
          'meta': {
            'manifest': {
              'version': OpenWebUiFunctionSource.parse(
                form['content'] as String,
              )!.version,
            },
          },
        };
        return _json(function!);
      case ('POST', '$base/toggle'):
        if (adminOnlyWrites) return _prohibited();
        if (function == null) return _json({'detail': _notFound}, 401);
        function = {
          ...function!,
          'is_active': !(function!['is_active'] as bool),
        };
        return _json(function!);
      case ('GET', '$base/valves/user'):
        if (function == null) return _json({'detail': _notFound}, 401);
        return _json(valves);
      case ('POST', '$base/valves/user/update'):
        if (function == null) return _json({'detail': _notFound}, 401);
        if (function!['is_active'] != true) {
          return _json({'detail': 'Function is not active'}, 400);
        }
        final body = Map<String, dynamic>.from(options.data as Map);
        writes.add(body);
        if (dropWrites > 0) {
          dropWrites--;
        } else {
          valves = body;
        }
        return _json(body);
    }
    return _json({'detail': 'Not Found'}, 404);
  }

  ResponseBody _prohibited() => _json({
    'detail':
        'You do not have permission to access this resource. Please contact '
        'your administrator for assistance.',
  }, 401);

  ResponseBody _json(Object? body, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
