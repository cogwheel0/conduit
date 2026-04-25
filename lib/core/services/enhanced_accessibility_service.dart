import 'dart:math' as math;
import 'dart:ui' show FlutterView;
import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter/semantics.dart';
import '../../shared/theme/tweakcn_themes.dart';
import '../../shared/theme/theme_extensions.dart';
import 'navigation_service.dart';

/// Enhanced accessibility service for WCAG 2.2 AA compliance
class EnhancedAccessibilityService {
  static AppLocalizations? get _l10n {
    final ctx = NavigationService.context;
    if (ctx == null) return null;
    return AppLocalizations.of(ctx);
  }

  static FlutterView? _resolveView(BuildContext? context) {
    if (context != null) {
      try {
        final view = View.maybeOf(context);
        if (view != null) {
          return view;
        }
      } catch (_) {}
    }
    return WidgetsBinding.instance.platformDispatcher.implicitView;
  }

  static TextDirection _resolveTextDirection(
    BuildContext? context,
    TextDirection? override,
  ) {
    if (override != null) {
      return override;
    }
    if (context != null) {
      final direction = Directionality.maybeOf(context);
      if (direction != null) {
        return direction;
      }
    }
    return TextDirection.ltr;
  }

  /// Announce text to screen readers
  static Future<void> announce(
    String message, {
    BuildContext? context,
    TextDirection? textDirection,
  }) async {
    final resolvedContext = context ?? NavigationService.context;
    final view = _resolveView(resolvedContext);
    if (view == null) return;

    final direction = _resolveTextDirection(resolvedContext, textDirection);
    await SemanticsService.sendAnnouncement(view, message, direction);
  }

  /// Announce loading state
  static void announceLoading(String loadingMessage) {
    final l10n = _l10n;
    final message =
        l10n?.loadingAnnouncement(loadingMessage) ?? 'Loading: $loadingMessage';
    announce(message);
  }

  /// Announce error with helpful context
  static void announceError(String error, {String? suggestion}) {
    final l10n = _l10n;
    final message = suggestion != null
        ? l10n?.errorAnnouncementWithSuggestion(error, suggestion) ??
              'Error: $error. $suggestion'
        : l10n?.errorAnnouncement(error) ?? 'Error: $error';
    announce(message);
  }

  /// Announce success with context
  static void announceSuccess(String successMessage) {
    final l10n = _l10n;
    announce(
      l10n?.successAnnouncement(successMessage) ?? 'Success: $successMessage',
    );
  }

  /// Check if reduce motion is enabled
  static bool shouldReduceMotion(BuildContext context) {
    return MediaQuery.of(context).disableAnimations;
  }

  /// Get appropriate animation duration based on motion settings
  static Duration getAnimationDuration(
    BuildContext context,
    Duration defaultDuration,
  ) {
    return shouldReduceMotion(context) ? Duration.zero : defaultDuration;
  }

  /// Get text scale factor with bounds for accessibility
  static double getBoundedTextScaleFactor(BuildContext context) {
    final textScaler = MediaQuery.of(context).textScaler;
    final textScaleFactor = textScaler.scale(1.0);
    // Ensure text doesn't get too small or too large
    return textScaleFactor.clamp(0.8, 3.0);
  }

  /// Create accessible button with proper semantics
  static Widget createAccessibleButton({
    required Widget child,
    required VoidCallback? onPressed,
    required String semanticLabel,
    String? semanticHint,
    bool isDestructive = false,
  }) {
    return Builder(
      builder: (context) => Semantics(
        label: semanticLabel,
        hint: semanticHint,
        button: true,
        enabled: onPressed != null,
        child: AdaptiveButton.child(
          onPressed: onPressed,
          color: isDestructive ? context.conduitTheme.error : null,
          style: AdaptiveButtonStyle.filled,
          minSize: const Size(44, 44),
          child: child,
        ),
      ),
    );
  }

  /// Create accessible icon button with proper semantics
  static Widget createAccessibleIconButton({
    required IconData icon,
    required VoidCallback? onPressed,
    required String semanticLabel,
    String? semanticHint,
    Color? iconColor,
    double iconSize = 24,
  }) {
    return Semantics(
      label: semanticLabel,
      hint: semanticHint,
      button: true,
      enabled: onPressed != null,
      child: SizedBox(
        width: 44, // Minimum touch target
        height: 44,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon, size: iconSize, color: iconColor),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  /// Create accessible text field with proper labels
  static Widget createAccessibleTextField({
    required String label,
    TextEditingController? controller,
    String? hintText,
    String? errorText,
    bool isRequired = false,
    TextInputType? keyboardType,
    bool obscureText = false,
    ValueChanged<String>? onChanged,
  }) {
    final l10n = _l10n;
    final effectiveLabel = isRequired
        ? l10n?.requiredFieldLabel(label) ?? '$label *'
        : label;

    return Semantics(
      label: effectiveLabel,
      hint: hintText,
      textField: true,
      child: AdaptiveTextFormField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscureText,
        onChanged: onChanged,
        placeholder: hintText,
        prefixIcon: errorText != null
            ? Builder(
                builder: (context) => Icon(
                  Icons.error_outline,
                  color: context.conduitTheme.error,
                ),
              )
            : null,
        decoration: InputDecoration(
          labelText: effectiveLabel,
          hintText: hintText,
          errorText: errorText,
          helperText: isRequired
              ? l10n?.requiredFieldHelper ?? 'Required field'
              : null,
          prefixIcon: errorText != null
              ? Builder(
                  builder: (context) => Icon(
                    Icons.error_outline,
                    color: context.conduitTheme.error,
                  ),
                )
              : null,
        ),
      ),
    );
  }

  /// Create accessible card with proper semantics
  static Widget createAccessibleCard({
    required Widget child,
    VoidCallback? onTap,
    String? semanticLabel,
    String? semanticHint,
    bool isSelected = false,
  }) {
    return Semantics(
      label: semanticLabel,
      hint: semanticHint,
      button: onTap != null,
      selected: isSelected,
      child: AdaptiveCard(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: child,
          ),
        ),
      ),
    );
  }

  /// Create accessible loading indicator
  static Widget createAccessibleLoadingIndicator({
    String? loadingMessage,
    double size = 24,
  }) {
    final l10n = _l10n;
    return Semantics(
      label: loadingMessage ?? l10n?.loadingShort ?? 'Loading',
      liveRegion: true,
      child: SizedBox(
        width: size,
        height: size,
        child: const CircularProgressIndicator(),
      ),
    );
  }

  /// Create accessible image with alt text
  static Widget createAccessibleImage({
    required ImageProvider image,
    required String altText,
    bool isDecorative = false,
    double? width,
    double? height,
    BoxFit fit = BoxFit.cover,
  }) {
    if (isDecorative) {
      return Semantics(
        excludeSemantics: true,
        child: Image(image: image, width: width, height: height, fit: fit),
      );
    }

    return Semantics(
      label: altText,
      image: true,
      child: Image(image: image, width: width, height: height, fit: fit),
    );
  }

  /// Create accessible toggle switch
  static Widget createAccessibleSwitch({
    required bool value,
    required ValueChanged<bool>? onChanged,
    required String label,
    String? description,
  }) {
    final l10n = _l10n;
    final onLabel = l10n?.switchOnLabel ?? 'On';
    final offLabel = l10n?.switchOffLabel ?? 'Off';
    return Builder(
      builder: (context) => Semantics(
        label: label,
        value: value ? onLabel : offLabel,
        hint: description,
        toggled: value,
        onTap: onChanged != null ? () => onChanged(!value) : null,
        child: SwitchListTile(
          title: Text(
            label,
            style: AppTypography.bodyMediumStyle.copyWith(
              color: context.conduitTheme.textPrimary,
            ),
          ),
          subtitle: description != null
              ? Text(
                  description,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: context.conduitTheme.textSecondary,
                  ),
                )
              : null,
          value: value,
          onChanged: onChanged,
        ),
      ),
    );
  }

  /// Create accessible slider
  static Widget createAccessibleSlider({
    required double value,
    required ValueChanged<double>? onChanged,
    required String label,
    double min = 0.0,
    double max = 1.0,
    int? divisions,
    String Function(double)? valueFormatter,
  }) {
    final formattedValue =
        valueFormatter?.call(value) ?? value.toStringAsFixed(1);

    return Semantics(
      label: label,
      value: formattedValue,
      increasedValue:
          valueFormatter?.call((value + 0.1).clamp(min, max)) ??
          (value + 0.1).clamp(min, max).toStringAsFixed(1),
      decreasedValue:
          valueFormatter?.call((value - 0.1).clamp(min, max)) ??
          (value - 0.1).clamp(min, max).toStringAsFixed(1),
      onIncrease: onChanged != null
          ? () => onChanged((value + 0.1).clamp(min, max))
          : null,
      onDecrease: onChanged != null
          ? () => onChanged((value - 0.1).clamp(min, max))
          : null,
      child: AdaptiveSlider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
        label: formattedValue,
      ),
    );
  }

  /// Create accessible modal with focus management
  static Future<T?> showAccessibleModal<T>({
    required BuildContext context,
    required Widget child,
    required String title,
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dialogContext) {
        final dialogL10n = AppLocalizations.of(dialogContext);
        return Semantics(
          scopesRoute: true,
          explicitChildNodes: true,
          label: dialogL10n?.dialogSemanticLabel(title) ?? 'Dialog: $title',
          child: AlertDialog(
            title: Semantics(header: true, child: Text(title)),
            content: child,
          ),
        );
      },
    );
  }

  /// Check color contrast ratio (simplified implementation)
  static bool hasGoodContrast(Color foreground, Color background) {
    // Simplified contrast calculation
    final fgLuminance = _getLuminance(foreground);
    final bgLuminance = _getLuminance(background);

    final lighter = fgLuminance > bgLuminance ? fgLuminance : bgLuminance;
    final darker = fgLuminance > bgLuminance ? bgLuminance : fgLuminance;

    final contrast = (lighter + 0.05) / (darker + 0.05);

    // WCAG AA requires 4.5:1 for normal text, 3:1 for large text
    return contrast >= 4.5;
  }

  /// Calculate relative luminance of a color
  static double _getLuminance(Color color) {
    final r = _gammaCorrect((color.r * 255.0).round() / 255.0);
    final g = _gammaCorrect((color.g * 255.0).round() / 255.0);
    final b = _gammaCorrect((color.b * 255.0).round() / 255.0);

    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  /// Apply gamma correction
  static double _gammaCorrect(double value) {
    return value <= 0.03928
        ? value / 12.92
        : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  }

  /// Provide haptic feedback if available
  static void hapticFeedback() {
    ConduitHaptics.lightImpact();
  }

  /// Create accessible focus border
  static BoxDecoration createFocusBorder({
    required bool hasFocus,
    Color? focusColor,
    double borderWidth = 2.0,
    BorderRadius? borderRadius,
  }) {
    return BoxDecoration(
      border: hasFocus
          ? Border.all(
              color: focusColor ?? TweakcnThemes.t3Chat.light.primary,
              width: borderWidth,
            )
          : null,
      borderRadius: borderRadius,
    );
  }

  /// Create accessible text with proper scaling
  static Widget createAccessibleText(
    String text, {
    TextStyle? style,
    TextAlign? textAlign,
    bool isHeader = false,
    int? maxLines,
  }) {
    return Builder(
      builder: (context) {
        final textScaleFactor = getBoundedTextScaleFactor(context);

        Widget textWidget = Text(
          text,
          style:
              style?.copyWith(
                fontSize: style.fontSize != null
                    ? style.fontSize! * textScaleFactor
                    : null,
              ) ??
              TextStyle(fontSize: AppTypography.bodyLarge * textScaleFactor),
          textAlign: textAlign,
          maxLines: maxLines,
          overflow: maxLines != null ? TextOverflow.ellipsis : null,
        );

        if (isHeader) {
          textWidget = Semantics(header: true, child: textWidget);
        }

        return textWidget;
      },
    );
  }
}
