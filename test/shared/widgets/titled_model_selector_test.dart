import 'package:checks/checks.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/foundation.dart';
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
  }) async {
    final showsTitle = ValueNotifier<bool>(false);
    addTearDown(showsTitle.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat)
            .copyWith(platform: TargetPlatform.iOS),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(
            body: Center(
              child: ConduitAdaptiveAppBarModelSelector(
                label: 'GPT-5 Mini',
                title: title,
                showsTitle: showsTitle,
                maxWidth: 260,
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
}
