import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show knowledgeLimitsSupportedProvider;
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_knowledge_files.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/views/knowledge/workspace_knowledge_file_browser.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_fields.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_mutation_coordinator.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_session.dart';
import 'package:conduit/features/workspace/widgets/workspace_resource_editor_host.dart';
import 'package:conduit/features/workspace/widgets/workspace_export_controller.dart';
import 'package:conduit/features/workspace/widgets/workspace_read_only_badge.dart';
import 'package:conduit/features/workspace/widgets/workspace_section_editors.dart';
import 'package:conduit/features/workspace/widgets/workspace_tiles.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
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
    return WorkspaceResourceEditorRoute<WorkspaceKnowledgeDetail>(
      title: l10n.workspaceKnowledge,
      section: WorkspaceSection.knowledge,
      mode: mode,
      resourceId: knowledgeId,
      errorMessage: l10n.workspaceLoadFailed,
      createBuilder: () => const _WorkspaceKnowledgeForm(
        mode: WorkspaceRouteMode.create,
        summary: null,
      ),
      detailLoader: (ref, id) =>
          ref.watch(workspaceKnowledgeDetailProvider(id)),
      onRetry: (ref, id) =>
          ref.invalidate(workspaceKnowledgeDetailProvider(id)),
      builder: (value) => _WorkspaceKnowledgeForm(
        key: ValueKey(
          'workspace-knowledge-form-${value.summary.id}-${mode.name}',
        ),
        mode: mode,
        summary: value.summary,
      ),
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
  late final TextEditingController _maxFileCountController;
  late final TextEditingController _maxFileSizeController;
  late List<WorkspaceAccessGrantInput> _grants;

  late final WorkspaceEditorSession _session;
  bool get _isExternal => widget.summary?.isExternal ?? false;
  bool get _writeAccess =>
      _session.isCreate || (widget.summary?.writeAccess ?? false);

  /// Metadata fields are editable only in create/edit modes with write access on
  /// a local base. Detail is read-only for fields (edit via the Edit button).
  bool get _fieldsReadOnly => _isExternal || !_writeAccess || _session.isDetail;

  /// The file browser is manageable in both detail and edit for local, writable
  /// bases; external/connected bases are always read-only.
  bool get _filesReadOnly => _isExternal || !_writeAccess;

  /// A base's own file limits (Open WebUI 0.13 and later), which the server
  /// takes only from its owner or an admin, and never for an external base.
  bool get _limitsAvailable {
    if (_isExternal || !ref.watch(knowledgeLimitsSupportedProvider)) {
      return false;
    }
    if (_session.isCreate) return true;
    return _canDeleteUnderlying;
  }

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
    _session = WorkspaceEditorSession(widget.mode)
      ..addListener(_handleSessionChanged);
    _nameController = TextEditingController(text: widget.summary?.name ?? '');
    _descriptionController = TextEditingController(
      text: widget.summary?.description ?? '',
    );
    _maxFileCountController = TextEditingController(
      text: widget.summary?.maxFileCount?.toString() ?? '',
    );
    _maxFileSizeController = TextEditingController(
      text: widget.summary?.maxFileSize?.toString() ?? '',
    );
    _grants = [
      for (final grant in widget.summary?.accessGrants ?? const [])
        WorkspaceAccessGrantInput.fromGrant(grant),
    ];
  }

  @override
  void dispose() {
    _session.removeListener(_handleSessionChanged);
    _session.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _maxFileCountController.dispose();
    _maxFileSizeController.dispose();
    super.dispose();
  }

  void _handleSessionChanged() {
    if (mounted) setState(() {});
  }

  void _markDirty() {
    _session.markDirty();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (_nameController.text.trim().isEmpty) {
      _session.setError(l10n.workspaceKnowledgeNameRequired);
      return;
    }
    WorkspaceKnowledgeLimits? limits;
    if (_limitsAvailable) {
      final maxFileCount = _parseLimit(_maxFileCountController.text);
      final maxFileSize = _parseLimit(_maxFileSizeController.text);
      if (maxFileCount == null || maxFileSize == null) {
        _session.setError(l10n.workspaceKnowledgeLimitInvalid);
        return;
      }
      limits = (maxFileCount: maxFileCount.value, maxFileSize: maxFileSize.value);
    }
    final notifier = ref.read(workspaceKnowledgeProvider.notifier);
    final form = WorkspaceKnowledgeForm(
      name: _nameController.text.trim(),
      description: _descriptionController.text.trim(),
      accessGrants: _grants,
      limits: limits,
    );
    await WorkspaceEditorMutationCoordinator.run<WorkspaceKnowledgeDetail>(
      context: context,
      session: _session,
      section: WorkspaceSection.knowledge,
      scope: 'workspace/knowledge',
      resourceLabel: 'knowledge',
      successMessage: l10n.workspaceKnowledgeSaved,
      failureMessage: l10n.workspaceKnowledgeSaveFailed,
      editorMounted: () => mounted,
      mutate: (isCreate) => isCreate
          ? notifier.create(form)
          : notifier.updateItem(widget.summary!.id, form),
      resourceId: (result) => result.summary.id,
    );
  }

  /// A limit as typed: no limit when empty, null when it is not a whole
  /// number above zero.
  static ({int? value})? _parseLimit(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return (value: null);
    final parsed = int.tryParse(trimmed);
    return parsed != null && parsed > 0 ? (value: parsed) : null;
  }

  Future<void> _manageAccess() async {
    final l10n = AppLocalizations.of(context)!;
    final capabilities = ref
        .read(workspaceCapabilitiesProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => WorkspaceCapabilities.none,
        );
    final summary = widget.summary;
    final readOnly = _isExternal || !_writeAccess;
    // An existing knowledge base saves from the sheet, which stays open with
    // the error when the save fails. A new one keeps the grants for its first
    // save.
    final grants = await WorkspaceAccessGrantSheet.show(
      context,
      initialGrants: _grants,
      capabilities: capabilities.knowledge,
      allowUserGrants: capabilities.allowUserGrants,
      allowGroupGrants: capabilities.allowGroupGrants,
      readOnly: readOnly,
      resourceName: summary?.name,
      onSave: summary != null && !readOnly
          ? (grants, _) async {
              final saved = await WorkspaceEditorOperationRunner.stay<void>(
                session: _session,
                scope: 'workspace/knowledge',
                operationLabel: 'knowledge access update',
                editorMounted: () => mounted,
                operation: () => ref
                    .read(workspaceKnowledgeProvider.notifier)
                    .updateAccess(summary.id, grants),
                onSuccess: (_) {
                  setState(() => _grants = grants);
                  ref.invalidate(workspaceKnowledgeDetailProvider(summary.id));
                  _showSnack(l10n.workspaceKnowledgeSaved);
                },
              );
              return saved
                  ? const WorkspaceAccessSaveOutcome.saved()
                  : WorkspaceAccessSaveOutcome.failed(
                      l10n.workspaceKnowledgeSaveFailed,
                    );
            }
          : null,
    );
    if (grants == null || !mounted || summary != null) return;
    setState(() => _grants = grants);
    // Create mode persists nothing server-side here, so record the grant
    // change for the unsaved-changes guard.
    _markDirty();
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
    await WorkspaceEditorOperationRunner.stay<void>(
      session: _session,
      scope: 'workspace/knowledge',
      operationLabel: 'knowledge reset',
      editorMounted: () => mounted,
      operation: () =>
          ref.read(workspaceKnowledgeProvider.notifier).reset(summary.id),
      onSuccess: (_) {
        // Reset deleted every file server-side; refetch the browser so it no
        // longer shows (or offers actions on) the now-deleted entries.
        ref.invalidate(workspaceKnowledgeFilesProvider(summary.id));
        _showSnack(l10n.workspaceKnowledgeResetDone);
      },
      onFailure: (_) =>
          _showSnack(l10n.workspaceKnowledgeSaveFailed, isError: true),
    );
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
    await WorkspaceEditorMutationCoordinator.exitAfterDelete(
      context: context,
      session: _session,
      section: WorkspaceSection.knowledge,
      scope: 'workspace/knowledge',
      resourceLabel: 'knowledge',
      successMessage: l10n.workspaceKnowledgeDeleted,
      failureMessage: l10n.workspaceKnowledgeSaveFailed,
      editorMounted: () => mounted,
      delete: () =>
          ref.read(workspaceKnowledgeProvider.notifier).delete(summary.id),
    );
  }

  @override
  Widget build(BuildContext context) => _buildContent(context);

  Widget _buildContent(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final summary = widget.summary;
    final title = _session.isCreate
        ? l10n.workspaceKnowledgeCreateTitle
        : (_nameController.text.trim().isEmpty
              ? l10n.workspaceKnowledge
              : _nameController.text.trim());
    final sectionGap = WorkspaceEditorMetrics.sectionGap(context);

    return WorkspaceEditorScaffold(
      title: title,
      section: WorkspaceSection.knowledge,
      mode: widget.mode,
      isDirty: _session.dirty && !_session.saving,
      readOnly: _fieldsReadOnly,
      isSaving: _session.saving,
      canSave: !_fieldsReadOnly,
      onSave: _fieldsReadOnly ? null : _save,
      onEdit: _session.isDetail && _writeAccess && !_isExternal
          ? () => context.pushWorkspace(
              WorkspaceSection.knowledge.routes.editLocation(summary!.id),
            )
          : null,
      errorMessage: _session.errorMessage,
      actions: _buildActions(l10n),
      bodyPadding: EdgeInsets.zero,
      child: AbsorbPointer(
        absorbing: _session.saving,
        child: ListView(
          key: const Key('workspace-knowledge-editor-body'),
          padding: WorkspaceEditorMetrics.bodyPadding(context),
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
            WorkspaceEditorFieldGroup(
              children: [
                WorkspaceEditorField(
                  fieldKey: 'workspace-knowledge-name',
                  controller: _nameController,
                  label: l10n.workspaceKnowledgeName,
                  isDetail: _session.isDetail,
                  enabled: !_fieldsReadOnly,
                  onChanged: (_) => _markDirty(),
                ),
                WorkspaceEditorField(
                  fieldKey: 'workspace-knowledge-description',
                  controller: _descriptionController,
                  label: l10n.workspaceKnowledgeDescription,
                  isDetail: _session.isDetail,
                  enabled: !_fieldsReadOnly,
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (_) => _markDirty(),
                ),
              ],
            ),
            if (_limitsAvailable) ...[
              SizedBox(height: sectionGap),
              WorkspaceEditorFieldGroup(
                key: const Key('workspace-knowledge-limits'),
                title: l10n.workspaceKnowledgeLimitsTitle,
                footer: l10n.workspaceKnowledgeLimitsFooter,
                children: [
                  WorkspaceEditorField(
                    fieldKey: 'workspace-knowledge-max-file-count',
                    controller: _maxFileCountController,
                    label: l10n.workspaceKnowledgeMaxFileCount,
                    hint: l10n.workspaceKnowledgeLimitDefault,
                    detailValue: _maxFileCountController.text.isEmpty
                        ? l10n.workspaceKnowledgeLimitDefault
                        : null,
                    isDetail: _session.isDetail,
                    enabled: !_fieldsReadOnly,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => _markDirty(),
                  ),
                  WorkspaceEditorField(
                    fieldKey: 'workspace-knowledge-max-file-size',
                    controller: _maxFileSizeController,
                    label: l10n.workspaceKnowledgeMaxFileSize,
                    hint: l10n.workspaceKnowledgeLimitDefault,
                    detailValue: _maxFileSizeController.text.isEmpty
                        ? l10n.workspaceKnowledgeLimitDefault
                        : null,
                    isDetail: _session.isDetail,
                    enabled: !_fieldsReadOnly,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => _markDirty(),
                  ),
                ],
              ),
            ],
            SizedBox(height: sectionGap),
            _accessTile(l10n),
            if (!_session.isCreate && summary != null) ...[
              SizedBox(height: sectionGap),
              WorkspaceKnowledgeFileBrowser(
                key: Key('workspace-knowledge-files-${summary.id}'),
                knowledgeId: summary.id,
                readOnly: _filesReadOnly,
                canDeleteUnderlying: _canDeleteUnderlying,
              ),
            ],
            SizedBox(height: sectionGap),
          ],
        ),
      ),
    );
  }

  Widget _accessTile(AppLocalizations l10n) {
    return WorkspaceResourceTile(
      key: const Key('workspace-knowledge-access'),
      icon: workspaceAccessSummaryIcon(_grants),
      title: l10n.workspaceKnowledgeManageAccess,
      subtitle: workspaceAccessSummary(l10n, _grants),
      onTap: _manageAccess,
    );
  }

  List<WorkspaceEditorAction> _buildActions(AppLocalizations l10n) {
    if (_session.isCreate) return const [];
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
      type: isError ? AdaptiveSnackBarType.error : AdaptiveSnackBarType.success,
    );
  }
}
