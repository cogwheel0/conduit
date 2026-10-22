import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/utils/system_ui_style.dart';
import 'theme_extensions.dart';
import 'tweakcn_themes.dart';
import 'color_tokens.dart';

class AppTheme {
  static ThemeData light(
    TweakcnThemeDefinition theme, {
    ColorScheme? dynamicScheme,
  }) => _buildMaterialTheme(theme, Brightness.light, dynamicScheme);

  static ThemeData dark(
    TweakcnThemeDefinition theme, {
    ColorScheme? dynamicScheme,
  }) => _buildMaterialTheme(theme, Brightness.dark, dynamicScheme);

  static ThemeData _buildMaterialTheme(
    TweakcnThemeDefinition theme,
    Brightness brightness,
    ColorScheme? dynamicScheme,
  ) {
    final scheme = theme.usesDynamicColors ? dynamicScheme : null;
    final resolved = theme.withDynamicColors(
      lightScheme: brightness == Brightness.light ? scheme : null,
      darkScheme: brightness == Brightness.dark ? scheme : null,
    );
    final tokens = brightness == Brightness.light
        ? AppColorTokens.light(theme: resolved)
        : AppColorTokens.dark(theme: resolved);
    return _buildTheme(
      theme: resolved,
      tokens: tokens,
      brightness: brightness,
      dynamicScheme: scheme,
    );
  }

  /// Builds a [CupertinoThemeData] for light mode.
  static CupertinoThemeData cupertinoLight(
    TweakcnThemeDefinition theme, {
    ColorScheme? dynamicScheme,
  }) {
    final resolved = theme.withDynamicColors(lightScheme: dynamicScheme);
    final variant = resolved.variantFor(Brightness.light);
    final tokens = AppColorTokens.light(theme: resolved);
    return _buildCupertinoThemeData(
      brightness: Brightness.light,
      variant: variant,
      tokens: tokens,
    );
  }

  /// Builds a [CupertinoThemeData] for dark mode.
  static CupertinoThemeData cupertinoDark(
    TweakcnThemeDefinition theme, {
    ColorScheme? dynamicScheme,
  }) {
    final resolved = theme.withDynamicColors(darkScheme: dynamicScheme);
    final variant = resolved.variantFor(Brightness.dark);
    final tokens = AppColorTokens.dark(theme: resolved);
    return _buildCupertinoThemeData(
      brightness: Brightness.dark,
      variant: variant,
      tokens: tokens,
    );
  }

  static ThemeData _buildTheme({
    required TweakcnThemeDefinition theme,
    required AppColorTokens tokens,
    required Brightness brightness,
    ColorScheme? dynamicScheme,
  }) {
    final variant = theme.variantFor(brightness);
    final isDark = brightness == Brightness.dark;
    final surfaces = dynamicScheme == null
        ? SurfaceThemeExtension.fromVariant(variant)
        : SurfaceThemeExtension.fromColorScheme(dynamicScheme);
    final shadows = ShadowThemeExtension.standard();
    final shapes = ShapeThemeExtension.fromVariant(variant);
    final sidebar = SidebarThemeExtension.fromVariant(variant);
    final conduitExtension = ConduitThemeExtension.create(
      theme: theme,
      tokens: tokens,
      brightness: brightness,
      surfaces: surfaces,
      shadows: shadows,
      shapes: shapes,
    );
    final fixedVariant = theme.light;
    final fixedTokens = AppColorTokens.light(theme: theme);
    final colorScheme =
        dynamicScheme ??
        tokens.toColorScheme().copyWith(
          primary: variant.primary,
          onPrimary: conduitExtension.buttonPrimaryText,
          secondary: variant.secondary,
          onSecondary: conduitExtension.selectionForeground,
          tertiary: variant.accent,
          onTertiary: readableOn(
            variant.accent,
            preferred: variant.accentForeground,
            foreground: variant.foreground,
            background: variant.background,
          ),
          surfaceTint: variant.primary,
          // Roles left to `ColorScheme.fromSeed` come out hue-shifted from the
          // seed (pink/teal containers on the monochrome Conduit palette), and
          // Material components such as segmented buttons, chips, menus, and
          // switches read them directly. Derive every one from the palette.
          // shadcn draws selected tabs/toggles with `secondary`; `accent` is a
          // hover color (Catppuccin's is saturated sky blue).
          secondaryContainer: conduitExtension.selectionBackground,
          onSecondaryContainer: conduitExtension.selectionForeground,
          tertiaryContainer: variant.muted,
          onTertiaryContainer: variant.foreground,
          errorContainer: Color.alphaBlend(
            tokens.statusError60.withValues(alpha: isDark ? 0.24 : 0.12),
            surfaces.background,
          ),
          // Error details render as body text inside the container.
          onErrorContainer: tokens.neutralOnSurface,
          surfaceContainerLowest: isDark
              ? surfaces.background
              : surfaces.popover,
          surfaceContainer: surfaces.container,
          surfaceContainerHigh: Color.lerp(
            surfaces.container,
            surfaces.card,
            0.5,
          ),
          surfaceDim: isDark ? surfaces.background : surfaces.card,
          surfaceBright: isDark ? surfaces.card : surfaces.background,
          inverseSurface: variant.foreground,
          onInverseSurface: variant.background,
          // Accent text on the inverse surface: the palette primary, with its
          // lightness adjusted where it would blend into that surface.
          inversePrimary: withMinContrast(
            variant.primary,
            variant.foreground,
            4.5,
          ),
          primaryFixed: fixedTokens.brandTone90,
          primaryFixedDim: fixedTokens.brandTone90,
          onPrimaryFixed: fixedTokens.brandOn90,
          onPrimaryFixedVariant: fixedTokens.brandOn90,
          secondaryFixed: fixedVariant.secondary,
          secondaryFixedDim: fixedVariant.secondary,
          onSecondaryFixed: fixedVariant.secondaryForeground,
          onSecondaryFixedVariant: fixedVariant.secondaryForeground,
          tertiaryFixed: fixedVariant.muted,
          tertiaryFixedDim: fixedVariant.muted,
          onTertiaryFixed: fixedVariant.foreground,
          onTertiaryFixedVariant: fixedVariant.foreground,
        );

    final OutlineInputBorder baseInputBorder = OutlineInputBorder(
      borderRadius: shapes.medium,
      borderSide: BorderSide(
        color: conduitExtension.inputBorder,
        width: BorderWidth.standard,
      ),
    );

    final TextTheme textTheme = _buildTextTheme(
      tokens: tokens,
      isDark: isDark,
      tertiary: conduitExtension.textTertiary,
    );
    final TextTheme materialChromeTextTheme =
        AppTypography.materialChromeTextTheme(
          primary: tokens.neutralOnSurface,
          secondary: isDark ? tokens.neutralTone80 : tokens.neutralTone60,
          tertiary: conduitExtension.textTertiary,
        );
    final cupertinoOverrideTheme = _buildCupertinoThemeData(
      brightness: brightness,
      variant: variant,
      tokens: tokens,
    );
    final textInputAccentColor = variant.primary;

    final inputDecorationTheme = InputDecorationThemeData(
      filled: true,
      fillColor: conduitExtension.inputBackground,
      focusColor: conduitExtension.inputBorderFocused,
      hoverColor: Color.alphaBlend(
        shadows.shadowXs.first.color,
        conduitExtension.inputBackground,
      ),
      hintStyle: AppTypography.inputHintStyle.copyWith(
        color: conduitExtension.inputPlaceholder,
      ),
      border: baseInputBorder,
      enabledBorder: baseInputBorder,
      focusedBorder: baseInputBorder.copyWith(
        borderSide: BorderSide(
          color: conduitExtension.inputBorderFocused,
          width: 2,
        ),
      ),
      errorBorder: baseInputBorder.copyWith(
        borderSide: BorderSide(
          color: conduitExtension.error,
          width: BorderWidth.standard,
        ),
      ),
      focusedErrorBorder: baseInputBorder.copyWith(
        borderSide: BorderSide(color: conduitExtension.error, width: 2),
      ),
      disabledBorder: baseInputBorder.copyWith(
        borderSide: BorderSide(color: surfaces.border),
      ),
      labelStyle: TextStyle(color: conduitExtension.inputPlaceholder),
      floatingLabelStyle: WidgetStateTextStyle.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.error)
              ? conduitExtension.error
              : conduitExtension.inputBorderFocused,
        ),
      ),
      errorStyle: AppTypography.small.copyWith(color: conduitExtension.error),
      contentPadding: EdgeInsets.symmetric(
        horizontal: Spacing.inputPadding,
        vertical: AppTypography.inputVerticalPadding,
      ),
    );
    final menuStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(surfaces.popover),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    );
    var actionForeground = variant.primary;
    for (final surface in [
      surfaces.background,
      surfaces.card,
      surfaces.popover,
    ]) {
      actionForeground = withMinContrast(actionForeground, surface, 4.5);
    }

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: surfaces.background,
      canvasColor: surfaces.background,
      cupertinoOverrideTheme: cupertinoOverrideTheme,
      pageTransitionsTheme: _pageTransitionsTheme,
      splashFactory: NoSplash.splashFactory,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: Elevation.none,
        backgroundColor: surfaces.background,
        foregroundColor: tokens.neutralOnSurface,
        titleTextStyle: materialChromeTextTheme.titleLarge,
        toolbarTextStyle: materialChromeTextTheme.bodyMedium,
        systemOverlayStyle: systemUiOverlayStyleForBrightness(brightness),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaces.card,
        modalBackgroundColor: surfaces.card,
        surfaceTintColor: surfaces.card,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.bottomSheet),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        showDragHandle: false,
      ),
      cardTheme: CardThemeData(
        color: surfaces.card,
        elevation: Elevation.low,
        shape: RoundedRectangleBorder(
          borderRadius: shapes.large,
          side: BorderSide(color: surfaces.border),
        ),
        shadowColor: shadows.shadowSm.first.color,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: conduitExtension.statusPalette.info.base,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: conduitExtension.statusPalette.info.onBase,
        ),
        actionTextColor: conduitExtension.statusPalette.info.onBase,
        shape: RoundedRectangleBorder(borderRadius: shapes.medium),
        elevation: Elevation.low,
        insetPadding: const EdgeInsets.all(Spacing.md),
      ),
      inputDecorationTheme: inputDecorationTheme,
      dropdownMenuTheme: DropdownMenuThemeData(
        inputDecorationTheme: inputDecorationTheme,
        textStyle: textTheme.bodyLarge?.copyWith(
          color: conduitExtension.inputText,
        ),
        menuStyle: menuStyle,
      ),
      menuTheme: MenuThemeData(style: menuStyle),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: conduitExtension.buttonPrimary,
          foregroundColor: conduitExtension.buttonPrimaryText,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: surfaces.card,
          foregroundColor: actionForeground,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: actionForeground),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(foregroundColor: actionForeground),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              !states.contains(WidgetState.disabled) &&
                  states.contains(WidgetState.selected)
              ? colorScheme.primary
              : null,
        ),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              !states.contains(WidgetState.disabled) &&
                  states.contains(WidgetState.selected)
              ? colorScheme.onPrimary
              : null,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) =>
              !states.contains(WidgetState.disabled) &&
                  states.contains(WidgetState.selected)
              ? colorScheme.primary
              : null,
        ),
        checkColor: WidgetStateProperty.resolveWith(
          (states) =>
              !states.contains(WidgetState.disabled) &&
                  states.contains(WidgetState.selected)
              ? colorScheme.onPrimary
              : null,
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: shapes.medium),
        padding: EdgeInsets.symmetric(
          horizontal: AppTypography.chipHorizontalPadding,
          vertical: AppTypography.chipVerticalPadding,
        ),
        backgroundColor: Color.lerp(surfaces.card, surfaces.muted, 0.4)!,
        disabledColor: Color.alphaBlend(
          shadows.shadowXs.first.color,
          surfaces.card,
        ),
        selectedColor: conduitExtension.selectionBackground,
        secondarySelectedColor: conduitExtension.selectionBackground,
        shadowColor: shadows.shadowSm.first.color,
        selectedShadowColor: shadows.shadowSm.first.color,
        brightness: brightness,
        labelStyle: WidgetStateTextStyle.resolveWith(
          (states) => textTheme.bodySmall!.copyWith(
            color: states.contains(WidgetState.selected)
                ? conduitExtension.selectionForeground
                : conduitExtension.textPrimary,
          ),
        ),
        secondaryLabelStyle: textTheme.bodySmall?.copyWith(
          color: conduitExtension.selectionForeground,
        ),
        side: BorderSide(color: surfaces.border),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: conduitExtension.statusPalette.info.base,
        textColor: conduitExtension.statusPalette.info.onBase,
        padding: EdgeInsets.symmetric(
          horizontal: AppTypography.badgeHorizontalPadding,
          vertical: AppTypography.badgeVerticalPadding,
        ),
        largeSize: AppTypography.badgeLargeSize,
        smallSize: AppTypography.badgeSmallSize,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaces.popover,
        surfaceTintColor: Colors.transparent,
        elevation: Elevation.medium,
        shadowColor: shadows.shadowLg.first.color,
        shape: RoundedRectangleBorder(borderRadius: shapes.large),
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: surfaces.popoverForeground,
        ),
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: tokens.neutralOnSurface,
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: shapes.medium),
        tileColor: Color.lerp(surfaces.card, surfaces.muted, 0.25),
        selectedTileColor: conduitExtension.selectionBackground,
        selectedColor: conduitExtension.selectionForeground,
        iconColor: tokens.neutralTone80,
        textColor: tokens.neutralOnSurface,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaces.popover,
        surfaceTintColor: Colors.transparent,
        elevation: Elevation.high,
        shadowColor: shadows.shadowLg.first.color,
        shape: RoundedRectangleBorder(
          borderRadius: shapes.large,
          side: BorderSide(
            color: surfaces.border.withValues(alpha: 0.15),
            width: 0.5,
          ),
        ),
        textStyle: textTheme.bodyMedium?.copyWith(
          color: tokens.neutralOnSurface,
        ),
        labelTextStyle: WidgetStateProperty.all(
          textTheme.bodyMedium?.copyWith(
            color: tokens.neutralOnSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      textTheme: textTheme,
      textSelectionTheme: TextSelectionThemeData(
        // Keep cursor, handles, and selection highlight on the active theme
        // accent across both Material and Cupertino text fields.
        cursorColor: textInputAccentColor,
        selectionColor: textInputAccentColor.withValues(alpha: 0.2),
        selectionHandleColor: textInputAccentColor,
      ),
      extensions: <ThemeExtension<dynamic>>[
        tokens,
        surfaces,
        shadows,
        shapes,
        sidebar,
        conduitExtension,
        AppPaletteThemeExtension(palette: theme),
      ],
    );
  }

  static TextTheme _buildTextTheme({
    required AppColorTokens tokens,
    required bool isDark,
    required Color tertiary,
  }) {
    final primary = tokens.neutralOnSurface;
    final secondary = isDark ? tokens.neutralTone80 : tokens.neutralTone60;
    return AppTypography.textTheme(
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
    );
  }

  static CupertinoThemeData _buildCupertinoThemeData({
    required Brightness brightness,
    required TweakcnThemeVariant variant,
    required AppColorTokens tokens,
  }) {
    final isDark = brightness == Brightness.dark;
    final primaryText = tokens.neutralOnSurface;
    final secondaryText = isDark ? tokens.neutralTone80 : tokens.neutralTone60;
    final actionColor = variant.primary;
    final chromeTextTheme = AppTypography.cupertinoChromeTextTheme(
      primary: primaryText,
      secondary: secondaryText,
      tertiary: secondaryText,
    );

    return CupertinoThemeData(
      brightness: brightness,
      primaryColor: actionColor,
      scaffoldBackgroundColor: tokens.neutralTone10,
      barBackgroundColor: tokens.neutralTone10,
      textTheme: CupertinoTextThemeData(
        textStyle: chromeTextTheme.bodyLarge,
        actionTextStyle: chromeTextTheme.bodyLarge?.copyWith(
          color: actionColor,
        ),
        actionSmallTextStyle: chromeTextTheme.bodyMedium?.copyWith(
          color: actionColor,
        ),
        tabLabelTextStyle: AppTypography.cupertinoChromeMicroStyle.copyWith(
          color: secondaryText,
        ),
        navTitleTextStyle: chromeTextTheme.titleLarge,
        navLargeTitleTextStyle: chromeTextTheme.displayLarge,
        navActionTextStyle: chromeTextTheme.bodyLarge?.copyWith(
          color: actionColor,
        ),
        pickerTextStyle: chromeTextTheme.titleLarge,
        dateTimePickerTextStyle: chromeTextTheme.titleLarge,
      ),
    );
  }

  static const PageTransitionsTheme _pageTransitionsTheme =
      PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
        },
      );
}

/// Animated theme wrapper for smooth theme transitions
class AnimatedThemeWrapper extends StatefulWidget {
  final Widget child;
  final ThemeData theme;
  final Duration duration;

  const AnimatedThemeWrapper({
    super.key,
    required this.child,
    required this.theme,
    this.duration = const Duration(milliseconds: 250),
  });

  @override
  State<AnimatedThemeWrapper> createState() => _AnimatedThemeWrapperState();
}

class _AnimatedThemeWrapperState extends State<AnimatedThemeWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  ThemeData? _previousTheme;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: widget.duration, vsync: this);
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _previousTheme = widget.theme;
  }

  @override
  void didUpdateWidget(AnimatedThemeWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.theme != widget.theme) {
      _previousTheme = oldWidget.theme;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void deactivate() {
    // Pause animations during deactivation to avoid rebuilds in wrong build scope
    _controller.stop();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // If a theme transition was in progress, resume it
    if (_controller.value < 1.0 && !_controller.isAnimating) {
      _controller.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Theme(
          data: ThemeData.lerp(
            _previousTheme ?? widget.theme,
            widget.theme,
            _animation.value,
          ),
          child: widget.child,
        );
      },
    );
  }
}

/// Theme transition widget for individual components
class ThemeTransition extends StatelessWidget {
  final Widget child;
  final Duration duration;

  const ThemeTransition({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 200),
  });

  @override
  Widget build(BuildContext context) {
    return child.animate().fadeIn(duration: duration);
  }
}

// Typography, spacing, and design token classes are now in theme_extensions.dart for consistency
