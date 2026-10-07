import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'automation_harness.dart';

void main() {
  group('who sees the page', () {
    testWidgets('Advanced off explains itself and sends nothing', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        settings: const AppSettings(),
      );

      expect(
        find.byKey(const Key('scheduled-tasks-needs-advanced')),
        findsOneWidget,
      );
      expect(find.text('Digest'), findsNothing);
      expect(session.wire.requests, isEmpty);
    });

    for (final (name, permissions, enabled) in [
      (
        'an account without the permission',
        const <String, dynamic>{
          'features': {'automations': false},
        },
        true,
      ),
      (
        'a server with scheduled tasks off',
        const <String, dynamic>{
          'features': {'automations': true},
        },
        false,
      ),
    ]) {
      testWidgets('$name sees it unavailable and sends nothing', (
        tester,
      ) async {
        final session = await pumpAutomations(
          tester,
          permissions: permissions,
          serverEnabled: enabled,
        );

        expect(
          find.byKey(const Key('scheduled-tasks-unavailable')),
          findsOneWidget,
        );
        expect(session.wire.requests, isEmpty);
      });
    }
  });

  group('the list', () {
    testWidgets('shows what the server holds with its status and schedule', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson('a', name: 'Morning digest'),
          taskJson(
            'b',
            name: 'Weekly report',
            active: false,
            rrule: 'RRULE:FREQ=WEEKLY;BYDAY=MO,WE;BYHOUR=18;BYMINUTE=30',
          ),
        ],
      );

      expect(find.text('Morning digest'), findsOneWidget);
      expect(find.text('Weekly report'), findsOneWidget);
      expect(find.text('Active'), findsWidgets);
      expect(find.textContaining('Daily at'), findsOneWidget);
      expect(find.textContaining('Mon, Wed at'), findsOneWidget);
      // A paused task is not promised a next run.
      final paused = find.byKey(const Key('scheduled-task-row-b'));
      expect(
        find.descendant(of: paused, matching: find.textContaining('Next run')),
        findsNothing,
      );
      expect(
        find.descendant(of: paused, matching: find.text('Paused')),
        findsOneWidget,
      );
      final list = session.wire.where('GET', '/list').single;
      expect(list.uri.queryParameters, {'page': '1'});
      expect(session.wire.writes, isEmpty);
    });

    testWidgets('an empty account says so', (tester) async {
      await pumpAutomations(tester, tasks: []);

      expect(find.text('No scheduled tasks yet.'), findsOneWidget);
    });

    testWidgets('a search is sent when submitted', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson('a', name: 'Morning digest'),
          taskJson('b', name: 'Weekly report'),
        ],
      );
      session.wire.requests.clear();

      await tester.enterText(
        find.byKey(const Key('scheduled-tasks-search')),
        'report',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(session.wire.where('GET', '/list').single.uri.queryParameters, {
        'query': 'report',
        'page': '1',
      });
      expect(find.text('Weekly report'), findsOneWidget);
      expect(find.text('Morning digest'), findsNothing);
    });

    testWidgets('a status filter is the server\'s, not a local one', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson('a', name: 'Morning digest'),
          taskJson('b', name: 'Weekly report', active: false),
        ],
      );
      session.wire.requests.clear();

      await tester.tap(find.byKey(const Key('scheduled-tasks-filter-paused')));
      await tester.pumpAndSettle();

      expect(session.wire.where('GET', '/list').single.uri.queryParameters, {
        'status': 'paused',
        'page': '1',
      });
      expect(find.text('Weekly report'), findsOneWidget);
      expect(find.text('Morning digest'), findsNothing);
    });

    testWidgets('Load more asks for the next page and appends it', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson('a', name: 'First'),
          taskJson('b', name: 'Second'),
        ],
        configureWire: (wire) => wire.pageSize = 1,
      );
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsNothing);
      session.wire.requests.clear();

      await tester.tap(find.byKey(const Key('scheduled-tasks-load-more')));
      await tester.pumpAndSettle();

      expect(session.wire.where('GET', '/list').single.uri.queryParameters, {
        'page': '2',
      });
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      expect(find.byKey(const Key('scheduled-tasks-load-more')), findsNothing);
    });

    testWidgets('opening a task shows the server\'s copy of it', (
      tester,
    ) async {
      await pumpAutomations(
        tester,
        tasks: [taskJson('a', name: 'Morning digest')],
      );

      await tester.tap(find.byKey(const Key('scheduled-task-row-a')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scheduled-task-run')), findsOneWidget);
      expect(find.text('Summarize the news'), findsOneWidget);
    });

    testWidgets('New scheduled task opens the editor', (tester) async {
      await pumpAutomations(tester);

      await tester.tap(find.byKey(const Key('scheduled-tasks-add')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scheduled-task-save')), findsOneWidget);
      expect(find.text('New scheduled task'), findsWidgets);
    });
  });
}
