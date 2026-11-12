import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_prompt_command.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart';
import 'package:conduit_core/navigation/routes.dart' show WorkspaceSection;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:dio/dio.dart';
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

/// How many versions a page of a prompt's history holds.
const workspacePromptHistoryPageSize = 20;

/// A prompt's editor while its page is open.
final class WorkspacePromptEditor {
  WorkspacePromptEditor(this.key, this.session);

  final String key;
  final WorkspaceSessionIdentity? session;

  WorkspacePromptSummary? summary;
  bool loaded = false;
  bool loadFailed = false;

  String name = '';
  String command = '';
  String content = '';
  String commit = '';
  List<String> tags = [];
  List<WorkspaceAccessGrantInput> grants = [];
  String? versionId;
  bool isProduction = true;

  /// The command was typed, so the name no longer writes it.
  bool commandTyped = false;
  bool commandError = false;

  bool dirty = false;
  bool busy = false;
  String? notice;
  bool noticeIsError = true;
  bool shownEdited = false;

  /// What went wrong with the last change to a version, for its page.
  ({String versionId, String text})? versionFailure;

  /// Comparisons of versions with the live one, by version id.
  final Map<String, WorkspacePromptComparison> comparisons = {};

  /// The version history, as its page last read it.
  List<WorkspacePromptHistoryEntry>? history;
  int historyPage = 0;
  bool historyHasMore = false;
  bool historyLoading = false;
  bool historyFailed = false;
  int historyRead = 0;

  bool get isCreate => key == workspaceNewKey;
  bool get writeAccess => isCreate || (summary?.writeAccess ?? false);
  bool get readOnly => !writeAccess;
  bool get ready => isCreate || loaded;

  void adopt(WorkspacePromptSummary next) {
    summary = next;
    loaded = true;
    loadFailed = false;
    name = next.name;
    command = WorkspacePromptCommand.strip(next.command);
    content = next.content;
    commit = '';
    tags = [...next.tags];
    grants = [
      for (final grant in next.accessGrants)
        WorkspaceAccessGrantInput.fromGrant(grant),
    ];
    versionId = next.versionId;
    isProduction = true;
    commandTyped = true;
    commandError = false;
    dirty = false;
  }
}

String _formatDate(int seconds) {
  if (seconds <= 0) return '';
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}

String _shortId(String id) => id.length >= 7 ? id.substring(0, 7) : id;

/// A prompt's editor page: its name and command, its content and tags, the
/// version a save makes, who may open it, its history and, for a saved
/// prompt, the actions on it. A prompt the account may only view reads
/// without fields.
@visibleForTesting
NativeSheetDetailConfig buildWorkspacePromptPage(
  AppLocalizations l10n, {
  required WorkspacePromptEditor editor,
}) {
  final key = editor.key;
  final pageId = '$workspacePromptPagePrefix$key';
  final fallbackTitle = editor.isCreate
      ? l10n.workspacePromptCreateTitle
      : l10n.workspacePrompts;
  if (!editor.ready) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: fallbackTitle,
      items: [
        if (editor.loadFailed)
          NativeSheetItemConfig(
            id: workspaceRowId('prompt-retry', key),
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
  final locked = readOnly || editor.busy;
  final summary = editor.summary;
  NativeSheetItemConfig field(
    String field,
    String title,
    String value, {
    String symbol = 'textformat',
    bool multiline = false,
    String? placeholder,
    String? subtitle,
  }) => NativeSheetItemConfig(
    id: workspaceRowId('prompt-$field', key),
    title: title,
    subtitle: subtitle,
    sfSymbol: symbol,
    kind: readOnly
        ? NativeSheetItemKind.readOnlyText
        : multiline
        ? NativeSheetItemKind.multilineTextField
        : NativeSheetItemKind.textField,
    value: value,
    placeholder: placeholder ?? title,
    disabled: editor.busy,
  );
  return NativeSheetDetailConfig(
    id: pageId,
    title: editor.isCreate
        ? l10n.workspacePromptCreateTitle
        : (editor.name.trim().isEmpty ? fallbackTitle : editor.name.trim()),
    confirmActionId: readOnly ? null : workspaceRowId('prompt-save', key),
    confirmActionLabel: l10n.save,
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
        footer: readOnly ? null : l10n.workspacePromptCommandHint,
        items: [
          field(
            'name',
            l10n.workspacePromptName,
            editor.name,
            symbol: 'text.quote',
          ),
          field(
            'command',
            l10n.workspacePromptCommand,
            editor.command,
            symbol: editor.commandError
                ? 'exclamationmark.triangle'
                : 'chevron.left.forwardslash.chevron.right',
            placeholder: l10n.workspacePromptCommand,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          field(
            'content',
            l10n.workspacePromptContent,
            editor.content,
            symbol: 'doc.text',
            multiline: true,
            placeholder: l10n.workspacePromptContentHint,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.workspacePromptTags,
        items: [
          for (final tag in editor.tags)
            NativeSheetItemConfig(
              id: '$pageId-tag-${Uri.encodeComponent(tag)}',
              title: tag,
              sfSymbol: 'tag',
              kind: NativeSheetItemKind.info,
              rowActions: [
                if (!locked)
                  NativeSheetRowAction(
                    id: workspaceRowId('prompt-tag-remove', key, tag),
                    label: l10n.delete,
                    sfSymbol: 'trash',
                    destructive: true,
                  ),
              ],
            ),
          if (!locked)
            NativeSheetItemConfig(
              id: workspaceRowId('prompt-tag-add', key),
              title: l10n.workspacePromptTagAdd,
              sfSymbol: 'plus.circle',
              kind: NativeSheetItemKind.textField,
              value: '',
              placeholder: l10n.workspacePromptTagAdd,
            ),
        ],
      ),
      if (!readOnly && !editor.isCreate)
        NativeSheetSectionConfig(
          title: l10n.workspacePromptVersionSection,
          footer: l10n.workspacePromptSetProductionSubtitle,
          items: [
            field(
              'commit',
              l10n.workspacePromptCommitMessage,
              editor.commit,
              symbol: 'text.badge.checkmark',
              placeholder: l10n.workspacePromptCommitMessageHint,
            ),
            NativeSheetItemConfig(
              id: workspaceRowId('prompt-production', key),
              title: l10n.workspacePromptSetProduction,
              sfSymbol: 'checkmark.seal',
              kind: NativeSheetItemKind.toggle,
              value: editor.isProduction,
              disabled: editor.busy,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: workspaceAccessPageId(WorkspaceSection.prompts, key),
            title: l10n.workspacePromptManageAccess,
            subtitle: workspaceAccessSummary(l10n, editor.grants),
            sfSymbol: 'person.2',
          ),
          if (!editor.isCreate && summary != null)
            NativeSheetItemConfig(
              id: '$workspacePromptHistoryPagePrefix$key',
              title: l10n.workspacePromptHistory,
              sfSymbol: 'clock.arrow.circlepath',
            ),
        ],
      ),
      if (!editor.isCreate && summary != null && editor.writeAccess)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: workspaceRowId('prompt-details', key),
              title: l10n.workspacePromptUpdateDetails,
              sfSymbol: 'square.and.pencil',
              showsDisclosure: false,
              disabled: editor.busy,
            ),
            NativeSheetItemConfig(
              id: workspaceRowId('prompt-clone', key),
              title: l10n.workspacePromptClone,
              sfSymbol: 'plus.square.on.square',
              showsDisclosure: false,
              disabled: editor.busy,
            ),
            NativeSheetItemConfig(
              id: workspaceRowId('prompt-active', key),
              title: summary.isActive
                  ? l10n.workspacePromptDeactivate
                  : l10n.workspacePromptActivate,
              sfSymbol: summary.isActive ? 'pause.circle' : 'play.circle',
              showsDisclosure: false,
              disabled: editor.busy,
            ),
            NativeSheetItemConfig(
              id: workspaceRowId('prompt-delete', key),
              title: l10n.workspacePromptDelete,
              sfSymbol: 'trash',
              destructive: true,
              showsDisclosure: false,
              disabled: editor.busy,
              confirmMessage: l10n.workspacePromptDeleteConfirmMessage(
                summary.name.isEmpty ? summary.command : summary.name,
              ),
            ),
          ],
        ),
    ],
  );
}

/// A prompt's version history: each version, newest first, with the live
/// one marked.
@visibleForTesting
NativeSheetDetailConfig buildWorkspacePromptHistoryPage(
  AppLocalizations l10n, {
  required WorkspacePromptEditor editor,
}) {
  final key = editor.key;
  final pageId = '$workspacePromptHistoryPagePrefix$key';
  final entries = editor.history;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.workspacePromptHistory,
    items: [
      if (entries == null && editor.historyFailed)
        NativeSheetItemConfig(
          id: workspaceRowId('prompt-history-retry', key),
          title: l10n.workspacePromptHistoryLoadFailed,
          subtitle: l10n.workspaceRetry,
          sfSymbol: 'exclamationmark.triangle',
          showsDisclosure: false,
        )
      else if (entries == null)
        buildNativeLoadingItem(l10n, id: '$pageId-loading')
      else if (entries.isEmpty)
        workspaceNote(
          '$pageId-empty',
          l10n.workspacePromptHistoryEmpty,
          'clock',
        )
      else
        for (final entry in entries)
          NativeSheetItemConfig(
            id: workspacePromptVersionPageId(key, entry.id),
            title: entry.commitMessage?.trim().isNotEmpty ?? false
                ? entry.commitMessage!.trim()
                : l10n.workspacePromptHistoryCommitFallback,
            subtitle: [
              if (entry.id == editor.versionId) l10n.workspacePromptHistoryLive,
              _shortId(entry.id),
              _formatDate(entry.createdAt),
            ].where((part) => part.isNotEmpty).join(' · '),
            sfSymbol: entry.id == editor.versionId
                ? 'checkmark.seal'
                : 'clock.arrow.circlepath',
          ),
      if (entries != null && editor.historyHasMore)
        NativeSheetItemConfig(
          id: workspaceRowId('prompt-history-more', key),
          title: l10n.workspaceLoadMore,
          sfSymbol: 'arrow.down.circle',
          accent: true,
          showsDisclosure: false,
          pending: editor.historyLoading ? true : null,
          disabled: editor.historyLoading,
        ),
    ],
  );
}

String workspacePromptVersionPageId(String key, String versionId) =>
    '$workspacePromptVersionPagePrefix$key:${Uri.encodeComponent(versionId)}';

/// One version of a prompt: its message, when it was made and by whom, its
/// content, and what may be done with it.
@visibleForTesting
NativeSheetDetailConfig buildWorkspacePromptVersionPage(
  AppLocalizations l10n, {
  required WorkspacePromptEditor editor,
  required WorkspacePromptHistoryEntry entry,
}) {
  final key = editor.key;
  final pageId = workspacePromptVersionPageId(key, entry.id);
  final live = entry.id == editor.versionId;
  final content = entry.snapshot['content']?.toString() ?? '';
  final author = entry.owner?.name.trim();
  final failure = editor.versionFailure?.versionId == entry.id
      ? editor.versionFailure!.text
      : null;
  return NativeSheetDetailConfig(
    id: pageId,
    title: entry.commitMessage?.trim().isNotEmpty ?? false
        ? entry.commitMessage!.trim()
        : l10n.workspacePromptHistoryCommitFallback,
    busy: editor.busy,
    announcement: failure,
    sections: [
      if (failure != null)
        NativeSheetSectionConfig(
          items: [workspaceWarning('$pageId-failure', failure)],
        ),
      NativeSheetSectionConfig(
        items: [
          workspaceNote(
            '$pageId-when',
            [
              _shortId(entry.id),
              _formatDate(entry.createdAt),
              if (author != null && author.isNotEmpty) author,
            ].where((part) => part.isNotEmpty).join(' · '),
            live ? 'checkmark.seal' : 'clock',
            live ? l10n.workspacePromptHistoryLive : null,
          ),
          NativeSheetItemConfig(
            id: '$pageId-content',
            title: l10n.workspacePromptContent,
            sfSymbol: 'doc.text',
            kind: NativeSheetItemKind.readOnlyText,
            value: content,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        footer: live && editor.writeAccess
            ? l10n.workspacePromptHistoryDeleteProduction
            : null,
        items: [
          if (!live && editor.versionId != null)
            NativeSheetItemConfig(
              id: workspacePromptDiffPageId(key, entry.id),
              title: l10n.workspacePromptHistoryDiff,
              sfSymbol: 'arrow.left.arrow.right',
            ),
          if (!editor.readOnly)
            NativeSheetItemConfig(
              id: workspaceRowId('prompt-version-restore', key, entry.id),
              title: l10n.workspacePromptHistoryRestore,
              sfSymbol: 'arrow.uturn.backward.circle',
              accent: true,
              showsDisclosure: false,
              disabled: editor.busy,
            ),
          if (editor.writeAccess && !live)
            NativeSheetItemConfig(
              id: workspaceRowId('prompt-version-live', key, entry.id),
              title: l10n.workspacePromptHistorySetProduction,
              sfSymbol: 'checkmark.seal',
              showsDisclosure: false,
              disabled: editor.busy,
            ),
          if (editor.writeAccess && !live)
            NativeSheetItemConfig(
              id: workspaceRowId('prompt-version-delete', key, entry.id),
              title: l10n.workspacePromptHistoryDelete,
              sfSymbol: 'trash',
              destructive: true,
              showsDisclosure: false,
              disabled: editor.busy,
              confirmMessage: l10n.workspacePromptHistoryDeleteConfirmMessage,
            ),
        ],
      ),
    ],
  );
}

/// A version compared with the live one, as its page shows it.
final class WorkspacePromptComparison {
  /// The comparison's lines, unified-diff style, or null until read.
  List<String>? lines;
  bool nameChanged = false;
  bool loading = false;
  bool failed = false;
  bool tooLarge = false;
}

String workspacePromptDiffPageId(String key, String versionId) =>
    '$workspacePromptDiffPagePrefix$key:${Uri.encodeComponent(versionId)}';

/// The rows of a comparison: each line of [lines] (unified-diff style) as a
/// diff row, added, removed or unchanged, read out as such. The file
/// headers before the first run are left out, and a gap between two runs of
/// lines is a line of its own.
@visibleForTesting
List<NativeSheetItemConfig> workspacePromptDiffRows(
  AppLocalizations l10n,
  String pageId,
  List<String> lines,
) {
  final rows = <NativeSheetItemConfig>[];
  var hunks = 0;
  for (final (index, line) in lines.indexed) {
    // Past the first run, `--- ` is a removed line that began with `-- `.
    if (hunks == 0 &&
        (line.startsWith('--- ') ||
            line.startsWith('+++ ') ||
            line == '---' ||
            line == '+++')) {
      continue;
    }
    if (line.startsWith('@@')) {
      if (hunks++ > 0) {
        rows.add(
          NativeSheetItemConfig(
            id: '$pageId-gap-$index',
            title: '\u2026',
            kind: NativeSheetItemKind.diffLine,
            value: NativeSheetDiffLine.context.name,
          ),
        );
      }
      continue;
    }
    final (change, text) = switch (line.isEmpty ? ' ' : line[0]) {
      '+' => (NativeSheetDiffLine.added, line.substring(1)),
      '-' => (NativeSheetDiffLine.removed, line.substring(1)),
      ' ' => (
        NativeSheetDiffLine.context,
        line.isEmpty ? '' : line.substring(1),
      ),
      _ => (NativeSheetDiffLine.context, line),
    };
    // A blank line keeps its row: an empty title is dropped by the sheet.
    final shown = text.isEmpty ? ' ' : text;
    rows.add(
      NativeSheetItemConfig(
        id: '$pageId-line-$index',
        title: shown,
        subtitle: switch (change) {
          NativeSheetDiffLine.added => l10n.workspacePromptHistoryDiffAddedLine(
            text,
          ),
          NativeSheetDiffLine.removed =>
            l10n.workspacePromptHistoryDiffRemovedLine(text),
          NativeSheetDiffLine.context => shown,
        },
        kind: NativeSheetItemKind.diffLine,
        value: change.name,
      ),
    );
  }
  return rows;
}

/// A version of a prompt compared with its live one: what was removed and
/// added, line by line, read only.
@visibleForTesting
NativeSheetDetailConfig buildWorkspacePromptDiffPage(
  AppLocalizations l10n, {
  required WorkspacePromptEditor editor,
  required String versionId,
  required WorkspacePromptComparison? comparison,
}) {
  final key = editor.key;
  final pageId = workspacePromptDiffPageId(key, versionId);
  final lines = comparison?.lines;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.workspacePromptHistoryDiffTitle,
    sections: [
      // Not read yet, or being read: only a failed read offers Retry.
      if (comparison == null ||
          (lines == null && !comparison.failed && !comparison.tooLarge))
        NativeSheetSectionConfig(
          items: [buildNativeLoadingItem(l10n, id: '$pageId-loading')],
        )
      else if (comparison.tooLarge)
        NativeSheetSectionConfig(
          items: [
            workspaceWarning(
              '$pageId-too-large',
              l10n.workspacePromptHistoryDiffTooLarge,
            ),
          ],
        )
      else if (lines == null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: workspaceRowId('prompt-diff-retry', key, versionId),
              title: l10n.workspacePromptHistoryDiffFailed,
              subtitle: l10n.workspaceRetry,
              sfSymbol: 'exclamationmark.triangle',
              showsDisclosure: false,
            ),
          ],
        )
      else ...[
        if (comparison.nameChanged)
          NativeSheetSectionConfig(
            items: [
              workspaceNote(
                '$pageId-name',
                l10n.workspacePromptHistoryDiffNameChanged,
                'textformat',
              ),
            ],
          ),
        NativeSheetSectionConfig(
          items: lines.isEmpty
              ? [
                  workspaceNote(
                    '$pageId-same',
                    l10n.workspacePromptHistoryDiffEmpty,
                    'equal.circle',
                  ),
                ]
              : workspacePromptDiffRows(l10n, pageId, lines),
        ),
      ],
    ],
  );
}

bool _isCommandTaken(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    final detail = error.response?.data;
    final message = detail is Map ? detail['detail']?.toString() : null;
    return status == 400 &&
        (message == null || message.toLowerCase().contains('command'));
  }
  return false;
}

/// Prompts' editors in Settings.
class WorkspacePromptSettingsPages extends SettingsPageModule {
  WorkspacePromptSettingsPages(this._ref) {
    _access = WorkspaceAccessPages(
      _ref,
      section: WorkspaceSection.prompts,
      onSave: _saveAccess,
      onDone: _accessDone,
    );
  }

  final Ref _ref;
  late final WorkspaceAccessPages _access;
  AppLocalizations? _l10n;
  final Map<String, WorkspacePromptEditor> _editors = {};

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);
  WorkspacePrompts get _notifier =>
      _ref.read(workspacePromptsProvider.notifier);

  WorkspaceSectionCapabilities get _capabilities =>
      workspaceSectionCapabilities(
        _ref.read(workspaceCapabilitiesProvider).value,
        WorkspaceSection.prompts,
      );

  @override
  bool ownsPage(String detailId) =>
      detailId.startsWith(workspacePromptPagePrefix) ||
      detailId.startsWith(workspacePromptHistoryPagePrefix) ||
      detailId.startsWith(workspacePromptVersionPagePrefix) ||
      detailId.startsWith(workspacePromptDiffPagePrefix) ||
      _access.ownsPage(detailId);

  WorkspaceSessionIdentity? _session() {
    try {
      return WorkspaceSessionIdentity.read(_ref);
    } on StateError {
      return null;
    }
  }

  bool _current(WorkspacePromptEditor editor) =>
      identical(_editors[editor.key], editor) &&
      (editor.session?.isCurrent(_ref) ?? false);

  ({String key, String versionId})? _versionOf(String detailId) {
    final rest = detailId.substring(workspacePromptVersionPagePrefix.length);
    final colon = rest.indexOf(':');
    if (colon < 0) return null;
    return (
      key: rest.substring(0, colon),
      versionId: Uri.decodeComponent(rest.substring(colon + 1)),
    );
  }

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
    if (detailId.startsWith(workspacePromptHistoryPagePrefix)) {
      final editor =
          _editors[detailId.substring(workspacePromptHistoryPagePrefix.length)];
      if (editor == null) return;
      // Back from a version, the list stays where it was.
      if (editor.history == null) {
        await _applyHistory(l10n, editor);
        await _loadHistory(editor, reset: true);
      } else {
        await _applyHistory(l10n, editor);
      }
      return;
    }
    if (detailId.startsWith(workspacePromptDiffPagePrefix)) {
      final rest = detailId.substring(workspacePromptDiffPagePrefix.length);
      final colon = rest.indexOf(':');
      if (colon < 0) return;
      final editor = _editors[rest.substring(0, colon)];
      if (editor == null) return;
      final versionId = Uri.decodeComponent(rest.substring(colon + 1));
      final comparison = editor.comparisons[versionId];
      await _applyDiff(l10n, editor, versionId);
      if (comparison?.lines == null) await _loadDiff(editor, versionId);
      return;
    }
    if (detailId.startsWith(workspacePromptVersionPagePrefix)) {
      final version = _versionOf(detailId);
      final editor = version == null ? null : _editors[version.key];
      final entry = editor?.history
          ?.where((candidate) => candidate.id == version!.versionId)
          .firstOrNull;
      if (editor == null || entry == null) return;
      await _applyVersion(l10n, editor, entry);
      return;
    }
    final key = detailId.substring(workspacePromptPagePrefix.length);
    final open = _editors[key];
    if (open != null) {
      await _applyEditor(l10n, open);
      return;
    }
    final editor = _editors[key] = WorkspacePromptEditor(key, _session());
    await _applyEditor(l10n, editor);
    if (!editor.isCreate) await _load(editor);
  }

  @override
  void pageLeft(String detailId) {
    if (_access.ownsPage(detailId)) {
      _access.pageLeft(detailId);
      return;
    }
    if (detailId.startsWith(workspacePromptHistoryPagePrefix)) {
      final editor =
          _editors[detailId.substring(workspacePromptHistoryPagePrefix.length)];
      // Opened again, the history is read again.
      if (editor != null) {
        editor.history = null;
        editor.historyLoading = false;
        editor.historyRead++;
      }
      return;
    }
    if (detailId.startsWith(workspacePromptPagePrefix)) {
      final key = detailId.substring(workspacePromptPagePrefix.length);
      _editors.remove(key);
      _access.forget(key);
    }
  }

  @override
  void settingsClosed() {
    _editors.clear();
    _access.clear();
  }

  // -- Loading -----------------------------------------------------------------

  Future<void> _load(WorkspacePromptEditor editor) async {
    final l10n = _l10n;
    final id = workspaceIdOfKey(editor.key);
    if (l10n == null || id == null) return;
    editor.loadFailed = false;
    WorkspacePromptSummary? summary;
    try {
      final provider = workspacePromptDetailProvider(id);
      final listening = _ref.listen(provider, (_, _) {});
      try {
        summary = await _ref.read(provider.future);
      } finally {
        listening.close();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-prompt-load-failed',
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

  Future<void> _loadHistory(
    WorkspacePromptEditor editor, {
    required bool reset,
  }) async {
    final l10n = _l10n;
    final id = workspaceIdOfKey(editor.key);
    if (l10n == null || id == null || editor.historyLoading) return;
    final read = ++editor.historyRead;
    final page = reset ? 0 : editor.historyPage + 1;
    editor
      ..historyLoading = true
      ..historyFailed = false;
    if (!reset) await _applyHistory(l10n, editor);
    List<WorkspacePromptHistoryEntry>? entries;
    try {
      entries = await _notifier.history(id, page: page);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-prompt-history-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    // A read the page has since started over is not shown.
    if (!_current(editor) || editor.historyRead != read) return;
    editor.historyLoading = false;
    if (entries == null) {
      if (reset) editor.historyFailed = true;
    } else {
      editor
        ..history = [if (!reset) ...?editor.history, ...entries]
        ..historyPage = page
        ..historyHasMore = entries.length >= workspacePromptHistoryPageSize;
    }
    await _applyHistory(l10n, editor);
  }

  // -- Drawing ------------------------------------------------------------------

  Future<void> _applyEditor(
    AppLocalizations l10n,
    WorkspacePromptEditor editor, {
    bool withPages = true,
  }) {
    final key = editor.key;
    editor.shownEdited = editor.dirty;
    // Stand-ins only for pages not drawn yet: an open one keeps its rows.
    final known = _ref.read(settingsPagesProvider);
    final access = workspaceAccessPageId(WorkspaceSection.prompts, key);
    return _surface.applyDetail(
      buildWorkspacePromptPage(l10n, editor: editor),
      detailSheets: [
        if (withPages && editor.ready) ...[
          if (!known.contains(access))
            buildNativeLoadingDetail(
              l10n: l10n,
              id: access,
              title: l10n.workspacePromptManageAccess,
            ),
          if (!editor.isCreate &&
              !known.contains('$workspacePromptHistoryPagePrefix$key'))
            buildNativeLoadingDetail(
              l10n: l10n,
              id: '$workspacePromptHistoryPagePrefix$key',
              title: l10n.workspacePromptHistory,
            ),
        ],
      ],
    );
  }

  Future<void> _showEdited(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
  ) {
    if (editor.dirty == editor.shownEdited) return Future.value();
    return _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _applyHistory(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
  ) => _surface.applyDetail(
    buildWorkspacePromptHistoryPage(l10n, editor: editor),
    detailSheets: [
      for (final entry
          in editor.history ?? const <WorkspacePromptHistoryEntry>[])
        buildWorkspacePromptVersionPage(l10n, editor: editor, entry: entry),
    ],
  );

  // -- Changes ------------------------------------------------------------------

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    _l10n = l10n;
    if (await _access.handleChange(id, value, l10n)) return true;
    final row = parseWorkspaceRowId(id);
    if (row == null || !row.field.startsWith('prompt-')) return false;
    final editor = _editors[row.key];
    if (editor == null) return true;
    final field = row.field.substring('prompt-'.length);
    if (field == 'retry') {
      await _load(editor);
      return true;
    }
    if (!editor.ready || editor.busy) return true;
    switch (field) {
      case 'name' when value is String && !editor.readOnly:
        final wasDirty = editor.dirty;
        editor
          ..name = value
          ..dirty = true;
        // A new prompt's command follows its name until it is typed.
        if (editor.isCreate && !editor.commandTyped) {
          editor.command = WorkspacePromptCommand.slugify(value);
          await _applyEditor(l10n, editor, withPages: false);
        } else if (!wasDirty) {
          await _applyEditor(l10n, editor, withPages: false);
        }
      case 'command' when value is String && !editor.readOnly:
        final wasError = editor.commandError;
        editor
          ..command = value
          ..commandTyped = true
          ..commandError = false
          ..dirty = true;
        if (wasError) await _applyEditor(l10n, editor, withPages: false);
      case 'content' || 'commit' when value is String && !editor.readOnly:
        final wasDirty = editor.dirty;
        if (field == 'content') {
          editor.content = value;
        } else {
          editor.commit = value;
        }
        editor.dirty = true;
        if (!wasDirty) await _applyEditor(l10n, editor, withPages: false);
      case 'production' when value is bool && !editor.readOnly:
        editor
          ..isProduction = value
          ..dirty = true;
        await _applyEditor(l10n, editor, withPages: false);
      case 'tag-add' when value is String && !editor.readOnly:
        final tag = value.trim();
        if (tag.isNotEmpty && !editor.tags.contains(tag)) {
          editor
            ..tags = [...editor.tags, tag]
            ..dirty = true;
        }
        await _applyEditor(l10n, editor, withPages: false);
      case 'tag-remove' when row.extra != null && !editor.readOnly:
        editor
          ..tags = [
            for (final tag in editor.tags)
              if (tag != row.extra) tag,
          ]
          ..dirty = true;
        await _applyEditor(l10n, editor, withPages: false);
      case 'save':
        await _save(l10n, editor);
      case 'details':
        await _saveDetails(l10n, editor);
      case 'clone':
        await _clone(l10n, editor);
      case 'active':
        await _toggleActive(l10n, editor);
      case 'delete':
        await _delete(l10n, editor);
      case 'history-retry':
        await _loadHistory(editor, reset: true);
      case 'history-more':
        await _loadHistory(editor, reset: false);
      case 'diff-retry' when row.extra != null:
        editor.comparisons.remove(row.extra);
        await _applyDiff(l10n, editor, row.extra!);
        await _loadDiff(editor, row.extra!);
      case 'version-restore' when row.extra != null:
        await _restore(l10n, editor, row.extra!);
      case 'version-live' when row.extra != null:
        await _setLive(l10n, editor, row.extra!);
      case 'version-delete' when row.extra != null:
        await _deleteVersion(l10n, editor, row.extra!);
    }
    return true;
  }

  void _say(WorkspacePromptEditor editor, String message, {bool error = true}) {
    editor
      ..notice = message
      ..noticeIsError = error;
  }

  /// The command checked, or null after saying on the page why it is not
  /// one.
  String? _checked(AppLocalizations l10n, WorkspacePromptEditor editor) {
    if (editor.name.trim().isEmpty) {
      _say(editor, l10n.workspacePromptNameRequired);
      return null;
    }
    final command = WorkspacePromptCommand.strip(editor.command);
    if (!WorkspacePromptCommand.isValid(command)) {
      editor.commandError = true;
      _say(
        editor,
        command.isEmpty
            ? l10n.workspacePromptCommandRequired
            : l10n.workspacePromptCommandInvalid,
      );
      return null;
    }
    return command;
  }

  Future<void> _save(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
  ) async {
    if (editor.readOnly || editor.busy) return;
    final command = _checked(l10n, editor);
    if (command == null) {
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    if (editor.content.trim().isEmpty) {
      _say(editor, l10n.workspacePromptContentRequired);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    final commit = editor.commit.trim();
    final form = WorkspacePromptForm(
      command: command,
      name: editor.name.trim(),
      content: editor.content,
      tags: editor.tags,
      accessGrants: editor.grants,
      versionId: editor.versionId,
      commitMessage: commit.isEmpty ? null : commit,
      isProduction: editor.isProduction,
    );
    editor
      ..busy = true
      ..commandError = false
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
        'workspace-prompt-save-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      editor.commandError = _isCommandTaken(error);
      problem = editor.commandError
          ? l10n.workspacePromptCommandTaken
          : l10n.workspacePromptSaveFailed;
    }
    if (!_current(editor)) return;
    editor.busy = false;
    if (problem != null) {
      _say(editor, problem);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    editor.dirty = false;
    // Saved, the editor goes back to the list, which shows the prompt.
    _editors.remove(editor.key);
    _access.forget(editor.key);
    await _surface.closeDetail('$workspacePromptPagePrefix${editor.key}');
  }

  /// Runs [operation] on a saved prompt, the editor staying open.
  Future<bool> _operate(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
    Future<void> Function() operation, {
    String Function(Object error)? failure,
  }) async {
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
        'workspace-prompt-operation-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return false;
    editor.busy = false;
    if (failed != null) {
      _say(editor, failure?.call(failed) ?? l10n.workspacePromptSaveFailed);
      await _applyEditor(l10n, editor, withPages: false);
      return false;
    }
    return true;
  }

  /// Saves the name, command and tags alone, making no new version.
  Future<void> _saveDetails(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || !editor.writeAccess) return;
    final command = _checked(l10n, editor);
    if (command == null) {
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    editor.commandError = false;
    WorkspacePromptSummary? saved;
    final ok = await _operate(
      l10n,
      editor,
      () async => saved = await _notifier.updateMetadata(
        summary.id,
        name: editor.name.trim(),
        command: command,
        tags: editor.tags,
      ),
      failure: (error) {
        editor.commandError = _isCommandTaken(error);
        return editor.commandError
            ? l10n.workspacePromptCommandTaken
            : l10n.workspacePromptSaveFailed;
      },
    );
    if (!ok) return;
    final content = editor.content;
    final contentChanged = content != summary.content;
    if (saved != null) {
      editor.summary = saved;
    }
    // The content and the version still wait for Save when they changed.
    editor.dirty = contentChanged || editor.commit.trim().isNotEmpty;
    _say(editor, l10n.workspacePromptDetailsSaved, error: false);
    await _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _clone(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
  ) async {
    if (!editor.writeAccess) return;
    final baseCommand = WorkspacePromptCommand.strip(editor.command);
    final cloneCommand = WorkspacePromptCommand.slugify(
      '$baseCommand-${l10n.workspacePromptCloneSuffix}',
    );
    // Clones never inherit the source prompt's sharing grants.
    final form = WorkspacePromptForm(
      command: cloneCommand.isEmpty ? '$baseCommand-copy' : cloneCommand,
      name: '${editor.name.trim()} ${l10n.workspacePromptCloneSuffix}',
      content: editor.content,
      tags: editor.tags,
    );
    final ok = await _operate(
      l10n,
      editor,
      () => _notifier.create(form),
      failure: (error) => _isCommandTaken(error)
          ? l10n.workspacePromptCommandTaken
          : l10n.workspacePromptSaveFailed,
    );
    if (!ok) return;
    _say(editor, l10n.workspacePromptSaved, error: false);
    await _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _toggleActive(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || !editor.writeAccess) return;
    WorkspacePromptSummary? toggled;
    final ok = await _operate(
      l10n,
      editor,
      () async => toggled = await _notifier.toggle(summary.id),
    );
    if (!ok) return;
    if (toggled != null) editor.summary = toggled;
    _say(editor, l10n.workspacePromptSaved, error: false);
    await _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _delete(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || !editor.writeAccess) return;
    final ok = await _operate(l10n, editor, () => _notifier.delete(summary.id));
    if (!ok) return;
    _editors.remove(editor.key);
    _access.forget(editor.key);
    await _surface.closeDetail('$workspacePromptPagePrefix${editor.key}');
  }

  WorkspacePromptHistoryEntry? _entry(
    WorkspacePromptEditor editor,
    String versionId,
  ) => editor.history
      ?.where((candidate) => candidate.id == versionId)
      .firstOrNull;

  /// Puts a version's name, content and tags in the editor, to be saved as
  /// a new version. The command and who may open the prompt stay.
  Future<void> _restore(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
    String versionId,
  ) async {
    final entry = _entry(editor, versionId);
    if (entry == null || editor.readOnly) return;
    final snapshot = entry.snapshot;
    final content = snapshot['content']?.toString();
    final name = snapshot['name']?.toString();
    if (content != null) editor.content = content;
    if (name != null && name.isNotEmpty) editor.name = name;
    // A version that had no tags clears the current ones.
    editor
      ..tags = workspaceStringList(snapshot['tags'])
      ..dirty = true;
    _say(editor, l10n.workspacePromptHistoryRestored, error: false);
    // Back on the editor, which shows the restored version.
    await _applyEditor(l10n, editor, withPages: false);
    await _surface.closeDetail(
      '$workspacePromptHistoryPagePrefix${editor.key}',
    );
  }

  Future<void> _setLive(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
    String versionId,
  ) async {
    final summary = editor.summary;
    final entry = _entry(editor, versionId);
    if (summary == null || entry == null || !editor.writeAccess) return;
    editor
      ..busy = true
      ..versionFailure = null;
    await _applyVersion(l10n, editor, entry);
    WorkspacePromptSummary? updated;
    Object? failed;
    try {
      updated = await _notifier.setProductionVersion(summary.id, versionId);
    } catch (error, stackTrace) {
      failed = error;
      DebugLogger.error(
        'workspace-prompt-live-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return;
    editor.busy = false;
    if (failed == null) {
      if (updated != null) {
        // An editor with no edits shows the version now live, so a later
        // save starts from it; a draft keeps what was typed.
        if (editor.dirty) {
          editor.summary = updated;
        } else {
          editor.adopt(updated);
        }
      }
      editor.versionId = updated?.versionId ?? versionId;
      // Compared with the old live version, the comparisons are stale.
      editor.comparisons.clear();
      _say(editor, l10n.workspacePromptHistoryProductionSet, error: false);
    } else {
      _say(editor, l10n.workspacePromptSaveFailed);
      editor.versionFailure = (
        versionId: versionId,
        text: l10n.workspacePromptSaveFailed,
      );
    }
    await _applyVersion(l10n, editor, entry);
    await _applyHistory(l10n, editor);
    await _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _deleteVersion(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
    String versionId,
  ) async {
    final summary = editor.summary;
    final entry = _entry(editor, versionId);
    if (summary == null || entry == null || !editor.writeAccess) return;
    if (versionId == editor.versionId) return;
    editor
      ..busy = true
      ..versionFailure = null;
    await _applyVersion(l10n, editor, entry);
    Object? failed;
    try {
      await _notifier.deleteHistoryEntry(summary.id, versionId);
    } catch (error, stackTrace) {
      failed = error;
      DebugLogger.error(
        'workspace-prompt-version-delete-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return;
    editor.busy = false;
    if (failed != null) {
      _say(editor, l10n.workspacePromptSaveFailed);
      editor.versionFailure = (
        versionId: versionId,
        text: l10n.workspacePromptSaveFailed,
      );
      await _applyVersion(l10n, editor, entry);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    editor.history = [
      for (final candidate
          in editor.history ?? const <WorkspacePromptHistoryEntry>[])
        if (candidate.id != versionId) candidate,
    ];
    _say(editor, l10n.workspacePromptHistoryDeleted, error: false);
    await _applyHistory(l10n, editor);
    // The server's pages moved up by one: read them again from the first,
    // so Load More does not skip the version that moved into it.
    if (editor.historyHasMore) unawaited(_loadHistory(editor, reset: true));
    await _applyEditor(l10n, editor, withPages: false);
    await _surface.closeDetail(
      workspacePromptVersionPageId(editor.key, versionId),
    );
  }

  Future<void> _applyVersion(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
    WorkspacePromptHistoryEntry entry,
  ) => _surface.applyDetail(
    buildWorkspacePromptVersionPage(l10n, editor: editor, entry: entry),
    detailSheets: [
      if (entry.id != editor.versionId)
        buildNativeLoadingDetail(
          l10n: l10n,
          id: workspacePromptDiffPageId(editor.key, entry.id),
          title: l10n.workspacePromptHistoryDiffTitle,
        ),
    ],
  );

  Future<void> _applyDiff(
    AppLocalizations l10n,
    WorkspacePromptEditor editor,
    String versionId,
  ) => _surface.applyDetail(
    buildWorkspacePromptDiffPage(
      l10n,
      editor: editor,
      versionId: versionId,
      comparison: editor.comparisons[versionId] ??= WorkspacePromptComparison(),
    ),
  );

  /// Compares version [versionId] with the live one, as the server does.
  Future<void> _loadDiff(WorkspacePromptEditor editor, String versionId) async {
    final l10n = _l10n;
    final summary = editor.summary;
    final live = editor.versionId;
    final comparison = editor.comparisons[versionId] ??=
        WorkspacePromptComparison();
    if (l10n == null || summary == null || live == null || comparison.loading) {
      return;
    }
    comparison
      ..loading = true
      ..failed = false
      ..tooLarge = false;
    await _applyDiff(l10n, editor, versionId);
    Map<String, dynamic>? diff;
    var tooLarge = false;
    try {
      diff = await _notifier.historyDiff(
        summary.id,
        fromId: versionId,
        toId: live,
      );
    } on WorkspacePromptDiffTooLargeException {
      tooLarge = true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-prompt-diff-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    // Left meanwhile, or another account signed in: nothing to show it on.
    if (!_current(editor) ||
        !identical(editor.comparisons[versionId], comparison)) {
      return;
    }
    comparison
      ..loading = false
      ..tooLarge = tooLarge
      ..failed = diff == null && !tooLarge
      ..lines = diff == null
          ? null
          : [
              for (final line in diff['content_diff'] as List? ?? const [])
                line.toString(),
            ]
      ..nameChanged = diff?['name_changed'] == true;
    await _applyDiff(l10n, editor, versionId);
  }

  // -- Access ----------------------------------------------------------------------

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
        'workspace-prompt-access-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      return l10n.workspacePromptSaveFailed;
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
      _say(editor, l10n.workspacePromptSaved, error: false);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    // A new prompt keeps the list for its first save.
    editor.dirty = true;
    await _showEdited(l10n, editor);
    await _applyEditor(l10n, editor, withPages: false);
  }

  /// Exposed for the capabilities the editor reads.
  @visibleForTesting
  WorkspaceSectionCapabilities get capabilities => _capabilities;
}
