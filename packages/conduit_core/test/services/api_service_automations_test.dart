import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

// Written the way the pinned server serializes it: nanosecond epochs are plain
// JSON integers, larger than a double holds exactly.
const _automationJson = '''
{
  "id": "auto-1",
  "user_id": "user-1",
  "folder_id": "folder-1",
  "name": "Morning digest",
  "data": {
    "prompt": "Summarize the news",
    "model_id": "gpt-4o",
    "rrule": "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
    "terminal": {"server_id": "term-1", "cwd": "/work"},
    "target": {"type": "channel", "channel_id": "chan-1"},
    "future_field": {"kept": true}
  },
  "meta": {"system_prompt": "Be brief", "temperature": 0.2},
  "is_active": true,
  "last_run_at": 1791234567891234567,
  "next_run_at": 1791320967000000001,
  "created_at": 1790000000123456789,
  "updated_at": 1790000001987654321,
  "last_run": {
    "id": "run-9",
    "automation_id": "auto-1",
    "chat_id": "chat-9",
    "status": "success",
    "error": null,
    "created_at": 1791234567891234567
  },
  "next_runs": [1791320967000000001, 1791407367000000003]
}
''';

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

  group('list', () {
    test(
      'sends the search, status, page and folder as query parameters',
      () async {
        adapter.reply('{"items": [], "total": 0}');

        await api.getAutomations(
          query: ' digest ',
          status: 'active',
          folderId: 'folder-1',
          page: 2,
          authSnapshot: api.captureAuthSnapshot(),
        );

        final request = adapter.requests.single;
        check(request.method).equals('GET');
        check(request.path).equals('/api/v1/automations/list');
        check(request.headers['Authorization']).equals('Bearer session-a');
        check(request.queryParameters).deepEquals({
          'query': 'digest',
          'status': 'active',
          'page': 2,
          'folder_id': 'folder-1',
        });
      },
    );

    test('leaves out an empty search and the all-status filter', () async {
      adapter.reply('{"items": [], "total": 0}');

      await api.getAutomations(
        query: '  ',
        status: 'all',
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(adapter.requests.single.queryParameters).deepEquals({'page': 1});
    });

    test('reads items and the total across pages', () async {
      adapter.reply('{"items": [$_automationJson], "total": 61}');

      final page = await api.getAutomations(
        page: 3,
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(page.total).equals(61);
      check(page.items.single.id).equals('auto-1');
      check(adapter.requests.single.queryParameters['page']).equals(3);
    });

    // The list route does not compute next runs (they are null), so the next
    // run comes from the stored next_run_at, and only for an active task.
    test('a list item without next runs falls back to next_run_at', () async {
      const item =
          '{"id": "a", "user_id": "u", "name": "n", "data": {"prompt": "p", '
          '"model_id": "m", "rrule": "RRULE:FREQ=DAILY"}, "next_run_at": ';
      adapter.reply(
        '{"items": [${item}1791320967000000001, "is_active": true}, '
        '${item}1791320967000000001, "is_active": false}], "total": 2}',
      );

      final page = await api.getAutomations(
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(page.items[0].nextRunsNs).isNull();
      check(page.items[0].nextRunNs).equals(1791320967000000001);
      check(page.items[1].nextRunNs).isNull();
    });

    test('keeps nanosecond timestamps exactly', () async {
      adapter.reply(_automationJson);

      final automation = await api.getAutomation(
        'auto-1',
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(automation.lastRunAtNs).equals(1791234567891234567);
      check(automation.nextRunAtNs).equals(1791320967000000001);
      check(automation.createdAtNs).equals(1790000000123456789);
      check(automation.updatedAtNs).equals(1790000001987654321);
      check(automation.nextRunsNs)
          .isNotNull()
          .deepEquals([1791320967000000001, 1791407367000000003]);
      check(automation.lastRun!.createdAtNs).equals(1791234567891234567);
      check(
        dateTimeFromEpochNanoseconds(automation.lastRunAtNs)!
            .microsecondsSinceEpoch,
      ).equals(1791234567891234);
    });

    test('keeps data and meta whole, unknown keys included', () async {
      adapter.reply(_automationJson);

      final automation = await api.getAutomation(
        'auto-1',
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(automation.prompt).equals('Summarize the news');
      check(automation.modelId).equals('gpt-4o');
      check(automation.target.isChannel).isTrue();
      check(automation.target.channelId).equals('chan-1');
      check(automation.terminal)
          .isNotNull()
          .deepEquals({'server_id': 'term-1', 'cwd': '/work'});
      check(automation.data['future_field'])
          .isA<Map<String, dynamic>>()
          .deepEquals({'kept': true});
      check(automation.meta)
          .isNotNull()
          .deepEquals({'system_prompt': 'Be brief', 'temperature': 0.2});
    });

    test('a task without next runs or last run reads as never run', () async {
      adapter.reply('''
{"id": "a", "user_id": "u", "name": "n",
 "data": {"prompt": "p", "model_id": "m", "rrule": "RRULE:FREQ=DAILY"},
 "is_active": false, "last_run": null, "next_run_at": null}
''');

      final automation = await api.getAutomation(
        'a',
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(automation.lastRun).isNull();
      check(automation.nextRunsNs).isNull();
      check(automation.nextRunNs).isNull();
      check(automation.target.isChannel).isFalse();
    });
  });

  group('writes', () {
    // The server overwrites name, folder, data and meta from every form, so
    // anything this client does not send is erased.
    test(
      'create and update send the whole form, unknown keys included',
      () async {
        final form = AutomationForm(
          name: 'Morning digest',
          folderId: null,
          data: const {
            'prompt': 'Summarize the news',
            'model_id': 'gpt-4o',
            'rrule': 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',
            'terminal': {'server_id': 'term-1', 'cwd': '/work'},
            'target': {'type': 'chat'},
            'future_field': {'kept': true},
          },
          meta: const {'system_prompt': 'Be brief'},
          isActive: false,
        );
        adapter.reply(_automationJson);

        await api.createAutomation(
          form,
          authSnapshot: api.captureAuthSnapshot(),
        );
        await api.updateAutomation(
          'a/b c',
          form,
          authSnapshot: api.captureAuthSnapshot(),
        );

        final expected = {
          'name': 'Morning digest',
          'folder_id': null,
          'data': form.data,
          'meta': {'system_prompt': 'Be brief'},
          'is_active': false,
        };
        final [create, update] = adapter.requests;
        check(create.method).equals('POST');
        check(create.path).equals('/api/v1/automations/create');
        check(create.data).isA<Map<String, dynamic>>().deepEquals(expected);
        check(update.method).equals('POST');
        check(update.path).equals('/api/v1/automations/a%2Fb%20c/update');
        check(update.data).isA<Map<String, dynamic>>().deepEquals(expected);
      },
    );

    test('a form with no meta sends none', () async {
      adapter.reply(_automationJson);

      await api.createAutomation(
        const AutomationForm(
          name: 'n',
          data: {'prompt': 'p', 'model_id': 'm', 'rrule': 'RRULE:FREQ=DAILY'},
          isActive: true,
        ),
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(adapter.requests.single.data)
          .isA<Map<String, dynamic>>()
          .not((body) => body.containsKey('meta'));
    });

    test('toggle, run and delete are bodiless calls on the task', () async {
      final snapshot = api.captureAuthSnapshot();
      adapter.reply(_automationJson);
      await api.toggleAutomation('auto-1', authSnapshot: snapshot);
      await api.runAutomation('auto-1', authSnapshot: snapshot);
      adapter.reply('true');
      await api.deleteAutomation('auto-1', authSnapshot: snapshot);

      final [toggle, run, delete] = adapter.requests;
      check(toggle.method).equals('POST');
      check(toggle.path).equals('/api/v1/automations/auto-1/toggle');
      check(run.method).equals('POST');
      check(run.path).equals('/api/v1/automations/auto-1/run');
      check(delete.method).equals('DELETE');
      check(delete.path).equals('/api/v1/automations/auto-1/delete');
      for (final request in adapter.requests) {
        check(request.data).isNull();
      }
    });

    test('a run request answers with the task, not a run record', () async {
      // The pinned server starts the run in the background and returns the
      // enriched definition. Its last run is whatever happened before.
      adapter.reply(_automationJson);

      final accepted = await api.runAutomation(
        'auto-1',
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(accepted.id).equals('auto-1');
      check(accepted.lastRun!.id).equals('run-9');
    });

    test('a delete the server does not confirm is an error', () async {
      adapter.reply('false');

      await expectLater(
        api.deleteAutomation('auto-1', authSnapshot: api.captureAuthSnapshot()),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('history', () {
    test('pages by offset and reads each run on its own', () async {
      adapter.reply('''
[
  {"id": "r2", "automation_id": "auto-1", "chat_id": "channel:chan-1",
   "status": "success", "error": null, "created_at": 1791407367000000003},
  {"id": "r1", "automation_id": "auto-1", "chat_id": null,
   "status": "error", "error": "Model not found", "created_at": 1791320967000000001}
]
''');

      final runs = await api.getAutomationRuns(
        'auto-1',
        skip: 50,
        authSnapshot: api.captureAuthSnapshot(),
      );

      final request = adapter.requests.single;
      check(request.method).equals('GET');
      check(request.path).equals('/api/v1/automations/auto-1/runs');
      check(request.queryParameters).deepEquals({'skip': 50, 'limit': 50});
      check(runs).length.equals(2);
      check(runs[0].succeeded).isTrue();
      check(runs[0].resultChannelId).equals('chan-1');
      check(runs[0].resultChatId).isNull();
      check(runs[0].createdAtNs).equals(1791407367000000003);
      check(runs[1].succeeded).isFalse();
      check(runs[1].error).equals('Model not found');
      check(runs[1].chatId).isNull();
    });

    test('a chat result links the chat, not a channel', () async {
      adapter.reply(
        '[{"id": "r", "automation_id": "a", "chat_id": "chat-9", '
        '"status": "success", "error": null, "created_at": 1}]',
      );

      final runs = await api.getAutomationRuns(
        'a',
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(runs.single.resultChatId).equals('chat-9');
      check(runs.single.resultChannelId).isNull();
    });
  });

  group('channel write access', () {
    test('is read from the channel itself', () async {
      final snapshot = api.captureAuthSnapshot();
      adapter.reply('{"id": "chan-1", "write_access": true}');
      check(
        await api.getAutomationChannelWriteAccess(
          'chan-1',
          authSnapshot: snapshot,
        ),
      ).isTrue();
      adapter.reply('{"id": "chan-2", "write_access": false}');
      check(
        await api.getAutomationChannelWriteAccess(
          'chan-2',
          authSnapshot: snapshot,
        ),
      ).isFalse();

      check(adapter.requests.map((r) => r.path))
          .deepEquals(['/api/v1/channels/chan-1', '/api/v1/channels/chan-2']);
    });
  });

  group('refusals', () {
    // These are the pinned server's own words (constants.py and
    // routers/automations.py), not text invented for the test.
    test('surface the server detail for each documented refusal', () async {
      final cases = <String, ({int status, String detail})>{
        'rule with nothing left to run': (
          status: 400,
          detail: 'RRULE has no future occurrences',
        ),
        'schedule under the minimum interval': (
          status: 400,
          detail: 'Schedule too frequent. Minimum interval is 3600 seconds.',
        ),
        'task limit': (status: 403, detail: 'Automation limit reached (5)'),
        'not the owner': (
          status: 404,
          detail: "We could not find what you're looking for :/",
        ),
        'feature off or no permission': (
          status: 403,
          detail: '401 Unauthorized',
        ),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        adapter.reply(
          jsonEncode({'detail': value.detail}),
          status: value.status,
        );

        Object? failure;
        try {
          await api.getAutomation(
            'auto-1',
            authSnapshot: api.captureAuthSnapshot(),
          );
        } catch (error) {
          failure = error;
        }

        check(failure, because: key).isA<DioException>();
        check(
          automationErrorDetail(failure!),
          because: key,
        ).equals(value.detail);
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
        const form = AutomationForm(
          name: 'n',
          data: {'prompt': 'p', 'model_id': 'm', 'rrule': 'RRULE:FREQ=DAILY'},
          isActive: true,
        );

        final operations = <String, Future<Object?> Function()>{
          'list': () => api.getAutomations(authSnapshot: accountA),
          'get': () => api.getAutomation('a', authSnapshot: accountA),
          'create': () => api.createAutomation(form, authSnapshot: accountA),
          'update': () =>
              api.updateAutomation('a', form, authSnapshot: accountA),
          'toggle': () => api.toggleAutomation('a', authSnapshot: accountA),
          'run': () => api.runAutomation('a', authSnapshot: accountA),
          'delete': () => api.deleteAutomation('a', authSnapshot: accountA),
          'runs': () => api.getAutomationRuns('a', authSnapshot: accountA),
          'channel': () =>
              api.getAutomationChannelWriteAccess('c', authSnapshot: accountA),
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
  });
}

/// Records every request that reaches the wire and answers with the last text
/// passed to [reply], verbatim.
final class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  String _body = '{}';
  int _status = 200;

  void reply(String body, {int status = 200}) {
    _body = body;
    _status = status;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      _body,
      _status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
