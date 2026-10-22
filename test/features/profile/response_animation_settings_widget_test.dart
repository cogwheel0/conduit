import 'dart:io';
import 'dart:ui' as ui;

import 'package:conduit/features/profile/widgets/response_animation_settings.dart';
import 'package:conduit/features/profile/widgets/response_finish_preview.dart';
import 'package:conduit/features/chat/widgets/response_finish_transition.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/features/chat/widgets/response_activity_indicator.dart';
import 'package:conduit/shared/widgets/adaptive_selection_sheet.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit_core/models/response_animation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  Widget harness(
    ProviderContainer container, {
    bool dark = true,
    double textScale = 1,
    bool disableAnimations = false,
    GlobalKey? capture,
  }) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: dark
          ? AppTheme.dark(TweakcnThemes.t3Chat)
          : AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations:
              disableAnimations || MediaQuery.disableAnimationsOf(context),
        ),
        child: child!,
      ),
      home: RepaintBoundary(
        key: capture,
        child: UtilityPageScaffold.settings(
          title: 'Appearance',
          children: const [ResponseAnimationSettings()],
        ),
      ),
    ),
  );

  final sheet = find.byKey(const ValueKey('animation-choice-sheet'));
  final headerPreview = find.byKey(const ValueKey('animation-choice-preview'));
  final cancel = find.byKey(const ValueKey('animation-choice-cancel'));
  final save = find.byKey(const ValueKey('animation-choice-save'));

  Finder choice(String label) => find.descendant(
    of: sheet,
    matching: find.widgetWithText(AdaptiveSelectionTile, label),
  );

  Future<void> openSheet(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(sheet, findsOneWidget);
  }

  Future<void> finishDismissal(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(sheet, findsNothing);
  }

  ResponseActivityPainter activityPainter(WidgetTester tester, Finder of) =>
      tester
              .widget<CustomPaint>(
                find.descendant(
                  of: of,
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is CustomPaint &&
                        widget.painter is ResponseActivityPainter,
                  ),
                ),
              )
              .painter!
          as ResponseActivityPainter;

  ResponseFinishTransition finishTransition(WidgetTester tester) =>
      tester.widget<ResponseFinishTransition>(
        find.descendant(
          of: headerPreview,
          matching: find.byType(ResponseFinishTransition),
        ),
      );

  void expectSettings(
    AppSettings settings, {
    ResponseIndicatorStyle thinking = ResponseIndicatorStyle.facets,
    ResponseIndicatorStyle skill = ResponseIndicatorStyle.exchange,
    ResponseFinishStyle finish = ResponseFinishStyle.fade,
  }) {
    expect(settings.thinkingIndicatorStyle, thinking);
    expect(settings.skillIndicatorStyle, skill);
    expect(settings.responseFinishStyle, finish);
  }

  testWidgets(
    'animation choices show disclosure and enabled preview contrast',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      for (final dark in [false, true]) {
        await tester.pumpWidget(harness(container, dark: dark));
        await tester.pump(const Duration(milliseconds: 300));
        final rows = find.byType(UtilityRow);
        expect(rows, findsNWidgets(3));
        for (final row in tester.widgetList<UtilityRow>(rows)) {
          expect(row.showChevron, isTrue);
          expect(row.onTap, isNotNull);
        }
        expect(find.byIcon(Icons.chevron_right), findsNWidgets(3));
        final color = tester
            .element(find.byType(ResponseAnimationSettings))
            .conduitTheme
            .iconPrimary;
        for (final preview in tester.widgetList<ResponseActivityIndicator>(
          find.byType(ResponseActivityIndicator),
        )) {
          expect(preview.color, color);
        }
        expect(
          tester
              .widget<ResponseFinishPreview>(find.byType(ResponseFinishPreview))
              .color,
          color,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('choices stay as drafts until Save persists each preference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(harness(container));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('08 Facets'), findsOneWidget);
    expect(find.text('14 Exchange'), findsOneWidget);
    await openSheet(tester, 'Thinking');
    for (final style in ResponseIndicatorStyle.thinkingChoices) {
      expect(choice(style.label), findsOneWidget);
    }
    expect(choice('14 Exchange'), findsNothing);
    await tester.tap(choice('04 Scan'));
    await tester.pump();
    expect(sheet, findsOneWidget);
    expectSettings(container.read(appSettingsProvider));
    expectSettings(await SettingsService.loadSettings());
    expect(
      tester.widget<AdaptiveSelectionTile>(choice('04 Scan')).selected,
      isTrue,
    );
    expect(
      tester.widget<AdaptiveSelectionTile>(choice('08 Facets')).selected,
      isFalse,
    );
    await tester.tap(save);
    await finishDismissal(tester);
    expect(
      container.read(appSettingsProvider).thinkingIndicatorStyle,
      ResponseIndicatorStyle.scan,
    );
    expectSettings(
      await SettingsService.loadSettings(),
      thinking: ResponseIndicatorStyle.scan,
    );

    await openSheet(tester, 'Using a skill');
    for (final style in ResponseIndicatorStyle.skillChoices) {
      expect(choice(style.label), findsOneWidget);
    }
    expect(choice('04 Scan'), findsNothing);
    await tester.tap(choice('06 Fold'));
    await tester.pump();
    expect(sheet, findsOneWidget);
    expectSettings(
      container.read(appSettingsProvider),
      thinking: ResponseIndicatorStyle.scan,
    );
    expectSettings(
      await SettingsService.loadSettings(),
      thinking: ResponseIndicatorStyle.scan,
    );
    await tester.tap(save);
    await finishDismissal(tester);
    expect(
      container.read(appSettingsProvider).skillIndicatorStyle,
      ResponseIndicatorStyle.fold,
    );
    expectSettings(
      await SettingsService.loadSettings(),
      thinking: ResponseIndicatorStyle.scan,
      skill: ResponseIndicatorStyle.fold,
    );

    await openSheet(tester, 'Response finishes');
    for (final style in ResponseFinishStyle.values) {
      expect(choice(style.label), findsOneWidget);
    }
    await tester.tap(choice('Shrink and fade'));
    await tester.pump();
    expect(sheet, findsOneWidget);
    expectSettings(
      container.read(appSettingsProvider),
      thinking: ResponseIndicatorStyle.scan,
      skill: ResponseIndicatorStyle.fold,
    );
    expectSettings(
      await SettingsService.loadSettings(),
      thinking: ResponseIndicatorStyle.scan,
      skill: ResponseIndicatorStyle.fold,
    );
    await tester.tap(save);
    await finishDismissal(tester);
    expect(
      container.read(appSettingsProvider).responseFinishStyle,
      ResponseFinishStyle.shrink,
    );
    expectSettings(
      await SettingsService.loadSettings(),
      thinking: ResponseIndicatorStyle.scan,
      skill: ResponseIndicatorStyle.fold,
      finish: ResponseFinishStyle.shrink,
    );
    expect(find.text('Shrink and fade'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final dismissal in ['Cancel', 'back', 'swipe']) {
    testWidgets('$dismissal discards every animation draft', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.setThinkingIndicatorStyle(ResponseIndicatorStyle.gather);
      await notifier.setSkillIndicatorStyle(ResponseIndicatorStyle.fold);
      await notifier.setResponseFinishStyle(ResponseFinishStyle.shrink);
      await tester.pumpWidget(harness(container));
      await tester.pump(const Duration(milliseconds: 300));
      for (final (title, draft) in [
        ('Thinking', '04 Scan'),
        ('Using a skill', '14 Exchange'),
        ('Response finishes', 'Clear immediately'),
      ]) {
        await openSheet(tester, title);
        await tester.tap(choice(draft));
        await tester.pump(const Duration(milliseconds: 100));
        expect(sheet, findsOneWidget);
        switch (dismissal) {
          case 'Cancel':
            await tester.tap(cancel);
          case 'back':
            await tester.binding.handlePopRoute();
          case 'swipe':
            await tester.fling(headerPreview, const Offset(0, 600), 1000);
        }
        await finishDismissal(tester);
        expectSettings(
          container.read(appSettingsProvider),
          thinking: ResponseIndicatorStyle.gather,
          skill: ResponseIndicatorStyle.fold,
          finish: ResponseFinishStyle.shrink,
        );
        expectSettings(
          await SettingsService.loadSettings(),
          thinking: ResponseIndicatorStyle.gather,
          skill: ResponseIndicatorStyle.fold,
          finish: ResponseFinishStyle.shrink,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  for (final (title, initial, next, choices) in [
    (
      'Thinking',
      ResponseIndicatorStyle.facets,
      ResponseIndicatorStyle.scan,
      ResponseIndicatorStyle.thinkingChoices,
    ),
    (
      'Using a skill',
      ResponseIndicatorStyle.exchange,
      ResponseIndicatorStyle.fold,
      ResponseIndicatorStyle.skillChoices,
    ),
  ]) {
    testWidgets(
      '$title uses one shared preview and replays the selected choice',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await tester.pumpWidget(harness(container));
        await tester.pump(const Duration(milliseconds: 300));
        await openSheet(tester, title);
        final preview = find.descendant(
          of: headerPreview,
          matching: find.byType(ResponseActivityIndicator),
        );
        expect(
          find.descendant(
            of: sheet,
            matching: find.byType(ResponseActivityIndicator),
          ),
          findsOneWidget,
        );
        expect(
          tester.widget<ResponseActivityIndicator>(preview).style,
          initial,
        );
        expect(tester.widget<ResponseActivityIndicator>(preview).size, 48);
        for (final style in choices) {
          expect(
            tester.widget<AdaptiveSelectionTile>(choice(style.label)).leading,
            isNull,
          );
        }
        await tester.tap(choice(next.label));
        await tester.pump();
        expect(tester.widget<ResponseActivityIndicator>(preview).style, next);
        expect(activityPainter(tester, preview).progress.value, 0);
        await tester.pump(const Duration(milliseconds: 150));
        expect(activityPainter(tester, preview).progress.value, greaterThan(0));
        final runningState = tester.state(preview);
        await tester.tap(choice(next.label));
        await tester.pump();
        expect(tester.state(preview), isNot(same(runningState)));
        expect(activityPainter(tester, preview).progress.value, 0);
        expectSettings(container.read(appSettingsProvider));
        await tester.tap(cancel);
        await finishDismissal(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('renders phone settings in both themes with enlarged text', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final bytes = ByteData.sublistView(
        File('design-previews/hermes-thinking/fonts/Roboto-Regular.ttf')
            .readAsBytesSync(),
      );
      for (final family in ['Roboto', 'Ahem']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final capture = GlobalKey();
    for (final dark in [true, false]) {
      await tester.pumpWidget(
        harness(container, dark: dark, textScale: 1.3, capture: capture),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.text('Response finishes'), findsOneWidget);
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final destination = File(
          'output/response-animations/settings-${dark ? 'dark' : 'light'}.png',
        );
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      for (final title in ['Thinking', 'Using a skill', 'Response finishes']) {
        await openSheet(tester, title);
        expect(tester.takeException(), isNull);
        expect(tester.getRect(save).bottom, lessThanOrEqualTo(760));
        expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(760));
        final tiles = find.descendant(
          of: sheet,
          matching: find.byType(AdaptiveSelectionTile),
        );
        for (final tile in tiles.evaluate()) {
          expect(
            tester.getSize(find.byWidget(tile.widget)).height,
            greaterThanOrEqualTo(48),
          );
        }
        await tester.tap(cancel);
        await finishDismissal(tester);
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('one finish preview replays each exit and same-option taps', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(harness(container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await openSheet(tester, 'Response finishes');

    final preview = find.descendant(
      of: sheet,
      matching: find.byType(ResponseFinishPreview),
    );
    expect(preview, findsOneWidget);
    expect(find.byType(ResponseFinishPreview), findsNWidgets(2));
    expect(tester.widget<ResponseFinishPreview>(preview).size, 48);
    expect(
      tester.widget<ResponseFinishPreview>(preview).indicatorStyle,
      ResponseIndicatorStyle.facets,
    );
    for (final style in ResponseFinishStyle.values) {
      expect(
        tester.widget<AdaptiveSelectionTile>(choice(style.label)).leading,
        isNull,
      );
      for (var replay = 0; replay < 2; replay++) {
        final previousToken = tester
            .widget<ResponseFinishPreview>(preview)
            .replayToken;
        await tester.tap(choice(style.label));
        await tester.pump();
        expect(sheet, findsOneWidget);
        expect(tester.widget<ResponseFinishPreview>(preview).style, style);
        expect(
          tester.widget<ResponseFinishPreview>(preview).replayToken,
          previousToken + 1,
        );
        expect(finishTransition(tester).progress.value, 1);
        await tester.pump(const Duration(milliseconds: 50));
        expect(finishTransition(tester).progress.value, closeTo(.75, .001));
        final fade = tester.widget<FadeTransition>(
          find.descendant(of: preview, matching: find.byType(FadeTransition)),
        );
        expect(
          fade.opacity.value,
          style == ResponseFinishStyle.clear
              ? 0
              : closeTo(Curves.easeOutCubic.transform(.75), .001),
        );
        final scale = find.descendant(
          of: preview,
          matching: find.byType(ScaleTransition),
        );
        if (style == ResponseFinishStyle.shrink) {
          expect(
            tester.widget<ScaleTransition>(scale).scale.value,
            closeTo(.93, .001),
          );
        } else {
          expect(scale, findsNothing);
        }
        await tester.pump(const Duration(milliseconds: 150));
        expect(finishTransition(tester).progress.value, closeTo(0, .001));
        expectSettings(container.read(appSettingsProvider));
        expectSettings(await SettingsService.loadSettings());
      }
    }
    await tester.tap(cancel);
    await finishDismissal(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.takeException(), isNull);
  });

  for (final (name, appReducedMotion, platformFeatures, disableAnimations) in [
    ('app setting', true, const FakeAccessibilityFeatures(), false),
    (
      'system disable animations',
      false,
      const FakeAccessibilityFeatures(disableAnimations: true),
      false,
    ),
    (
      'system reduced motion',
      false,
      const FakeAccessibilityFeatures(reduceMotion: true),
      false,
    ),
    ('MediaQuery override', false, const FakeAccessibilityFeatures(), true),
  ]) {
    testWidgets(
      '$name keeps shared previews static after selection and replay',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            platformFeatures;
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await SettingsService.setReduceMotion(appReducedMotion);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await tester.pumpWidget(
          harness(container, disableAnimations: disableAnimations),
        );
        await tester.pump(const Duration(milliseconds: 300));
        for (final indicator in tester.widgetList<ResponseActivityIndicator>(
          find.byType(ResponseActivityIndicator),
        )) {
          expect(indicator.animate, isFalse);
        }
        expect(
          tester
              .widget<ResponseFinishPreview>(find.byType(ResponseFinishPreview))
              .animate,
          isFalse,
        );
        for (final (title, draft) in [
          ('Thinking', '04 Scan'),
          ('Using a skill', '06 Fold'),
          ('Response finishes', 'Clear immediately'),
        ]) {
          await openSheet(tester, title);
          for (var replay = 0; replay < 2; replay++) {
            await tester.tap(choice(draft));
            await tester.pump();
            final painter = activityPainter(tester, headerPreview);
            final progress = painter.progress.value;
            expect(
              progress,
              closeTo(420 / painter.style.cycleMilliseconds, .001),
            );
            if (title == 'Response finishes') {
              expect(finishTransition(tester).progress.value, 1);
            }
            await tester.pump(const Duration(milliseconds: 500));
            expect(
              activityPainter(tester, headerPreview).progress.value,
              progress,
            );
            if (title == 'Response finishes') {
              expect(finishTransition(tester).progress.value, 1);
            }
          }
          expectSettings(container.read(appSettingsProvider));
          await tester.tap(cancel);
          await finishDismissal(tester);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'finish preview pauses when hidden or backgrounded and respects reduced motion',
    (tester) async {
      Widget preview({bool visible = true, bool animate = true}) => MaterialApp(
        home: TickerMode(
          enabled: visible,
          child: ResponseFinishPreview(
            style: ResponseFinishStyle.fade,
            indicatorStyle: ResponseIndicatorStyle.facets,
            color: Colors.white,
            animate: animate,
          ),
        ),
      );
      double exit() => tester
          .widget<ResponseFinishTransition>(
            find.byType(ResponseFinishTransition),
          )
          .progress
          .value;
      await tester.pumpWidget(preview());
      await tester.pump(const Duration(milliseconds: 1250));
      final midExit = exit();
      expect(midExit, closeTo(.75, .01));
      await tester.pumpWidget(preview(visible: false));
      await tester.pump(const Duration(milliseconds: 500));
      expect(exit(), midExit);
      await tester.pumpWidget(preview());
      await tester.pump(const Duration(milliseconds: 100));
      expect(exit(), lessThan(midExit));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final pausedExit = exit();
      await tester.pump(const Duration(milliseconds: 500));
      expect(exit(), pausedExit);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(exit(), lessThan(pausedExit));
      await tester.pumpWidget(preview(animate: false));
      await tester.pump(const Duration(seconds: 3));
      expect(exit(), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
