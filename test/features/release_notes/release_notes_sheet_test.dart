import 'package:conduit/features/release_notes/models/release_note.dart';
import 'package:conduit/features/release_notes/widgets/release_notes_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
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
                    title: 'A more private way to share updates',
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

      expect(find.text('A more private way to share updates'), findsOneWidget);
      expect(find.text('Share a quick review'), findsOneWidget);
      expect(find.text('Review Conduit'), findsOneWidget);
      expect(find.text('Support independent development'), findsOneWidget);
      expect(find.text('Buy Me a Coffee'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    },
  );
}
