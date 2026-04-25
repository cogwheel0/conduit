import 'dart:io' show Platform;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:conduit/core/services/haptic_service.dart';

import '../../core/models/model.dart';
import '../theme/theme_extensions.dart';
import 'model_avatar.dart';

/// Whether a [Model] supports reasoning based on its parameters.
bool modelSupportsReasoning(Model model) {
  final params = model.supportedParameters ?? const [];
  return params.any((p) => p.toLowerCase().contains('reasoning'));
}

/// Small chip that displays a model capability (e.g. multimodal, reasoning).
class ModelCapabilityChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const ModelCapabilityChip({
    super.key,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Container(
      margin: const EdgeInsets.only(right: Spacing.xs),
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 2),
      decoration: BoxDecoration(
        color: theme.buttonPrimary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppBorderRadius.chip),
        border: Border.all(
          color: theme.buttonPrimary.withValues(alpha: 0.3),
          width: BorderWidth.thin,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: theme.buttonPrimary),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppTypography.labelSmallStyle.copyWith(
              color: theme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact list tile for model selection, styled like the sidebar
/// conversation tiles — no card borders, rounded active highlight.
class ModelListTile extends StatelessWidget {
  final Model model;
  final bool isSelected;
  final VoidCallback onTap;

  /// The URL of the model icon (resolved via [resolveModelIconUrlForModel]).
  final String? iconUrl;

  /// Whether this tile represents the "auto-select" option.
  final bool isAutoSelect;

  const ModelListTile({
    super.key,
    required this.model,
    required this.isSelected,
    required this.onTap,
    this.iconUrl,
    this.isAutoSelect = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final borderRadius = BorderRadius.circular(AppBorderRadius.card);

    final baseBackground = theme.surfaceBackground;
    final background = isSelected
        ? Color.alphaBlend(
            theme.buttonPrimary.withValues(alpha: 0.1),
            baseBackground,
          )
        : Colors.transparent;

    final Widget leading;
    if (isAutoSelect) {
      leading = Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: theme.buttonPrimary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppBorderRadius.xs),
        ),
        child: Icon(
          Platform.isIOS ? CupertinoIcons.wand_stars : Icons.auto_awesome,
          color: theme.buttonPrimary,
          size: IconSize.small,
        ),
      );
    } else {
      leading = ModelAvatar(size: 32, imageUrl: iconUrl, label: model.name);
    }

    final hasCapabilities =
        !isAutoSelect && (model.isMultimodal || modelSupportsReasoning(model));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
      child: Material(
        color: background,
        borderRadius: borderRadius,
        child: InkWell(
          borderRadius: borderRadius,
          onTap: () {
            ConduitHaptics.selectionClick();
            onTap();
          },
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return theme.buttonPrimary.withValues(alpha: Alpha.buttonPressed);
            }
            return Colors.transparent;
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: Spacing.xs,
            ),
            child: Row(
              children: [
                leading,
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isAutoSelect ? l10n.autoSelect : model.name,
                        style: AppTypography.bodyMediumStyle.copyWith(
                          color: isSelected
                              ? theme.textPrimary
                              : theme.textSecondary,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (isAutoSelect) ...[
                        const SizedBox(height: 2),
                        Text(
                          l10n.autoSelectDescription,
                          style: AppTypography.labelSmallStyle.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                      ] else if (hasCapabilities) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (model.isMultimodal)
                              ModelCapabilityChip(
                                icon: Platform.isIOS
                                    ? CupertinoIcons.photo
                                    : Icons.image,
                                label: l10n.modelCapabilityMultimodal,
                              ),
                            if (modelSupportsReasoning(model))
                              ModelCapabilityChip(
                                icon: Platform.isIOS
                                    ? CupertinoIcons.lightbulb
                                    : Icons.psychology_alt,
                                label: l10n.modelCapabilityReasoning,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (isSelected) ...[
                  const SizedBox(width: Spacing.xs),
                  Icon(
                    Platform.isIOS ? CupertinoIcons.check_mark : Icons.check,
                    color: theme.buttonPrimary,
                    size: IconSize.medium,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
