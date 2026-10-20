import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

const _secretUrl = 'https://hooks.example.com/services/T000/B000/s3cr3t';

typedef _Operation = Future<Object?> Function(
  NotificationTargets targets,
  NotificationTargetsOwner owner,
);

final _operations = <String, _Operation>{
  'create': (targets, owner) => targets.create(
    url: _secretUrl,
    enabled: true,
    events: const ['chat.finished'],
    delivery: 'away',
    owner: owner,
  ),
  'update': (targets, owner) =>
      targets.updateTarget('ops', enabled: false, owner: owner),
  'default': (targets, owner) => targets.makeDefault('ops', owner: owner),
  'delete': (targets, owner) => targets.remove('ops', owner: owner),
  'test': (targets, owner) => targets.sendTest('ops', owner: owner),
};

void main() {
  group('capability', () {
    // Each case is one way the account may not use webhook destinations. The
    // list load and every operation must refuse before any request.
    final denied = <String, void Function(_Session session)>{
      'server flag off': (s) => s.config = _config(enabled: false),
      'server flag missing': (s) => s.config = _config(enabled: null),
      'config from another server': (s) =>
          s.config = _config(serverId: 'other-server'),
      'config without a server': (s) => s.config = _config(serverId: null),
      'no permission document entry': (s) => s.permissions = const {},
      'permission off': (s) => s.permissions = const {
        'features': {'webhooks': false},
      },
    };

    for (final MapEntry(:key, :value) in denied.entries) {
      test('$key refuses the load and every operation', () async {
        final session = await _Session.start(configure: value);
        addTearDown(session.dispose);
        final notifier = session.container.read(
          notificationTargetsProvider.notifier,
        );
        final owner = notifier.captureOwner()!;

        await expectLater(
          session.container.read(notificationTargetsProvider.future),
          throwsA(isA<NotificationTargetsUnavailableException>()),
        );
        for (final MapEntry(key: name, value: run) in _operations.entries) {
          await expectLater(
            run(notifier, owner),
            throwsA(isA<NotificationTargetsUnavailableException>()),
            reason: name,
          );
        }

        check(session.server.requests).isEmpty();
        check(session.container.read(notificationTargetsAvailableProvider))
            .isFalse();
      });
    }

    test('a permitted account loads, and admins need no permission', () async {
      for (final configure in <void Function(_Session)>[
        (s) {},
        (s) {
          s.user = _user(role: 'admin');
          s.permissions = const {};
        },
      ]) {
        final session = await _Session.start(configure: configure);
        addTearDown(session.dispose);

        final data = await session.container.read(
          notificationTargetsProvider.future,
        );

        check(data.targets.map((t) => t.id)).deepEquals(['ops']);
        check(session.container.read(notificationTargetsAvailableProvider))
            .isTrue();
      }
    });

    test(
      'a permission revoked after the editor opened stops the save',
      () async {
        final session = await _Session.start();
        addTearDown(session.dispose);
        await session.container.read(notificationTargetsProvider.future);
        final notifier = session.container.read(
          notificationTargetsProvider.notifier,
        );
        final owner = notifier.captureOwner()!;
        session.server.requests.clear();

        session.permissions = const {
          'features': {'webhooks': false},
        };
        session.container.invalidate(userPermissionsProvider);

        for (final MapEntry(:key, :value) in _operations.entries) {
          await expectLater(
            value(notifier, owner),
            throwsA(isA<NotificationTargetsUnavailableException>()),
            reason: key,
          );
        }
        check(session.server.requests).isEmpty();
      },
    );

    test('an unreadable permission document is a denial', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(notificationTargetsProvider.future);
      final notifier = session.container.read(
        notificationTargetsProvider.notifier,
      );
      final owner = notifier.captureOwner()!;
      session.server.requests.clear();

      session.permissionsError = StateError('offline');
      session.container.invalidate(userPermissionsProvider);

      await expectLater(
        notifier.sendTest('ops', owner: owner),
        throwsA(isA<NotificationTargetsUnavailableException>()),
      );
      check(session.server.requests).isEmpty();
    });
  });

  group('owner captured when a surface opens', () {
    test('operations run for the account that opened it', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(notificationTargetsProvider.future);
      final notifier = session.container.read(
        notificationTargetsProvider.notifier,
      );
      final owner = notifier.captureOwner()!;
      session.server.requests.clear();

      await notifier.updateTarget('ops', enabled: false, owner: owner);
      await notifier.sendTest('ops', owner: owner);

      check(
        session.server.requests
            .where((r) => r.method != 'GET')
            .map((r) => '${r.method} ${r.uri.path}')
            .toList(),
      ).deepEquals([
        'PUT /api/v1/notifications/targets/ops',
        'POST /api/v1/notifications/targets/ops/test',
      ]);
    });

    test('nothing reaches the server once another account signs in on the '
        'same API', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(notificationTargetsProvider.future);
      final notifier = session.container.read(
        notificationTargetsProvider.notifier,
      );
      final owner = notifier.captureOwner()!;

      session.server.targets = [_target('b-hook')];
      session.switchAccount();
      await session.container.read(notificationTargetsProvider.future);
      session.server.requests.clear();

      for (final MapEntry(:key, :value) in _operations.entries) {
        await expectLater(
          value(notifier, owner),
          throwsA(isA<NotificationTargetsOwnerChangedException>()),
          reason: key,
        );
      }

      check(session.server.requests).isEmpty();
      check(
        session.container
            .read(notificationTargetsProvider)
            .requireValue
            .targets
            .map((t) => t.id),
      ).deepEquals(['b-hook']);
    });

    test(
      'an account change during the permission lookup sends nothing',
      () async {
        final session = await _Session.start();
        addTearDown(session.dispose);
        await session.container.read(notificationTargetsProvider.future);
        final notifier = session.container.read(
          notificationTargetsProvider.notifier,
        );
        final owner = notifier.captureOwner()!;
        session.server.requests.clear();

        session.permissionsGate = Completer<void>();
        session.container.invalidate(userPermissionsProvider);
        final test = notifier.sendTest('ops', owner: owner);
        await pumpEventQueue();
        final gate = session.permissionsGate!;
        session.permissionsGate = null;
        session.switchAccount();
        gate.complete();

        await expectLater(
          test,
          throwsA(isA<NotificationTargetsOwnerChangedException>()),
        );
        check(session.server.requests.where((r) => r.method != 'GET'))
            .isEmpty();
      },
    );

    // The providers still agree the account is current, but the ApiService's
    // credentials have already moved on. Only the request-level fence can stop
    // this one.
    test('a credential change that lands after admission cancels the '
        'request', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(notificationTargetsProvider.future);
      final notifier = session.container.read(
        notificationTargetsProvider.notifier,
      );
      final owner = notifier.captureOwner()!;
      session.server.requests.clear();

      session.permissionsGate = Completer<void>();
      session.container.invalidate(userPermissionsProvider);
      final test = notifier.sendTest('ops', owner: owner);
      await pumpEventQueue();
      session.api.updateAuthToken('token-b');
      session.permissionsGate!.complete();

      await expectLater(
        test,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      check(session.server.requests).isEmpty();
    });

    test('a list that arrives after an account switch is discarded', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(notificationTargetsProvider.future);
      final notifier = session.container.read(
        notificationTargetsProvider.notifier,
      );
      final owner = notifier.captureOwner()!;

      final gate = session.server.holdList = Completer<void>();
      final refreshed = notifier.refresh(owner: owner);
      await pumpEventQueue();
      session.server.holdList = null;

      session.server.targets = [_target('b-hook')];
      session.switchAccount();
      await session.container.read(notificationTargetsProvider.future);
      gate.complete();
      await refreshed;

      check(
        session.container
            .read(notificationTargetsProvider)
            .requireValue
            .targets
            .map((t) => t.id),
      ).deepEquals(['b-hook']);
    });
  });

  group('requests', () {
    test('listing and refreshing never send a test notification', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(notificationTargetsProvider.future);
      final notifier = session.container.read(
        notificationTargetsProvider.notifier,
      );
      await notifier.refresh(owner: notifier.captureOwner()!);
      session.container.invalidate(notificationTargetsProvider);
      await session.container.read(notificationTargetsProvider.future);

      check(session.server.requests.where((r) => r.method != 'GET')).isEmpty();
    });

    test('one explicit test is exactly one request', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(notificationTargetsProvider.future);
      final notifier = session.container.read(
        notificationTargetsProvider.notifier,
      );
      session.server.requests.clear();

      await notifier.sendTest('ops', owner: notifier.captureOwner()!);

      check(
        session.server.requests
            .map((r) => '${r.method} ${r.uri.path}')
            .toList(),
      ).deepEquals(['POST /api/v1/notifications/targets/ops/test']);
    });

    test('an edit that leaves the destination alone never sends a URL, and '
        'reads the list back', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(notificationTargetsProvider.future);
      final notifier = session.container.read(
        notificationTargetsProvider.notifier,
      );
      session.server.requests.clear();
      session.server.targets = [_target('ops', enabled: false)];

      await notifier.updateTarget(
        'ops',
        enabled: false,
        owner: notifier.captureOwner()!,
      );

      final put = session.server.requests.singleWhere((r) => r.method == 'PUT');
      check(put.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({'enabled': false});
      check(
        session.container
            .read(notificationTargetsProvider)
            .requireValue
            .targets
            .single
            .enabled,
      ).isFalse();
    });

    test('events this client does not know survive the load', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      session.server.targets = [
        _target('ops', events: const ['chat.finished', 'future.event']),
      ];

      final data = await session.container.read(
        notificationTargetsProvider.future,
      );

      check(data.targets.single.events)
          .deepEquals(['chat.finished', 'future.event']);
      check(data.events.map((e) => e.event)).deepEquals(['chat.finished']);
    });

    test('a catalog that cannot be read leaves the list usable', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      session.server.eventsStatus = 500;

      final data = await session.container.read(
        notificationTargetsProvider.future,
      );

      check(data.targets).length.equals(1);
      check(data.events).isEmpty();
    });

    test('a write that lands but cannot be read back keeps the list and '
        'marks it stale', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(notificationTargetsProvider.future);
      final notifier = session.container.read(
        notificationTargetsProvider.notifier,
      );
      session.server.listStatus = 500;

      await notifier.makeDefault('ops', owner: notifier.captureOwner()!);

      final data = session.container
          .read(notificationTargetsProvider)
          .requireValue;
      check(data.stale).isTrue();
      check(data.targets.map((t) => t.id)).deepEquals(['ops']);
    });

    test('a refused save explains itself without the URL', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(notificationTargetsProvider.future);
      final notifier = session.container.read(
        notificationTargetsProvider.notifier,
      );
      session.server.writeRejection = 'Webhook URL is required';

      Object? caught;
      try {
        await notifier.create(
          url: _secretUrl,
          enabled: true,
          events: const [],
          delivery: 'away',
          owner: notifier.captureOwner()!,
        );
      } catch (error) {
        caught = error;
      }

      check(caught).isNotNull();
      check(notificationTargetErrorDetail(caught!))
          .equals('Webhook URL is required');
      check(caught.toString()).not((text) => text.contains('s3cr3t'));
      check((caught as DioException).error.toString())
          .not((text) => text.contains('s3cr3t'));
    });
  });
}

BackendConfig _config({
  bool? enabled = true,
  String? serverId = 'test-server',
}) => BackendConfig(serverId: serverId, enableUserWebhooks: enabled);

User _user({String role = 'user'}) =>
    User(id: 'user-1', username: 'user', email: 'user@example.com', role: role);

Map<String, dynamic> _target(
  String id, {
  bool enabled = true,
  List<String> events = const ['chat.finished'],
}) => {
  'id': id,
  'type': 'webhook',
  'is_default': true,
  'enabled': enabled,
  'events': events,
  'delivery': 'away',
  'config': {'url_masked': 'https://hooks.example.com/...cret'},
};

/// One signed-in client whose account can be switched without replacing the
/// [ApiService], as happens when another user signs in on the same server.
final class _Session {
  _Session._(this.api, this.server) {
    container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        currentUserProvider2.overrideWith((ref) => user),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWith((ref) => token),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => _epoch),
        backendConfigProvider.overrideWith(() => _FakeBackendConfig(this)),
        userPermissionsProvider.overrideWith((ref) async {
          await permissionsGate?.future;
          final error = permissionsError;
          if (error != null) throw error;
          return permissions;
        }),
      ],
    );
  }

  /// Starts a session whose active server, permissions and capability have
  /// resolved, so the first read of the notifier is not superseded by them.
  static Future<_Session> start({
    void Function(_Session session)? configure,
  }) async {
    final server = _Server();
    final api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
      authToken: 'token-a',
    );
    api.dio.httpClientAdapter = server;
    final session = _Session._(api, server);
    configure?.call(session);
    await session.container.read(activeServerProvider.future);
    await session.container.read(userPermissionsProvider.future);
    await session.container.read(backendConfigProvider.future);
    await pumpEventQueue();
    return session;
  }

  final ApiService api;
  final _Server server;
  late final ProviderContainer container;
  Object _epoch = Object();
  String token = 'token-a';
  User user = _user();
  BackendConfig? config = _config();
  Map<String, dynamic> permissions = const {
    'features': {'webhooks': true},
  };
  Completer<void>? permissionsGate;
  Object? permissionsError;

  void switchAccount() {
    _epoch = Object();
    token = 'token-b';
    api.updateAuthToken('token-b');
    container
      ..invalidate(openWebUiAuthSessionEpochProvider)
      ..invalidate(authTokenProvider3)
      ..invalidate(userPermissionsProvider);
  }

  void dispose() {
    container.dispose();
    api.dispose();
  }
}

final class _FakeBackendConfig extends BackendConfigNotifier {
  _FakeBackendConfig(this._session);

  final _Session _session;

  @override
  Future<BackendConfig?> build() async => _session.config;
}

final class _Storage extends Fake implements OptimizedStorageService {
  @override
  bool isUncommittedServerConfigCandidate(ServerConfig config) => false;

  @override
  Future<List<ServerConfig>> getServerConfigs() async => const [_server];

  @override
  Future<List<ServerConfig>> getServerConfigsStrict() async => const [_server];

  @override
  Future<String?> getActiveServerId() async => _server.id;
}

/// Answers the notification routes with canned bodies and records every
/// request that reaches the wire.
final class _Server implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  List<Map<String, dynamic>> targets = [_target('ops')];
  Completer<void>? holdList;
  int listStatus = 200;
  int eventsStatus = 200;
  String? writeRejection;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    final isWrite = options.method != 'GET';
    if (isWrite && writeRejection != null) {
      return _json({'detail': writeRejection}, 400);
    }
    if (path.endsWith('/events')) {
      return eventsStatus == 200
          ? _json({
              'events': [
                {'event': 'chat.finished', 'label': 'Chat finished'},
              ],
            })
          : _json({'detail': 'unavailable'}, eventsStatus);
    }
    if (path.endsWith('/targets') && options.method == 'GET') {
      final body = {'targets': targets};
      await holdList?.future;
      return listStatus == 200
          ? _json(body)
          : _json({'detail': 'unavailable'}, listStatus);
    }
    if (path.endsWith('/test') || options.method == 'DELETE') {
      return _json({'ok': true});
    }
    return _json(targets.first);
  }

  ResponseBody _json(Object body, [int status = 200]) =>
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
