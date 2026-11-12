import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_set_aside_session_store.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
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

/// Preferences whose writes fail while [refuseWrites] is set.
final class _RefusingStore extends InMemoryKeyValueStore {
  bool refuseWrites = false;

  @override
  Future<bool> setStringList(String key, List<String> value) async =>
      !refuseWrites && await super.setStringList(key, value);
}

late _RefusingStore _store;

void main() {
  setUp(() => PreferencesStore.debugOverride(_store = _RefusingStore()));
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

    test('reads every page of archived sessions', () async {
      final routes = _Routes({
        'GET /api/sessions': (options) {
          final offset = int.parse(options.uri.queryParameters['offset']!);
          final count = offset == 0 ? 100 : 30;
          return (
            200,
            {
              'sessions': [
                for (var index = 0; index < count; index++)
                  {'id': 'local-${offset + index}', 'archived': true},
              ],
            },
          );
        },
      });
      final rows = await _desktop(routes).listArchivedSessions();

      check(rows).isNotNull().length.equals(130);
      check(
        routes.called('GET', '/api/sessions').map((r) => r.query['offset']),
      ).deepEquals(['0', '100']);
    });

    test('archived sessions past five pages are listed too', () async {
      final routes = _Routes({
        'GET /api/sessions': (options) {
          final offset = int.parse(options.uri.queryParameters['offset']!);
          final count = offset < 600 ? 100 : 7;
          return (
            200,
            {
              'sessions': [
                for (var index = 0; index < count; index++)
                  {'id': 'local-${offset + index}', 'archived': true},
              ],
            },
          );
        },
      });

      final rows = await _desktop(routes).listArchivedSessions();

      check(rows).isNotNull().length.equals(607);
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
    for (final hidden in [false, true]) {
      test('asks each server to leave scheduled runs out only once they are '
          'hidden (hidden: $hidden)', () async {
        if (hidden) {
          await PreferencesStore.put(
            PreferenceKeys.hermesShowScheduledSessions,
            false,
          );
        }
        final api = _Routes({
          'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        });
        await _container(_rest(api)).read(hermesSessionsProvider.future);
        // The API server cannot leave a source out: it lists its largest
        // page instead, so runs crowd out fewer chats.
        check(
          api.called('GET', '/api/sessions').single.query['limit'],
        ).equals(hidden ? '$kHermesApiServerMaxSessionPage' : null);

        final dashboard = _Routes({
          'GET /api/sessions': (_) => (200, {'sessions': <Object>[]}),
        });
        await _container(
          _desktop(dashboard),
        ).read(hermesSessionsProvider.future);
        final list = dashboard.called('GET', '/api/sessions').single;
        check(list.query['exclude_sources']).equals(hidden ? 'cron' : null);
        check(list.query['limit']).equals('100');
      });
    }

    test('an archived run that cannot be read is still filtered as a run',
        () async {
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        'PATCH /api/sessions/run_1': (_) => (200, {'session': {}}),
        // The server is down when the archived row looks the run up.
        'GET /api/sessions/run_1': (_) => (
          503,
          {
            'error': {'code': 'unavailable', 'message': 'down'},
          },
        ),
      });
      final service = _rest(routes);
      final container = _container(service);
      const run = HermesSessionSummary(
        id: 'run_1',
        title: 'Synthetic digest',
        source: 'cron',
      );

      await container
          .read(hermesSessionsProvider.notifier)
          .setArchived(run, true);
      final record = HermesSetAsideSessionStore.find(
        scope: hermesSetAsideScope(service.config),
        sessionId: 'run_1',
      );
      check(record?.source).equals('cron');

      final archived = await container.read(
        hermesArchivedSessionsProvider.future,
      );
      check(archived.single)
        ..has((session) => session.id, 'id').equals('run_1')
        ..has((session) => session.source, 'source').equals('cron');
      check(hermesListedSessions(archived, showScheduled: false)).isEmpty();
    });

    test('a kept record reads back its source; an older one has none', () {
      const record = HermesSetAsideSession(
        scope: 'conn-rest',
        sessionId: 'run_1',
        title: 'Synthetic digest',
        kind: HermesSetAsideKind.archived,
        source: 'cron',
      );
      final restored = HermesSetAsideSession.fromStorage(record.toStorage());
      check(restored?.source).equals('cron');
      check(restored?.toSummary().source).equals('cron');

      final older = HermesSetAsideSession.fromStorage(
        '{"scope":"conn-rest","session_id":"chat_1","title":"Synthetic",'
        '"kind":"archived"}',
      );
      check(older).isNotNull().has((r) => r.source, 'source').isNull();
    });

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
      final scope = hermesSetAsideScope(service.config);
      check(HermesSetAsideSessionStore.forScope(scope)).length.equals(1);
      final archived = await container.read(
        hermesArchivedSessionsProvider.future,
      );
      check(archived.map((session) => session.id)).deepEquals(['api_1']);

      await container
          .read(hermesSessionsProvider.notifier)
          .setArchived(archived.single, false);
      check(HermesSetAsideSessionStore.forScope(scope)).isEmpty();
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
      final scope = hermesSetAsideScope(service.config);
      final container = _container(service);
      final sessions = container.read(hermesSessionsProvider.notifier);

      await sessions.setHidden(
        const HermesSessionSummary(id: 'local-h', title: 'Synthetic hidden'),
        true,
      );
      await HermesSetAsideSessionStore.remember(
        HermesSetAsideSession(
          scope: scope,
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
      check(HermesSetAsideSessionStore.forScope(scope)).length.equals(1);

      // Unhidden from another app: no longer offered here.
      hiddenOnServer = false;
      container.invalidate(hermesHiddenSessionsProvider);
      check(
        await container.read(hermesHiddenSessionsProvider.future),
      ).isEmpty();
      check(HermesSetAsideSessionStore.forScope(scope)).isEmpty();
    });

    // A delete refreshed the archived list but not the hidden one, which
    // kept the deleted chat while it was open.
    test('a deleted hidden chat leaves the hidden list', () async {
      var deleted = false;
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        'PATCH /api/sessions/api_h': (_) => (200, {'session': {}}),
        'GET /api/sessions/api_h': (_) => deleted
            ? (404, {'detail': 'Not Found'})
            : (
                200,
                {
                  'session': {
                    'id': 'api_h',
                    'title': 'Synthetic hidden',
                    'hidden': true,
                  },
                },
              ),
        'DELETE /api/sessions/api_h': (_) {
          deleted = true;
          return (200, {'ok': true});
        },
      });
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: [
          hermesApiServiceProvider.overrideWithValue(_rest(routes)),
          directLocalDatabaseProvider.overrideWithValue(database),
        ],
      );
      addTearDown(container.dispose);
      final sessions = container.read(hermesSessionsProvider.notifier);
      await sessions.setHidden(
        const HermesSessionSummary(id: 'api_h', title: 'Synthetic hidden'),
        true,
      );
      // The hidden chats are on screen.
      final shown = container.listen(hermesHiddenSessionsProvider, (_, _) {});
      addTearDown(shown.close);
      check(
        (await container.read(
          hermesHiddenSessionsProvider.future,
        )).map((session) => session.id),
      ).deepEquals(['api_h']);

      check(await sessions.delete('api_h')).isTrue();

      check(
        await container.read(hermesHiddenSessionsProvider.future),
      ).isEmpty();
    });

    test('an archived chat brought out of hiding is archived again', () async {
      var flags = <String, Object?>{'archived': true, 'hidden': true};
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        'PATCH /api/sessions/api_1': (options) {
          final data = options.data;
          flags = {
            ...flags,
            ...(data is String ? jsonDecode(data) as Map : data as Map),
          };
          return (200, {'session': {}});
        },
        'GET /api/sessions/api_1': (_) => (
          200,
          {
            'session': {'id': 'api_1', 'title': 'Synthetic plan', ...flags},
          },
        ),
      });
      final service = _rest(routes);
      final container = _container(service);
      final notifier = container.read(hermesSessionsProvider.notifier);
      const archived = HermesSessionSummary(
        id: 'api_1',
        title: 'Synthetic plan',
        archived: true,
      );
      flags = {'archived': true, 'hidden': false};

      await notifier.setHidden(archived, true);
      final hidden = await container.read(hermesHiddenSessionsProvider.future);
      check(hidden.single.archived).isTrue();

      await notifier.setHidden(hidden.single, false);
      check(
        HermesSetAsideSessionStore.find(
          scope: hermesSetAsideScope(service.config),
          sessionId: 'api_1',
        )?.kind,
      ).equals(HermesSetAsideKind.archived);
      final archivedRow = await container.read(
        hermesArchivedSessionsProvider.future,
      );
      check(archivedRow.map((session) => session.id)).deepEquals(['api_1']);
    });

    test('the way back is saved before the server sets a chat aside, and '
        'kept when its answer fails', () async {
      HermesSetAsideSession? savedAtPatch;
      var refuse = false;
      late final String scope;
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        'PATCH /api/sessions/api_1': (_) {
          savedAtPatch = HermesSetAsideSessionStore.find(
            scope: scope,
            sessionId: 'api_1',
          );
          return refuse ? (500, {'error': 'refused'}) : (200, {'session': {}});
        },
      });
      final service = _rest(routes);
      scope = hermesSetAsideScope(service.config);
      final notifier = _container(
        service,
      ).read(hermesSessionsProvider.notifier);
      const session = HermesSessionSummary(id: 'api_1', title: 'Plan');

      await notifier.setArchived(session, true);
      check(savedAtPatch?.kind).equals(HermesSetAsideKind.archived);

      refuse = true;
      await check(
        notifier.setHidden(session.copyWith(archived: true), true),
      ).throws<DioException>();
      check(savedAtPatch?.kind).equals(HermesSetAsideKind.hidden);
      // Hermes may have hidden it before its answer was lost: the record
      // stays, and its lookup puts it right.
      check(
        HermesSetAsideSessionStore.find(scope: scope, sessionId: 'api_1'),
      ).isNotNull()
        ..has((r) => r.kind, 'kind').equals(HermesSetAsideKind.hidden)
        ..has((r) => r.archived, 'archived').isTrue();
    });

    test('a lookup moves a record to where the chat now is', () async {
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        // The hide never landed: the chat is archived, not hidden.
        'GET /api/sessions/api_1': (_) => (
          200,
          {
            'session': {
              'id': 'api_1',
              'title': 'Synthetic plan',
              'archived': true,
              'hidden': false,
            },
          },
        ),
      });
      final service = _rest(routes);
      final scope = hermesSetAsideScope(service.config);
      await HermesSetAsideSessionStore.remember(
        HermesSetAsideSession(
          scope: scope,
          sessionId: 'api_1',
          title: 'Synthetic plan',
          kind: HermesSetAsideKind.hidden,
          archived: true,
        ),
      );
      final container = _container(service);

      check(
        await container.read(hermesHiddenSessionsProvider.future),
      ).isEmpty();
      check(
        HermesSetAsideSessionStore.find(scope: scope, sessionId: 'api_1')?.kind,
      ).equals(HermesSetAsideKind.archived);
      check(
        (await container.read(
          hermesArchivedSessionsProvider.future,
        )).map((session) => session.id),
      ).deepEquals(['api_1']);
    });

    test('an unreadable hidden chat keeps its archived flag', () async {
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        'GET /api/sessions/api_1': (_) => (503, {'error': 'down'}),
      });
      final service = _rest(routes);
      final scope = hermesSetAsideScope(service.config);
      await HermesSetAsideSessionStore.remember(
        HermesSetAsideSession(
          scope: scope,
          sessionId: 'api_1',
          title: 'Synthetic plan',
          kind: HermesSetAsideKind.hidden,
          archived: true,
        ),
      );

      final hidden = await _container(
        service,
      ).read(hermesHiddenSessionsProvider.future);

      check(hidden.single)
        ..has((s) => s.hidden, 'hidden').isTrue()
        ..has((s) => s.archived, 'archived').isTrue();
    });

    test('a lookup does not drop a record that replaced the one it read',
        () async {
      final service = _rest(_Routes({}));
      final scope = hermesSetAsideScope(service.config);
      final archivedRecord = HermesSetAsideSession(
        scope: scope,
        sessionId: 'api_1',
        title: 'Synthetic plan',
        kind: HermesSetAsideKind.archived,
      );
      await HermesSetAsideSessionStore.remember(archivedRecord);
      // Hidden meanwhile: the newer record replaced the archived one.
      final hiddenRecord = HermesSetAsideSession(
        scope: scope,
        sessionId: 'api_1',
        title: 'Synthetic plan',
        kind: HermesSetAsideKind.hidden,
        archived: true,
      );
      await HermesSetAsideSessionStore.remember(hiddenRecord);

      await HermesSetAsideSessionStore.forgetRecord(archivedRecord);

      check(
        HermesSetAsideSessionStore.find(scope: scope, sessionId: 'api_1')?.kind,
      ).equals(HermesSetAsideKind.hidden);
    });

    test('a replacement too long to read back keeps the record', () async {
      final service = _rest(_Routes({}));
      final scope = hermesSetAsideScope(service.config);
      final record = HermesSetAsideSession(
        scope: scope,
        sessionId: 'api_1',
        title: 'Synthetic plan',
        kind: HermesSetAsideKind.hidden,
      );
      await HermesSetAsideSessionStore.remember(record);

      await HermesSetAsideSessionStore.replaceRecord(
        record,
        HermesSetAsideSession(
          scope: scope,
          sessionId: 'api_1',
          title: 'T' * 4096,
          kind: HermesSetAsideKind.archived,
        ),
      );

      check(
        HermesSetAsideSessionStore.find(scope: scope, sessionId: 'api_1')?.kind,
      ).equals(HermesSetAsideKind.hidden);
    });

    test('a lookup leaves a record alone while its change is under way',
        () async {
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        // Read before the hide lands: not hidden yet.
        'GET /api/sessions/api_1': (_) => (
          200,
          {
            'session': {'id': 'api_1', 'title': 'Synthetic plan'},
          },
        ),
      });
      final service = _rest(routes);
      final scope = hermesSetAsideScope(service.config);
      await HermesSetAsideSessionStore.remember(
        HermesSetAsideSession(
          scope: scope,
          sessionId: 'api_1',
          title: 'Synthetic plan',
          kind: HermesSetAsideKind.hidden,
        ),
      );
      final container = _container(service);

      await HermesSetAsideSessionStore.whileChanging(
        scope: scope,
        sessionId: 'api_1',
        change: () => container.read(hermesHiddenSessionsProvider.future),
      );

      check(
        HermesSetAsideSessionStore.find(scope: scope, sessionId: 'api_1'),
      ).isNotNull();
    });

    // The change ended before the stale flags arrived, so nothing marked it
    // as under way, and the record it saved was forgotten.
    test('a change made while a lookup read the flags keeps its record',
        () async {
      late final String scope;
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        'GET /api/sessions/api_1': (_) {
          // Hidden, and answered, while this read is on its way back.
          unawaited(
            HermesSetAsideSessionStore.whileChanging(
              scope: scope,
              sessionId: 'api_1',
              change: () async {},
            ),
          );
          return (
            200,
            {
              'session': {'id': 'api_1', 'title': 'Synthetic plan'},
            },
          );
        },
      });
      final service = _rest(routes);
      scope = hermesSetAsideScope(service.config);
      await HermesSetAsideSessionStore.remember(
        HermesSetAsideSession(
          scope: scope,
          sessionId: 'api_1',
          title: 'Synthetic plan',
          kind: HermesSetAsideKind.hidden,
        ),
      );

      await _container(service).read(hermesHiddenSessionsProvider.future);

      check(
        HermesSetAsideSessionStore.isChanging(scope: scope, sessionId: 'api_1'),
      ).isFalse();
      check(
        HermesSetAsideSessionStore.find(scope: scope, sessionId: 'api_1'),
      ).isNotNull();
    });

    test('a change saves its record again once Hermes answers', () async {
      late final String scope;
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        'PATCH /api/sessions/api_1': (_) {
          // A lookup that ran before the change was marked dropped it.
          unawaited(
            HermesSetAsideSessionStore.forget(scope: scope, sessionId: 'api_1'),
          );
          return (200, {'session': {}});
        },
      });
      final service = _rest(routes);
      scope = hermesSetAsideScope(service.config);
      final notifier = _container(
        service,
      ).read(hermesSessionsProvider.notifier);

      await notifier.setHidden(
        const HermesSessionSummary(id: 'api_1', title: 'Plan'),
        true,
      );

      check(
        HermesSetAsideSessionStore.find(scope: scope, sessionId: 'api_1')?.kind,
      ).equals(HermesSetAsideKind.hidden);
    });

    test('a record too long to read back is refused', () async {
      await check(
        HermesSetAsideSessionStore.remember(
          HermesSetAsideSession(
            scope: 'https://hermes.example/${'p' * 4096}',
            sessionId: 'api_1',
            title: 'Synthetic plan',
            kind: HermesSetAsideKind.hidden,
          ),
        ),
      ).throws<ArgumentError>();
    });

    // A record write that failed made the whole list fail to load, and the
    // other hidden chats, listed nowhere else, could not be brought back.
    test('a record that cannot be updated leaves the list loading', () async {
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
        // Brought back from another app: its record is to be dropped.
        'GET /api/sessions/api_1': (_) => (
          200,
          {
            'session': {'id': 'api_1', 'title': 'Synthetic plan'},
          },
        ),
        'GET /api/sessions/api_2': (_) => (
          200,
          {
            'session': {
              'id': 'api_2',
              'title': 'Synthetic list',
              'hidden': true,
            },
          },
        ),
      });
      final service = _rest(routes);
      final scope = hermesSetAsideScope(service.config);
      for (final (id, title) in [
        ('api_1', 'Synthetic plan'),
        ('api_2', 'Synthetic list'),
      ]) {
        await HermesSetAsideSessionStore.remember(
          HermesSetAsideSession(
            scope: scope,
            sessionId: id,
            title: title,
            kind: HermesSetAsideKind.hidden,
          ),
        );
      }
      _store.refuseWrites = true;
      final container = _container(service);

      check(
        (await container.read(
          hermesHiddenSessionsProvider.future,
        )).map((session) => session.id),
      ).deepEquals(['api_2']);
      // Kept for a later lookup to drop.
      check(
        HermesSetAsideSessionStore.find(scope: scope, sessionId: 'api_1'),
      ).isNotNull();
    });

    test('a full store refuses before the server changes', () async {
      const full = HermesSetAsideSessionStore.maxRecords;
      for (var index = 0; index < full; index++) {
        await HermesSetAsideSessionStore.remember(
          HermesSetAsideSession(
            scope: 'elsewhere',
            sessionId: 'old_$index',
            title: 'Old',
            kind: HermesSetAsideKind.hidden,
          ),
        );
      }
      final routes = _Routes();
      final notifier = _container(
        _rest(routes),
      ).read(hermesSessionsProvider.notifier);

      await check(
        notifier.setHidden(
          const HermesSessionSummary(id: 'api_1', title: 'Plan'),
          true,
        ),
      ).throws<HermesSetAsideStoreFullException>();
      check(routes.called('PATCH', '/api/sessions/api_1')).isEmpty();
      // Nothing older was dropped to make room.
      check(HermesSetAsideSessionStore.forScope('elsewhere'))
          .length
          .equals(HermesSetAsideSessionStore.maxRecords);
    });

    test('every saved chat is looked up, not only the newest', () async {
      final routes = _Routes({
        'GET /api/sessions': (_) => (200, {'data': <Object>[]}),
      });
      final service = _rest(routes);
      final scope = hermesSetAsideScope(service.config);
      for (var index = 0; index < 60; index++) {
        routes.routes['GET /api/sessions/api_$index'] = (_) => (
          200,
          {
            'session': {'id': 'api_$index', 'title': 'Chat', 'hidden': true},
          },
        );
        await HermesSetAsideSessionStore.remember(
          HermesSetAsideSession(
            scope: scope,
            sessionId: 'api_$index',
            title: 'Chat',
            kind: HermesSetAsideKind.hidden,
          ),
        );
      }

      final hidden = await _container(
        service,
      ).read(hermesHiddenSessionsProvider.future);
      check(hidden).length.equals(60);
    });
  });

  group('set-aside scope', () {
    HermesConfig config({
      String baseUrl = 'https://hermes.example',
      String profile = 'default',
      HermesBackendMode mode = HermesBackendMode.desktopGateway,
    }) => HermesConfig(
      enabled: true,
      baseUrl: baseUrl,
      mode: mode,
      desktopProfile: profile,
      connectionId: 'conn-1',
    );

    test('follows the endpoint and Desktop profile', () {
      final base = hermesSetAsideScope(config());
      check(hermesSetAsideScope(config(profile: 'research'))).not(
        (it) => it.equals(base),
      );
      check(
        hermesSetAsideScope(config(baseUrl: 'https://other.example')),
      ).not((it) => it.equals(base));
      // The API server has no profiles.
      check(
        hermesSetAsideScope(
          config(mode: HermesBackendMode.responsesApi, profile: 'research'),
        ),
      ).equals(
        hermesSetAsideScope(config(mode: HermesBackendMode.responsesApi)),
      );
    });

    test('every scope of a deleted connection is cleared', () async {
      for (final scope in [
        hermesSetAsideScope(config()),
        hermesSetAsideScope(config(profile: 'research')),
      ]) {
        await HermesSetAsideSessionStore.remember(
          HermesSetAsideSession(
            scope: scope,
            sessionId: 'local-1',
            title: 'Chat',
            kind: HermesSetAsideKind.hidden,
          ),
        );
      }
      await HermesSetAsideSessionStore.clearScopes(
        (scope) => hermesSetAsideScopeOfConnection(scope, 'conn-1'),
      );
      check(
        HermesSetAsideSessionStore.forScope(hermesSetAsideScope(config())),
      ).isEmpty();
      check(
        HermesSetAsideSessionStore.forScope(
          hermesSetAsideScope(config(profile: 'research')),
        ),
      ).isEmpty();
    });
  });
}
