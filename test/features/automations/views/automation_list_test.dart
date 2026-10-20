import 'package:conduit/features/profile/widgets/adaptive_segmented_selector.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'automation_harness.dart';

Finder _filter(String label) => find.descendant(
  of: find.byKey(const Key('scheduled-tasks-filter')),
  matching: find.text(label),
);

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
      // The shared Advanced page names the feature and offers to turn it on.
      expect(find.byKey(const Key('advanced-required')), findsOneWidget);
      expect(
        find.byKey(const Key('advanced-required-turn-on')),
        findsOneWidget,
      );
      expect(find.textContaining('Scheduled tasks'), findsWidgets);
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

    testWidgets('an empty account is invited to add a task', (tester) async {
      await pumpAutomations(tester, tasks: []);

      expect(find.text('No scheduled tasks yet.'), findsOneWidget);
      // The empty list is the way in, so there is no second add row.
      expect(find.byKey(const Key('scheduled-tasks-add')), findsNothing);

      await tester.tap(find.byKey(const Key('scheduled-tasks-empty')));
      await tester.pumpAndSettle();

      expect(find.text('New scheduled task'), findsWidgets);
      expect(find.byKey(const Key('scheduled-task-save')), findsOneWidget);
    });

    testWidgets('a search is sent once typing pauses, and clearing it shows '
        'everything again', (tester) async {
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
        'rep',
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const Key('scheduled-tasks-search')),
        'report',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(session.wire.where('GET', '/list'), isEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(session.wire.where('GET', '/list').single.uri.queryParameters, {
        'query': 'report',
        'page': '1',
      });
      expect(find.text('Weekly report'), findsOneWidget);
      expect(find.text('Morning digest'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('scheduled-tasks-search')),
        '',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Weekly report'), findsOneWidget);
      expect(find.text('Morning digest'), findsOneWidget);
    });

    testWidgets('a search that matches nothing offers the whole list', (
      tester,
    ) async {
      await pumpAutomations(
        tester,
        tasks: [taskJson('a', name: 'Morning digest')],
      );

      await tester.enterText(
        find.byKey(const Key('scheduled-tasks-search')),
        'nothing like it',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('No tasks match.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('scheduled-tasks-show-all')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Morning digest'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('scheduled-tasks-search')),
          matching: find.text('nothing like it'),
        ),
        findsNothing,
      );
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

      await tester.tap(_filter('Paused'));
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

    testWidgets('a chosen filter shows at once, with progress until the '
        'server answers', (tester) async {
      final session = await pumpAutomations(
        tester,
        tasks: [
          taskJson('a', name: 'Morning digest'),
          taskJson('b', name: 'Weekly report', active: false),
        ],
      );
      final hold = session.wire.hold('GET', '/api/v1/automations/list');

      await tester.tap(_filter('Paused'));
      await reach(tester, hold);

      final selector = tester.widget<AdaptiveSegmentedSelector<Object>>(
        find.descendant(
          of: find.byKey(const Key('scheduled-tasks-filter')),
          matching: find.byWidgetPredicate(
            (widget) => widget is AdaptiveSegmentedSelector,
          ),
        ),
      );
      expect(selector.value, AutomationStatusFilter.paused);
      expect(find.byKey(const Key('scheduled-tasks-loading')), findsOneWidget);
      // The rows on screen answered the old filter, so they are not shown.
      expect(find.text('Morning digest'), findsNothing);

      hold.release();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scheduled-tasks-loading')), findsNothing);
      expect(find.text('Weekly report'), findsOneWidget);
    });

    testWidgets('a task whose last run failed says so in the list', (
      tester,
    ) async {
      await pumpAutomations(
        tester,
        tasks: [
          {
            ...taskJson('a', name: 'Morning digest'),
            'last_run': runJson('r1', status: 'error', error: 'x'),
          },
          {...taskJson('b', name: 'Weekly report'), 'last_run': runJson('r2')},
        ],
      );

      expect(
        find.byKey(const Key('scheduled-task-row-failed-a')),
        findsOneWidget,
      );
      expect(find.text('Last run failed'), findsOneWidget);
      expect(find.byKey(const Key('scheduled-task-row-failed-b')), findsNothing);
      expect(
        tester.getSemantics(find.byKey(const Key('scheduled-task-row-a'))).label,
        contains('Last run failed'),
      );
    });

    testWidgets('a rule the controls cannot describe is named, not printed', (
      tester,
    ) async {
      await pumpAutomations(
        tester,
        tasks: [
          taskJson(
            'a',
            name: 'Monthly',
            rrule: 'RRULE:FREQ=MONTHLY;BYMONTHDAY=15;BYHOUR=9;BYMINUTE=0',
          ),
        ],
      );

      final row = find.byKey(const Key('scheduled-task-row-a'));
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('Custom schedule'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('FREQ=')),
        findsNothing,
      );
    });

    testWidgets('the filter fits a 360pt phone at large text', (tester) async {
      await pumpAutomations(tester);
      tester.view.physicalSize = const Size(360, 1600);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();

      for (final label in ['All', 'Active', 'Paused']) {
        expect(_filter(label).hitTestable(), findsOneWidget, reason: label);
        expect(tester.getRect(_filter(label)).right, lessThanOrEqualTo(360));
      }
      expect(tester.takeException(), isNull);
    });
  });
}
