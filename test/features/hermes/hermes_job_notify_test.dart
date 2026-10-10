import 'package:conduit/features/hermes/views/hermes_jobs_page.dart';
import 'package:conduit/features/hermes/widgets/hermes_job_editor.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart'
    show AdaptiveSwitch;
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../push/push_test_support.dart';

const _connection = 'conn-api';

PushState _push(PushStatus status) => pushStateWith([
  PushTargetState(target: pushHermesApiTarget, status: status),
]);

void main() {
  group('the editor', () {
    Future<HermesJobDraft?> open(WidgetTester tester, {bool? notify}) async {
      HermesJobDraft? result;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showHermesJobEditor(
                context,
                initialName: 'Daily',
                initialPrompt: 'Summarize',
                initialSchedule: '0 9 * * *',
                initialNotify: notify,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (notify != null) {
        expect(find.text('Notify me'), findsOneWidget);
        await tester.tap(find.byType(AdaptiveSwitch));
        await tester.pumpAndSettle();
      } else {
        expect(find.text('Notify me'), findsNothing);
      }
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('offers Notify me when push reaches the connection', (
      tester,
    ) async {
      final result = await open(tester, notify: true);
      expect(result?.notify, isFalse);
      expect(result?.name, 'Daily');
    });

    testWidgets('leaves it out otherwise', (tester) async {
      final result = await open(tester);
      expect(result?.notify, isNull);
    });
  });

  group('the jobs page', () {
    Future<FakePushCoordinator> pumpPage(
      WidgetTester tester, {
      required PushState? push,
      List<HermesJob> jobs = const [],
    }) async {
      final fake = FakePushCoordinator(push ?? const PushState());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            hermesJobsProvider.overrideWith(() => _Jobs(jobs)),
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
            hermesActiveConnectionIdProvider.overrideWithValue(_connection),
            pushStateIfUsedProvider.overrideWithValue(push),
            pushCoordinatorProvider.overrideWith(() => fake),
          ],
          child: const MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: HermesJobsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return fake;
    }

    Future<void> createJob(WidgetTester tester, {required bool offered}) async {
      await tester.tap(find.text('New scheduled job'));
      await tester.pumpAndSettle();
      expect(find.text('Notify me'), offered ? findsOneWidget : findsNothing);
      if (offered) {
        final toggle = tester.widget<AdaptiveSwitch>(
          find.byType(AdaptiveSwitch).last,
        );
        // On by default for a new job.
        expect(toggle.value, isTrue);
      }
      await tester.enterText(find.byType(EditableText).at(0), 'Daily');
      await tester.enterText(find.byType(EditableText).at(1), 'Summarize');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    testWidgets('a new job notifies by default when push is on', (
      tester,
    ) async {
      final fake = await pumpPage(tester, push: _push(PushStatus.on));
      await createJob(tester, offered: true);
      expect(fake.calls, [
        'setHermesJobNotify $_connection job-new local true',
      ]);
    });

    testWidgets('no Notify me until push works for the connection', (
      tester,
    ) async {
      final fake = await pumpPage(
        tester,
        push: _push(PushStatus.needsHermesPlugin),
      );
      await createJob(tester, offered: false);
      expect(fake.calls, isEmpty);
    });

    testWidgets('editing a job turns Notify me on', (tester) async {
      final fake = await pumpPage(
        tester,
        push: _push(PushStatus.on),
        jobs: const [
          HermesJob(
            id: 'job-1',
            name: 'Daily',
            prompt: 'Summarize',
            schedule: '0 9 * * *',
            deliveryTarget: 'telegram',
          ),
        ],
      );
      await tester.tap(find.byTooltip('Edit scheduled job'));
      await tester.pumpAndSettle();
      final toggle = find.descendant(
        of: find.byKey(const Key('hermes-job-notify')),
        matching: find.byType(AdaptiveSwitch),
      );
      expect(tester.widget<AdaptiveSwitch>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(fake.calls, [
        'setHermesJobNotify $_connection job-1 telegram true',
      ]);
    });

    testWidgets('no Notify me while push is off', (tester) async {
      final fake = await pumpPage(tester, push: null);
      await createJob(tester, offered: false);
      expect(fake.calls, isEmpty);
    });
  });
}

final class _Jobs extends HermesJobsController {
  _Jobs(this.jobs);

  final List<HermesJob> jobs;

  @override
  Future<List<HermesJob>> build() async => jobs;

  @override
  Future<void> edit(
    String id, {
    String? name,
    String? prompt,
    String? schedule,
  }) async {}

  @override
  Future<HermesJob?> create({
    required String name,
    required String prompt,
    required String schedule,
  }) async => HermesJob(
    id: 'job-new',
    name: name,
    prompt: prompt,
    schedule: schedule,
    deliveryTarget: 'local',
  );
}
