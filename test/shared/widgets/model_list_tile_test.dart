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
  Model model = _reasoningModel,
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
                model: model,
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

  testWidgets('selection is a trailing checkmark, not a row fill', (
    tester,
  ) async {
    final theme = await _pumpTile(tester, isSelected: true);

    final tile = find.byType(ModelListTile);
    final containers = tester.widgetList<Container>(
      find.descendant(of: tile, matching: find.byType(Container)),
    );
    final rowBackgrounds = containers
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .map((decoration) => decoration.color)
        .whereType<Color>();
    check(rowBackgrounds).not(
      (it) => it.contains(
        Color.alphaBlend(
          theme.buttonPrimary.withValues(alpha: 0.1),
          theme.cardBackground,
        ),
      ),
    );
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });

  testWidgets("a model one of the user's devices offers names the device", (
    tester,
  ) async {
    // As Open WebUI 0.13.4 lists it: `connection_type: local`, as the
    // server's own connections can be, says nothing about where it runs.
    final model = Model.fromJson(const <String, dynamic>{
      'id': 'qwen3:8b',
      'name': 'qwen3:8b',
      'owned_by': 'openai',
      'connection_type': 'local',
      'tags': <dynamic>[
        <String, dynamic>{'name': 'Studio Mac · Garage lab'},
      ],
      'owner_id': 'user-1',
      'base_url': 'tether://3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d',
      'service': 'garage_lab',
    });

    await _pumpTile(tester, isSelected: false, model: model);

    // Once, where it comes from, rather than again as a tag.
    check(find.text('Studio Mac · Garage lab').evaluate()).length.equals(1);
    check(find.text('STUDIO MAC · GARAGE LAB').evaluate()).isEmpty();
  });
}
