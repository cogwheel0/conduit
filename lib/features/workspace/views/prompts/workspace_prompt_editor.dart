import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/models/workspace_prompt_command.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/views/prompts/workspace_prompt_history.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_mutation_coordinator.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_session.dart';
import 'package:conduit/features/workspace/widgets/workspace_resource_editor_host.dart';
import 'package:conduit/features/workspace/widgets/workspace_export_controller.dart';
import 'package:conduit/features/workspace/widgets/workspace_import_sheet.dart';
import 'package:conduit/features/workspace/widgets/workspace_section_editors.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:conduit/shared/widgets/utility_components.dart';

import 'workspace_prompt_editor_sections.dart';

/// Section-registry entry point for the Prompts editor. Dispatches to the
/// create/detail/edit editor based on [WorkspaceEditorArgs.mode].
Widget buildWorkspacePromptEditor(
  BuildContext context,
  WorkspaceEditorArgs args,
) {
  return WorkspacePromptEditorView(
    key: ValueKey(
      'workspace-prompt-editor-${args.mode.name}-${args.resourceId}',
    ),
    mode: args.mode,
    promptId: args.resourceId,
  );
}

class WorkspacePromptEditorView extends ConsumerWidget {
  const WorkspacePromptEditorView({
    super.key,
    required this.mode,
    this.promptId,
  });

  final WorkspaceRouteMode mode;
  final String? promptId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return WorkspaceResourceEditorRoute<WorkspacePromptSummary>(
      title: l10n.workspacePrompts,
      section: WorkspaceSection.prompts,
      mode: mode,
      resourceId: promptId,
      errorMessage: l10n.workspaceLoadFailed,
      createBuilder: () => const _WorkspacePromptForm(
        mode: WorkspaceRouteMode.create,
        summary: null,
      ),
      detailLoader: (ref, id) => ref.watch(workspacePromptDetailProvider(id)),
      onRetry: (ref, id) => ref.invalidate(workspacePromptDetailProvider(id)),
      builder: (value) => _WorkspacePromptForm(
        key: ValueKey('workspace-prompt-form-${value.id}-${mode.name}'),
        mode: mode,
        summary: value,
      ),
    );
  }
}

/// The create/detail/edit form for a single workspace prompt.
class _WorkspacePromptForm extends ConsumerStatefulWidget {
  const _WorkspacePromptForm({super.key, required this.mode, this.summary});

  final WorkspaceRouteMode mode;
  final WorkspacePromptSummary? summary;

  @override
  ConsumerState<_WorkspacePromptForm> createState() =>
      _WorkspacePromptFormState();
}

class _WorkspacePromptFormState extends ConsumerState<_WorkspacePromptForm> {
  late final TextEditingController _nameController;
  late final TextEditingController _commandController;
  late final TextEditingController _contentController;
  late final TextEditingController _commitController;
  late List<String> _tags;
  late List<WorkspaceAccessGrantInput> _grants;
  late String? _versionId;

  bool _isProduction = true;
  bool _previewMode = false;
  bool _versionExpanded = false;
  bool _commandManuallyEdited = false;
  late final WorkspaceEditorSession _session;
  bool _commandError = false;

  bool get _writeAccess =>
      _session.isCreate || (widget.summary?.writeAccess ?? false);

  /// The prompt fields (name/command/content/tags) are editable only in
  /// create/edit modes with write access. Detail is a read-only view.
  bool get _fieldsReadOnly => !_writeAccess || _session.isDetail;

  @override
  void initState() {
    super.initState();
    _session = WorkspaceEditorSession(widget.mode)
      ..addListener(_handleSessionChanged);
    final summary = widget.summary;
    _nameController = TextEditingController(text: summary?.name ?? '');
    _commandController = TextEditingController(
      text: summary == null
          ? ''
          : WorkspacePromptCommand.strip(summary.command),
    );
    _contentController = TextEditingController(text: summary?.content ?? '');
    _commitController = TextEditingController();
    _tags = [...?summary?.tags];
    _grants = [
      for (final grant in summary?.accessGrants ?? const [])
        WorkspaceAccessGrantInput.fromGrant(grant),
    ];
    _versionId = summary?.versionId;
    // An existing prompt already has a command, so treat it as user-set to
    // avoid slugify clobbering it while the user edits the name.
    _commandManuallyEdited = summary != null;
  }

  @override
  void dispose() {
    _session.removeListener(_handleSessionChanged);
    _session.dispose();
    _nameController.dispose();
    _commandController.dispose();
    _contentController.dispose();
    _commitController.dispose();
    super.dispose();
  }

  void _handleSessionChanged() {
    if (mounted) setState(() {});
  }

  void _markDirty() {
    _session.markDirty();
  }

  void _onNameChanged(String value) {
    if (_session.isCreate && !_commandManuallyEdited) {
      _commandController.text = WorkspacePromptCommand.slugify(value);
    }
    _markDirty();
  }

  void _onCommandChanged(String _) {
    _commandManuallyEdited = true;
    if (_commandError) setState(() => _commandError = false);
    _markDirty();
  }

  WorkspaceCapabilities get _capabilities => ref
      .read(workspaceCapabilitiesProvider)
      .maybeWhen(
        data: (value) => value,
        orElse: () => WorkspaceCapabilities.none,
      );

  // --- Save -----------------------------------------------------------------

  /// Validates the shared fields. Returns the stripped command on success, or
  /// null after surfacing the appropriate inline error.
  String? _validateForm(AppLocalizations l10n) {
    if (_nameController.text.trim().isEmpty) {
      _session.setError(l10n.workspacePromptNameRequired);
      return null;
    }
    final command = WorkspacePromptCommand.strip(_commandController.text);
    if (!WorkspacePromptCommand.isValid(command)) {
      setState(() => _commandError = true);
      _session.setError(
        command.isEmpty
            ? l10n.workspacePromptCommandRequired
            : l10n.workspacePromptCommandInvalid,
      );
      return null;
    }
    if (_contentController.text.trim().isEmpty) {
      _session.setError(l10n.workspacePromptContentRequired);
      return null;
    }
    return command;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final command = _validateForm(l10n);
    if (command == null) return;
    setState(() => _commandError = false);
    final notifier = ref.read(workspacePromptsProvider.notifier);
    final commit = _commitController.text.trim();
    final form = WorkspacePromptForm(
      command: command,
      name: _nameController.text.trim(),
      content: _contentController.text,
      tags: _tags,
      accessGrants: _grants,
      versionId: _versionId,
      commitMessage: commit.isEmpty ? null : commit,
      isProduction: _isProduction,
    );
    await WorkspaceEditorMutationCoordinator.run<WorkspacePromptDetail>(
      context: context,
      session: _session,
      section: WorkspaceSection.prompts,
      scope: 'workspace/prompts',
      resourceLabel: 'prompt',
      successMessage: l10n.workspacePromptSaved,
      failureMessage: l10n.workspacePromptSaveFailed,
      editorMounted: () => mounted,
      mutate: (isCreate) => isCreate
          ? notifier.create(form)
          : notifier.updateItem(widget.summary!.id, form),
      resourceId: (result) => result.id,
      errorMessage: (error) {
        final commandTaken = _isCommandTaken(error);
        setState(() => _commandError = commandTaken);
        return commandTaken
            ? l10n.workspacePromptCommandTaken
            : l10n.workspacePromptSaveFailed;
      },
    );
  }

  /// Metadata-only update: persists name/command/tags without creating a new
  /// history version.
  Future<void> _updateDetailsOnly() async {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    if (summary == null) return;
    if (_nameController.text.trim().isEmpty) {
      _session.setError(l10n.workspacePromptNameRequired);
      return;
    }
    final command = WorkspacePromptCommand.strip(_commandController.text);
    if (!WorkspacePromptCommand.isValid(command)) {
      setState(() => _commandError = true);
      _session.setError(l10n.workspacePromptCommandInvalid);
      return;
    }
    setState(() => _commandError = false);
    if (!_session.beginOperation(clearError: true)) return;
    try {
      await ref
          .read(workspacePromptsProvider.notifier)
          .updateMetadata(
            summary.id,
            name: _nameController.text.trim(),
            command: command,
            tags: _tags,
          );
      if (!mounted) return;
      _session.markClean();
      _showSnack(l10n.workspacePromptDetailsSaved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt metadata update failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      final commandTaken = _isCommandTaken(error);
      setState(() => _commandError = commandTaken);
      _session.setError(
        commandTaken
            ? l10n.workspacePromptCommandTaken
            : l10n.workspacePromptSaveFailed,
      );
    } finally {
      if (mounted) _session.endOperation();
    }
  }

  // --- Overflow actions -----------------------------------------------------

  Future<void> _clone() async {
    final l10n = AppLocalizations.of(context)!;
    final router = GoRouter.of(context);
    final baseCommand = WorkspacePromptCommand.strip(_commandController.text);
    final cloneCommand = WorkspacePromptCommand.slugify(
      '$baseCommand-${l10n.workspacePromptCloneSuffix}',
    );
    if (!_session.beginOperation()) return;
    // Clones never inherit the source prompt's sharing grants.
    final form = WorkspacePromptForm(
      command: cloneCommand.isEmpty ? '$baseCommand-copy' : cloneCommand,
      name: '${_nameController.text.trim()} ${l10n.workspacePromptCloneSuffix}',
      content: _contentController.text,
      tags: _tags,
    );
    try {
      final created = await ref
          .read(workspacePromptsProvider.notifier)
          .create(form);
      if (!mounted) return;
      _showSnack(l10n.workspacePromptSaved);
      router.pushReplacement(
        WorkspaceSection.prompts.routes.editLocation(created.id),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt clone failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _session.endOperation();
        _showSnack(l10n.workspacePromptSaveFailed, isError: true);
      }
    }
  }

  Future<void> _toggleActive() async {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    if (summary == null) return;
    if (!_session.beginOperation()) return;
    try {
      await ref.read(workspacePromptsProvider.notifier).toggle(summary.id);
      if (!mounted) return;
      _showSnack(l10n.workspacePromptSaved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt toggle failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspacePromptSaveFailed, isError: true);
    } finally {
      if (mounted) _session.endOperation();
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    if (summary == null) return;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.workspacePromptDeleteConfirmTitle,
      message: l10n.workspacePromptDeleteConfirmMessage(
        summary.name.isEmpty ? summary.command : summary.name,
      ),
      confirmText: l10n.delete,
      cancelText: l10n.cancel,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    final router = GoRouter.of(context);
    if (!_session.beginOperation()) return;
    try {
      await ref.read(workspacePromptsProvider.notifier).delete(summary.id);
      if (!mounted) return;
      _session.markClean();
      _showSnack(l10n.workspacePromptDeleted);
      if (router.canPop()) {
        router.pop();
      } else {
        router.go(WorkspaceSection.prompts.routes.collectionPath);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt delete failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _session.endOperation();
        _showSnack(l10n.workspacePromptSaveFailed, isError: true);
      }
    }
  }

  Future<void> _manageAccess() async {
    final l10n = AppLocalizations.of(context)!;
    final capabilities = _capabilities;
    final grants = await WorkspaceAccessGrantSheet.show(
      context,
      initialGrants: _grants,
      capabilities: capabilities.prompts,
      allowUserGrants: capabilities.allowUserGrants,
      readOnly: !_writeAccess,
    );
    if (grants == null || !mounted) return;
    final summary = widget.summary;
    // In create mode (or without write access) the grants are held locally and
    // persisted with the first save.
    if (summary == null || !_writeAccess) {
      setState(() => _grants = grants);
      if (summary == null) _session.markDirty();
      return;
    }
    if (!_session.beginOperation()) return;
    try {
      await ref
          .read(workspacePromptsProvider.notifier)
          .updateAccess(summary.id, grants);
      if (!mounted) return;
      setState(() => _grants = grants);
      _showSnack(l10n.workspacePromptSaved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt access update failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspacePromptSaveFailed, isError: true);
    } finally {
      if (mounted) _session.endOperation();
    }
  }

  Future<void> _import() async {
    final l10n = AppLocalizations.of(context)!;
    final report = await WorkspaceImportSheet.show(
      context,
      title: l10n.workspacePromptImport,
      importer: (items) => runWorkspaceImport(
        items,
        importItem: (item) => ref
            .read(workspacePromptsProvider.notifier)
            .importPrompt(_formFromImport(item)),
        labelOf: (item) =>
            item['name']?.toString() ?? item['command']?.toString() ?? '',
      ),
    );
    if (report != null && mounted) {
      // Refresh once so slash suggestions pick up the imported prompts.
      await ref.read(workspacePromptsProvider.notifier).refresh();
    }
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      // Export the full list (all pages), not just the pages currently loaded
      // into the paginated in-UI state, so the backup is complete.
      final items = await ref
          .read(workspacePromptsProvider.notifier)
          .loadAllForExport();
      if (!mounted) return;
      final payload = [for (final item in items) _exportMap(item)];
      await WorkspaceExportController().shareJson(
        filename: 'prompts',
        data: payload,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt export failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspacePromptExportFailed, isError: true);
    }
  }

  void _restoreFromSnapshot(Map<String, dynamic> snapshot) {
    // Restore the editable body only. The command and sharing grants are the
    // prompt's identity/permissions and must never be replaced by a restore.
    final content = snapshot['content']?.toString();
    final name = snapshot['name']?.toString();
    setState(() {
      if (content != null) _contentController.text = content;
      if (name != null && name.isNotEmpty) _nameController.text = name;
      // Always assign — a restored version that cleared its tags must clear the
      // current tags too, otherwise stale tags survive the restore.
      _tags = workspaceStringList(snapshot['tags']);
      _previewMode = false;
    });
    _session.markDirty();
    _showSnack(AppLocalizations.of(context)!.workspacePromptHistoryRestored);
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) => _buildContent(context);

  Widget _buildContent(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    // Watch so the overflow actions rebuild once capabilities resolve.
    final capabilities = ref
        .watch(workspaceCapabilitiesProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => WorkspaceCapabilities.none,
        );
    final title = _session.isCreate
        ? l10n.workspacePromptCreateTitle
        : (_nameController.text.trim().isEmpty
              ? l10n.workspacePrompts
              : _nameController.text.trim());

    return WorkspaceEditorScaffold(
      title: title,
      section: WorkspaceSection.prompts,
      mode: widget.mode,
      isDirty: _session.dirty && !_session.saving,
      readOnly: _fieldsReadOnly,
      isSaving: _session.saving,
      canSave: !_fieldsReadOnly,
      onSave: _fieldsReadOnly ? null : _save,
      onEdit: _session.isDetail && _writeAccess
          ? () => context.push(
              WorkspaceSection.prompts.routes.editLocation(summary!.id),
            )
          : null,
      errorMessage: _session.errorMessage,
      actions: buildWorkspacePromptActions(
        l10n: l10n,
        capabilities: capabilities,
        isCreate: _session.isCreate,
        isEdit: _session.isEdit,
        canWrite: _writeAccess,
        summary: summary,
        onImport: _import,
        onExport: _export,
        onClone: _clone,
        onUpdateDetails: _updateDetailsOnly,
        onToggleActive: _toggleActive,
        onManageAccess: _manageAccess,
        onDelete: _delete,
      ),
      bodyPadding: EdgeInsets.zero,
      child: AbsorbPointer(
        absorbing: _session.saving,
        child: ListView(
          key: const Key('workspace-prompt-editor-body'),
          padding: EdgeInsets.fromLTRB(
            Spacing.pagePadding,
            Spacing.md,
            Spacing.pagePadding,
            Spacing.pagePadding + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            InsetGroupedSection(
              title: l10n.workspacePrompts,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  WorkspacePromptCoreFields(
                    isDetail: _session.isDetail,
                    readOnly: _fieldsReadOnly,
                    commandError: _commandError,
                    nameController: _nameController,
                    commandController: _commandController,
                    tags: _tags,
                    onNameChanged: _onNameChanged,
                    onCommandChanged: _onCommandChanged,
                    onRemoveTag: (tag) {
                      setState(() => _tags = [..._tags]..remove(tag));
                      _session.markDirty();
                    },
                    onAddTag: () => _addTag(l10n),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Spacing.xl),
            WorkspacePromptContentEditor(
              isDetail: _session.isDetail,
              readOnly: _fieldsReadOnly,
              previewMode: _previewMode,
              controller: _contentController,
              onPreviewModeChanged: (value) =>
                  setState(() => _previewMode = value),
              onContentChanged: _markDirty,
            ),
            if (!_fieldsReadOnly) ...[
              const SizedBox(height: Spacing.xl),
              WorkspacePromptVersionSection(
                readOnly: _fieldsReadOnly,
                expanded: _versionExpanded,
                isProduction: _isProduction,
                commitController: _commitController,
                onExpandedChanged: (value) =>
                    setState(() => _versionExpanded = value),
                onCommitChanged: _markDirty,
                onProductionChanged: (value) {
                  setState(() => _isProduction = value);
                  _session.markDirty();
                },
              ),
            ],
            const SizedBox(height: Spacing.xl),
            WorkspacePromptAccessTile(grants: _grants, onTap: _manageAccess),
            if (!_session.isCreate && summary != null) ...[
              const SizedBox(height: Spacing.xl),
              WorkspacePromptHistorySection(
                key: Key('workspace-prompt-history-${summary.id}'),
                promptId: summary.id,
                productionVersionId: _versionId,
                canMutate: _writeAccess,
                canRestore: !_fieldsReadOnly,
                onRestore: _restoreFromSnapshot,
                onProductionChanged: (versionId) {
                  if (mounted) setState(() => _versionId = versionId);
                },
              ),
            ],
            const SizedBox(height: Spacing.xl),
          ],
        ),
      ),
    );
  }

  Future<void> _addTag(AppLocalizations l10n) async {
    final value = await ThemedDialogs.promptTextInput(
      context,
      title: l10n.workspacePromptTagAdd,
      hintText: l10n.workspacePromptTagAdd,
    );
    final tag = value?.trim() ?? '';
    // Guard against the editor being disposed while the tag dialog was open
    // (e.g. a live permission revocation removes the route): a setState after
    // dispose throws.
    if (tag.isEmpty || _tags.contains(tag) || !mounted) return;
    setState(() => _tags = [..._tags, tag]);
    _session.markDirty();
  }

  void _showSnack(String message, {bool isError = false}) {
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: isError ? AdaptiveSnackBarType.error : AdaptiveSnackBarType.success,
    );
  }

  Map<String, dynamic> _exportMap(WorkspacePromptSummary item) => {
    'command': WorkspacePromptCommand.strip(item.command),
    'name': item.name,
    'content': item.content,
    'tags': item.tags,
    if (item.meta != null) 'meta': item.meta,
    if (item.data != null) 'data': item.data,
  };

  WorkspacePromptForm _formFromImport(Map<String, dynamic> json) {
    final rawCommand = json['command']?.toString() ?? '';
    final name = json['name']?.toString() ?? json['title']?.toString() ?? '';
    final command = WorkspacePromptCommand.strip(rawCommand);
    return WorkspacePromptForm(
      command: command.isEmpty ? WorkspacePromptCommand.slugify(name) : command,
      name: name,
      content: json['content']?.toString() ?? '',
      tags: workspaceStringList(json['tags']),
      meta: json['meta'] is Map ? workspaceJsonMap(json['meta']) : null,
      data: json['data'] is Map ? workspaceJsonMap(json['data']) : null,
    );
  }

  static bool _isCommandTaken(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      final detail = error.response?.data;
      final message = detail is Map ? detail['detail']?.toString() : null;
      return status == 400 &&
          (message == null || message.toLowerCase().contains('command'));
    }
    return false;
  }
}
