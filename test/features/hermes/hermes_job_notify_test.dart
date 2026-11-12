
import 'package:conduit/features/hermes/widgets/hermes_job_editor.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart'
    show AdaptiveSwitch;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';


void main() {
  group('the editor', () {
    Future<HermesJobEditorResult?> open(WidgetTester tester, {bool? notify}) async {
      HermesJobEditorResult? result;
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
        expect(find.text('Notify Me'), findsOneWidget);
        await tester.tap(find.byType(AdaptiveSwitch));
        await tester.pumpAndSettle();
      } else {
        expect(find.text('Notify Me'), findsNothing);
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
}
