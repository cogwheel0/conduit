import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/theme_extensions.dart';
import '../services/brand_service.dart';
import '../../core/services/enhanced_accessibility_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../core/services/platform_service.dart';
import '../../core/services/settings_service.dart';

/// Unified component library following Conduit design patterns
/// This provides consistent, reusable UI components throughout the app

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
    Color backgroundColor;
    Color textColor;

    if (isDestructive) {
      backgroundColor = context.conduitTheme.error;
      textColor = context.conduitTheme.buttonPrimaryText;
    } else if (isSecondary) {
      backgroundColor = context.conduitTheme.buttonSecondary;
      textColor = context.conduitTheme.buttonSecondaryText;
    } else {
      backgroundColor = context.conduitTheme.buttonPrimary;
      textColor = context.conduitTheme.buttonPrimaryText;
    }

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
          child: ElevatedButton(
            onPressed: isLoading ? null : onPressed,
            style: ElevatedButton.styleFrom(
              backgroundColor: backgroundColor,
              foregroundColor: textColor,
              disabledBackgroundColor: context.conduitTheme.buttonDisabled,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.button),
              ),
              elevation: Elevation.none,
              shadowColor: backgroundColor.withValues(alpha: Alpha.standard),
              minimumSize: Size(
                TouchTarget.minimum,
                isCompact ? TouchTarget.medium : TouchTarget.comfortable,
              ),
              padding: EdgeInsets.symmetric(
                horizontal: isCompact ? Spacing.md : Spacing.buttonPadding,
                vertical: isCompact ? Spacing.sm : Spacing.sm,
              ),
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
                        Icon(icon, size: IconSize.small),
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

class ConduitInput extends StatelessWidget {
  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
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
  final ValueChanged<String>? onSubmitted;
  final bool isRequired;

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
  });

  @override
  Widget build(BuildContext context) {
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
              (AppLocalizations.of(context)?.inputField ?? 'Input field'),
          textField: true,
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            onTap: onTap,
            onSubmitted: onSubmitted,
            obscureText: obscureText,
            enabled: enabled,
            maxLines: maxLines,
            keyboardType: keyboardType,
            autofocus: autofocus,
            style: AppTypography.standard.copyWith(
              color: context.conduitTheme.textPrimary,
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
                horizontal: Spacing.inputPadding,
                vertical: Spacing.md,
              ),
              suffixIcon: suffixIcon,
              prefixIcon: prefixIcon,
              errorText: errorText,
              errorStyle: AppTypography.small.copyWith(
                color: context.conduitTheme.error,
              ),
            ),
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

  const ConduitCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.isSelected = false,
    this.isElevated = false,
    this.isCompact = false,
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
              : context.conduitTheme.cardBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.card),
          border: Border.all(
            color: isSelected
                ? context.conduitTheme.buttonPrimary.withValues(
                    alpha: Alpha.standard,
                  )
                : context.conduitTheme.cardBorder,
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
    final effectiveBackgroundColor =
        backgroundColor ??
        (isActive
            ? context.conduitTheme.buttonPrimary.withValues(
                alpha: Alpha.highlight,
              )
            : Colors.transparent);
    final effectiveIconColor =
        iconColor ??
        (isActive
            ? context.conduitTheme.buttonPrimary
            : context.conduitTheme.iconSecondary);

    // Build semantic label with context
    String semanticLabel = tooltip ?? 'Button';
    if (isActive) {
      semanticLabel = '$semanticLabel, active';
    }

    return Semantics(
      label: semanticLabel,
      button: true,
      enabled: onPressed != null,
      child: Tooltip(
        message: tooltip ?? '',
        child: GestureDetector(
          onTap: () {
            if (onPressed != null) {
              PlatformService.hapticFeedbackWithSettings(
                type: HapticType.selection,
                hapticEnabled: hapticEnabled,
              );
              onPressed!();
            }
          },
          child: Container(
            width: isCompact ? TouchTarget.medium : TouchTarget.minimum,
            height: isCompact ? TouchTarget.medium : TouchTarget.minimum,
            decoration: BoxDecoration(
              color: effectiveBackgroundColor,
              borderRadius: BorderRadius.circular(
                isCircular
                    ? AppBorderRadius.circular
                    : AppBorderRadius.standard,
              ),
              border: isActive
                  ? Border.all(
                      color: context.conduitTheme.buttonPrimary.withValues(
                        alpha: Alpha.standard,
                      ),
                      width: BorderWidth.standard,
                    )
                  : null,
            ),
            child: Icon(
              icon,
              size: isCompact ? IconSize.small : IconSize.medium,
              color: effectiveIconColor,
              semanticLabel: tooltip,
            ),
          ),
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
                : context.conduitTheme.dividerColor,
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
          child: TextFormField(
            controller: controller,
            onChanged: onChanged,
            onTap: onTap,
            onFieldSubmitted: onSubmitted,
            obscureText: obscureText,
            enabled: enabled,
            maxLines: maxLines,
            keyboardType: keyboardType,
            autofocus: autofocus,
            validator: validator,
            autofillHints: autofillHints,
            style: AppTypography.standard.copyWith(
              color: context.conduitTheme.textPrimary,
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
