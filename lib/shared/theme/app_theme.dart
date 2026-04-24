import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'theme_extensions.dart';
import 'tweakcn_themes.dart';
import 'color_tokens.dart';

class AppTheme {
  static ThemeData light(TweakcnThemeDefinition theme) {
    final tokens = AppColorTokens.light(theme: theme);
    return _buildTheme(
      theme: theme,
      tokens: tokens,
      brightness: Brightness.light,
    );
  }

  static ThemeData dark(TweakcnThemeDefinition theme) {
    final tokens = AppColorTokens.dark(theme: theme);
    return _buildTheme(
      theme: theme,
      tokens: tokens,
      brightness: Brightness.dark,
    );
  }

  static CupertinoThemeData cupertinoTheme(
    BuildContext context,
    TweakcnThemeDefinition theme,
  ) {
    final brightness = Theme.of(context).brightness;
    final variant = theme.variantFor(brightness);
    final tokens = brightness == Brightness.dark
        ? AppColorTokens.dark(theme: theme)
        : AppColorTokens.light(theme: theme);
    return _buildCupertinoThemeData(
      brightness: brightness,
      variant: variant,
      tokens: tokens,
    );
  }

  /// Builds a [CupertinoThemeData] for light mode.
  static CupertinoThemeData cupertinoLight(TweakcnThemeDefinition theme) {
    final variant = theme.variantFor(Brightness.light);
    final tokens = AppColorTokens.light(theme: theme);
    return _buildCupertinoThemeData(
      brightness: Brightness.light,
      variant: variant,
      tokens: tokens,
    );
  }

  /// Builds a [CupertinoThemeData] for dark mode.
  static CupertinoThemeData cupertinoDark(TweakcnThemeDefinition theme) {
    final variant = theme.variantFor(Brightness.dark);
    final tokens = AppColorTokens.dark(theme: theme);
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
  }) {
    final variant = theme.variantFor(brightness);
    final isDark = brightness == Brightness.dark;
    final typography = TypographyThemeExtension.fromVariant(variant);
    final surfaces = SurfaceThemeExtension.fromVariant(variant);
    final shadows = ShadowThemeExtension.standard();
    final shapes = ShapeThemeExtension.fromVariant(variant);
    final sidebar = SidebarThemeExtension.fromVariant(variant);
    final conduitExtension = ConduitThemeExtension.create(
      theme: theme,
      tokens: tokens,
      brightness: brightness,
      typography: typography,
      surfaces: surfaces,
      shadows: shadows,
      shapes: shapes,
    );
    final colorScheme = tokens.toColorScheme().copyWith(
      primary: variant.primary,
      onPrimary: _pickOnColor(variant.primary, tokens),
      secondary: variant.secondary,
      onSecondary: _pickOnColor(variant.secondary, tokens),
      tertiary: variant.accent,
      onTertiary: _pickOnColor(variant.accent, tokens),
      surfaceTint: variant.primary,
    );

    final OutlineInputBorder baseInputBorder = OutlineInputBorder(
      borderRadius: shapes.medium,
      borderSide: BorderSide(
        color: isDark
            ? Color.lerp(surfaces.border, surfaces.input, 0.6)!
            : Color.lerp(surfaces.border, surfaces.input, 0.4)!,
        width: 1,
      ),
    );

    final TextTheme textTheme = _buildTextTheme(tokens: tokens, isDark: isDark)
        .apply(
          fontFamily: typography.primaryFont.isEmpty
              ? null
              : typography.primaryFont,
          fontFamilyFallback: typography.primaryFallback.isEmpty
              ? null
              : typography.primaryFallback,
        );
    final cupertinoOverrideTheme = _buildCupertinoThemeData(
      brightness: brightness,
      variant: variant,
      tokens: tokens,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: typography.primaryFont.isEmpty
          ? null
          : typography.primaryFont,
      fontFamilyFallback: typography.primaryFallback.isEmpty
          ? null
          : typography.primaryFallback,
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
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarBrightness: brightness,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          systemNavigationBarIconBrightness: isDark
              ? Brightness.light
              : Brightness.dark,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaces.card,
        modalBackgroundColor: surfaces.card,
        surfaceTintColor: surfaces.card,
        shape: RoundedRectangleBorder(borderRadius: shapes.extraLarge),
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
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: conduitExtension.inputBackground,
        focusColor: surfaces.ring,
        hoverColor: Color.alphaBlend(
          shadows.shadowXs.first.color,
          conduitExtension.inputBackground,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: conduitExtension.inputPlaceholder,
        ),
        border: baseInputBorder,
        enabledBorder: baseInputBorder,
        focusedBorder: baseInputBorder.copyWith(
          borderSide: BorderSide(color: surfaces.ring, width: 2),
        ),
        errorBorder: baseInputBorder.copyWith(
          borderSide: BorderSide(color: tokens.statusError60, width: 1),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: Spacing.inputPadding,
          vertical: AppTypography.inputVerticalPadding,
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
        selectedColor: conduitExtension.statusPalette.success.background,
        secondarySelectedColor: conduitExtension.statusPalette.info.background,
        shadowColor: shadows.shadowSm.first.color,
        selectedShadowColor: shadows.shadowSm.first.color,
        brightness: brightness,
        labelStyle: textTheme.bodySmall?.copyWith(
          color: tokens.neutralOnSurface,
        ),
        secondaryLabelStyle: textTheme.bodySmall?.copyWith(
          color: conduitExtension.statusPalette.info.onBase,
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
        selectedTileColor: Color.alphaBlend(
          conduitExtension.statusPalette.info.background,
          surfaces.card,
        ),
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
        // Use the platform-native selection tint: iOS/macOS use system blue
        // at ~15% opacity; other platforms use the theme primary at 20%.
        selectionColor: switch (defaultTargetPlatform) {
          TargetPlatform.iOS || TargetPlatform.macOS => const Color(0x26007AFF),
          _ => variant.primary.withValues(alpha: 0.2),
        },
        cursorColor: variant.primary,
        selectionHandleColor: variant.primary,
      ),
      extensions: <ThemeExtension<dynamic>>[
        tokens,
        typography,
        surfaces,
        shadows,
        shapes,
        sidebar,
        conduitExtension,
        AppPaletteThemeExtension(palette: theme),
      ],
    );
  }

  static Color _pickOnColor(Color background, AppColorTokens tokens) {
    final contrastOnLight = _contrastRatio(background, tokens.neutralTone00);
    final contrastOnDark = _contrastRatio(background, tokens.neutralOnSurface);
    return contrastOnLight >= contrastOnDark
        ? tokens.neutralTone00
        : tokens.neutralOnSurface;
  }

  static TextTheme _buildTextTheme({
    required AppColorTokens tokens,
    required bool isDark,
  }) {
    final primary = tokens.neutralOnSurface;
    final secondary = isDark ? tokens.neutralTone80 : tokens.neutralTone60;
    final tertiary = tokens.neutralTone60;
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

    return CupertinoThemeData(
      brightness: brightness,
      primaryColor: actionColor,
      scaffoldBackgroundColor: tokens.neutralTone10,
      barBackgroundColor: tokens.neutralTone10,
      textTheme: CupertinoTextThemeData(
        textStyle: AppTypography.bodyLargeStyle.copyWith(color: primaryText),
        actionTextStyle: AppTypography.bodyLargeStyle.copyWith(
          color: actionColor,
        ),
        actionSmallTextStyle: AppTypography.bodyMediumStyle.copyWith(
          color: actionColor,
        ),
        tabLabelTextStyle: AppTypography.micro.copyWith(color: secondaryText),
        navTitleTextStyle: AppTypography.titleLargeStyle.copyWith(
          color: primaryText,
        ),
        navLargeTitleTextStyle: AppTypography.displayLargeStyle.copyWith(
          color: primaryText,
        ),
        navActionTextStyle: AppTypography.bodyLargeStyle.copyWith(
          color: actionColor,
        ),
        pickerTextStyle: AppTypography.extraLarge.copyWith(color: primaryText),
        dateTimePickerTextStyle: AppTypography.extraLarge.copyWith(
          color: primaryText,
        ),
      ),
    );
  }

  static double _contrastRatio(Color a, Color b) {
    final luminanceA = a.computeLuminance();
    final luminanceB = b.computeLuminance();
    final lighter = math.max(luminanceA, luminanceB);
    final darker = math.min(luminanceA, luminanceB);
    return (lighter + 0.05) / (darker + 0.05);
  }

  static const PageTransitionsTheme _pageTransitionsTheme =
      PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: ZoomPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
          TargetPlatform.macOS: ZoomPageTransitionsBuilder(),
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
