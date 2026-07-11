import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
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
import 'package:conduit/features/workspace/widgets/workspace_editor_fields.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/widgets/workspace_export_controller.dart';
import 'package:conduit/features/workspace/widgets/workspace_import_sheet.dart';
import 'package:conduit/features/workspace/widgets/workspace_section_editors.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';

/// Section-registry entry point for the Prompts editor. Dispatches to the
/// create/detail/edit editor based on [WorkspaceEditorArgs.mode].
Widget buildWorkspacePromptEditor(
  BuildContext context,
  WorkspaceEditorArgs args,
) {
  return WorkspacePromptEditorView(
    key: ValueKey('workspace-prompt-editor-${args.mode.name}-${args.resourceId}'),
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
    if (mode == WorkspaceRouteMode.create) {
      return const _WorkspacePromptForm(
        mode: WorkspaceRouteMode.create,
        summary: null,
      );
    }

    final id = promptId;
    if (id == null || id.isEmpty) {
      return WorkspaceEditorScaffold(
        title: l10n.workspacePrompts,
        errorMessage: l10n.workspaceLoadFailed,
        child: const SizedBox.shrink(),
      );
    }

    final detail = ref.watch(workspacePromptDetailProvider(id));
    return detail.when(
      loading: () => WorkspaceEditorScaffold(
        title: l10n.workspacePrompts,
        isLoading: true,
        child: const SizedBox.shrink(),
      ),
      error: (_, _) => WorkspaceEditorScaffold(
        title: l10n.workspacePrompts,
        errorMessage: l10n.workspaceLoadFailed,
        onRetry: () => ref.invalidate(workspacePromptDetailProvider(id)),
        child: const SizedBox.shrink(),
      ),
      data: (value) {
        if (value == null) {
          return WorkspaceEditorScaffold(
            title: l10n.workspacePrompts,
            errorMessage: l10n.workspaceLoadFailed,
            onRetry: () => ref.invalidate(workspacePromptDetailProvider(id)),
            child: const SizedBox.shrink(),
          );
        }
        return _WorkspacePromptForm(
          key: ValueKey('workspace-prompt-form-${value.id}-${mode.name}'),
          mode: mode,
          summary: value,
        );
      },
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
  bool _commandManuallyEdited = false;
  bool _dirty = false;
  bool _saving = false;
  String? _errorMessage;
  bool _commandError = false;

  bool get _isCreate => widget.mode == WorkspaceRouteMode.create;
  bool get _isDetail => widget.mode == WorkspaceRouteMode.detail;
  bool get _isEdit => widget.mode == WorkspaceRouteMode.edit;

  bool get _writeAccess => _isCreate || (widget.summary?.writeAccess ?? false);

  /// The prompt fields (name/command/content/tags) are editable only in
  /// create/edit modes with write access. Detail is a read-only view.
  bool get _fieldsReadOnly => !_writeAccess || _isDetail;

  @override
  void initState() {
    super.initState();
    final summary = widget.summary;
    _nameController = TextEditingController(text: summary?.name ?? '');
    _commandController = TextEditingController(
      text: summary == null ? '' : WorkspacePromptCommand.strip(summary.command),
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
    _nameController.dispose();
    _commandController.dispose();
    _contentController.dispose();
    _commitController.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _onNameChanged(String value) {
    if (_isCreate && !_commandManuallyEdited) {
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
      .maybeWhen(data: (value) => value, orElse: () => WorkspaceCapabilities.none);

  // --- Save -----------------------------------------------------------------

  /// Validates the shared fields. Returns the stripped command on success, or
  /// null after surfacing the appropriate inline error.
  String? _validateForm(AppLocalizations l10n) {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _errorMessage = l10n.workspacePromptNameRequired);
      return null;
    }
    final command = WorkspacePromptCommand.strip(_commandController.text);
    if (!WorkspacePromptCommand.isValid(command)) {
      setState(() {
        _commandError = true;
        _errorMessage = command.isEmpty
            ? l10n.workspacePromptCommandRequired
            : l10n.workspacePromptCommandInvalid;
      });
      return null;
    }
    if (_contentController.text.trim().isEmpty) {
      setState(() => _errorMessage = l10n.workspacePromptContentRequired);
      return null;
    }
    return command;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final command = _validateForm(l10n);
    if (command == null) return;
    setState(() {
      _saving = true;
      _errorMessage = null;
      _commandError = false;
    });
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
    // Capture the router and a root overlay context *before* the await: on the
    // edit path `updateItem` invalidates `workspacePromptDetailProvider`, which
    // the parent view watches — the parent rebuilds into its loading branch and
    // disposes this form before the future resolves, so `mounted` is false by
    // the time we get here. Driving navigation/snackbar off these captured
    // references (instead of gating the whole success path on `mounted`) ensures
    // a successful edit still pops and releases the saving lock.
    final router = GoRouter.of(context);
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    try {
      final WorkspacePromptDetail result = _isCreate
          ? await notifier.create(form)
          : await notifier.updateItem(widget.summary!.id, form);
      _dirty = false;
      DebugLogger.log(
        'prompt saved',
        scope: 'workspace/prompts',
        data: {'id': result.id, 'create': _isCreate},
      );
      if (rootContext.mounted) {
        _showSnack(l10n.workspacePromptSaved, overlayContext: rootContext);
      }
      if (_isCreate) {
        router.pushReplacement(
          WorkspaceSection.prompts.routes.detailLocation(result.id),
        );
      } else if (router.canPop()) {
        router.pop();
      } else if (mounted) {
        // Edit saved with nothing to pop (deep-linked into /edit): release the
        // saving lock so the form does not stay stuck behind AbsorbPointer.
        setState(() => _saving = false);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt save failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _commandError = _isCommandTaken(error);
        _errorMessage = _isCommandTaken(error)
            ? l10n.workspacePromptCommandTaken
            : l10n.workspacePromptSaveFailed;
      });
    }
  }

  /// Metadata-only update: persists name/command/tags without creating a new
  /// history version.
  Future<void> _updateDetailsOnly() async {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    if (summary == null) return;
    if (_nameController.text.trim().isEmpty) {
      setState(() => _errorMessage = l10n.workspacePromptNameRequired);
      return;
    }
    final command = WorkspacePromptCommand.strip(_commandController.text);
    if (!WorkspacePromptCommand.isValid(command)) {
      setState(() {
        _commandError = true;
        _errorMessage = l10n.workspacePromptCommandInvalid;
      });
      return;
    }
    setState(() {
      _saving = true;
      _errorMessage = null;
      _commandError = false;
    });
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
      _dirty = false;
      _showSnack(l10n.workspacePromptDetailsSaved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt metadata update failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _commandError = _isCommandTaken(error);
        _errorMessage = _isCommandTaken(error)
            ? l10n.workspacePromptCommandTaken
            : l10n.workspacePromptSaveFailed;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
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
    setState(() => _saving = true);
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
        setState(() => _saving = false);
        _showSnack(l10n.workspacePromptSaveFailed, isError: true);
      }
    }
  }

  Future<void> _toggleActive() async {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    if (summary == null) return;
    setState(() => _saving = true);
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
      if (mounted) setState(() => _saving = false);
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
    setState(() => _saving = true);
    try {
      await ref.read(workspacePromptsProvider.notifier).delete(summary.id);
      if (!mounted) return;
      _dirty = false;
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
        setState(() => _saving = false);
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
      setState(() {
        _grants = grants;
        if (summary == null) _dirty = true;
      });
      return;
    }
    setState(() => _saving = true);
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
      if (mounted) setState(() => _saving = false);
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
      _dirty = true;
    });
    _showSnack(AppLocalizations.of(context)!.workspacePromptHistoryRestored);
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    // Watch so the overflow actions rebuild once capabilities resolve.
    final capabilities = ref
        .watch(workspaceCapabilitiesProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => WorkspaceCapabilities.none,
        );
    final title = _isCreate
        ? l10n.workspacePromptCreateTitle
        : (_nameController.text.trim().isEmpty
              ? l10n.workspacePrompts
              : _nameController.text.trim());

    return WorkspaceEditorScaffold(
      title: title,
      isDirty: _dirty && !_saving,
      readOnly: _fieldsReadOnly,
      isSaving: _saving,
      canSave: !_fieldsReadOnly,
      onSave: _fieldsReadOnly ? null : _save,
      errorMessage: _errorMessage,
      actions: _buildActions(l10n, capabilities),
      bodyPadding: EdgeInsets.zero,
      child: AbsorbPointer(
        absorbing: _saving,
        child: ListView(
          key: const Key('workspace-prompt-editor-body'),
          padding: const EdgeInsets.all(Spacing.md),
          children: [
            if (_isDetail && _writeAccess)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: ConduitButton(
                  key: const Key('workspace-prompt-edit'),
                  text: l10n.edit,
                  icon: Icons.edit_outlined,
                  onPressed: () => context.push(
                    WorkspaceSection.prompts.routes.editLocation(summary!.id),
                  ),
                ),
              ),
            _nameField(l10n),
            const SizedBox(height: Spacing.sm),
            _commandField(l10n),
            const SizedBox(height: Spacing.md),
            _tagsField(l10n),
            const SizedBox(height: Spacing.md),
            _contentEditor(l10n),
            if (!_fieldsReadOnly) ...[
              const SizedBox(height: Spacing.md),
              _versionSection(l10n),
            ],
            const SizedBox(height: Spacing.md),
            _accessTile(l10n),
            if (!_isCreate && summary != null) ...[
              const Divider(height: Spacing.xl),
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

  Widget _nameField(AppLocalizations l10n) {
    return ConduitInput(
      key: const Key('workspace-prompt-name'),
      controller: _nameController,
      label: l10n.workspacePromptName,
      enabled: !_fieldsReadOnly,
      onChanged: _onNameChanged,
      textInputAction: TextInputAction.next,
    );
  }

  Widget _commandField(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return WorkspaceLabeledField(
      helperText: l10n.workspacePromptCommandHint,
      child: ConduitInput(
        key: const Key('workspace-prompt-command'),
        controller: _commandController,
        label: l10n.workspacePromptCommand,
        enabled: !_fieldsReadOnly,
        onChanged: _onCommandChanged,
        errorText: _commandError ? l10n.workspacePromptCommandInvalid : null,
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: Spacing.md, right: Spacing.xs),
          child: Text(
            '/',
            style: AppTypography.standard.copyWith(color: theme.textSecondary),
          ),
        ),
      ),
    );
  }

  Widget _tagsField(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.workspacePromptTags, style: theme.label),
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: [
            for (final tag in _tags)
              InputChip(
                key: Key('workspace-prompt-tag-$tag'),
                label: Text(tag),
                onDeleted: _fieldsReadOnly
                    ? null
                    : () => setState(() {
                        _tags = [..._tags]..remove(tag);
                        _dirty = true;
                      }),
              ),
            if (!_fieldsReadOnly)
              ActionChip(
                key: const Key('workspace-prompt-tag-add'),
                avatar: const Icon(Icons.add, size: IconSize.small),
                label: Text(l10n.workspacePromptTagAdd),
                onPressed: () => _addTag(l10n),
              ),
          ],
        ),
      ],
    );
  }

  Widget _contentEditor(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(l10n.workspacePromptContent, style: theme.label)),
            // The adaptive segmented control renders a native platform view on
            // iOS 26; a non-flex child in a Row is measured with unbounded
            // width, which makes the native layer's frame infinite (NaN) and
            // crashes. Give it a definite width.
            SizedBox(
              width: 200,
              child: AdaptiveSegmentedControl(
                key: const Key('workspace-prompt-preview-toggle'),
                shrinkWrap: true,
                labels: [
                  l10n.workspacePromptWriteTab,
                  l10n.workspacePromptPreviewTab,
                ],
                selectedIndex: _previewMode ? 1 : 0,
                onValueChanged: (index) =>
                    setState(() => _previewMode = index == 1),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        if (_previewMode)
          _previewPane(l10n)
        else
          AdaptiveTextField(
            key: const Key('workspace-prompt-content'),
            controller: _contentController,
            enabled: !_fieldsReadOnly,
            minLines: 6,
            maxLines: 20,
            onChanged: (_) => _markDirty(),
            style: theme.code?.copyWith(color: theme.textPrimary),
            placeholder: l10n.workspacePromptContentHint,
          ),
      ],
    );
  }

  Widget _previewPane(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    final content = _contentController.text.trim();
    return Container(
      key: const Key('workspace-prompt-preview'),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 120),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.medium),
        border: Border.all(color: theme.dividerColor),
      ),
      child: content.isEmpty
          ? Text(
              l10n.workspacePromptPreviewEmpty,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            )
          : ConduitMarkdownWidget(data: content),
    );
  }

  Widget _versionSection(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.workspacePromptVersionSection, style: theme.label),
        const SizedBox(height: Spacing.xs),
        ConduitInput(
          key: const Key('workspace-prompt-commit-message'),
          controller: _commitController,
          label: l10n.workspacePromptCommitMessage,
          hint: l10n.workspacePromptCommitMessageHint,
          enabled: !_fieldsReadOnly,
          onChanged: (_) => _markDirty(),
        ),
        const SizedBox(height: Spacing.xs),
        AdaptiveListTile(
          key: const Key('workspace-prompt-production-toggle'),
          padding: EdgeInsets.zero,
          title: Text(l10n.workspacePromptSetProduction),
          subtitle: Text(l10n.workspacePromptSetProductionSubtitle),
          trailing: AdaptiveSwitch(
            value: _isProduction,
            onChanged: _fieldsReadOnly
                ? null
                : (value) => setState(() {
                    _isProduction = value;
                    _dirty = true;
                  }),
          ),
        ),
      ],
    );
  }

  Widget _accessTile(AppLocalizations l10n) {
    final principals = workspaceSharedPrincipals(_grants);
    final isPublic = workspaceGrantsArePublic(_grants);
    return AdaptiveListTile(
      key: const Key('workspace-prompt-access'),
      padding: EdgeInsets.zero,
      leading: Icon(isPublic ? Icons.public : Icons.lock_outline),
      title: Text(l10n.workspacePromptManageAccess),
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
        if (capabilities.prompts.importItems)
          WorkspaceEditorAction(
            label: l10n.workspacePromptImport,
            icon: Icons.upload_file_outlined,
            menuKey: const Key('workspace-prompt-action-import'),
            onSelected: _import,
          ),
        if (capabilities.prompts.exportItems)
          WorkspaceEditorAction(
            label: l10n.workspacePromptExport,
            icon: Icons.download_outlined,
            menuKey: const Key('workspace-prompt-action-export'),
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
          label: l10n.workspacePromptClone,
          icon: Icons.copy_outlined,
          menuKey: const Key('workspace-prompt-action-clone'),
          onSelected: _clone,
        ),
      if (canWrite && _isEdit)
        WorkspaceEditorAction(
          label: l10n.workspacePromptUpdateDetails,
          icon: Icons.drive_file_rename_outline,
          menuKey: const Key('workspace-prompt-action-update-details'),
          onSelected: _updateDetailsOnly,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: summary.isActive
              ? l10n.workspacePromptDeactivate
              : l10n.workspacePromptActivate,
          icon: summary.isActive
              ? Icons.toggle_on_outlined
              : Icons.toggle_off_outlined,
          menuKey: const Key('workspace-prompt-action-toggle'),
          onSelected: _toggleActive,
        ),
      WorkspaceEditorAction(
        label: l10n.workspacePromptManageAccess,
        icon: Icons.group_outlined,
        menuKey: const Key('workspace-prompt-action-access'),
        onSelected: _manageAccess,
      ),
      if (capabilities.prompts.exportItems)
        WorkspaceEditorAction(
          label: l10n.workspacePromptExport,
          icon: Icons.download_outlined,
          menuKey: const Key('workspace-prompt-action-export'),
          onSelected: _export,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspacePromptDelete,
          icon: Icons.delete_outline,
          isDestructive: true,
          menuKey: const Key('workspace-prompt-action-delete'),
          onSelected: _delete,
        ),
    ];
  }

  // --- Interactions ---------------------------------------------------------

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
    setState(() {
      _tags = [..._tags, tag];
      _dirty = true;
    });
  }

  void _showSnack(
    String message, {
    bool isError = false,
    BuildContext? overlayContext,
  }) {
    // Callers may pass a root overlay context so a snackbar can still be shown
    // after this form's own element has been disposed (e.g. a successful edit
    // that pops the editor).
    AdaptiveSnackBar.show(
      overlayContext ?? context,
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
