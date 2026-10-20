import 'package:conduit/features/chat/widgets/composer_overflow_menu.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('a toggle row is activatable by screen readers', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: Scaffold(
          body: Builder(
            builder: (context) => ToggleTile(
              glyph: const Icon(Icons.search),
              title: 'Web Search',
              subtitle: 'Search the web',
              selected: false,
              onToggle: () => toggles++,
              theme: context.conduitTheme,
            ),
          ),
        ),
      ),
    );

    // The labelled node replaces the InkWell's, so it must carry the tap.
    tester.semantics.tap(find.semantics.byLabel('Web Search'));
    expect(toggles, 1);
  });
}
