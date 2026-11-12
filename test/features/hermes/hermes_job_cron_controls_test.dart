import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/widgets/hermes_job_delivery_field.dart';
import 'package:conduit/features/hermes/widgets/hermes_job_editor.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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

/// Disposes what the test showed, so nothing it started outlives it.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 5));
}

/// Lays out native iOS 26 controls, as on a current iPhone.
void _useNativeIOS26() {
  PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
  PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
  PlatformUiCapabilities.debugNativeIOS26Override = true;
}

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  group('editor', () {
    /// Opens the editor over a bare page; `result` completes when it closes.
    Future<({Future<HermesJobEditorResult?> result})> openEditor(
      WidgetTester tester, {
      String? initialPrompt,
      String? initialDeliver,
      HermesJobCatchUp initialCatchUp = HermesJobCatchUp.hermesDefault,
      bool deliveryEditable = true,
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
        deliveryEditable: deliveryEditable,
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

      expect(find.text('Skip Missed Runs'), findsOneWidget);
      await scrollTo(tester, target('bot-chat:research'));
      // A saved target Hermes does not list stays shown as stored.
      expect(find.text('origin'), findsOneWidget);
      expect(find.text('Messaging Apps'), findsOneWidget);
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

      await tester.tap(find.text('Hermes Default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run Once After Missed Runs').last);
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

    testWidgets('the list keeps room for Conduit when asked to', (
      tester,
    ) async {
      // Room targets filling the list to 2,035 characters: `,telegram`
      // still fits, but not with `,conduit` after it.
      final rooms = <String>[];
      while (['local', ...rooms].join(',').length < 1990) {
        rooms.add('room:${'r' * 30}${rooms.length}@ops');
      }
      final last = 2035 - ['local', ...rooms].join(',').length - 1;
      rooms.add('room:${'s' * (last - 'room:@ops'.length)}@ops');
      final value = ['local', ...rooms].join(',');
      check(value.length).equals(2035);

      for (final (reserved, allowed) in [(0, true), (8, false)]) {
        final changes = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: HermesJobDeliveryField(
                  key: ValueKey(reserved),
                  value: value,
                  options: _options,
                  reservedCharacters: reserved,
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
        check(changes).length.equals(allowed ? 1 : 0);
      }
    });

    testWidgets("delivery the app can't read is never replaced", (
      tester,
    ) async {
      // The job's targets came back in a shape this app can't read.
      final editor = await openEditor(
        tester,
        initialPrompt: 'Summarize the overnight notes',
        deliveryEditable: false,
      );

      check(target('local').evaluate()).isEmpty();
      check(target('telegram').evaluate()).isEmpty();
      await save(tester);

      check(await editor.result).isNotNull()
          .has((r) => r.deliver, 'deliver')
          .isNull();
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
      expect(find.text('Skip Missed Runs'), findsOneWidget);
      await scrollTo(tester, target('telegram'));
      await save(tester);

      check(await editor.result).isNotNull()
          .has((r) => r.name, 'name')
          .equals('Digest');
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
