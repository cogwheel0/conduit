import 'dart:io';

import 'package:conduit/features/release_notes/data/release_notes_repository.dart';
import 'package:conduit/features/release_notes/widgets/release_notes_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    final fontLoader = FontLoader('Geist Sans')
      ..addFont(rootBundle.load('assets/fonts/geist/Geist-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/geist/Geist-SemiBold.ttf'))
      ..addFont(rootBundle.load('assets/fonts/geist/Geist-Bold.ttf'));
    await fontLoader.load();
  });

  for (final localeName in [
    'cs',
    'de',
    'en',
    'es',
    'fr',
    'it',
    'ja',
    'ko',
    'nl',
    'ru',
    'sk',
    'zh',
    'zh_Hant',
  ]) {
    testWidgets('$localeName keeps the release actions on one page', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        tester.view.physicalSize = const Size(402, 874);
        tester.view.devicePixelRatio = 1;
        tester.view.viewPadding = const FakeViewPadding(bottom: 34);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewPadding);

        final notes = parseReleaseNotes(
          File('assets/release_notes/$localeName.json').readAsStringSync(),
        );
        final locale = localeName == 'zh_Hant'
            ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
            : Locale(localeName);

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppTheme.light(TweakcnThemes.t3Chat),
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConduitAdaptiveSheetSurface(
                    bottomSafeArea: false,
                    padding: const EdgeInsets.fromLTRB(
                      Spacing.modalPadding,
                      Spacing.modalPadding,
                      Spacing.modalPadding,
                      0,
                    ),
                    child: ReleaseNotesSheet(
                      currentVersion: '4.0.2',
                      notes: notes,
                      onReview: _noop,
                      onOpenSupport: _noop,
                      supportLabel: 'Buy Me a Coffee',
                      supportIcon: Icons.local_cafe_outlined,
                      onClose: _noop,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull, reason: localeName);
        expect(find.text('Buy Me a Coffee').hitTestable(), findsOneWidget);
        expect(find.byType(ConduitButton).hitTestable(), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}

void _noop() {}
