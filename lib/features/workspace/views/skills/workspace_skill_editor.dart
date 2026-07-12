import 'dart:convert';
import 'dart:io';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/models/workspace_skill_content.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
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
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';

/// Reads a user-picked Markdown file as text, or null if cancelled.
typedef WorkspaceMarkdownPicker = Future<String?> Function();

Future<String?> _defaultPickMarkdownFile() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const ['md', 'markdown', 'txt'],
  );
  if (file == null) return null;
  final bytes = file.path != null
      ? await File(file.path!).readAsBytes()
      : await file.readAsBytes();
  return utf8.decode(bytes);
}

/// Section-registry entry point for the Skills editor. Dispatches to the
/// create/detail/edit editor based on [WorkspaceEditorArgs.mode].
Widget buildWorkspaceSkillEditor(
  BuildContext context,
  WorkspaceEditorArgs args,
) {
  return WorkspaceSkillEditorView(
    key: ValueKey(
      'workspace-skill-editor-${args.mode.name}-${args.resourceId}',
    ),
    mode: args.mode,
    skillId: args.resourceId,
  );
}

class WorkspaceSkillEditorView extends ConsumerWidget {
  const WorkspaceSkillEditorView({
    super.key,
    required this.mode,
    this.skillId,
    this.markdownPicker,
  });

  final WorkspaceRouteMode mode;
  final String? skillId;

  /// Injectable Markdown file picker (tests supply a stub). Defaults to the
  /// platform file picker.
  final WorkspaceMarkdownPicker? markdownPicker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (mode == WorkspaceRouteMode.create) {
      return _WorkspaceSkillForm(
        mode: WorkspaceRouteMode.create,
        summary: null,
        markdownPicker: markdownPicker,
      );
    }

    final id = skillId;
    if (id == null || id.isEmpty) {
      return WorkspaceEditorScaffold(
        title: l10n.workspaceSkills,
        errorMessage: l10n.workspaceLoadFailed,
        child: const SizedBox.shrink(),
      );
    }

    final detail = ref.watch(workspaceSkillDetailProvider(id));
    return detail.when(
      loading: () => WorkspaceEditorScaffold(
        title: l10n.workspaceSkills,
        isLoading: true,
        child: const SizedBox.shrink(),
      ),
      error: (_, _) => WorkspaceEditorScaffold(
        title: l10n.workspaceSkills,
        errorMessage: l10n.workspaceLoadFailed,
        onRetry: () => ref.invalidate(workspaceSkillDetailProvider(id)),
        child: const SizedBox.shrink(),
      ),
      data: (value) {
        if (value == null) {
          return WorkspaceEditorScaffold(
            title: l10n.workspaceSkills,
            errorMessage: l10n.workspaceLoadFailed,
            onRetry: () => ref.invalidate(workspaceSkillDetailProvider(id)),
            child: const SizedBox.shrink(),
          );
        }
        return _WorkspaceSkillForm(
          key: ValueKey('workspace-skill-form-${value.id}-${mode.name}'),
          mode: mode,
          summary: value,
          markdownPicker: markdownPicker,
        );
      },
    );
  }
}

/// The create/detail/edit form for a single workspace skill.
class _WorkspaceSkillForm extends ConsumerStatefulWidget {
  const _WorkspaceSkillForm({
    super.key,
    required this.mode,
    this.summary,
    this.markdownPicker,
  });

  final WorkspaceRouteMode mode;
  final WorkspaceSkillSummary? summary;
  final WorkspaceMarkdownPicker? markdownPicker;

  @override
  ConsumerState<_WorkspaceSkillForm> createState() =>
      _WorkspaceSkillFormState();
}

class _WorkspaceSkillFormState extends ConsumerState<_WorkspaceSkillForm> {
  late final TextEditingController _nameController;
  late final TextEditingController _idController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _contentController;
  late List<WorkspaceAccessGrantInput> _grants;
  late Map<String, dynamic> _meta;

  bool _previewMode = false;
  bool _idManuallyEdited = false;
  bool _dirty = false;
  bool _saving = false;
  String? _errorMessage;
  // The specific inline id error to show under the field (null = no error), so
  // the message matches the reason (required / invalid characters / taken)
  // rather than always reading "invalid characters".
  String? _idErrorText;

  bool get _isCreate => widget.mode == WorkspaceRouteMode.create;
  bool get _isDetail => widget.mode == WorkspaceRouteMode.detail;

  bool get _writeAccess => _isCreate || (widget.summary?.writeAccess ?? false);

  /// Fields are editable only in create/edit modes with write access. Detail is
  /// a read-only view. The id is additionally immutable once a skill exists.
  bool get _fieldsReadOnly => !_writeAccess || _isDetail;
  bool get _idReadOnly => _fieldsReadOnly || !_isCreate;

  @override
  void initState() {
    super.initState();
    final summary = widget.summary;
    _nameController = TextEditingController(text: summary?.name ?? '');
    _idController = TextEditingController(text: summary?.id ?? '');
    _descriptionController = TextEditingController(
      text: summary?.description ?? '',
    );
    _contentController = TextEditingController(text: summary?.content ?? '');
    _grants = [
      for (final grant in summary?.accessGrants ?? const [])
        WorkspaceAccessGrantInput.fromGrant(grant),
    ];
    _meta = summary == null
        ? <String, dynamic>{'tags': <String>[]}
        : Map<String, dynamic>.from(summary.meta);
    // An existing skill already has an id, so treat it as user-set to keep the
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
      _idController.text = WorkspaceSkillContent.slugify(value);
    }
    _markDirty();
  }

  void _onIdChanged(String _) {
    _idManuallyEdited = true;
    if (_idErrorText != null) setState(() => _idErrorText = null);
    _markDirty();
  }

  void _onContentChanged(String value) {
    if (_isCreate) _applyFrontmatterPrefill(value);
    _markDirty();
  }

  /// Prefills name/id/description from Markdown front-matter, but only for empty
  /// fields so a manual edit is never overwritten. All fields stay editable.
  void _applyFrontmatterPrefill(String content) {
    final fm = WorkspaceSkillContent.parseFrontmatter(content);
    if (fm.isEmpty) return;
    final fmName = fm['name']?.trim() ?? '';
    final fmDescription = fm['description']?.trim() ?? '';
    final fmId = fm['id']?.trim() ?? '';
    var changed = false;

    if (fmName.isNotEmpty && _nameController.text.trim().isEmpty) {
      _nameController.text = WorkspaceSkillContent.formatSkillName(fmName);
      changed = true;
    }
    if (!_idManuallyEdited && _idController.text.trim().isEmpty) {
      final source = fmId.isNotEmpty ? fmId : fmName;
      if (source.isNotEmpty) {
        _idController.text = WorkspaceSkillContent.slugify(source);
        changed = true;
      }
    }
    if (fmDescription.isNotEmpty &&
        _descriptionController.text.trim().isEmpty) {
      _descriptionController.text = fmDescription;
      changed = true;
    }
    if (changed) setState(() {});
  }

  WorkspaceCapabilities get _capabilities => ref
      .read(workspaceCapabilitiesProvider)
      .maybeWhen(
        data: (value) => value,
        orElse: () => WorkspaceCapabilities.none,
      );

  // --- Save -----------------------------------------------------------------

  /// Validates the shared fields. Returns the trimmed id on success, or null
  /// after surfacing the appropriate inline error.
  String? _validateForm(AppLocalizations l10n) {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _errorMessage = l10n.workspaceSkillNameRequired);
      return null;
    }
    final id = _idController.text.trim();
    if (id.isEmpty) {
      setState(() {
        _idErrorText = l10n.workspaceSkillIdRequired;
        _errorMessage = l10n.workspaceSkillIdRequired;
      });
      return null;
    }
    if (!WorkspaceSkillContent.isValidId(id)) {
      setState(() {
        _idErrorText = l10n.workspaceSkillIdInvalid;
        _errorMessage = l10n.workspaceSkillIdInvalid;
      });
      return null;
    }
    if (_contentController.text.trim().isEmpty) {
      setState(() => _errorMessage = l10n.workspaceSkillContentRequired);
      return null;
    }
    return id;
  }

  WorkspaceSkillForm _buildForm({required String id}) {
    final description = _descriptionController.text.trim();
    return WorkspaceSkillForm(
      id: id,
      name: _nameController.text.trim(),
      description: description.isEmpty ? null : description,
      content: _contentController.text,
      meta: _meta,
      isActive: widget.summary?.isActive ?? true,
      accessGrants: _grants,
    );
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final id = _validateForm(l10n);
    if (id == null) return;
    setState(() {
      _saving = true;
      _errorMessage = null;
      _idErrorText = null;
    });
    final notifier = ref.read(workspaceSkillsProvider.notifier);
    // The update endpoint keys off the existing id; the id field is immutable
    // after create, so submit the summary's id when editing.
    final form = _buildForm(id: _isCreate ? id : widget.summary!.id);
    try {
      final WorkspaceSkillDetail result = _isCreate
          ? await notifier.create(form)
          : await notifier.updateItem(widget.summary!.id, form);
      if (!mounted) return;
      _dirty = false;
      DebugLogger.log(
        'skill saved',
        scope: 'workspace/skills',
        data: {'id': result.id, 'create': _isCreate},
      );
      _showSnack(l10n.workspaceSkillSaved);
      final router = GoRouter.of(context);
      if (_isCreate) {
        router.pushReplacement(
          WorkspaceSection.skills.routes.detailLocation(result.id),
        );
      } else if (router.canPop()) {
        router.pop();
      } else {
        // Edit saved but there is nothing to pop (e.g. deep-linked into /edit):
        // clear the saving lock so the form stays usable and reflects the
        // freshly invalidated detail.
        setState(() => _saving = false);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'skill save failed',
        scope: 'workspace/skills',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      final conflict = _isConflict(error);
      setState(() {
        _saving = false;
        _idErrorText = conflict ? l10n.workspaceSkillIdTaken : null;
        _errorMessage = conflict
            ? l10n.workspaceSkillIdTaken
            : l10n.workspaceSkillSaveFailed;
      });
    }
  }

  // --- Overflow actions -----------------------------------------------------

  Future<void> _clone() async {
    final l10n = AppLocalizations.of(context)!;
    final router = GoRouter.of(context);
    final baseId = _idController.text.trim();
    final cloneId = baseId.isEmpty ? 'skill_clone' : '${baseId}_clone';
    setState(() => _saving = true);
    // Clones never inherit the source skill's sharing grants.
    final form = WorkspaceSkillForm(
      id: cloneId,
      name: '${_nameController.text.trim()} ${l10n.workspaceSkillCloneSuffix}',
      description: _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim(),
      content: _contentController.text,
      meta: _meta,
    );
    try {
      final created = await ref
          .read(workspaceSkillsProvider.notifier)
          .create(form);
      if (!mounted) return;
      _showSnack(l10n.workspaceSkillSaved);
      router.pushReplacement(
        WorkspaceSection.skills.routes.editLocation(created.id),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'skill clone failed',
        scope: 'workspace/skills',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _saving = false);
        _showSnack(l10n.workspaceSkillSaveFailed, isError: true);
      }
    }
  }

  Future<void> _toggleActive() async {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summary;
    if (summary == null) return;
    setState(() => _saving = true);
    try {
      await ref.read(workspaceSkillsProvider.notifier).toggle(summary.id);
      if (!mounted) return;
      _showSnack(l10n.workspaceSkillSaved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'skill toggle failed',
        scope: 'workspace/skills',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceSkillSaveFailed, isError: true);
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
      title: l10n.workspaceSkillDeleteConfirmTitle,
      message: l10n.workspaceSkillDeleteConfirmMessage(
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
      await ref.read(workspaceSkillsProvider.notifier).delete(summary.id);
      if (!mounted) return;
      _dirty = false;
      _showSnack(l10n.workspaceSkillDeleted);
      if (router.canPop()) {
        router.pop();
      } else {
        router.go(WorkspaceSection.skills.routes.collectionPath);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'skill delete failed',
        scope: 'workspace/skills',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _saving = false);
        _showSnack(l10n.workspaceSkillSaveFailed, isError: true);
      }
    }
  }

  Future<void> _manageAccess() async {
    final l10n = AppLocalizations.of(context)!;
    final capabilities = _capabilities;
    final grants = await WorkspaceAccessGrantSheet.show(
      context,
      initialGrants: _grants,
      capabilities: capabilities.skills,
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
          .read(workspaceSkillsProvider.notifier)
          .updateAccess(summary.id, grants);
      if (!mounted) return;
      setState(() => _grants = grants);
      _showSnack(l10n.workspaceSkillSaved);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'skill access update failed',
        scope: 'workspace/skills',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceSkillSaveFailed, isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Markdown import: reads a `.md` file, parses front-matter, and prefills the
  /// current (unsaved) create form. The user reviews and explicitly saves.
  Future<void> _importMarkdown() async {
    final l10n = AppLocalizations.of(context)!;
    final picker = widget.markdownPicker ?? _defaultPickMarkdownFile;
    String? content;
    try {
      content = await picker();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'skill markdown import read failed',
        scope: 'workspace/skills',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _showSnack(l10n.workspaceSkillImportMarkdownFailed, isError: true);
      }
      return;
    }
    if (content == null || !mounted) return;
    final fm = WorkspaceSkillContent.parseFrontmatter(content);
    setState(() {
      _contentController.text = content!;
      final fmName = fm['name']?.trim() ?? '';
      final fmId = fm['id']?.trim() ?? '';
      if (fmName.isNotEmpty) {
        _nameController.text = WorkspaceSkillContent.formatSkillName(fmName);
      }
      // Honor a front-matter `id` even without a `name`, preferring the explicit
      // id and otherwise deriving it from the name, so a valid id isn't dropped.
      final idSource = fmId.isNotEmpty ? fmId : fmName;
      if (idSource.isNotEmpty) {
        _idController.text = WorkspaceSkillContent.slugify(idSource);
        _idManuallyEdited = false;
      }
      final fmDescription = fm['description']?.trim() ?? '';
      if (fmDescription.isNotEmpty) _descriptionController.text = fmDescription;
      _previewMode = false;
      _dirty = true;
      _errorMessage = null;
      _idErrorText = null;
    });
    _showSnack(l10n.workspaceSkillImportMarkdownLoaded);
  }

  /// JSON import: creates one or many skills, reporting per-item success/failure
  /// without aborting the batch on the first error.
  Future<void> _importJson() async {
    final l10n = AppLocalizations.of(context)!;
    final report = await WorkspaceImportSheet.show(
      context,
      title: l10n.workspaceSkillImport,
      importer: (items) => runWorkspaceImport(
        items,
        importItem: (item) => ref
            .read(workspaceSkillsProvider.notifier)
            .importSkill(_formFromImport(item)),
        labelOf: (item) =>
            item['name']?.toString() ?? item['id']?.toString() ?? '',
      ),
    );
    if (report != null && mounted) {
      // Refresh once so model skill selectors/runtime metadata reconcile.
      await ref.read(workspaceSkillsProvider.notifier).refresh();
    }
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final skills = await ref
          .read(workspaceSkillsProvider.notifier)
          .exportAll();
      if (!mounted) return;
      final payload = [for (final item in skills) _exportMap(item)];
      await WorkspaceExportController().shareJson(
        filename: 'skills',
        data: payload,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'skill export failed',
        scope: 'workspace/skills',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspaceSkillExportFailed, isError: true);
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
        ? l10n.workspaceSkillCreateTitle
        : (_nameController.text.trim().isEmpty
              ? l10n.workspaceSkills
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
          key: const Key('workspace-skill-editor-body'),
          padding: EdgeInsets.fromLTRB(
            Spacing.pagePadding,
            Spacing.md,
            Spacing.pagePadding,
            Spacing.pagePadding + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            if (_isDetail && _writeAccess)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: ConduitButton(
                  key: const Key('workspace-skill-edit'),
                  text: l10n.edit,
                  icon: Icons.edit_outlined,
                  onPressed: () => context.push(
                    WorkspaceSection.skills.routes.editLocation(summary!.id),
                  ),
                ),
              ),
            _nameField(l10n),
            const SizedBox(height: Spacing.md),
            _idField(l10n),
            const SizedBox(height: Spacing.md),
            _descriptionField(l10n),
            const SizedBox(height: Spacing.xl),
            _contentEditor(l10n),
            const SizedBox(height: Spacing.xl),
            _accessTile(l10n),
            const SizedBox(height: Spacing.xl),
          ],
        ),
      ),
    );
  }

  Widget _nameField(AppLocalizations l10n) {
    return ConduitInput(
      key: const Key('workspace-skill-name'),
      controller: _nameController,
      label: l10n.workspaceSkillName,
      hint: l10n.workspaceSkillNameHint,
      enabled: !_fieldsReadOnly,
      onChanged: _onNameChanged,
      textInputAction: TextInputAction.next,
    );
  }

  Widget _idField(AppLocalizations l10n) {
    return WorkspaceLabeledField(
      helperText: l10n.workspaceSkillIdHint,
      child: ConduitInput(
        key: const Key('workspace-skill-id'),
        controller: _idController,
        label: l10n.workspaceSkillId,
        enabled: !_idReadOnly,
        onChanged: _onIdChanged,
        errorText: _idErrorText,
      ),
    );
  }

  Widget _descriptionField(AppLocalizations l10n) {
    return ConduitInput(
      key: const Key('workspace-skill-description'),
      controller: _descriptionController,
      label: l10n.workspaceSkillDescription,
      hint: l10n.workspaceSkillDescriptionHint,
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
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.workspaceSkillContent,
                style: theme.headingSmall,
              ),
            ),
            // Bound the width: on iOS 26 this is a native platform view and an
            // unbounded Row constraint makes its layer frame infinite (NaN),
            // which crashes the app.
            SizedBox(
              width: 200,
              child: AdaptiveSegmentedControl(
                key: const Key('workspace-skill-preview-toggle'),
                shrinkWrap: true,
                labels: [
                  l10n.workspaceSkillWriteTab,
                  l10n.workspaceSkillPreviewTab,
                ],
                selectedIndex: _previewMode ? 1 : 0,
                onValueChanged: (index) =>
                    setState(() => _previewMode = index == 1),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        if (_previewMode)
          _previewPane(l10n)
        else
          AdaptiveTextField(
            key: const Key('workspace-skill-content'),
            controller: _contentController,
            enabled: !_fieldsReadOnly,
            minLines: 10,
            maxLines: 28,
            onChanged: _onContentChanged,
            style: theme.code?.copyWith(color: theme.textPrimary),
            placeholder: l10n.workspaceSkillContentHint,
          ),
      ],
    );
  }

  Widget _previewPane(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    final content = _contentController.text.trim();
    return Container(
      key: const Key('workspace-skill-preview'),
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
              l10n.workspaceSkillPreviewEmpty,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            )
          : ConduitMarkdownWidget(data: content),
    );
  }

  Widget _accessTile(AppLocalizations l10n) {
    final principals = workspaceSharedPrincipals(_grants);
    final isPublic = workspaceGrantsArePublic(_grants);
    return WorkspaceResourceTile(
      key: const Key('workspace-skill-access'),
      icon: isPublic ? Icons.public : Icons.lock_outline,
      title: l10n.workspaceSkillManageAccess,
      subtitle: isPublic
          ? l10n.workspaceAccessVisibilityLabel
          : l10n.workspaceModelSelectCount(principals.length),
      onTap: _manageAccess,
    );
  }

  List<WorkspaceEditorAction> _buildActions(
    AppLocalizations l10n,
    WorkspaceCapabilities capabilities,
  ) {
    if (_isCreate) {
      return [
        if (capabilities.skills.importItems) ...[
          WorkspaceEditorAction(
            label: l10n.workspaceSkillImportMarkdown,
            icon: Icons.description_outlined,
            menuKey: const Key('workspace-skill-action-import-markdown'),
            onSelected: _importMarkdown,
          ),
          WorkspaceEditorAction(
            label: l10n.workspaceSkillImportJson,
            icon: Icons.data_object_outlined,
            menuKey: const Key('workspace-skill-action-import-json'),
            onSelected: _importJson,
          ),
        ],
        if (capabilities.skills.exportItems)
          WorkspaceEditorAction(
            label: l10n.workspaceSkillExport,
            icon: Icons.download_outlined,
            menuKey: const Key('workspace-skill-action-export'),
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
          label: l10n.workspaceSkillClone,
          icon: Icons.copy_outlined,
          menuKey: const Key('workspace-skill-action-clone'),
          onSelected: _clone,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: summary.isActive
              ? l10n.workspaceSkillDeactivate
              : l10n.workspaceSkillActivate,
          icon: summary.isActive
              ? Icons.toggle_on_outlined
              : Icons.toggle_off_outlined,
          menuKey: const Key('workspace-skill-action-toggle'),
          onSelected: _toggleActive,
        ),
      WorkspaceEditorAction(
        label: l10n.workspaceSkillManageAccess,
        icon: Icons.group_outlined,
        menuKey: const Key('workspace-skill-action-access'),
        onSelected: _manageAccess,
      ),
      if (capabilities.skills.exportItems)
        WorkspaceEditorAction(
          label: l10n.workspaceSkillExport,
          icon: Icons.download_outlined,
          menuKey: const Key('workspace-skill-action-export'),
          onSelected: _export,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspaceSkillDelete,
          icon: Icons.delete_outline,
          isDestructive: true,
          menuKey: const Key('workspace-skill-action-delete'),
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

  Map<String, dynamic> _exportMap(WorkspaceSkillSummary item) => {
    'id': item.id,
    'name': item.name,
    if (item.description != null) 'description': item.description,
    'content': item.content ?? '',
    'meta': item.meta,
    'is_active': item.isActive,
  };

  WorkspaceSkillForm _formFromImport(Map<String, dynamic> json) {
    final rawId = json['id']?.toString().trim() ?? '';
    final name = json['name']?.toString() ?? json['title']?.toString() ?? '';
    final id = rawId.isEmpty ? WorkspaceSkillContent.slugify(name) : rawId;
    return WorkspaceSkillForm(
      id: id,
      name: name,
      description: json['description']?.toString(),
      content: json['content']?.toString() ?? '',
      meta: json['meta'] is Map ? workspaceJsonMap(json['meta']) : const {},
      isActive: workspaceBool(json['is_active'], true),
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
