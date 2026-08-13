import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/chrome_gradient_fade.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('chrome fade combines backdrop blur with its gradient', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: const Scaffold(
          body: Stack(
            children: [
              Text('Scrolling content'),
              ConduitChromeGradientFade.top(contentHeight: 80),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(find.byType(DecoratedBox), findsWidgets);
    final fade = find.byType(ConduitChromeGradientFade);
    expect(
      find.descendant(of: fade, matching: find.byType(IgnorePointer)),
      findsOneWidget,
    );
  });
}
