import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/conduit_button_styles.dart';
import '../theme/conduit_input_styles.dart';
import '../theme/theme_extensions.dart';
import '../services/brand_service.dart';
import '../../core/services/enhanced_accessibility_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../core/services/platform_service.dart';
import '../../core/services/settings_service.dart';

/// Unified component library following Conduit design patterns
/// This provides consistent, reusable UI components throughout the app

// =============================================================================
// FLOATING APP BAR COMPONENTS
// =============================================================================

/// A pill-shaped container with blur effect for floating app bar elements.
/// Used for back buttons, titles, and action buttons in the floating app bar.
class FloatingAppBarPill extends StatelessWidget {
  final Widget child;
  final bool isCircular;

  const FloatingAppBarPill({
    super.key,
    required this.child,
    this.isCircular = false,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = isCircular
        ? BorderRadius.circular(100)
        : BorderRadius.circular(AppBorderRadius.pill);

    final blurChild = isCircular
        ? SizedBox(width: 44, height: 44, child: Center(child: child))
        : child;

    if (PlatformInfo.isIOS26OrHigher()) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final hasBoundedWidth = constraints.maxWidth.isFinite;
          final minSize = hasBoundedWidth
              ? Size(
                  constraints.maxWidth,
                  isCircular ? TouchTarget.minimum : TouchTarget.input,
                )
              : null;

          return Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: AdaptiveButton.child(
                    onPressed: () {},
                    style: AdaptiveButtonStyle.glass,
                    size: AdaptiveButtonSize.large,
                    minSize: minSize,
                    useSmoothRectangleBorder: false,
                    child: const SizedBox.shrink(),
                  ),
                ),
              ),
              ClipRRect(borderRadius: borderRadius, child: blurChild),
            ],
          );
        },
      );
    }

    // On iOS, use glass blur. On Android/web/desktop, use Material surface.
    if (!kIsWeb && Platform.isIOS) {
      return AdaptiveBlurView(
        blurStyle: BlurStyle.systemUltraThinMaterial,
        borderRadius: borderRadius,
        child: blurChild,
      );
    }
    final theme = context.conduitTheme;
    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceContainerHighest,
        borderRadius: borderRadius,
        border: Border.all(
          color: theme.cardBorder,
          width: BorderWidth.thin,
        ),
      ),
      child: blurChild,
    );
  }
}

/// A floating app bar with gradient background and pill-shaped elements.
/// Provides a consistent app bar style across the app with blur effects.
///
/// Supports:
/// - Simple title with optional leading/actions
/// - Custom title widget for complex layouts
/// - Bottom widget for search bars or other content
/// - Flexible actions positioning
class FloatingAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// Leading widget (typically a back button or menu button)
  final Widget? leading;

  /// Title widget - can be a simple [FloatingAppBarTitle] or custom widget
  final Widget title;

  /// Action widgets displayed on the right side
  final List<Widget>? actions;

  /// Bottom widget displayed below the main row (e.g., search bar)
  final Widget? bottom;

  /// Height of the bottom widget (used for preferredSize calculation)
  final double bottomHeight;

  /// Whether to show a trailing spacer when there's a leading widget but no actions
  /// Set to false if you want the title to use all available space
  final bool balanceLeading;

  const FloatingAppBar({
    super.key,
    this.leading,
    required this.title,
    this.actions,
    this.bottom,
    this.bottomHeight = 0,
    this.balanceLeading = true,
  });

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + bottomHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overlayStyle = theme.appBarTheme.systemOverlayStyle;

    Widget bar = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0.0, 0.4, 1.0],
          colors: [
            theme.scaffoldBackgroundColor,
            theme.scaffoldBackgroundColor.withValues(alpha: 0.85),
            theme.scaffoldBackgroundColor.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: kToolbarHeight,
              child: Row(
                children: [
                  // Leading
                  if (leading != null)
                    Padding(
                      padding: const EdgeInsets.only(
                        left: Spacing.inputPadding,
                      ),
                      child: Center(child: leading),
                    )
                  else
                    const SizedBox(width: Spacing.inputPadding),
                  // Title centered
                  Expanded(child: Center(child: title)),
                  // Actions or trailing spacer
                  if (actions != null && actions!.isNotEmpty)
                    Row(mainAxisSize: MainAxisSize.min, children: actions!)
                  else if (leading != null && balanceLeading)
                    const SizedBox(width: 44 + Spacing.inputPadding)
                  else
                    const SizedBox(width: Spacing.inputPadding),
                ],
              ),
            ),
            ?bottom,
          ],
        ),
      ),
    );

    if (overlayStyle != null) {
      bar = AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: bar,
      );
    }

    return bar;
  }
}

/// Helper to build a standard floating app bar title pill with text.
class FloatingAppBarTitle extends StatelessWidget {
  final String text;
  final IconData? icon;

  const FloatingAppBarTitle({super.key, required this.text, this.icon});

  @override
  Widget build(BuildContext context) {
    final conduitTheme = context.conduitTheme;

    return FloatingAppBarPill(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                color: conduitTheme.textPrimary.withValues(alpha: 0.7),
                size: IconSize.md,
              ),
              const SizedBox(width: Spacing.sm),
            ],
            Text(
              text,
              style: AppTypography.headlineSmallStyle.copyWith(
                color: conduitTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Helper to build a standard floating app bar back button.
class FloatingAppBarBackButton extends StatelessWidget {
  final VoidCallback? onTap;
  final IconData? icon;

  const FloatingAppBarBackButton({super.key, this.onTap, this.icon});

  @override
  Widget build(BuildContext context) {
    final conduitTheme = context.conduitTheme;
    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;

    return GestureDetector(
      onTap: onTap ?? () => Navigator.of(context).maybePop(),
      child: FloatingAppBarPill(
        isCircular: true,
        child: Icon(
          icon ?? (isIOS ? Icons.arrow_back_ios_new : Icons.arrow_back),
          color: conduitTheme.textPrimary,
          size: IconSize.appBar,
        ),
      ),
    );
  }
}

/// Helper to build a floating app bar icon button (circular pill with icon).
class FloatingAppBarIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color? iconColor;

  const FloatingAppBarIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final conduitTheme = context.conduitTheme;

    return GestureDetector(
      onTap: onTap,
      child: FloatingAppBarPill(
        isCircular: true,
        child: Icon(
          icon,
          color: iconColor ?? conduitTheme.textPrimary,
          size: IconSize.appBar,
        ),
      ),
    );
  }
}

/// Helper to build a floating app bar action with padding.
class FloatingAppBarAction extends StatelessWidget {
  final Widget child;

  const FloatingAppBarAction({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: Spacing.inputPadding),
      child: Center(child: child),
    );
  }
}

class ConduitGlassSearchField extends StatelessWidget {
  const ConduitGlassSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    required this.query,
    required this.onClear,
    this.focusNode,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final ValueChanged<String> onChanged;
  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final textColor = context.conduitTheme.textPrimary;
    final hintColor = context.conduitTheme.iconSecondary;

    final Widget searchField;

    if (PlatformInfo.isIOS) {
      // CupertinoSearchTextField wrapped in CupertinoTheme so the cursor uses
      // the iOS system-tint blue instead of inheriting a dark Material color.
      searchField = CupertinoTheme(
        data: const CupertinoThemeData(
          primaryColor: CupertinoColors.activeBlue,
        ),
        child: CupertinoSearchTextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          placeholder: hintText,
          style: AppTypography.standard.copyWith(color: textColor),
          placeholderStyle: AppTypography.standard.copyWith(
            color: hintColor.withValues(alpha: 0.5),
          ),
          prefixIcon: Icon(
            CupertinoIcons.search,
            color: hintColor,
            size: 16,
          ),
          // Equal left/right insets so icon and clear button are balanced.
          prefixInsets: const EdgeInsetsDirectional.fromSTEB(14, 0, 9, 0),
          suffixInsets: const EdgeInsetsDirectional.fromSTEB(0, 0, 10, 0),
          suffixIcon: const Icon(CupertinoIcons.xmark_circle_fill),
          suffixMode: OverlayVisibilityMode.editing,
          itemColor: hintColor,
          // Small bottom offset nudges text up to align with the prefix icon.
          padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 5, 2),
          decoration: const BoxDecoration(color: Colors.transparent),
        ),
      );
    } else {
      final placeholderColor = context.conduitTheme.inputPlaceholder;
      final clearIcon = Icon(Icons.clear, color: hintColor, size: 18);
      searchField = Material(
        color: Colors.transparent,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          textAlignVertical: TextAlignVertical.center,
          style: AppTypography.standard.copyWith(color: textColor),
          decoration: InputDecoration(
            isDense: true,
            hintText: hintText,
            hintStyle: AppTypography.standard.copyWith(
              color: placeholderColor,
            ),
            prefixIcon: Icon(Icons.search, color: hintColor, size: 18),
            prefixIconConstraints: const BoxConstraints(
              minWidth: TouchTarget.minimum,
              minHeight: TouchTarget.minimum,
            ),
            suffixIcon: query.isNotEmpty
                ? IconButton(onPressed: onClear, icon: clearIcon)
                : null,
            suffixIconConstraints: const BoxConstraints(
              minWidth: TouchTarget.minimum,
              minHeight: TouchTarget.minimum,
            ),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: Spacing.sm,
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: TouchTarget.minimum,
      child: FloatingAppBarPill(child: searchField),
    );
  }
}

// =============================================================================
// EXISTING COMPONENTS
// =============================================================================

class ConduitButton extends ConsumerWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool isDestructive;
  final bool isSecondary;
  final IconData? icon;
  final double? width;
  final bool isFullWidth;
  final bool isCompact;

  const ConduitButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.isDestructive = false,
    this.isSecondary = false,
    this.icon,
    this.width,
    this.isFullWidth = false,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hapticEnabled = ref.watch(hapticEnabledProvider);
    final styles = context.conduitButtonStyles;
    final variant = isDestructive
        ? styles.destructive()
        : isSecondary
            ? styles.secondary()
            : styles.primary();
    final backgroundColor = variant.background;
    final textColor = variant.foreground;

    // Build semantic label
    String semanticLabel = text;
    if (isLoading) {
      final l10n = AppLocalizations.of(context);
      semanticLabel = '${l10n?.loadingContent ?? 'Loading'}: $text';
    } else if (isDestructive) {
      semanticLabel = 'Warning: $text';
    }

    return Semantics(
      label: semanticLabel,
      button: true,
      enabled: !isLoading && onPressed != null,
      child: GestureDetector(
        // Trigger haptic feedback on tap down for immediate tactile response
        onTapDown: (onPressed != null && !isLoading)
            ? (_) {
                PlatformService.hapticFeedbackWithSettings(
                  type: isDestructive ? HapticType.warning : HapticType.light,
                  hapticEnabled: hapticEnabled,
                );
              }
            : null,
        child: SizedBox(
          width: isFullWidth ? double.infinity : width,
          height: isCompact ? TouchTarget.medium : TouchTarget.comfortable,
          child: AdaptiveButton.child(
            onPressed: onPressed,
            enabled: !isLoading && onPressed != null,
            color: backgroundColor,
            style: variant.adaptiveStyle,
            size: isCompact
                ? AdaptiveButtonSize.small
                : AdaptiveButtonSize.medium,
            padding: EdgeInsets.symmetric(
              horizontal: isCompact ? Spacing.md : Spacing.buttonPadding,
              vertical: Spacing.sm,
            ),
            borderRadius: BorderRadius.circular(AppBorderRadius.button),
            minSize: Size(
              TouchTarget.minimum,
              isCompact ? TouchTarget.medium : TouchTarget.comfortable,
            ),
            child: isLoading
                ? Semantics(
                    label:
                        AppLocalizations.of(context)?.loadingContent ??
                        'Loading',
                    excludeSemantics: true,
                    child: SizedBox(
                      width: IconSize.small,
                      height: IconSize.small,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(textColor),
                      ),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: IconSize.small, color: textColor),
                        SizedBox(width: Spacing.iconSpacing),
                      ],
                      Flexible(
                        child:
                            EnhancedAccessibilityService.createAccessibleText(
                              text,
                              style: AppTypography.standard.copyWith(
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                              maxLines: 1,
                            ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Variants that map to [ConduitInputStyles] presets.
enum _InputVariant { standard, borderless, underline, compact }

/// A themed text input that delegates decoration to
/// [ConduitInputStyles].
///
/// Use the default constructor for standard form fields, or the
/// named constructors [ConduitInput.borderless],
/// [ConduitInput.underline], and [ConduitInput.compact] for
/// alternative styles.
class ConduitInput extends StatelessWidget {
  /// Label displayed above the input field.
  final String? label;

  /// Hint text shown inside the input when empty.
  final String? hint;

  /// Controller for the underlying text field.
  final TextEditingController? controller;

  /// Called when the text value changes.
  final ValueChanged<String>? onChanged;

  /// Called when the input is tapped.
  final VoidCallback? onTap;

  /// Whether the text is obscured (for passwords).
  final bool obscureText;

  /// Whether the input is interactive.
  final bool enabled;

  /// Error message shown below the input.
  final String? errorText;

  /// Maximum number of lines for the input.
  final int? maxLines;

  /// Widget displayed after the input text.
  final Widget? suffixIcon;

  /// Widget displayed before the input text.
  final Widget? prefixIcon;

  /// Keyboard type for the input.
  final TextInputType? keyboardType;

  /// Whether the input should autofocus on mount.
  final bool autofocus;

  /// Accessibility label for screen readers.
  final String? semanticLabel;

  /// Called when the user submits the input.
  final ValueChanged<String>? onSubmitted;

  /// Whether to display a required asterisk next to the label.
  final bool isRequired;

  /// Optional custom text style for the input content.
  final TextStyle? style;

  final _InputVariant _variant;

  /// Standard form input with outlined border and fill.
  const ConduitInput({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.onChanged,
    this.onTap,
    this.obscureText = false,
    this.enabled = true,
    this.errorText,
    this.maxLines = 1,
    this.suffixIcon,
    this.prefixIcon,
    this.keyboardType,
    this.autofocus = false,
    this.semanticLabel,
    this.onSubmitted,
    this.isRequired = false,
    this.style,
  }) : _variant = _InputVariant.standard;

  /// Borderless input for chat, note editor, and inline edits.
  const ConduitInput.borderless({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.onChanged,
    this.onTap,
    this.obscureText = false,
    this.enabled = true,
    this.errorText,
    this.maxLines = 1,
    this.suffixIcon,
    this.prefixIcon,
    this.keyboardType,
    this.autofocus = false,
    this.semanticLabel,
    this.onSubmitted,
    this.isRequired = false,
    this.style,
  }) : _variant = _InputVariant.borderless;

  /// Underline input for dialog text fields.
  const ConduitInput.underline({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.onChanged,
    this.onTap,
    this.obscureText = false,
    this.enabled = true,
    this.errorText,
    this.maxLines = 1,
    this.suffixIcon,
    this.prefixIcon,
    this.keyboardType,
    this.autofocus = false,
    this.semanticLabel,
    this.onSubmitted,
    this.isRequired = false,
    this.style,
  }) : _variant = _InputVariant.underline;

  /// Compact input with tighter padding for search bars.
  const ConduitInput.compact({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.onChanged,
    this.onTap,
    this.obscureText = false,
    this.enabled = true,
    this.errorText,
    this.maxLines = 1,
    this.suffixIcon,
    this.prefixIcon,
    this.keyboardType,
    this.autofocus = false,
    this.semanticLabel,
    this.onSubmitted,
    this.isRequired = false,
    this.style,
  }) : _variant = _InputVariant.compact;

  InputDecoration _resolveDecoration(
    ConduitInputStyles inputStyles,
  ) {
    final base = switch (_variant) {
      _InputVariant.standard =>
        inputStyles.standard(hint: hint, error: errorText),
      _InputVariant.borderless =>
        inputStyles.borderless(hint: hint),
      _InputVariant.underline =>
        inputStyles.underline(hint: hint),
      _InputVariant.compact =>
        inputStyles.compact(hint: hint, error: errorText),
    };

    return base.copyWith(
      suffixIcon: suffixIcon,
      prefixIcon: prefixIcon,
      errorText: switch (_variant) {
        _InputVariant.borderless ||
        _InputVariant.underline =>
          errorText,
        _ => null,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final inputStyles = context.conduitInputStyles;
    final decoration = _resolveDecoration(inputStyles);
    final textStyle = style ??
        AppTypography.standard.copyWith(
          color: context.conduitTheme.textPrimary,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Row(
            children: [
              Text(
                label!,
                style: AppTypography.standard.copyWith(
                  fontWeight: FontWeight.w500,
                  color: context.conduitTheme.textPrimary,
                ),
              ),
              if (isRequired) ...[
                SizedBox(width: Spacing.textSpacing),
                Text(
                  '*',
                  style: AppTypography.standard.copyWith(
                    color: context.conduitTheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
          SizedBox(height: Spacing.sm),
        ],
        Semantics(
          label:
              semanticLabel ??
              label ??
              (AppLocalizations.of(context)?.inputField ??
                  'Input field'),
          textField: true,
          child: AdaptiveTextField(
            controller: controller,
            onChanged: onChanged,
            onTap: onTap,
            onSubmitted: onSubmitted,
            obscureText: obscureText,
            enabled: enabled,
            maxLines: maxLines,
            keyboardType: keyboardType,
            autofocus: autofocus,
            style: textStyle,
            placeholder: hint,
            suffixIcon: suffixIcon,
            prefixIcon: prefixIcon,
            decoration: decoration,
          ),
        ),
      ],
    );
  }
}

class ConduitCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final bool isSelected;
  final bool isElevated;
  final bool isCompact;
  final Color? backgroundColor;
  final Color? borderColor;

  const ConduitCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.isSelected = false,
    this.isElevated = false,
    this.isCompact = false,
    this.backgroundColor,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            padding ??
            EdgeInsets.all(isCompact ? Spacing.md : Spacing.cardPadding),
        decoration: BoxDecoration(
          color: isSelected
              ? context.conduitTheme.buttonPrimary.withValues(
                  alpha: Alpha.highlight,
                )
              : backgroundColor ?? context.conduitTheme.cardBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.card),
          border: Border.all(
            color: isSelected
                ? context.conduitTheme.buttonPrimary.withValues(
                    alpha: Alpha.standard,
                  )
                : borderColor ?? context.conduitTheme.cardBorder,
            width: BorderWidth.standard,
          ),
          boxShadow: isElevated ? ConduitShadows.card(context) : null,
        ),
        child: child,
      ),
    );
  }
}

class ConduitIconButton extends ConsumerWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool isActive;
  final Color? backgroundColor;
  final Color? iconColor;
  final bool isCompact;
  final bool isCircular;

  const ConduitIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.isActive = false,
    this.backgroundColor,
    this.iconColor,
    this.isCompact = false,
    this.isCircular = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hapticEnabled = ref.watch(hapticEnabledProvider);
    final styles = context.conduitButtonStyles;
    final variant = isActive ? styles.primary() : styles.ghost();
    final effectiveIconColor =
        iconColor ??
        (isActive
            ? variant.background
            : context.conduitTheme.iconSecondary);
    final effectiveBackgroundColor =
        backgroundColor ??
        (isActive
            ? variant.background.withValues(
                alpha: Alpha.highlight,
              )
            : Colors.transparent);

    String semanticLabel = tooltip ?? 'Button';
    if (isActive) {
      semanticLabel = '$semanticLabel, active';
    }

    final double size =
        isCompact ? TouchTarget.medium : TouchTarget.minimum;
    final borderRadius = BorderRadius.circular(
      isCircular
          ? AppBorderRadius.circular
          : AppBorderRadius.standard,
    );

    return Semantics(
      label: semanticLabel,
      button: true,
      enabled: onPressed != null,
      child: AdaptiveTooltip(
        message: tooltip ?? '',
        child: AdaptiveButton.child(
          onPressed: onPressed != null
              ? () {
                  PlatformService.hapticFeedbackWithSettings(
                    type: HapticType.selection,
                    hapticEnabled: hapticEnabled,
                  );
                  onPressed!();
                }
              : null,
          enabled: onPressed != null,
          color: effectiveBackgroundColor,
          style: variant.adaptiveStyle,
          borderRadius: borderRadius,
          minSize: Size(size, size),
          padding: EdgeInsets.zero,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Icon(
                icon,
                size: isCompact
                    ? IconSize.small
                    : IconSize.medium,
                color: effectiveIconColor,
                semanticLabel: tooltip,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A text button for dialog actions, replacing raw [TextButton].
///
/// Wraps [AdaptiveButton] with [ConduitButtonStyles.ghost] for the
/// default style or uses primary/destructive colors for emphasis.
class ConduitTextButton extends ConsumerWidget {
  /// The button label text.
  final String text;

  /// Called when the button is tapped.
  final VoidCallback? onPressed;

  /// Whether to use destructive (error) coloring.
  final bool isDestructive;

  /// Whether to use primary coloring for emphasis.
  final bool isPrimary;

  /// Creates a text button styled for dialog actions.
  const ConduitTextButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isDestructive = false,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hapticEnabled = ref.watch(hapticEnabledProvider);
    final styles = context.conduitButtonStyles;
    final Color textColor;
    if (isDestructive) {
      textColor = styles.destructive().background;
    } else if (isPrimary) {
      textColor = styles.primary().background;
    } else {
      textColor = styles.ghost().foreground;
    }

    return AdaptiveButton.child(
      onPressed: onPressed != null
          ? () {
              PlatformService.hapticFeedbackWithSettings(
                type: isDestructive
                    ? HapticType.warning
                    : HapticType.light,
                hapticEnabled: hapticEnabled,
              );
              onPressed!();
            }
          : null,
      enabled: onPressed != null,
      style: AdaptiveButtonStyle.plain,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      child: Text(
        text,
        style: AppTypography.standard.copyWith(
          color: textColor,
          fontWeight: isPrimary || isDestructive
              ? FontWeight.w600
              : FontWeight.normal,
        ),
      ),
    );
  }
}

class ConduitLoadingIndicator extends StatelessWidget {
  final String? message;
  final double size;
  final bool isCompact;

  const ConduitLoadingIndicator({
    super.key,
    this.message,
    this.size = 24,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            strokeWidth: isCompact ? 2 : 3,
            valueColor: AlwaysStoppedAnimation<Color>(
              context.conduitTheme.buttonPrimary,
            ),
          ),
        ),
        if (message != null) ...[
          SizedBox(height: isCompact ? Spacing.sm : Spacing.md),
          Text(
            message!,
            style: AppTypography.standard.copyWith(
              color: context.conduitTheme.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

class ConduitEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final bool isCompact;

  const ConduitEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(isCompact ? Spacing.md : Spacing.lg),
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: isCompact ? IconSize.xxl : IconSize.xxl + Spacing.md,
                height: isCompact ? IconSize.xxl : IconSize.xxl + Spacing.md,
                decoration: BoxDecoration(
                  color: context.conduitTheme.surfaceBackground,
                  borderRadius: BorderRadius.circular(AppBorderRadius.circular),
                ),
                child: Icon(
                  icon,
                  size: isCompact ? IconSize.xl : TouchTarget.minimum,
                  color: context.conduitTheme.iconSecondary,
                ),
              ),
              SizedBox(height: isCompact ? Spacing.sm : Spacing.md),
              Text(
                title,
                style: AppTypography.headlineSmallStyle.copyWith(
                  color: context.conduitTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: Spacing.sm),
              Text(
                message,
                style: AppTypography.standard.copyWith(
                  color: context.conduitTheme.textSecondary,
                ),
                textAlign: TextAlign.center,
                maxLines: isCompact ? 2 : null,
                overflow: isCompact ? TextOverflow.ellipsis : null,
              ),
              if (action != null) ...[
                SizedBox(height: isCompact ? Spacing.md : Spacing.lg),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ConduitAvatar extends StatelessWidget {
  final double size;
  final IconData? icon;
  final String? text;
  final bool isCompact;

  const ConduitAvatar({
    super.key,
    this.size = 32,
    this.icon,
    this.text,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return BrandService.createBrandAvatar(
      size: isCompact ? size * 0.8 : size,
      fallbackText: text,
      context: context,
    );
  }
}

class ConduitBadge extends StatelessWidget {
  final String text;
  final Color? backgroundColor;
  final Color? textColor;
  final bool isCompact;
  // Optional text behavior controls for truncation/wrapping
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;

  const ConduitBadge({
    super.key,
    required this.text,
    this.backgroundColor,
    this.textColor,
    this.isCompact = false,
    this.maxLines,
    this.overflow,
    this.softWrap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? Spacing.sm : Spacing.md,
        vertical: isCompact ? Spacing.xs : Spacing.sm,
      ),
      decoration: BoxDecoration(
        color:
            backgroundColor ??
            context.conduitTheme.buttonPrimary.withValues(
              alpha: Alpha.badgeBackground,
            ),
        borderRadius: BorderRadius.circular(AppBorderRadius.badge),
      ),
      child: Text(
        text,
        style: AppTypography.small.copyWith(
          color: textColor ?? context.conduitTheme.buttonPrimary,
          fontWeight: FontWeight.w600,
        ),
        maxLines: maxLines,
        overflow: overflow,
        softWrap: softWrap,
      ),
    );
  }
}

class ConduitChip extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool isSelected;
  final IconData? icon;
  final bool isCompact;

  const ConduitChip({
    super.key,
    required this.label,
    this.onTap,
    this.isSelected = false,
    this.icon,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isCompact ? Spacing.sm : Spacing.md,
          vertical: isCompact ? Spacing.xs : Spacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? context.conduitTheme.buttonPrimary.withValues(
                  alpha: Alpha.highlight,
                )
              : context.conduitTheme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppBorderRadius.chip),
          border: Border.all(
            color: isSelected
                ? context.conduitTheme.buttonPrimary.withValues(
                    alpha: Alpha.standard,
                  )
                : context.conduitTheme.cardBorder,
            width: BorderWidth.standard,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: isCompact ? IconSize.xs : IconSize.small,
                color: isSelected
                    ? context.conduitTheme.buttonPrimary
                    : context.conduitTheme.iconSecondary,
              ),
              SizedBox(width: Spacing.iconSpacing),
            ],
            Text(
              label,
              style: AppTypography.small.copyWith(
                color: isSelected
                    ? context.conduitTheme.buttonPrimary
                    : context.conduitTheme.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ConduitDivider extends StatelessWidget {
  final bool isCompact;
  final Color? color;

  const ConduitDivider({super.key, this.isCompact = false, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: BorderWidth.standard,
      color: color ?? context.conduitTheme.dividerColor,
      margin: EdgeInsets.symmetric(
        vertical: isCompact ? Spacing.sm : Spacing.md,
      ),
    );
  }
}

class ConduitSpacer extends StatelessWidget {
  final double height;
  final bool isCompact;

  const ConduitSpacer({super.key, this.height = 16, this.isCompact = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(height: isCompact ? height * 0.5 : height);
  }
}

/// Enhanced form field with better accessibility and validation
class AccessibleFormField extends StatelessWidget {
  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final bool obscureText;
  final bool enabled;
  final String? errorText;
  final int? maxLines;
  final Widget? suffixIcon;
  final Widget? prefixIcon;
  final TextInputType? keyboardType;
  final bool autofocus;
  final String? semanticLabel;
  final String? Function(String?)? validator;
  final bool isRequired;
  final bool isCompact;
  final Iterable<String>? autofillHints;

  const AccessibleFormField({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.obscureText = false,
    this.enabled = true,
    this.errorText,
    this.maxLines = 1,
    this.suffixIcon,
    this.prefixIcon,
    this.keyboardType,
    this.autofocus = false,
    this.semanticLabel,
    this.validator,
    this.isRequired = false,
    this.isCompact = false,
    this.autofillHints,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Wrap(
            spacing: Spacing.textSpacing,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                label!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.standard.copyWith(
                  fontWeight: FontWeight.w500,
                  color: context.conduitTheme.textPrimary,
                ),
              ),
              if (isRequired)
                Text(
                  '*',
                  style: AppTypography.standard.copyWith(
                    color: context.conduitTheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          SizedBox(height: isCompact ? Spacing.xs : Spacing.sm),
        ],
        Semantics(
          label:
              semanticLabel ??
              label ??
              (AppLocalizations.of(context)?.inputField ?? 'Input field'),
          textField: true,
          child: AdaptiveTextFormField(
            controller: controller,
            onChanged: onChanged,
            onTap: onTap,
            onSubmitted: onSubmitted,
            obscureText: obscureText,
            enabled: enabled,
            maxLines: maxLines,
            keyboardType: keyboardType,
            autofocus: autofocus,
            validator: validator != null
                ? (value) => validator!(value ?? controller?.text)
                : null,
            autofillHints: autofillHints?.toList(),
            placeholder: hint,
            prefixIcon: prefixIcon,
            suffixIcon: suffixIcon,
            style: AppTypography.standard.copyWith(
              color: context.conduitTheme.textPrimary,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: isCompact ? Spacing.md : Spacing.inputPadding,
              vertical: isCompact ? Spacing.sm : Spacing.md,
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: AppTypography.standard.copyWith(
                color: context.conduitTheme.inputPlaceholder,
              ),
              filled: true,
              fillColor: context.conduitTheme.inputBackground,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.input),
                borderSide: BorderSide(
                  color: context.conduitTheme.inputBorder,
                  width: BorderWidth.standard,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.input),
                borderSide: BorderSide(
                  color: context.conduitTheme.inputBorder,
                  width: BorderWidth.standard,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.input),
                borderSide: BorderSide(
                  color: context.conduitTheme.buttonPrimary,
                  width: BorderWidth.thick,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.input),
                borderSide: BorderSide(
                  color: context.conduitTheme.error,
                  width: BorderWidth.standard,
                ),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.input),
                borderSide: BorderSide(
                  color: context.conduitTheme.error,
                  width: BorderWidth.thick,
                ),
              ),
              contentPadding: EdgeInsets.symmetric(
                horizontal: isCompact ? Spacing.md : Spacing.inputPadding,
                vertical: isCompact ? Spacing.sm : Spacing.md,
              ),
              suffixIcon: suffixIcon,
              prefixIcon: prefixIcon,
              errorText: errorText,
              errorStyle: AppTypography.small.copyWith(
                color: context.conduitTheme.error,
              ),
            ),
            cupertinoDecoration: null,
          ),
        ),
      ],
    );
  }
}

/// Enhanced section header with better typography
class ConduitSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? action;
  final bool isCompact;

  const ConduitSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? Spacing.md : Spacing.pagePadding,
        vertical: isCompact ? Spacing.sm : Spacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTypography.headlineSmallStyle.copyWith(
                    color: context.conduitTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  SizedBox(height: Spacing.textSpacing),
                  Text(
                    subtitle!,
                    style: AppTypography.standard.copyWith(
                      color: context.conduitTheme.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) ...[SizedBox(width: Spacing.md), action!],
        ],
      ),
    );
  }
}

/// Enhanced list item with better consistency
class ConduitListItem extends StatelessWidget {
  final Widget leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isSelected;
  final bool isCompact;

  const ConduitListItem({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.isSelected = false,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(
          isCompact ? Spacing.sm : Spacing.listItemPadding,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? context.conduitTheme.buttonPrimary.withValues(
                  alpha: Alpha.highlight,
                )
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppBorderRadius.standard),
        ),
        child: Row(
          children: [
            leading,
            SizedBox(width: isCompact ? Spacing.sm : Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  if (subtitle != null) ...[
                    SizedBox(height: Spacing.textSpacing),
                    subtitle!,
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              SizedBox(width: isCompact ? Spacing.sm : Spacing.md),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
