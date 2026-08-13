import 'dart:convert';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_model_draft.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_model_relationships.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/services/workspace_model_avatar_codec.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_mutation_coordinator.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_session.dart';
import 'package:conduit/features/workspace/widgets/workspace_resource_editor_host.dart';
import 'package:conduit/features/workspace/widgets/workspace_import_sheet.dart';
import 'package:conduit/features/workspace/widgets/workspace_section_editors.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';

import 'workspace_model_editor_body.dart';
import 'workspace_model_editor_controller.dart';
import 'workspace_model_export.dart';
import 'workspace_model_relationship_sheet.dart';

export 'workspace_model_export.dart' show exportWorkspaceModelsToShare;

/// Section-registry entry point for the Models editor. Dispatches to the
/// create/detail/edit editor based on [WorkspaceEditorArgs.mode].
Widget buildWorkspaceModelEditor(
  BuildContext context,
  WorkspaceEditorArgs args,
) {
  return WorkspaceModelEditorView(
    key: ValueKey(
      'workspace-model-editor-${args.mode.name}-${args.resourceId}',
    ),
    mode: args.mode,
    modelId: args.resourceId,
  );
}

class WorkspaceModelEditorView extends ConsumerWidget {
  const WorkspaceModelEditorView({super.key, required this.mode, this.modelId});

  final WorkspaceRouteMode mode;
  final String? modelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return WorkspaceResourceEditorRoute<WorkspaceModelDetail>(
      title: l10n.workspaceModels,
      section: WorkspaceSection.models,
      mode: mode,
      resourceId: modelId,
      errorMessage: l10n.workspaceLoadFailed,
      createBuilder: () => _WorkspaceModelForm(
        mode: mode,
        initialDraft: WorkspaceModelDraft.empty(),
        writeAccess: true,
      ),
      detailLoader: (ref, id) => ref.watch(workspaceModelDetailProvider(id)),
      onRetry: (ref, id) => ref.invalidate(workspaceModelDetailProvider(id)),
      builder: (value) => _WorkspaceModelForm(
        key: ValueKey('workspace-model-form-${value.id}-${mode.name}'),
        mode: mode,
        initialDraft: WorkspaceModelDraft.fromSummary(value),
        writeAccess: value.writeAccess,
        summary: value,
      ),
    );
  }
}

class _WorkspaceModelForm extends ConsumerStatefulWidget {
  const _WorkspaceModelForm({
    super.key,
    required this.mode,
    required this.initialDraft,
    required this.writeAccess,
    this.summary,
  });

  final WorkspaceRouteMode mode;
  final WorkspaceModelDraft initialDraft;
  final bool writeAccess;
  final WorkspaceModelSummary? summary;

  @override
  ConsumerState<_WorkspaceModelForm> createState() =>
      _WorkspaceModelFormState();
}

class _WorkspaceModelFormState extends ConsumerState<_WorkspaceModelForm> {
  late final WorkspaceModelEditorController _controller;
  late final WorkspaceModelRelationshipCoordinator _relationshipCoordinator;

  WorkspaceModelDraft get _draft => _controller.draft;
  WorkspaceEditorSession get _session => _controller.session;
  bool get _readOnly => _controller.readOnly;

  @override
  void initState() {
    super.initState();
    _controller = WorkspaceModelEditorController(
      mode: widget.mode,
      initialDraft: widget.initialDraft,
      writeAccess: widget.writeAccess,
      summary: widget.summary,
    )..addListener(_handleControllerChanged);
    _relationshipCoordinator = WorkspaceModelRelationshipCoordinator(
      _controller,
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pickRelationship(WorkspaceModelRelationshipKind kind) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await _relationshipCoordinator.pick(
      kind,
      load: () => _loadRelationshipOptions(kind),
      present: (options, selectedIds) {
        if (!mounted) return Future<List<String>?>.value();
        return WorkspaceRelationshipSheet.show(
          context,
          title: _relationshipTitle(l10n, kind),
          options: options,
          selectedIds: selectedIds,
        );
      },
    );
    if (result.outcome == WorkspaceModelRelationshipPickOutcome.failed) {
      DebugLogger.error(
        '${kind.name} relationship selection failed',
        scope: 'workspace/models',
        error: result.error,
        stackTrace: result.stackTrace,
      );
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.workspaceLoadFailed,
          type: AdaptiveSnackBarType.error,
        );
      }
    }
  }

  Future<List<WorkspaceRelationshipOption>> _loadRelationshipOptions(
    WorkspaceModelRelationshipKind kind,
  ) async {
    switch (kind) {
      case WorkspaceModelRelationshipKind.knowledge:
        final state = await ref.read(workspaceKnowledgeProvider.future);
        return state.items
            .map(
              (item) => WorkspaceRelationshipOption(
                id: item.id,
                label: item.name,
                subtitle: item.description,
              ),
            )
            .toList();
      case WorkspaceModelRelationshipKind.tools:
        final state = await ref.read(workspaceToolsProvider.future);
        return state.items
            .map(
              (tool) =>
                  WorkspaceRelationshipOption(id: tool.id, label: tool.name),
            )
            .toList();
      case WorkspaceModelRelationshipKind.skills:
        final state = await ref.read(workspaceSkillsProvider.future);
        return state.items
            .map(
              (skill) => WorkspaceRelationshipOption(
                id: skill.id,
                label: skill.name,
                subtitle: skill.description,
              ),
            )
            .toList();
      case WorkspaceModelRelationshipKind.filters:
      case WorkspaceModelRelationshipKind.defaultFilters:
      case WorkspaceModelRelationshipKind.actions:
        final functions = await ref.read(workspaceFunctionsProvider.future);
        final filters = kind != WorkspaceModelRelationshipKind.actions;
        return functions
            .where((item) => filters ? item.isFilter : item.isAction)
            .map(
              (item) => WorkspaceRelationshipOption(
                id: item.id,
                label: item.name,
                subtitle: item.type,
              ),
            )
            .toList();
    }
  }

  String _relationshipTitle(
    AppLocalizations l10n,
    WorkspaceModelRelationshipKind kind,
  ) => switch (kind) {
    WorkspaceModelRelationshipKind.knowledge => l10n.workspaceModelKnowledge,
    WorkspaceModelRelationshipKind.tools => l10n.workspaceModelTools,
    WorkspaceModelRelationshipKind.skills => l10n.workspaceModelSkills,
    WorkspaceModelRelationshipKind.filters => l10n.workspaceModelFilters,
    WorkspaceModelRelationshipKind.defaultFilters =>
      l10n.workspaceModelDefaultFilters,
    WorkspaceModelRelationshipKind.actions => l10n.workspaceModelActions,
  };

  // --- Save -----------------------------------------------------------------

  bool _syncDraftOrShowError() {
    final synchronized = _controller.syncTextIntoDraft();
    final message = AppLocalizations.of(context)!.workspaceModelInvalidJson;
    if (!synchronized) {
      _session.setError(message);
      return false;
    }
    if (_session.errorMessage == message) _session.clearError();
    return true;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_syncDraftOrShowError()) return;
    if (!_draft.isValid) {
      _session.setError(
        _draft.id.trim().isEmpty
            ? l10n.workspaceModelIdRequired
            : l10n.workspaceModelNameRequired,
      );
      return;
    }

    final notifier = ref.read(workspaceModelsProvider.notifier);
    final form = _draft.toForm();
    await WorkspaceEditorMutationCoordinator.run<WorkspaceModelDetail>(
      context: context,
      session: _session,
      section: WorkspaceSection.models,
      scope: 'workspace/models',
      resourceLabel: 'model',
      successMessage: l10n.workspaceModelSaved,
      failureMessage: l10n.workspaceModelSaveFailed,
      editorMounted: () => mounted,
      mutate: (isCreate) =>
          isCreate ? notifier.create(form) : notifier.updateItem(form),
      resourceId: (result) => result.id,
    );
  }

  // --- Overflow actions -----------------------------------------------------

  Future<void> _clone() async {
    final l10n = AppLocalizations.of(context)!;
    // Abort on invalid params/builtin-tools JSON so the clone is built from the
    // form's actual contents, not stale draft values — matching _save and
    // _toggleHidden.
    if (!_syncDraftOrShowError()) return;
    final clone = _controller.buildClone(l10n.workspaceModelCloneSuffix);
    await WorkspaceEditorMutationCoordinator.replaceWithClone<
      WorkspaceModelDetail
    >(
      context: context,
      session: _session,
      section: WorkspaceSection.models,
      scope: 'workspace/models',
      resourceLabel: 'model',
      successMessage: l10n.workspaceModelSaved,
      failureMessage: l10n.workspaceModelSaveFailed,
      editorMounted: () => mounted,
      clone: () =>
          ref.read(workspaceModelsProvider.notifier).create(clone.toForm()),
      resourceId: (created) => created.id,
    );
  }

  Future<void> _toggleActive() async {
    final id = _draft.id;
    if (id.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    // Toggling active-state hits a dedicated endpoint that does not persist form
    // edits, then invalidates the detail provider — which rebuilds the editor
    // from the server response and discards any unsaved edits. Honour the same
    // discard-changes guard the navigation paths use before proceeding.
    if (_session.dirty) {
      final discard = await ThemedDialogs.confirm(
        context,
        title: l10n.workspaceEditorDiscardTitle,
        message: l10n.workspaceEditorDiscardMessage,
        confirmText: l10n.workspaceEditorDiscardConfirm,
        cancelText: l10n.workspaceEditorKeepEditing,
        isDestructive: true,
      );
      if (!discard || !mounted) return;
    }
    await WorkspaceEditorOperationRunner.stay<void>(
      session: _session,
      scope: 'workspace/models',
      operationLabel: 'model toggle',
      editorMounted: () => mounted,
      operation: () => ref.read(workspaceModelsProvider.notifier).toggle(id),
      onSuccess: (_) {
        _session.markClean();
        ref.invalidate(workspaceModelDetailProvider(id));
        _showSnack(l10n.workspaceModelSaved);
      },
      onFailure: (_) => _showSnack(
        AppLocalizations.of(context)!.workspaceModelSaveFailed,
        isError: true,
      ),
    );
  }

  Future<void> _toggleHidden() async {
    final id = _draft.id;
    if (id.isEmpty) return;
    // There is no hidden-only endpoint, so this persists the whole model. Honour
    // the same validation as _save (abort on invalid params JSON) and reconcile
    // _session.dirty on success so the discard-changes guard does not later prompt for
    // changes that were already saved here.
    if (!_syncDraftOrShowError()) return;
    await WorkspaceEditorOperationRunner.stay<void>(
      session: _session,
      scope: 'workspace/models',
      operationLabel: 'model hide toggle',
      editorMounted: () => mounted,
      operation: () async {
        _controller.toggleHidden();
        await ref
            .read(workspaceModelsProvider.notifier)
            .updateItem(_draft.toForm());
      },
      onSuccess: (_) {
        _session.markClean();
        ref.invalidate(workspaceModelDetailProvider(id));
        _showSnack(AppLocalizations.of(context)!.workspaceModelSaved);
      },
      onFailure: (_) {
        _controller.toggleHidden();
        _showSnack(
          AppLocalizations.of(context)!.workspaceModelSaveFailed,
          isError: true,
        );
      },
    );
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final id = _draft.id;
    if (id.isEmpty) return;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.workspaceModelDeleteConfirmTitle,
      message: l10n.workspaceModelDeleteConfirmMessage(
        _draft.name.isEmpty ? id : _draft.name,
      ),
      confirmText: l10n.delete,
      cancelText: l10n.cancel,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    await WorkspaceEditorMutationCoordinator.exitAfterDelete(
      context: context,
      session: _session,
      section: WorkspaceSection.models,
      scope: 'workspace/models',
      resourceLabel: 'model',
      successMessage: l10n.workspaceModelDeleted,
      failureMessage: l10n.workspaceModelSaveFailed,
      editorMounted: () => mounted,
      delete: () => ref.read(workspaceModelsProvider.notifier).delete(id),
    );
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
      initialGrants: _draft.normalizedAccessGrants,
      capabilities: capabilities.models,
      allowUserGrants: capabilities.allowUserGrants,
      readOnly: _readOnly,
    );
    if (grants == null || !mounted) return;
    if (_readOnly) return;
    if (_session.isCreate) {
      _controller.replaceAccessGrants(grants);
      return;
    }
    final id = _draft.id;
    if (id.isEmpty) return;
    await WorkspaceEditorOperationRunner.stay<void>(
      session: _session,
      scope: 'workspace/models',
      operationLabel: 'model access update',
      editorMounted: () => mounted,
      operation: () => ref
          .read(workspaceModelsProvider.notifier)
          .updateAccess(id, _draft.name, grants),
      onSuccess: (_) {
        _controller.replaceAccessGrants(grants, markDirty: false);
        ref.invalidate(workspaceModelDetailProvider(id));
        _showSnack(l10n.workspaceModelSaved);
      },
      onFailure: (_) =>
          _showSnack(l10n.workspaceModelSaveFailed, isError: true),
    );
  }

  Future<void> _exportSingle() async {
    if (!_syncDraftOrShowError()) return;
    await exportWorkspaceModelsToShare(
      context,
      models: [_draft.toForm().toJson()],
      filename: _draft.id.isEmpty ? 'model' : _draft.id,
    );
  }

  Future<void> _exportAll() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final models = await ref
          .read(workspaceModelsProvider.notifier)
          .exportAll();
      if (!mounted) return;
      await exportWorkspaceModelsToShare(
        context,
        models: models
            .map((m) => WorkspaceModelDraft.fromSummary(m).toForm().toJson())
            .toList(),
        filename: 'models',
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'model export-all failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceModelExportFailed, isError: true);
    }
  }

  Future<void> _import() async {
    final l10n = AppLocalizations.of(context)!;
    final report = await WorkspaceImportSheet.show(
      context,
      title: l10n.workspaceModelImport,
      importer: (items) => runWorkspaceImport(
        items,
        importItem: (item) async {
          final ok = await ref
              .read(workspaceModelsProvider.notifier)
              .importItems([item]);
          if (!ok) throw StateError('import rejected');
        },
        labelOf: (item) =>
            item['name']?.toString() ?? item['id']?.toString() ?? '',
      ),
    );
    if (report != null && mounted) {
      ref.read(workspaceModelsProvider.notifier).refresh();
    }
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) => _buildContent(context);

  Widget _buildContent(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final capabilities = ref
        .watch(workspaceCapabilitiesProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => WorkspaceCapabilities.none,
        );
    final baseModels = ref
        .watch(workspaceBaseModelsProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => const <WorkspaceRelationshipOption>[],
        );
    final title = _session.isCreate
        ? l10n.workspaceModelNewTitle
        : (_controller.fields.name.text.trim().isEmpty
              ? l10n.workspaceModels
              : _controller.fields.name.text.trim());

    return WorkspaceEditorScaffold(
      title: title,
      section: WorkspaceSection.models,
      mode: widget.mode,
      isDirty: _session.dirty && !_session.saving,
      readOnly: _readOnly,
      isSaving: _session.saving,
      canSave: !_readOnly,
      onSave: _readOnly ? null : _save,
      onEdit: _session.isDetail && widget.writeAccess
          ? () => context.push(
              WorkspaceSection.models.routes.editLocation(_draft.id),
            )
          : null,
      errorMessage: _session.errorMessage,
      actions: _buildActions(l10n, capabilities),
      bodyPadding: EdgeInsets.zero,
      child: AbsorbPointer(
        absorbing: _session.saving,
        child: WorkspaceModelEditorBody(
          controller: _controller,
          baseModels: baseModels,
          onPickImage: _pickImage,
          onAddTag: () => _addTag(l10n),
          onAddSuggestion: () => _addSuggestion(l10n),
          onPickRelationship: _pickRelationship,
          onManageAccess: _manageAccess,
        ),
      ),
    );
  }

  List<WorkspaceEditorAction> _buildActions(
    AppLocalizations l10n,
    WorkspaceCapabilities capabilities,
  ) {
    if (_session.isCreate) {
      return [
        if (capabilities.models.importItems)
          WorkspaceEditorAction(
            label: l10n.workspaceModelImport,
            icon: Icons.upload_file_outlined,
            menuKey: const Key('workspace-model-action-import'),
            onSelected: _import,
          ),
        if (capabilities.models.exportItems)
          WorkspaceEditorAction(
            label: l10n.workspaceModelExportAll,
            icon: Icons.download_outlined,
            menuKey: const Key('workspace-model-action-export-all'),
            onSelected: _exportAll,
          ),
      ];
    }
    final canWrite = widget.writeAccess;
    return [
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspaceModelClone,
          icon: Icons.copy_outlined,
          menuKey: const Key('workspace-model-action-clone'),
          onSelected: _clone,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: _draft.isActive
              ? l10n.workspaceModelDeactivate
              : l10n.workspaceModelActivate,
          icon: _draft.isActive
              ? Icons.toggle_on_outlined
              : Icons.toggle_off_outlined,
          menuKey: const Key('workspace-model-action-toggle'),
          onSelected: _toggleActive,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: _draft.hidden
              ? l10n.workspaceModelUnhide
              : l10n.workspaceModelHide,
          icon: _draft.hidden
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          menuKey: const Key('workspace-model-action-hide'),
          onSelected: _toggleHidden,
        ),
      WorkspaceEditorAction(
        label: l10n.workspaceModelManageAccess,
        icon: Icons.group_outlined,
        menuKey: const Key('workspace-model-action-access'),
        onSelected: _manageAccess,
      ),
      if (capabilities.models.exportItems)
        WorkspaceEditorAction(
          label: l10n.workspaceModelExport,
          icon: Icons.download_outlined,
          menuKey: const Key('workspace-model-action-export'),
          onSelected: _exportSingle,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspaceModelDelete,
          icon: Icons.delete_outline,
          isDestructive: true,
          menuKey: const Key('workspace-model-action-delete'),
          onSelected: _delete,
        ),
    ];
  }

  // --- Interactions ---------------------------------------------------------

  Future<void> _pickImage() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.image);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;
      // Cap the avatar's dimensions before base64-embedding it so a large source
      // image does not bloat the draft JSON / spike memory. A downscaled image
      // is always re-encoded as PNG; an unchanged image keeps its source mime.
      final bounded = await WorkspaceModelAvatarCodec.bound(bytes);
      final String mime;
      if (identical(bounded, bytes)) {
        final ext = (file.extension ?? 'png').toLowerCase();
        mime = switch (ext) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'gif' => 'image/gif',
          'webp' => 'image/webp',
          _ => 'image/png',
        };
      } else {
        mime = 'image/png';
      }
      final dataUrl = 'data:$mime;base64,${base64Encode(bounded)}';
      _controller.setAvatar(dataUrl);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'model image pick failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _showSnack(
          AppLocalizations.of(context)!.workspaceModelImageFailed,
          isError: true,
        );
      }
    }
  }

  Future<void> _addTag(AppLocalizations l10n) async {
    final value = await _promptText(l10n.workspaceModelTags);
    if (value == null) return;
    final tag = value.trim();
    if (tag.isEmpty || _draft.tags.contains(tag)) return;
    _controller.addTag(tag);
  }

  Future<void> _addSuggestion(AppLocalizations l10n) async {
    final value = await _promptText(l10n.workspaceModelSuggestionPrompts);
    if (value == null) return;
    final prompt = value.trim();
    if (prompt.isEmpty) return;
    _controller.addSuggestion(prompt);
  }

  Future<String?> _promptText(String label) {
    final l10n = AppLocalizations.of(context)!;
    return ThemedDialogs.promptTextInput(
      context,
      title: label,
      hintText: label,
      confirmText: l10n.workspaceModelAddAction,
    );
  }

  void _showSnack(String message, {bool isError = false}) {
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: isError ? AdaptiveSnackBarType.error : AdaptiveSnackBarType.success,
    );
  }
}
