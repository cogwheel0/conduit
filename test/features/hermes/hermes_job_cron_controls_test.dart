import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/views/hermes_jobs_page.dart';
import 'package:conduit/features/hermes/widgets/hermes_job_delivery_field.dart';
import 'package:conduit/features/hermes/widgets/hermes_job_editor.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
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

final _options = HermesDeliveryOptions.build(
  targets: [
    {'id': 'local', 'name': 'Local (save only)'},
    {'id': 'telegram', 'name': 'Telegram', 'home_target_set': true},
    {'id': 'discord', 'name': 'Discord', 'home_target_set': false},
    {'id': 'bot-chat:research', 'name': 'Bot Chat (research)'},
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

  /// A fresh list each time, as a real read is: an identical one would not
  /// notify the page.
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

/// The connection the page reads; tests switch it to another server.
final class _Connection extends Notifier<HermesBackendService?> {
  @override
  HermesBackendService? build() => null;

  void use(HermesBackendService service) => state = service;
}

final _connectionProvider =
    NotifierProvider<_Connection, HermesBackendService?>(_Connection.new);

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
        hermesApiServiceProvider.overrideWith(
          (ref) => ref.watch(_connectionProvider),
        ),
        hermesJobDeliveryOptionsProvider.overrideWith((ref) async => _options),
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

/// Lays out native iOS 26 controls, as on a current iPhone.
void _useNativeIOS26() {
  PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
  PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
  PlatformUiCapabilities.debugNativeIOS26Override = true;
}

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

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

    testWidgets('a list read before the cancel is answered does not settle '
        'it', (tester) async {
      final jobs = _CronJobs([_job(status: 'running')]);
      final cancel = Completer<HermesJobStopResult>();
      jobs.onStop = () => cancel.future;
      await _pumpPage(tester, jobs);

      await tester.tap(find.byKey(_stopKey));
      await tester.pump();
      // A poll sent before Stop answers with the job idle.
      jobs.publish([_job()]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('The run finished before it could stop.'), findsNothing);

      cancel.complete(
        const HermesJobStopResult(cancelled: true, executionId: 'exec-1'),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Run stopped.'), findsOneWidget);
      expect(find.text('The run finished before it could stop.'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('an idle list is polled, so a run started elsewhere shows '
        'Stop', (tester) async {
      final jobs = _CronJobs([_job(status: 'completed')]);
      await _pumpPage(tester, jobs);
      expect(find.byKey(_stopKey), findsNothing);

      // The scheduler starts the job; nothing on the page asked for it.
      jobs.jobs = [_job(status: 'running')];
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();

      expect(find.text('Running now'), findsOneWidget);
      expect(find.byKey(_stopKey), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('leaving while Stop waits is safe', (tester) async {
      final jobs = _CronJobs([_job(status: 'running')]);
      final cancel = Completer<HermesJobStopResult>();
      jobs.onStop = () => cancel.future;
      await _pumpPage(tester, jobs);

      await tester.tap(find.byKey(_stopKey));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      cancel.complete(const HermesJobStopResult(cancelled: false));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));

      expect(tester.takeException(), isNull);
    });

    testWidgets('a reply from the previous connection is ignored', (
      tester,
    ) async {
      final jobs = _CronJobs([_job(status: 'running')]);
      final answer = Completer<void>();
      jobs.onStop = () async {
        await answer.future;
        throw const HermesJobStopUnsupportedException();
      };
      await _pumpPage(tester, jobs);

      await tester.tap(find.byKey(_stopKey));
      await tester.pump();
      ProviderScope.containerOf(tester.element(find.byType(HermesJobsPage)))
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
      await tester.pump();
      answer.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Update Hermes to stop running jobs.'), findsNothing);
      expect(find.byKey(_stopKey), findsOneWidget);
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

    testWidgets('a Run now withdrawn before it was sent reads stopped', (
      tester,
    ) async {
      final jobs = _CronJobs([_job(status: 'claimed')]);
      jobs.onStop = () async =>
          const HermesJobStopResult(cancelled: true, beforeStart: true);
      await _pumpPage(tester, jobs);

      await tester.tap(find.byKey(_stopKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Run stopped.'), findsOneWidget);
      expect(find.text('Stopping…'), findsNothing);
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

    testWidgets('Run now and Stopping… fit a narrow phone with large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final jobs = _CronJobs([_job(status: 'running')]);
      final cancel = Completer<HermesJobStopResult>();
      jobs.onStop = () => cancel.future;
      await _pumpPage(tester, jobs);

      await tester.tap(find.byKey(_stopKey));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(_stopKey), findsOneWidget);
      cancel.complete(
        const HermesJobStopResult(cancelled: true, executionId: 'exec-1'),
      );
      await _unmount(tester);
    });

    testWidgets('reads Stopping… with one ellipsis while it waits', (
      tester,
    ) async {
      final jobs = _CronJobs([_job(status: 'running')]);
      final cancel = Completer<HermesJobStopResult>();
      jobs.onStop = () => cancel.future;
      await _pumpPage(tester, jobs);

      await tester.tap(find.byKey(_stopKey));
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(_stopKey),
          matching: find.text('Stopping…'),
        ),
        findsOneWidget,
      );
      expect(find.text('Stopping……'), findsNothing);
      cancel.complete(
        const HermesJobStopResult(cancelled: true, executionId: 'exec-1'),
      );
      await _unmount(tester);
    });

    testWidgets('labels the glass Stop in the error colour on iOS 26', (
      tester,
    ) async {
      _useNativeIOS26();
      final jobs = _CronJobs([_job(status: 'running')]);
      await _pumpPage(tester, jobs);

      final stop = tester.widget<CNButton>(
        find.descendant(
          of: find.byKey(_stopKey),
          matching: find.byType(CNButton),
        ),
      );
      final theme = tester.element(find.byKey(_stopKey)).conduitTheme;
      check(stop.label).equals('Stop');
      check(stop.config.style).equals(CNButtonStyle.glass);
      // The light text of a filled destructive button vanishes on glass.
      check(stop.config.labelColor).equals(theme.error);
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('is not offered by the API server', (tester) async {
      final jobs = _CronJobs([_job(status: 'running')]);
      await _pumpPage(tester, jobs, desktop: false);

      expect(find.byKey(_stopKey), findsNothing);
      expect(find.text('Running now'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('names each delivery target on the card', (tester) async {
      final jobs = _CronJobs([
        _job(deliver: 'local,bot-chat:research,room:standup@ops'),
      ]);
      await _pumpPage(tester, jobs);

      expect(
        find.text(
          'Delivery: Save in Hermes only, Bot Chat: research, '
          'Group Chat: standup',
        ),
        findsOneWidget,
      );
      await _unmount(tester);
    });
  });

  group('editor', () {
    /// Opens the editor over a bare page; `result` completes when it closes.
    Future<({Future<HermesJobEditorResult?> result})> openEditor(
      WidgetTester tester, {
      String? initialPrompt,
      String? initialDeliver,
      HermesJobCatchUp initialCatchUp = HermesJobCatchUp.hermesDefault,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            hermesJobDeliveryOptionsProvider.overrideWith(
              (ref) async => _options,
            ),
          ],
          child: const MaterialApp(home: Scaffold()),
        ),
      );
      final result = showHermesJobEditor(
        tester.element(find.byType(Scaffold)),
        initialName: initialPrompt == null ? null : 'Digest',
        initialPrompt: initialPrompt,
        initialSchedule: '0 7 * * *',
        initialDeliver: initialDeliver,
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

    Future<void> scrollTo(WidgetTester tester, Finder finder) =>
        tester.scrollUntilVisible(
          finder,
          100,
          scrollable: find
              .descendant(
                of: find.byType(SingleChildScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );

    Finder target(String id) =>
        find.byKey(ValueKey<String>('hermes-job-deliver-$id'));

    testWidgets('an untouched edit leaves delivery and policy alone', (
      tester,
    ) async {
      final editor = await openEditor(
        tester,
        initialPrompt: 'Summarize the overnight notes',
        initialDeliver: 'origin,local',
        initialCatchUp: HermesJobCatchUp.skip,
      );

      expect(find.text('Skip missed runs'), findsOneWidget);
      await scrollTo(tester, target('bot-chat:research'));
      // A saved target Hermes does not list stays shown as stored.
      expect(find.text('origin'), findsOneWidget);
      expect(find.text('Messaging apps'), findsOneWidget);
      expect(find.text('Bot Chats'), findsOneWidget);
      expect(find.text('Research'), findsNothing);
      expect(find.text('research'), findsOneWidget);
      expect(find.text('Set a home channel in Hermes first.'), findsOneWidget);
      await save(tester);

      check(await editor.result).isNotNull()
        ..has((r) => r.name, 'name').equals('Digest')
        ..has((r) => r.deliver, 'deliver').isNull()
        ..has((r) => r.catchUp, 'catchUp').isNull();
    });

    testWidgets('returns the delivery and policy the user changed', (
      tester,
    ) async {
      final editor = await openEditor(
        tester,
        initialPrompt: 'Summarize the overnight notes',
        initialDeliver: 'local',
      );

      await tester.tap(find.text('Hermes default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run once after missed runs').last);
      await tester.pumpAndSettle();

      await scrollTo(tester, target('discord'));
      await tester.tap(target('telegram'));
      // A platform without a home channel cannot be picked.
      await tester.tap(target('discord'));
      await tester.pumpAndSettle();
      await save(tester);

      check(await editor.result).isNotNull()
        ..has((r) => r.deliver, 'deliver').equals('local,telegram')
        ..has((r) => r.catchUp, 'catchUp').equals(HermesJobCatchUp.runOnce);
    });

    testWidgets('no target is added past what a job can hold', (
      tester,
    ) async {
      // Room targets filling the delivery list nearly to its limit.
      final rooms = <String>[];
      while (['local', ...rooms].join(',').length < 2040) {
        rooms.add('room:${'r' * 30}${rooms.length}@ops');
      }
      final value = ['local', ...rooms].join(',');
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HermesJobDeliveryField(
                value: value,
                options: _options,
                onChanged: changes.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.ensureVisible(target('telegram'));
      await tester.tap(target('telegram'));
      await tester.pump();

      check(changes).isEmpty();
    });

    testWidgets('the last target cannot be cleared', (tester) async {
      final editor = await openEditor(
        tester,
        initialPrompt: 'Summarize the overnight notes',
        initialDeliver: 'telegram',
      );

      await scrollTo(tester, target('telegram'));
      await tester.tap(target('telegram'));
      await tester.pumpAndSettle();
      await save(tester);

      check(await editor.result).isNotNull()
          .has((r) => r.deliver, 'deliver')
          .isNull();
    });

    testWidgets('a new job always carries its delivery and policy', (
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
        ..has((r) => r.deliver, 'deliver').equals('local')
        ..has((r) => r.catchUp, 'catchUp')
            .equals(HermesJobCatchUp.hermesDefault);
    });

    // The dialog sizes its body to its intrinsic width, which the native
    // menu button cannot report: the editor opened blank and froze.
    testWidgets('lays out with native iOS 26 controls', (tester) async {
      _useNativeIOS26();
      final editor = await openEditor(
        tester,
        initialPrompt: 'Summarize the overnight notes',
        initialCatchUp: HermesJobCatchUp.skip,
      );

      check(tester.takeException()).isNull();
      expect(find.byType(CNPopupMenuButton), findsNothing);
      expect(find.text('Skip missed runs'), findsOneWidget);
      await scrollTo(tester, target('telegram'));
      await save(tester);

      check(await editor.result).isNotNull()
          .has((r) => r.name, 'name')
          .equals('Digest');
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
