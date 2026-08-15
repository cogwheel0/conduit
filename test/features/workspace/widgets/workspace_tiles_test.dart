import 'package:conduit/features/workspace/widgets/workspace_tiles.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets('non-grouped Cupertino resource tile keeps selection tint', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: const Scaffold(
          body: WorkspaceResourceTile(
            key: ValueKey('selected-resource'),
            icon: Icons.history,
            title: 'Version',
            selected: true,
            grouped: false,
          ),
        ),
      ),
    );

    final tile = find.byKey(const ValueKey('selected-resource'));
    final container = tester.widget<AnimatedContainer>(
      find.descendant(of: tile, matching: find.byType(AnimatedContainer)),
    );
    final theme = tester.element(tile).conduitTheme;
    expect(
      (container.decoration as BoxDecoration).color,
      theme.buttonPrimary.withValues(alpha: 0.1),
    );
  });
}
