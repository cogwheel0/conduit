import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/settings/pages/scheduled_task_settings_pages.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import '../automations/automation_harness.dart';

final _l10n = automationL10n;

const _list = scheduledTasksPageId;
final _pageA = scheduledTaskPageId('a');
final _newEditor = scheduledTaskEditorPageId(null);
final _editA = scheduledTaskEditorPageId('a');

String _listRow(String field) =>
    scheduledTaskRowId(field, scheduledTasksListKey);
String _row(String field, [String? extra]) =>
    scheduledTaskRowId(field, 'a', extra);
String _newRow(String field, [String? extra]) =>
    scheduledTaskRowId(field, scheduledTaskNewKey, extra);

Map<String, dynamic> _body(AutomationWire wire, String suffix) =>
    wire.where('POST', suffix).single.data as Map<String, dynamic>;

Map<String, dynamic> _data(AutomationWire wire, String suffix) =>
    _body(wire, suffix)['data'] as Map<String, dynamic>;

RequestOptions _lastList(AutomationWire wire) =>
    wire.where('GET', '/list').last;

/// A new task's editor with a name, instructions and a model, ready to save.
Future<void> _fillNew(AutomationSession session) async {
  await session.change(_newRow('name'), 'Morning digest');
  await session.change(_newRow('prompt'), 'Summarize the news');
  await session.change(_newRow('model'), 'claude');
}

void main() {
  group('the list', () {
    testWidgets('Advanced off explains itself and sends nothing', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        settings: const AppSettings(),
      );
      session.wire.requests.clear();

      await session.open(_list);

      expect(
        session.titles(_list).single,
        _l10n.advancedRequiredMessage(_l10n.scheduledTasksTitle),
      );
      expect(session.wire.requests, isEmpty);
    });

    testWidgets('a server without scheduled tasks says so', (tester) async {
      final session = await pumpAutomations(tester, serverEnabled: false);

      await session.open(_list);

      expect(session.titles(_list).single, _l10n.scheduledTasksUnavailable);
    });

    testWidgets('shows what the server holds with its status and schedule', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson('a'),
          taskJson('b', name: 'Weekly review', active: false),
        ],
      );

      await session.open(_list);

      final a = session.row(_list, scheduledTaskPageId('a'))!;
      expect(a.title, 'Digest');
      expect(a.subtitle, contains('9:00'));
      final b = session.row(_list, scheduledTaskPageId('b'))!;
      expect(b.subtitle, contains(_l10n.scheduledTaskStatusPaused));
      // Each opens its own page, and a row adds one.
      expect(session.row(_list, _newEditor)!.title, _l10n.scheduledTasksAdd);
    });

    testWidgets('an empty account is invited to add a task', (tester) async {
      final session = await pumpAutomations(tester, tasks: []);

      await session.open(_list);

      final add = session.row(_list, _newEditor)!;
      expect(add.title, _l10n.scheduledTasksEmpty);
      expect(add.subtitle, _l10n.scheduledTasksEmptyHint);
    });

    testWidgets('the search above the list asks the server as it is typed, '
        'and an empty one shows every task', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson('a'),
          taskJson('b', name: 'Weekly review'),
        ],
      );
      await session.open(_list);
      final search = session.page(_list).search!;
      expect(search.id, _listRow('search'));
      expect(search.placeholder, _l10n.scheduledTasksSearchHint);
      expect(search.value, '');

      await session.change(search.id, 'weekly');
      await session.idle();
      expect(_lastList(session.wire).uri.queryParameters['query'], 'weekly');
      expect(session.row(_list, _pageA), isNull);
      expect(session.page(_list).search!.value, 'weekly');

      await session.change(search.id, '');
      await session.idle();
      expect(_lastList(session.wire).uri.queryParameters['query'], isNull);
      expect(session.row(_list, _pageA), isNotNull);
    });

    testWidgets("an earlier search's late answer is not shown for the one "
        'typed since', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson('a', name: 'Weekend digest'),
          taskJson('b', name: 'Weekly review'),
        ],
      );
      await session.open(_list);
      final hold = session.wire.hold('GET', '/api/v1/automations/list');

      await session.change(_listRow('search'), 'week');
      await reach(tester, hold);
      // Typed on while the first answer is still on its way.
      await session.change(_listRow('search'), 'weekly');
      await session.idle();
      hold.release();
      await session.idle();

      expect(session.row(_list, scheduledTaskPageId('b')), isNotNull);
      expect(session.row(_list, _pageA), isNull);
      expect(session.page(_list).search!.value, 'weekly');
    });

    testWidgets('a search that matches nothing offers the whole list', (
      tester,
    ) async {
      final session = await pumpAutomations(tester);
      await session.open(_list);

      await session.change(_listRow('search'), 'nothing like it');
      await session.idle();
      expect(
        session.titles(_list),
        contains(_l10n.scheduledTasksEmptyFiltered),
      );

      await session.change(_listRow('show-all'));
      expect(session.row(_list, _pageA), isNotNull);
    });

    testWidgets("a status filter is the server's", (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a'), taskJson('b', active: false)],
      );
      await session.open(_list);

      await session.change(_listRow('filter'), 'paused');

      expect(_lastList(session.wire).uri.queryParameters['status'], 'paused');
      expect(session.row(_list, _pageA), isNull);
      expect(session.row(_list, scheduledTaskPageId('b')), isNotNull);
    });

    testWidgets('a chosen filter shows at once, with progress until the '
        'server answers', (tester) async {
      final session = await pumpAutomations(tester);
      await session.open(_list);
      final hold = session.wire.hold('GET', '/api/v1/automations/list');

      final change = session.module.handleChange(
        _listRow('filter'),
        'paused',
        _l10n,
      );
      await reach(tester, hold);

      expect(session.row(_list, _listRow('filter'))!.value, 'paused');
      expect(session.row(_list, _pageA), isNull);
      hold.release();
      await session.settle(change);
    });

    testWidgets('Load More asks for the next page and adds it', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a'), taskJson('b')],
        configureWire: (wire) => wire.pageSize = 1,
      );
      await session.open(_list);
      expect(session.row(_list, scheduledTaskPageId('b')), isNull);

      await session.change(_listRow('more'));

      expect(_lastList(session.wire).uri.queryParameters['page'], '2');
      expect(session.row(_list, _pageA), isNotNull);
      expect(session.row(_list, scheduledTaskPageId('b')), isNotNull);
    });

    testWidgets('a rule the controls cannot describe is named, not printed', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a', rrule: 'RRULE:FREQ=MONTHLY;BYMONTHDAY=1')],
      );

      await session.open(_list);

      final row = session.row(_list, _pageA)!;
      expect(row.subtitle, contains(_l10n.scheduledTaskScheduleCustom));
      expect(row.subtitle, isNot(contains('MONTHLY')));
    });

    testWidgets("a row's menu pauses a task, or deletes it once asked", (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a'), taskJson('b')],
      );
      await session.open(_list);
      final actions = session.row(_list, _pageA)!.rowActions;
      final pause = actions.singleWhere((a) => a.id == _row('active', 'off'));
      final delete = actions.singleWhere((a) => a.id == _row('delete'));
      expect(pause.label, _l10n.hermesJobPause);
      expect(delete.destructive, isTrue);
      expect(delete.confirmMessage, _l10n.scheduledTaskDeleteConfirm('Digest'));

      await session.change(pause.id);
      expect(session.wire.where('POST', '/a/toggle'), hasLength(1));
      expect(
        session.row(_list, _pageA)!.subtitle,
        contains(_l10n.scheduledTaskStatusPaused),
      );

      await session.change(delete.id);
      expect(session.wire.where('DELETE', '/a/delete'), hasLength(1));
      expect(session.row(_list, _pageA), isNull);
    });
  });

  group("a task's page", () {
    testWidgets("shows the definition and the server's next runs", (
      tester,
    ) async {
      final session = await pumpAutomations(tester);

      await session.open(_pageA);

      final page = session.page(_pageA);
      expect(page.title, 'Digest');
      expect(
        session.row(_pageA, '$_pageA-schedule')!.subtitle,
        contains('9:00'),
      );
      expect(session.row(_pageA, '$_pageA-model')!.subtitle, 'GPT-4o');
      expect(
        session.row(_pageA, '$_pageA-next-run-1791320967000000001'),
        isNotNull,
      );
      expect(
        session.row(_pageA, '$_pageA-prompt')!.value,
        'Summarize the news',
      );
      // The editor is a row of its own.
      expect(session.row(_pageA, _editA)!.title, _l10n.edit);
    });

    testWidgets('a paused task is promised no next run', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a', active: false)],
      );

      await session.open(_pageA);

      expect(
        session.row(_pageA, '$_pageA-no-next-runs')!.title,
        _l10n.scheduledTaskStatusPaused,
      );
    });

    testWidgets('a task that is gone says so', (tester) async {
      final session = await pumpAutomations(tester);
      final gone = scheduledTaskPageId('gone');

      await session.open(gone);

      expect(session.titles(gone).first, _l10n.scheduledTasksNotFound);
    });

    testWidgets('keeps a terminal attached without editing it', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson('a', terminal: {'server_id': 't1', 'cwd': '/work'}),
        ],
      );

      await session.open(_pageA);

      expect(
        session.page(_pageA).sections.map((s) => s.footer),
        contains(_l10n.scheduledTaskTerminalKept),
      );
    });

    testWidgets('a task read again that fails says so, not its last copy', (
      tester,
    ) async {
      final session = await pumpAutomations(tester);
      await session.open(_pageA);
      expect(session.row(_pageA, _row('active')), isNotNull);

      // Deleted elsewhere; the page is shown again and reads it.
      session.wire.tasks.removeWhere((task) => task['id'] == 'a');
      await session.open(_pageA);

      expect(session.row(_pageA, '$_pageA-load-error'), isNotNull);
      expect(session.row(_pageA, _row('active')), isNull);
    });

    testWidgets("a task moved to another terminal leaves the last one's "
        'folder behind', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson('a', terminal: {'server_id': 't1', 'cwd': '/work'}),
        ],
      );
      session.wire.terminals.addAll([
        {'id': 't1', 'name': 'Studio'},
        {'id': 't2', 'name': 'Lab'},
      ]);
      await session.open(_editA);

      await session.change(_row('terminal'), 't2');
      await session.change(_row('save'));

      final terminal = _data(session.wire, '/a/update')['terminal'];
      expect(terminal, isA<Map<String, dynamic>>());
      expect((terminal as Map)['server_id'], 't2');
      expect(terminal['cwd'], isNot('/work'));
    });

    testWidgets("pausing is one toggle, and the switch shows the server's "
        'state', (tester) async {
      final session = await pumpAutomations(tester);
      await session.open(_pageA);

      await session.change(_row('active'), false);

      expect(session.wire.where('POST', '/a/toggle'), hasLength(1));
      expect(session.row(_pageA, _row('active'))!.value, isFalse);
    });

    testWidgets('the switch moves at once and waits for the server', (
      tester,
    ) async {
      final session = await pumpAutomations(tester);
      await session.open(_pageA);
      final hold = session.wire.hold('POST', '/api/v1/automations/a/toggle');

      final change = session.module.handleChange(_row('active'), false, _l10n);
      await reach(tester, hold);

      final toggle = session.row(_pageA, _row('active'))!;
      expect(toggle.value, isFalse);
      expect(toggle.disabled, isTrue);
      // Run Now waits for it.
      expect(session.row(_pageA, _row('run'))!.disabled, isTrue);
      hold.release();
      await session.settle(change);
      expect(session.row(_pageA, _row('active'))!.disabled, isFalse);
    });

    testWidgets('a refused change explains itself and changes nothing', (
      tester,
    ) async {
      final session = await pumpAutomations(tester);
      await session.open(_pageA);
      session.wire.rejectWrites = (status: 400, detail: 'Not now');

      await session.change(_row('active'), false);

      expect(session.row(_pageA, '$_pageA-error')!.title, 'Not now');
      expect(session.row(_pageA, _row('active'))!.value, isTrue);
    });

    group('Run Now', () {
      testWidgets('is one request, then waits for the run to show in '
          'history', (tester) async {
        final session = await pumpAutomations(tester);
        await session.open(_pageA);

        await session.change(_row('run'));

        expect(session.wire.runRequests, hasLength(1));
        expect(
          session.row(_pageA, '$_pageA-run-notice')!.title,
          _l10n.scheduledTaskRunning,
        );
        session.wire.runs['a'] = [runJson('r1', chatId: 'chat-1')];
        await tester.pump(scheduledTaskRunPollInterval);
        await session.settle(Future<void>.value());

        expect(
          session.row(_pageA, '$_pageA-run-notice')!.title,
          _l10n.scheduledTaskRunFinished,
        );
        expect(session.row(_pageA, _row('open-run', 'r1')), isNotNull);
      });

      testWidgets('a run already in history is not taken for the new one', (
        tester,
      ) async {
        final session = await pumpAutomations(
          tester,
          configureWire: (wire) => wire.runs['a'] = [runJson('old')],
        );
        await session.open(_pageA);

        await session.change(_row('run'));
        await tester.pump(scheduledTaskRunPollInterval);
        await session.settle(Future<void>.value());

        expect(
          session.row(_pageA, '$_pageA-run-notice')!.title,
          _l10n.scheduledTaskRunning,
        );
        session.module.pageLeft(_pageA);
      });

      testWidgets('stops watching after about two minutes and says the run '
          'was asked for', (tester) async {
        final session = await pumpAutomations(tester);
        await session.open(_pageA);

        await session.change(_row('run'));
        for (var i = 0; i < scheduledTaskRunPollLimit; i++) {
          await tester.pump(scheduledTaskRunPollInterval);
          await session.settle(Future<void>.value());
        }

        expect(
          session.row(_pageA, '$_pageA-run-notice')!.title,
          _l10n.scheduledTaskRunRequested,
        );
        final reads = session.wire.where('GET', '/a/runs').length;
        await tester.pump(scheduledTaskRunPollInterval * 3);
        expect(session.wire.where('GET', '/a/runs'), hasLength(reads));
      });

      testWidgets('stops watching when the page closes', (tester) async {
        final session = await pumpAutomations(tester);
        await session.open(_pageA);
        await session.change(_row('run'));

        await session.leave(_pageA);
        final reads = session.wire.where('GET', '/a/runs').length;
        await tester.pump(scheduledTaskRunPollInterval * 3);

        expect(session.wire.where('GET', '/a/runs'), hasLength(reads));
      });

      testWidgets('stops watching when the account changes', (tester) async {
        final session = await pumpAutomations(tester);
        await session.open(_pageA);
        await session.change(_row('run'));

        session.switchAccount();
        await tester.pump(scheduledTaskRunPollInterval);
        await session.settle(Future<void>.value());

        expect(
          session.row(_pageA, '$_pageA-error')!.title,
          _l10n.scheduledTasksAccountChanged,
        );
        expect(session.row(_pageA, '$_pageA-run-notice'), isNull);
      });

      testWidgets("a refused run shows the server's reason", (tester) async {
        final session = await pumpAutomations(tester);
        await session.open(_pageA);
        session.wire.rejectWrites = (status: 409, detail: 'Already running');

        await session.change(_row('run'));

        expect(session.row(_pageA, '$_pageA-error')!.title, 'Already running');
        expect(session.row(_pageA, _row('run'))!.disabled, isFalse);
      });
    });

    testWidgets('history lists each run and pages by offset until a short '
        'page', (tester) async {
      final session = await pumpAutomations(
        tester,
        configureWire: (wire) => wire.runs['a'] = [
          for (var i = 0; i < 51; i++)
            runJson('r$i', status: i.isEven ? 'success' : 'error'),
        ],
      );
      await session.open(_pageA);
      expect(session.row(_pageA, _row('open-run', 'r0')), isNotNull);
      expect(session.row(_pageA, _row('open-run', 'r50')), isNull);

      await session.change(_row('runs-more'));

      expect(
        session.wire.where('GET', '/a/runs').last.uri.queryParameters['skip'],
        '50',
      );
      expect(session.row(_pageA, _row('open-run', 'r50')), isNotNull);
      expect(session.row(_pageA, _row('runs-more')), isNull);
    });

    testWidgets("a task's instructions are a row with a caption, which the "
        'native sheet needs to draw it', (tester) async {
      final session = await pumpAutomations(tester);
      await session.open(_pageA);

      final prompt = session.row(_pageA, '$_pageA-prompt')!;
      expect(prompt.title, _l10n.scheduledTaskPromptLabel);
    });

    group('results', () {
      testWidgets('a chat result opens through the account the page opened '
          'for', (tester) async {
        final session = await pumpAutomations(
          tester,
          configureWire: (wire) =>
              wire.runs['a'] = [runJson('r1', chatId: 'chat-1')],
        );
        await session.open(_pageA);
        // Somewhere else first, so opening the result has to go to the chat.
        session.router.goNamed(
          RouteNames.channel,
          pathParameters: {'id': 'c0'},
        );
        await tester.pumpAndSettle();
        expect(
          session.router.routerDelegate.currentConfiguration.uri.path,
          isNot(Routes.chat),
        );

        await session.change(_row('open-run', 'r1'));
        await tester.pumpAndSettle();

        expect(FakeSelection.selected.single.id, 'chat-1');
        expect(
          session.router.routerDelegate.currentConfiguration.uri.path,
          Routes.chat,
        );
      });

      testWidgets('a channel result opens the channel', (tester) async {
        final session = await pumpAutomations(
          tester,
          configureWire: (wire) =>
              wire.runs['a'] = [runJson('r1', chatId: 'channel:c1')],
        );
        await session.open(_pageA);

        await session.change(_row('open-run', 'r1'));
        await tester.pumpAndSettle();

        expect(find.byKey(automationChannelKey('c1')), findsOneWidget);
        expect(FakeSelection.selected, isEmpty);
      });

      testWidgets('a page that outlived an account switch opens nothing', (
        tester,
      ) async {
        final session = await pumpAutomations(
          tester,
          configureWire: (wire) =>
              wire.runs['a'] = [runJson('r1', chatId: 'chat-1')],
        );
        await session.open(_pageA);

        session.switchAccount();
        await session.change(_row('open-run', 'r1'));

        expect(FakeSelection.selected, isEmpty);
        expect(
          session.row(_pageA, '$_pageA-error')!.title,
          _l10n.scheduledTasksAccountChanged,
        );
      });
    });

    group('an answer that arrives after the account changed', () {
      testWidgets('a task read does not show the task to the new account', (
        tester,
      ) async {
        final session = await pumpAutomations(tester);
        final hold = session.wire.hold('GET', '/api/v1/automations/a');
        session.pages.register([
          NativeSheetDetailConfig(id: _pageA, title: ''),
        ]);

        final opening = session.module.hydrate(_pageA, _l10n);
        await reach(tester, hold);
        session.switchAccount();
        hold.release();
        await session.settle(opening);
        await session.settle(Future<void>.value());

        expect(session.page(_pageA).title, isNot('Digest'));
      });

      testWidgets('a deleted task stays deleted but does not close the '
          'page for the new account', (tester) async {
        final session = await pumpAutomations(tester);
        await session.open(_pageA);
        final hold = session.wire.hold(
          'DELETE',
          '/api/v1/automations/a/delete',
        );

        final change = session.module.handleChange(_row('delete'), true, _l10n);
        await reach(tester, hold);
        session.switchAccount();
        hold.release();
        await session.settle(change);

        expect(session.wire.where('DELETE', '/a/delete'), hasLength(1));
        expect(session.closed, isEmpty);
      });
    });

    testWidgets('Delete asks first, then deletes once and leaves the page', (
      tester,
    ) async {
      final session = await pumpAutomations(tester);
      await session.open(_pageA);
      final delete = session.row(_pageA, _row('delete'))!;
      expect(delete.confirmMessage, _l10n.scheduledTaskDeleteConfirm('Digest'));

      await session.change(delete.id);

      expect(session.wire.where('DELETE', '/a/delete'), hasLength(1));
      expect(session.closed, [_pageA]);
    });
  });

  group('the editor', () {
    testWidgets('a new task needs a name, instructions and a model before it '
        'sends', (tester) async {
      final session = await pumpAutomations(tester);
      await session.open(_newEditor);
      // Nothing is flagged before the first try.
      expect(session.row(_newEditor, _newRow('name'))!.subtitle, isNull);

      await session.change(_newRow('save'));

      expect(
        session.row(_newEditor, _newRow('name'))!.subtitle,
        _l10n.scheduledTaskNameRequired,
      );
      expect(
        session.row(_newEditor, _newRow('prompt'))!.subtitle,
        _l10n.scheduledTaskPromptRequired,
      );
      expect(
        session.row(_newEditor, _newRow('model'))!.subtitle,
        _l10n.scheduledTaskModelRequired,
      );
      // An issue goes as soon as it is fixed, without another Save.
      await session.change(_newRow('name'), 'n');
      expect(session.row(_newEditor, _newRow('name'))!.subtitle, isNull);
      expect(session.wire.writes, isEmpty);
    });

    testWidgets("creates a daily task in the web client's shape, then "
        'closes', (tester) async {
      final session = await pumpAutomations(tester);
      await session.open(_newEditor);

      await session.change(_newRow('name'), '  Morning digest ');
      await session.change(_newRow('prompt'), 'Summarize the news');
      await session.change(_newRow('model'), 'claude');
      await session.change(_newRow('save'));

      expect(_body(session.wire, '/create'), {
        'name': 'Morning digest',
        'folder_id': null,
        'data': {
          'prompt': 'Summarize the news',
          'model_id': 'claude',
          'rrule': 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',
          'target': {'type': 'chat'},
        },
        'is_active': true,
      });
      expect(session.closed, [_newEditor]);
    });

    testWidgets("one time writes the web client's DTSTART rule, at the time "
        'chosen', (tester) async {
      final session = await pumpAutomations(tester);
      await session.open(_newEditor);
      await _fillNew(session);

      await session.change(_newRow('kind'), 'once');
      final date = session.row(_newEditor, _newRow('date'))!;
      expect(date.kind, NativeSheetItemKind.date);
      expect(date.min, isNotNull);
      await session.change(
        _newRow('time'),
        nativeSheetDateValue(DateTime(2000, 1, 1, 10, 30)),
      );
      await session.change(_newRow('save'));

      expect(
        _data(session.wire, '/create')['rrule'],
        matches(RegExp(r'^DTSTART:\d{8}T103000\nRRULE:FREQ=DAILY;COUNT=1$')),
      );
    });

    testWidgets('says which time zone a schedule is read in', (tester) async {
      final session = await pumpAutomations(tester);

      await session.open(_newEditor);

      expect(
        session.page(_newEditor).sections.map((s) => s.footer),
        contains(_l10n.scheduledTaskTimezoneNote),
      );
    });

    testWidgets('a name change sends the whole task back, unchanged parts as '
        'the server holds them', (tester) async {
      final session = await pumpAutomations(tester);
      await session.open(_pageA);
      await session.open(_editA);

      await session.change(_row('name'), 'Evening digest');
      await session.change(_row('save'));

      final body = _body(session.wire, '/a/update');
      expect(body['name'], 'Evening digest');
      expect(body['data'], containsPair('prompt', 'Summarize the news'));
      expect(body['data'], containsPair('model_id', 'gpt-4o'));
      expect(session.closed, [_editA]);
      // The task's page, under the editor, reads what the server holds now.
      await session.settle(Future<void>.value());
      expect(session.page(_pageA).title, 'Evening digest');
    });

    testWidgets('a weekday change on the Days page writes the control rule, '
        'and the editor under it counts as edited', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson(
            'a',
            rrule: 'RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=18;BYMINUTE=30',
          ),
        ],
      );
      await session.open(_editA);
      final days = '$scheduledTaskDaysPagePrefix${Uri.encodeComponent('a')}';
      await session.open(days);
      expect(session.page(_editA).edited, isFalse);

      await session.change(_row('day', 'TU'));

      expect(session.row(days, _row('day', 'TU'))!.checked, isTrue);
      expect(session.page(_editA).edited, isTrue);
      expect(session.page(_editA).discardPrompt, isNotNull);
      await session.change(_row('save'));
      expect(
        _data(session.wire, '/a/update')['rrule'],
        'RRULE:FREQ=WEEKLY;BYDAY=MO,TU;BYHOUR=18;BYMINUTE=30',
      );
    });

    testWidgets('a weekly task with no day says so and sends nothing', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson(
            'a',
            rrule: 'RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=18;BYMINUTE=30',
          ),
        ],
      );
      await session.open(_editA);
      final days = '$scheduledTaskDaysPagePrefix${Uri.encodeComponent('a')}';
      await session.open(days);

      await session.change(_row('day', 'MO'));
      expect(
        session.page(days).sections.single.footer,
        _l10n.scheduledTaskScheduleIncomplete,
      );
      await session.change(_row('save'));

      expect(session.wire.writes, isEmpty);
      expect(
        session
            .row(
              _editA,
              '$scheduledTaskDaysPagePrefix${Uri.encodeComponent('a')}',
            )!
            .subtitle,
        _l10n.scheduledTaskScheduleIncomplete,
      );
    });

    testWidgets('a rule the controls cannot edit is shown as stored and kept '
        'through an unrelated edit', (tester) async {
      const rule = 'RRULE:FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0';
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a', rrule: rule)],
      );
      await session.open(_editA);
      expect(session.row(_editA, _row('kind'))!.value, 'custom');
      expect(
        session.row(_editA, '$_editA-raw')!.subtitle,
        _l10n.scheduledTaskRruleKept,
      );

      await session.change(_row('name'), 'Monthly digest');
      await session.change(_row('save'));

      expect(_data(session.wire, '/a/update')['rrule'], rule);
    });

    testWidgets('a rule the controls cannot edit is replaced only when a kind '
        'is chosen', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson(
            'a',
            rrule: 'RRULE:FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0',
          ),
        ],
      );
      await session.open(_editA);

      await session.change(_row('kind'), 'daily');
      await session.change(_row('save'));

      expect(
        _data(session.wire, '/a/update')['rrule'],
        'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',
      );
    });

    testWidgets('the Advanced Schedule page edits the raw rule', (
      tester,
    ) async {
      final session = await pumpAutomations(tester);
      await session.open(_editA);
      final rule = '$scheduledTaskRulePagePrefix${Uri.encodeComponent('a')}';
      await session.open(rule);

      await session.change(
        _row('rule'),
        'RRULE:FREQ=WEEKLY;BYDAY=FR;BYHOUR=7;BYMINUTE=15',
      );

      expect(session.row(_editA, _row('kind'))!.value, 'weekly');
      expect(session.page(_editA).edited, isTrue);
      await session.change(_row('save'));
      expect(
        _data(session.wire, '/a/update')['rrule'],
        'RRULE:FREQ=WEEKLY;BYDAY=FR;BYHOUR=7;BYMINUTE=15',
      );
    });

    group('a refused save', () {
      testWidgets("shows the server's reason and keeps the form", (
        tester,
      ) async {
        final session = await pumpAutomations(tester);
        await session.open(_editA);
        session.wire.rejectWrites = (status: 400, detail: 'Bad rule');

        await session.change(_row('name'), 'Evening digest');
        await session.change(_row('save'));

        expect(session.row(_editA, '$_editA-error')!.title, 'Bad rule');
        expect(session.row(_editA, _row('name'))!.value, 'Evening digest');
        expect(session.page(_editA).busy, isFalse);
        expect(session.closed, isEmpty);
      });

      testWidgets('after an account switch sends nothing and shows none of '
          "the form, the previous account's", (tester) async {
        final session = await pumpAutomations(tester);
        await session.open(_editA);
        await session.change(_row('name'), 'Evening digest');

        session.switchAccount();
        await session.change(_row('save'));

        expect(session.wire.writes, isEmpty);
        expect(
          session.row(_editA, '$_editA-error')!.title,
          _l10n.scheduledTasksAccountChanged,
        );
        expect(session.row(_editA, _row('name')), isNull);
      });

      testWidgets('a save answered after the account changed does not close '
          'the form', (tester) async {
        final session = await pumpAutomations(tester);
        await session.open(_editA);
        await session.change(_row('name'), 'Evening digest');
        final hold = session.wire.hold('POST', '/api/v1/automations/a/update');

        final change = session.module.handleChange(_row('save'), true, _l10n);
        await reach(tester, hold);
        session.switchAccount();
        hold.release();
        await session.settle(change);

        expect(session.closed, isEmpty);
      });
    });

    testWidgets("a list change refused after another account signed in says "
        "nothing on that account's list", (tester) async {
      final session = await pumpAutomations(tester);
      await session.open(_list);
      session.wire.rejectWrites = (status: 409, detail: 'Already gone');
      final hold = session.wire.hold('DELETE', '/api/v1/automations/a/delete');

      final change = session.module.handleChange(_row('delete'), true, _l10n);
      await reach(tester, hold);
      session.switchAccount();
      hold.release();
      await session.settle(change);

      expect(session.page(_list).announcement, isNull);
    });

    testWidgets("an account switch shows the next account none of the last "
        "one's task", (tester) async {
      final session = await pumpAutomations(tester);
      await session.open(_pageA);
      expect(session.row(_pageA, _row('active')), isNotNull);
      final taskTitle = session.page(_pageA).title;

      session.switchAccount();
      await session.settle(Future<void>.value());

      expect(session.page(_pageA).title, isNot(taskTitle));
      expect(session.row(_pageA, _row('active')), isNull);
      expect(
        session.row(_pageA, '$_pageA-error')!.title,
        _l10n.scheduledTasksAccountChanged,
      );
    });

    testWidgets("an account switch leaves open Days and Advanced Schedule "
        "pages none of the last one's schedule", (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson(
            'a',
            rrule: 'RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=18;BYMINUTE=30',
          ),
        ],
      );
      // Settings keeps its pages' modules followed while it is open.
      final modules = session.container.listen(
        settingsPageModulesProvider,
        (_, _) {},
      );
      addTearDown(modules.close);
      await session.open(_editA);
      final days = '$scheduledTaskDaysPagePrefix${Uri.encodeComponent('a')}';
      final rule = '$scheduledTaskRulePagePrefix${Uri.encodeComponent('a')}';
      await session.open(days);
      await session.open(rule);
      expect(session.row(days, _row('day', 'MO'))!.checked, isTrue);
      expect(session.row(rule, _row('rule')), isNotNull);
      session.switchAccount();
      await session.settle(Future<void>.value());

      for (final page in [days, rule]) {
        expect(
          session.row(page, '$page-error')?.title,
          _l10n.scheduledTasksAccountChanged,
          reason: page,
        );
      }
      expect(session.row(days, _row('day', 'MO')), isNull);
      expect(session.row(rule, _row('rule')), isNull);
    });

    testWidgets('Advanced switched off leaves open Days and Advanced Schedule '
        'pages none of the schedule', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson(
            'a',
            rrule: 'RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=18;BYMINUTE=30',
          ),
        ],
      );
      // Settings keeps its pages' modules followed while it is open.
      final modules = session.container.listen(
        settingsPageModulesProvider,
        (_, _) {},
      );
      addTearDown(modules.close);
      await session.open(_editA);
      final days = '$scheduledTaskDaysPagePrefix${Uri.encodeComponent('a')}';
      final rule = '$scheduledTaskRulePagePrefix${Uri.encodeComponent('a')}';
      await session.open(days);
      await session.open(rule);
      expect(session.row(days, _row('day', 'MO'))!.checked, isTrue);

      await session.settle(
        session.container
            .read(appSettingsProvider.notifier)
            .setAdvancedFeaturesEnabled(false),
      );

      for (final page in [_editA, days, rule]) {
        expect(session.titles(page), [
          _l10n.advancedRequiredMessage(_l10n.scheduledTasksTitle),
        ], reason: page);
      }

      // Shown again, as after a back swipe let go of: still nothing.
      for (final page in [days, rule]) {
        await session.open(page);
        expect(session.titles(page), [
          _l10n.advancedRequiredMessage(_l10n.scheduledTasksTitle),
        ], reason: '$page shown again');
      }
    });

    testWidgets("the list follows the device's clock style once the app is "
        'back from its settings', (tester) async {
      tester.platformDispatcher.alwaysUse24HourFormatTestValue = false;
      addTearDown(tester.platformDispatcher.clearAlwaysUse24HourTestValue);
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a', rrule: 'RRULE:FREQ=DAILY;BYHOUR=17;BYMINUTE=0')],
      );
      await session.open(_list);
      expect(
        session.row(_list, scheduledTaskPageId('a'))!.subtitle,
        contains('PM'),
      );

      // The 24-hour clock is switched on in the device's settings.
      tester.platformDispatcher.alwaysUse24HourFormatTestValue = true;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await session.settle(Future<void>.value());

      expect(
        session.row(_list, scheduledTaskPageId('a'))!.subtitle,
        contains('17:'),
      );
    });

    testWidgets('a saved task left as it was is not written on Save', (
      tester,
    ) async {
      final session = await pumpAutomations(tester);
      await session.open(_editA);

      await session.change(_row('save'));

      expect(session.wire.writes, isEmpty);
      expect(session.closed, contains(_editA));
    });

    testWidgets('keeps a saved model that is not available visible, and needs '
        'a compatible one', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a', model: 'retired-model')],
      );
      await session.open(_editA);
      expect(
        session.row(_editA, _row('model'))!.subtitle,
        _l10n.scheduledTaskModelUnavailable('retired-model'),
      );

      await session.change(_row('save'));

      expect(
        session.row(_editA, _row('model'))!.subtitle,
        _l10n.scheduledTaskModelUnavailableIssue,
      );
      expect(session.wire.writes, isEmpty);
    });

    testWidgets('a folder that is gone blocks the save until it is cleared', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a', folderId: 'gone')],
        folders: [Folder(id: 'f1', name: 'Reports')],
      );
      await session.open(_editA);

      await session.change(_row('save'));
      expect(
        session.row(_editA, _row('folder'))!.subtitle,
        _l10n.scheduledTaskFolderUnavailableIssue,
      );
      expect(session.wire.writes, isEmpty);

      await session.change(_row('folder'), '');
      await session.change(_row('save'));
      expect(_body(session.wire, '/a/update')['folder_id'], isNull);
    });

    group('a channel destination', () {
      testWidgets('a group channel is chosen without a write check', (
        tester,
      ) async {
        final session = await pumpAutomations(
          tester,
          channels: const [Channel(id: 'g1', name: 'team', type: 'group')],
        );
        await session.open(_editA);

        await session.change(_row('target'), 'channel');
        await session.change(_row('channel'), 'g1');

        expect(session.wire.where('GET', '/channels/g1'), isEmpty);
        expect(session.row(_editA, _row('channel'))!.subtitle, '#team');
      });

      testWidgets('a standard channel is read back and refused without '
          'write access', (tester) async {
        final session = await pumpAutomations(
          tester,
          channels: const [Channel(id: 'c1', name: 'general')],
          configureWire: (wire) => wire.channelWrite = false,
        );
        await session.open(_editA);

        await session.change(_row('target'), 'channel');
        await session.change(_row('channel'), 'c1');

        expect(
          session.row(_editA, '$_editA-error')!.title,
          _l10n.scheduledTaskChannelNoWrite,
        );
        expect(
          session.row(_editA, _row('channel'))!.subtitle,
          _l10n.scheduledTaskChannelChoose,
        );
      });

      testWidgets('a channel task needs a channel before it saves', (
        tester,
      ) async {
        final session = await pumpAutomations(tester);
        await session.open(_editA);

        await session.change(_row('target'), 'channel');
        await session.change(_row('save'));

        expect(
          session.row(_editA, _row('channel'))!.subtitle,
          _l10n.scheduledTaskChannelRequired,
        );
        expect(session.wire.writes, isEmpty);
      });
    });

    testWidgets('the pickers offer the models and folders the account has', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        folders: [Folder(id: 'f1', name: 'Reports')],
      );
      await session.open(_editA);

      final model = session.row(_editA, _row('model'))!;
      expect(model.kind, NativeSheetItemKind.searchablePicker);
      expect(model.options.map((o) => o.id), ['gpt-4o', 'claude']);
      expect(model.value, 'gpt-4o');
      expect(session.row(_editA, _row('folder'))!.options.map((o) => o.id), [
        '',
        'f1',
      ]);
    });

    testWidgets('an editor left keeps nothing that was typed', (tester) async {
      final session = await pumpAutomations(tester);
      await session.open(_editA);
      await session.change(_row('name'), 'Evening digest');

      await session.leave(_editA);
      await session.open(_editA);

      expect(session.row(_editA, _row('name'))!.value, 'Digest');
      expect(session.wire.writes, isEmpty);
    });
  });
}
