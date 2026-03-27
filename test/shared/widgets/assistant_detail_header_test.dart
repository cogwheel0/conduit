import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/assistant_detail_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildHarness({
    required bool showShimmer,
    bool disableAnimations = false,
  }) {
    return MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: Scaffold(
          body: Center(
            child: AssistantDetailHeader(
              title: 'Thinking',
              showShimmer: showShimmer,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('pending header settles under widget-test bindings', (
    tester,
  ) async {
    await tester.pumpWidget(buildHarness(showShimmer: true));
    await tester.pumpAndSettle();

    expect(find.text('Thinking'), findsOneWidget);
  });

  testWidgets('reduced motion skips shimmer entirely', (tester) async {
    await tester.pumpWidget(
      buildHarness(showShimmer: true, disableAnimations: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Thinking'), findsOneWidget);
  });

  testWidgets('still renders the plain header when shimmer is disabled', (
    tester,
  ) async {
    await tester.pumpWidget(buildHarness(showShimmer: false));

    expect(find.text('Thinking'), findsOneWidget);
  });
}
