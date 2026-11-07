import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/views/hermes_jobs_page.dart';
import 'package:conduit/features/hermes/widgets/hermes_job_editor.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

HermesJob _job({String? status, String? error, String deliver = 'local'}) =>
    HermesJob.fromJson({
      'id': 'job-1',
      'name': 'Morning digest',
      'prompt': 'Summarize the overnight notes',
      'schedule': '0 7 * * *',
      'deliver': deliver,
      if (status != null)
        'latest_execution': {
          'id': 'exec-1',
          'status': status,
          'error': error,
        },
    })!;

final class _DesktopConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    mode: HermesBackendMode.desktopGateway,
  );
}

final class _ApiServerConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    apiKey: 'synthetic-key',
  );
}

final class _CronJobs extends HermesJobsController {
  _CronJobs(this.jobs);

  List<HermesJob> jobs;
  final stops = <String>[];
  Future<HermesJobStopResult> Function() onStop = () async =>
      const HermesJobStopResult(cancelled: true, executionId: 'exec-1');

  @override
  Future<List<HermesJob>> build() async => jobs;

  @override
  Future<HermesJobStopResult> stopRun(String id) {
    stops.add(id);
    return onStop();
  }

  @override
  Future<List<HermesJob>?> refreshQuietly() async {
    state = AsyncData(jobs);
    return jobs;
  }

  void publish(List<HermesJob> next) {
    jobs = next;
    state = AsyncData(next);
  }
}

Future<void> _pumpPage(
  WidgetTester tester,
  _CronJobs jobs, {
  bool desktop = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hermesConfigProvider.overrideWith(
          desktop ? _DesktopConfig.new : _ApiServerConfig.new,
        ),
        hermesJobsProvider.overrideWith(() => jobs),
        hermesCapabilitiesProvider.overrideWith(
          (ref) async => const HermesCapabilities(),
        ),
        hermesApiServiceProvider.overrideWithValue(null),
      ],
      child: const MaterialApp(home: HermesJobsPage()),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Disposes the page so its live-run poll stops before the test ends.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 5));
}

const _stopKey = ValueKey<String>('hermes-job-stop-job-1');

void main() {
  group('stop', () {
    testWidgets('holds Stopping… until the run is cancelled', (tester) async {
      final jobs = _CronJobs([_job(status: 'running')]);
      final cancel = Completer<HermesJobStopResult>();
      jobs.onStop = () => cancel.future;
      await _pumpPage(tester, jobs);

      expect(find.text('Running now'), findsOneWidget);
      await tester.tap(find.byKey(_stopKey));
      await tester.pump();

      check(jobs.stops).deepEquals(['job-1']);
      expect(find.text('Stopping…'), findsWidgets);

      cancel.complete(
        const HermesJobStopResult(cancelled: true, executionId: 'exec-1'),
      );
      await tester.pump();
      await tester.pump();
      // The run has not reached its cancel check yet.
      expect(find.text('Stopping…'), findsWidgets);
      expect(find.text('Run stopped.'), findsNothing);

      jobs.publish([
        _job(status: 'cancelled', error: 'cancelled on request (Stop)'),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Run stopped.'), findsOneWidget);
      expect(find.byKey(_stopKey), findsNothing);
      expect(
        find.text('Last run stopped: cancelled on request (Stop)'),
        findsOneWidget,
      );
      await _unmount(tester);
    });

    testWidgets('reports a run that finished first', (tester) async {
      final jobs = _CronJobs([_job(status: 'running')]);
      await _pumpPage(tester, jobs);

      // The run ends on its own before the cancel reaches it.
      jobs.jobs = [_job(status: 'completed')];
      await tester.tap(find.byKey(_stopKey));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text('The run finished before it could stop.'),
        findsOneWidget,
      );
      await _unmount(tester);
    });

    testWidgets('says when nothing is in flight', (tester) async {
      final jobs = _CronJobs([_job(status: 'claimed')]);
      jobs.onStop = () async => const HermesJobStopResult(cancelled: false);
      await _pumpPage(tester, jobs);

      await tester.tap(find.byKey(_stopKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('No run is in progress.'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('asks for an update on an older Hermes', (tester) async {
      final jobs = _CronJobs([_job(status: 'running')]);
      jobs.onStop = () async => throw const HermesJobStopUnsupportedException();
      await _pumpPage(tester, jobs);

      await tester.tap(find.byKey(_stopKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Update Hermes to stop running jobs.'), findsOneWidget);
      expect(find.byKey(_stopKey), findsNothing);
      await _unmount(tester);
    });

    testWidgets('is not offered by the API server', (tester) async {
      final jobs = _CronJobs([_job(status: 'running')]);
      await _pumpPage(tester, jobs, desktop: false);

      expect(find.byKey(_stopKey), findsNothing);
      expect(find.text('Running now'), findsNothing);
      await _unmount(tester);
    });

  });

  group('editor', () {
    /// Opens the editor over a bare page; `result` completes when it closes.
    Future<({Future<HermesJobEditorResult?> result})> openEditor(
      WidgetTester tester, {
      String? initialPrompt,
      HermesJobCatchUp initialCatchUp = HermesJobCatchUp.hermesDefault,
    }) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: Scaffold())),
      );
      final result = showHermesJobEditor(
        tester.element(find.byType(Scaffold)),
        initialName: initialPrompt == null ? null : 'Digest',
        initialPrompt: initialPrompt,
        initialSchedule: '0 7 * * *',
        initialCatchUp: initialCatchUp,
        scheduling: true,
      );
      await tester.pumpAndSettle();
      return (result: result);
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    testWidgets('an untouched edit leaves the policy alone', (
      tester,
    ) async {
      final editor = await openEditor(
        tester,
        initialPrompt: 'Summarize the overnight notes',
        initialCatchUp: HermesJobCatchUp.skip,
      );

      expect(find.text('Skip missed runs'), findsOneWidget);
      await save(tester);

      check(await editor.result).isNotNull()
        ..has((r) => r.name, 'name').equals('Digest')
        ..has((r) => r.catchUp, 'catchUp').isNull();
    });

    testWidgets('returns the policy the user changed', (
      tester,
    ) async {
      final editor = await openEditor(
        tester,
        initialPrompt: 'Summarize the overnight notes',
      );

      await tester.tap(find.text('Hermes default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run once after missed runs').last);
      await tester.pumpAndSettle();
      await save(tester);

      check(await editor.result).isNotNull()
          .has((r) => r.catchUp, 'catchUp')
          .equals(HermesJobCatchUp.runOnce);
    });

    testWidgets('a new job always carries its policy', (
      tester,
    ) async {
      final editor = await openEditor(tester);

      await tester.enterText(find.byType(EditableText).at(0), 'Digest');
      await tester.enterText(
        find.byType(EditableText).at(1),
        'Summarize the overnight notes',
      );
      await save(tester);

      check(await editor.result).isNotNull()
          .has((r) => r.catchUp, 'catchUp')
          .equals(HermesJobCatchUp.hermesDefault);
    });
  });
}
