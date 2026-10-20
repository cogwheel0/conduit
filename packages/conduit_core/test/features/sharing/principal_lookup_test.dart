import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/sharing/providers/principal_lookup.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://server.example',
  isActive: true,
);

typedef _Ref = ({WorkspacePrincipalType type, String id});

_Ref _user(String id) => (type: WorkspacePrincipalType.user, id: id);
_Ref _group(String id) => (type: WorkspacePrincipalType.group, id: id);

WorkspacePrincipalPreview _person(String id, String name) =>
    WorkspacePrincipalPreview(
      id: id,
      type: WorkspacePrincipalType.user,
      name: name,
    );

/// Answers the users and groups routes, recording each request and the
/// bearer it carried.
final class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final users = <String, Map<String, dynamic>>{};
  int failWith = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    ResponseBody reply(Object body, int status) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
    if (failWith != 0) return reply({'detail': 'nope'}, failWith);
    final path = options.path;
    if (path == '/api/v1/groups/') {
      return reply([
        {'id': 'g-1', 'name': 'Editors'},
      ], 200);
    }
    final id = path.split('/')[4];
    final user = users[id];
    return user == null
        ? reply({'detail': 'User not found'}, 400)
        : reply(user, 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('WorkspacePrincipalLookup', () {
    test('asks once per person, remembers who does not exist, and asks '
        'again after a failure', () async {
      final asked = <String>[];
      var failCarol = true;
      final lookup = WorkspacePrincipalLookup(
        fetchUser: (id) async {
          asked.add(id);
          if (id == 'carol' && failCarol) throw StateError('offline');
          return switch (id) {
            'alice' => _person('alice', 'Alice'),
            'carol' => _person('carol', 'Carol'),
            _ => null,
          };
        },
        fetchGroups: () async => const [],
      );

      await lookup.resolve([_user('alice'), _user('ghost'), _user('carol')]);
      check(lookup.cached(WorkspacePrincipalType.user, 'alice')?.name)
          .equals('Alice');
      check(lookup.resolutionOf(WorkspacePrincipalType.user, 'ghost'))
          .equals(WorkspacePrincipalResolution.unresolvable);
      check(lookup.resolutionOf(WorkspacePrincipalType.user, 'carol'))
          .equals(WorkspacePrincipalResolution.unknown);

      failCarol = false;
      await lookup.resolve([_user('alice'), _user('ghost'), _user('carol')]);
      check(asked).deepEquals(['alice', 'ghost', 'carol', 'carol']);
      check(lookup.cached(WorkspacePrincipalType.user, 'carol')?.name)
          .equals('Carol');
    });

    test('a resolve made while another is in flight waits for it instead of '
        'asking again', () async {
      final gate = Completer<void>();
      var asks = 0;
      final lookup = WorkspacePrincipalLookup(
        fetchUser: (id) async {
          asks++;
          await gate.future;
          return _person(id, 'Alice');
        },
        fetchGroups: () async => const [],
      );

      final first = lookup.resolve([_user('alice')]);
      check(lookup.resolutionOf(WorkspacePrincipalType.user, 'alice'))
          .equals(WorkspacePrincipalResolution.pending);
      final second = lookup.resolve([_user('alice')]);
      gate.complete();
      await Future.wait([first, second]);

      check(asks).equals(1);
      check(lookup.resolutionOf(WorkspacePrincipalType.user, 'alice'))
          .equals(WorkspacePrincipalResolution.resolved);
    });

    test(
      'no more than the allowed number of people are asked at once',
      () async {
        var inFlight = 0;
        var most = 0;
        final lookup = WorkspacePrincipalLookup(
          maxConcurrentUsers: 2,
          fetchUser: (id) async {
            inFlight++;
            most = most > inFlight ? most : inFlight;
            await Future<void>.delayed(Duration.zero);
            inFlight--;
            return _person(id, id);
          },
          fetchGroups: () async => const [],
        );

        await lookup.resolve([for (var i = 0; i < 7; i++) _user('u$i')]);

        check(most).equals(2);
        for (var i = 0; i < 7; i++) {
          check(lookup.resolutionOf(WorkspacePrincipalType.user, 'u$i'))
              .equals(WorkspacePrincipalResolution.resolved);
        }
      },
    );

    test(
      'groups are listed once; a group not in the list is unknown',
      () async {
        var loads = 0;
        final lookup = WorkspacePrincipalLookup(
          fetchUser: (_) async => null,
          fetchGroups: () async {
            loads++;
            return const [
              WorkspacePrincipalPreview(
                id: 'g-1',
                type: WorkspacePrincipalType.group,
                name: 'Editors',
              ),
            ];
          },
        );

        await lookup.resolve([_group('g-1'), _group('g-2')]);
        await lookup.resolve([_group('g-1'), _group('g-2')]);

        check(loads).equals(1);
        check(lookup.cached(WorkspacePrincipalType.group, 'g-1')?.name)
            .equals('Editors');
        check(lookup.resolutionOf(WorkspacePrincipalType.group, 'g-2'))
            .equals(WorkspacePrincipalResolution.unresolvable);
      },
    );

    test('what a picker already returned is known without asking', () async {
      var asks = 0;
      final lookup = WorkspacePrincipalLookup(
        fetchUser: (_) async {
          asks++;
          return null;
        },
        fetchGroups: () async => throw StateError('not needed'),
      );

      lookup.remember([
        _person('dana', 'Dana'),
        const WorkspacePrincipalPreview(
          id: 'g-9',
          type: WorkspacePrincipalType.group,
          name: 'Ops',
        ),
      ]);
      await lookup.resolve([_user('dana'), _group('g-9')]);

      check(asks).equals(0);
      check(lookup.cached(WorkspacePrincipalType.user, 'dana')?.name)
          .equals('Dana');
      check(lookup.cached(WorkspacePrincipalType.group, 'g-9')?.name)
          .equals('Ops');
    });
  });

  group('forApi', () {
    late _Adapter adapter;
    late ApiService api;

    setUp(() {
      adapter = _Adapter();
      api = ApiService(
        serverConfig: _server,
        workerManager: WorkerManager(),
        authToken: 'session-a',
      );
      api.dio.httpClientAdapter = adapter;
    });

    tearDown(() => api.dispose());

    test('reads names from the users route with the account it was made for, '
        'with a picture from the server', () async {
      adapter.users['alice'] = {
        'id': 'alice',
        'name': 'Alice',
        'email': 'alice@example.com',
        'role': 'user',
      };
      final lookup = WorkspacePrincipalLookup.forApi(api);

      await lookup.resolve([_user('alice'), _user('ghost'), _group('g-1')]);

      final alice = lookup.cached(WorkspacePrincipalType.user, 'alice');
      check(alice?.name).equals('Alice');
      check(alice?.email).equals('alice@example.com');
      check(alice?.profileImageUrl)
          .equals('https://server.example/api/v1/users/alice/profile/image');
      check(lookup.resolutionOf(WorkspacePrincipalType.user, 'ghost'))
          .equals(WorkspacePrincipalResolution.unresolvable);
      check(lookup.cached(WorkspacePrincipalType.group, 'g-1')?.name)
          .equals('Editors');
      check([for (final r in adapter.requests) r.path]).unorderedEquals([
        '/api/v1/users/alice/info',
        '/api/v1/users/ghost/info',
        '/api/v1/groups/',
      ]);
      for (final request in adapter.requests) {
        check(request.headers['Authorization']).equals('Bearer session-a');
      }
    });

    test('a server error is not taken for a missing person', () async {
      adapter.failWith = 500;
      final lookup = WorkspacePrincipalLookup.forApi(api);

      await lookup.resolve([_user('alice')]);

      check(lookup.resolutionOf(WorkspacePrincipalType.user, 'alice'))
          .equals(WorkspacePrincipalResolution.unknown);
    });

    test('a token rotated to another account after the lookup was made is '
        'not used for its requests', () async {
      adapter.users['alice'] = {'id': 'alice', 'name': 'Alice'};
      final lookup = WorkspacePrincipalLookup.forApi(api);
      api.updateAuthToken('session-b');

      await lookup.resolve([_user('alice')]);

      check(
        adapter.requests.where(
          (r) => r.headers['Authorization'] == 'Bearer session-b',
        ),
      ).isEmpty();
      check(lookup.cached(WorkspacePrincipalType.user, 'alice')).isNull();
    });
  });
}
