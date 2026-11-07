import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_set_aside_session_store.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

typedef _Request = ({
  String method,
  String path,
  Map<String, String> query,
  Object? body,
});

/// Answers REST requests from a `METHOD /path` table (else 200 `{}`) and
/// records each with its decoded JSON body.
final class _Routes implements HttpClientAdapter {
  _Routes([Map<String, (int, Object?) Function(RequestOptions)>? routes])
    : routes = routes ?? {};

  final Map<String, (int, Object?) Function(RequestOptions)> routes;
  final requests = <_Request>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object? body = options.data;
    if (requestStream != null) {
      final bytes = <int>[];
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
      body = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
    } else if (body is String && body.isNotEmpty) {
      body = jsonDecode(body);
    }
    if (options.uri.path != '/api/status') {
      requests.add((
        method: options.method,
        path: options.uri.path,
        query: options.uri.queryParameters,
        body: body,
      ));
    }
    final key = '${options.method} ${options.uri.path}';
    final (status, response) =
        routes[key]?.call(options) ??
        (options.uri.path == '/api/status'
            ? (200, {'auth_required': false, 'gateway_running': true})
            : (200, <String, Object?>{}));
    return ResponseBody.fromString(
      jsonEncode(response),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  List<_Request> called(String method, String path) => [
    for (final request in requests)
      if (request.method == method && request.path == path) request,
  ];
}

HermesApiService _rest(_Routes routes, {String connectionId = 'conn-rest'}) =>
    HermesApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        apiKey: 'synthetic-key',
        connectionId: connectionId,
      ),
      dio: Dio()..httpClientAdapter = routes,
    );

HermesDesktopApiService _desktop(
  _Routes routes, {
  String connectionId = 'conn-desktop',
}) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://desktop.example',
      mode: HermesBackendMode.desktopGateway,
      desktopAuthKind: HermesDesktopAuthKind.legacyToken,
      desktopCredentials: HermesDesktopCredentials(
        legacyToken: 'session-token',
      ),
      connectionId: connectionId,
    ),
    dio: Dio()..httpClientAdapter = routes,
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) =>
          throw StateError('no socket in this test'),
    ),
  );
  addTearDown(service.close);
  return service;
}

ProviderContainer _container(HermesBackendService service) {
  final container = ProviderContainer(
    overrides: [hermesApiServiceProvider.overrideWithValue(service)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  group('a session summary', () {
    test('reads sidebar flags as booleans or SQLite 0/1', () {
      final dashboard = HermesSessionSummary.fromJson({
        'id': 'local-1',
        'title': 'Synthetic trip',
        'pinned': true,
        'archived': false,
        'hidden': 1,
      })!;
      check(dashboard.pinned).isTrue();
      check(dashboard.archived).isFalse();
      check(dashboard.hidden).isTrue();

      final plain = HermesSessionSummary.fromJson({'id': 'api-1'})!;
      check(plain.pinned).isFalse();
      check(plain.archived).isFalse();
      check(plain.hidden).isFalse();
    });
  });

  group('the API server', () {
    test('patches only the flags it is given', () async {
      final routes = _Routes();
      await _rest(
        routes,
      ).setSessionFlags('api_1', archived: true, pinned: false);

      final patch = routes.called('PATCH', '/api/sessions/api_1').single;
      check(patch.body as Map?).isNotNull().deepEquals({
        'pinned': false,
        'archived': true,
      });
    });

    test('cannot list archived sessions and reads one by id', () async {
      final routes = _Routes({
        'GET /api/sessions/api_1': (_) => (
          200,
          {
            'object': 'hermes.session',
            'session': {'id': 'api_1', 'title': 'Synthetic', 'archived': true},
          },
        ),
        'GET /api/sessions/gone': (_) => (
          404,
          {
            'error': {'code': 'session_not_found', 'message': 'gone'},
          },
        ),
      });
      final service = _rest(routes);

      check(await service.listArchivedSessions()).isNull();
      check(
        await service.getSession('api_1'),
      ).isNotNull().has((row) => row['archived'], 'archived').equals(true);
      check(await service.getSession('gone')).isNull();
    });
  });

  group('the dashboard', () {
    test('fences a flag edit with the mutation snapshot', () async {
      final routes = _Routes({
        'GET /api/sessions/local-1/mutation-snapshot': (_) => (
          200,
          {'exists': true, 'runtime_revision': 4, 'runtime_generation': 2},
        ),
      });
      await _desktop(routes).setSessionFlags('local-1', pinned: true);

      final patch = routes.called('PATCH', '/api/sessions/local-1').single;
      final body = patch.body as Map;
      check(body['pinned']).equals(true);
      check(body['expected_revision']).equals(4);
      check(body['expected_generation']).equals(2);
      check(body['request_id'] as String?).isNotNull().isNotEmpty();
      // The PATCH body names the profile: the dashboard reads it there.
      check(body['profile']).equals('default');
      check(body.containsKey('archived')).isFalse();
    });

    test('an older dashboard takes the plain edit', () async {
      final routes = _Routes({
        'GET /api/sessions/local-1/mutation-snapshot': (_) => (
          404,
          {'detail': 'Not Found'},
        ),
      });
      await _desktop(routes).setSessionFlags('local-1', hidden: true);

      final body =
          routes.called('PATCH', '/api/sessions/local-1').single.body as Map;
      check(body).deepEquals({'hidden': true, 'profile': 'default'});
    });

    test('lists only archived sessions for the archived row', () async {
      final routes = _Routes({
        'GET /api/sessions': (options) => (
          200,
          {
            'sessions': [
              {
                'id': 'local-a',
                'title': 'Archived synthetic',
                'archived': true,
                'hidden': 0,
              },
            ],
          },
        ),
      });
      final rows = await _desktop(routes).listArchivedSessions();

      check(rows).isNotNull().length.equals(1);
      final list = routes.called('GET', '/api/sessions').single;
      check(list.query['archived']).equals('only');
      check(list.query['order']).equals('recent');
    });
  });

  group('the sessions controller', () {
    test('leaves archived and hidden rows out of the list', () async {
      final routes = _Routes({
        'GET /api/sessions': (_) => (
          200,
          {
            'data': [
              {'id': 'kept', 'title': 'Kept', 'pinned': true},
              {'id': 'archived', 'title': 'Old', 'archived': true},
              {'id': 'hidden', 'title': 'Hidden', 'hidden': true},
            ],
          },
        ),
      });
      final container = _container(_rest(routes));

      final sessions = await container.read(hermesSessionsProvider.future);
      check(sessions.map((session) => session.id)).deepEquals(['kept']);
      check(sessions.single.pinned).isTrue();
    });

    test('archiving unpins and, on the API server, keeps the chat '
        'so the archived row can list it', () async {
      final patches = <Object?>[];
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        'PATCH /api/sessions/api_1': (options) {
          patches.add(options.data);
          return (200, {'session': {}});
        },
        'GET /api/sessions/api_1': (_) => (
          200,
          {
            'session': {
              'id': 'api_1',
              'title': 'Synthetic plan',
              'archived': true,
            },
          },
        ),
      });
      final service = _rest(routes);
      final container = _container(service);
      const session = HermesSessionSummary(
        id: 'api_1',
        title: 'Synthetic plan',
        pinned: true,
      );

      await container
          .read(hermesSessionsProvider.notifier)
          .setArchived(session, true);

      final patch =
          routes.called('PATCH', '/api/sessions/api_1').single.body as Map;
      check(patch).deepEquals({'pinned': false, 'archived': true});
      check(
        HermesSetAsideSessionStore.forScope('conn-rest'),
      ).length.equals(1);
      final archived = await container.read(
        hermesArchivedSessionsProvider.future,
      );
      check(archived.map((session) => session.id)).deepEquals(['api_1']);

      await container
          .read(hermesSessionsProvider.notifier)
          .setArchived(archived.single, false);
      check(HermesSetAsideSessionStore.forScope('conn-rest')).isEmpty();
    });

    test('a hidden chat is listed for settings until it is unhidden '
        'or gone', () async {
      var hiddenOnServer = true;
      final routes = _Routes({
        'GET /api/sessions/local-h/mutation-snapshot': (_) => (
          200,
          {'exists': true, 'runtime_revision': 1, 'runtime_generation': 1},
        ),
        'GET /api/sessions/local-h': (_) => (
          200,
          {
            'id': 'local-h',
            'title': 'Synthetic hidden',
            'hidden': hiddenOnServer ? 1 : 0,
          },
        ),
        'GET /api/sessions/local-gone': (_) => (404, {'detail': 'Not Found'}),
        'GET /api/sessions': (_) => (200, {'sessions': <Object>[]}),
      });
      final service = _desktop(routes);
      final container = _container(service);
      final sessions = container.read(hermesSessionsProvider.notifier);

      await sessions.setHidden(
        const HermesSessionSummary(id: 'local-h', title: 'Synthetic hidden'),
        true,
      );
      await HermesSetAsideSessionStore.remember(
        const HermesSetAsideSession(
          scope: 'conn-desktop',
          sessionId: 'local-gone',
          title: 'Deleted elsewhere',
          kind: HermesSetAsideKind.hidden,
        ),
      );

      final hidden = await container.read(
        hermesHiddenSessionsProvider.future,
      );
      check(hidden.map((session) => session.id)).deepEquals(['local-h']);
      // The deleted one is forgotten once its lookup finds nothing.
      check(
        HermesSetAsideSessionStore.forScope('conn-desktop'),
      ).length.equals(1);

      // Unhidden from another app: no longer offered here.
      hiddenOnServer = false;
      container.invalidate(hermesHiddenSessionsProvider);
      check(
        await container.read(hermesHiddenSessionsProvider.future),
      ).isEmpty();
      check(HermesSetAsideSessionStore.forScope('conn-desktop')).isEmpty();
    });
  });
}
