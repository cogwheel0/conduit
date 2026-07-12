import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_model_draft.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_model_relationships.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_fields.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/widgets/workspace_export_controller.dart';
import 'package:conduit/features/workspace/widgets/workspace_import_sheet.dart';
import 'package:conduit/features/workspace/widgets/workspace_section_editors.dart';
import 'package:conduit/features/workspace/widgets/workspace_tiles.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';

import 'workspace_model_relationship_sheet.dart';

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
    if (mode == WorkspaceRouteMode.create) {
      return _WorkspaceModelForm(
        mode: mode,
        initialDraft: WorkspaceModelDraft.empty(),
        writeAccess: true,
      );
    }

    final id = modelId;
    if (id == null || id.isEmpty) {
      return WorkspaceEditorScaffold(
        title: l10n.workspaceModels,
        errorMessage: l10n.workspaceLoadFailed,
        child: const SizedBox.shrink(),
      );
    }

    final detail = ref.watch(workspaceModelDetailProvider(id));
    return detail.when(
      loading: () => WorkspaceEditorScaffold(
        title: l10n.workspaceModels,
        isLoading: true,
        child: const SizedBox.shrink(),
      ),
      error: (_, _) => WorkspaceEditorScaffold(
        title: l10n.workspaceModels,
        errorMessage: l10n.workspaceLoadFailed,
        onRetry: () => ref.invalidate(workspaceModelDetailProvider(id)),
        child: const SizedBox.shrink(),
      ),
      data: (value) {
        if (value == null) {
          return WorkspaceEditorScaffold(
            title: l10n.workspaceModels,
            errorMessage: l10n.workspaceLoadFailed,
            onRetry: () => ref.invalidate(workspaceModelDetailProvider(id)),
            child: const SizedBox.shrink(),
          );
        }
        return _WorkspaceModelForm(
          key: ValueKey('workspace-model-form-${value.id}-${mode.name}'),
          mode: mode,
          initialDraft: WorkspaceModelDraft.fromSummary(value),
          writeAccess: value.writeAccess,
          summary: value,
        );
      },
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
  late final TextEditingController _idController;
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _systemController;
  late final TextEditingController _stopController;
  late final TextEditingController _terminalController;
  late final TextEditingController _ttsController;
  late final TextEditingController _defaultFeaturesController;
  late final TextEditingController _paramsController;
  late final TextEditingController _builtinToolsController;

  bool _dirty = false;
  bool _saving = false;
  String? _errorMessage;
  String? _paramsError;
  // True once the user explicitly removes the avatar, so the editor renders the
  // placeholder instead of re-fetching the still-persisted server image (which
  // would silently undo the removal on screen until the model is saved).
  bool _avatarRemoved = false;

  bool get _isCreate => widget.mode == WorkspaceRouteMode.create;
  bool get _isDetail => widget.mode == WorkspaceRouteMode.detail;
  bool get _readOnly => !widget.writeAccess || _isDetail;

  @override
  void initState() {
    super.initState();
    _draft = WorkspaceModelDraft.fromSummary(_snapshot());
    _idController = TextEditingController(text: _draft.id);
    _nameController = TextEditingController(text: _draft.name);
    _descriptionController = TextEditingController(text: _draft.description);
    _systemController = TextEditingController(text: _draft.system);
    _stopController = TextEditingController(text: _draft.stop.join(', '));
    _terminalController = TextEditingController(text: _draft.terminalId);
    _ttsController = TextEditingController(text: _draft.ttsVoice);
    _defaultFeaturesController = TextEditingController(
      text: _draft.defaultFeatureIds.join(', '),
    );
    _paramsController = TextEditingController(
      text: _draft.advancedParams.isEmpty
          ? ''
          : const JsonEncoder.withIndent('  ').convert(_draft.advancedParams),
    );
    _builtinToolsController = TextEditingController(
      text: _draft.builtinTools.isEmpty
          ? ''
          : const JsonEncoder.withIndent('  ').convert(_draft.builtinTools),
    );
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
    _idController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _systemController.dispose();
    _stopController.dispose();
    _terminalController.dispose();
    _ttsController.dispose();
    _defaultFeaturesController.dispose();
    _paramsController.dispose();
    _builtinToolsController.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _update(void Function() mutate) {
    setState(() {
      mutate();
      _dirty = true;
    });
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
      setState(() => _paramsError = 'params');
      return false;
    }
    final builtin = _parseJsonObject(_builtinToolsController.text);
    if (builtin == null) {
      setState(() => _paramsError = 'builtinTools');
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
        () => _errorMessage = _draft.id.trim().isEmpty
            ? AppLocalizations.of(context)!.workspaceModelIdRequired
            : AppLocalizations.of(context)!.workspaceModelNameRequired,
      );
      return;
    }

    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    final notifier = ref.read(workspaceModelsProvider.notifier);
    final form = _draft.toForm();
    try {
      final WorkspaceModelDetail result = _isCreate
          ? await notifier.create(form)
          : await notifier.updateItem(form);
      if (!mounted) return;
      _dirty = false;
      _showSnack(AppLocalizations.of(context)!.workspaceModelSaved);
      DebugLogger.log(
        'model saved',
        scope: 'workspace/models',
        data: {'id': result.id, 'create': _isCreate},
      );
      final router = GoRouter.of(context);
      if (_isCreate) {
        router.pushReplacement(
          WorkspaceSection.models.routes.detailLocation(result.id),
        );
      } else if (router.canPop()) {
        router.pop();
      } else {
        // Edit saved with nothing to pop (deep-linked into /edit): release the
        // saving lock so the form stays usable.
        setState(() => _saving = false);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'model save failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorMessage = AppLocalizations.of(context)!.workspaceModelSaveFailed;
      });
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
    setState(() => _saving = true);
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
        setState(() => _saving = false);
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
    if (_dirty) {
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
    setState(() => _saving = true);
    try {
      await ref.read(workspaceModelsProvider.notifier).toggle(id);
      if (!mounted) return;
      _dirty = false;
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
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleHidden() async {
    final id = _draft.id;
    if (id.isEmpty) return;
    // There is no hidden-only endpoint, so this persists the whole model. Honour
    // the same validation as _save (abort on invalid params JSON) and reconcile
    // _dirty on success so the discard-changes guard does not later prompt for
    // changes that were already saved here.
    if (!_syncTextIntoDraft()) return;
    _draft.hidden = !_draft.hidden;
    setState(() => _saving = true);
    try {
      await ref
          .read(workspaceModelsProvider.notifier)
          .updateItem(_draft.toForm());
      if (!mounted) return;
      _dirty = false;
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
      if (mounted) setState(() => _saving = false);
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
    setState(() => _saving = true);
    try {
      await ref.read(workspaceModelsProvider.notifier).delete(id);
      if (!mounted) return;
      _dirty = false;
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
        setState(() => _saving = false);
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
    setState(() => _saving = true);
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
      if (mounted) setState(() => _saving = false);
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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final capabilities = ref
        .watch(workspaceCapabilitiesProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => WorkspaceCapabilities.none,
        );
    final title = _isCreate
        ? l10n.workspaceModelNewTitle
        : (_nameController.text.trim().isEmpty
              ? l10n.workspaceModels
              : _nameController.text.trim());

    return WorkspaceEditorScaffold(
      title: title,
      isDirty: _dirty && !_saving,
      readOnly: _readOnly,
      isSaving: _saving,
      canSave: !_readOnly,
      onSave: _readOnly ? null : _save,
      errorMessage: _errorMessage,
      actions: _buildActions(l10n, capabilities),
      bodyPadding: EdgeInsets.zero,
      child: AbsorbPointer(
        absorbing: _saving,
        child: ListView(
          key: const Key('workspace-model-editor-body'),
          padding: EdgeInsets.fromLTRB(
            Spacing.pagePadding,
            Spacing.md,
            Spacing.pagePadding,
            Spacing.pagePadding + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            if (_isDetail && widget.writeAccess)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: ConduitButton(
                  key: const Key('workspace-model-edit'),
                  text: l10n.edit,
                  icon: Icons.edit_outlined,
                  onPressed: () => context.push(
                    WorkspaceSection.models.routes.editLocation(_draft.id),
                  ),
                ),
              ),
            _profileImage(l10n),
            const SizedBox(height: Spacing.xl),
            WorkspaceSectionHeader(title: l10n.workspaceModelSectionBasics),
            _textField(
              key: 'workspace-model-id',
              controller: _idController,
              label: l10n.workspaceModelIdLabel,
              enabled: !_readOnly && _isCreate,
              onChanged: (_) => _markDirty(),
            ),
            _baseModelSelector(l10n),
            _textField(
              key: 'workspace-model-name',
              controller: _nameController,
              label: l10n.workspaceModelName,
              enabled: !_readOnly,
              onChanged: (_) => _markDirty(),
            ),
            _textField(
              key: 'workspace-model-description',
              controller: _descriptionController,
              label: l10n.workspaceModelDescription,
              enabled: !_readOnly,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => _markDirty(),
            ),
            _tagsField(l10n),
            const SizedBox(height: Spacing.xl),
            WorkspaceSectionHeader(title: l10n.workspaceModelSectionPrompt),
            _textField(
              key: 'workspace-model-system',
              controller: _systemController,
              label: l10n.workspaceModelSystemPrompt,
              enabled: !_readOnly,
              minLines: 3,
              maxLines: 10,
              onChanged: (_) => _markDirty(),
            ),
            _suggestionPrompts(l10n),
            const SizedBox(height: Spacing.xl),
            WorkspaceSectionHeader(title: l10n.workspaceModelSectionAdvanced),
            _textField(
              key: 'workspace-model-stop',
              controller: _stopController,
              label: l10n.workspaceModelStopSequences,
              helperText: l10n.workspaceModelStopHint,
              enabled: !_readOnly,
              onChanged: (_) => _markDirty(),
            ),
            _jsonField(
              key: 'workspace-model-params',
              controller: _paramsController,
              label: l10n.workspaceModelAdvancedParams,
              helperText: l10n.workspaceModelParamsHint,
              hasError: _paramsError == 'params',
            ),
            _capabilities(l10n),
            _textField(
              key: 'workspace-model-terminal',
              controller: _terminalController,
              label: l10n.workspaceModelTerminal,
              enabled: !_readOnly,
              onChanged: (_) => _markDirty(),
            ),
            _textField(
              key: 'workspace-model-tts',
              controller: _ttsController,
              label: l10n.workspaceModelTtsVoice,
              enabled: !_readOnly,
              onChanged: (_) => _markDirty(),
            ),
            _textField(
              key: 'workspace-model-default-features',
              controller: _defaultFeaturesController,
              label: l10n.workspaceModelDefaultFeatures,
              enabled: !_readOnly,
              onChanged: (_) => _markDirty(),
            ),
            _jsonField(
              key: 'workspace-model-builtin-tools',
              controller: _builtinToolsController,
              label: l10n.workspaceModelBuiltinTools,
              helperText: l10n.workspaceModelParamsHint,
              hasError: _paramsError == 'builtinTools',
            ),
            const SizedBox(height: Spacing.xl),
            WorkspaceSectionHeader(
              title: l10n.workspaceModelSectionRelationships,
            ),
            _knowledgeSelector(l10n),
            _relationshipTile(
              keyId: 'workspace-model-tools',
              label: l10n.workspaceModelTools,
              count: _draft.toolIds.length,
              onTap: _readOnly ? null : () => _pickTools(l10n),
            ),
            _relationshipTile(
              keyId: 'workspace-model-skills',
              label: l10n.workspaceModelSkills,
              count: _draft.skillIds.length,
              onTap: _readOnly ? null : () => _pickSkills(l10n),
            ),
            _relationshipTile(
              keyId: 'workspace-model-filters',
              label: l10n.workspaceModelFilters,
              count: _draft.filterIds.length,
              onTap: _readOnly
                  ? null
                  : () => _pickFunctions(l10n, isFilter: true),
            ),
            _relationshipTile(
              keyId: 'workspace-model-default-filters',
              label: l10n.workspaceModelDefaultFilters,
              count: _draft.defaultFilterIds.length,
              onTap: _readOnly
                  ? null
                  : () => _pickFunctions(l10n, isFilter: true, isDefault: true),
            ),
            _relationshipTile(
              keyId: 'workspace-model-actions',
              label: l10n.workspaceModelActions,
              count: _draft.actionIds.length,
              onTap: _readOnly
                  ? null
                  : () => _pickFunctions(l10n, isFilter: false),
            ),
            const SizedBox(height: Spacing.xl),
            WorkspaceSectionHeader(title: l10n.workspaceModelSectionAccess),
            _accessTile(l10n),
            const SizedBox(height: Spacing.xl),
          ],
        ),
      ),
    );
  }

  List<WorkspaceEditorAction> _buildActions(
    AppLocalizations l10n,
    WorkspaceCapabilities capabilities,
  ) {
    if (_isCreate) {
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

  // --- Field builders -------------------------------------------------------

  Widget _textField({
    required String key,
    required TextEditingController controller,
    required String label,
    required bool enabled,
    String? helperText,
    int minLines = 1,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: WorkspaceLabeledField(
        helperText: helperText,
        child: ConduitInput(
          key: Key(key),
          controller: controller,
          label: label,
          enabled: enabled,
          minLines: minLines,
          maxLines: maxLines < minLines ? minLines : maxLines,
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _jsonField({
    required String key,
    required TextEditingController controller,
    required String label,
    String? helperText,
    bool hasError = false,
  }) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: WorkspaceLabeledField(
        helperText: helperText,
        child: ConduitInput(
          key: Key(key),
          controller: controller,
          label: label,
          enabled: !_readOnly,
          minLines: 2,
          maxLines: 8,
          style: theme.code?.copyWith(color: theme.textPrimary),
          errorText: hasError
              ? AppLocalizations.of(context)!.workspaceModelInvalidJson
              : null,
          onChanged: (_) => _markDirty(),
        ),
      ),
    );
  }

  Widget _profileImage(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Row(
      children: [
        _ModelAvatar(
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

  Widget _baseModelSelector(AppLocalizations l10n) {
    // Base models are the raw `/models/base` options (not the general chat
    // model list, which also contains already-composed custom models).
    final models = ref
        .watch(workspaceBaseModelsProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => const <WorkspaceRelationshipOption>[],
        );
    // Drive the field from the draft's saved id. A `FormFieldState` only honours
    // `initialValue` on its first build, so `workspaceBaseModelsProvider`
    // resolving later must not be what first supplies the id — otherwise the
    // field is created with `null` (empty options) and stays on "None" even
    // though `_draft.baseModelId` holds the real id. We seed `initialValue` with
    // the saved id directly and guarantee it is always a selectable item (adding
    // a synthetic entry when the async options have not yet arrived or no longer
    // contain it), so an existing base model renders correctly from build one.
    final selectedId = _draft.baseModelId;
    final hasSelectedOption =
        selectedId == null || models.any((m) => m.id == selectedId);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: DropdownButtonFormField<String?>(
        key: const Key('workspace-model-base'),
        initialValue: selectedId,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: l10n.workspaceModelBaseModel,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem<String?>(
            value: null,
            child: Text(l10n.workspaceModelBaseModelNone),
          ),
          if (!hasSelectedOption)
            DropdownMenuItem<String?>(
              value: selectedId,
              child: Text(selectedId, overflow: TextOverflow.ellipsis),
            ),
          for (final model in models)
            DropdownMenuItem<String?>(
              value: model.id,
              child: Text(model.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: _readOnly
            ? null
            : (value) => _update(() => _draft.baseModelId = value),
      ),
    );
  }

  Widget _tagsField(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceModelTags, style: theme.label),
          const SizedBox(height: Spacing.xs),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              for (final tag in _draft.tags)
                InputChip(
                  key: Key('workspace-model-tag-$tag'),
                  label: Text(tag),
                  onDeleted: _readOnly
                      ? null
                      : () => _update(() => _draft.tags.remove(tag)),
                ),
              if (!_readOnly)
                ActionChip(
                  key: const Key('workspace-model-tag-add'),
                  avatar: const Icon(Icons.add, size: IconSize.small),
                  label: Text(l10n.workspaceModelTagsHint),
                  onPressed: () => _addTag(l10n),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _suggestionPrompts(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceModelSuggestionPrompts, style: theme.label),
          const SizedBox(height: Spacing.xs),
          for (var i = 0; i < _draft.suggestionPrompts.length; i++)
            AdaptiveListTile(
              key: Key('workspace-model-suggestion-$i'),
              padding: EdgeInsets.zero,
              title: Text(_draft.suggestionPrompts[i]),
              trailing: _readOnly
                  ? null
                  : IconButton(
                      tooltip: l10n.workspaceModelRemoveSuggestion,
                      icon: const Icon(Icons.close, size: IconSize.small),
                      onPressed: () =>
                          _update(() => _draft.suggestionPrompts.removeAt(i)),
                    ),
            ),
          if (!_readOnly)
            Align(
              alignment: Alignment.centerLeft,
              child: WorkspacePlainIconButton(
                buttonKey: const Key('workspace-model-suggestion-add'),
                onPressed: () => _addSuggestion(l10n),
                icon: Icons.add,
                label: l10n.workspaceModelAddSuggestion,
              ),
            ),
        ],
      ),
    );
  }

  Widget _capabilities(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.workspaceModelCapabilities,
            style: context.conduitTheme.label,
          ),
          for (final key in _draft.capabilities.keys)
            AdaptiveListTile(
              key: Key('workspace-model-capability-$key'),
              padding: EdgeInsets.zero,
              title: Text(key),
              trailing: AdaptiveSwitch(
                value: _draft.capabilities[key] ?? false,
                onChanged: _readOnly
                    ? null
                    : (value) =>
                          _update(() => _draft.capabilities[key] = value),
              ),
            ),
        ],
      ),
    );
  }

  Widget _relationshipTile({
    required String keyId,
    required String label,
    required int count,
    VoidCallback? onTap,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: WorkspaceResourceTile(
        key: Key(keyId),
        icon: Icons.account_tree_outlined,
        title: label,
        subtitle: count == 0
            ? l10n.workspaceModelSelectNone
            : l10n.workspaceModelSelectCount(count),
        onTap: onTap,
      ),
    );
  }

  Widget _knowledgeSelector(AppLocalizations l10n) {
    return _relationshipTile(
      keyId: 'workspace-model-knowledge',
      label: l10n.workspaceModelKnowledge,
      count: _draft.knowledge.length,
      onTap: _readOnly ? null : () => _pickKnowledge(l10n),
    );
  }

  Widget _accessTile(AppLocalizations l10n) {
    final principals = workspaceSharedPrincipals(_draft.normalizedAccessGrants);
    final isPublic = workspaceGrantsArePublic(_draft.normalizedAccessGrants);
    return WorkspaceResourceTile(
      key: const Key('workspace-model-access'),
      icon: isPublic ? Icons.public : Icons.lock_outline,
      title: l10n.workspaceModelManageAccess,
      subtitle: isPublic
          ? l10n.workspaceAccessVisibilityLabel
          : l10n.workspaceModelSelectCount(principals.length),
      onTap: _manageAccess,
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
      final bounded = await _boundAvatarBytes(bytes);
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

  /// Downscales [bytes] so the longest edge is at most [_avatarMaxEdge],
  /// re-encoding as PNG. Returns the original [bytes] unchanged when the image
  /// already fits, and falls back to the original on any decode/encode failure
  /// so picking an avatar never breaks.
  static const int _avatarMaxEdge = 512;

  Future<Uint8List> _boundAvatarBytes(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      final longest = width > height ? width : height;
      if (longest <= _avatarMaxEdge) {
        return bytes;
      }
      final scale = _avatarMaxEdge / longest;
      codec = await descriptor.instantiateCodec(
        targetWidth: (width * scale).round(),
        targetHeight: (height * scale).round(),
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List() ?? bytes;
    } catch (_) {
      return bytes;
    } finally {
      // Release every native handle even when a step above throws, disposing
      // the image/codec/descriptor before the backing buffer.
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
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

  Future<void> _pickKnowledge(AppLocalizations l10n) async {
    final List<WorkspaceRelationshipOption> options;
    try {
      options = await ref
          .read(workspaceKnowledgeProvider.future)
          .then(
            (state) => state.items
                .map(
                  (item) => WorkspaceRelationshipOption(
                    id: item.id,
                    label: item.name,
                    subtitle: item.description,
                  ),
                )
                .toList(),
          );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'knowledge relationship load failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceLoadFailed, isError: true);
      return;
    }
    if (!mounted) return;
    final selected = await WorkspaceRelationshipSheet.show(
      context,
      title: l10n.workspaceModelKnowledge,
      options: options,
      selectedIds: _draft.knowledge.map((ref) => ref.id).toList(),
    );
    if (selected == null) return;
    _update(() {
      _draft.knowledge = [
        for (final id in selected)
          _draft.knowledge.firstWhere(
            (ref) => ref.id == id,
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

  Future<void> _pickTools(AppLocalizations l10n) async {
    final List<WorkspaceRelationshipOption> options;
    try {
      options = await ref
          .read(workspaceToolsProvider.future)
          .then(
            (state) => state.items
                .map(
                  (t) => WorkspaceRelationshipOption(id: t.id, label: t.name),
                )
                .toList(),
          );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'tools relationship load failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceLoadFailed, isError: true);
      return;
    }
    if (!mounted) return;
    final selected = await WorkspaceRelationshipSheet.show(
      context,
      title: l10n.workspaceModelTools,
      options: options,
      selectedIds: _draft.toolIds,
    );
    if (selected != null) _update(() => _draft.toolIds = selected);
  }

  Future<void> _pickSkills(AppLocalizations l10n) async {
    final List<WorkspaceRelationshipOption> options;
    try {
      options = await ref
          .read(workspaceSkillsProvider.future)
          .then(
            (state) => state.items
                .map(
                  (s) => WorkspaceRelationshipOption(
                    id: s.id,
                    label: s.name,
                    subtitle: s.description,
                  ),
                )
                .toList(),
          );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'skills relationship load failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceLoadFailed, isError: true);
      return;
    }
    if (!mounted) return;
    final selected = await WorkspaceRelationshipSheet.show(
      context,
      title: l10n.workspaceModelSkills,
      options: options,
      selectedIds: _draft.skillIds,
    );
    if (selected != null) _update(() => _draft.skillIds = selected);
  }

  Future<void> _pickFunctions(
    AppLocalizations l10n, {
    required bool isFilter,
    bool isDefault = false,
  }) async {
    final List<WorkspaceFunctionRef> functions;
    try {
      functions = await ref.read(workspaceFunctionsProvider.future);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'functions relationship load failed',
        scope: 'workspace/models',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceLoadFailed, isError: true);
      return;
    }
    if (!mounted) return;
    final options = functions
        .where((fn) => isFilter ? fn.isFilter : fn.isAction)
        .map(
          (fn) => WorkspaceRelationshipOption(
            id: fn.id,
            label: fn.name,
            subtitle: fn.type,
          ),
        )
        .toList();
    final current = isFilter
        ? (isDefault ? _draft.defaultFilterIds : _draft.filterIds)
        : _draft.actionIds;
    final title = isFilter
        ? (isDefault
              ? l10n.workspaceModelDefaultFilters
              : l10n.workspaceModelFilters)
        : l10n.workspaceModelActions;
    final selected = await WorkspaceRelationshipSheet.show(
      context,
      title: title,
      options: options,
      selectedIds: current,
    );
    if (selected == null) return;
    _update(() {
      if (isFilter) {
        if (isDefault) {
          _draft.defaultFilterIds = selected;
        } else {
          _draft.filterIds = selected;
        }
      } else {
        _draft.actionIds = selected;
      }
    });
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

/// Renders the model's current profile image: from an inline draft data/URL, or
/// lazily fetched from the dedicated profile-image endpoint for saved models.
class _ModelAvatar extends ConsumerStatefulWidget {
  const _ModelAvatar({
    required this.draftImage,
    required this.modelId,
    this.removed = false,
  });

  final String? draftImage;
  final String modelId;

  /// When true the user has explicitly removed the avatar this session, so the
  /// persisted server image must not be re-fetched until the model is saved.
  final bool removed;

  @override
  ConsumerState<_ModelAvatar> createState() => _ModelAvatarState();
}

class _ModelAvatarState extends ConsumerState<_ModelAvatar> {
  // Memoized profile-image request, keyed by the model id it was issued for, so
  // parent rebuilds (e.g. every keystroke in the form) reuse the in-flight /
  // resolved future instead of firing a fresh request and flickering the avatar.
  Future<List<int>?>? _imageFuture;
  String? _fetchedModelId;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final draftImage = widget.draftImage;
    final modelId = widget.modelId;
    final placeholder = Container(
      key: const Key('workspace-model-avatar-placeholder'),
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: theme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppBorderRadius.medium),
      ),
      child: Icon(Icons.smart_toy_outlined, color: theme.iconSecondary),
    );

    Widget wrap(Widget child) => ClipRRect(
      borderRadius: BorderRadius.circular(AppBorderRadius.medium),
      child: SizedBox(width: 56, height: 56, child: child),
    );

    final inline = draftImage;
    if (inline != null && inline.startsWith('data:image')) {
      try {
        final bytes = base64Decode(inline.split(',').last);
        return wrap(Image.memory(bytes, fit: BoxFit.cover));
      } catch (_) {
        return placeholder;
      }
    }
    if (inline != null && inline.startsWith('http')) {
      return wrap(
        Image.network(
          inline,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => placeholder,
        ),
      );
    }
    // A fresh model or an explicit removal both render the placeholder without
    // reaching for the persisted server image.
    if (modelId.isEmpty || widget.removed) return placeholder;

    if (_fetchedModelId != modelId) {
      _fetchedModelId = modelId;
      _imageFuture = ref
          .read(apiServiceProvider)
          ?.getWorkspaceModelProfileImage(modelId);
    }

    return FutureBuilder<List<int>?>(
      future: _imageFuture,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null || data.isEmpty) return placeholder;
        return wrap(
          Image.memory(
            Uint8List.fromList(data),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder,
          ),
        );
      },
    );
  }
}

/// Shares one or more model definitions as a JSON file via the OS share sheet.
Future<void> exportWorkspaceModelsToShare(
  BuildContext context, {
  required List<Map<String, dynamic>> models,
  required String filename,
}) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    await WorkspaceExportController().shareJson(
      filename: filename,
      data: models,
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'model export share failed',
      scope: 'workspace/models',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) {
      AdaptiveSnackBar.show(
        context,
        message: l10n.workspaceModelExportFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }
}
