import 'dart:io' show Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/adaptive_route_shell.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/chrome_gradient_fade.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/middle_ellipsis_text.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';

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
    final pageBackground = context.usesCupertinoChrome
        ? CupertinoColors.systemGroupedBackground.resolveFrom(context)
        : theme.surfaceBackground;
    final compact = MediaQuery.sizeOf(context).width < 840;
    // The route title already identifies compact editors. Repeating the same
    // icon and title at the top of the form made these screens read like web
    // detail pages rather than native push destinations.
    final effectiveHeader =
        header ??
        (compact && readOnly
            ? const Align(
                alignment: AlignmentDirectional.centerStart,
                child: WorkspaceReadOnlyBadge(),
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
          context.goWorkspace(section.path);
        }
      },
      child: compact
          ? AdaptiveRouteShell(
              backgroundColor: pageBackground,
              appBar: _compactAppBar(context),
              body: _compactBody(context, content, pageBackground),
            )
          : content,
    );
  }

  Widget _compactBody(
    BuildContext context,
    Widget content,
    Color pageBackground,
  ) {
    final usesCupertinoChrome = context.usesCupertinoChrome;
    final topInset = usesCupertinoChrome
        ? MediaQuery.paddingOf(context).top +
              conduitAdaptiveToolbarHeightOf(context)
        : 0.0;
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(top: topInset),
            child: Material(color: Colors.transparent, child: content),
          ),
        ),
        if (usesCupertinoChrome)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: ConduitChromeGradientFade.top(
              contentHeight: topInset,
              backgroundColor: pageBackground,
            ),
          ),
      ],
    );
  }

  AdaptiveAppBar _compactAppBar(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final textScaler = MediaQuery.textScalerOf(context);
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
          onPressed: isSaving ? null : () => _showActions(context),
        ),
    ];
    return AdaptiveAppBar(
      title: title,
      useNativeToolbar: false,
      tintColor: theme.textPrimary,
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
      cupertinoNavigationBar: ConduitAdaptiveCupertinoNavigationBar(
        textScaler: textScaler,
        leading: AdaptiveTooltip(
          message: MaterialLocalizations.of(context).backButtonTooltip,
          child: ConduitAdaptiveAppBarIconButton(
            key: const Key('workspace-editor-native-back'),
            icon: CupertinoIcons.chevron_back,
            iconColor: theme.textPrimary,
            onPressed: () => _exitCompact(context),
          ),
        ),
        middle: MiddleEllipsisText(
          title,
          style: conduitAdaptiveToolbarPillTextStyle(context),
          semanticsLabel: title,
        ),
        trailing: _compactCupertinoActions(context, actions),
      ),
    );
  }

  Widget _compactCupertinoActions(
    BuildContext context,
    List<AdaptiveAppBarAction> actions,
  ) {
    if (actions.isEmpty) return const SizedBox.shrink();
    final theme = context.conduitTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final action in actions)
          if (action.title != null)
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
              minimumSize: const Size(0, TouchTarget.minimum),
              onPressed: action.onPressed,
              child: Text(
                action.title!,
                style: TextStyle(color: theme.buttonPrimary),
              ),
            )
          else
            ConduitAdaptiveAppBarIconButton(
              icon: action.icon ?? CupertinoIcons.ellipsis,
              iosSymbol: action.iosSymbol,
              iconColor: theme.textPrimary,
              onPressed: action.onPressed,
            ),
      ],
    );
  }

  Future<void> _exitCompact(BuildContext context) async {
    if (isDirty && !await _confirmDiscard(context)) return;
    if (context.mounted) context.goWorkspace(section.path);
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
                  onTap: isSaving || item.onSelected == null
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
            Material(
              type: MaterialType.transparency,
              child: AdaptivePopupMenuButton.icon<WorkspaceEditorAction>(
                key: const Key('workspace-editor-overflow'),
                enabled: !isSaving,
                icon: Platform.isIOS ? 'ellipsis' : Icons.more_vert,
                buttonStyle: PopupButtonStyle.plain,
                onSelected: (_, entry) => entry.value?.onSelected?.call(),
                items: [
                  for (final action in actions)
                    AdaptivePopupMenuItem<WorkspaceEditorAction>(
                      key: action.menuKey,
                      value: action,
                      label: action.label,
                      icon: action.icon,
                      enabled: !isSaving && action.onSelected != null,
                      isDestructive: action.isDestructive,
                    ),
                ],
              ),
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
