import 'dart:async';

import 'package:conduit/features/automations/views/scheduled_task_detail_page.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'automation_harness.dart';

Future<AutomationSession> _open(
  WidgetTester tester, {
  List<Map<String, dynamic>>? tasks,
  List<Map<String, dynamic>> runs = const [],
  String shellLocation = Routes.chat,
  void Function(AutomationWire wire)? configure,
}) {
  return pumpAutomations(
    tester,
    location: '/profile/scheduled-tasks/a',
    shellLocation: shellLocation,
    tasks: tasks ?? [taskJson('a', name: 'Morning digest')],
    configureWire: (wire) {
      wire.runs['a'] = runs;
      configure?.call(wire);
    },
  );
}

void main() {
  group('the task', () {
    testWidgets('shows the definition and the server\'s upcoming runs', (
      tester,
    ) async {
      final session = await _open(tester);

      expect(find.text('Morning digest'), findsWidgets);
      expect(find.text('Summarize the news'), findsOneWidget);
      // The model is named as the account's model list names it.
      expect(
        find.descendant(
          of: find.byKey(const Key('scheduled-task-model-row')),
          matching: find.text('GPT-4o'),
        ),
        findsOneWidget,
      );
      // Both runs come from the server's next_runs, not a local calculation.
      expect(
        find.byKey(const Key('scheduled-task-next-run-1791320967000000001')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('scheduled-task-next-run-1791407367000000003')),
        findsOneWidget,
      );
      expect(session.wire.writes, isEmpty);
      expect(session.wire.runRequests, isEmpty);
    });

    testWidgets('a paused task is promised no next run', (tester) async {
      await _open(tester, tasks: [taskJson('a', active: false)]);

      expect(
        find.byKey(const Key('scheduled-task-no-next-runs')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('scheduled-task-next-run-1791320967000000001')),
        findsNothing,
      );
    });

    testWidgets('a task that is gone says so', (tester) async {
      await pumpAutomations(
        tester,
        location: '/profile/scheduled-tasks/missing',
      );

      expect(find.text('This task no longer exists.'), findsOneWidget);
    });

    testWidgets('keeps a terminal attached without editing it', (tester) async {
      await _open(
        tester,
        tasks: [
          taskJson('a', terminal: {'server_id': 't', 'cwd': '/work'}),
        ],
      );

      expect(find.textContaining('A terminal is attached'), findsOneWidget);
    });
  });

  group('controls', () {
    testWidgets('pausing is one toggle, and the switch shows the server\'s '
        'answer', (tester) async {
      final session = await _open(tester);
      session.wire.requests.clear();

      await tester.tap(find.byKey(const Key('scheduled-task-active-switch')));
      await tester.pumpAndSettle();

      expect(session.wire.writes.map((r) => '${r.method} ${r.uri.path}'), [
        'POST /api/v1/automations/a/toggle',
      ]);
      expect(find.text('Paused'), findsWidgets);
    });

    // The server's toggle flips whatever it holds. A switch showing old state
    // must not flip back a task that another client already paused.
    testWidgets('a task already paused elsewhere is not toggled back on', (
      tester,
    ) async {
      final session = await _open(tester);
      session.wire.tasks.single['is_active'] = false;
      session.wire.requests.clear();

      await tester.tap(find.byKey(const Key('scheduled-task-active-switch')));
      await tester.pumpAndSettle();

      expect(session.wire.writes, isEmpty);
      expect(session.wire.tasks.single['is_active'], isFalse);
      expect(find.text('Paused'), findsWidgets);
    });

    testWidgets('a refused change explains itself and changes nothing', (
      tester,
    ) async {
      final session = await _open(tester);
      session.wire.rejectWrites = (
        status: 403,
        detail: 'Automation limit reached (5)',
      );

      await tester.tap(find.byKey(const Key('scheduled-task-active-switch')));
      await tester.pumpAndSettle();

      expect(find.text('Automation limit reached (5)'), findsOneWidget);
      expect(session.wire.tasks.single['is_active'], isTrue);
    });
  });

  group('layout', () {
    testWidgets('Edit is in the toolbar, and Delete comes last, after History', (
      tester,
    ) async {
      await _open(tester, runs: [runJson('r1')]);

      final edit = find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const Key('scheduled-task-edit')),
      );
      expect(edit, findsOneWidget);
      final run = tester.getRect(find.byKey(const Key('scheduled-task-run')));
      final history = tester.getRect(find.text('History'));
      final delete = tester.getRect(
        find.byKey(const Key('scheduled-task-delete')),
      );
      expect(run.top, lessThan(history.top));
      expect(delete.top, greaterThan(history.top));

      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scheduled-task-save')), findsOneWidget);
    });

    testWidgets('the switch moves at once and waits for the server', (
      tester,
    ) async {
      final session = await _open(tester);
      final hold = session.wire.hold('POST', '/api/v1/automations/a/toggle');

      await tester.tap(find.byKey(const Key('scheduled-task-active-switch')));
      await reach(tester, hold);

      final pending = tester.widget<AdaptiveSwitch>(
        find.byKey(const Key('scheduled-task-active-switch')),
      );
      expect(pending.value, isFalse);
      expect(pending.onChanged, isNull);

      hold.release();
      await tester.pumpAndSettle();
      final settled = tester.widget<AdaptiveSwitch>(
        find.byKey(const Key('scheduled-task-active-switch')),
      );
      expect(settled.value, isFalse);
      expect(settled.onChanged, isNotNull);
    });

    testWidgets('a refused switch goes back', (tester) async {
      final session = await _open(tester);
      session.wire.rejectWrites = (status: 403, detail: 'No');

      await tester.tap(find.byKey(const Key('scheduled-task-active-switch')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<AdaptiveSwitch>(
              find.byKey(const Key('scheduled-task-active-switch')),
            )
            .value,
        isTrue,
      );
    });
  });

  group('run now', () {
    testWidgets('is one request, then waits for the run to show in History', (
      tester,
    ) async {
      final session = await _open(tester);
      session.wire.requests.clear();

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(session.wire.runRequests, hasLength(1));
      expect(
        session.wire.runRequests.single.uri.path,
        '/api/v1/automations/a/run',
      );
      // History was read once right before the request, as its baseline.
      expect(session.wire.where('GET', '/runs'), hasLength(1));
      expect(find.text('Running…'), findsOneWidget);
      // Run now cannot be pressed again while the first run is awaited.
      final run = tester.widget<UtilityRow>(
        find.byKey(const Key('scheduled-task-run')),
      );
      expect(run.onTap, isNull);
      // No run is invented: history shows only what the server recorded.
      expect(find.text('No runs yet.'), findsOneWidget);

      // A read before the server records anything keeps waiting.
      await tester.pump(scheduledTaskRunPollInterval);
      await tester.pump();
      expect(session.wire.where('GET', '/runs'), hasLength(2));
      expect(find.text('Running…'), findsOneWidget);

      // The server records the outcome, and the next read finds it.
      session.wire.runs['a'] = [runJson('r1', chatId: 'chat-1')];
      await tester.pump(scheduledTaskRunPollInterval);
      await tester.pumpAndSettle();

      expect(find.text('Run finished.'), findsOneWidget);
      expect(find.byKey(const Key('scheduled-task-run-r1')), findsOneWidget);
      expect(
        tester
            .widget<UtilityRow>(find.byKey(const Key('scheduled-task-run')))
            .onTap,
        isNotNull,
      );

      // Watching stopped once the run showed, and nothing ran again.
      await tester.pump(scheduledTaskRunPollInterval * 3);
      expect(session.wire.where('GET', '/runs'), hasLength(3));
      expect(session.wire.runRequests, hasLength(1));
    });

    testWidgets('a run already in History is not taken for the new one', (
      tester,
    ) async {
      final session = await _open(
        tester,
        runs: [runJson('old', createdAt: 1000)],
      );

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await tester.pump();
      await tester.pump(scheduledTaskRunPollInterval);
      await tester.pump();
      expect(find.text('Running…'), findsOneWidget);

      session.wire.runs['a'] = [
        runJson('new', status: 'error', error: 'Model not found'),
        runJson('old', createdAt: 1000),
      ];
      await tester.pump(scheduledTaskRunPollInterval);
      await tester.pumpAndSettle();

      expect(
        find.text('The run failed. See History for details.'),
        findsOneWidget,
      );
      expect(find.text('Model not found'), findsOneWidget);
    });

    testWidgets('a scheduled run that finished after the page loaded is not '
        'taken for the requested one', (tester) async {
      final session = await _open(tester);
      // The schedule ran while the page was open; the page has not heard.
      session.wire.runs['a'] = [runJson('scheduled', createdAt: 1791320000)];

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await tester.pump();
      await tester.pump(scheduledTaskRunPollInterval);
      await tester.pump();
      expect(find.text('Running…'), findsOneWidget);
      expect(find.text('Run finished.'), findsNothing);

      session.wire.runs['a'] = [
        runJson('requested', status: 'error', error: 'Model not found'),
        runJson('scheduled', createdAt: 1791320000),
      ];
      await tester.pump(scheduledTaskRunPollInterval);
      await tester.pumpAndSettle();
      expect(
        find.text('The run failed. See History for details.'),
        findsOneWidget,
      );
    });

    testWidgets('Run now and the switch wait for each other', (tester) async {
      final session = await _open(tester);
      final runHold = session.wire.hold('POST', '/api/v1/automations/a/run');

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await reach(tester, runHold);
      AdaptiveSwitch toggle() => tester.widget<AdaptiveSwitch>(
        find.byKey(const Key('scheduled-task-active-switch')),
      );
      UtilityRow runRow() => tester.widget<UtilityRow>(
        find.byKey(const Key('scheduled-task-run')),
      );
      expect(toggle().onChanged, isNull);

      runHold.release();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      // Accepted, and History is watched: the switch is free again.
      expect(find.text('Running…'), findsOneWidget);
      expect(toggle().onChanged, isNotNull);

      // Once History shows the run, Run now is free again.
      session.wire.runs['a'] = [runJson('r1')];
      await tester.pump(scheduledTaskRunPollInterval);
      await tester.pumpAndSettle();
      expect(runRow().onTap, isNotNull);

      final toggleHold = session.wire.hold(
        'POST',
        '/api/v1/automations/a/toggle',
      );
      await tester.tap(find.byKey(const Key('scheduled-task-active-switch')));
      await reach(tester, toggleHold);
      expect(runRow().onTap, isNull);
      expect(runRow().enabled, isFalse);

      toggleHold.release();
      await tester.pumpAndSettle();
      expect(runRow().onTap, isNotNull);
      expect(toggle().value, isFalse);
      expect(session.wire.runRequests, hasLength(1));
    });

    testWidgets('the Last run row shows the run Run now found', (
      tester,
    ) async {
      final session = await _open(
        tester,
        runs: [runJson('old', createdAt: 1790000000000000000)],
      );
      String lastRun() => tester
          .widget<UtilityRow>(find.byKey(const Key('scheduled-task-last-run')))
          .title;
      final before = lastRun();

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      session.wire.runs['a'] = [
        runJson('new', status: 'error', error: 'Model not found'),
        runJson('old', createdAt: 1790000000000000000),
      ];
      await tester.pump(scheduledTaskRunPollInterval);
      await tester.pumpAndSettle();

      expect(
        find.text('The run failed. See History for details.'),
        findsOneWidget,
      );
      final newRunTime = tester
          .widget<UtilityRow>(find.byKey(const Key('scheduled-task-run-new')))
          .title;
      expect(lastRun(), isNot(before));
      expect(lastRun(), contains(newRunTime));
      expect(
        find.descendant(
          of: find.byKey(const Key('scheduled-task-last-run')),
          matching: find.byKey(const ValueKey<String>('run-failed')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a run older than the task\'s last run, or without a time, is '
        'not taken for the new one', (tester) async {
      final task = taskJson('a', name: 'Morning digest')
        ..['last_run_at'] = 1790000000000000000;
      final session = await _open(tester, tasks: [task]);

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // History lags behind the task: it lists an untimed run and one from
      // before the task's last run, neither of them the one asked for.
      session.wire.runs['a'] = [
        runJson('untimed')..['created_at'] = null,
        runJson('older', createdAt: 1780000000000000000),
      ];
      await tester.pump(scheduledTaskRunPollInterval);
      await tester.pump();
      expect(find.text('Running…'), findsOneWidget);

      session.wire.runs['a'] = [
        runJson('new'),
        ...session.wire.runs['a']!,
      ];
      await tester.pump(scheduledTaskRunPollInterval);
      await tester.pumpAndSettle();
      expect(find.text('Run finished.'), findsOneWidget);
    });

    testWidgets('a slow first History read does not drop the run Run now '
        'found', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a', name: 'Morning digest')],
        configureWire: (wire) => wire.runs['a'] = const [],
      );
      final hold = session.wire.hold('GET', '/api/v1/automations/a/runs');
      unawaited(session.router.push<void>('/profile/scheduled-tasks/a'));
      await reach(tester, hold);

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      session.wire.runs['a'] = [runJson('r1', chatId: 'chat-1')];
      await tester.pump(scheduledTaskRunPollInterval);
      await tester.pump();
      expect(find.text('Run finished.'), findsOneWidget);
      expect(find.byKey(const Key('scheduled-task-run-r1')), findsOneWidget);

      // The first read, answered before the run, lands last.
      hold.release();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scheduled-task-run-r1')), findsOneWidget);
      expect(find.text('No runs yet.'), findsNothing);
    });

    testWidgets('stops watching after about two minutes and says where the '
        'result will show', (tester) async {
      final session = await _open(tester);

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await tester.pump();
      for (var i = 0; i < scheduledTaskRunPollLimit; i++) {
        await tester.pump(scheduledTaskRunPollInterval);
      }
      await tester.pumpAndSettle();

      expect(find.textContaining('Run requested'), findsOneWidget);
      expect(find.text('Running…'), findsNothing);
      final reads = session.wire.where('GET', '/runs').length;
      await tester.pump(scheduledTaskRunPollInterval * 3);
      expect(session.wire.where('GET', '/runs'), hasLength(reads));
    });

    testWidgets('stops watching when the page closes', (tester) async {
      final session = await _open(tester);

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      session.router.pop();
      await tester.pumpAndSettle();
      final reads = session.wire.where('GET', '/runs').length;

      await tester.pump(scheduledTaskRunPollInterval * 3);
      expect(session.wire.where('GET', '/runs'), hasLength(reads));
    });

    testWidgets('stops watching when the account changes', (tester) async {
      final session = await _open(tester);

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      session.switchAccount();
      await tester.pump();
      session.wire.requests.clear();

      await tester.pump(scheduledTaskRunPollInterval * 3);
      await tester.pumpAndSettle();

      expect(session.wire.where('GET', '/runs'), isEmpty);
      expect(find.text('Running…'), findsNothing);
      expect(
        find.text('The account changed. Reopen scheduled tasks to continue.'),
        findsOneWidget,
      );
    });

    testWidgets('a refused run shows the server\'s reason', (tester) async {
      final session = await _open(tester);
      session.wire.rejectWrites = (status: 404, detail: 'gone');

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await tester.pumpAndSettle();

      expect(session.wire.runRequests, hasLength(1));
      expect(find.text('This task no longer exists.'), findsOneWidget);
      expect(find.byKey(const Key('scheduled-task-run-notice')), findsNothing);
    });
  });

  group('history', () {
    testWidgets('lists each recorded run on its own', (tester) async {
      await _open(
        tester,
        runs: [
          runJson('r2', chatId: 'chat-2'),
          runJson('r1', status: 'error', error: 'Model not found'),
        ],
      );

      // Each row leads with its outcome, says it in words to assistive
      // technology, and shows an error under the time.
      final succeeded = find.byKey(const Key('scheduled-task-run-r2'));
      final failed = find.byKey(const Key('scheduled-task-run-r1'));
      expect(
        find.descendant(
          of: succeeded,
          matching: find.byKey(const ValueKey('run-succeeded')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: failed,
          matching: find.byKey(const ValueKey('run-failed')),
        ),
        findsOneWidget,
      );
      expect(tester.getSemantics(succeeded).label, startsWith('Succeeded. '));
      expect(tester.getSemantics(failed).label, startsWith('Failed. '));
      expect(
        find.descendant(of: failed, matching: find.text('Model not found')),
        findsOneWidget,
      );
      expect(find.text('View chat'), findsOneWidget);
      // The last run on the definition shows its outcome too.
      expect(
        find.descendant(
          of: find.byKey(const Key('scheduled-task-last-run')),
          matching: find.byKey(const ValueKey('run-succeeded')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('pages by offset until a short page', (tester) async {
      final runs = [
        for (var i = 0; i < 60; i++) runJson('r$i', createdAt: 1000 + i),
      ];
      final session = await _open(tester, runs: runs);

      expect(session.wire.where('GET', '/runs').single.uri.queryParameters, {
        'skip': '0',
        'limit': '50',
      });
      expect(find.byKey(const Key('scheduled-task-run-r49')), findsOneWidget);
      expect(find.byKey(const Key('scheduled-task-run-r50')), findsNothing);

      await tester.tap(find.byKey(const Key('scheduled-task-history-more')));
      await tester.pumpAndSettle();

      expect(session.wire.where('GET', '/runs').last.uri.queryParameters, {
        'skip': '50',
        'limit': '50',
      });
      expect(find.byKey(const Key('scheduled-task-run-r59')), findsOneWidget);
      expect(
        find.byKey(const Key('scheduled-task-history-more')),
        findsNothing,
      );
    });
  });

  group('results', () {
    testWidgets('a chat result opens through the captured account\'s chat '
        'selection', (tester) async {
      await _open(tester, runs: [runJson('r1', chatId: 'chat-9')]);

      await tester.tap(find.byKey(const Key('scheduled-task-run-r1')));
      await tester.pumpAndSettle();

      expect(FakeSelection.selected.map((c) => c.id), ['chat-9']);
      expect(find.byKey(automationChatKey), findsOneWidget);
      expect(find.byKey(const Key('scheduled-task-run-r1')), findsNothing);
    });

    // The shell is already mounted under the scheduled task whatever the user
    // had open before Settings. Entering it again by push reserves its page
    // key twice and the navigator asserts.
    for (final (underneath, shellLocation) in [
      ('a chat', Routes.chat),
      ('a folder', Routes.folderPath('f1')),
      ('another channel', '/channel/other'),
    ]) {
      testWidgets('a channel result opens the channel over $underneath', (
        tester,
      ) async {
        await _open(
          tester,
          runs: [runJson('r1', chatId: 'channel:chan-1')],
          shellLocation: shellLocation,
        );

        await tester.tap(find.byKey(const Key('scheduled-task-run-r1')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(FakeSelection.selected, isEmpty);
        expect(find.byKey(automationChannelKey('chan-1')), findsOneWidget);
        expect(find.byKey(automationShellKey), findsOneWidget);
        expect(find.byKey(const Key('scheduled-task-run-r1')), findsNothing);
      });
    }

    for (final (kind, chatId) in [
      ('chat', 'chat-9'),
      ('channel', 'channel:chan-1'),
    ]) {
      testWidgets('a screen that outlived an account switch opens no $kind', (
        tester,
      ) async {
        final session = await _open(
          tester,
          runs: [runJson('r1', chatId: chatId)],
        );
        session.switchAccount();
        await tester.pumpAndSettle();
        session.wire.requests.clear();

        await tester.tap(find.byKey(const Key('scheduled-task-run-r1')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(FakeSelection.selected, isEmpty);
        expect(find.byKey(automationChatKey), findsNothing);
        expect(find.byKey(automationChannelKey('chan-1')), findsNothing);
        expect(
          find.text('The account changed. Reopen scheduled tasks to continue.'),
          findsOneWidget,
        );
      });
    }

    testWidgets('controls on that screen are refused without a request', (
      tester,
    ) async {
      final session = await _open(tester);
      session.switchAccount();
      await tester.pumpAndSettle();
      session.wire.requests.clear();

      await tester.tap(find.byKey(const Key('scheduled-task-run')));
      await tester.pumpAndSettle();

      // The only traffic is the new account's own list reload; nothing was
      // sent for the task the old account's screen was showing.
      expect(
        session.wire.requests.where((r) => !r.uri.path.endsWith('/list')),
        isEmpty,
      );
      expect(
        find.text('The account changed. Reopen scheduled tasks to continue.'),
        findsOneWidget,
      );
    });
  });

  // A slow network can answer after another account has signed in on the same
  // server. What the first account asked for stays done; none of it may reach
  // the screen or the navigation of the second.
  group('an answer that arrives after the account changed', () {
    const accountChanged =
        'The account changed. Reopen scheduled tasks to continue.';
    const taskPath = '/api/v1/automations/a';

    Future<void> switchWhileHeld(
      WidgetTester tester,
      AutomationSession session,
      AutomationHold hold,
    ) async {
      await reach(tester, hold);
      session.switchAccount();
      await tester.pump(const Duration(milliseconds: 100));
      hold.release();
      await tester.pumpAndSettle();
    }

    testWidgets('a task read does not show the task to the new account', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a', name: 'Morning digest')],
        configureWire: (wire) => wire.runs['a'] = const [],
      );
      final hold = session.wire.hold('GET', taskPath);
      unawaited(session.router.push<void>('/profile/scheduled-tasks/a'));

      await switchWhileHeld(tester, session, hold);

      expect(find.byKey(const Key('scheduled-task-prompt-text')), findsNothing);
      expect(find.text(accountChanged), findsOneWidget);
      expect(session.wire.where('GET', '/runs'), isEmpty);
    });

    testWidgets('a history read does not list runs for the new account', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a', name: 'Morning digest')],
        configureWire: (wire) => wire.runs['a'] = [runJson('r1')],
      );
      final hold = session.wire.hold('GET', '$taskPath/runs');
      unawaited(session.router.push<void>('/profile/scheduled-tasks/a'));

      await switchWhileHeld(tester, session, hold);

      expect(find.byKey(const Key('scheduled-task-run-r1')), findsNothing);
      expect(
        find.byKey(const Key('scheduled-task-history-retry')),
        findsOneWidget,
      );
    });

    testWidgets('a pause stays paused but is not shown as the new account\'s '
        'task', (tester) async {
      final session = await _open(tester);
      final hold = session.wire.hold('POST', '$taskPath/toggle');
      await tester.tap(find.byKey(const Key('scheduled-task-active-switch')));

      await switchWhileHeld(tester, session, hold);

      expect(session.wire.where('POST', '/toggle'), hasLength(1));
      expect(session.wire.tasks.single['is_active'], isFalse);
      expect(find.text('Paused'), findsNothing);
      expect(find.text(accountChanged), findsOneWidget);
    });

    testWidgets('an accepted run is not reported to the new account and its '
        'history is not read for it', (tester) async {
      final session = await _open(tester);
      final hold = session.wire.hold('POST', '$taskPath/run');
      await tester.tap(find.byKey(const Key('scheduled-task-run')));

      await switchWhileHeld(tester, session, hold);
      session.wire.requests.clear();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(session.wire.runRequests, isEmpty);
      expect(find.byKey(const Key('scheduled-task-run-notice')), findsNothing);
      expect(find.text(accountChanged), findsOneWidget);
      expect(session.wire.where('GET', '/runs'), isEmpty);
    });

    testWidgets('a deleted task stays deleted but does not close the page for '
        'the new account', (tester) async {
      final session = await _open(tester);
      final hold = session.wire.hold('DELETE', '$taskPath/delete');
      await tester.tap(find.byKey(const Key('scheduled-task-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));

      await switchWhileHeld(tester, session, hold);

      expect(session.wire.where('DELETE', '/delete'), hasLength(1));
      expect(session.wire.tasks, isEmpty);
      expect(session.router.state.uri.path, '/profile/scheduled-tasks/a');
      expect(find.text(accountChanged), findsOneWidget);
    });

    testWidgets('a delete does not close a page opened over the task', (
      tester,
    ) async {
      final session = await _open(tester);
      final hold = session.wire.hold('DELETE', '$taskPath/delete');
      await tester.tap(find.byKey(const Key('scheduled-task-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await reach(tester, hold);
      unawaited(session.router.push<void>('/profile/scheduled-tasks'));
      await tester.pumpAndSettle();

      hold.release();
      await tester.pumpAndSettle();

      expect(session.wire.where('DELETE', '/delete'), hasLength(1));
      expect(session.router.state.uri.path, '/profile/scheduled-tasks');
    });
  });

  group('delete', () {
    testWidgets('asks first, then deletes once and leaves the page', (
      tester,
    ) async {
      final session = await _open(tester);
      session.wire.requests.clear();

      await tester.tap(find.byKey(const Key('scheduled-task-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete scheduled task?'), findsOneWidget);
      expect(
        find.text(
          'Morning digest will stop running on the server, and its run '
          'history will be removed.',
        ),
        findsOneWidget,
      );
      expect(session.wire.writes, isEmpty);

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(session.wire.writes.map((r) => '${r.method} ${r.uri.path}'), [
        'DELETE /api/v1/automations/a/delete',
      ]);
      expect(session.wire.tasks, isEmpty);
      expect(find.byKey(const Key('scheduled-task-run')), findsNothing);
      expect(session.router.state.uri.path, Routes.chat);
    });
  });
}
