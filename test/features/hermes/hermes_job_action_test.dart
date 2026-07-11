import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_job.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/utils/hermes_schedule_format.dart';
import 'package:conduit/features/hermes/views/hermes_jobs_page.dart';
import 'package:conduit/features/hermes/widgets/hermes_job_editor.dart';
import 'package:conduit/features/hermes/widgets/hermes_jobs_sheet.dart';
import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Hermes cron validation accepts standard syntax and rejects bad fields',
    () {
      check(isValidHermesCronExpression('0 9 * * 1')).isTrue();
      check(
        isValidHermesCronExpression('*/15 9-17 * JAN,MAR MON-FRI'),
      ).isTrue();
      check(isValidHermesCronExpression('60 9 * * 1')).isFalse();
      check(isValidHermesCronExpression('0 9 * *')).isFalse();
      check(isValidHermesCronExpression('0 9 * * MONDAY')).isFalse();
    },
  );

  test('common Hermes cron schedules have concise cadence labels', () {
    check(describeHermesCronSchedule('* * * * *')).equals('Every minute');
    check(
      describeHermesCronSchedule('*/15 * * * *'),
    ).equals('Every 15 minutes');
    check(describeHermesCronSchedule('0 * * * *')).equals('Every hour');
    check(
      describeHermesCronSchedule('30 */6 * * *'),
    ).equals('Every 6 hours at :30');
    check(
      describeHermesCronSchedule('0 9 * * 1-5'),
    ).equals('Weekdays at 9:00 AM');
    check(
      describeHermesCronSchedule('30 18 * * MON'),
    ).equals('Every Monday at 6:30 PM');
    check(
      describeHermesCronSchedule('0 8 1 * *'),
    ).equals('Monthly on the 1st at 8:00 AM');
    check(describeHermesCronSchedule('5,35 * * * *')).equals('5,35 * * * *');
    check(hermesScheduleNeedsRawDisplay('0 9 * * 1-5')).isTrue();
    check(hermesScheduleNeedsRawDisplay('5,35 * * * *')).isFalse();
    check(hermesScheduleNeedsRawDisplay('  5,35   * * * *  ')).isFalse();
  });

  test('job mutations fail when the Hermes service is unavailable', () async {
    final container = ProviderContainer(
      overrides: [hermesApiServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await container.read(hermesJobsProvider.future);
    final controller = container.read(hermesJobsProvider.notifier);

    await expectLater(
      controller.create(prompt: 'Summarize updates', schedule: '0 9 * * *'),
      throwsStateError,
    );
    await expectLater(
      controller.edit('job-1', prompt: 'Updated prompt'),
      throwsStateError,
    );
    await expectLater(controller.setEnabled('job-1', false), throwsStateError);
    await expectLater(controller.runNow('job-1'), throwsStateError);
    await expectLater(controller.delete('job-1'), throwsStateError);
  });

  testWidgets('job mutation boundary reports failures without rethrowing', (
    tester,
  ) async {
    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              actionContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final result = await runHermesJobMutation(
      actionContext,
      action: () async => throw StateError('offline'),
      failureMessage: 'Could not run scheduled job.',
    );
    await tester.pumpAndSettle();

    check(result).isFalse();
    expect(find.text('Could not run scheduled job.'), findsOneWidget);
  });

  testWidgets('job mutation boundary can acknowledge success', (tester) async {
    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              actionContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final result = await runHermesJobMutation(
      actionContext,
      action: () async {},
      failureMessage: 'Could not run scheduled job.',
      successMessage: 'Scheduled job started.',
    );
    await tester.pumpAndSettle();

    check(result).isTrue();
    expect(find.text('Scheduled job started.'), findsOneWidget);
  });

  testWidgets('run-now owns the row until its mutation completes', (
    tester,
  ) async {
    final controller = _PendingJobsController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hermesJobsProvider.overrideWith(() => controller),
          hermesCapabilitiesProvider.overrideWith(
            (ref) async => const HermesCapabilities(),
          ),
          hermesApiServiceProvider.overrideWithValue(
            HermesApiService(
              config: const HermesConfig(
                enabled: true,
                baseUrl: 'https://hermes.example',
                apiKey: 'test-key',
              ),
            ),
          ),
          hapticEnabledProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: HermesJobsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('job-1')), findsOneWidget);
    final runButton = find.byKey(
      const ValueKey<String>('hermes-job-run-job-1'),
    );
    await tester.tap(runButton);
    await tester.tap(runButton);
    await tester.pump();

    check(controller.runCalls).equals(1);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    controller.runCompleter.complete();
    await tester.pumpAndSettle();
    expect(find.text('Scheduled job started.'), findsOneWidget);
  });

  testWidgets('jobs sheet shows polished timing details and toggles a job', (
    tester,
  ) async {
    final controller = _PendingJobsController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hermesJobsProvider.overrideWith(() => controller),
          hermesCapabilitiesProvider.overrideWith(
            (ref) async => const HermesCapabilities(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(height: 640, child: HermesJobsSheet())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Every day at 9:00 AM'), findsOneWidget);
    expect(find.text('0 9 * * *'), findsOneWidget);
    expect(find.text('Summarize updates'), findsOneWidget);

    final toggle = tester.widget<AdaptiveSwitch>(find.byType(AdaptiveSwitch));
    toggle.onChanged!(false);
    await tester.pumpAndSettle();

    check(controller.toggleCalls).deepEquals([('job-1', false)]);
  });
}

class _PendingJobsController extends HermesJobsController {
  final runCompleter = Completer<void>();
  int runCalls = 0;
  final List<(String, bool)> toggleCalls = [];

  @override
  Future<List<HermesJob>> build() async => const [
    HermesJob(
      id: 'job-1',
      name: 'Daily summary',
      prompt: 'Summarize updates',
      schedule: '0 9 * * *',
    ),
  ];

  @override
  Future<void> runNow(String id) {
    runCalls++;
    return runCompleter.future;
  }

  @override
  Future<void> setEnabled(String id, bool enabled) async {
    toggleCalls.add((id, enabled));
  }
}
