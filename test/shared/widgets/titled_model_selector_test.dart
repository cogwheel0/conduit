import 'package:checks/checks.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  setUp(() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
  });
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  Future<ValueNotifier<bool>> pumpPill(
    WidgetTester tester, {
    String? title = 'Sourdough plan',
    bool disableAnimations = false,
    VoidCallback? onPressed,
    double maxWidth = 260,
    double textScale = 1,
  }) async {
    final showsTitle = ValueNotifier<bool>(false);
    addTearDown(showsTitle.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat)
            .copyWith(platform: TargetPlatform.iOS),
        home: MediaQuery(
          data: MediaQueryData(
            disableAnimations: disableAnimations,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Center(
              child: ConduitAdaptiveAppBarModelSelector(
                label: 'GPT-5 Mini',
                title: title,
                showsTitle: showsTitle,
                maxWidth: maxWidth,
                onPressed: onPressed ?? () {},
              ),
            ),
          ),
        ),
      ),
    );
    return showsTitle;
  }

  double opacityOf(WidgetTester tester, String text) {
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first,
    );
    return opacity.opacity;
  }

  testWidgets('at rest the pill names only the model', (tester) async {
    await pumpPill(tester);

    expect(find.text('GPT-5 Mini'), findsOneWidget);
    expect(find.text('Sourdough plan'), findsNothing);
  });

  testWidgets('scrolled under the bar it names the chat over the model', (
    tester,
  ) async {
    final showsTitle = await pumpPill(tester);
    final restingWidth = tester
        .getSize(find.byType(ConduitAdaptiveAppBarModelSelector))
        .width;

    showsTitle.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    // Mid-way: both lines are on screen while the spring runs.
    expect(find.text('Sourdough plan'), findsOneWidget);
    await tester.pumpAndSettle();

    expect(find.text('Sourdough plan'), findsOneWidget);
    // The model stays in the pill as the smaller second line.
    expect(find.text('GPT-5 Mini'), findsOneWidget);
    final title = tester.widget<Text>(find.text('Sourdough plan'));
    check(title.overflow).equals(TextOverflow.ellipsis);
    check(title.style?.fontWeight).equals(FontWeight.w600);
    final titledWidth = tester
        .getSize(find.byType(ConduitAdaptiveAppBarModelSelector))
        .width;
    check(titledWidth).isGreaterThan(restingWidth);

    showsTitle.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Sourdough plan'), findsNothing);
    check(tester.getSize(find.byType(ConduitAdaptiveAppBarModelSelector)).width)
        .equals(restingWidth);
  });

  testWidgets('a reversal mid-way returns without finishing first', (
    tester,
  ) async {
    final showsTitle = await pumpPill(tester);

    showsTitle.value = true;
    await tester.pump(const Duration(milliseconds: 80));
    showsTitle.value = false;
    await tester.pump(const Duration(milliseconds: 16));
    // Still heading back from where it was: the model line never vanished.
    check(opacityOf(tester, 'GPT-5 Mini')).isGreaterThan(0);
    await tester.pumpAndSettle();
    expect(find.text('Sourdough plan'), findsNothing);
  });

  testWidgets('Reduce Motion cross-fades without moving the lines', (
    tester,
  ) async {
    final showsTitle = await pumpPill(tester, disableAnimations: true);

    showsTitle.value = true;
    await tester.pump(const Duration(milliseconds: 150));
    final shifts = tester
        .widgetList<Transform>(
          find.ancestor(
            of: find.text('Sourdough plan'),
            matching: find.byType(Transform),
          ),
        )
        .map((transform) => transform.transform.getTranslation().y);
    check(shifts.every((y) => y == 0)).isTrue();
    await tester.pumpAndSettle();
    expect(find.text('Sourdough plan'), findsOneWidget);
  });

  testWidgets('a chat without a title keeps the model alone', (tester) async {
    final showsTitle = await pumpPill(tester, title: null);

    showsTitle.value = true;
    await tester.pumpAndSettle();
    expect(find.text('GPT-5 Mini'), findsOneWidget);
    check(opacityOf(tester, 'GPT-5 Mini')).equals(1);
  });

  testWidgets('either state is one tap from the model picker', (tester) async {
    var taps = 0;
    final semantics = tester.ensureSemantics();
    final showsTitle = await pumpPill(tester, onPressed: () => taps++);

    await tester.tap(find.byType(ConduitAdaptiveAppBarModelSelector));
    showsTitle.value = true;
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Sourdough plan, GPT-5 Mini'), findsOneWidget);
    await tester.tap(find.byType(ConduitAdaptiveAppBarModelSelector));

    check(taps).equals(2);
    semantics.dispose();
  });

  group('a title too long for the pill', () {
    Text titleText(WidgetTester tester) => tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.style?.fontWeight == FontWeight.w600 &&
            widget.data != null,
      ),
    );

    Future<void> showTitle(
      WidgetTester tester,
      String title, {
      double maxWidth = 280,
    }) async {
      final showsTitle = await pumpPill(
        tester,
        title: title,
        maxWidth: maxWidth,
      );
      showsTitle.value = true;
      await tester.pumpAndSettle();
    }

    testWidgets('a title that fits stays at 15 pt', (tester) async {
      await showTitle(tester, 'Herb care tips');
      final text = titleText(tester);
      check(text.data).equals('Herb care tips');
      check(text.style!.fontSize).equals(15);
    });

    testWidgets('is set a little smaller before anything is cut', (
      tester,
    ) async {
      // 18 glyphs: too wide for 252 pt of text at 15 pt, whole at 14 pt.
      await showTitle(tester, 'Basil on the sills');
      final text = titleText(tester);
      check(text.data).equals('Basil on the sills');
      check(text.style!.fontSize!).isLessThan(15);
      check(text.style!.fontSize!).isGreaterOrEqual(13);
    });

    testWidgets('then ends after its last whole word, never mid-word', (
      tester,
    ) async {
      const title = 'Sourdough starter schedule for a cool kitchen';
      await showTitle(tester, title);
      final text = titleText(tester);
      // At 15 pt only "Sourdough…" fits; a size smaller keeps a word more.
      check(text.data).equals('Sourdough starter\u2026');
      check(text.style!.fontSize!).isLessThan(15);
      check(text.style!.fontSize!).isGreaterOrEqual(13);
      // The pill stays within its room, and VoiceOver hears the whole title.
      check(
        tester.getSize(find.byType(ConduitAdaptiveAppBarModelSelector)).width,
      ).isLessOrEqual(280);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('$title, GPT-5 Mini'), findsOneWidget);
      semantics.dispose();
    });
  });

  testWidgets('stays at 15 pt when smaller would show no more of it', (
    tester,
  ) async {
    final showsTitle = await pumpPill(
      tester,
      title: 'Sourdough starter schedule for a cool kitchen',
      maxWidth: 300,
    );
    showsTitle.value = true;
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.textContaining('Sourdough starter'));
    check(text.data).equals('Sourdough starter\u2026');
    check(text.style!.fontSize).equals(15);
  });

  testWidgets('at large text sizes the title grows only so far', (
    tester,
  ) async {
    final showsTitle = await pumpPill(
      tester,
      title: 'Sourdough starter schedule',
      maxWidth: 220,
      textScale: 2,
    );
    showsTitle.value = true;
    await tester.pumpAndSettle();
    // Still whole words, and set at no more than 1.2 times 15 pt.
    final title = find.text('Sourdough\u2026');
    expect(title, findsOneWidget);
    check(tester.getSize(title).height).isCloseTo(15 * 1.2 * 1.2, 0.5);
  });

  group('conduitTruncateAtWordBoundary', () {
    // One unit per character, so widths are lengths.
    double measure(String text) => text.characters.length.toDouble();

    test('leaves a title that fits alone', () {
      check(
        conduitTruncateAtWordBoundary(
          'Quick Sleep Tips',
          maxWidth: 16,
          measure: measure,
        ),
      ).equals('Quick Sleep Tips');
    });

    test('cuts after the last whole word that fits', () {
      check(
        conduitTruncateAtWordBoundary(
          'Sourdough starter schedule',
          maxWidth: 22,
          measure: measure,
        ),
      ).equals('Sourdough starter\u2026');
    });

    test('drops a dangling comma or dash before the ellipsis', () {
      check(
        conduitTruncateAtWordBoundary(
          'Porto, Lisbon and Sintra in a week',
          maxWidth: 16,
          measure: measure,
        ),
      ).equals('Porto, Lisbon\u2026');
      check(
        conduitTruncateAtWordBoundary(
          'Herbs \u2014 what grows indoors',
          maxWidth: 10,
          measure: measure,
        ),
      ).equals('Herbs\u2026');
    });

    test('cuts between characters when words would waste the room', () {
      // One long word: whole words would keep only "A…".
      check(
        conduitTruncateAtWordBoundary(
          'A counterproductiveness study',
          maxWidth: 12,
          measure: measure,
        ),
      ).equals('A counterpr\u2026');
      // Scripts written without spaces.
      check(
        conduitTruncateAtWordBoundary(
          '\u9178\u7a2e\u306e\u80b2\u3066\u65b9\u3068\u7ba1\u7406',
          maxWidth: 5,
          measure: measure,
        ),
      ).equals('\u9178\u7a2e\u306e\u80b2\u2026');
    });
  });

  test('tracking follows the system text styles', () {
    check(conduitSystemTextTracking(17)).equals(-0.43);
    check(conduitSystemTextTracking(15)).equals(-0.23);
    check(conduitSystemTextTracking(12)).equals(0);
    check(conduitSystemTextTracking(14.5)).isCloseTo(-0.19, 1e-9);
  });
}
