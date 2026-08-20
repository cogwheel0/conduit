import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/features/release_notes/models/release_note.dart';
import 'package:conduit/features/release_notes/widgets/release_notes_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/chrome_gradient_fade.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  testWidgets(
    'flutter release notes sheet uses editorial review and support sections',
    (tester) async {
      var reviewCalls = 0;
      var supportCalls = 0;
      var closeCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ReleaseNotesSheet(
                currentVersion: '3.3.2',
                notes: [
                  ReleaseNote(
                    version: '3.3.2',
                    title: "What's new",
                    intro: 'Hi, this update is bundled with the app.',
                    bullets: ['Baked changelog', 'Localized copy'],
                  ),
                ],
                onReview: () => reviewCalls += 1,
                onOpenSupport: () => supportCalls += 1,
                supportLabel: 'Buy Me a Coffee',
                supportIcon: Icons.local_cafe_outlined,
                onClose: () => closeCalls += 1,
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Conduit 3.3 is here'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('Conduit 3.3 is here')).style?.fontSize,
        AppTypography.headlineMedium,
      );
      expect(find.text("What's new"), findsNothing);
      expect(find.text('Enjoying Conduit?'), findsOneWidget);
      expect(
        find.text(
          'A short review helps more people find Conduit. A small tip helps me keep building it. Either one means a lot.',
        ),
        findsOneWidget,
      );
      expect(find.text('Review Conduit'), findsOneWidget);
      expect(find.text('Buy Me a Coffee'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.text(
                'A short review helps more people find Conduit. A small tip helps me keep building it. Either one means a lot.',
              ),
            )
            .style
            ?.fontSize,
        AppTypography.bodyMedium,
      );
      expect(
        tester.widget<Text>(find.text('Review Conduit')).style?.fontSize,
        AppTypography.bodyMedium,
      );
      expect(find.text('Since 3.3.1, now on 3.3.2'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName == 'assets/icons/icon.png',
        ),
        findsNothing,
      );
      expect(find.byType(PageView), findsNothing);
      expect(find.byType(ConduitButton), findsOneWidget);
      final bottomFade = tester.widget<ConduitChromeGradientFade>(
        find.byType(ConduitChromeGradientFade),
      );
      expect(bottomFade.edge, ConduitChromeFadeEdge.bottom);
      expect(bottomFade.contentHeight, TouchTarget.comfortable);
      expect(
        tester.getBottomLeft(find.byType(ConduitButton)).dy,
        tester.getBottomLeft(find.byType(ReleaseNotesSheet)).dy,
      );
      expect(find.text('Baked changelog'), findsOneWidget);
      expect(find.text('Localized copy'), findsOneWidget);

      expect(find.text('Review Conduit').hitTestable(), findsOneWidget);
      expect(find.text('Buy Me a Coffee').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Review Conduit'));
      await tester.pump();
      expect(reviewCalls, 1);
      expect(supportCalls, 0);
      expect(closeCalls, 0);

      await tester.tap(find.text('Buy Me a Coffee'));
      await tester.pump();
      expect(reviewCalls, 1);
      expect(supportCalls, 1);
      expect(closeCalls, 0);
      expect(find.text('Done'), findsOneWidget);
    },
  );

  testWidgets('adaptive surface applies modal-safe content padding', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: const Scaffold(
          body: ConduitAdaptiveSheetSurface(child: Text('Release notes')),
        ),
      ),
    );

    expect(find.byType(SafeArea), findsOneWidget);
    expect(find.text('Release notes'), findsOneWidget);
  });

  testWidgets('dark support card uses the standard modal card treatment', (
    tester,
  ) async {
    await _pumpReleaseNotesSheet(
      tester,
      darkMode: true,
      disableAnimations: true,
    );

    final card = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey<String>('release-notes-support-card')),
    );
    final decoration = card.decoration as BoxDecoration;
    final context = tester.element(
      find.byKey(const ValueKey<String>('release-notes-support-card')),
    );

    expect(decoration.color, context.conduitTheme.cardBackground);
    expect(decoration.border?.top.color, context.conduitTheme.cardBorder);
    expect(decoration.border?.top.width, BorderWidth.standard);
  });

  testWidgets('keeps release notes controls in Flutter composition', (
    tester,
  ) async {
    await _pumpReleaseNotesSheet(tester, disableAnimations: true);
    await tester.pump();

    final adaptiveButtons = tester.widgetList<AdaptiveButton>(
      find.byType(AdaptiveButton),
    );
    expect(adaptiveButtons, isNotEmpty);
    expect(
      adaptiveButtons.every((button) => !button.useNative),
      isTrue,
      reason:
          'Native UIKit platform views can hide Flutter-painted prompt text '
          'inside the blurred release notes surface on iOS 26.',
    );
  });

  testWidgets(
    'keeps support actions visible without scrolling a normal sheet',
    (tester) async {
      await _pumpReleaseNotesSheet(tester, disableAnimations: true);
      await tester.pump();

      expect(
        find.byKey(const ValueKey('release-notes-summary-scroll')),
        findsOneWidget,
      );
      expect(find.text('Review Conduit').hitTestable(), findsOneWidget);
      expect(find.text('Buy Me a Coffee').hitTestable(), findsOneWidget);
      expect(find.text('Done').hitTestable(), findsOneWidget);
    },
  );

  testWidgets('long multi-release summaries scroll behind fixed actions', (
    tester,
  ) async {
    await _pumpReleaseNotesSheet(
      tester,
      disableAnimations: true,
      notes: [
        for (var release = 0; release < 3; release++)
          ReleaseNote(
            version: '4.0.$release',
            title: 'Release $release',
            intro: 'A warm hello from release $release.',
            bullets: [
              for (var bullet = 0; bullet < 4; bullet++)
                'Feature $release.$bullet: A concise improvement.',
            ],
          ),
      ],
    );
    await tester.pump();

    final firstFeature = find.text('Feature 0.0');
    final featureBefore = tester.getTopLeft(firstFeature).dy;
    final reviewBefore = tester.getTopLeft(find.text('Review Conduit')).dy;
    await tester.drag(
      find.byKey(const ValueKey('release-notes-summary-scroll')),
      const Offset(0, -240),
    );
    await tester.pump();

    expect(tester.getTopLeft(firstFeature).dy, lessThan(featureBefore));
    expect(tester.takeException(), isNull);
    expect(find.text('Review Conduit').hitTestable(), findsOneWidget);
    expect(find.text('Buy Me a Coffee').hitTestable(), findsOneWidget);
    expect(find.text('Done').hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(find.text('Review Conduit')).dy, reviewBefore);
  });

  testWidgets('matches the iOS compact composer bottom inset', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetViewPadding);
    try {
      await _pumpReleaseNotesSheet(
        tester,
        size: const Size(402, 874),
        disableAnimations: true,
      );
      await tester.pump();

      expect(tester.getSize(find.byType(ReleaseNotesSheet)).height, 754);
      expect(
        tester.getBottomLeft(find.byType(ConduitButton)).dy,
        tester.getBottomLeft(find.byType(ReleaseNotesSheet)).dy,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('fits a compact screen without overflow', (tester) async {
    await _pumpReleaseNotesSheet(
      tester,
      size: const Size(320, 568),
      disableAnimations: true,
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Done'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('release-notes-summary-scroll')),
      findsOneWidget,
    );
    expect(find.text('Review Conduit').hitTestable(), findsOneWidget);
    expect(find.text('Buy Me a Coffee').hitTestable(), findsOneWidget);
    expect(
      tester.getSize(find.byType(ReleaseNotesSheet)).height,
      lessThanOrEqualTo(568 * 0.84),
    );
  });

  testWidgets('supports large accessibility text without overflow', (
    tester,
  ) async {
    await _pumpReleaseNotesSheet(
      tester,
      textScaler: const TextScaler.linear(2),
      disableAnimations: true,
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Enjoying Conduit?'), findsOneWidget);
    expect(find.text('Review Conduit').hitTestable(), findsOneWidget);
    expect(find.text('Buy Me a Coffee').hitTestable(), findsOneWidget);
  });

  testWidgets('keeps the release hierarchy intact in RTL', (tester) async {
    await _pumpReleaseNotesSheet(
      tester,
      textDirection: TextDirection.rtl,
      disableAnimations: true,
    );
    await tester.pump();

    expect(find.text('Conduit 4.0 is here'), findsOneWidget);
    expect(find.text('Local models'), findsOneWidget);
    expect(find.text('Polished details'), findsOneWidget);
    await tester.ensureVisible(find.text('Review Conduit'));
    await tester.tap(find.text('Review Conduit'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('removes staged motion when animations are disabled', (
    tester,
  ) async {
    await _pumpReleaseNotesSheet(tester, disableAnimations: true);
    await tester.pump();

    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('Chinese support prompts use full-width punctuation', (
    tester,
  ) async {
    await _pumpReleaseNotesSheet(
      tester,
      locale: const Locale('zh'),
      disableAnimations: true,
    );
    await tester.pump();
    expect(find.text('喜欢 Conduit 吗？'), findsOneWidget);
    expect(find.textContaining('无论哪一种，对我都意义重大。'), findsOneWidget);

    await _pumpReleaseNotesSheet(
      tester,
      locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      disableAnimations: true,
    );
    await tester.pump();
    expect(find.text('喜歡 Conduit 嗎？'), findsOneWidget);
    expect(find.textContaining('無論哪一種，對我都意義重大。'), findsOneWidget);
  });

  testWidgets('release notes sheet matches its golden', (tester) async {
    await _pumpReleaseNotesSheet(tester, disableAnimations: true);
    await tester.pump();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/release_notes_sheet.png'),
    );
  });
}

Future<void> _pumpReleaseNotesSheet(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
  bool disableAnimations = false,
  bool darkMode = false,
  Locale locale = const Locale('en'),
  List<ReleaseNote>? notes,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: darkMode
            ? AppTheme.dark(TweakcnThemes.t3Chat)
            : AppTheme.light(TweakcnThemes.t3Chat),
        locale: locale,
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            final mediaQuery = MediaQuery.of(context).copyWith(
              textScaler: textScaler,
              disableAnimations: disableAnimations,
            );
            return MediaQuery(
              data: mediaQuery,
              child: Directionality(
                textDirection: textDirection,
                child: Scaffold(
                  body: ReleaseNotesSheet(
                    currentVersion: '4.0.1',
                    notes:
                        notes ??
                        [
                          ReleaseNote(
                            version: '4.0.1',
                            title: "What's new",
                            intro: 'A focused update, bundled with the app.',
                            bullets: [
                              'Local models: Chat privately on your device.',
                              'Polished details: A calmer, clearer experience.',
                            ],
                          ),
                        ],
                    onReview: _noop,
                    onOpenSupport: _noop,
                    supportLabel: 'Buy Me a Coffee',
                    supportIcon: Icons.local_cafe_outlined,
                    onClose: _noop,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

void _noop() {}
