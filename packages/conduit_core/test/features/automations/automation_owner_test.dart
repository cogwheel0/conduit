import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/automation_draft.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
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

typedef _Operation = Future<Object?> Function(
  Automations tasks,
  AutomationsOwner owner,
);

final _form = AutomationForm(
  name: 'n',
  data: const {'prompt': 'p', 'model_id': 'm', 'rrule': 'RRULE:FREQ=DAILY'},
  isActive: true,
);

final _operations = <String, _Operation>{
  'fetch': (tasks, owner) => tasks.fetch('a', owner: owner),
  'create': (tasks, owner) => tasks.create(_form, owner: owner),
  'update': (tasks, owner) => tasks.updateTask('a', _form, owner: owner),
  'setActive': (tasks, owner) => tasks.setActive('a', false, owner: owner),
  'run': (tasks, owner) => tasks.run('a', owner: owner),
  'remove': (tasks, owner) => tasks.remove('a', owner: owner),
  'runs': (tasks, owner) => tasks.runs('a', owner: owner),
  'channel': (tasks, owner) => tasks.channelWritable('c', owner: owner),
};

void main() {
  group('capability', () {
    // Each case is one way the account may not use scheduled tasks. The list
    // load and every operation must refuse before any request.
    final denied = <String, void Function(_Session session)>{
      'server flag off': (s) => s.config = _config(enabled: false),
      'server flag missing': (s) => s.config = _config(enabled: null),
      'config from another server': (s) =>
          s.config = _config(serverId: 'other-server'),
      'no permission document entry': (s) => s.permissions = const {},
      'permission off': (s) => s.permissions = const {
        'features': {'automations': false},
      },
    };

    for (final MapEntry(:key, :value) in denied.entries) {
      test('$key refuses the load and every operation', () async {
        final session = await _Session.start(configure: value);
        addTearDown(session.dispose);
        final tasks = session.container.read(automationsProvider.notifier);
        final owner = tasks.captureOwner()!;

        await expectLater(
          session.container.read(automationsProvider.future),
          throwsA(isA<AutomationsUnavailableException>()),
        );
        for (final MapEntry(key: name, value: run) in _operations.entries) {
          await expectLater(
            run(tasks, owner),
            throwsA(isA<AutomationsUnavailableException>()),
            reason: name,
          );
        }

        check(session.server.requests).isEmpty();
        check(session.container.read(automationsAvailableProvider)).isFalse();
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

        final data = await session.container.read(automationsProvider.future);

        check(data.items.map((t) => t.id)).deepEquals(['a']);
        check(session.container.read(automationsAvailableProvider)).isTrue();
      }
    });

    test(
      'a permission revoked after the surface opened stops the work',
      () async {
        final session = await _Session.start();
        addTearDown(session.dispose);
        await session.container.read(automationsProvider.future);
        final tasks = session.container.read(automationsProvider.notifier);
        final owner = tasks.captureOwner()!;
        session.server.requests.clear();

        session.permissions = const {
          'features': {'automations': false},
        };
        session.container.invalidate(userPermissionsProvider);

        for (final MapEntry(:key, :value) in _operations.entries) {
          await expectLater(
            value(tasks, owner),
            throwsA(isA<AutomationsUnavailableException>()),
            reason: key,
          );
        }
        check(session.server.requests).isEmpty();
      },
    );
  });

  group('owner captured when a surface opens', () {
    test('nothing reaches the server once another account signs in on the '
        'same API', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      final owner = tasks.captureOwner()!;

      session.server.tasks = [_task('b-task')];
      session.switchAccount();
      await session.container.read(automationsProvider.future);
      session.server.requests.clear();

      for (final MapEntry(:key, :value) in _operations.entries) {
        await expectLater(
          value(tasks, owner),
          throwsA(isA<AutomationsOwnerChangedException>()),
          reason: key,
        );
      }

      check(session.server.requests).isEmpty();
      check(
        session.container
            .read(automationsProvider)
            .requireValue
            .items
            .map((t) => t.id),
      ).deepEquals(['b-task']);
    });

    test(
      'an account change during the permission lookup sends nothing',
      () async {
        final session = await _Session.start();
        addTearDown(session.dispose);
        await session.container.read(automationsProvider.future);
        final tasks = session.container.read(automationsProvider.notifier);
        final owner = tasks.captureOwner()!;
        session.server.requests.clear();

        session.permissionsGate = Completer<void>();
        session.container.invalidate(userPermissionsProvider);
        final run = tasks.run('a', owner: owner);
        await pumpEventQueue();
        final gate = session.permissionsGate!;
        session.permissionsGate = null;
        session.switchAccount();
        gate.complete();

        await expectLater(
          run,
          throwsA(isA<AutomationsOwnerChangedException>()),
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
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      final owner = tasks.captureOwner()!;
      session.server.requests.clear();

      session.permissionsGate = Completer<void>();
      session.container.invalidate(userPermissionsProvider);
      final run = tasks.run('a', owner: owner);
      await pumpEventQueue();
      session.api.updateAuthToken('token-b');
      session.permissionsGate!.complete();

      await expectLater(
        run,
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
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      final owner = tasks.captureOwner()!;

      final gate = session.server.holdList = Completer<void>();
      final refreshed = tasks.refresh(owner: owner);
      await pumpEventQueue();
      session.server.holdList = null;

      session.server.tasks = [_task('b-task')];
      session.switchAccount();
      await session.container.read(automationsProvider.future);
      gate.complete();
      await refreshed;

      check(
        session.container
            .read(automationsProvider)
            .requireValue
            .items
            .map((t) => t.id),
      ).deepEquals(['b-task']);
    });
  });

  group('a read that answers after the account changed', () {
    // The server has answered for the first account. The second must not be
    // handed that answer to show.
    final reads = <String, _Operation>{
      'fetch': (tasks, owner) => tasks.fetch('a', owner: owner),
      'runs': (tasks, owner) => tasks.runs('a', owner: owner),
      'channel': (tasks, owner) => tasks.channelWritable('c', owner: owner),
    };

    for (final MapEntry(:key, :value) in reads.entries) {
      test('$key is refused', () async {
        final session = await _Session.start();
        addTearDown(session.dispose);
        await session.container.read(automationsProvider.future);
        final tasks = session.container.read(automationsProvider.notifier);
        final owner = tasks.captureOwner()!;

        final gate = session.server.holdReads = Completer<void>();
        final read = value(tasks, owner);
        final refused = expectLater(
          read,
          throwsA(isA<AutomationsOwnerChangedException>()),
        );
        await pumpEventQueue();
        session.server.holdReads = null;
        session.switchAccount();
        await session.container.read(automationsProvider.future);
        gate.complete();

        await refused;
      });
    }

    test('a write accepted for the first account still completes', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      final owner = tasks.captureOwner()!;

      final gate = session.server.holdWrites = Completer<void>();
      final run = tasks.run('a', owner: owner);
      await pumpEventQueue();
      session.server.holdWrites = null;
      session.switchAccount();
      gate.complete();

      // The request was already accepted, so the caller still hears so; the
      // surface decides it is no longer for the signed-in account.
      check((await run).id).equals('a');
      check(tasks.isCurrentOwner(owner)).isFalse();
      check(session.server.requests.where((r) => r.method == 'POST')).length
          .equals(1);
    });
  });

  group('list paging', () {
    test('loads page two when asked and appends only what is new', () async {
      final session = await _Session.start(
        configure: (s) {
          s.server.tasks = [_task('a'), _task('b')];
          s.server.pageSize = 1;
          s.server.total = 2;
        },
      );
      addTearDown(session.dispose);
      final tasks = session.container.read(automationsProvider.notifier);
      final owner = tasks.captureOwner()!;
      check((await session.container.read(automationsProvider.future)).hasMore)
          .isTrue();

      await tasks.loadMore(owner: owner);

      final data = session.container.read(automationsProvider).requireValue;
      check(data.items.map((t) => t.id)).deepEquals(['a', 'b']);
      check(data.total).equals(2);
      check(data.page).equals(2);
      check(data.hasMore).isFalse();
      check(
        session.server.requests
            .where((r) => r.uri.path.endsWith('/list'))
            .map((r) => r.uri.queryParameters['page']),
      ).deepEquals(['1', '2']);
    });

    test('a page that adds nothing stops further requests', () async {
      final session = await _Session.start(
        configure: (s) {
          s.server.tasks = [_task('a')];
          s.server.pageSize = 1;
          // The server says more exist, but its next page repeats the first.
          s.server.total = 5;
          s.server.repeatFirstPage = true;
        },
      );
      addTearDown(session.dispose);
      final tasks = session.container.read(automationsProvider.notifier);
      await session.container.read(automationsProvider.future);

      await tasks.loadMore(owner: tasks.captureOwner()!);

      final data = session.container.read(automationsProvider).requireValue;
      check(data.items).length.equals(1);
      check(data.hasMore).isFalse();
    });

    test('a change reloads every page that was showing', () async {
      final session = await _Session.start(
        configure: (s) {
          s.server.tasks = [_task('a'), _task('b')];
          s.server.pageSize = 1;
          s.server.total = 2;
        },
      );
      addTearDown(session.dispose);
      final tasks = session.container.read(automationsProvider.notifier);
      final owner = tasks.captureOwner()!;
      await session.container.read(automationsProvider.future);
      await tasks.loadMore(owner: owner);
      session.server.requests.clear();

      await tasks.run('a', owner: owner);

      check(
        session.container
            .read(automationsProvider)
            .requireValue
            .items
            .map((t) => t.id),
      ).deepEquals(['a', 'b']);
      check(
        session.server.requests
            .where((r) => r.uri.path.endsWith('/list'))
            .map((r) => r.uri.queryParameters['page']),
      ).deepEquals(['1', '2']);
    });

    test('a new search or status starts again from page one', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      session.server.requests.clear();

      await tasks.refresh(
        owner: tasks.captureOwner()!,
        query: ' digest ',
        status: AutomationStatusFilter.paused,
      );

      final request = session.server.requests.single;
      check(request.uri.queryParameters)
          .deepEquals({'query': 'digest', 'status': 'paused', 'page': '1'});
      final data = session.container.read(automationsProvider).requireValue;
      check(data.query).equals('digest');
      check(data.status).equals(AutomationStatusFilter.paused);
    });

    test('a write that lands but cannot be read back keeps the list and '
        'marks it stale', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      session.server.listStatus = 500;

      await tasks.run('a', owner: tasks.captureOwner()!);

      final data = session.container.read(automationsProvider).requireValue;
      check(data.stale).isTrue();
      check(data.items.map((t) => t.id)).deepEquals(['a']);
    });
  });

  group('controls', () {
    // The server's toggle flips whatever it holds. A switch that was showing
    // old state must not flip a task back that another client already changed.
    test('turning on a task that is already on sends no toggle', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      session.server.requests.clear();

      final result = await tasks.setActive(
        'a',
        true,
        owner: tasks.captureOwner()!,
      );

      check(result.isActive).isTrue();
      check(session.server.requests.where((r) => r.method == 'POST')).isEmpty();
    });

    test('pausing an active task is one toggle on the server', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      session.server.requests.clear();

      final result = await tasks.setActive(
        'a',
        false,
        owner: tasks.captureOwner()!,
      );

      check(result.isActive).isFalse();
      check(
        session.server.requests
            .where((r) => r.method == 'POST')
            .map((r) => r.uri.path),
      ).deepEquals(['/api/v1/automations/a/toggle']);
      check(
        session.container
            .read(automationsProvider)
            .requireValue
            .items
            .single
            .isActive,
      ).isFalse();
    });

    test('a run request is one POST and leaves history alone', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      session.server.requests.clear();

      final accepted = await tasks.run('a', owner: tasks.captureOwner()!);

      check(accepted.id).equals('a');
      check(
        session.server.requests
            .where((r) => r.method == 'POST')
            .map((r) => r.uri.path),
      ).deepEquals(['/api/v1/automations/a/run']);
      check(session.server.requests.where((r) => r.uri.path.endsWith('/runs')))
          .isEmpty();
    });

    test('history pages are fetched by offset, apart from the task', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      session.server.requests.clear();

      final runs = await tasks.runs(
        'a',
        skip: 50,
        owner: tasks.captureOwner()!,
      );

      check(runs.single.id).equals('r1');
      final request = session.server.requests.single;
      check(request.uri.path).equals('/api/v1/automations/a/runs');
      check(request.uri.queryParameters)
          .deepEquals({'skip': '50', 'limit': '50'});
    });
  });

  group('editing keeps what the server holds', () {
    // The server overwrites data and meta from every update form, and filters
    // keys its model does not know. Everything the client was given must go
    // back, and a schedule the user did not touch must go back as stored.
    test('an edit of the prompt sends the whole task back', () async {
      final session = await _Session.start(
        configure: (s) => s.server.tasks = [_task('a', rrule: _storedWeekly)],
      );
      addTearDown(session.dispose);
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      final owner = tasks.captureOwner()!;
      final task = await tasks.fetch('a', owner: owner);
      session.server.requests.clear();

      final draft = AutomationDraft.edit(task)
          .copyWith(prompt: '  A new prompt  ');
      await tasks.updateTask('a', draft.toForm(), owner: owner);

      final request = session.server.requests.firstWhere(
        (r) => r.uri.path.endsWith('/update'),
      );
      check(request.data).isA<Map<String, dynamic>>().deepEquals({
        'name': 'Digest',
        'folder_id': 'folder-1',
        'data': {
          'prompt': 'A new prompt',
          'model_id': 'gpt-4o',
          // Stored in tap order; an unrelated edit does not reorder it.
          'rrule': _storedWeekly,
          'terminal': {'server_id': 'term-1', 'cwd': '/work'},
          'target': {'type': 'chat'},
          'future_field': {'kept': true},
        },
        'meta': {'system_prompt': 'Be brief'},
        'is_active': true,
      });
    });

    test('changing the schedule writes the control rule', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      final owner = tasks.captureOwner()!;
      final task = await tasks.fetch('a', owner: owner);
      session.server.requests.clear();

      await tasks.updateTask(
        'a',
        AutomationDraft.edit(task)
            .copyWith(
              schedule: const DailyAutomationSchedule(hour: 7, minute: 15),
            )
            .toForm(),
        owner: owner,
      );

      final data =
          (session.server.requests
                      .firstWhere((r) => r.uri.path.endsWith('/update'))
                      .data
                  as Map<String, dynamic>)['data']
              as Map<String, dynamic>;
      check(data['rrule']).equals('RRULE:FREQ=DAILY;BYHOUR=7;BYMINUTE=15');
    });

    test('a refused save explains itself in the server\'s words', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(automationsProvider.future);
      final tasks = session.container.read(automationsProvider.notifier);
      session.server.writeRejection = (
        status: 400,
        detail: 'Schedule too frequent. Minimum interval is 3600 seconds.',
      );

      Object? caught;
      try {
        await tasks.create(_form, owner: tasks.captureOwner()!);
      } catch (error) {
        caught = error;
      }

      check(caught).isNotNull();
      check(automationErrorDetail(caught!))
          .equals('Schedule too frequent. Minimum interval is 3600 seconds.');
    });
  });
}

const _storedWeekly = 'RRULE:FREQ=WEEKLY;BYDAY=WE,MO;BYHOUR=9;BYMINUTE=0';

BackendConfig _config({
  bool? enabled = true,
  String? serverId = 'test-server',
}) => BackendConfig(serverId: serverId, enableAutomations: enabled);

User _user({String role = 'user'}) =>
    User(id: 'user-1', username: 'user', email: 'user@example.com', role: role);

Map<String, dynamic> _task(
  String id, {
  bool active = true,
  String rrule = 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',
}) => {
  'id': id,
  'user_id': 'user-1',
  'folder_id': 'folder-1',
  'name': 'Digest',
  'data': {
    'prompt': 'Summarize the news',
    'model_id': 'gpt-4o',
    'rrule': rrule,
    'terminal': {'server_id': 'term-1', 'cwd': '/work'},
    'target': {'type': 'chat'},
    'future_field': {'kept': true},
  },
  'meta': {'system_prompt': 'Be brief'},
  'is_active': active,
  'last_run_at': null,
  'next_run_at': 1791320967000000001,
  'created_at': 1790000000123456789,
  'updated_at': 1790000001987654321,
  'last_run': null,
  'next_runs': [1791320967000000001],
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
          return permissions;
        }),
      ],
    );
  }

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
    'features': {'automations': true},
  };
  Completer<void>? permissionsGate;

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

/// A server that holds tasks in memory. Toggle flips the stored flag, as the
/// pinned route does, and every request is recorded.
final class _Server implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  List<Map<String, dynamic>> tasks = [_task('a')];
  Completer<void>? holdList;

  /// Holds the answer to single-task, history and channel reads.
  Completer<void>? holdReads;

  /// Holds the answer to a write after the server has acted on it.
  Completer<void>? holdWrites;
  int listStatus = 200;
  int pageSize = 30;
  int? total;
  bool repeatFirstPage = false;
  ({int status, String detail})? writeRejection;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    final rejection = writeRejection;
    if (options.method != 'GET' && rejection != null) {
      return _json({'detail': rejection.detail}, rejection.status);
    }
    if (path.endsWith('/list')) {
      await holdList?.future;
      if (listStatus != 200) {
        return _json({'detail': 'unavailable'}, listStatus);
      }
      final page = int.parse(options.uri.queryParameters['page'] ?? '1');
      final from = repeatFirstPage ? 0 : (page - 1) * pageSize;
      final items = tasks.skip(from).take(pageSize).toList();
      return _json({'items': items, 'total': total ?? tasks.length});
    }
    if (path.endsWith('/runs')) {
      await holdReads?.future;
      return _json([
        {
          'id': 'r1',
          'automation_id': 'a',
          'chat_id': 'chat-1',
          'status': 'success',
          'error': null,
          'created_at': 1791320967000000001,
        },
      ]);
    }
    if (path.endsWith('/delete')) return _json(true);
    if (path.contains('/channels/')) {
      await holdReads?.future;
      return _json({'id': 'c', 'write_access': true});
    }
    final task = tasks.firstWhere(
      (t) => path.contains('/automations/${t['id']}'),
      orElse: () => tasks.first,
    );
    if (path.endsWith('/toggle')) {
      task['is_active'] = !(task['is_active'] as bool);
    }
    await (options.method == 'GET' ? holdReads : holdWrites)?.future;
    return _json(task);
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
