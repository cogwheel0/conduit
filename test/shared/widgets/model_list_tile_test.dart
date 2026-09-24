import 'package:checks/checks.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/horizontal_overflow_fade.dart';
import 'package:conduit/shared/widgets/model_list_tile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _reasoningModel = Model(
  id: 'reasoning-model',
  name: 'Reasoning model',
  supportedParameters: ['reasoning'],
);

Future<ConduitThemeExtension> _pumpTile(
  WidgetTester tester, {
  required bool isSelected,
}) async {
  late ConduitThemeExtension theme;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(TweakcnThemes.conduit),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            theme = context.conduitTheme;
            return ConduitCard(
              child: ModelListTile(
                model: _reasoningModel,
                isSelected: isSelected,
                onTap: () {},
              ),
            );
          },
        ),
      ),
    ),
  );
  return theme;
}

void main() {
  testWidgets('the metadata row keeps its trailing overflow cue', (
    tester,
  ) async {
    await _pumpTile(tester, isSelected: false);

    check(find.byType(HorizontalOverflowFade).evaluate()).length.equals(1);
  });

  testWidgets('a settled metadata row paints no fade', (tester) async {
    await _pumpTile(tester, isSelected: false);
    await tester.pump();

    // The cue is surface independent now, so the only thing that may paint it
    // is real trailing overflow. A row that fits must stay clean, whether the
    // cue would mask the row or paint a gradient over it.
    final fade = find.byType(HorizontalOverflowFade);
    check(
      find.descendant(of: fade, matching: find.byType(ShaderMask)).evaluate(),
    ).isEmpty();
    check(
      tester
          .widgetList<DecoratedBox>(
            find.descendant(of: fade, matching: find.byType(DecoratedBox)),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .where((decoration) => decoration.gradient != null),
    ).isEmpty();
  });

  testWidgets('the selected row highlight paints against the card surface', (
    tester,
  ) async {
    final theme = await _pumpTile(tester, isSelected: true);
    final highlighted = Color.alphaBlend(
      theme.buttonPrimary.withValues(alpha: 0.1),
      theme.cardBackground,
    );
    final surfaceHighlighted = Color.alphaBlend(
      theme.buttonPrimary.withValues(alpha: 0.1),
      theme.surfaceBackground,
    );

    check(highlighted).not((it) => it.equals(surfaceHighlighted));

    final tile = find.byType(ModelListTile);
    final containers = tester.widgetList<Container>(
      find.descendant(of: tile, matching: find.byType(Container)),
    );
    final rowBackgrounds = containers
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .map((decoration) => decoration.color);
    check(rowBackgrounds).contains(highlighted);
  });
}
