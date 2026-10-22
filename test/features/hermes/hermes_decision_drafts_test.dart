import 'package:conduit/features/hermes/providers/hermes_decision_drafts.dart';
import 'package:conduit/features/hermes/widgets/hermes_decision_card.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const keyA = (
  conversation: 'chat',
  session: 'session',
  message: 'row',
  runtime: 'runtime',
  request: 'request',
);
void main() {
  testWidgets(
    'request replacement, expiry and disposal clear ordinary drafts',
    (tester) async {
      final store = HermesDecisionDrafts();
      final expires = DateTime.now().add(const Duration(seconds: 2));
      final first = store.obtain(keyA, expires)..text = 'old answer';
      final other = (
        conversation: 'other',
        session: 'other',
        message: 'row',
        runtime: 'runtime',
        request: 'request',
      );
      final separate = store.obtain(other, expires)..text = 'other answer';
      expect(store.obtain(keyA, expires), same(first));
      final replacement = (
        conversation: 'chat',
        session: 'session',
        message: 'row',
        runtime: 'runtime',
        request: 'new',
      );
      final next = store.obtain(replacement, expires);
      expect(first.valid, false);
      expect(first.text, isEmpty);
      expect(next.text, isEmpty);
      expect(separate.text, 'other answer');
      await tester.pump(const Duration(seconds: 3));
      expect(next.valid, false);
      expect(separate.text, isEmpty);
      store.dispose();
    },
  );

  for (final sensitive in [false, true]) {
    testWidgets(
      'remount retains only ordinary draft and custom choice mode sensitive=$sensitive',
      (tester) async {
        final draft = HermesDecisionDraft();
        late StateSetter rebuild;
        var visible = true;
        Widget card() => HermesDecisionCard(
          kind: sensitive
              ? HermesDecisionKind.secret
              : HermesDecisionKind.clarification,
          draft: draft,
          choices: sensitive ? const [] : const ['One', 'Two'],
          onSubmit: (_) async => false,
        );
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (_, setState) {
                  rebuild = setState;
                  return visible ? card() : const SizedBox.shrink();
                },
              ),
            ),
          ),
        );
        if (!sensitive) {
          await tester.tap(find.text('Write a different answer'));
          await tester.pump();
        }
        await tester.enterText(find.byType(TextField), 'Unsent answer');
        rebuild(() => visible = false);
        await tester.pump();
        rebuild(() => visible = true);
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          sensitive ? '' : 'Unsent answer',
        );
        if (sensitive) expect(draft.text, isEmpty);
        if (!sensitive) {
          await tester.tap(find.text('Send'));
          await tester.pumpAndSettle();
          expect(
            draft.text,
            'Unsent answer',
            reason: 'Failed submission retains the answer.',
          );
          await tester.tap(find.text('Dismiss'));
          await tester.pump();
          rebuild(() => visible = false);
          await tester.pump();
          rebuild(() => visible = true);
          await tester.pump();
          expect(find.byType(TextField), findsNothing);
          await tester.tap(find.text('Waiting for your response'));
          await tester.pump();
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'Unsent answer',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
