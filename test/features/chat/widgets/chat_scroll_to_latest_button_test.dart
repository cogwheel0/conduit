import 'package:checks/checks.dart';
import 'package:conduit/features/chat/widgets/chat_scroll_to_latest_button.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const buttonKey = ValueKey('button');

  Future<void> pumpButton(
    WidgetTester tester, {
    required bool visible,
    bool disableAnimations = false,
    bool quickExit = false,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(
            body: Center(
              child: ChatScrollToLatestButton(
                visible: visible,
                quickExit: quickExit,
                dimension: 40,
                child: const SizedBox.square(key: buttonKey, dimension: 40),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double opacity(WidgetTester tester) => tester
      .widget<Opacity>(
        find.ancestor(
          of: find.byKey(buttonKey),
          matching: find.byType(Opacity),
        ),
      )
      .opacity;

  double rise(WidgetTester tester) => tester
      .widget<Transform>(
        find
            .ancestor(
              of: find.byKey(buttonKey),
              matching: find.byType(Transform),
            )
            .first,
      )
      .transform
      .getTranslation()
      .y;

  testWidgets('hidden, it keeps its place but drops the button', (
    tester,
  ) async {
    await pumpButton(tester, visible: false);

    expect(find.byKey(buttonKey), findsNothing);
    check(tester.getSize(find.byType(ChatScrollToLatestButton)).height)
        .equals(kChatScrollToLatestComposerGap + 40);
  });

  testWidgets('it rises and fades in without overshooting', (tester) async {
    await pumpButton(tester, visible: false);
    await pumpButton(tester, visible: true);

    var lastRise = double.infinity;
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final y = rise(tester);
      // Critically damped: it only ever closes on its resting place.
      check(y).isGreaterOrEqual(0);
      check(y).isLessOrEqual(lastRise);
      lastRise = y;
    }
    await tester.pumpAndSettle();
    check(opacity(tester)).equals(1);
    check(rise(tester)).equals(0);
  });

  testWidgets('it leaves the way it came and stops taking taps', (
    tester,
  ) async {
    await pumpButton(tester, visible: true);
    await pumpButton(tester, visible: false);
    await tester.pump(const Duration(milliseconds: 50));

    check(rise(tester)).isGreaterThan(0);
    final ignore = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byKey(buttonKey),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    check(ignore.ignoring).isTrue();
    await tester.pumpAndSettle();
    expect(find.byKey(buttonKey), findsNothing);
  });

  testWidgets('a send takes it away in the frame it is shown in', (
    tester,
  ) async {
    await pumpButton(tester, visible: true);
    await pumpButton(tester, visible: false, quickExit: true);
    // Gone at once: no native button left fading under the message that
    // flies up across its place.
    expect(find.byKey(buttonKey), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(buttonKey), findsNothing);

    // It comes back on its spring when it is wanted again.
    await pumpButton(tester, visible: true);
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(buttonKey), findsOneWidget);
    check(opacity(tester)).isGreaterThan(0);
    await tester.pumpAndSettle();
    check(opacity(tester)).equals(1);
  });

  testWidgets('Reduce Motion only fades it', (tester) async {
    await pumpButton(tester, visible: false, disableAnimations: true);
    await pumpButton(tester, visible: true, disableAnimations: true);
    await tester.pump(const Duration(milliseconds: 60));

    check(opacity(tester)).isGreaterThan(0);
    check(opacity(tester)).isLessThan(1);
    check(rise(tester)).equals(0);
    await tester.pumpAndSettle();
    check(opacity(tester)).equals(1);
  });

  testWidgets('it floats over the transcript: nothing opaque behind it', (
    tester,
  ) async {
    await pumpButton(tester, visible: true);

    check(
      find
          .descendant(
            of: find.byType(ChatScrollToLatestButton),
            matching: find.byType(DecoratedBox),
          )
          .evaluate(),
    ).isEmpty();
  });
}
