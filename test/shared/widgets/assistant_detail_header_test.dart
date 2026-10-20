import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/assistant_detail_header.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildHarness({required bool showShimmer}) {
    return MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      home: Scaffold(
        body: Center(
          child: AssistantDetailHeader(
            title: 'Thinking',
            showShimmer: showShimmer,
          ),
        ),
      ),
    );
  }

  testWidgets('a pending header shimmers until it settles', (tester) async {
    await tester.pumpWidget(buildHarness(showShimmer: true));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.hasRunningAnimations, isTrue);
    expect(find.byType(ShaderMask), findsOneWidget);

    // Settling can only finish once the repeating shimmer has stopped.
    await tester.pumpWidget(buildHarness(showShimmer: false));
    await tester.pumpAndSettle();

    expect(find.byType(ShaderMask), findsNothing);
    expect(find.text('Thinking'), findsOneWidget);
  });

  testWidgets('reduced motion keeps a pending header still', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(buildHarness(showShimmer: true));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byType(ShaderMask), findsNothing);
    expect(find.text('Thinking'), findsOneWidget);
  });
}
