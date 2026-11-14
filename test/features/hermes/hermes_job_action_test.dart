import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/widgets/hermes_jobs_sheet.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Schedule validation and wording moved to conduit_core
  // (hermes_schedule_validation_test.dart, hermes_schedule_format_test.dart).

  test('job mutations fail when the Hermes service is unavailable', () async {
    final container = ProviderContainer(
      overrides: [hermesApiServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await container.read(hermesJobsProvider.future);
    final controller = container.read(hermesJobsProvider.notifier);

    await expectLater(
      controller.create(
        name: 'Daily summary',
        prompt: 'Summarize updates',
        schedule: '0 9 * * *',
      ),
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

  testWidgets('jobs sheet failure logs never include a raw job id', (
    tester,
  ) async {
    const hostileJobId = 'job-configured-api-secret';
    const providerErrorSecret = 'provider-error-reflected-job-id';
    const providerStackSecret = 'provider-stack-reflected-job-id';
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };

    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            hermesJobsProvider.overrideWith(
              () => _FailingJobsController(
                jobId: hostileJobId,
                errorSecret: providerErrorSecret,
                stackSecret: providerStackSecret,
              ),
            ),
            hermesCapabilitiesProvider.overrideWith(
              (ref) async => const HermesCapabilities(),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(height: 640, child: HermesJobsSheet()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final toggle = tester.widget<AdaptiveSwitch>(find.byType(AdaptiveSwitch));
      toggle.onChanged!(false);
      await tester.pumpAndSettle();
    } finally {
      debugPrint = previousDebugPrint;
    }

    final combinedLogs = logs.join('\n');
    check(combinedLogs).contains('toggle-failed');
    check(combinedLogs).contains('enabled=false');
    check(combinedLogs).not((value) => value.contains(hostileJobId));
    check(combinedLogs).not((value) => value.contains(providerErrorSecret));
    check(combinedLogs).not((value) => value.contains(providerStackSecret));
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

class _FailingJobsController extends HermesJobsController {
  _FailingJobsController({
    required this.jobId,
    required this.errorSecret,
    required this.stackSecret,
  });

  final String jobId;
  final String errorSecret;
  final String stackSecret;

  @override
  Future<List<HermesJob>> build() async => [
    HermesJob(
      id: jobId,
      name: 'Unsafe provider job',
      prompt: 'Never expose my opaque identifier',
      schedule: '0 9 * * *',
    ),
  ];

  @override
  Future<void> setEnabled(String id, bool enabled) => Future<void>.error(
    StateError('$errorSecret $id'),
    StackTrace.fromString(stackSecret),
  );
}
