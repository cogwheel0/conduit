import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:conduit/features/hermes/widgets/hermes_schedule_editor.dart';
import 'package:conduit/features/hermes/widgets/hermes_schedule_details.dart';
import 'package:conduit/features/hermes/widgets/hermes_conversation_actions.dart';
import 'package:conduit/features/hermes/views/hermes_jobs_page.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';

class _Jobs extends HermesJobsController {
  final calls = <Map<String, Object?>>[];
  bool fail = false;
  Completer<void>? pending;
  @override
  Future<List<HermesJob>> build() async => [];
  @override
  Future<void> create({
    required String name,
    required String prompt,
    required String schedule,
    List<String>? skills,
  }) async {
    calls.add({
      'name': name,
      'prompt': prompt,
      'schedule': schedule,
      'skills': skills,
    });
    if (pending != null) await pending!.future;
    if (fail) throw StateError('server refused');
  }

  @override
  Future<void> edit(
    String id, {
    String? name,
    String? prompt,
    String? schedule,
    List<String>? skills,
  }) async {
    calls.add({
      'id': id,
      'name': name,
      'prompt': prompt,
      'schedule': schedule,
      'skills': skills,
    });
  }
}

class _Routes extends Interceptor {
  final requests = <RequestOptions>[];
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.uri.path;
    if (!path.endsWith('/api/status')) requests.add(options);
    handler.resolve(
      Response(
        requestOptions: options,
        statusCode: 200,
        data: utf8.encode(
          jsonEncode(
            path.endsWith('/api/status')
                ? {'auth_required': false}
                : path.endsWith('/runs')
                ? {'runs': <Object>[]}
                : {'id': 'test-job'},
          ),
        ),
      ),
    );
  }
}

final _config = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example',
  mode: HermesBackendMode.desktopGateway,
  desktopCredentials: HermesDesktopCredentials(legacyToken: 'test-token'),
);
void main() {
  test(
    'editing unknown schedules preserves exact expressions and timezone',
    () {
      for (final value in [
        '5,35 * * * *',
        'every 2h',
        '2026-12-20T09:30:00-07:00',
        '0 9 1 * *',
        'every monday 9am',
      ]) {
        expect(HermesScheduleTiming(value).expression, value);
        expect(HermesScheduleTiming(value).repeat, HermesScheduleRepeat.custom);
      }
      expect(HermesScheduleTiming('30 13 * * 1-5').expression, '30 13 * * 1-5');
      expect(HermesScheduleTiming('0 9 * * 7').expression, '0 9 * * 0');
    },
  );
  test('jobs preserve current and legacy skill bindings', () {
    final job = HermesJob.fromJson({
      'id': 'one',
      'prompt': '',
      'schedule': '0 9 * * *',
      'skills': ['research', 'research', 12],
      'skill': 'notes',
    });
    expect(job!.skills, ['research']);
    expect(parseHermesJobSkills(null, single: 'notes'), ['notes']);
    expect(parseHermesJobSkills([], single: 'notes'), isEmpty);
  });
  test(
    'Desktop create and edit transport native skills and explicit clearing',
    () async {
      final routes = _Routes();
      final service = HermesDesktopApiService(
        config: _config,
        dio: Dio()..interceptors.add(routes),
      );
      addTearDown(service.close);
      await service.createJob(
        name: 'Skill schedule',
        prompt: '',
        schedule: '0 9 * * *',
        skills: ['research', 'notes'],
      );
      expect(routes.requests.last.data, {
        'name': 'Skill schedule',
        'prompt': '',
        'schedule': '0 9 * * *',
        'deliver': 'local',
        'skills': ['research', 'notes'],
      });
      await service.updateJob(
        'test-job',
        prompt: 'Write a summary',
        skills: [],
      );
      expect(routes.requests.last.data, {
        'updates': {'prompt': 'Write a summary', 'skills': []},
      });
      await service.updateJob('test-job', name: 'Rename');
      expect(routes.requests.last.data, {
        'updates': {'name': 'Rename'},
      });
      await service.listJobRuns('test-job', profile: 'research');
      expect(routes.requests.last.uri.path, '/api/cron/jobs/test-job/runs');
      expect(routes.requests.last.uri.queryParameters, {
        'limit': '20',
        'profile': 'research',
      });
      await service.listJobRuns('test-job');
      expect(routes.requests.last.uri.queryParameters, {
        'limit': '20',
        'profile': _config.desktopProfile,
      });
    },
  );
  testWidgets('Save remains above the keyboard', (tester) async {
    await _pump(tester, _Jobs());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(
      tester.getBottomRight(find.byKey(const ValueKey('schedule-save'))).dy,
      lessThanOrEqualTo(700),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'script schedules remain editable without adding an agent prompt',
    (tester) async {
      final jobs = _Jobs();
      const job = HermesJob(
        id: 'script',
        name: 'Script schedule',
        prompt: '',
        schedule: '0 9 * * *',
        script: '/jobs/news.py',
        noAgent: true,
      );
      await _pump(tester, jobs, job: job);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Script'), findsOneWidget);
      expect(find.byKey(const ValueKey('schedule-skills')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('schedule-save')));
      await tester.pumpAndSettle();
      expect(jobs.calls.single['prompt'], '');
      expect(jobs.calls.single['skills'], isEmpty);
      expect(jobs.calls.single['schedule'], '0 9 * * *');
    },
  );
  testWidgets('failed Save retains draft and prohibits duplicate submissions', (
    tester,
  ) async {
    final jobs = _Jobs()
      ..fail = true
      ..pending = Completer<void>();
    await _pump(tester, jobs);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('schedule-instructions')),
      'Keep this draft on failure',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('schedule-save')));
    await tester.tap(find.byKey(const ValueKey('schedule-save')));
    await tester.pump();
    expect(jobs.calls, hasLength(1));
    expect(tester.widget<PopScope>(find.byType(PopScope).last).canPop, false);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(HermesScheduleEditor), findsOneWidget);
    await tester.drag(find.text('New schedule'), const Offset(0, 600));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(HermesScheduleEditor), findsOneWidget);
    jobs.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Could not create scheduled job.'), findsOneWidget);
    expect(find.text('Keep this draft on failure'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'skill picker retains missing bindings and saves skills separately from instructions',
    (tester) async {
      final jobs = _Jobs();
      const job = HermesJob(
        id: 'one',
        name: 'Skill schedule',
        prompt: '',
        schedule: '5,35 * * * *',
        skills: ['missing-skill'],
      );
      await _pump(tester, jobs, job: job);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('schedule-skills')));
      await tester.tap(find.byKey(const ValueKey('schedule-skills')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(HermesScheduleSkillPicker),
          matching: find.text('missing-skill'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('research'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-save')));
      await tester.pumpAndSettle();
      expect(jobs.calls.single['skills'], ['missing-skill', 'research']);
      expect(jobs.calls.single['prompt'], '');
      expect(jobs.calls.single['schedule'], '5,35 * * * *');
      expect(find.text('Open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('nested details return to the schedule without creating a turn', (
    tester,
  ) async {
    final jobs = _Jobs();
    const job = HermesJob(
      id: 'one',
      name: 'Morning',
      prompt: 'Summarize email',
      schedule: '0 9 * * *',
      skills: ['research'],
    );
    await _pump(tester, jobs, job: job, details: true);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Instructions'));
    await tester.pumpAndSettle();
    expect(find.text('Summarize email'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').last);
    await tester.pumpAndSettle();
    expect(find.text('What to run'), findsOneWidget);
    expect(jobs.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed status without error details opens error and repair', (
    tester,
  ) async {
    const job = HermesJob(
      id: 'failed-status',
      name: 'Morning',
      prompt: 'Summarize email',
      schedule: '0 9 * * *',
      lastStatus: 'fail',
    );
    expect(hermesScheduleHasError(job), isTrue);
    expect(
      hermesScheduleRepairPrompt(job, profile: 'research'),
      allOf(
        contains('Bot profile: research'),
        contains('No execution error details'),
      ),
    );
    await _pump(tester, _Jobs(), job: job, details: true);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('hermes-job-error-failed-status')),
    );
    await tester.tap(
      find.byKey(const ValueKey('hermes-job-error-failed-status')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Last: fail'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('hermes-job-fix-failed-status')),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Schedule actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View schedule error'));
    await tester.pumpAndSettle();
    expect(find.text('Last: fail'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Retry confirmation uses the action label and preserves Delete default',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextButton(
                    onPressed: () => confirmHermesRemoval(
                      context,
                      'Retry this member?',
                      'Review activity',
                      confirmText: 'Retry',
                    ),
                    child: const Text('Open retry'),
                  ),
                  TextButton(
                    onPressed: () => confirmHermesRemoval(
                      context,
                      'Delete this chat?',
                      'Remove conversation',
                    ),
                    child: const Text('Open delete'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open retry'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Delete'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open delete'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Delete'), findsOneWidget);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Jobs jobs, {
  HermesJob? job,
  bool details = false,
}) async {
  tester.view.physicalSize = const Size(400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final service = HermesDesktopApiService(config: _config);
  addTearDown(service.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(service),
        hermesJobsProvider.overrideWith(() => jobs),
        hermesCapabilitiesProvider.overrideWith(
          (ref) async => const HermesCapabilities(jobs: true, jobsAdmin: true),
        ),
        hermesInstalledSkillsProvider.overrideWith(
          (ref) async => [
            {'name': 'research', 'description': 'Find sources'},
          ],
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => details
                  ? showHermesScheduleDetail(context, job!)
                  : showHermesScheduleEditor(context, job: job),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
