import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher, Offset, Rect;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_knowledge_files.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/navigation/routes.dart' show WorkspaceSection;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart'
    show KnowledgeUploadRefused;
import 'package:conduit_core/utils/debug_logger.dart';
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
import 'workspace_settings_pages.dart'
    show workspaceExportControllerProvider, workspaceSectionCapabilities;

/// The forms a knowledge base's files open: a text file, a folder, a file
/// or folder renamed, a file moved, and a file of the account's attached.
abstract final class WorkspaceKnowledgeForms {
  static const text = 'text';
  static const folder = 'folder';
  static const renameFile = 'rename-file';
  static const renameFolder = 'rename-folder';
  static const move = 'move';
  static const attach = 'attach';
}

/// What one of a knowledge base's forms holds while it is open.
final class WorkspaceKnowledgeFormDraft {
  String name = '';
  String content = '';
  String query = '';
  bool busy = false;
  String? notice;

  /// The name the form opened with: a rename's current name.
  String openedName = '';

  /// Whether anything was typed, so leaving asks first.
  bool get edited =>
      name.trim() != openedName.trim() || content.trim().isNotEmpty;
}

/// A knowledge base's editor while its page is open.
final class WorkspaceKnowledgeEditor {
  WorkspaceKnowledgeEditor(this.key, this.session);

  final String key;
  final WorkspaceSessionIdentity? session;

  /// The base as read, or as it was created on this page.
  WorkspaceKnowledgeSummary? summary;
  bool loaded = false;
  bool loadFailed = false;

  String name = '';
  String description = '';
  String maxFileCount = '';
  String maxFileSize = '';
  List<WorkspaceAccessGrantInput> grants = [];

  bool dirty = false;
  bool busy = false;
  String? notice;
  bool noticeIsError = true;
  bool shownEdited = false;

  /// The names of the folders seen, by id, for their pages' titles.
  final Map<String, String> folderNames = {};

  /// The folders whose pages are open, the deepest last.
  final List<String> foldersShown = [];

  /// What a folder's page says, by folder id.
  final Map<String, ({String text, bool error})> folderNotices = {};

  /// What each open form holds, by its page id.
  final Map<String, WorkspaceKnowledgeFormDraft> forms = {};

  /// Whether the files could not be read for the folder shown.
  bool filesFailed = false;

  /// Bumped as a folder is read, so an older read is not shown.
  int folderRead = 0;

  bool get isCreate => key == workspaceNewKey && summary == null;
  bool get external => summary?.isExternal ?? false;
  bool get writeAccess => isCreate || (summary?.writeAccess ?? false);

  /// The name and description cannot change: a connected base, or one the
  /// account may only view.
  bool get fieldsReadOnly => external || !writeAccess;

  /// The files cannot change, for the same reasons.
  bool get filesReadOnly => external || !writeAccess;
  bool get ready => isCreate || loaded;
  String? get knowledgeId => summary?.id;

  void adopt(WorkspaceKnowledgeSummary next) {
    summary = next;
    loaded = true;
    loadFailed = false;
    name = next.name;
    description = next.description;
    maxFileCount = next.maxFileCount?.toString() ?? '';
    maxFileSize = next.maxFileSize?.toString() ?? '';
    grants = [
      for (final grant in next.accessGrants)
        WorkspaceAccessGrantInput.fromGrant(grant),
    ];
    dirty = false;
  }
}

/// A limit as typed: no limit when empty, null when it is not a whole
/// number above zero.
({int? value})? workspaceKnowledgeLimit(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return (value: null);
  final parsed = int.tryParse(trimmed);
  return parsed != null && parsed > 0 ? (value: parsed) : null;
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _knowledgeRow(String field, String key, [String? extra]) =>
    workspaceRowId('knowledge-$field', key, extra);

/// The part of a form's row id after its key: the form's kind and target.
String _formExtra(String kind, String target) => '$kind|$target';

({String kind, String target})? _parseFormExtra(String? extra) {
  if (extra == null) return null;
  final bar = extra.indexOf('|');
  if (bar < 0) return null;
  return (kind: extra.substring(0, bar), target: extra.substring(bar + 1));
}

NativeSheetItemConfig _notice(
  String pageId,
  ({String text, bool error}) notice,
) => notice.error
    ? workspaceWarning('$pageId-notice', notice.text)
    : workspaceNote('$pageId-notice', notice.text, 'checkmark.circle');

/// A knowledge base's editor page: its name and description, its file
/// limits where the server takes them, its files, who may open it, and the
/// actions on it. A connected base, or one the account may only view, reads
/// without fields.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceKnowledgePage(
  AppLocalizations l10n, {
  required WorkspaceKnowledgeEditor editor,
  bool limitsAvailable = false,
  bool canExport = false,
}) {
  final key = editor.key;
  final pageId = '$workspaceKnowledgePagePrefix$key';
  final title = editor.isCreate
      ? l10n.workspaceKnowledgeCreateTitle
      : (editor.name.trim().isEmpty
            ? l10n.workspaceKnowledge
            : editor.name.trim());
  if (!editor.ready) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: title,
      items: [
        if (editor.loadFailed)
          NativeSheetItemConfig(
            id: _knowledgeRow('retry', key),
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
  final readOnly = editor.fieldsReadOnly;
  final summary = editor.summary;
  NativeSheetItemConfig field(
    String field,
    String title,
    String value, {
    required String symbol,
    bool multiline = false,
    String? placeholder,
    NativeSheetKeyboard? keyboard,
  }) => NativeSheetItemConfig(
    id: _knowledgeRow(field, key),
    title: title,
    sfSymbol: symbol,
    kind: readOnly
        ? NativeSheetItemKind.readOnlyText
        : multiline
        ? NativeSheetItemKind.multilineTextField
        : NativeSheetItemKind.textField,
    value: value,
    placeholder: placeholder ?? title,
    keyboard: keyboard,
    disabled: editor.busy,
  );
  final canWrite = editor.writeAccess && !editor.external;
  return NativeSheetDetailConfig(
    id: pageId,
    title: title,
    confirmActionId: readOnly ? null : _knowledgeRow('save', key),
    confirmActionLabel: editor.isCreate ? l10n.workspaceCreate : l10n.save,
    discardPrompt: readOnly ? null : nativeDiscardPrompt(l10n),
    edited: editor.dirty,
    busy: editor.busy,
    announcement: editor.notice,
    sections: [
      if (editor.notice != null)
        NativeSheetSectionConfig(
          items: [
            _notice(pageId, (
              text: editor.notice!,
              error: editor.noticeIsError,
            )),
          ],
        ),
      if (editor.external)
        NativeSheetSectionConfig(
          items: [
            workspaceNote(
              '$pageId-external',
              l10n.workspaceKnowledgeExternalReadOnly,
              'link',
              summary?.externalProvider,
            ),
          ],
        )
      else if (!editor.writeAccess)
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
        items: [
          field(
            'name',
            l10n.workspaceKnowledgeName,
            editor.name,
            symbol: 'books.vertical',
          ),
          field(
            'description',
            l10n.workspaceKnowledgeDescription,
            editor.description,
            symbol: 'text.alignleft',
            multiline: true,
          ),
        ],
      ),
      if (limitsAvailable)
        NativeSheetSectionConfig(
          title: l10n.workspaceKnowledgeLimitsTitle,
          footer: l10n.workspaceKnowledgeLimitsFooter,
          items: [
            field(
              'max-count',
              l10n.workspaceKnowledgeMaxFileCount,
              editor.maxFileCount,
              symbol: 'number',
              placeholder: l10n.workspaceKnowledgeLimitDefault,
              keyboard: NativeSheetKeyboard.number,
            ),
            field(
              'max-size',
              l10n.workspaceKnowledgeMaxFileSize,
              editor.maxFileSize,
              symbol: 'internaldrive',
              placeholder: l10n.workspaceKnowledgeLimitDefault,
              keyboard: NativeSheetKeyboard.number,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          if (summary != null)
            NativeSheetItemConfig(
              id: workspaceKnowledgeFolderPageId(key, ''),
              title: l10n.workspaceKnowledgeFilesTitle,
              sfSymbol: 'folder',
            ),
          NativeSheetItemConfig(
            id: workspaceAccessPageId(WorkspaceSection.knowledge, key),
            title: l10n.workspaceKnowledgeManageAccess,
            subtitle: workspaceAccessSummary(l10n, editor.grants),
            sfSymbol: 'person.2',
          ),
        ],
      ),
      if (summary != null && (canExport || canWrite))
        NativeSheetSectionConfig(
          items: [
            if (canExport)
              NativeSheetItemConfig(
                id: _knowledgeRow('export', key),
                title: l10n.workspaceKnowledgeExport,
                sfSymbol: 'square.and.arrow.up',
                showsDisclosure: false,
                disabled: editor.busy,
              ),
            if (canWrite)
              NativeSheetItemConfig(
                id: _knowledgeRow('reset', key),
                title: l10n.workspaceKnowledgeReset,
                sfSymbol: 'arrow.counterclockwise',
                destructive: true,
                showsDisclosure: false,
                disabled: editor.busy,
                confirmMessage: l10n.workspaceKnowledgeResetConfirmMessage(
                  summary.name,
                ),
              ),
            if (canWrite)
              NativeSheetItemConfig(
                id: _knowledgeRow('delete', key),
                title: l10n.workspaceKnowledgeDelete,
                sfSymbol: 'trash',
                destructive: true,
                showsDisclosure: false,
                disabled: editor.busy,
                confirmMessage: l10n.workspaceKnowledgeDeleteConfirmMessage(
                  summary.name,
                ),
              ),
          ],
        ),
    ],
  );
}

/// One folder of a knowledge base's files: what is uploading or still
/// being processed, its folders (each a page of its own), its files with
/// their menus, and the ways to add files.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceKnowledgeFolderPage(
  AppLocalizations l10n, {
  required WorkspaceKnowledgeEditor editor,
  required String directoryId,
  WorkspaceKnowledgeBrowserState? browser,
}) {
  final key = editor.key;
  final pageId = workspaceKnowledgeFolderPageId(key, directoryId);
  final title = directoryId.isEmpty
      ? l10n.workspaceKnowledgeFilesTitle
      : editor.folderNames[directoryId] ?? l10n.workspaceKnowledgeFilesTitle;
  final showing = browser != null && browser.directoryId == directoryId;
  // A folder that could not be read keeps the last one's entries in the
  // browser: it offers Retry, not those.
  if (!showing ||
      editor.filesFailed ||
      (browser.isLoading && !browser.isLoadingMore)) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: title,
      items: [
        if (editor.filesFailed && !(browser?.isLoading ?? false))
          NativeSheetItemConfig(
            id: _knowledgeRow('files-retry', key, directoryId),
            title: l10n.workspaceKnowledgeFilesLoadFailed,
            subtitle: l10n.workspaceRetry,
            sfSymbol: 'exclamationmark.triangle',
            showsDisclosure: false,
          )
        else
          buildNativeLoadingItem(l10n, id: '$pageId-loading'),
      ],
    );
  }
  final readOnly = editor.filesReadOnly;
  final busy = browser.isBusy;
  final notice = editor.folderNotices[directoryId];
  final upload = browser.upload;
  return NativeSheetDetailConfig(
    id: pageId,
    title: title,
    announcement: notice?.text,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(items: [_notice(pageId, notice)]),
      if (editor.external)
        NativeSheetSectionConfig(
          items: [
            workspaceNote(
              '$pageId-external',
              l10n.workspaceKnowledgeExternalReadOnly,
              'link',
            ),
          ],
        ),
      if (upload != null || browser.pending.isNotEmpty)
        NativeSheetSectionConfig(
          items: [
            if (upload != null)
              NativeSheetItemConfig(
                id: '$pageId-upload',
                title: l10n.workspaceKnowledgeUploading(upload.filename),
                subtitle: upload.fraction == null
                    ? null
                    : '${(upload.fraction! * 100).round()}%',
                sfSymbol: 'arrow.up.doc',
                showsDisclosure: false,
                pending: true,
              ),
            for (final file in browser.pending) _pendingRow(l10n, pageId, file),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          if (browser.isEmpty && upload == null && browser.pending.isEmpty)
            workspaceNote(
              '$pageId-empty',
              l10n.workspaceKnowledgeFilesEmpty,
              'folder',
            ),
          for (final folder in browser.directories)
            NativeSheetItemConfig(
              id: workspaceKnowledgeFolderPageId(key, folder.id),
              title: folder.name,
              sfSymbol: 'folder',
              disabled: busy,
              rowActions: [
                if (!readOnly && !busy) ...[
                  NativeSheetRowAction(
                    id: workspaceKnowledgeFormPageId(
                      WorkspaceKnowledgeForms.renameFolder,
                      key,
                      folder.id,
                    ),
                    label: l10n.workspaceKnowledgeRenameFolder,
                    sfSymbol: 'pencil',
                  ),
                  NativeSheetRowAction(
                    id: _knowledgeRow('folder-delete', key, folder.id),
                    label: l10n.workspaceKnowledgeDeleteFolder,
                    sfSymbol: 'trash',
                    destructive: true,
                    confirmMessage: l10n
                        .workspaceKnowledgeDeleteFolderConfirmMessage(
                          folder.name,
                        ),
                  ),
                ],
              ],
            ),
          for (final file in browser.files)
            NativeSheetItemConfig(
              id: '$pageId-file-${Uri.encodeComponent(file.id)}',
              title: file.filename,
              subtitle: file.size == null ? null : _formatSize(file.size!),
              sfSymbol: 'doc',
              kind: NativeSheetItemKind.info,
              rowActions: [
                if (!readOnly && !busy) ...[
                  NativeSheetRowAction(
                    id: workspaceKnowledgeFormPageId(
                      WorkspaceKnowledgeForms.renameFile,
                      key,
                      file.id,
                    ),
                    label: l10n.workspaceKnowledgeFileRename,
                    sfSymbol: 'pencil',
                  ),
                  NativeSheetRowAction(
                    id: _knowledgeRow('reindex', key, file.id),
                    label: l10n.workspaceKnowledgeFileRefresh,
                    sfSymbol: 'arrow.clockwise',
                  ),
                  NativeSheetRowAction(
                    id: workspaceKnowledgeFormPageId(
                      WorkspaceKnowledgeForms.move,
                      key,
                      file.id,
                    ),
                    label: l10n.workspaceKnowledgeFileMove,
                    sfSymbol: 'folder',
                  ),
                  NativeSheetRowAction(
                    id: _knowledgeRow('detach', key, file.id),
                    label: l10n.workspaceKnowledgeFileDetach,
                    sfSymbol: 'minus.circle',
                    destructive: true,
                  ),
                ],
              ],
            ),
          if (browser.hasMore)
            NativeSheetItemConfig(
              id: _knowledgeRow('files-more', key, directoryId),
              title: l10n.workspaceLoadMore,
              sfSymbol: 'arrow.down.circle',
              accent: true,
              showsDisclosure: false,
              pending: browser.isLoadingMore ? true : null,
              disabled: browser.isLoadingMore,
            ),
        ],
      ),
      if (!readOnly)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: _knowledgeRow('upload', key, directoryId),
              title: l10n.workspaceKnowledgeUploadFiles,
              sfSymbol: 'square.and.arrow.up',
              accent: true,
              showsDisclosure: false,
              disabled: busy,
            ),
            NativeSheetItemConfig(
              id: workspaceKnowledgeFormPageId(
                WorkspaceKnowledgeForms.attach,
                key,
                directoryId,
              ),
              title: l10n.workspaceKnowledgeAttachExisting,
              sfSymbol: 'paperclip',
              disabled: busy,
            ),
            NativeSheetItemConfig(
              id: workspaceKnowledgeFormPageId(
                WorkspaceKnowledgeForms.text,
                key,
                directoryId,
              ),
              title: l10n.workspaceKnowledgeAddText,
              sfSymbol: 'doc.text',
              disabled: busy,
            ),
            NativeSheetItemConfig(
              id: workspaceKnowledgeFormPageId(
                WorkspaceKnowledgeForms.folder,
                key,
                directoryId,
              ),
              title: l10n.workspaceKnowledgeNewFolder,
              sfSymbol: 'folder.badge.plus',
              disabled: busy,
            ),
          ],
        ),
    ],
  );
}

NativeSheetItemConfig _pendingRow(
  AppLocalizations l10n,
  String pageId,
  WorkspacePendingFile file,
) {
  final failed =
      (file.status ?? '').toLowerCase() == 'failed' || file.error != null;
  return NativeSheetItemConfig(
    id: '$pageId-pending-${Uri.encodeComponent(file.id)}',
    title: file.raw['filename']?.toString() ?? file.id,
    subtitle: failed
        ? l10n.workspaceKnowledgeStatusFailed
        : l10n.workspaceKnowledgeStatusPending,
    sfSymbol: failed ? 'exclamationmark.triangle' : 'hourglass',
    kind: NativeSheetItemKind.info,
    showsDisclosure: false,
    pending: failed ? null : true,
  );
}

/// One of a knowledge base's small forms: a text file or folder to add, a
/// file or folder to rename, where to move a file, or a file of the
/// account's to attach.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceKnowledgeFormPage(
  AppLocalizations l10n, {
  required WorkspaceKnowledgeEditor editor,
  required String kind,
  required String target,
  required WorkspaceKnowledgeFormDraft draft,
  WorkspaceKnowledgeBrowserState? browser,
  List<FileInfo>? files,
  bool filesFailed = false,
}) {
  final key = editor.key;
  final pageId = workspaceKnowledgeFormPageId(kind, key, target);
  final extra = _formExtra(kind, target);
  final notice = draft.notice;
  final noticeSection = [
    if (notice != null)
      NativeSheetSectionConfig(
        items: [workspaceWarning('$pageId-notice', notice)],
      ),
  ];
  NativeSheetItemConfig nameField(String title, {String? placeholder}) =>
      NativeSheetItemConfig(
        id: _knowledgeRow('form-name', key, extra),
        title: title,
        sfSymbol: 'textformat',
        kind: NativeSheetItemKind.textField,
        value: draft.name,
        placeholder: placeholder ?? title,
        disabled: draft.busy,
      );
  NativeSheetDetailConfig form(
    String title,
    List<NativeSheetItemConfig> items,
  ) => NativeSheetDetailConfig(
    id: pageId,
    title: title,
    confirmActionId: _knowledgeRow('form-done', key, extra),
    confirmActionLabel: l10n.save,
    discardPrompt: nativeDiscardPrompt(l10n),
    edited: draft.edited,
    busy: draft.busy,
    announcement: notice,
    sections: [
      ...noticeSection,
      NativeSheetSectionConfig(items: items),
    ],
  );
  switch (kind) {
    case WorkspaceKnowledgeForms.text:
      return form(l10n.workspaceKnowledgeAddText, [
        nameField(l10n.workspaceKnowledgeAddTextName),
        NativeSheetItemConfig(
          id: _knowledgeRow('form-content', key, extra),
          title: l10n.workspaceKnowledgeAddTextContent,
          sfSymbol: 'doc.text',
          kind: NativeSheetItemKind.multilineTextField,
          value: draft.content,
          placeholder: l10n.workspaceKnowledgeAddTextContent,
          disabled: draft.busy,
        ),
      ]);
    case WorkspaceKnowledgeForms.folder:
      return form(l10n.workspaceKnowledgeNewFolder, [
        nameField(l10n.workspaceKnowledgeFolderName),
      ]);
    case WorkspaceKnowledgeForms.renameFolder:
      return form(l10n.workspaceKnowledgeRenameFolder, [
        nameField(l10n.workspaceKnowledgeFolderName),
      ]);
    case WorkspaceKnowledgeForms.renameFile:
      return form(l10n.workspaceKnowledgeFileRename, [
        nameField(l10n.workspaceKnowledgeAddTextName),
      ]);
    case WorkspaceKnowledgeForms.move:
      final file = browser?.files.where((f) => f.id == target).firstOrNull;
      final current = file?.directoryId ?? '';
      final seen = <String>{};
      final folders = [
        for (final folder in [
          ...?browser?.breadcrumbs,
          ...?browser?.directories,
        ])
          if (seen.add(folder.id)) folder,
      ];
      NativeSheetItemConfig destination(String id, String title) =>
          NativeSheetItemConfig(
            id: _knowledgeRow('move-to', key, '$target|$id'),
            title: title,
            sfSymbol: id.isEmpty ? 'house' : 'folder',
            showsDisclosure: false,
            checked: id == current,
            disabled: draft.busy || id == current,
          );
      return NativeSheetDetailConfig(
        id: pageId,
        title: l10n.workspaceKnowledgeMoveTitle,
        busy: draft.busy,
        announcement: notice,
        sections: [
          ...noticeSection,
          NativeSheetSectionConfig(
            items: [
              destination('', l10n.workspaceKnowledgeMoveRoot),
              for (final folder in folders) destination(folder.id, folder.name),
            ],
          ),
        ],
      );
    case WorkspaceKnowledgeForms.attach:
      return NativeSheetDetailConfig(
        id: pageId,
        title: l10n.workspaceKnowledgeAttachExisting,
        busy: draft.busy,
        announcement: notice,
        search: NativeSheetSearchConfig(
          id: _knowledgeRow('attach-search', key, extra),
          placeholder: l10n.workspaceSearchHint,
          value: draft.query,
        ),
        sections: [
          ...noticeSection,
          NativeSheetSectionConfig(
            items: [
              if (files == null && filesFailed)
                NativeSheetItemConfig(
                  id: _knowledgeRow('attach-retry', key, extra),
                  title: l10n.workspaceLoadFailed,
                  subtitle: l10n.workspaceRetry,
                  sfSymbol: 'exclamationmark.triangle',
                  showsDisclosure: false,
                )
              else if (files == null)
                buildNativeLoadingItem(l10n, id: '$pageId-loading')
              else if (files.isEmpty)
                workspaceNote('$pageId-empty', l10n.workspaceEmpty, 'doc')
              else
                for (final file in files)
                  NativeSheetItemConfig(
                    id: _knowledgeRow('attach-pick', key, '$target|${file.id}'),
                    title: file.originalFilename.isEmpty
                        ? file.filename
                        : file.originalFilename,
                    subtitle: _formatSize(file.size),
                    sfSymbol: 'doc',
                    showsDisclosure: false,
                    disabled: draft.busy,
                  ),
            ],
          ),
        ],
      );
  }
  return NativeSheetDetailConfig(id: pageId, title: '');
}

/// A knowledge base's pages in Settings: its editor, its files folder by
/// folder, the small forms acting on them, and who may open it.
class WorkspaceKnowledgeSettingsPages extends SettingsPageModule {
  WorkspaceKnowledgeSettingsPages(this._ref) {
    _access = WorkspaceAccessPages(
      _ref,
      section: WorkspaceSection.knowledge,
      onSave: _saveAccess,
      onDone: _accessDone,
    );
  }

  final Ref _ref;
  late final WorkspaceAccessPages _access;
  AppLocalizations? _l10n;
  final Map<String, WorkspaceKnowledgeEditor> _editors = {};

  /// The files followed while a folder page is open, by editor key.
  final Map<String, ProviderSubscription<Object?>> _following = {};
  final Map<String, Timer> _pendingPolls = {};
  bool _redrawQueued = false;

  /// The account's files the attach forms list, by query.
  final Map<String, List<FileInfo>> _attachFiles = {};
  (String, String)? _attachFilesFor;

  /// The Attach form's files, by search, for the account signed in: another
  /// account's are dropped rather than shown.
  Map<String, List<FileInfo>> _attachCache() {
    final session = _session();
    final account = session == null ? null : (session.serverId, session.userId);
    if (account != _attachFilesFor) {
      _attachFiles.clear();
      _attachFailed.clear();
      _attachFilesFor = account;
    }
    return _attachFiles;
  }

  final Set<String> _attachFailed = {};

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);
  WorkspaceKnowledge get _notifier =>
      _ref.read(workspaceKnowledgeProvider.notifier);

  WorkspaceSectionCapabilities get _capabilities =>
      workspaceSectionCapabilities(
        _ref.read(workspaceCapabilitiesProvider).value,
        WorkspaceSection.knowledge,
      );

  @override
  bool ownsPage(String detailId) =>
      detailId.startsWith(workspaceKnowledgePagePrefix) ||
      detailId.startsWith(workspaceKnowledgeFolderPagePrefix) ||
      detailId.startsWith(workspaceKnowledgeFormPagePrefix) ||
      _access.ownsPage(detailId);

  WorkspaceSessionIdentity? _session() {
    try {
      return WorkspaceSessionIdentity.read(_ref);
    } on StateError {
      return null;
    }
  }

  bool _current(WorkspaceKnowledgeEditor editor) =>
      identical(_editors[editor.key], editor) &&
      (editor.session?.isCurrent(_ref) ?? false);

  /// The editor open under [key] for the account signed in now. One kept
  /// from another account is dropped unseen, with its access draft and the
  /// files it followed, and none is returned.
  WorkspaceKnowledgeEditor? _openEditor(String? key) {
    final editor = key == null ? null : _editors[key];
    if (key == null || editor == null || _current(editor)) return editor;
    _editors.remove(key);
    _access.forget(key);
    _stopFollowing(key);
    return null;
  }

  /// The editor [detailId] belongs to, as [_openEditor] finds it. A page
  /// left from another account's editor is closed rather than drawn.
  Future<WorkspaceKnowledgeEditor?> _ownerOf(
    String key,
    String detailId,
  ) async {
    final kept = _editors[key];
    final editor = _openEditor(key);
    if (editor == null && kept != null) await _surface.closeDetail(detailId);
    return editor;
  }

  /// Whether the base's own file limits may be set: Open WebUI 0.13 and
  /// later, never for a connected base, and only by its owner or an admin.
  bool _limitsAvailable(WorkspaceKnowledgeEditor editor) {
    if (editor.external || !_ref.read(knowledgeLimitsSupportedProvider)) {
      return false;
    }
    if (editor.isCreate) return true;
    return _ownsBase(editor);
  }

  /// The owner or an admin, who may also delete a file a base holds.
  bool _ownsBase(WorkspaceKnowledgeEditor editor) {
    final summary = editor.summary;
    final user = _ref.read(currentUserProvider2);
    if (summary == null || user == null) return false;
    return user.role == 'admin' || summary.userId == user.id;
  }

  WorkspaceKnowledgeFilesProvider? _filesOf(WorkspaceKnowledgeEditor editor) {
    final id = editor.knowledgeId;
    return id == null ? null : workspaceKnowledgeFilesProvider(id);
  }

  WorkspaceKnowledgeBrowserState? _browser(WorkspaceKnowledgeEditor editor) {
    final provider = _filesOf(editor);
    return provider == null ? null : _ref.read(provider).value;
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
          readOnly: editor.fieldsReadOnly,
          saveOnDone: editor.summary != null,
          resourceName: editor.name.trim().isEmpty ? null : editor.name.trim(),
          session: editor.session,
        );
      }
      await _access.hydrate(detailId, l10n);
      return;
    }
    final folder = workspaceKnowledgeFolderOf(detailId);
    if (folder != null) {
      final editor = await _ownerOf(folder.key, detailId);
      if (editor == null || editor.knowledgeId == null) return;
      await _openFolder(l10n, editor, folder.directoryId);
      return;
    }
    final form = workspaceKnowledgeFormOf(detailId);
    if (form != null) {
      final editor = await _ownerOf(form.key, detailId);
      if (editor == null) return;
      await _openForm(l10n, editor, form.kind, form.target, detailId);
      return;
    }
    final key = detailId.substring(workspaceKnowledgePagePrefix.length);
    final open = _openEditor(key);
    if (open != null) {
      await _applyEditor(l10n, open);
      return;
    }
    // This account's base, read afresh.
    final editor = _editors[key] = WorkspaceKnowledgeEditor(key, _session());
    await _applyEditor(l10n, editor);
    if (key != workspaceNewKey) await _load(editor);
  }

  @override
  void pageLeft(String detailId) {
    if (_access.ownsPage(detailId)) {
      _access.pageLeft(detailId);
      return;
    }
    final folder = workspaceKnowledgeFolderOf(detailId);
    if (folder != null) {
      final editor = _editors[folder.key];
      if (editor != null) {
        editor.foldersShown.remove(folder.directoryId);
        editor.folderNotices.remove(folder.directoryId);
        if (editor.foldersShown.isEmpty) {
          _stopFollowing(editor.key);
        } else {
          // The folder below is on top again, and what is added goes where
          // the browser is: it goes back there. Settings's own pages do not
          // say they appeared again, as the native sheet's do.
          final below = editor.foldersShown.last;
          if (_current(editor) && _browser(editor)?.directoryId != below) {
            unawaited(_readFolder(editor, below, refresh: false));
          }
        }
      }
      return;
    }
    final form = workspaceKnowledgeFormOf(detailId);
    if (form != null) {
      // Left, the form keeps nothing typed into it.
      _editors[form.key]?.forms.remove(detailId);
      return;
    }
    if (detailId.startsWith(workspaceKnowledgePagePrefix)) {
      final key = detailId.substring(workspaceKnowledgePagePrefix.length);
      _editors.remove(key);
      _access.forget(key);
      _stopFollowing(key);
    }
  }

  @override
  void settingsClosed() {
    for (final key in _following.keys.toList()) {
      _stopFollowing(key);
    }
    _editors.clear();
    _access.clear();
    _attachFiles.clear();
    _attachFailed.clear();
  }

  // -- Loading -----------------------------------------------------------------

  Future<void> _load(WorkspaceKnowledgeEditor editor) async {
    final l10n = _l10n;
    final id = workspaceIdOfKey(editor.key);
    if (l10n == null || id == null) return;
    editor.loadFailed = false;
    final detail = await _readDetail(id);
    if (!_current(editor)) return;
    if (detail == null) {
      editor.loadFailed = true;
    } else {
      editor.adopt(detail.summary);
    }
    await _applyEditor(l10n, editor);
  }

  /// Base [id] as the server has it now, or null when it cannot be read.
  Future<WorkspaceKnowledgeDetail?> _readDetail(String id) async {
    try {
      final provider = workspaceKnowledgeDetailProvider(id);
      final listening = _ref.listen(provider, (_, _) {});
      try {
        return await _ref.read(provider.future);
      } finally {
        listening.close();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-knowledge-load-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  // -- Drawing -----------------------------------------------------------------

  Future<void> _applyEditor(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor, {
    bool withPages = true,
  }) {
    final key = editor.key;
    editor.shownEdited = editor.dirty;
    return _surface.applyDetail(
      buildWorkspaceKnowledgePage(
        l10n,
        editor: editor,
        limitsAvailable: _limitsAvailable(editor),
        canExport: _capabilities.exportItems,
      ),
      detailSheets: [
        if (withPages && editor.ready) ...[
          buildNativeLoadingDetail(
            l10n: l10n,
            id: workspaceAccessPageId(WorkspaceSection.knowledge, key),
            title: l10n.workspaceKnowledgeManageAccess,
          ),
          if (editor.summary != null)
            buildNativeLoadingDetail(
              l10n: l10n,
              id: workspaceKnowledgeFolderPageId(key, ''),
              title: l10n.workspaceKnowledgeFilesTitle,
            ),
        ],
      ],
    );
  }

  Future<void> _showEdited(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
  ) {
    if (editor.dirty == editor.shownEdited) return Future.value();
    return _applyEditor(l10n, editor, withPages: false);
  }

  /// The folder page of [directoryId], and the pages its rows open.
  Future<void> _applyFolder(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
    String directoryId,
  ) {
    final browser = _browser(editor);
    final key = editor.key;
    final showing = browser != null && browser.directoryId == directoryId;
    if (showing) {
      for (final folder in [...browser.breadcrumbs, ...browser.directories]) {
        editor.folderNames[folder.id] = folder.name;
      }
    }
    final known = _ref.read(settingsPagesProvider);
    return _surface.applyDetail(
      buildWorkspaceKnowledgeFolderPage(
        l10n,
        editor: editor,
        directoryId: directoryId,
        browser: browser,
      ),
      detailSheets: [
        for (final page in <NativeSheetDetailConfig>[
          if (showing) ...[
            for (final folder in browser.directories) ...[
              buildNativeLoadingDetail(
                l10n: l10n,
                id: workspaceKnowledgeFolderPageId(key, folder.id),
                title: folder.name,
              ),
              buildNativeLoadingDetail(
                l10n: l10n,
                id: workspaceKnowledgeFormPageId(
                  WorkspaceKnowledgeForms.renameFolder,
                  key,
                  folder.id,
                ),
                title: l10n.workspaceKnowledgeRenameFolder,
              ),
            ],
            for (final file in browser.files) ...[
              buildNativeLoadingDetail(
                l10n: l10n,
                id: workspaceKnowledgeFormPageId(
                  WorkspaceKnowledgeForms.renameFile,
                  key,
                  file.id,
                ),
                title: l10n.workspaceKnowledgeFileRename,
              ),
              buildNativeLoadingDetail(
                l10n: l10n,
                id: workspaceKnowledgeFormPageId(
                  WorkspaceKnowledgeForms.move,
                  key,
                  file.id,
                ),
                title: l10n.workspaceKnowledgeMoveTitle,
              ),
            ],
            // A page with no title is not one the native sheet opens.
            for (final (kind, title) in [
              (
                WorkspaceKnowledgeForms.attach,
                l10n.workspaceKnowledgeAttachExisting,
              ),
              (WorkspaceKnowledgeForms.text, l10n.workspaceKnowledgeAddText),
              (
                WorkspaceKnowledgeForms.folder,
                l10n.workspaceKnowledgeNewFolder,
              ),
            ])
              buildNativeLoadingDetail(
                l10n: l10n,
                id: workspaceKnowledgeFormPageId(kind, key, directoryId),
                title: title,
              ),
          ],
        ])
          // Stand-ins only for pages not drawn yet: a form open above this
          // folder keeps what was typed through the folder's redraws.
          if (!known.contains(page.id)) page,
      ],
    );
  }

  Future<void> _applyForm(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
    String kind,
    String target,
  ) {
    final pageId = workspaceKnowledgeFormPageId(kind, editor.key, target);
    final draft = editor.forms[pageId] ??= WorkspaceKnowledgeFormDraft();
    return _surface.applyDetail(
      buildWorkspaceKnowledgeFormPage(
        l10n,
        editor: editor,
        kind: kind,
        target: target,
        draft: draft,
        browser: _browser(editor),
        files: _attachCache()[draft.query],
        filesFailed: _attachFailed.contains(draft.query),
      ),
    );
  }

  // -- Folders ---------------------------------------------------------------

  /// Shows folder [directoryId], reading it when the browser shows another.
  Future<void> _openFolder(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
    String directoryId,
  ) async {
    final provider = _filesOf(editor);
    if (provider == null) return;
    editor.foldersShown
      ..remove(directoryId)
      ..add(directoryId);
    _follow(editor, provider);
    final browser = _ref.read(provider).value;
    await _applyFolder(l10n, editor, directoryId);
    if (browser != null && browser.directoryId == directoryId) {
      // Back from a folder inside it, or opened again: read it again.
      await _readFolder(editor, directoryId, refresh: true);
      return;
    }
    await _readFolder(editor, directoryId, refresh: false);
  }

  Future<void> _readFolder(
    WorkspaceKnowledgeEditor editor,
    String directoryId, {
    required bool refresh,
  }) async {
    final l10n = _l10n;
    final provider = _filesOf(editor);
    if (l10n == null || provider == null) return;
    final read = ++editor.folderRead;
    editor.filesFailed = false;
    try {
      final listening = _ref.listen(provider, (_, _) {});
      try {
        await _ref.read(provider.future);
        if (!_current(editor) || editor.folderRead != read) return;
        final notifier = _ref.read(provider.notifier);
        final shown = _ref.read(provider).value?.directoryId;
        if (refresh || shown != directoryId) {
          await (shown == directoryId
              ? notifier.refresh()
              : notifier.openDirectory(directoryId));
        }
      } finally {
        listening.close();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-knowledge-files-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      if (_current(editor) && editor.folderRead == read) {
        editor.filesFailed = true;
      }
    }
    if (!_current(editor) || editor.folderRead != read) return;
    if (_ref.read(provider).hasError) editor.filesFailed = true;
    if (editor.foldersShown.contains(directoryId)) {
      await _applyFolder(l10n, editor, directoryId);
    }
  }

  void _follow(
    WorkspaceKnowledgeEditor editor,
    WorkspaceKnowledgeFilesProvider provider,
  ) {
    if (_following.containsKey(editor.key)) return;
    _following[editor.key] = _ref
        .listen<AsyncValue<WorkspaceKnowledgeBrowserState>>(provider, (
          _,
          next,
        ) {
          _syncPendingPoll(editor, next.value);
          _queueRedraw();
        });
  }

  void _stopFollowing(String key) {
    _following.remove(key)?.close();
    _pendingPolls.remove(key)?.cancel();
  }

  /// While files are still being processed, their state is read again
  /// every few seconds.
  void _syncPendingPoll(
    WorkspaceKnowledgeEditor editor,
    WorkspaceKnowledgeBrowserState? browser,
  ) {
    final pending = browser?.pending.isNotEmpty ?? false;
    final poll = _pendingPolls[editor.key];
    if (pending && poll == null) {
      final provider = _filesOf(editor);
      if (provider == null) return;
      _pendingPolls[editor.key] = Timer.periodic(const Duration(seconds: 3), (
        _,
      ) {
        if (!_current(editor)) return;
        unawaited(
          _ref.read(provider.notifier).refreshPending().catchError((_) {}),
        );
      });
    } else if (!pending && poll != null) {
      _pendingPolls.remove(editor.key)?.cancel();
    }
  }

  void _queueRedraw() {
    if (_redrawQueued) return;
    _redrawQueued = true;
    scheduleMicrotask(() async {
      _redrawQueued = false;
      final l10n = _l10n;
      if (l10n == null) return;
      for (final editor in _editors.values.toList()) {
        final folder = editor.foldersShown.lastOrNull;
        if (folder != null) await _applyFolder(l10n, editor, folder);
      }
    });
  }

  // -- Forms -------------------------------------------------------------------

  Future<void> _openForm(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
    String kind,
    String target,
    String pageId,
  ) async {
    final opening = !editor.forms.containsKey(pageId);
    final draft = editor.forms[pageId] ??= WorkspaceKnowledgeFormDraft();
    if (opening) {
      final browser = _browser(editor);
      // A rename starts from the name it has.
      if (kind == WorkspaceKnowledgeForms.renameFile) {
        draft.name =
            browser?.files.where((f) => f.id == target).firstOrNull?.filename ??
            '';
      } else if (kind == WorkspaceKnowledgeForms.renameFolder) {
        draft.name = editor.folderNames[target] ?? '';
      }
      draft.openedName = draft.name;
    }
    await _applyForm(l10n, editor, kind, target);
    if (kind == WorkspaceKnowledgeForms.attach) {
      await _readAttachFiles(editor, kind, target, draft.query);
    }
  }

  Future<void> _readAttachFiles(
    WorkspaceKnowledgeEditor editor,
    String kind,
    String target,
    String query,
  ) async {
    final l10n = _l10n;
    if (l10n == null) return;
    _attachFailed.remove(query);
    List<FileInfo>? files;
    try {
      final provider = query.isEmpty ? null : searchUserFilesProvider(query);
      if (provider == null) {
        final listening = _ref.listen(userFilesProvider, (_, _) {});
        try {
          files = await _ref.read(userFilesProvider.future);
        } finally {
          listening.close();
        }
      } else {
        final listening = _ref.listen(provider, (_, _) {});
        try {
          files = await _ref.read(provider.future);
        } finally {
          listening.close();
        }
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-knowledge-attach-list-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    final pageId = workspaceKnowledgeFormPageId(kind, editor.key, target);
    final draft = editor.forms[pageId];
    // Left, or searched again meanwhile: this answer is not shown.
    if (!_current(editor) || draft == null || draft.query != query) return;
    if (files == null) {
      // An earlier answer to the same search is not shown as this one's.
      _attachFailed.add(query);
      _attachCache().remove(query);
    } else {
      _attachCache()[query] = files;
    }
    await _applyForm(l10n, editor, kind, target);
  }

  // -- Changes -------------------------------------------------------------------

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    _l10n = l10n;
    if (await _access.handleChange(id, value, l10n)) return true;
    final row = parseWorkspaceRowId(id);
    if (row == null || !row.field.startsWith('knowledge-')) return false;
    final editor = _editors[row.key];
    // A row of another account's editor, drawn before it signed in, is
    // not acted on: nothing is read or sent for it under this account.
    if (editor == null || !_current(editor)) return true;
    final field = row.field.substring('knowledge-'.length);
    if (field == 'retry') {
      await _load(editor);
      return true;
    }
    if (!editor.ready) return true;
    switch (field) {
      case 'name' || 'description' || 'max-count' || 'max-size'
          when value is String && !editor.fieldsReadOnly && !editor.busy:
        final wasDirty = editor.dirty;
        switch (field) {
          case 'name':
            editor.name = value;
          case 'description':
            editor.description = value;
          case 'max-count':
            editor.maxFileCount = value;
          default:
            editor.maxFileSize = value;
        }
        editor.dirty = true;
        if (!wasDirty) await _applyEditor(l10n, editor, withPages: false);
      case 'save':
        await _save(l10n, editor);
      case 'export':
        await _export(l10n, editor);
      case 'reset':
        await _reset(l10n, editor);
      case 'delete':
        await _delete(l10n, editor);
      case 'files-retry' when row.extra != null:
        // Kept alive, a failed read stays the answer until it is dropped.
        final files = _filesOf(editor);
        if (files != null && _ref.read(files).hasError) _ref.invalidate(files);
        await _readFolder(editor, row.extra!, refresh: true);
      case 'files-more':
        // A read: a view-only account pages through the files too.
        await _fileAction(
          l10n,
          editor,
          (files) => files.loadMore(),
          failure: l10n.workspaceKnowledgeFilesLoadFailed,
          read: true,
        );
      case 'upload':
        await _upload(l10n, editor);
      case 'reindex' when row.extra != null:
        await _fileAction(
          l10n,
          editor,
          (files) => files.reindex(row.extra!),
          failure: l10n.workspaceKnowledgeSaveFailed,
          success: l10n.workspaceKnowledgeFileReindexed,
        );
      case 'detach' when row.extra != null:
        await _detach(l10n, editor, row.extra!);
      case 'folder-delete' when row.extra != null:
        await _fileAction(
          l10n,
          editor,
          (files) => files.deleteDirectory(row.extra!),
          failure: l10n.workspaceKnowledgeFolderDeleteFailed,
        );
      case 'form-name' || 'form-content' when value is String:
        final form = _parseFormExtra(row.extra);
        if (form == null) return true;
        final pageId = workspaceKnowledgeFormPageId(
          form.kind,
          editor.key,
          form.target,
        );
        final draft = editor.forms[pageId];
        if (draft == null || draft.busy) return true;
        final wasEdited = draft.edited;
        if (field == 'form-name') {
          draft.name = value;
        } else {
          draft.content = value;
        }
        if (wasEdited != draft.edited) {
          await _applyForm(l10n, editor, form.kind, form.target);
        }
      case 'form-done':
        final form = _parseFormExtra(row.extra);
        if (form != null) {
          await _submitForm(l10n, editor, form.kind, form.target);
        }
      case 'move-to' when row.extra != null:
        final bar = row.extra!.indexOf('|');
        if (bar < 0) return true;
        await _move(
          l10n,
          editor,
          row.extra!.substring(0, bar),
          row.extra!.substring(bar + 1),
        );
      case 'attach-search' when value is String:
        final form = _parseFormExtra(row.extra);
        if (form == null) return true;
        final pageId = workspaceKnowledgeFormPageId(
          form.kind,
          editor.key,
          form.target,
        );
        final draft = editor.forms[pageId];
        if (draft == null) return true;
        draft.query = value.trim();
        await _applyForm(l10n, editor, form.kind, form.target);
        await _readAttachFiles(editor, form.kind, form.target, draft.query);
      case 'attach-retry':
        final form = _parseFormExtra(row.extra);
        final pageId = form == null
            ? null
            : workspaceKnowledgeFormPageId(form.kind, editor.key, form.target);
        final draft = pageId == null ? null : editor.forms[pageId];
        if (form == null || draft == null) return true;
        // Kept alive, a failed read of the account's files stays the answer
        // until it is dropped.
        if (draft.query.isEmpty && _ref.read(userFilesProvider).hasError) {
          _ref.invalidate(userFilesProvider);
        }
        await _readAttachFiles(editor, form.kind, form.target, draft.query);
      case 'attach-pick' when row.extra != null:
        final bar = row.extra!.indexOf('|');
        if (bar < 0) return true;
        await _attach(
          l10n,
          editor,
          row.extra!.substring(0, bar),
          row.extra!.substring(bar + 1),
        );
    }
    return true;
  }

  void _say(
    WorkspaceKnowledgeEditor editor,
    String message, {
    bool error = true,
  }) {
    editor
      ..notice = message
      ..noticeIsError = error;
  }

  Future<void> _save(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
  ) async {
    if (editor.fieldsReadOnly || editor.busy) return;
    if (editor.name.trim().isEmpty) {
      _say(editor, l10n.workspaceKnowledgeNameRequired);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    WorkspaceKnowledgeLimits? limits;
    if (_limitsAvailable(editor)) {
      final count = workspaceKnowledgeLimit(editor.maxFileCount);
      final size = workspaceKnowledgeLimit(editor.maxFileSize);
      if (count == null || size == null) {
        _say(editor, l10n.workspaceKnowledgeLimitInvalid);
        await _applyEditor(l10n, editor, withPages: false);
        return;
      }
      limits = (maxFileCount: count.value, maxFileSize: size.value);
    }
    final form = WorkspaceKnowledgeForm(
      name: editor.name.trim(),
      description: editor.description.trim(),
      accessGrants: editor.grants,
      limits: limits,
    );
    final creating = editor.summary == null;
    editor
      ..busy = true
      ..notice = null;
    await _applyEditor(l10n, editor, withPages: false);
    // Another account signed in while the editor was drawn busy: nothing is
    // sent, with no await between this and the write.
    if (!_current(editor)) return;
    WorkspaceKnowledgeDetail? saved;
    try {
      saved = creating
          ? await _notifier.create(form)
          : await _notifier.updateItem(editor.summary!.id, form);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-knowledge-save-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return;
    editor.busy = false;
    if (saved == null) {
      _say(editor, l10n.workspaceKnowledgeSaveFailed);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    if (creating) {
      // Made, the page stays as the new base's, so its files can be added.
      // What a create answers may not say what the account may do with the
      // base, so it is read again; the one who made it may change it.
      final made = saved.summary;
      final read = await _readDetail(made.id);
      if (!_current(editor)) return;
      editor.adopt(
        read?.summary ??
            WorkspaceKnowledgeSummary(
              id: made.id,
              name: made.name,
              userId: made.userId,
              description: made.description,
              meta: made.meta,
              accessGrants: made.accessGrants,
              writeAccess: true,
              owner: made.owner,
              createdAt: made.createdAt,
              updatedAt: made.updatedAt,
            ),
      );
      _say(editor, l10n.workspaceKnowledgeSaved, error: false);
      await _applyEditor(l10n, editor);
      return;
    }
    editor.dirty = false;
    // Saved, the editor goes back to the list, which shows the base.
    _editors.remove(editor.key);
    _access.forget(editor.key);
    _stopFollowing(editor.key);
    await _surface.closeDetail('$workspaceKnowledgePagePrefix${editor.key}');
  }

  /// Runs [operation] on a saved base, the editor staying open.
  Future<bool> _operate(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
    Future<void> Function() operation, {
    required String failure,
  }) async {
    if (editor.busy) return false;
    editor
      ..busy = true
      ..notice = null;
    await _applyEditor(l10n, editor, withPages: false);
    if (!_current(editor)) return false;
    Object? failed;
    try {
      await operation();
    } catch (error, stackTrace) {
      failed = error;
      DebugLogger.error(
        'workspace-knowledge-operation-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return false;
    editor.busy = false;
    if (failed != null) {
      _say(editor, failure);
      await _applyEditor(l10n, editor, withPages: false);
      return false;
    }
    return true;
  }

  /// Where the share sheet opens from: the middle of the screen, as iPad
  /// asks for an origin.
  Rect? _shareOrigin() {
    final view = PlatformDispatcher.instance.views.firstOrNull;
    if (view == null) return null;
    final size = view.physicalSize / view.devicePixelRatio;
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 1,
      height: 1,
    );
  }

  Future<void> _export(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || !_capabilities.exportItems) return;
    List<int>? bytes;
    final ok = await _operate(
      l10n,
      editor,
      () async => bytes = await _notifier.export(summary.id),
      failure: l10n.workspaceKnowledgeExportFailed,
    );
    final exported = bytes;
    if (!ok || exported == null) return;
    await _applyEditor(l10n, editor, withPages: false);
    // Read for an account since gone, the base is not shared.
    if (!_current(editor)) return;
    try {
      await _ref
          .read(workspaceExportControllerProvider)
          .shareBytes(
            // Open WebUI exports a base as a ZIP archive.
            filename:
                '${summary.name.isEmpty ? 'knowledge' : summary.name}.zip',
            bytes: exported,
            mimeType: 'application/zip',
            sharePositionOrigin: _shareOrigin(),
          );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-knowledge-share-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_current(editor)) return;
      _say(editor, l10n.workspaceKnowledgeExportFailed);
      await _applyEditor(l10n, editor, withPages: false);
    }
  }

  Future<void> _reset(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || !editor.writeAccess || editor.external) return;
    final ok = await _operate(
      l10n,
      editor,
      () => _notifier.reset(summary.id),
      failure: l10n.workspaceKnowledgeSaveFailed,
    );
    if (!ok) return;
    // Every file is gone, so the browser reads its files again.
    _ref.invalidate(workspaceKnowledgeFilesProvider(summary.id));
    _say(editor, l10n.workspaceKnowledgeResetDone, error: false);
    await _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _delete(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || !editor.writeAccess || editor.external) return;
    final ok = await _operate(
      l10n,
      editor,
      () => _notifier.delete(summary.id),
      failure: l10n.workspaceKnowledgeSaveFailed,
    );
    if (!ok) return;
    _editors.remove(editor.key);
    _access.forget(editor.key);
    _stopFollowing(editor.key);
    await _surface.closeDetail('$workspaceKnowledgePagePrefix${editor.key}');
  }

  // -- Files -------------------------------------------------------------------

  /// Runs [action] on the base's files for the folder shown, saying on its
  /// page how it went.
  Future<bool> _fileAction(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
    Future<void> Function(WorkspaceKnowledgeFiles files) action, {
    required String failure,
    String? success,
    bool read = false,
  }) async {
    final provider = _filesOf(editor);
    final folder = editor.foldersShown.lastOrNull;
    if (provider == null || folder == null || (editor.filesReadOnly && !read)) {
      return false;
    }
    // Checked with no await before the request: a picker or a question may
    // have waited while another account signed in.
    if (!_current(editor)) return false;
    editor.folderNotices.remove(folder);
    String? problem;
    try {
      await action(_ref.read(provider.notifier));
    } on KnowledgeUploadRefused catch (refused) {
      // The base's limits refused it; the server said which.
      problem = refused.reason;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-knowledge-file-action-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      problem = failure;
    }
    if (!_current(editor)) return false;
    if (problem != null) {
      editor.folderNotices[folder] = (text: problem, error: true);
    } else if (success != null) {
      editor.folderNotices[folder] = (text: success, error: false);
    }
    if (editor.foldersShown.contains(folder)) {
      await _applyFolder(l10n, editor, folder);
    }
    return problem == null;
  }

  Future<void> _upload(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
  ) async {
    if (_filesOf(editor) == null || editor.filesReadOnly) return;
    final List<WorkspaceUploadSource> picked;
    try {
      // Over the Settings sheet, as a picker opened from one of its rows.
      picked = await _ref.read(workspaceKnowledgeFilePickerProvider)();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-knowledge-pick-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      final folder = editor.foldersShown.lastOrNull;
      if (folder == null || !_current(editor)) return;
      editor.folderNotices[folder] = (
        text: l10n.workspaceKnowledgeUploadFailed,
        error: true,
      );
      await _applyFolder(l10n, editor, folder);
      return;
    }
    // Cancelled, or the page was left while the picker was open.
    if (picked.isEmpty || !_current(editor)) return;
    await _fileAction(
      l10n,
      editor,
      (files) => files.uploadMany(picked),
      failure: l10n.workspaceKnowledgeUploadFailed,
    );
  }

  Future<void> _detach(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
    String fileId,
  ) async {
    final browser = _browser(editor);
    final file = browser?.files.where((f) => f.id == fileId).firstOrNull;
    if (file == null || editor.filesReadOnly) return;
    final owner = _ownsBase(editor);
    final answer = await _surface.ask(
      title: l10n.workspaceKnowledgeFileDetachTitle,
      message: l10n.workspaceKnowledgeFileDetachMessage(file.filename),
      actions: [
        NativeSheetAlertAction(
          'cancel',
          l10n.cancel,
          style: NativeSheetAlertStyle.cancel,
        ),
        NativeSheetAlertAction(
          'detach',
          l10n.workspaceKnowledgeFileDetach,
          style: NativeSheetAlertStyle.destructive,
        ),
        // Deleting the file itself is for the base's owner or an admin.
        if (owner)
          NativeSheetAlertAction(
            'delete',
            l10n.workspaceKnowledgeFileDeleteUnderlying,
            style: NativeSheetAlertStyle.destructive,
          ),
      ],
    );
    if ((answer != 'detach' && answer != 'delete') || !_current(editor)) {
      return;
    }
    await _fileAction(
      l10n,
      editor,
      (files) => files.detach(fileId, deleteUnderlying: answer == 'delete'),
      failure: l10n.workspaceKnowledgeFileDetachFailed,
    );
  }

  Future<void> _move(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
    String fileId,
    String directoryId,
  ) async {
    final pageId = workspaceKnowledgeFormPageId(
      WorkspaceKnowledgeForms.move,
      editor.key,
      fileId,
    );
    final draft = editor.forms[pageId];
    if (draft == null || draft.busy) return;
    await _runForm(
      l10n,
      editor,
      WorkspaceKnowledgeForms.move,
      fileId,
      draft,
      (files) => files.move(fileId, directoryId.isEmpty ? null : directoryId),
      failure: l10n.workspaceKnowledgeFileMoveFailed,
    );
  }

  Future<void> _attach(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
    String directoryId,
    String fileId,
  ) async {
    final pageId = workspaceKnowledgeFormPageId(
      WorkspaceKnowledgeForms.attach,
      editor.key,
      directoryId,
    );
    final draft = editor.forms[pageId];
    if (draft == null || draft.busy) return;
    await _runForm(
      l10n,
      editor,
      WorkspaceKnowledgeForms.attach,
      directoryId,
      draft,
      (files) => files.attachExisting(fileId),
      failure: l10n.workspaceKnowledgeAttachFailed,
    );
  }

  Future<void> _submitForm(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
    String kind,
    String target,
  ) async {
    final pageId = workspaceKnowledgeFormPageId(kind, editor.key, target);
    final draft = editor.forms[pageId];
    if (draft == null || draft.busy) return;
    final name = draft.name.trim();
    if (name.isEmpty) {
      draft.notice = l10n.workspaceKnowledgeNameRequired;
      await _applyForm(l10n, editor, kind, target);
      return;
    }
    final (action, failure) = switch (kind) {
      WorkspaceKnowledgeForms.text => (
        (WorkspaceKnowledgeFiles files) =>
            files.addTextFile(name, draft.content),
        l10n.workspaceKnowledgeAddTextFailed,
      ),
      WorkspaceKnowledgeForms.folder => (
        (WorkspaceKnowledgeFiles files) => files.createDirectory(name),
        l10n.workspaceKnowledgeFolderCreateFailed,
      ),
      WorkspaceKnowledgeForms.renameFolder => (
        (WorkspaceKnowledgeFiles files) => files.updateDirectory(target, name),
        l10n.workspaceKnowledgeFolderCreateFailed,
      ),
      _ => (
        (WorkspaceKnowledgeFiles files) => files.rename(target, name),
        l10n.workspaceKnowledgeFileRenameFailed,
      ),
    };
    await _runForm(l10n, editor, kind, target, draft, action, failure: failure);
  }

  /// Runs a form's [action], closing the form once it went through and
  /// staying on it with why when it did not.
  Future<void> _runForm(
    AppLocalizations l10n,
    WorkspaceKnowledgeEditor editor,
    String kind,
    String target,
    WorkspaceKnowledgeFormDraft draft,
    Future<void> Function(WorkspaceKnowledgeFiles files) action, {
    required String failure,
  }) async {
    final provider = _filesOf(editor);
    if (provider == null || editor.filesReadOnly) return;
    final pageId = workspaceKnowledgeFormPageId(kind, editor.key, target);
    draft
      ..busy = true
      ..notice = null;
    await _applyForm(l10n, editor, kind, target);
    if (!_current(editor)) return;
    String? problem;
    try {
      await action(_ref.read(provider.notifier));
    } on KnowledgeUploadRefused catch (refused) {
      problem = refused.reason;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-knowledge-form-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      problem = failure;
    }
    // Left meanwhile, the form is no one's.
    if (!_current(editor) || !identical(editor.forms[pageId], draft)) return;
    draft.busy = false;
    if (problem != null) {
      draft.notice = problem;
      await _applyForm(l10n, editor, kind, target);
      return;
    }
    editor.forms.remove(pageId);
    await _surface.closeDetail(pageId);
  }

  // -- Access ------------------------------------------------------------------

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
    if (!_current(editor)) return l10n.workspaceKnowledgeSaveFailed;
    try {
      final saved = await _notifier.updateAccess(summary.id, grants);
      // What the server kept: it drops grants the account may not give.
      draft.kept = [
        for (final grant in saved.summary.accessGrants)
          WorkspaceAccessGrantInput.fromGrant(grant),
      ];
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-knowledge-access-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      return l10n.workspaceKnowledgeSaveFailed;
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
      _say(editor, l10n.workspaceKnowledgeSaved, error: false);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    // A new base keeps the list for its first save.
    editor.dirty = true;
    await _showEdited(l10n, editor);
    await _applyEditor(l10n, editor, withPages: false);
  }
}

/// Picks files to upload, over Settings, or none when cancelled; replaced
/// in tests.
final workspaceKnowledgeFilePickerProvider =
    Provider<Future<List<WorkspaceUploadSource>> Function()>(
      (ref) => () async {
        final picked = await FilePicker.pickFiles(type: FileType.any);
        if (picked.isEmpty) return const [];
        return [
          for (final file in picked)
            (
              name: file.name,
              size: await file.length() ?? -1,
              read: () async => file.path != null
                  ? await File(file.path!).readAsBytes()
                  : await file.readAsBytes(),
            ),
        ];
      },
    );
