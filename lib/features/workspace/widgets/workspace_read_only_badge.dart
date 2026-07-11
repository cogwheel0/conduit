import 'package:flutter/material.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';

/// Compact badge that marks a workspace resource as read-only.
///
/// Rendered by editors and access sheets whenever the active session lacks
/// write permission for the resource. Carries a semantics label so the state
/// is announced to assistive technology.
class WorkspaceReadOnlyBadge extends StatelessWidget {
  const WorkspaceReadOnlyBadge({super.key, this.compact = false});

  /// When true, drops the text label and renders only the lock glyph. Used in
  /// tight toolbars where a full pill would crowd other actions.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final label = l10n.workspaceReadOnlyBadge;

    return Tooltip(
      message: l10n.workspaceReadOnlyExplanation,
      child: Semantics(
        label: '$label. ${l10n.workspaceReadOnlyExplanation}',
        readOnly: true,
        container: true,
        child: Container(
          key: const Key('workspace-read-only-badge'),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? Spacing.xs : Spacing.sm,
            vertical: Spacing.xxs,
          ),
          decoration: BoxDecoration(
            color: theme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppBorderRadius.badge),
            border: Border.all(color: theme.dividerColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline,
                size: IconSize.small,
                color: theme.iconSecondary,
              ),
              if (!compact) ...[
                const SizedBox(width: Spacing.xxs),
                Text(
                  label,
                  style: theme.caption?.copyWith(color: theme.textSecondary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
