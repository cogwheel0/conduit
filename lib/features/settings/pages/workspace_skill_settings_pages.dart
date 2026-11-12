import 'dart:convert';
import 'dart:io';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/models/workspace_skill_content.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart';
import 'package:conduit_core/navigation/routes.dart' show WorkspaceSection;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../workspace/widgets/workspace_access_grants.dart'
    show workspaceAccessSummary;
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'workspace_access_settings_pages.dart';
import 'workspace_page_ids.dart';
import 'workspace_settings_pages.dart' show workspaceSectionCapabilities;

/// One skill's editor while its page is open.
final class WorkspaceSkillEditor {
  WorkspaceSkillEditor(this.key, this.session);

  final String key;
  final WorkspaceSessionIdentity? session;

  WorkspaceSkillSummary? summary;
  bool loaded = false;
  bool loadFailed = false;

  String name = '';
  String id = '';
  String description = '';
  String content = '';
  Map<String, dynamic> meta = {};
  List<WorkspaceAccessGrantInput> grants = [];

  /// The id was typed, so the name no longer writes it.
  bool idTyped = false;
  bool idError = false;

  bool dirty = false;
  bool busy = false;
  String? notice;
  bool noticeIsError = true;
  bool shownEdited = false;

  bool get isCreate => key == workspaceNewKey;
  bool get writeAccess => isCreate || (summary?.writeAccess ?? false);
  bool get readOnly => !writeAccess;
  bool get ready => isCreate || loaded;

  void adopt(WorkspaceSkillSummary next) {
    summary = next;
    loaded = true;
    loadFailed = false;
    name = next.name;
    id = next.id;
    description = next.description ?? '';
    content = next.content ?? '';
    meta = Map<String, dynamic>.from(next.meta);
    grants = [
      for (final grant in next.accessGrants)
        WorkspaceAccessGrantInput.fromGrant(grant),
    ];
    idTyped = true;
    idError = false;
    dirty = false;
  }

  /// Fills empty fields from the Markdown's front matter, so a skill's
  /// instructions can say what it is.
  void prefillFrom(String source) {
    final front = WorkspaceSkillContent.parseFrontmatter(source);
    final frontName = front['name']?.trim() ?? '';
    final frontId = front['id']?.trim() ?? '';
    final about = front['description']?.trim() ?? '';
    if (frontName.isNotEmpty && name.trim().isEmpty) {
      name = WorkspaceSkillContent.formatSkillName(frontName);
    }
    if (!idTyped && id.trim().isEmpty) {
      final source = frontId.isNotEmpty ? frontId : frontName;
      if (source.isNotEmpty) id = WorkspaceSkillContent.slugify(source);
    }
    if (about.isNotEmpty && description.trim().isEmpty) description = about;
  }
}

String _skillRow(String field, String key, [String? extra]) =>
    workspaceRowId('skill-$field', key, extra);

/// A skill's editor page: its name, id and description, its instructions
/// (a page of their own), who may use it, and the actions on it. A skill
/// the account may only view reads without fields.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceSkillPage(
  AppLocalizations l10n, {
  required WorkspaceSkillEditor editor,
}) {
  final key = editor.key;
  final pageId = '$workspaceSkillPagePrefix$key';
  final title = editor.isCreate
      ? l10n.workspaceSkillCreateTitle
      : (editor.name.trim().isEmpty
            ? l10n.workspaceSkills
            : editor.name.trim());
  if (!editor.ready) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: title,
      items: [
        if (editor.loadFailed)
          NativeSheetItemConfig(
            id: _skillRow('retry', key),
            title: l10n.workspaceLoadFailed,
            subtitle: l10n.workspaceRetry,
            sfSymbol: 'exclamationmark.triangle',
            showsDisclosure: false,
          )
        else
          buildNativeLoadingItem(l10n, id: '$pageId-loading'),
      ],
    );
  }
  final readOnly = editor.readOnly;
  final summary = editor.summary;
  final canWrite = !readOnly && summary != null;
  NativeSheetItemConfig field(
    String field,
    String title,
    String value, {
    required String symbol,
    String? placeholder,
    bool locked = false,
  }) => NativeSheetItemConfig(
    id: _skillRow(field, key),
    title: title,
    sfSymbol: symbol,
    kind: readOnly || locked
        ? NativeSheetItemKind.readOnlyText
        : NativeSheetItemKind.textField,
    value: value,
    placeholder: placeholder ?? title,
    disabled: editor.busy,
  );
  return NativeSheetDetailConfig(
    id: pageId,
    title: title,
    confirmActionId: readOnly ? null : _skillRow('save', key),
    confirmActionLabel: editor.isCreate ? l10n.workspaceCreate : l10n.save,
    discardPrompt: readOnly ? null : nativeDiscardPrompt(l10n),
    edited: editor.dirty,
    busy: editor.busy,
    announcement: editor.notice,
    sections: [
      if (editor.notice != null)
        NativeSheetSectionConfig(
          items: [
            editor.noticeIsError
                ? workspaceWarning('$pageId-notice', editor.notice!)
                : workspaceNote(
                    '$pageId-notice',
                    editor.notice!,
                    'checkmark.circle',
                  ),
          ],
        ),
      if (readOnly)
        NativeSheetSectionConfig(
          items: [
            workspaceNote(
              '$pageId-read-only',
              l10n.workspaceReadOnlyExplanation,
              'lock',
            ),
          ],
        ),
      NativeSheetSectionConfig(
        footer: editor.isCreate && !readOnly ? l10n.workspaceSkillIdHint : null,
        items: [
          field(
            'name',
            l10n.workspaceSkillName,
            editor.name,
            symbol: 'graduationcap',
            placeholder: l10n.workspaceSkillNameHint,
          ),
          field(
            'id',
            l10n.workspaceSkillId,
            editor.id,
            symbol: editor.idError ? 'exclamationmark.triangle' : 'number',
            locked: !editor.isCreate,
          ),
          field(
            'description',
            l10n.workspaceSkillDescription,
            editor.description,
            symbol: 'text.alignleft',
            placeholder: l10n.workspaceSkillDescriptionHint,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: '$workspaceSkillContentPagePrefix$key',
            title: l10n.workspaceSkillContent,
            sfSymbol: 'doc.text',
          ),
          if (editor.isCreate)
            NativeSheetItemConfig(
              id: _skillRow('import-markdown', key),
              title: l10n.workspaceSkillImportMarkdown,
              sfSymbol: 'square.and.arrow.down',
              showsDisclosure: false,
              disabled: editor.busy,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: workspaceAccessPageId(WorkspaceSection.skills, key),
            title: l10n.workspaceSkillManageAccess,
            subtitle: workspaceAccessSummary(l10n, editor.grants),
            sfSymbol: 'person.2',
          ),
        ],
      ),
      if (canWrite)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: _skillRow('clone', key),
              title: l10n.workspaceSkillClone,
              sfSymbol: 'plus.square.on.square',
              showsDisclosure: false,
              disabled: editor.busy,
            ),
            NativeSheetItemConfig(
              id: _skillRow('active', key),
              title: summary.isActive
                  ? l10n.workspaceSkillDeactivate
                  : l10n.workspaceSkillActivate,
              sfSymbol: summary.isActive ? 'pause.circle' : 'play.circle',
              showsDisclosure: false,
              disabled: editor.busy,
            ),
            NativeSheetItemConfig(
              id: _skillRow('delete', key),
              title: l10n.workspaceSkillDelete,
              sfSymbol: 'trash',
              destructive: true,
              showsDisclosure: false,
              disabled: editor.busy,
              confirmMessage: l10n.workspaceSkillDeleteConfirmMessage(
                summary.name.isEmpty ? summary.id : summary.name,
              ),
            ),
          ],
        ),
    ],
  );
}

/// A skill's instructions, Markdown edited as is on a page of its own.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceSkillContentPage(
  AppLocalizations l10n, {
  required WorkspaceSkillEditor editor,
}) => NativeSheetDetailConfig(
  id: '$workspaceSkillContentPagePrefix${editor.key}',
  title: l10n.workspaceSkillContent,
  items: [
    NativeSheetItemConfig(
      id: _skillRow('content', editor.key),
      title: l10n.workspaceSkillContent,
      kind: NativeSheetItemKind.code,
      value: editor.content,
      placeholder: l10n.workspaceSkillContentHint,
      disabled: editor.readOnly || editor.busy,
    ),
  ],
);

/// A skill's pages in Settings: its editor, its instructions, and who may
/// use it.
class WorkspaceSkillSettingsPages extends SettingsPageModule {
  WorkspaceSkillSettingsPages(this._ref) {
    _access = WorkspaceAccessPages(
      _ref,
      section: WorkspaceSection.skills,
      onSave: _saveAccess,
      onDone: _accessDone,
    );
  }

  final Ref _ref;
  late final WorkspaceAccessPages _access;
  AppLocalizations? _l10n;
  final Map<String, WorkspaceSkillEditor> _editors = {};

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);
  WorkspaceSkills get _notifier => _ref.read(workspaceSkillsProvider.notifier);

  WorkspaceSectionCapabilities get _capabilities =>
      workspaceSectionCapabilities(
        _ref.read(workspaceCapabilitiesProvider).value,
        WorkspaceSection.skills,
      );

  @override
  bool ownsPage(String detailId) =>
      detailId.startsWith(workspaceSkillPagePrefix) ||
      detailId.startsWith(workspaceSkillContentPagePrefix) ||
      _access.ownsPage(detailId);

  WorkspaceSessionIdentity? _session() {
    try {
      return WorkspaceSessionIdentity.read(_ref);
    } on StateError {
      return null;
    }
  }

  bool _current(WorkspaceSkillEditor editor) =>
      identical(_editors[editor.key], editor) &&
      (editor.session?.isCurrent(_ref) ?? false);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    if (_access.ownsPage(detailId)) {
      final key = _access.editorKeyOf(detailId);
      final editor = key == null ? null : _editors[key];
      if (editor != null && editor.ready) {
        _access.open(
          editorKey: editor.key,
          grants: editor.grants,
          readOnly: editor.readOnly,
          saveOnDone: !editor.isCreate,
          resourceName: editor.name.trim().isEmpty ? null : editor.name.trim(),
        );
      }
      await _access.hydrate(detailId, l10n);
      return;
    }
    if (detailId.startsWith(workspaceSkillContentPagePrefix)) {
      final editor =
          _editors[detailId.substring(workspaceSkillContentPagePrefix.length)];
      if (editor != null) {
        await _surface.applyDetail(
          buildWorkspaceSkillContentPage(l10n, editor: editor),
        );
      }
      return;
    }
    final key = detailId.substring(workspaceSkillPagePrefix.length);
    final open = _editors[key];
    if (open != null) {
      await _applyEditor(l10n, open);
      return;
    }
    final editor = _editors[key] = WorkspaceSkillEditor(key, _session());
    await _applyEditor(l10n, editor);
    if (!editor.isCreate) await _load(editor);
  }

  @override
  void pageLeft(String detailId) {
    if (_access.ownsPage(detailId)) {
      _access.pageLeft(detailId);
      return;
    }
    if (detailId.startsWith(workspaceSkillPagePrefix)) {
      final key = detailId.substring(workspaceSkillPagePrefix.length);
      _editors.remove(key);
      _access.forget(key);
    }
  }

  @override
  void settingsClosed() {
    _editors.clear();
    _access.clear();
  }

  Future<void> _load(WorkspaceSkillEditor editor) async {
    final l10n = _l10n;
    final id = workspaceIdOfKey(editor.key);
    if (l10n == null || id == null) return;
    editor.loadFailed = false;
    WorkspaceSkillSummary? summary;
    try {
      final provider = workspaceSkillDetailProvider(id);
      final listening = _ref.listen(provider, (_, _) {});
      try {
        summary = await _ref.read(provider.future);
      } finally {
        listening.close();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-skill-load-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return;
    if (summary == null) {
      editor.loadFailed = true;
    } else {
      editor.adopt(summary);
    }
    await _applyEditor(l10n, editor);
  }

  Future<void> _applyEditor(
    AppLocalizations l10n,
    WorkspaceSkillEditor editor, {
    bool withPages = true,
  }) {
    final key = editor.key;
    editor.shownEdited = editor.dirty;
    return _surface.applyDetail(
      buildWorkspaceSkillPage(l10n, editor: editor),
      detailSheets: [
        if (withPages && editor.ready) ...[
          buildWorkspaceSkillContentPage(l10n, editor: editor),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: workspaceAccessPageId(WorkspaceSection.skills, key),
            title: l10n.workspaceSkillManageAccess,
          ),
        ],
      ],
    );
  }

  Future<void> _showEdited(AppLocalizations l10n, WorkspaceSkillEditor editor) {
    if (editor.dirty == editor.shownEdited) return Future.value();
    return _applyEditor(l10n, editor, withPages: false);
  }

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    _l10n = l10n;
    if (await _access.handleChange(id, value, l10n)) return true;
    final row = parseWorkspaceRowId(id);
    if (row == null || !row.field.startsWith('skill-')) return false;
    final editor = _editors[row.key];
    if (editor == null) return true;
    final field = row.field.substring('skill-'.length);
    if (field == 'retry') {
      await _load(editor);
      return true;
    }
    if (!editor.ready) return true;
    switch (field) {
      case 'name' when value is String && !editor.readOnly && !editor.busy:
        final wasDirty = editor.dirty;
        editor
          ..name = value
          ..dirty = true;
        // A new skill's id follows its name until it is typed.
        if (editor.isCreate && !editor.idTyped) {
          editor.id = WorkspaceSkillContent.slugify(value);
          await _applyEditor(l10n, editor, withPages: false);
        } else if (!wasDirty) {
          await _applyEditor(l10n, editor, withPages: false);
        }
      case 'id' when value is String && editor.isCreate && !editor.busy:
        final wasError = editor.idError;
        final wasDirty = editor.dirty;
        editor
          ..id = value
          ..idTyped = true
          ..idError = false
          ..dirty = true;
        if (wasError || !wasDirty) {
          await _applyEditor(l10n, editor, withPages: false);
        }
      case 'description'
          when value is String && !editor.readOnly && !editor.busy:
        final wasDirty = editor.dirty;
        editor
          ..description = value
          ..dirty = true;
        if (!wasDirty) await _applyEditor(l10n, editor, withPages: false);
      case 'content' when value is String && !editor.readOnly && !editor.busy:
        if (value == editor.content) return true;
        editor
          ..content = value
          ..dirty = true;
        if (editor.isCreate) editor.prefillFrom(value);
        await _applyEditor(l10n, editor, withPages: false);
      case 'import-markdown':
        await _importMarkdown(l10n, editor);
      case 'save':
        await _save(l10n, editor);
      case 'clone':
        await _clone(l10n, editor);
      case 'active':
        await _toggleActive(l10n, editor);
      case 'delete':
        await _delete(l10n, editor);
    }
    return true;
  }

  void _say(WorkspaceSkillEditor editor, String message, {bool error = true}) {
    editor
      ..notice = message
      ..noticeIsError = error;
  }

  /// Whether the server refused the id as taken. Open WebUI answers 400
  /// for other refusals too (source that does not load, a name in use), so
  /// a 400 counts only when it says the id is the problem.
  static bool _isConflict(Object error) {
    if (error is! DioException) return false;
    final status = error.response?.statusCode;
    if (status == 409) return true;
    if (status != 400) return false;
    final data = error.response?.data;
    final detail = (data is Map ? data['detail'] : data)
        ?.toString()
        .toLowerCase();
    return detail != null &&
        detail.contains('id') &&
        (detail.contains('taken') || detail.contains('already'));
  }

  String? _checked(AppLocalizations l10n, WorkspaceSkillEditor editor) {
    if (editor.name.trim().isEmpty) {
      _say(editor, l10n.workspaceSkillNameRequired);
      return null;
    }
    final id = editor.isCreate ? editor.id.trim() : editor.summary!.id;
    if (editor.isCreate) {
      if (id.isEmpty || !WorkspaceSkillContent.isValidId(id)) {
        editor.idError = true;
        _say(
          editor,
          id.isEmpty
              ? l10n.workspaceSkillIdRequired
              : l10n.workspaceSkillIdInvalid,
        );
        return null;
      }
    }
    if (editor.content.trim().isEmpty) {
      _say(editor, l10n.workspaceSkillContentRequired);
      return null;
    }
    return id;
  }

  Future<void> _save(AppLocalizations l10n, WorkspaceSkillEditor editor) async {
    if (editor.readOnly || editor.busy) return;
    final id = _checked(l10n, editor);
    if (id == null) {
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    final description = editor.description.trim();
    final form = WorkspaceSkillForm(
      id: id,
      name: editor.name.trim(),
      description: description.isEmpty ? null : description,
      content: editor.content,
      meta: editor.meta,
      isActive: editor.summary?.isActive ?? true,
      // Who may open it is saved on its Access page; an update leaves it
      // as it is, rather than putting back what was read on opening.
      accessGrants: editor.isCreate ? editor.grants : null,
    );
    editor
      ..busy = true
      ..idError = false
      ..notice = null;
    await _applyEditor(l10n, editor, withPages: false);
    String? problem;
    try {
      if (editor.isCreate) {
        await _notifier.create(form);
      } else {
        await _notifier.updateItem(editor.summary!.id, form);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-skill-save-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      editor.idError = editor.isCreate && _isConflict(error);
      problem = editor.idError
          ? l10n.workspaceSkillIdTaken
          : l10n.workspaceSkillSaveFailed;
    }
    if (!_current(editor)) return;
    editor.busy = false;
    if (problem != null) {
      _say(editor, problem);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    editor.dirty = false;
    // Saved, the editor goes back to the list, which shows the skill.
    _editors.remove(editor.key);
    _access.forget(editor.key);
    await _surface.closeDetail('$workspaceSkillPagePrefix${editor.key}');
  }

  Future<bool> _operate(
    AppLocalizations l10n,
    WorkspaceSkillEditor editor,
    Future<void> Function() operation,
  ) async {
    if (editor.busy) return false;
    editor
      ..busy = true
      ..notice = null;
    await _applyEditor(l10n, editor, withPages: false);
    Object? failed;
    try {
      await operation();
    } catch (error, stackTrace) {
      failed = error;
      DebugLogger.error(
        'workspace-skill-operation-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return false;
    editor.busy = false;
    if (failed != null) {
      _say(editor, l10n.workspaceSkillSaveFailed);
      await _applyEditor(l10n, editor, withPages: false);
      return false;
    }
    return true;
  }

  Future<void> _clone(
    AppLocalizations l10n,
    WorkspaceSkillEditor editor,
  ) async {
    if (editor.summary == null || editor.readOnly) return;
    final base = editor.id.trim();
    final description = editor.description.trim();
    // Clones never take the source skill's sharing grants.
    final form = WorkspaceSkillForm(
      id: base.isEmpty ? 'skill_clone' : '${base}_clone',
      name: '${editor.name.trim()} ${l10n.workspaceSkillCloneSuffix}',
      description: description.isEmpty ? null : description,
      content: editor.content,
      // Its supporting files go with it (SKILL.md is the content above),
      // and it is on or off as the skill is.
      files: [
        for (final file in editor.summary?.files ?? const [])
          if (file['path'] != 'SKILL.md') file,
      ],
      meta: editor.meta,
      isActive: editor.summary?.isActive ?? true,
    );
    final ok = await _operate(l10n, editor, () => _notifier.create(form));
    if (!ok) return;
    _say(editor, l10n.workspaceSkillSaved, error: false);
    await _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _toggleActive(
    AppLocalizations l10n,
    WorkspaceSkillEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || editor.readOnly) return;
    WorkspaceSkillSummary? toggled;
    final ok = await _operate(
      l10n,
      editor,
      () async => toggled = await _notifier.toggle(summary.id),
    );
    if (!ok) return;
    final next = toggled;
    if (next != null) {
      // The toggle answers less than the whole skill (no write access):
      // only whether it is on is taken from it, and what was typed stays.
      editor.summary = WorkspaceSkillSummary(
        id: summary.id,
        name: summary.name,
        userId: summary.userId,
        description: summary.description,
        content: summary.content,
        files: summary.files,
        meta: summary.meta,
        isActive: next.isActive,
        accessGrants: summary.accessGrants,
        writeAccess: summary.writeAccess,
        owner: summary.owner,
        createdAt: summary.createdAt,
        updatedAt: summary.updatedAt,
      );
    }
    _say(editor, l10n.workspaceSkillSaved, error: false);
    await _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _delete(
    AppLocalizations l10n,
    WorkspaceSkillEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || editor.readOnly) return;
    final ok = await _operate(l10n, editor, () => _notifier.delete(summary.id));
    if (!ok) return;
    _editors.remove(editor.key);
    _access.forget(editor.key);
    await _surface.closeDetail('$workspaceSkillPagePrefix${editor.key}');
  }

  /// Fills a new skill from a Markdown file picked over Settings.
  Future<void> _importMarkdown(
    AppLocalizations l10n,
    WorkspaceSkillEditor editor,
  ) async {
    if (!editor.isCreate || editor.busy) return;
    String? text;
    try {
      text = await _ref.read(workspaceSkillMarkdownPickerProvider)();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-skill-markdown-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_current(editor)) return;
      _say(editor, l10n.workspaceSkillImportMarkdownFailed);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    // Cancelled, or the editor was left while the picker was open.
    if (text == null || !_current(editor)) return;
    final front = WorkspaceSkillContent.parseFrontmatter(text);
    final frontName = front['name']?.trim() ?? '';
    final frontId = front['id']?.trim() ?? '';
    final about = front['description']?.trim() ?? '';
    editor.content = text;
    if (frontName.isNotEmpty) {
      editor.name = WorkspaceSkillContent.formatSkillName(frontName);
    }
    final idSource = frontId.isNotEmpty ? frontId : frontName;
    if (idSource.isNotEmpty) {
      editor
        ..id = WorkspaceSkillContent.slugify(idSource)
        ..idTyped = false;
    }
    if (about.isNotEmpty) editor.description = about;
    editor
      ..idError = false
      ..dirty = true;
    _say(editor, l10n.workspaceSkillImportMarkdownLoaded, error: false);
    await _applyEditor(l10n, editor);
  }

  Future<String?> _saveAccess(
    WorkspaceAccessDraft draft,
    List<WorkspaceAccessGrantInput> grants,
  ) async {
    final l10n = _l10n;
    final editor = _editors[draft.editorKey];
    final summary = editor?.summary;
    if (l10n == null || editor == null || summary == null) return null;
    try {
      await _notifier.updateAccess(summary.id, grants);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-skill-access-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      return l10n.workspaceSkillSaveFailed;
    }
    return null;
  }

  Future<void> _accessDone(
    WorkspaceAccessDraft draft,
    List<WorkspaceAccessGrantInput> grants, {
    required bool saved,
  }) async {
    final l10n = _l10n;
    final editor = _editors[draft.editorKey];
    if (l10n == null || editor == null || !_current(editor)) return;
    editor.grants = grants;
    if (saved) {
      _say(editor, l10n.workspaceSkillSaved, error: false);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    // A new skill keeps the list for its first save.
    editor.dirty = true;
    await _showEdited(l10n, editor);
    await _applyEditor(l10n, editor, withPages: false);
  }

  /// Exposed for the capabilities the editor reads.
  @visibleForTesting
  WorkspaceSectionCapabilities get capabilities => _capabilities;
}

/// Reads a Markdown file the user picks, over Settings, or null when they
/// cancel; replaced in tests.
final workspaceSkillMarkdownPickerProvider =
    Provider<Future<String?> Function()>(
      (ref) => () async {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: const ['md', 'markdown', 'txt'],
        );
        if (file == null) return null;
        final bytes = file.path != null
            ? await File(file.path!).readAsBytes()
            : await file.readAsBytes();
        return utf8.decode(bytes);
      },
    );
