import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/adaptive_route_shell.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/middle_ellipsis_text.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'workspace_grouped_components.dart';
import 'workspace_read_only_badge.dart';
import 'workspace_tiles.dart';

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
    required this.section,
    required this.mode,
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
    this.onEdit,
    this.header,
  });

  final String title;
  final WorkspaceSection section;
  final WorkspaceRouteMode mode;
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
  final VoidCallback? onEdit;
  final Widget? header;

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
    final compact = MediaQuery.sizeOf(context).width < 840;
    final effectiveHeader =
        header ??
        (compact
            ? WorkspaceIdentityHeader(
                leading: WorkspaceIconBadge(
                  icon: _identityIcon(section),
                  color: theme.buttonPrimary,
                ),
                title: title,
                subtitle: readOnly
                    ? AppLocalizations.of(context)!.workspaceReadOnlyBadge
                    : null,
              )
            : null);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compact) _toolbar(context),
        if (errorMessage != null) _errorBanner(context, errorMessage!),
        if (!compact) Divider(height: 1, color: theme.dividerColor),
        Expanded(
          child: isLoading
              ? Center(
                  child: ConduitLoading.primary(
                    message: AppLocalizations.of(context)!.loadingShort,
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Padding(
                      padding: bodyPadding,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (effectiveHeader != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                Spacing.pagePadding,
                                Spacing.lg,
                                Spacing.pagePadding,
                                0,
                              ),
                              child: effectiveHeader,
                            ),
                          if (effectiveHeader != null)
                            const SizedBox(height: Spacing.xl),
                          Expanded(child: child),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
    return PopScope(
      canPop: !isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _confirmDiscard(context);
        if (shouldPop && context.mounted) {
          context.go(section.path);
        }
      },
      child: compact
          ? AdaptiveRouteShell(
              backgroundColor: theme.surfaceBackground,
              appBar: _compactAppBar(context),
              body: Material(color: Colors.transparent, child: content),
            )
          : content,
    );
  }

  IconData _identityIcon(WorkspaceSection value) => switch (value) {
    WorkspaceSection.models => Icons.smart_toy_outlined,
    WorkspaceSection.knowledge => Icons.menu_book_outlined,
    WorkspaceSection.prompts => Icons.chat_bubble_outline,
    WorkspaceSection.tools => Icons.build_outlined,
    WorkspaceSection.skills => Icons.auto_awesome_outlined,
  };

  AdaptiveAppBar _compactAppBar(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final actions = <AdaptiveAppBarAction>[
      if (mode == WorkspaceRouteMode.detail && onEdit != null)
        AdaptiveAppBarAction(title: l10n.edit, onPressed: onEdit!),
      if (mode != WorkspaceRouteMode.detail && onSave != null)
        AdaptiveAppBarAction(
          title: isSaving ? l10n.workspaceEditorSaving : l10n.save,
          onPressed: canSave && !isSaving ? () => onSave!() : null,
        ),
      if (this.actions.isNotEmpty)
        AdaptiveAppBarAction(
          iosSymbol: 'ellipsis',
          icon: Icons.more_vert,
          onPressed: () => _showActions(context),
        ),
    ];
    return AdaptiveAppBar(
      title: title,
      tintColor: context.conduitTheme.textPrimary,
      leading: AdaptiveTooltip(
        message: MaterialLocalizations.of(context).backButtonTooltip,
        child: ConduitAdaptiveAppBarIconButton(
          key: const Key('workspace-editor-back'),
          icon: context.usesCupertinoChrome
              ? CupertinoIcons.chevron_back
              : Icons.arrow_back,
          onPressed: () => _exitCompact(context),
        ),
      ),
      actions: actions,
    );
  }

  Future<void> _exitCompact(BuildContext context) async {
    if (isDirty && !await _confirmDiscard(context)) return;
    if (context.mounted) context.go(section.path);
  }

  Future<void> _showActions(BuildContext context) async {
    final action = await ThemedSheets.showSurface<WorkspaceEditorAction>(
      context: context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.pagePadding,
            Spacing.md,
            Spacing.pagePadding,
            Spacing.pagePadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in actions)
                AdaptiveListTile(
                  key: item.menuKey,
                  leading: item.icon == null
                      ? null
                      : Icon(
                          item.icon,
                          color: item.isDestructive
                              ? sheetContext.conduitTheme.error
                              : sheetContext.conduitTheme.iconSecondary,
                        ),
                  title: Text(
                    item.label,
                    style: item.isDestructive
                        ? TextStyle(color: sheetContext.conduitTheme.error)
                        : null,
                  ),
                  onTap: item.onSelected == null
                      ? null
                      : () => Navigator.of(sheetContext).pop(item),
                ),
            ],
          ),
        ),
      ),
    );
    action?.onSelected?.call();
  }

  Widget _toolbar(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.pagePadding,
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
          if (onEdit != null) ...[
            const SizedBox(width: Spacing.sm),
            ConduitButton(
              key: const Key('workspace-editor-edit'),
              text: l10n.edit,
              icon: Icons.edit_outlined,
              isCompact: true,
              onPressed: onEdit,
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
                        Flexible(
                          child: Text(
                            action.label,
                            overflow: TextOverflow.ellipsis,
                            style: action.isDestructive
                                ? TextStyle(color: theme.error)
                                : null,
                          ),
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
            ConduitButton(
              key: const Key('workspace-editor-error-retry'),
              text: l10n.retry,
              onPressed: onRetry,
              isSecondary: true,
              isCompact: true,
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
    return AdaptiveTooltip(
      message: tooltip,
      child: ConduitButton(
        key: const Key('workspace-editor-save'),
        text: isSaving ? savingLabel : saveLabel,
        isLoading: isSaving,
        isCompact: true,
        onPressed: enabled ? () => onSave() : null,
      ),
    );
  }
}
