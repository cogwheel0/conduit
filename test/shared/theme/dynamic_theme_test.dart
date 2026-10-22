import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/color_tokens.dart';
import 'package:conduit/shared/theme/conduit_button_styles.dart';
import 'package:conduit/shared/theme/conduit_input_styles.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('Material You is opt-in and unavailable colors use Conduit', () {
    expect(TweakcnThemes.byId(null), same(TweakcnThemes.conduit));
    expect(TweakcnThemes.byId('unknown'), same(TweakcnThemes.conduit));
    expect(TweakcnThemes.byId('material_you'), same(TweakcnThemes.materialYou));
    for (final brightness in Brightness.values) {
      final fallback = _theme(TweakcnThemes.conduit, brightness);
      final dynamicFallback = _theme(TweakcnThemes.materialYou, brightness);
      expect(dynamicFallback.colorScheme, fallback.colorScheme);
      expect(
        dynamicFallback.inputDecorationTheme,
        fallback.inputDecorationTheme,
      );
      expect(
        dynamicFallback.extension<AppPaletteThemeExtension>()!.palette.id,
        'material_you',
      );
    }
  });

  test('an explicit saved palette takes precedence over platform colors', () {
    final platform = ColorScheme.fromSeed(seedColor: const Color(0xFF006B50));
    for (final palette in TweakcnThemes.all.where(
      (p) => !p.usesDynamicColors,
    )) {
      expect(TweakcnThemes.byId(palette.id), same(palette));
      for (final brightness in Brightness.values) {
        final supplied = platform.copyWith(brightness: brightness);
        final standard = _theme(palette, brightness);
        final injected = _theme(palette, brightness, supplied);
        expect(injected.colorScheme, standard.colorScheme);
        expect(
          injected.extension<ConduitThemeExtension>()!.variant,
          same(palette.variantFor(brightness)),
        );
      }
    }
  });

  for (final seed in [const Color(0xFF006B50), const Color(0xFF744EAE)]) {
    for (final brightness in Brightness.values) {
      test(
        'system scheme drives Material and custom roles: $seed $brightness',
        () {
          final scheme = ColorScheme.fromSeed(
            seedColor: seed,
            brightness: brightness,
          );
          final theme = _theme(TweakcnThemes.materialYou, brightness, scheme);
          final conduit = theme.extension<ConduitThemeExtension>()!;
          final tokens = theme.extension<AppColorTokens>()!;
          const selected = {WidgetState.selected};

          expect(theme.colorScheme, scheme);
          expect(theme.extension<AppPaletteThemeExtension>()!.palette.preview, [
            scheme.primary,
            scheme.secondaryContainer,
            scheme.tertiaryContainer,
          ]);
          expect(conduit.buttonPrimary, scheme.primary);
          expect(conduit.buttonPrimaryText, scheme.onPrimary);
          expect(conduit.surfaceBackground, scheme.surface);
          expect(conduit.surfaceContainer, scheme.surfaceContainer);
          expect(
            conduit.surfaceContainerHighest,
            scheme.surfaceContainerHighest,
          );
          expect(conduit.surfaces.popover, scheme.surfaceContainerHigh);
          expect(tokens.brandTone60, scheme.primary);
          expect(conduit.selectionBackground, scheme.secondaryContainer);
          expect(conduit.selectionForeground, scheme.onSecondaryContainer);
          expect(theme.dialogTheme.backgroundColor, conduit.surfaces.popover);
          expect(theme.popupMenuTheme.color, conduit.surfaces.popover);
          expect(
            theme.menuTheme.style!.backgroundColor!.resolve({}),
            conduit.surfaces.popover,
          );
          expect(
            theme.dropdownMenuTheme.inputDecorationTheme,
            theme.inputDecorationTheme,
          );
          expect(
            theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
            conduit.buttonPrimary,
          );
          expect(
            theme.filledButtonTheme.style!.foregroundColor!.resolve({}),
            conduit.buttonPrimaryText,
          );
          expect(
            theme.switchTheme.trackColor!.resolve(selected),
            scheme.primary,
          );
          expect(
            theme.switchTheme.thumbColor!.resolve(selected),
            scheme.onPrimary,
          );
          expect(
            theme.checkboxTheme.fillColor!.resolve(selected),
            scheme.primary,
          );
          expect(
            theme.checkboxTheme.checkColor!.resolve(selected),
            scheme.onPrimary,
          );
          expect(theme.textSelectionTheme.cursorColor, scheme.primary);
          expect(theme.textSelectionTheme.selectionHandleColor, scheme.primary);
          expect(theme.chipTheme.selectedColor, conduit.selectionBackground);
          expect(
            theme.listTileTheme.selectedTileColor,
            conduit.selectionBackground,
          );
          expect(
            theme.listTileTheme.selectedColor,
            conduit.selectionForeground,
          );
          expect(
            contrastRatio(
              conduit.navigationSelected,
              conduit.navigationSelectedBackground,
            ),
            greaterThanOrEqualTo(4.5),
          );

          final standard = ConduitInputStyles(conduit).standard();
          expect(standard.fillColor, theme.inputDecorationTheme.fillColor);
          expect(
            standard.enabledBorder,
            theme.inputDecorationTheme.enabledBorder,
          );
          expect(
            standard.focusedBorder,
            theme.inputDecorationTheme.focusedBorder,
          );
          expect(standard.errorBorder, theme.inputDecorationTheme.errorBorder);
          expect(
            standard.focusedErrorBorder,
            theme.inputDecorationTheme.focusedErrorBorder,
          );
          final destructive = ConduitButtonStyles(conduit).destructive();
          expect(
            contrastRatio(destructive.foreground, destructive.background),
            greaterThanOrEqualTo(4.5),
          );
        },
      );
    }
  }

  test(
    'selected states and field borders stay readable across all presets',
    () {
      for (final palette in TweakcnThemes.all) {
        for (final brightness in Brightness.values) {
          final theme = _theme(palette, brightness);
          final conduit = theme.extension<ConduitThemeExtension>()!;
          final reason = '${palette.id} $brightness';
          expect(
            contrastRatio(
              conduit.navigationSelected,
              conduit.navigationSelectedBackground,
            ),
            greaterThanOrEqualTo(4.5),
            reason: reason,
          );
          expect(
            contrastRatio(conduit.inputBorder, conduit.inputBackground),
            greaterThanOrEqualTo(3),
            reason: reason,
          );
          expect(
            contrastRatio(conduit.inputBorderFocused, conduit.inputBackground),
            greaterThanOrEqualTo(3),
            reason: reason,
          );
        }
      }
    },
  );

  testWidgets('field and dropdown inherit one dynamic decoration', (
    tester,
  ) async {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF006B50),
      brightness: Brightness.dark,
    );
    final theme = AppTheme.dark(
      TweakcnThemes.materialYou,
      dynamicScheme: scheme,
    );
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Column(
            children: [
              TextField(
                focusNode: focusNode,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              DropdownMenu<String>(
                label: const Text('Model'),
                dropdownMenuEntries: const [
                  DropdownMenuEntry(value: 'model', label: 'Model one'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final fields = tester
        .widgetList<InputDecorator>(find.byType(InputDecorator))
        .toList();
    expect(fields, hasLength(2));
    for (final field in fields) {
      expect(field.decoration.fillColor, theme.inputDecorationTheme.fillColor);
      expect(
        field.decoration.enabledBorder,
        theme.inputDecorationTheme.enabledBorder,
      );
    }
    focusNode.requestFocus();
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<InputDecorator>(find.byType(InputDecorator))
          .first
          .isFocused,
      isTrue,
    );
    await tester.tap(find.byType(TextField).last);
    await tester.pumpAndSettle();
    expect(find.text('Model one'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

ThemeData _theme(
  TweakcnThemeDefinition palette,
  Brightness brightness, [
  ColorScheme? scheme,
]) => brightness == Brightness.dark
    ? AppTheme.dark(palette, dynamicScheme: scheme)
    : AppTheme.light(palette, dynamicScheme: scheme);
