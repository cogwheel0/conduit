import 'dart:convert';
import 'dart:io';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/models/workspace_skill_content.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/utils/server_version_compat.dart';
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
import '../settings_controller.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'workspace_access_settings_pages.dart';
import 'workspace_page_ids.dart';
import 'workspace_settings_pages.dart' show workspaceSectionCapabilities;

/// One skill's editor while its page is open.
final class WorkspaceSkillEditor {
  WorkspaceSkillEditor(this.key, this.session, {this.since = 0});

  final String key;
  final WorkspaceSessionIdentity? session;

  /// How many row changes had joined Settings's queue as this editor
  /// opened: one numbered up to this was made on an editor before it.
  final int since;

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

  /// Whether the row change being handled was queued before [editor]
  /// opened: made on an editor since left under the same key, and not this
  /// one's to apply.
  bool _queuedBefore(WorkspaceSkillEditor editor) {
    final handled = _ref.read(settingsControllerProvider).controlHandled;
    return handled != null && handled <= editor.since;
  }

  /// The editor open under [key] for the account signed in now. One kept
  /// from another account is dropped unseen, with its access draft, and
  /// none is returned.
  WorkspaceSkillEditor? _openEditor(String? key) {
    final editor = key == null ? null : _editors[key];
    if (key == null || editor == null || _current(editor)) return editor;
    _editors.remove(key);
    _access.forget(key);
    return null;
  }

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    if (_access.ownsPage(detailId)) {
      final editor = _openEditor(_access.editorKeyOf(detailId));
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
      final key = detailId.substring(workspaceSkillContentPagePrefix.length);
      final kept = _editors[key];
      final editor = _openEditor(key);
      if (editor != null) {
        await _surface.applyDetail(
          buildWorkspaceSkillContentPage(l10n, editor: editor),
        );
      } else if (kept != null) {
        // Another account's source: closed rather than drawn.
        await _surface.closeDetail(detailId);
      }
      return;
    }
    final key = detailId.substring(workspaceSkillPagePrefix.length);
    final open = _openEditor(key);
    if (open != null) {
      await _applyEditor(l10n, open);
      return;
    }
    final editor = _editors[key] = WorkspaceSkillEditor(
      key,
      _session(),
      since: _ref.read(settingsControllerProvider).controlsQueued,
    );
    if (_notSent.remove(key)) _say(editor, l10n.workspaceEditorAccountChanged);
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
      _notSent.remove(key);
    }
  }

  @override
  void settingsClosed() {
    _editors.clear();
    _notSent.clear();
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
    if (editor == null || _queuedBefore(editor)) return true;
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

  /// Whether the server refused the id as taken: a 400 that says so. A
  /// 409 is a skill name already in use, which the id cannot fix.
  static bool _isConflict(Object error) {
    if (error is! DioException) return false;
    if (error.response?.statusCode != 400) return false;
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
      // On or off is the switch's to change: an update leaves it as the
      // server has it, should another client have switched it meanwhile.
      // Open WebUI before 0.12 takes a missing value as on, so it is sent
      // the value read instead.
      isActive: editor.isCreate
          ? true
          : ServerVersionCompat.knownAtLeast(
                  _ref.read(workspaceServerVersionProvider),
                  '0.12.0',
                ) ==
                true
          ? null
          : editor.summary?.isActive ?? true,
      // Who may open it is saved on its Access page; an update leaves it
      // as it is, rather than putting back what was read on opening.
      accessGrants: editor.isCreate ? editor.grants : null,
    );
    editor
      ..busy = true
      ..idError = false
      ..notice = null;
    await _applyEditor(l10n, editor, withPages: false);
    // Another account signed in while the editor was drawn busy: nothing is
    // sent, with no await between this and the write.
    if (!_current(editor)) {
      await _sessionEnded(l10n, editor);
      return;
    }
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
    if (!_current(editor)) {
      await _sessionEnded(l10n, editor);
      return;
    }
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

  /// Editors whose change was not sent because their session ended: the one
  /// read afresh in their place says so.
  final _notSent = <String>{};

  /// Frees [editor] once its session ended during a change it was drawn
  /// busy for, so its page is not left disabled. Still the one open, the
  /// page is described again for the session there is now, as on its
  /// return: the editor from before is dropped unseen, and the skill read
  /// afresh.
  Future<void> _sessionEnded(
    AppLocalizations l10n,
    WorkspaceSkillEditor editor,
  ) async {
    editor.busy = false;
    if (!identical(_editors[editor.key], editor)) return;
    _notSent.add(editor.key);
    await hydrate('$workspaceSkillPagePrefix${editor.key}', l10n);
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
    // Another account signed in while the editor was drawn busy: nothing is
    // sent, with no await between this and the operation.
    if (!_current(editor)) {
      await _sessionEnded(l10n, editor);
      return false;
    }
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
    if (!_current(editor)) {
      await _sessionEnded(l10n, editor);
      return false;
    }
    editor.busy = false;
    if (failed != null) {
      _say(editor, l10n.workspaceSkillSaveFailed);
      await _applyEditor(l10n, editor, withPages: false);
      return false;
    }
    return true;
  }

  /// The package a clone is made from, or null for a skill that is its
  /// SKILL.md alone.
  static List<Map<String, dynamic>>? _clonedFiles(WorkspaceSkillEditor editor) {
    final files = editor.summary?.files ?? const <Map<String, dynamic>>[];
    final supporting = [
      for (final file in files)
        if (file['path'] != 'SKILL.md') file,
    ];
    if (supporting.isEmpty) return null;
    return [
      {'path': 'SKILL.md', 'content': editor.content},
      ...supporting,
    ];
  }

  Future<void> _clone(
    AppLocalizations l10n,
    WorkspaceSkillEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || editor.readOnly) return;
    // The copy is of the skill as saved, so a draft is refused with a
    // prompt to save or discard it first.
    if (editor.dirty) {
      _say(editor, l10n.workspaceSkillCloneSaveFirst);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    final base = editor.id.trim();
    final description = editor.description.trim();
    final id = base.isEmpty ? 'skill_clone' : '${base}_clone';
    final name = '${editor.name.trim()} ${l10n.workspaceSkillCloneSuffix}';
    // Clones never take the source skill's sharing grants.
    final form = WorkspaceSkillForm(
      id: id,
      name: name,
      description: description.isEmpty ? null : description,
      content: editor.content,
      // Its supporting files go with it, beside a SKILL.md of the content
      // above: a package the server takes whole. With none, the content
      // alone makes the skill, as it always did.
      files: _clonedFiles(editor),
      meta: editor.meta,
      isActive: editor.summary?.isActive ?? true,
    );
    // Open WebUI 0.12 and later duplicate a skill themselves, every file of
    // its package included (the skill as read here has none); an older one
    // is sent a copy made from what was read.
    final serverClones = ServerVersionCompat.knownAtLeast(
      _ref.read(workspaceServerVersionProvider),
      '0.12.0',
    );
    final ok = await _operate(l10n, editor, () async {
      if (serverClones == false) {
        await _notifier.create(form);
        return;
      }
      try {
        await _notifier.clone(summary.id, newId: id, name: name);
      } on DioException catch (error) {
        // A server of a version not known to have it may not: a copy is
        // made instead, while the account it was read for is still in use.
        final status = error.response?.statusCode;
        if (serverClones == true || (status != 404 && status != 405)) {
          rethrow;
        }
        if (!_current(editor)) return;
        await _notifier.create(form);
      }
    });
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
    // Switched at once, it would stay switched if the changes were then
    // discarded: they are saved or discarded first.
    if (editor.dirty) {
      _say(editor, l10n.workspaceSkillToggleSaveFirst);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
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
    // Another account signed in while the page was drawn: nothing is sent,
    // and the page says it was not saved.
    if (!_current(editor)) return l10n.workspaceSkillSaveFailed;
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
