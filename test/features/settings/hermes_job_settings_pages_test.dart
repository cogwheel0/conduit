import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/settings/pages/hermes_job_settings_pages.dart';
import 'package:conduit/features/settings/pages/hermes_page_ids.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../push/push_test_support.dart';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

HermesJob _job({String? status, String? error, String deliver = 'local'}) =>
    HermesJob.fromJson({
      'id': 'job-1',
      'name': 'Morning digest',
      'prompt': 'Summarize the overnight notes',
      'schedule': '0 7 * * *',
      'deliver': deliver,
      if (status != null)
        'latest_execution': {'id': 'exec-1', 'status': status, 'error': error},
    })!;

final _options = HermesDeliveryOptions.build(
  targets: [
    {'id': 'local', 'name': 'Local (save only)'},
    {'id': 'telegram', 'name': 'Telegram', 'home_target_set': true},
  ],
  rooms: const [],
  roomProfile: 'ops',
);

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

final class _Jobs extends HermesJobsController {
  _Jobs(this.jobs);

  List<HermesJob> jobs;
  final stops = <String>[];
  int runCalls = 0;
  Completer<void>? running;
  final created = <String>[];
  final toggled = <(String, bool)>[];
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
  Future<void> runNow(String id) {
    runCalls++;
    return (running ??= Completer<void>()).future;
  }

  @override
  Future<void> setEnabled(String id, bool enabled) async {
    toggled.add((id, enabled));
    jobs = [
      for (final job in jobs)
        HermesJob(
          id: job.id,
          name: job.name,
          prompt: job.prompt,
          schedule: job.schedule,
          enabled: enabled,
        ),
    ];
    state = AsyncData(jobs);
  }

  /// Whether a created job comes back with its id, as a server names it.
  bool answersJob = true;
  final edits = <String>[];

  @override
  Future<HermesJob?> create({
    required String name,
    required String prompt,
    required String schedule,
    String? deliver,
    HermesJobCatchUp catchUp = HermesJobCatchUp.hermesDefault,
  }) async {
    created.add('$name|$prompt|$schedule|$deliver|${catchUp.name}');
    return answersJob
        ? HermesJob(
            id: 'job-new',
            name: name,
            prompt: prompt,
            schedule: schedule,
          )
        : null;
  }

  @override
  Future<void> edit(
    String id, {
    String? name,
    String? prompt,
    String? schedule,
    String? deliver,
    HermesJobCatchUp? catchUp,
  }) async {
    edits.add('$id|$name|$deliver');
  }

  /// A fresh list each time, as a real read is.
  @override
  Future<List<HermesJob>?> refreshQuietly() async {
    final fresh = [...jobs];
    state = AsyncData(fresh);
    return fresh;
  }

  void publish(List<HermesJob> next) {
    jobs = next;
    state = AsyncData(next);
  }
}

/// The connection the pages read; tests switch it to another server.
final class _Connection extends Notifier<HermesBackendService?> {
  @override
  HermesBackendService? build() => HermesApiService(
    config: const HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes-a.example',
      apiKey: 'synthetic-key',
    ),
  );

  void use(HermesBackendService service) => state = service;
}

final _connectionProvider =
    NotifierProvider<_Connection, HermesBackendService?>(_Connection.new);

/// The saved id of the connection in use, switched by a test.
final class _ConnectionId extends Notifier<String?> {
  @override
  String? build() => 'home';

  void use(String id) => state = id;
}

final _connectionIdProvider = NotifierProvider<_ConnectionId, String?>(
  _ConnectionId.new,
);

final class _Rig {
  _Rig(this.tester, this.container, this.jobs);

  final WidgetTester tester;
  final ProviderContainer container;
  final _Jobs jobs;

  HermesJobSettingsPages get module => container
      .read(settingsPageModulesProvider)
      .whereType<HermesJobSettingsPages>()
      .single;

  NativeSheetDetailConfig page(String id) =>
      container.read(settingsPagesProvider)[id]!;

  List<NativeSheetItemConfig> rows(String id) => [
    ...page(id).items,
    for (final section in page(id).sections) ...section.items,
  ];

  NativeSheetItemConfig? row(String pageId, String rowId) =>
      rows(pageId).where((row) => row.id == rowId).firstOrNull;

  String? get notice => page(hermesJobsPageId).announcement;

  NativeSheetItemConfig get listRow =>
      row(hermesJobsPageId, hermesJobPageId('job-1'))!;

  Iterable<String> get listActions =>
      listRow.rowActions.map((action) => action.id);

  Future<void> open(String id) async {
    if (container.read(settingsPagesProvider)[id] == null) {
      container.read(settingsPagesProvider.notifier).register([
        NativeSheetDetailConfig(id: id, title: ''),
      ]);
    }
    await settle(module.hydrate(id, _l10n));
  }

  Future<void> change(String id, [Object? value = true]) =>
      settle(module.handleChange(id, value, _l10n));

  /// Starts [id]'s change without waiting for it to end.
  void start(String id, [Object? value = true]) =>
      unawaited(module.handleChange(id, value, _l10n));

  Future<void> settle(Future<Object?> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    for (var i = 0; i < 500 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await work;
  }

  Future<void> frames([int count = 10]) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  /// Leaves the pages so their reading again stops before the test ends.
  void leave() => module.settingsClosed();
}

const _stop = 'hermes-job.stop:job-1';
const _run = 'hermes-job.run:job-1';

Future<_Rig> _pump(
  WidgetTester tester,
  _Jobs jobs, {
  bool desktop = true,
  PushState? push,
  FakePushCoordinator? pushCoordinator,
  bool scheduledKind = true,
}) async {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      hermesConfigProvider.overrideWith(
        desktop ? _DesktopConfig.new : _ApiServerConfig.new,
      ),
      hermesJobsProvider.overrideWith(() => jobs),
      hermesCapabilitiesProvider.overrideWith(
        (ref) async => const HermesCapabilities(),
      ),
      hermesApiServiceProvider.overrideWith(
        (ref) => ref.watch(_connectionProvider),
      ),
      hermesActiveConnectionIdProvider.overrideWith(
        (ref) => ref.watch(_connectionIdProvider),
      ),
      hermesJobDeliveryOptionsProvider.overrideWith((ref) async => _options),
      hermesJobRunsProvider.overrideWith((ref, jobId) async => const []),
      appSettingsProvider.overrideWith(
        () => FixedSettings(
          AppSettings(notificationScheduledEnabled: scheduledKind),
        ),
      ),
      pushStateIfUsedProvider.overrideWithValue(push),
      if (pushCoordinator != null)
        pushCoordinatorProvider.overrideWith(() => pushCoordinator),
    ],
  );
  addTearDown(container.dispose);
  final rig = _Rig(tester, container, jobs);
  await rig.open(hermesJobsPageId);
  return rig;
}

void main() {
  group('stop', () {
    testWidgets('holds Stopping… until the run is cancelled', (tester) async {
      final jobs = _Jobs([_job(status: 'running')]);
      final cancel = Completer<HermesJobStopResult>();
      jobs.onStop = () => cancel.future;
      final rig = await _pump(tester, jobs);
      check(rig.listRow.subtitle!).contains(_l10n.hermesJobRunning);

      rig.start(_stop);
      await rig.frames();
      check(jobs.stops).deepEquals(['job-1']);
      check(rig.listRow.subtitle!).contains(_l10n.hermesJobStopping);

      cancel.complete(
        const HermesJobStopResult(cancelled: true, executionId: 'exec-1'),
      );
      await rig.frames();
      // The run has not reached its cancel check yet.
      check(rig.listRow.subtitle!).contains(_l10n.hermesJobStopping);
      check(rig.notice).isNull();

      jobs.publish([
        _job(status: 'cancelled', error: 'cancelled on request (Stop)'),
      ]);
      await rig.frames();

      check(rig.notice).equals(_l10n.hermesJobStopped);
      check(rig.listActions).not((it) => it.contains(_stop));
      await rig.open(hermesJobPageId('job-1'));
      check(
        rig.rows(hermesJobPageId('job-1')).map((row) => row.title),
      ).contains(_l10n.hermesJobLastCancelled('cancelled on request (Stop)'));
      rig.leave();
    });

    testWidgets('reports a run that finished first', (tester) async {
      final jobs = _Jobs([_job(status: 'running')]);
      final rig = await _pump(tester, jobs);

      // The run ends on its own before the cancel reaches it.
      jobs.jobs = [_job(status: 'completed')];
      await rig.change(_stop);
      await rig.frames();

      check(rig.notice).equals(_l10n.hermesJobFinishedBeforeStop);
      rig.leave();
    });

    testWidgets('a list read before the cancel is answered does not settle '
        'it', (tester) async {
      final jobs = _Jobs([_job(status: 'running')]);
      final cancel = Completer<HermesJobStopResult>();
      jobs.onStop = () => cancel.future;
      final rig = await _pump(tester, jobs);

      rig.start(_stop);
      await rig.frames();
      // A poll sent before Stop answers with the job idle.
      jobs.publish([_job()]);
      await rig.frames();
      check(rig.notice).isNull();

      cancel.complete(
        const HermesJobStopResult(cancelled: true, executionId: 'exec-1'),
      );
      await rig.frames();
      check(rig.notice).equals(_l10n.hermesJobStopped);
      rig.leave();
    });

    testWidgets('an idle list is read again, so a run started elsewhere '
        'shows Stop', (tester) async {
      final jobs = _Jobs([_job(status: 'completed')]);
      final rig = await _pump(tester, jobs);
      check(rig.listActions).not((it) => it.contains(_stop));

      // The scheduler starts the job; nothing on the page asked for it.
      jobs.jobs = [_job(status: 'running')];
      await tester.pump(const Duration(seconds: 16));
      await rig.frames();

      check(rig.listRow.subtitle!).contains(_l10n.hermesJobRunning);
      check(rig.listActions).contains(_stop);
      rig.leave();
    });

    testWidgets('a list left is no longer read', (tester) async {
      final jobs = _Jobs([_job(status: 'completed')]);
      final rig = await _pump(tester, jobs);
      rig.module.pageLeft(hermesJobsPageId);

      jobs.jobs = [_job(status: 'running')];
      await tester.pump(const Duration(seconds: 16));
      await rig.frames();

      check(rig.listActions).not((it) => it.contains(_stop));
    });

    testWidgets('leaving while Stop waits is safe', (tester) async {
      final jobs = _Jobs([_job(status: 'running')]);
      final cancel = Completer<HermesJobStopResult>();
      jobs.onStop = () => cancel.future;
      final rig = await _pump(tester, jobs);

      rig.start(_stop);
      await rig.frames();
      rig.leave();
      cancel.complete(const HermesJobStopResult(cancelled: false));
      await rig.frames();
      await tester.pump(const Duration(seconds: 5));

      check(tester.takeException()).isNull();
    });

    testWidgets('a reply from the previous connection is ignored', (
      tester,
    ) async {
      final jobs = _Jobs([_job(status: 'running')]);
      final answer = Completer<void>();
      jobs.onStop = () async {
        await answer.future;
        throw const HermesJobStopUnsupportedException();
      };
      final rig = await _pump(tester, jobs);

      rig.start(_stop);
      await rig.frames();
      rig.container.read(_connectionIdProvider.notifier).use('work');
      rig.container
          .read(_connectionProvider.notifier)
          .use(
            HermesApiService(
              config: const HermesConfig(
                enabled: true,
                baseUrl: 'https://hermes-b.example',
                apiKey: 'synthetic-key',
              ),
            ),
          );
      await rig.frames();
      answer.complete();
      await rig.frames();

      check(rig.notice).not((it) => it.equals(_l10n.hermesJobStopUnsupported));
      check(rig.listActions).contains(_stop);
      rig.leave();
    });

    testWidgets('a Run Now answered after another connection took over '
        'says nothing of it', (tester) async {
      final jobs = _Jobs([_job()]);
      final rig = await _pump(tester, jobs);

      rig.start(_run);
      await rig.frames();
      rig.container.read(_connectionIdProvider.notifier).use('work');
      rig.container
          .read(_connectionProvider.notifier)
          .use(
            HermesApiService(
              config: const HermesConfig(
                enabled: true,
                baseUrl: 'https://hermes-b.example',
                apiKey: 'synthetic-key',
              ),
            ),
          );
      await rig.frames();
      jobs.running!.complete();
      await rig.frames();

      check(rig.notice).not((it) => it.equals(_l10n.hermesJobStarted));
      rig.leave();
    });

    testWidgets('a Run Now that fails across a token refresh still says so', (
      tester,
    ) async {
      final jobs = _Jobs([_job()]);
      final rig = await _pump(tester, jobs);

      rig.start(_run);
      await rig.frames();
      // The same connection, its client rebuilt with new tokens.
      rig.container
          .read(_connectionProvider.notifier)
          .use(
            HermesApiService(
              config: const HermesConfig(
                enabled: true,
                baseUrl: 'https://hermes.example',
                apiKey: 'synthetic-key',
              ),
            ),
          );
      await rig.frames();
      jobs.running!.completeError(StateError('offline'));
      await rig.frames();

      check(rig.notice).equals(_l10n.hermesJobRunFailed);
      rig.leave();
    });

    testWidgets('says when nothing is in flight', (tester) async {
      final jobs = _Jobs([_job(status: 'claimed')]);
      jobs.onStop = () async => const HermesJobStopResult(cancelled: false);
      final rig = await _pump(tester, jobs);

      await rig.change(_stop);

      check(rig.notice).equals(_l10n.hermesJobNothingToStop);
      check(rig.listActions).contains(_stop);
      rig.leave();
    });

    testWidgets('a Run now withdrawn before it was sent reads stopped', (
      tester,
    ) async {
      final jobs = _Jobs([_job(status: 'claimed')]);
      jobs.onStop = () async =>
          const HermesJobStopResult(cancelled: true, beforeStart: true);
      final rig = await _pump(tester, jobs);

      await rig.change(_stop);

      check(rig.notice).equals(_l10n.hermesJobStopped);
      check(rig.listRow.subtitle!)
          .not((it) => it.contains(_l10n.hermesJobStopping));
      rig.leave();
    });

    testWidgets('asks for an update on an older Hermes', (tester) async {
      final jobs = _Jobs([_job(status: 'running')]);
      jobs.onStop = () async => throw const HermesJobStopUnsupportedException();
      final rig = await _pump(tester, jobs);

      await rig.change(_stop);

      check(rig.notice).equals(_l10n.hermesJobStopUnsupported);
      check(rig.listActions).not((it) => it.contains(_stop));
      rig.leave();
    });

    testWidgets('is not offered by the API server', (tester) async {
      final jobs = _Jobs([_job(status: 'running')]);
      final rig = await _pump(tester, jobs, desktop: false);

      check(rig.listActions).not((it) => it.contains(_stop));
      check(rig.listRow.subtitle!)
          .not((it) => it.contains(_l10n.hermesJobRunning));
      rig.leave();
    });
  });

  testWidgets('Run Now holds the job until its run ends, then says it '
      'started', (tester) async {
    final jobs = _Jobs([_job()]);
    final rig = await _pump(tester, jobs);

    rig.start(_run);
    rig.start(_run);
    await rig.frames();

    check(jobs.runCalls).equals(1);
    check(rig.listRow.pending).equals(true);
    check(rig.listActions).not((it) => it.contains(_run));

    jobs.running!.complete();
    await rig.frames();
    check(rig.notice).equals(_l10n.hermesJobStarted);
    rig.leave();
  });

  testWidgets('Run Now does not hold the rows behind it while the run '
      'waits', (tester) async {
    final jobs = _Jobs([_job()]);
    final rig = await _pump(tester, jobs);

    // Answered at once, though the run itself is still on its way.
    await rig.change(_run);
    check(jobs.runCalls).equals(1);
    check(rig.listRow.pending).equals(true);

    jobs.running!.complete();
    await rig.frames();
    check(rig.notice).equals(_l10n.hermesJobStarted);
    rig.leave();
  });

  testWidgets("a job's menu pauses it, and a paused job's resumes it", (
    tester,
  ) async {
    final jobs = _Jobs([_job()]);
    final rig = await _pump(tester, jobs);
    NativeSheetRowAction? action(String label) => rig.listRow.rowActions
        .where((action) => action.label == label)
        .firstOrNull;
    check(action(_l10n.hermesJobResume)).isNull();

    await rig.change(action(_l10n.hermesJobPause)!.id);
    check(jobs.toggled).deepEquals([('job-1', false)]);
    check(rig.notice).equals(_l10n.hermesJobPausedSuccess);

    await rig.change(action(_l10n.hermesJobResume)!.id);
    check(jobs.toggled).deepEquals([('job-1', false), ('job-1', true)]);
    check(rig.notice).equals(_l10n.hermesJobResumed);
    rig.leave();
  });

  testWidgets("a job's page names each delivery target", (tester) async {
    final jobs = _Jobs([
      _job(deliver: 'local,bot-chat:research,room:standup@ops'),
    ]);
    final rig = await _pump(tester, jobs);
    final page = hermesJobPageId('job-1');
    await rig.open(page);

    check(
      rig.rows(page).singleWhere((row) => row.id == '$page-delivery').subtitle,
    ).equals('Save in Hermes, Bot Chat: research, Group Chat: standup');
    rig.leave();
  });

  group('editor', () {
    const key = hermesNewJobKey;
    final editor = hermesJobEditorPageId(null);
    String field(String name) => hermesJobRowId(name, key);

    testWidgets('a new job is checked, then added with its delivery and '
        'policy', (tester) async {
      final jobs = _Jobs([]);
      final rig = await _pump(tester, jobs);
      await rig.open(editor);

      await rig.change(field('save'));
      check(jobs.created).isEmpty();
      check(rig.row(editor, field('name'))!.subtitle)
          .equals(_l10n.requiredFieldHelper);

      await rig.change(field('name'), 'Evening review');
      await rig.change(field('prompt'), 'List what changed today');
      await rig.change(field('schedule'), '0 18 * * *');
      await rig.open('$hermesJobDeliveryPagePrefix$key');
      await rig.change(hermesJobRowId('deliver', key, 'telegram'), true);
      check(rig.page(editor).edited).isTrue();
      await rig.change(field('catch-up'), HermesJobCatchUp.skip.name);
      await rig.change(field('save'));

      check(jobs.created).deepEquals([
        'Evening review|List what changed today|0 18 * * *|local,telegram|skip',
      ]);
      check(rig.notice).equals(_l10n.hermesJobCreated);
      // New can be tapped again straight away.
      check(rig.row(hermesJobsPageId, editor)!.disabled).isFalse();
      rig.leave();
    });

    testWidgets('the last target cannot be turned off', (tester) async {
      final jobs = _Jobs([]);
      final rig = await _pump(tester, jobs);
      await rig.open(editor);
      final deliver = '$hermesJobDeliveryPagePrefix$key';
      await rig.open(deliver);

      check(rig.row(deliver, hermesJobRowId('deliver', key, 'local'))!.disabled)
          .isTrue();
      rig.leave();
    });
  });

  group('Notify me', () {
    const key = hermesNewJobKey;
    final editor = hermesJobEditorPageId(null);
    String field(String name, [String k = key]) => hermesJobRowId(name, k);

    PushState push(PushStatus status, {bool enabled = true}) => PushState(
      enabled: enabled,
      relayConfigured: true,
      targets: {
        PushTarget.hermesScope('home'): PushTargetState(
          target: const HermesPushTarget(
            connectionId: 'home',
            label: 'Home Hermes',
            baseUrl: 'https://hermes-a.example',
            mode: HermesBackendMode.desktopGateway,
          ),
          status: status,
        ),
      },
    );

    Future<void> fill(_Rig rig) async {
      await rig.change(field('name'), 'Daily');
      await rig.change(field('prompt'), 'Summarize');
      await rig.change(field('schedule'), '0 7 * * *');
    }

    testWidgets('a new job notifies by default when push reaches the '
        'connection', (tester) async {
      final jobs = _Jobs([]);
      final state = push(PushStatus.on);
      final fake = FakePushCoordinator(state);
      final rig = await _pump(tester, jobs, push: state, pushCoordinator: fake);
      await rig.open(editor);
      check(rig.row(editor, field('notify'))!.value).equals(true);

      await fill(rig);
      await rig.change(field('save'));

      check(fake.calls).deepEquals(['setHermesJobNotify home job-new true']);
      check(rig.notice).equals(_l10n.hermesJobCreated);
      rig.leave();
    });

    testWidgets('none until push works for the connection, or while it is '
        'off', (tester) async {
      for (final state in [
        push(PushStatus.needsHermesPlugin),
        push(PushStatus.on, enabled: false),
        null,
      ]) {
        final jobs = _Jobs([]);
        final fake = FakePushCoordinator(state ?? const PushState());
        final rig = await _pump(
          tester,
          jobs,
          push: state,
          pushCoordinator: fake,
        );
        await rig.open(editor);
        check(rig.row(editor, field('notify'))).isNull();
        await fill(rig);
        await rig.change(field('save'));
        check(fake.calls).isEmpty();
        rig.leave();
      }
    });

    testWidgets('with Scheduled tasks off it is off and says why', (
      tester,
    ) async {
      final state = push(PushStatus.on);
      final fake = FakePushCoordinator(state);
      final rig = await _pump(
        tester,
        _Jobs([]),
        push: state,
        pushCoordinator: fake,
        scheduledKind: false,
      );
      await rig.open(editor);

      final row = rig.row(editor, field('notify'))!;
      check(row.value).equals(false);
      check(row.disabled).isTrue();
      check(row.subtitle).equals(_l10n.hermesJobNotifyNeedsScheduled);
      await fill(rig);
      await rig.change(field('save'));
      check(fake.calls).isEmpty();
      rig.leave();
    });

    testWidgets('a created job the server did not name says notify failed', (
      tester,
    ) async {
      final jobs = _Jobs([])..answersJob = false;
      final state = push(PushStatus.on);
      final rig = await _pump(
        tester,
        jobs,
        push: state,
        pushCoordinator: FakePushCoordinator(state),
      );
      await rig.open(editor);
      await fill(rig);
      await rig.change(field('save'));

      check(jobs.created).length.equals(1);
      check(rig.notice).equals(_l10n.hermesJobCreatedNotifyFailed);
      rig.leave();
    });

    testWidgets('editing a job turns it on, and a failed step says the job '
        'was saved', (tester) async {
      final jobs = _Jobs([_job()]);
      final state = push(PushStatus.on);
      final fake = FakePushCoordinator(state)..jobNotifyError = StateError('x');
      final rig = await _pump(tester, jobs, push: state, pushCoordinator: fake);
      final edit = hermesJobEditorPageId('job-1');
      final k = Uri.encodeComponent('job-1');
      await rig.open(edit);
      check(rig.row(edit, field('notify', k))!.value).equals(false);

      await rig.change(field('notify', k), true);
      await rig.change(field('save', k));

      check(jobs.edits).length.equals(1);
      check(fake.calls).deepEquals(['setHermesJobNotify home job-1 true']);
      check(rig.notice).equals(_l10n.hermesJobUpdatedNotifyFailed);
      rig.leave();
    });

    testWidgets("Deliver To leaves Conduit's target out and a save keeps it", (
      tester,
    ) async {
      final jobs = _Jobs([_job(deliver: 'local,conduit')]);
      final rig = await _pump(tester, jobs);
      final k = Uri.encodeComponent('job-1');
      await rig.open(hermesJobEditorPageId('job-1'));
      final deliver = '$hermesJobDeliveryPagePrefix$k';
      await rig.open(deliver);
      check(rig.row(deliver, hermesJobRowId('deliver', k, 'conduit'))).isNull();

      await rig.change(hermesJobRowId('deliver', k, 'telegram'), true);
      await rig.change(field('save', k));

      check(jobs.edits)
          .deepEquals(['job-1|Morning digest|local,telegram,conduit']);
      rig.leave();
    });

    testWidgets('a job is not made on a connection switched to meanwhile', (
      tester,
    ) async {
      final jobs = _Jobs([]);
      final rig = await _pump(tester, jobs);
      await rig.open(editor);
      await fill(rig);

      rig.container.read(_connectionIdProvider.notifier).use('work');
      await rig.change(field('save'));

      check(jobs.created).isEmpty();
      check(rig.page(editor).announcement).equals(_l10n.hermesJobCreateFailed);
      rig.leave();
    });
  });
}
