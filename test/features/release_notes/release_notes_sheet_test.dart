import 'package:conduit/features/release_notes/models/release_note.dart';
import 'package:conduit/features/release_notes/widgets/release_notes_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'flutter release notes sheet uses editorial review and support sections',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ReleaseNotesSheet(
                currentVersion: '3.3.2',
                previousVersion: '3.3.1',
                notes: [
                  ReleaseNote(
                    version: '3.3.2',
                    title: "What's new",
                    intro: 'Hi, this update is bundled with the app.',
                    bullets: ['Baked changelog', 'Localized copy'],
                  ),
                ],
                onOpenUrl: (_) {},
                onOpenSupport: () {},
                supportLabel: 'Buy Me a Coffee',
                supportIcon: Icons.local_cafe_outlined,
                onClose: () {},
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text("What's new"), findsOneWidget);
      expect(find.text('Enjoying Conduit?'), findsOneWidget);
      expect(
        find.text(
          'A short review helps more people find Conduit. A small tip helps me keep building it. Either one means a lot.',
        ),
        findsOneWidget,
      );
      expect(find.text('Review Conduit'), findsOneWidget);
      expect(find.text('Buy Me a Coffee'), findsOneWidget);
      expect(find.byType(PageView), findsOneWidget);
      expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.controller?.viewportFraction, 1);

      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
      expect(find.text('Done'), findsOneWidget);
    },
  );

  testWidgets('expressive surface provides a clipped Material card', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: const Scaffold(
          body: ConduitExpressiveSheetSurface(child: Text('Release notes')),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) => widget is Material && widget.clipBehavior == Clip.antiAlias,
      ),
      findsOneWidget,
    );
  });
}
