import 'dart:convert';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
import 'package:conduit/features/workspace/widgets/workspace_editor_fields.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_session.dart';
import 'package:conduit/features/workspace/widgets/workspace_resource_editor_host.dart';
import 'package:conduit/features/workspace/widgets/workspace_import_sheet.dart';
import 'package:conduit/features/workspace/widgets/workspace_section_editors.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';

import 'workspace_model_editor_body.dart';
import 'workspace_model_editor_contract.dart';
import 'workspace_model_avatar.dart';
import 'workspace_model_export.dart';
import 'workspace_model_relationship_picker.dart';

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
  late WorkspaceModelDraft _draft;
  late final WorkspaceModelFormBindings _fields;

  TextEditingController get _idController => _fields.id;
  TextEditingController get _nameController => _fields.name;
  TextEditingController get _descriptionController => _fields.description;
  TextEditingController get _systemController => _fields.system;
  TextEditingController get _stopController => _fields.stop;
  TextEditingController get _terminalController => _fields.terminal;
  TextEditingController get _ttsController => _fields.tts;
  TextEditingController get _defaultFeaturesController =>
      _fields.defaultFeatures;
  TextEditingController get _paramsController => _fields.params;
  TextEditingController get _builtinToolsController => _fields.builtinTools;

  late final WorkspaceEditorSession _session;
  bool _advancedExpanded = false;
  String? _paramsError;
  // True once the user explicitly removes the avatar, so the editor renders the
  // placeholder instead of re-fetching the still-persisted server image (which
  // would silently undo the removal on screen until the model is saved).
  bool _avatarRemoved = false;
  static const _relationshipPicker = WorkspaceModelRelationshipPicker();

  bool get _readOnly => !widget.writeAccess || _session.isDetail;

  @override
  void initState() {
    super.initState();
    _session = WorkspaceEditorSession(widget.mode);
    _draft = WorkspaceModelDraft.fromSummary(_snapshot());
    _fields = WorkspaceModelFormBindings(_draft);
  }

  WorkspaceModelSummary _snapshot() {
    // Round-trips the incoming draft so the editing copy is independent of the
    // provider's cached instance.
    final source = widget.initialDraft;
    return WorkspaceModelSummary(
      id: source.id,
      name: source.name,
      userId: widget.summary?.userId ?? '',
      baseModelId: source.baseModelId,
      meta: source.buildMeta(),
      params: source.buildParams(),
      accessGrants: widget.summary?.accessGrants ?? const [],
      isActive: source.isActive,
      writeAccess: widget.writeAccess,
    );
  }

  @override
  void dispose() {
    _fields.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_session.dirty) setState(() => _session.markDirty());
  }

  void _update(void Function() mutate) {
    setState(() {
      mutate();
      _session.markDirty();
    });
  }

  Future<void> _pickKnowledge() async {
    final l10n = AppLocalizations.of(context)!;
    final options = await _loadRelationshipOptions('knowledge', () async {
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
    });
    if (options == null || !mounted) return;
    final selected = await _relationshipPicker.show(
      context,
      title: l10n.workspaceModelKnowledge,
      options: options,
      selectedIds: _draft.knowledge.map((item) => item.id).toList(),
    );
    if (selected == null || !mounted) return;
    _update(() {
      _draft.knowledge = [
        for (final id in selected)
          _draft.knowledge.firstWhere(
            (item) => item.id == id,
            orElse: () => WorkspaceModelKnowledgeRef(
              id: id,
              name: options
                  .firstWhere(
                    (option) => option.id == id,
                    orElse: () =>
                        WorkspaceRelationshipOption(id: id, label: id),
                  )
                  .label,
            ),
          ),
      ];
    });
  }

  Future<void> _pickTools() async {
    final l10n = AppLocalizations.of(context)!;
    final options = await _loadRelationshipOptions('tools', () async {
      final state = await ref.read(workspaceToolsProvider.future);
      return state.items
          .map(
            (tool) =>
                WorkspaceRelationshipOption(id: tool.id, label: tool.name),
          )
          .toList();
    });
    if (options == null || !mounted) return;
    final selected = await _relationshipPicker.show(
      context,
      title: l10n.workspaceModelTools,
      options: options,
      selectedIds: _draft.toolIds,
    );
    if (selected != null && mounted) {
      _update(() => _draft.toolIds = selected);
    }
  }

  Future<void> _pickSkills() async {
    final l10n = AppLocalizations.of(context)!;
    final options = await _loadRelationshipOptions('skills', () async {
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
    });
    if (options == null || !mounted) return;
    final selected = await _relationshipPicker.show(
      context,
      title: l10n.workspaceModelSkills,
      options: options,
      selectedIds: _draft.skillIds,
    );
    if (selected != null && mounted) {
      _update(() => _draft.skillIds = selected);
    }
  }

  Future<void> _pickFunctions({
    required bool isFilter,
    bool isDefault = false,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final functions = await _loadRelationshipOptions('functions', () async {
      final values = await ref.read(workspaceFunctionsProvider.future);
      return values
          .where((item) => isFilter ? item.isFilter : item.isAction)
          .map(
            (item) => WorkspaceRelationshipOption(
              id: item.id,
              label: item.name,
              subtitle: item.type,
            ),
          )
          .toList();
    });
    if (functions == null || !mounted) return;
    final selectedIds = isFilter
        ? (isDefault ? _draft.defaultFilterIds : _draft.filterIds)
        : _draft.actionIds;
    final title = isFilter
        ? (isDefault
              ? l10n.workspaceModelDefaultFilters
              : l10n.workspaceModelFilters)
        : l10n.workspaceModelActions;
    final selected = await _relationshipPicker.show(
      context,
      title: title,
      options: functions,
      selectedIds: selectedIds,
    );
    if (selected == null || !mounted) return;
    _update(() {
      if (!isFilter) {
        _draft.actionIds = selected;
      } else if (isDefault) {
        _draft.defaultFilterIds = selected;
      } else {
        _draft.filterIds = selected;
      }
    });
  }

  Future<List<WorkspaceRelationshipOption>?> _loadRelationshipOptions(
    String relationship,
    Future<List<WorkspaceRelationshipOption>> Function() load,
  ) async {
    try {
      return await load();
    } catch (error, stackTrace) {
      DebugLogger.error(
        '$relationship relationship load failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.workspaceLoadFailed,
          type: AdaptiveSnackBarType.error,
        );
      }
      return null;
    }
  }

  // --- Save -----------------------------------------------------------------

  bool _syncTextIntoDraft() {
    _draft.id = _idController.text.trim();
    _draft.name = _nameController.text;
    _draft.description = _descriptionController.text;
    _draft.system = _systemController.text;
    _draft.stop = _splitList(_stopController.text);
    _draft.terminalId = _terminalController.text;
    _draft.ttsVoice = _ttsController.text;
    _draft.defaultFeatureIds = _splitList(_defaultFeaturesController.text);

    final params = _parseJsonObject(_paramsController.text);
    if (params == null) {
      setState(() {
        _paramsError = 'params';
        _advancedExpanded = true;
      });
      return false;
    }
    final builtin = _parseJsonObject(_builtinToolsController.text);
    if (builtin == null) {
      setState(() {
        _paramsError = 'builtinTools';
        _advancedExpanded = true;
      });
      return false;
    }
    _draft.advancedParams = params;
    _draft.builtinTools = builtin;
    if (_paramsError != null) setState(() => _paramsError = null);
    return true;
  }

  Future<void> _save() async {
    if (!_syncTextIntoDraft()) return;
    if (!_draft.isValid) {
      setState(
        () => _session.setError(
          _draft.id.trim().isEmpty
              ? AppLocalizations.of(context)!.workspaceModelIdRequired
              : AppLocalizations.of(context)!.workspaceModelNameRequired,
        ),
      );
      return;
    }

    setState(() {
      _session.beginOperation(clearError: true);
    });
    final notifier = ref.read(workspaceModelsProvider.notifier);
    final form = _draft.toForm();
    try {
      final WorkspaceModelDetail result = _session.isCreate
          ? await notifier.create(form)
          : await notifier.updateItem(form);
      if (!mounted) return;
      _session.markClean();
      _showSnack(AppLocalizations.of(context)!.workspaceModelSaved);
      DebugLogger.log(
        'model saved',
        scope: 'workspace/models',
        data: {'id': result.id, 'create': _session.isCreate},
      );
      final router = GoRouter.of(context);
      if (_session.isCreate) {
        router.pushReplacement(
          WorkspaceSection.models.routes.detailLocation(result.id),
        );
      } else if (router.canPop()) {
        router.pop();
      } else {
        // Edit saved with nothing to pop (deep-linked into /edit): release the
        // saving lock so the form stays usable.
        setState(() => _session.endOperation());
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'model save failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(
        () => _session.finishOperation(
          errorMessage: AppLocalizations.of(context)!.workspaceModelSaveFailed,
        ),
      );
    }
  }

  // --- Overflow actions -----------------------------------------------------

  Future<void> _clone() async {
    final l10n = AppLocalizations.of(context)!;
    final router = GoRouter.of(context);
    // Abort on invalid params/builtin-tools JSON so the clone is built from the
    // form's actual contents, not stale draft values — matching _save and
    // _toggleHidden.
    if (!_syncTextIntoDraft()) return;
    final clone = WorkspaceModelDraft.fromSummary(
      WorkspaceModelSummary(
        id: '${_draft.id}-copy',
        name: '${_draft.name} ${l10n.workspaceModelCloneSuffix}',
        userId: '',
        baseModelId: _draft.baseModelId,
        meta: _draft.buildMeta(),
        params: _draft.buildParams(),
        isActive: _draft.isActive,
      ),
    );
    // Clones do not inherit the source's access grants.
    clone.accessGrants = [];
    setState(() => _session.beginOperation());
    try {
      final created = await ref
          .read(workspaceModelsProvider.notifier)
          .create(clone.toForm());
      if (!mounted) return;
      _showSnack(l10n.workspaceModelSaved);
      router.pushReplacement(
        WorkspaceSection.models.routes.editLocation(created.id),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'model clone failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _session.endOperation());
        _showSnack(l10n.workspaceModelSaveFailed, isError: true);
      }
    }
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
    setState(() => _session.beginOperation());
    try {
      await ref.read(workspaceModelsProvider.notifier).toggle(id);
      if (!mounted) return;
      _session.markClean();
      ref.invalidate(workspaceModelDetailProvider(id));
      _showSnack(l10n.workspaceModelSaved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'model toggle failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _showSnack(
          AppLocalizations.of(context)!.workspaceModelSaveFailed,
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _session.endOperation());
    }
  }

  Future<void> _toggleHidden() async {
    final id = _draft.id;
    if (id.isEmpty) return;
    // There is no hidden-only endpoint, so this persists the whole model. Honour
    // the same validation as _save (abort on invalid params JSON) and reconcile
    // _session.dirty on success so the discard-changes guard does not later prompt for
    // changes that were already saved here.
    if (!_syncTextIntoDraft()) return;
    _draft.hidden = !_draft.hidden;
    setState(() => _session.beginOperation());
    try {
      await ref
          .read(workspaceModelsProvider.notifier)
          .updateItem(_draft.toForm());
      if (!mounted) return;
      _session.markClean();
      ref.invalidate(workspaceModelDetailProvider(id));
      _showSnack(AppLocalizations.of(context)!.workspaceModelSaved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'model hide toggle failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _draft.hidden = !_draft.hidden;
        _showSnack(
          AppLocalizations.of(context)!.workspaceModelSaveFailed,
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _session.endOperation());
    }
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
    final router = GoRouter.of(context);
    setState(() => _session.beginOperation());
    try {
      await ref.read(workspaceModelsProvider.notifier).delete(id);
      if (!mounted) return;
      _session.markClean();
      _showSnack(l10n.workspaceModelDeleted);
      if (router.canPop()) {
        router.pop();
      } else {
        router.go(WorkspaceSection.models.routes.collectionPath);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'model delete failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _session.endOperation());
        _showSnack(l10n.workspaceModelSaveFailed, isError: true);
      }
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
      initialGrants: _draft.normalizedAccessGrants,
      capabilities: capabilities.models,
      allowUserGrants: capabilities.allowUserGrants,
      readOnly: _readOnly,
    );
    if (grants == null || !mounted) return;
    final id = _draft.id;
    if (_readOnly || id.isEmpty) return;
    setState(() => _session.beginOperation());
    try {
      await ref
          .read(workspaceModelsProvider.notifier)
          .updateAccess(id, _draft.name, grants);
      if (!mounted) return;
      _update(() => _draft.accessGrants = grants);
      ref.invalidate(workspaceModelDetailProvider(id));
      _showSnack(l10n.workspaceModelSaved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'model access update failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceModelSaveFailed, isError: true);
    } finally {
      if (mounted) setState(() => _session.endOperation());
    }
  }

  Future<void> _exportSingle() async {
    _syncTextIntoDraft();
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
        : (_nameController.text.trim().isEmpty
              ? l10n.workspaceModels
              : _nameController.text.trim());

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
          state: WorkspaceModelEditorViewState(
            draft: _draft,
            fields: _fields,
            isCreate: _session.isCreate,
            isDetail: _session.isDetail,
            readOnly: _readOnly,
            paramsError: _paramsError,
            baseModels: baseModels,
          ),
          intents: WorkspaceModelEditorIntents(
            onChanged: _markDirty,
            onMutate: _update,
            onAddTag: () => _addTag(l10n),
            onAddSuggestion: () => _addSuggestion(l10n),
            onPickKnowledge: _pickKnowledge,
            onPickTools: _pickTools,
            onPickSkills: _pickSkills,
            onPickFilters: () => _pickFunctions(isFilter: true),
            onPickDefaultFilters: () =>
                _pickFunctions(isFilter: true, isDefault: true),
            onPickActions: () => _pickFunctions(isFilter: false),
            onManageAccess: _manageAccess,
          ),
          profileImage: _profileImage(l10n),
          advancedExpanded: _advancedExpanded,
          onAdvancedChanged: (value) =>
              setState(() => _advancedExpanded = value),
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

  // --- Profile image --------------------------------------------------------

  Widget _profileImage(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Row(
      children: [
        WorkspaceModelAvatar(
          draftImage: _draft.profileImageUrl,
          modelId: _draft.id,
          removed: _avatarRemoved,
        ),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.workspaceModelProfileImage, style: theme.label),
              const SizedBox(height: Spacing.xs),
              if (!_readOnly)
                Wrap(
                  spacing: Spacing.sm,
                  children: [
                    WorkspacePlainIconButton(
                      buttonKey: const Key('workspace-model-image-pick'),
                      onPressed: _pickImage,
                      icon: Icons.image_outlined,
                      label: l10n.workspaceModelChangeImage,
                    ),
                    if (_draft.profileImageUrl != null)
                      WorkspacePlainIconButton(
                        buttonKey: const Key('workspace-model-image-remove'),
                        onPressed: () => _update(() {
                          _draft.profileImageUrl = null;
                          _avatarRemoved = true;
                        }),
                        icon: Icons.close,
                        label: l10n.workspaceModelRemoveImage,
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
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
      _update(() {
        _draft.profileImageUrl = dataUrl;
        _avatarRemoved = false;
      });
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
    _update(() => _draft.tags.add(tag));
  }

  Future<void> _addSuggestion(AppLocalizations l10n) async {
    final value = await _promptText(l10n.workspaceModelSuggestionPrompts);
    if (value == null) return;
    final prompt = value.trim();
    if (prompt.isEmpty) return;
    _update(() => _draft.suggestionPrompts.add(prompt));
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

  static List<String> _splitList(String raw) => raw
      .split(RegExp(r'[,\n]'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  static Map<String, dynamic>? _parseJsonObject(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    try {
      final decoded = json.decode(trimmed);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }
}
