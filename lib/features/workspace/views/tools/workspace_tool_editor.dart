import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/models/workspace_tool_content.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_fields.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/widgets/workspace_export_controller.dart';
import 'package:conduit/features/workspace/widgets/workspace_import_sheet.dart';
import 'package:conduit/features/workspace/widgets/workspace_section_editors.dart';
import 'package:conduit/features/workspace/widgets/workspace_tool_url_import_sheet.dart';
import 'package:conduit/features/workspace/widgets/workspace_tool_valves_sheet.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';

/// Default Python scaffold for a new tool, mirroring Open WebUI's boilerplate.
const String _toolBoilerplate = '''"""
title: My Tool
description: Tools for performing various operations
required_open_webui_version: 0.10.2
version: 0.0.1
"""

import os
from pydantic import BaseModel, Field


class Tools:
    def __init__(self):
        pass

    # Add your custom tools using pure Python code here. Make sure to add type
    # hints and descriptions so the model knows how to call them.

    def get_current_time(self) -> str:
        """
        Get the current time in a human-readable format.
        """
        from datetime import datetime

        return datetime.now().strftime("%A, %B %d, %Y %I:%M:%S %p")
''';

/// Section-registry entry point for the Tools editor. Dispatches to the
/// create/detail/edit editor based on [WorkspaceEditorArgs.mode].
Widget buildWorkspaceToolEditor(BuildContext context, WorkspaceEditorArgs args) {
  return WorkspaceToolEditorView(
    key: ValueKey('workspace-tool-editor-${args.mode.name}-${args.resourceId}'),
    mode: args.mode,
    toolId: args.resourceId,
  );
}

class WorkspaceToolEditorView extends ConsumerWidget {
  const WorkspaceToolEditorView({super.key, required this.mode, this.toolId});

  final WorkspaceRouteMode mode;
  final String? toolId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (mode == WorkspaceRouteMode.create) {
      return const _WorkspaceToolForm(
        mode: WorkspaceRouteMode.create,
        summary: null,
      );
    }

    final id = toolId;
    if (id == null || id.isEmpty) {
      return WorkspaceEditorScaffold(
        title: l10n.workspaceTools,
        errorMessage: l10n.workspaceLoadFailed,
        child: const SizedBox.shrink(),
      );
    }

    final detail = ref.watch(workspaceToolDetailProvider(id));
    return detail.when(
      loading: () => WorkspaceEditorScaffold(
        title: l10n.workspaceTools,
        isLoading: true,
        child: const SizedBox.shrink(),
      ),
      error: (_, _) => WorkspaceEditorScaffold(
        title: l10n.workspaceTools,
        errorMessage: l10n.workspaceLoadFailed,
        onRetry: () => ref.invalidate(workspaceToolDetailProvider(id)),
        child: const SizedBox.shrink(),
      ),
      data: (value) {
        if (value == null) {
          return WorkspaceEditorScaffold(
            title: l10n.workspaceTools,
            errorMessage: l10n.workspaceLoadFailed,
            onRetry: () => ref.invalidate(workspaceToolDetailProvider(id)),
            child: const SizedBox.shrink(),
          );
        }
        return _WorkspaceToolForm(
          key: ValueKey('workspace-tool-form-${value.id}-${mode.name}'),
          mode: mode,
          summary: value,
        );
      },
    );
  }
}

/// The create/detail/edit form for a single workspace tool.
class _WorkspaceToolForm extends ConsumerStatefulWidget {
  const _WorkspaceToolForm({super.key, required this.mode, this.summary});

  final WorkspaceRouteMode mode;
  final WorkspaceToolSummary? summary;

  @override
  ConsumerState<_WorkspaceToolForm> createState() => _WorkspaceToolFormState();
}

class _WorkspaceToolFormState extends ConsumerState<_WorkspaceToolForm> {
  late final TextEditingController _nameController;
  late final TextEditingController _idController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _contentController;
  late List<WorkspaceAccessGrantInput> _grants;
  late Map<String, dynamic> _meta;

  bool _idManuallyEdited = false;
  bool _dirty = false;
  bool _saving = false;
  String? _errorMessage;
  bool _idError = false;

  bool get _isCreate => widget.mode == WorkspaceRouteMode.create;
  bool get _isDetail => widget.mode == WorkspaceRouteMode.detail;

  bool get _writeAccess => _isCreate || (widget.summary?.writeAccess ?? false);

  /// Fields are editable only in create/edit modes with write access. Detail is
  /// a read-only view. The id is additionally immutable once a tool exists.
  bool get _fieldsReadOnly => !_writeAccess || _isDetail;
  bool get _idReadOnly => _fieldsReadOnly || !_isCreate;

  @override
  void initState() {
    super.initState();
    final summary = widget.summary;
    _nameController = TextEditingController(text: summary?.name ?? '');
    _idController = TextEditingController(text: summary?.id ?? '');
    _meta = summary == null
        ? <String, dynamic>{'description': ''}
        : Map<String, dynamic>.from(summary.meta);
    _descriptionController = TextEditingController(
      text: _meta['description']?.toString() ?? '',
    );
    _contentController = TextEditingController(
      text: summary?.content ?? (summary == null ? _toolBoilerplate : ''),
    );
    _grants = [
      for (final grant in summary?.accessGrants ?? const [])
        WorkspaceAccessGrantInput.fromGrant(grant),
    ];
    // An existing tool already has an id, so treat it as user-set to keep the
    // slug from being clobbered while the user edits the name.
    _idManuallyEdited = summary != null;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    _descriptionController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _onNameChanged(String value) {
    if (_isCreate && !_idManuallyEdited) {
      _idController.text = WorkspaceToolContent.nameToId(value);
    }
    _markDirty();
  }

  void _onIdChanged(String _) {
    _idManuallyEdited = true;
    if (_idError) setState(() => _idError = false);
    _markDirty();
  }

  void _onContentChanged(String value) {
    if (_isCreate) _applyFrontmatterPrefill(value);
    // Recompute compatibility as the declared version changes.
    setState(() {});
    _markDirty();
  }

  /// Prefills name/id/description from the Python front-matter, but only for
  /// empty fields so a manual edit is never overwritten.
  void _applyFrontmatterPrefill(String content) {
    final fm = WorkspaceToolContent.parseFrontmatter(content);
    if (fm.isEmpty) return;
    final fmTitle = fm['title']?.trim() ?? '';
    final fmDescription = fm['description']?.trim() ?? '';
    if (fmTitle.isNotEmpty && _nameController.text.trim().isEmpty) {
      _nameController.text = WorkspaceToolContent.formatToolName(fmTitle);
      if (!_idManuallyEdited) {
        _idController.text = WorkspaceToolContent.nameToId(fmTitle);
      }
    }
    if (fmDescription.isNotEmpty &&
        _descriptionController.text.trim().isEmpty) {
      _descriptionController.text = fmDescription;
    }
  }

  WorkspaceCapabilities get _capabilities => ref
      .read(workspaceCapabilitiesProvider)
      .maybeWhen(
        data: (value) => value,
        orElse: () => WorkspaceCapabilities.none,
      );

  bool get _isAdmin => ref.read(currentUserProvider2)?.role == 'admin';

  // --- Compatibility --------------------------------------------------------

  /// The `required_open_webui_version` declared in the current source, or null.
  String? get _requiredVersion =>
      WorkspaceToolContent.requiredServerVersion(_contentController.text);

  String? get _currentServerVersion =>
      ref.watch(workspaceServerVersionProvider);

  /// Whether the current source is incompatible with the connected server.
  bool get _isIncompatible => !WorkspaceToolContent.meetsRequiredVersion(
    required: _requiredVersion,
    current: _currentServerVersion,
  );

  // --- Save -----------------------------------------------------------------

  /// Validates the shared fields. Returns the trimmed id on success, or null
  /// after surfacing the appropriate inline error.
  String? _validateForm(AppLocalizations l10n) {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _errorMessage = l10n.workspaceToolNameRequired);
      return null;
    }
    final id = _idController.text.trim();
    // The id is only editable (and therefore validated) in create mode; on edit
    // it is the immutable, already-validated server id.
    if (_isCreate) {
      if (id.isEmpty) {
        setState(() {
          _idError = true;
          _errorMessage = l10n.workspaceToolIdRequired;
        });
        return null;
      }
      if (!WorkspaceToolContent.isValidId(id)) {
        setState(() {
          _idError = true;
          _errorMessage = l10n.workspaceToolIdInvalid;
        });
        return null;
      }
    }
    if (_contentController.text.trim().isEmpty) {
      setState(() => _errorMessage = l10n.workspaceToolContentRequired);
      return null;
    }
    return id;
  }

  WorkspaceToolForm _buildForm({required String id}) {
    final meta = Map<String, dynamic>.from(_meta);
    meta['description'] = _descriptionController.text.trim();
    return WorkspaceToolForm(
      id: id,
      name: _nameController.text.trim(),
      content: _contentController.text,
      meta: meta,
      accessGrants: _grants,
    );
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    // Block save when the declared required version outranks the server.
    if (_isIncompatible) {
      setState(
        () => _errorMessage = l10n.workspaceToolIncompatible(
          _requiredVersion ?? '0.0.0',
          _currentServerVersion ?? '?',
        ),
      );
      return;
    }
    final id = _validateForm(l10n);
    if (id == null) return;
    setState(() {
      _saving = true;
      _errorMessage = null;
      _idError = false;
    });
    final notifier = ref.read(workspaceToolsProvider.notifier);
    // The update endpoint keys off the existing id; the id is immutable after
    // create, so submit the summary's id when editing.
    final form = _buildForm(id: _isCreate ? id : widget.summary!.id);
    try {
      final WorkspaceToolDetail result = _isCreate
          ? await notifier.create(form)
          : await notifier.updateItem(widget.summary!.id, form);
      if (!mounted) return;
      _dirty = false;
      DebugLogger.log(
        'tool saved',
        scope: 'workspace/tools',
        data: {'id': result.id, 'create': _isCreate},
      );
      _showSnack(l10n.workspaceToolSaved);
      final router = GoRouter.of(context);
      if (_isCreate) {
        router.pushReplacement(
          WorkspaceSection.tools.routes.detailLocation(result.id),
        );
      } else if (router.canPop()) {
        router.pop();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'tool save failed',
        scope: 'workspace/tools',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _idError = _isConflict(error);
        _errorMessage = _isConflict(error)
            ? l10n.workspaceToolIdTaken
            : l10n.workspaceToolSaveFailed;
      });
    }
  }

  // --- Overflow actions -----------------------------------------------------

  Future<void> _clone() async {
    final l10n = AppLocalizations.of(context)!;
    final router = GoRouter.of(context);
    final baseId = _idController.text.trim();
    final cloneId = baseId.isEmpty ? 'tool_clone' : '${baseId}_clone';
    setState(() => _saving = true);
    // Clones never inherit the source tool's sharing grants.
    final meta = Map<String, dynamic>.from(_meta);
    meta['description'] = _descriptionController.text.trim();
    final form = WorkspaceToolForm(
      id: cloneId,
      name: '${_nameController.text.trim()} ${l10n.workspaceToolCloneSuffix}',
      content: _contentController.text,
      meta: meta,
    );
    try {
      final created = await ref
          .read(workspaceToolsProvider.notifier)
          .create(form);
      if (!mounted) return;
      _showSnack(l10n.workspaceToolSaved);
      router.pushReplacement(
        WorkspaceSection.tools.routes.editLocation(created.id),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'tool clone failed',
        scope: 'workspace/tools',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _saving = false);
        _showSnack(l10n.workspaceToolSaveFailed, isError: true);
      }
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    if (summary == null) return;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.workspaceToolDeleteConfirmTitle,
      message: l10n.workspaceToolDeleteConfirmMessage(
        summary.name.isEmpty ? summary.id : summary.name,
      ),
      confirmText: l10n.delete,
      cancelText: l10n.cancel,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    final router = GoRouter.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(workspaceToolsProvider.notifier).delete(summary.id);
      if (!mounted) return;
      _dirty = false;
      _showSnack(l10n.workspaceToolDeleted);
      if (router.canPop()) {
        router.pop();
      } else {
        router.go(WorkspaceSection.tools.routes.collectionPath);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'tool delete failed',
        scope: 'workspace/tools',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _saving = false);
        _showSnack(l10n.workspaceToolSaveFailed, isError: true);
      }
    }
  }

  Future<void> _manageAccess() async {
    final l10n = AppLocalizations.of(context)!;
    final capabilities = _capabilities;
    final grants = await WorkspaceAccessGrantSheet.show(
      context,
      initialGrants: _grants,
      capabilities: capabilities.tools,
      allowUserGrants: capabilities.allowUserGrants,
      readOnly: !_writeAccess,
    );
    if (grants == null || !mounted) return;
    final summary = widget.summary;
    // In create mode (or without write access) grants are held locally and
    // persisted with the first save.
    if (summary == null || !_writeAccess) {
      setState(() {
        _grants = grants;
        if (summary == null) _dirty = true;
      });
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(workspaceToolsProvider.notifier)
          .updateAccess(summary.id, grants);
      if (!mounted) return;
      setState(() => _grants = grants);
      _showSnack(l10n.workspaceToolSaved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'tool access update failed',
        scope: 'workspace/tools',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceToolSaveFailed, isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openValves() async {
    final summary = widget.summary;
    if (summary == null) return;
    await WorkspaceToolValvesSheet.show(context, toolId: summary.id);
  }

  /// JSON import: creates one or many tools, reporting per-item success/failure
  /// without aborting the batch on the first error.
  Future<void> _importJson() async {
    final l10n = AppLocalizations.of(context)!;
    final report = await WorkspaceImportSheet.show(
      context,
      title: l10n.workspaceToolImport,
      importer: (items) => runWorkspaceImport(
        items,
        importItem: (item) => ref
            .read(workspaceToolsProvider.notifier)
            .importTool(_formFromImport(item)),
        labelOf: (item) =>
            item['name']?.toString() ?? item['id']?.toString() ?? '',
      ),
    );
    if (report != null && mounted) {
      // Refresh once so chat tool consumers reconcile after the batch.
      await ref.read(workspaceToolsProvider.notifier).refresh();
    }
  }

  /// Admin-only URL import: loads a tool definition (GitHub URLs normalized to
  /// raw) and prefills the unsaved create form for review before save.
  Future<void> _importUrl() async {
    final l10n = AppLocalizations.of(context)!;
    final tool = await WorkspaceToolUrlImportSheet.show(
      context,
      loader: (url) => ref.read(workspaceToolsProvider.notifier).loadFromUrl(url),
    );
    if (tool == null || !mounted) return;
    final normalized = normalizeImportedTool(tool);
    setState(() {
      _nameController.text = normalized['name']?.toString() ?? '';
      _idController.text = normalized['id']?.toString() ?? '';
      _meta = workspaceJsonMap(normalized['meta']);
      _descriptionController.text = _meta['description']?.toString() ?? '';
      _contentController.text = normalized['content']?.toString() ?? '';
      _idManuallyEdited = true;
      _dirty = true;
      _errorMessage = null;
      _idError = false;
    });
    _showSnack(l10n.workspaceToolImportUrlLoaded);
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    try {
      final notifier = ref.read(workspaceToolsProvider.notifier);
      // Detail/edit exports the single tool's full detail; create exports all.
      final List<Map<String, dynamic>> payload = summary == null
          ? await notifier.exportAll()
          : [await notifier.exportOne(summary.id)];
      if (!mounted) return;
      await WorkspaceExportController().shareJson(
        filename: summary == null ? 'tools' : 'tool-${summary.id}',
        data: payload,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'tool export failed',
        scope: 'workspace/tools',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceToolExportFailed, isError: true);
    }
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    final capabilities = ref
        .watch(workspaceCapabilitiesProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => WorkspaceCapabilities.none,
        );
    final title = _isCreate
        ? l10n.workspaceToolCreateTitle
        : (_nameController.text.trim().isEmpty
              ? l10n.workspaceTools
              : _nameController.text.trim());

    return WorkspaceEditorScaffold(
      title: title,
      isDirty: _dirty && !_saving,
      readOnly: _fieldsReadOnly,
      isSaving: _saving,
      canSave: !_fieldsReadOnly && !_isIncompatible,
      onSave: _fieldsReadOnly ? null : _save,
      errorMessage: _errorMessage,
      actions: _buildActions(l10n, capabilities),
      bodyPadding: EdgeInsets.zero,
      child: AbsorbPointer(
        absorbing: _saving,
        child: ListView(
          key: const Key('workspace-tool-editor-body'),
          padding: const EdgeInsets.all(Spacing.md),
          children: [
            if (_isDetail && _writeAccess)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: ConduitButton(
                  key: const Key('workspace-tool-edit'),
                  text: l10n.edit,
                  icon: Icons.edit_outlined,
                  onPressed: () => context.push(
                    WorkspaceSection.tools.routes.editLocation(summary!.id),
                  ),
                ),
              ),
            _nameField(l10n),
            const SizedBox(height: Spacing.sm),
            _idField(l10n),
            const SizedBox(height: Spacing.sm),
            _descriptionField(l10n),
            const SizedBox(height: Spacing.md),
            if (_isIncompatible) _incompatibilityBanner(l10n),
            _contentEditor(l10n),
            const SizedBox(height: Spacing.sm),
            _warning(l10n),
            const SizedBox(height: Spacing.md),
            if (summary != null) ...[
              _manifestSummary(l10n, summary),
              _specsSummary(l10n, summary),
            ],
            _accessTile(l10n),
            const SizedBox(height: Spacing.xl),
          ],
        ),
      ),
    );
  }

  Widget _nameField(AppLocalizations l10n) {
    return ConduitInput(
      key: const Key('workspace-tool-name'),
      controller: _nameController,
      label: l10n.workspaceToolName,
      hint: l10n.workspaceToolNameHint,
      enabled: !_fieldsReadOnly,
      onChanged: _onNameChanged,
      textInputAction: TextInputAction.next,
    );
  }

  Widget _idField(AppLocalizations l10n) {
    return WorkspaceLabeledField(
      helperText: l10n.workspaceToolIdHint,
      child: ConduitInput(
        key: const Key('workspace-tool-id'),
        controller: _idController,
        label: l10n.workspaceToolId,
        enabled: !_idReadOnly,
        onChanged: _onIdChanged,
        errorText: _idError ? l10n.workspaceToolIdInvalid : null,
      ),
    );
  }

  Widget _descriptionField(AppLocalizations l10n) {
    return ConduitInput(
      key: const Key('workspace-tool-description'),
      controller: _descriptionController,
      label: l10n.workspaceToolDescription,
      hint: l10n.workspaceToolDescriptionHint,
      enabled: !_fieldsReadOnly,
      onChanged: (_) => _markDirty(),
      textInputAction: TextInputAction.next,
    );
  }

  Widget _contentEditor(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.workspaceToolContent, style: theme.label),
        const SizedBox(height: Spacing.xs),
        AdaptiveTextField(
          key: const Key('workspace-tool-content'),
          controller: _contentController,
          enabled: !_fieldsReadOnly,
          minLines: 12,
          maxLines: 32,
          onChanged: _onContentChanged,
          style: theme.code?.copyWith(color: theme.textPrimary),
          placeholder: l10n.workspaceToolContentHint,
        ),
      ],
    );
  }

  Widget _incompatibilityBanner(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Container(
      key: const Key('workspace-tool-incompatible'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Spacing.md),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.errorBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.medium),
        border: Border.all(color: theme.error),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined, size: IconSize.small, color: theme.error),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              l10n.workspaceToolIncompatible(
                _requiredVersion ?? '0.0.0',
                _currentServerVersion ?? '?',
              ),
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _warning(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: IconSize.small,
          color: theme.textSecondary,
        ),
        const SizedBox(width: Spacing.xs),
        Expanded(
          child: Text(
            l10n.workspaceToolWarning,
            style: theme.caption?.copyWith(color: theme.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _manifestSummary(AppLocalizations l10n, WorkspaceToolSummary summary) {
    final manifest = workspaceJsonMap(summary.meta['manifest']);
    if (manifest.isEmpty) return const SizedBox.shrink();
    final theme = context.conduitTheme;
    final version = manifest['version']?.toString();
    final requiredVersion =
        manifest['required_open_webui_version']?.toString();
    final fundingUrl = manifest['funding_url']?.toString();
    return Padding(
      key: const Key('workspace-tool-manifest'),
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceToolManifest, style: theme.label),
          const SizedBox(height: Spacing.xxs),
          if (version != null && version.isNotEmpty)
            Text(
              l10n.workspaceToolManifestVersion(version),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          if (requiredVersion != null && requiredVersion.isNotEmpty)
            Text(
              l10n.workspaceToolManifestRequiredVersion(requiredVersion),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          if (fundingUrl != null && fundingUrl.isNotEmpty)
            Text(
              l10n.workspaceToolManifestFunding(fundingUrl),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
        ],
      ),
    );
  }

  Widget _specsSummary(AppLocalizations l10n, WorkspaceToolSummary summary) {
    final theme = context.conduitTheme;
    final specs = summary.specs;
    return Padding(
      key: const Key('workspace-tool-specs'),
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceToolSpecs, style: theme.label),
          const SizedBox(height: Spacing.xxs),
          if (specs.isEmpty)
            Text(
              l10n.workspaceToolSpecsEmpty,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            )
          else
            for (final spec in specs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      spec['name']?.toString() ?? '',
                      style: theme.bodyMedium?.copyWith(
                        color: theme.textPrimary,
                      ),
                    ),
                    if ((spec['description']?.toString() ?? '').isNotEmpty)
                      Text(
                        spec['description'].toString(),
                        style: theme.caption?.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _accessTile(AppLocalizations l10n) {
    final principals = workspaceSharedPrincipals(_grants);
    final isPublic = workspaceGrantsArePublic(_grants);
    return AdaptiveListTile(
      key: const Key('workspace-tool-access'),
      padding: EdgeInsets.zero,
      leading: Icon(isPublic ? Icons.public : Icons.lock_outline),
      title: Text(l10n.workspaceToolManageAccess),
      subtitle: Text(
        isPublic
            ? l10n.workspaceAccessVisibilityLabel
            : l10n.workspaceModelSelectCount(principals.length),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: _manageAccess,
    );
  }

  List<WorkspaceEditorAction> _buildActions(
    AppLocalizations l10n,
    WorkspaceCapabilities capabilities,
  ) {
    if (_isCreate) {
      return [
        if (capabilities.tools.importItems)
          WorkspaceEditorAction(
            label: l10n.workspaceToolImportJson,
            icon: Icons.data_object_outlined,
            menuKey: const Key('workspace-tool-action-import-json'),
            onSelected: _importJson,
          ),
        // URL import is admin-only, independent of the tools_import permission.
        if (_isAdmin)
          WorkspaceEditorAction(
            label: l10n.workspaceToolImportUrl,
            icon: Icons.link_outlined,
            menuKey: const Key('workspace-tool-action-import-url'),
            onSelected: _importUrl,
          ),
        if (capabilities.tools.exportItems)
          WorkspaceEditorAction(
            label: l10n.workspaceToolExport,
            icon: Icons.download_outlined,
            menuKey: const Key('workspace-tool-action-export'),
            onSelected: _export,
          ),
      ];
    }
    final summary = widget.summary;
    if (summary == null) return const [];
    final canWrite = _writeAccess;
    return [
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspaceToolClone,
          icon: Icons.copy_outlined,
          menuKey: const Key('workspace-tool-action-clone'),
          onSelected: _clone,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspaceToolValves,
          icon: Icons.tune_outlined,
          menuKey: const Key('workspace-tool-action-valves'),
          onSelected: _openValves,
        ),
      WorkspaceEditorAction(
        label: l10n.workspaceToolManageAccess,
        icon: Icons.group_outlined,
        menuKey: const Key('workspace-tool-action-access'),
        onSelected: _manageAccess,
      ),
      if (capabilities.tools.exportItems)
        WorkspaceEditorAction(
          label: l10n.workspaceToolExport,
          icon: Icons.download_outlined,
          menuKey: const Key('workspace-tool-action-export'),
          onSelected: _export,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspaceToolDelete,
          icon: Icons.delete_outline,
          isDestructive: true,
          menuKey: const Key('workspace-tool-action-delete'),
          onSelected: _delete,
        ),
    ];
  }

  // --- Interactions ---------------------------------------------------------

  void _showSnack(String message, {bool isError = false}) {
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: isError ? AdaptiveSnackBarType.error : AdaptiveSnackBarType.success,
    );
  }

  WorkspaceToolForm _formFromImport(Map<String, dynamic> json) {
    final normalized = normalizeImportedTool(json);
    final rawId = normalized['id']?.toString().trim() ?? '';
    final name = normalized['name']?.toString() ?? '';
    final id = rawId.isEmpty ? WorkspaceToolContent.nameToId(name) : rawId;
    return WorkspaceToolForm(
      id: id,
      name: name,
      content: normalized['content']?.toString() ?? '',
      meta: workspaceJsonMap(normalized['meta']),
    );
  }

  static bool _isConflict(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      return status == 400 || status == 409;
    }
    return false;
  }
}
