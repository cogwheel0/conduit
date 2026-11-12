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
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
  Future<void> create({
    required String name,
    required String prompt,
    required String schedule,
    String? deliver,
    HermesJobCatchUp catchUp = HermesJobCatchUp.hermesDefault,
  }) async {
    created.add('$name|$prompt|$schedule|$deliver|${catchUp.name}');
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
      hermesJobDeliveryOptionsProvider.overrideWith((ref) async => _options),
      hermesJobRunsProvider.overrideWith((ref, jobId) async => const []),
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
}
