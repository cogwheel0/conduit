import 'dart:async';

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
      expect(find.text('gpt-4o'), findsOneWidget);
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

  group('run now', () {
    testWidgets('is one request, reported as requested rather than done', (
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
      expect(
        find.byKey(const Key('scheduled-task-run-notice')),
        findsOneWidget,
      );
      expect(find.textContaining('Run requested'), findsOneWidget);
      // No run is invented: history shows only what the server recorded.
      expect(find.text('No runs yet.'), findsOneWidget);
      expect(find.text('Succeeded'), findsNothing);

      // The server records the outcome later, and history is read again once.
      session.wire.runs['a'] = [runJson('r1', chatId: 'chat-1')];
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      // The log was cleared before the press, so the one history read here is
      // the single follow-up, not a repeated run.
      expect(session.wire.runRequests, hasLength(1));
      expect(session.wire.where('GET', '/runs'), hasLength(1));
      expect(find.textContaining('Succeeded'), findsOneWidget);
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

      expect(find.byKey(const Key('scheduled-task-run-r2')), findsOneWidget);
      expect(find.textContaining('Succeeded'), findsOneWidget);
      expect(find.textContaining('Failed'), findsOneWidget);
      expect(find.text('Model not found'), findsOneWidget);
      expect(find.text('View chat'), findsOneWidget);
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
      await tester.tap(find.widgetWithText(TextButton, 'Delete task'));

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
      await tester.tap(find.widgetWithText(TextButton, 'Delete task'));
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
      expect(session.wire.writes, isEmpty);

      await tester.tap(find.widgetWithText(TextButton, 'Delete task'));
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
