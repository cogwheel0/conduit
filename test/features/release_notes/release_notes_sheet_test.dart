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
      var reviewCalls = 0;
      var supportCalls = 0;
      var closeCalls = 0;

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

      await tester.tap(find.text('Review Conduit'));
      await tester.pump();
      expect(reviewCalls, 1);
      expect(supportCalls, 0);
      expect(closeCalls, 0);
      expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);

      await tester.tap(find.text('Buy Me a Coffee'));
      await tester.pump();
      expect(reviewCalls, 1);
      expect(supportCalls, 1);
      expect(closeCalls, 0);
      expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
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
  });

  testWidgets('uses the RTL page direction and keeps navigation working', (
    tester,
  ) async {
    await _pumpReleaseNotesSheet(
      tester,
      textDirection: TextDirection.rtl,
      disableAnimations: true,
    );
    await tester.pump();

    final scrollables = tester.widgetList<Scrollable>(
      find.descendant(
        of: find.byType(PageView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      scrollables.any(
        (scrollable) => scrollable.axisDirection == AxisDirection.left,
      ),
      isTrue,
    );

    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pump();
    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.controller?.page, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removes staged and paging motion when animations are disabled', (
    tester,
  ) async {
    await _pumpReleaseNotesSheet(tester, disableAnimations: true);
    await tester.pump();

    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.controller?.page, 0);

    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pump();
    expect(pageView.controller?.page, 1);
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
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
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
                    currentVersion: '4.0.0',
                    previousVersion: '3.4.3',
                    notes: [
                      ReleaseNote(
                        version: '4.0.0',
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
