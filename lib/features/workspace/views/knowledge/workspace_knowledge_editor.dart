import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_knowledge_files.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/views/knowledge/workspace_knowledge_file_browser.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/widgets/workspace_export_controller.dart';
import 'package:conduit/features/workspace/widgets/workspace_read_only_badge.dart';
import 'package:conduit/features/workspace/widgets/workspace_section_editors.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';

/// Section-registry entry point for the Knowledge editor.
Widget buildWorkspaceKnowledgeEditor(
  BuildContext context,
  WorkspaceEditorArgs args,
) {
  return WorkspaceKnowledgeEditorView(
    key: ValueKey(
      'workspace-knowledge-editor-${args.mode.name}-${args.resourceId}',
    ),
    mode: args.mode,
    knowledgeId: args.resourceId,
  );
}

class WorkspaceKnowledgeEditorView extends ConsumerWidget {
  const WorkspaceKnowledgeEditorView({
    super.key,
    required this.mode,
    this.knowledgeId,
  });

  final WorkspaceRouteMode mode;
  final String? knowledgeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (mode == WorkspaceRouteMode.create) {
      return const _WorkspaceKnowledgeForm(
        mode: WorkspaceRouteMode.create,
        summary: null,
      );
    }

    final id = knowledgeId;
    if (id == null || id.isEmpty) {
      return WorkspaceEditorScaffold(
        title: l10n.workspaceKnowledge,
        errorMessage: l10n.workspaceLoadFailed,
        child: const SizedBox.shrink(),
      );
    }

    final detail = ref.watch(workspaceKnowledgeDetailProvider(id));
    return detail.when(
      loading: () => WorkspaceEditorScaffold(
        title: l10n.workspaceKnowledge,
        isLoading: true,
        child: const SizedBox.shrink(),
      ),
      error: (_, _) => WorkspaceEditorScaffold(
        title: l10n.workspaceKnowledge,
        errorMessage: l10n.workspaceLoadFailed,
        onRetry: () => ref.invalidate(workspaceKnowledgeDetailProvider(id)),
        child: const SizedBox.shrink(),
      ),
      data: (value) {
        if (value == null) {
          return WorkspaceEditorScaffold(
            title: l10n.workspaceKnowledge,
            errorMessage: l10n.workspaceLoadFailed,
            onRetry: () => ref.invalidate(workspaceKnowledgeDetailProvider(id)),
            child: const SizedBox.shrink(),
          );
        }
        return _WorkspaceKnowledgeForm(
          key: ValueKey('workspace-knowledge-form-${value.summary.id}-${mode.name}'),
          mode: mode,
          summary: value.summary,
        );
      },
    );
  }
}

class _WorkspaceKnowledgeForm extends ConsumerStatefulWidget {
  const _WorkspaceKnowledgeForm({super.key, required this.mode, this.summary});

  final WorkspaceRouteMode mode;
  final WorkspaceKnowledgeSummary? summary;

  @override
  ConsumerState<_WorkspaceKnowledgeForm> createState() =>
      _WorkspaceKnowledgeFormState();
}

class _WorkspaceKnowledgeFormState
    extends ConsumerState<_WorkspaceKnowledgeForm> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late List<WorkspaceAccessGrantInput> _grants;

  bool _dirty = false;
  bool _saving = false;
  String? _errorMessage;

  bool get _isCreate => widget.mode == WorkspaceRouteMode.create;
  bool get _isDetail => widget.mode == WorkspaceRouteMode.detail;
  bool get _isExternal => widget.summary?.isExternal ?? false;
  bool get _writeAccess => _isCreate || (widget.summary?.writeAccess ?? false);

  /// Metadata fields are editable only in create/edit modes with write access on
  /// a local base. Detail is read-only for fields (edit via the Edit button).
  bool get _fieldsReadOnly => _isExternal || !_writeAccess || _isDetail;

  /// The file browser is manageable in both detail and edit for local, writable
  /// bases; external/connected bases are always read-only.
  bool get _filesReadOnly => _isExternal || !_writeAccess;

  bool get _canDeleteUnderlying {
    final summary = widget.summary;
    if (summary == null) return false;
    final user = ref.read(currentUserProvider2);
    if (user == null) return false;
    return user.role == 'admin' || summary.userId == user.id;
  }

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.summary?.name ?? '');
    _descriptionController = TextEditingController(
      text: widget.summary?.description ?? '',
    );
    _grants = [
      for (final grant in widget.summary?.accessGrants ?? const [])
        WorkspaceAccessGrantInput.fromGrant(grant),
    ];
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (_nameController.text.trim().isEmpty) {
      setState(() => _errorMessage = l10n.workspaceKnowledgeNameRequired);
      return;
    }
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    final notifier = ref.read(workspaceKnowledgeProvider.notifier);
    final form = WorkspaceKnowledgeForm(
      name: _nameController.text.trim(),
      description: _descriptionController.text.trim(),
      accessGrants: _grants,
    );
    try {
      final WorkspaceKnowledgeDetail result = _isCreate
          ? await notifier.create(form)
          : await notifier.updateItem(widget.summary!.id, form);
      if (!mounted) return;
      _dirty = false;
      DebugLogger.log(
        'knowledge saved',
        scope: 'workspace/knowledge',
        data: {'id': result.summary.id, 'create': _isCreate},
      );
      _showSnack(l10n.workspaceKnowledgeSaved);
      final router = GoRouter.of(context);
      if (_isCreate) {
        router.pushReplacement(
          WorkspaceSection.knowledge.routes.detailLocation(result.summary.id),
        );
      } else if (router.canPop()) {
        router.pop();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'knowledge save failed',
        scope: 'workspace/knowledge',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorMessage = l10n.workspaceKnowledgeSaveFailed;
      });
    }
  }

  Future<void> _manageAccess() async {
    final l10n = AppLocalizations.of(context)!;
    final capabilities = ref
        .read(workspaceCapabilitiesProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => WorkspaceCapabilities.none,
        );
    final grants = await WorkspaceAccessGrantSheet.show(
      context,
      initialGrants: _grants,
      capabilities: capabilities.knowledge,
      allowUserGrants: capabilities.allowUserGrants,
      readOnly: _isExternal || !_writeAccess,
    );
    if (grants == null || !mounted) return;
    final summary = widget.summary;
    if (summary == null || _isExternal || !_writeAccess) {
      setState(() => _grants = grants);
      // Create mode persists nothing server-side here, so record the grant
      // change for the unsaved-changes guard. Read-only surfaces can't actually
      // mutate grants, so only the create path needs this.
      if (summary == null) _markDirty();
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(workspaceKnowledgeProvider.notifier)
          .updateAccess(summary.id, grants);
      if (!mounted) return;
      setState(() => _grants = grants);
      ref.invalidate(workspaceKnowledgeDetailProvider(summary.id));
      _showSnack(l10n.workspaceKnowledgeSaved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'knowledge access update failed',
        scope: 'workspace/knowledge',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceKnowledgeSaveFailed, isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reset() async {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    if (summary == null) return;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.workspaceKnowledgeResetConfirmTitle,
      message: l10n.workspaceKnowledgeResetConfirmMessage(summary.name),
      confirmText: l10n.workspaceKnowledgeReset,
      cancelText: l10n.cancel,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref.read(workspaceKnowledgeProvider.notifier).reset(summary.id);
      if (!mounted) return;
      // Reset deleted every file server-side; refetch the browser so it no
      // longer shows (or offers actions on) the now-deleted entries.
      ref.invalidate(workspaceKnowledgeFilesProvider(summary.id));
      _showSnack(l10n.workspaceKnowledgeResetDone);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'knowledge reset failed',
        scope: 'workspace/knowledge',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceKnowledgeSaveFailed, isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    if (summary == null) return;
    try {
      final bytes = await ref
          .read(workspaceKnowledgeProvider.notifier)
          .export(summary.id);
      if (!mounted) return;
      await WorkspaceExportController().shareBytes(
        filename: summary.name.isEmpty ? 'knowledge' : summary.name,
        bytes: bytes,
        mimeType: 'application/json',
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'knowledge export failed',
        scope: 'workspace/knowledge',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _showSnack(l10n.workspaceKnowledgeExportFailed, isError: true);
      }
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    if (summary == null) return;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.workspaceKnowledgeDeleteConfirmTitle,
      message: l10n.workspaceKnowledgeDeleteConfirmMessage(summary.name),
      confirmText: l10n.delete,
      cancelText: l10n.cancel,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    final router = GoRouter.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(workspaceKnowledgeProvider.notifier).delete(summary.id);
      if (!mounted) return;
      _dirty = false;
      _showSnack(l10n.workspaceKnowledgeDeleted);
      if (router.canPop()) {
        router.pop();
      } else {
        router.go(WorkspaceSection.knowledge.routes.collectionPath);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'knowledge delete failed',
        scope: 'workspace/knowledge',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _saving = false);
        _showSnack(l10n.workspaceKnowledgeSaveFailed, isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final summary = widget.summary;
    final title = _isCreate
        ? l10n.workspaceKnowledgeCreateTitle
        : (_nameController.text.trim().isEmpty
              ? l10n.workspaceKnowledge
              : _nameController.text.trim());

    return WorkspaceEditorScaffold(
      title: title,
      isDirty: _dirty && !_saving,
      readOnly: _fieldsReadOnly,
      isSaving: _saving,
      canSave: !_fieldsReadOnly,
      onSave: _fieldsReadOnly ? null : _save,
      errorMessage: _errorMessage,
      actions: _buildActions(l10n),
      bodyPadding: EdgeInsets.zero,
      child: AbsorbPointer(
        absorbing: _saving,
        child: ListView(
          key: const Key('workspace-knowledge-editor-body'),
          padding: const EdgeInsets.all(Spacing.md),
          children: [
            if (_isExternal)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: Row(
                  children: [
                    const WorkspaceReadOnlyBadge(),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        summary?.externalProvider ??
                            l10n.workspaceKnowledgeExternalBadge,
                        style: theme.bodySmall?.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_isDetail && _writeAccess && !_isExternal)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: ConduitButton(
                  key: const Key('workspace-knowledge-edit'),
                  text: l10n.edit,
                  icon: Icons.edit_outlined,
                  onPressed: () => context.push(
                    WorkspaceSection.knowledge.routes.editLocation(summary!.id),
                  ),
                ),
              ),
            ConduitInput(
              key: const Key('workspace-knowledge-name'),
              controller: _nameController,
              label: l10n.workspaceKnowledgeName,
              enabled: !_fieldsReadOnly,
              onChanged: (_) => _markDirty(),
            ),
            const SizedBox(height: Spacing.sm),
            ConduitInput(
              key: const Key('workspace-knowledge-description'),
              controller: _descriptionController,
              label: l10n.workspaceKnowledgeDescription,
              enabled: !_fieldsReadOnly,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => _markDirty(),
            ),
            const SizedBox(height: Spacing.md),
            _accessTile(l10n),
            if (!_isCreate && summary != null) ...[
              const Divider(height: Spacing.xl),
              WorkspaceKnowledgeFileBrowser(
                key: Key('workspace-knowledge-files-${summary.id}'),
                knowledgeId: summary.id,
                readOnly: _filesReadOnly,
                canDeleteUnderlying: _canDeleteUnderlying,
              ),
            ],
            const SizedBox(height: Spacing.xl),
          ],
        ),
      ),
    );
  }

  Widget _accessTile(AppLocalizations l10n) {
    final principals = workspaceSharedPrincipals(_grants);
    final isPublic = workspaceGrantsArePublic(_grants);
    return AdaptiveListTile(
      key: const Key('workspace-knowledge-access'),
      padding: EdgeInsets.zero,
      leading: Icon(isPublic ? Icons.public : Icons.lock_outline),
      title: Text(l10n.workspaceKnowledgeManageAccess),
      subtitle: Text(
        isPublic
            ? l10n.workspaceAccessVisibilityLabel
            : l10n.workspaceModelSelectCount(principals.length),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: _manageAccess,
    );
  }

  List<WorkspaceEditorAction> _buildActions(AppLocalizations l10n) {
    if (_isCreate) return const [];
    final summary = widget.summary;
    if (summary == null) return const [];
    final capabilities = ref
        .watch(workspaceCapabilitiesProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => WorkspaceCapabilities.none,
        );
    final canWrite = _writeAccess && !_isExternal;
    return [
      WorkspaceEditorAction(
        label: l10n.workspaceKnowledgeManageAccess,
        icon: Icons.group_outlined,
        menuKey: const Key('workspace-knowledge-action-access'),
        onSelected: _manageAccess,
      ),
      if (capabilities.knowledge.exportItems)
        WorkspaceEditorAction(
          label: l10n.workspaceKnowledgeExport,
          icon: Icons.download_outlined,
          menuKey: const Key('workspace-knowledge-action-export'),
          onSelected: _export,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspaceKnowledgeReset,
          icon: Icons.restart_alt_outlined,
          isDestructive: true,
          menuKey: const Key('workspace-knowledge-action-reset'),
          onSelected: _reset,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspaceKnowledgeDelete,
          icon: Icons.delete_outline,
          isDestructive: true,
          menuKey: const Key('workspace-knowledge-action-delete'),
          onSelected: _delete,
        ),
    ];
  }

  void _showSnack(String message, {bool isError = false}) {
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: isError
          ? AdaptiveSnackBarType.error
          : AdaptiveSnackBarType.success,
    );
  }
}
