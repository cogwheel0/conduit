import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/middle_ellipsis_text.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'workspace_read_only_badge.dart';

/// An overflow-menu action for [WorkspaceEditorScaffold].
class WorkspaceEditorAction {
  const WorkspaceEditorAction({
    required this.label,
    required this.onSelected,
    this.icon,
    this.isDestructive = false,
    this.menuKey,
  });

  final String label;
  final VoidCallback? onSelected;
  final IconData? icon;
  final bool isDestructive;
  final Key? menuKey;
}

/// Shared chrome for every workspace section editor.
///
/// Deliberately renders its own inline toolbar (title, read-only badge, save
/// button, overflow menu) instead of an [AdaptiveAppBar]/route shell so it can
/// be embedded in the tablet three-pane layout without nesting a second
/// `AdaptiveRouteShell`. On compact layouts the surrounding
/// `WorkspaceScaffold` already provides the route shell.
///
/// Behaviour:
/// * A [PopScope] dirty-guard confirms discard before leaving when [isDirty].
/// * [readOnly] hides the save affordance and surfaces a [WorkspaceReadOnlyBadge].
/// * [errorMessage]/[onRetry] render an inline, retryable error banner without
///   collapsing the body to an empty list.
/// * [isLoading] shows an inline loading state in place of [child].
class WorkspaceEditorScaffold extends StatelessWidget {
  const WorkspaceEditorScaffold({
    super.key,
    required this.title,
    required this.child,
    this.isDirty = false,
    this.readOnly = false,
    this.onSave,
    this.canSave = true,
    this.isSaving = false,
    this.actions = const [],
    this.errorMessage,
    this.onRetry,
    this.isLoading = false,
    this.bodyPadding = const EdgeInsets.all(Spacing.md),
  });

  final String title;
  final Widget child;
  final bool isDirty;
  final bool readOnly;
  final Future<void> Function()? onSave;
  final bool canSave;
  final bool isSaving;
  final List<WorkspaceEditorAction> actions;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final bool isLoading;
  final EdgeInsets bodyPadding;

  Future<bool> _confirmDiscard(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    return ThemedDialogs.confirm(
      context,
      title: l10n.workspaceEditorDiscardTitle,
      message: l10n.workspaceEditorDiscardMessage,
      confirmText: l10n.workspaceEditorDiscardConfirm,
      cancelText: l10n.workspaceEditorKeepEditing,
      isDestructive: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return PopScope(
      canPop: !isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final shouldPop = await _confirmDiscard(context);
        if (shouldPop && navigator.mounted) {
          navigator.pop(result);
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(context),
          if (errorMessage != null)
            _errorBanner(context, errorMessage!),
          Divider(height: 1, color: theme.dividerColor),
          Expanded(
            child: isLoading
                ? Center(
                    child: ConduitLoading.primary(
                      message: AppLocalizations.of(context)!.loadingShort,
                    ),
                  )
                : Padding(padding: bodyPadding, child: child),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.sm,
        Spacing.sm,
        Spacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: MiddleEllipsisText(
              title,
              style: theme.headingSmall,
              semanticsLabel: title,
            ),
          ),
          if (readOnly)
            const Padding(
              padding: EdgeInsets.only(left: Spacing.sm),
              child: WorkspaceReadOnlyBadge(),
            )
          else if (onSave != null) ...[
            const SizedBox(width: Spacing.sm),
            _SaveButton(
              onSave: onSave!,
              enabled: canSave && !isSaving,
              isSaving: isSaving,
              tooltip: l10n.workspaceEditorSaveTooltip,
              savingLabel: l10n.workspaceEditorSaving,
              saveLabel: l10n.save,
            ),
          ],
          if (actions.isNotEmpty)
            PopupMenuButton<WorkspaceEditorAction>(
              key: const Key('workspace-editor-overflow'),
              tooltip: l10n.workspaceEditorMoreActions,
              icon: const Icon(Icons.more_vert),
              onSelected: (action) => action.onSelected?.call(),
              itemBuilder: (context) => [
                for (final action in actions)
                  PopupMenuItem<WorkspaceEditorAction>(
                    key: action.menuKey,
                    value: action,
                    enabled: action.onSelected != null,
                    child: Row(
                      children: [
                        if (action.icon != null) ...[
                          Icon(
                            action.icon,
                            size: IconSize.small,
                            color: action.isDestructive
                                ? theme.error
                                : theme.iconSecondary,
                          ),
                          const SizedBox(width: Spacing.sm),
                        ],
                        Text(
                          action.label,
                          style: action.isDestructive
                              ? TextStyle(color: theme.error)
                              : null,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _errorBanner(BuildContext context, String message) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Container(
      key: const Key('workspace-editor-error'),
      width: double.infinity,
      color: theme.errorBackground,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: IconSize.small, color: theme.error),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
          ),
          if (onRetry != null)
            TextButton(
              key: const Key('workspace-editor-error-retry'),
              onPressed: onRetry,
              child: Text(l10n.retry),
            ),
        ],
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({
    required this.onSave,
    required this.enabled,
    required this.isSaving,
    required this.tooltip,
    required this.savingLabel,
    required this.saveLabel,
  });

  final Future<void> Function() onSave;
  final bool enabled;
  final bool isSaving;
  final String tooltip;
  final String savingLabel;
  final String saveLabel;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: FilledButton(
        key: const Key('workspace-editor-save'),
        onPressed: enabled ? () => onSave() : null,
        child: isSaving
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: IconSize.small,
                    height: IconSize.small,
                    child: ConduitLoading.button(context: context),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Text(savingLabel),
                ],
              )
            : Text(saveLabel),
      ),
    );
  }
}
