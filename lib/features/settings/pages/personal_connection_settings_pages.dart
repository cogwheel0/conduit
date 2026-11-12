import 'dart:async';

import 'package:collection/collection.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/integrations/personal_connection_drafts.dart';
import 'package:conduit_core/features/integrations/personal_connection_edits.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/account_display.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../integrations/views/personal_connection_messages.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';

/// The list of the account's personal tool servers and terminals.
const personalConnectionsPageId = NativeSheetRoutes.personalConnections;

/// Prefix of a connection's editor; its key follows (see
/// [personalConnectionEditorPageId]).
const personalConnectionEditorPagePrefix = 'personal-connection:';

/// Prefix of the rows of the personal connections' pages.
const personalConnectionRowPrefix = 'personal-connection.';

/// The key the list's own rows carry.
const personalConnectionsListKey = 'list';

/// The key of the editor of connection [identity] of [kind], or of a new one
/// when [identity] is null: the kind and the URI-encoded identity.
String personalConnectionEditorKey(
  PersonalConnectionKind kind,
  String? identity,
) =>
    '${personalConnectionKindRouteValue(kind)}|'
    '${Uri.encodeComponent(identity ?? personalConnectionNewRouteValue)}';

String personalConnectionEditorPageId(
  PersonalConnectionKind kind,
  String? identity,
) =>
    '$personalConnectionEditorPagePrefix'
    '${personalConnectionEditorKey(kind, identity)}';

/// A row of the personal connections' pages:
/// `personal-connection.<field>:<key>`, with [extra] after another colon.
String personalConnectionRowId(String field, String key, [String? extra]) =>
    '$personalConnectionRowPrefix$field:$key'
    '${extra == null ? '' : ':${Uri.encodeComponent(extra)}'}';

({PersonalConnectionKind kind, String identity})? _parseKey(String key) {
  final bar = key.indexOf('|');
  if (bar < 0) return null;
  final kind = personalConnectionKindFromRouteValue(key.substring(0, bar));
  if (kind == null) return null;
  return (kind: kind, identity: Uri.decodeComponent(key.substring(bar + 1)));
}

NativeSheetItemConfig _note(
  String id,
  String title, [
  String symbol = 'info.circle',
  String? subtitle,
]) => NativeSheetItemConfig(
  id: id,
  title: title,
  subtitle: subtitle,
  sfSymbol: symbol,
  kind: NativeSheetItemKind.info,
);

String _storedOn(
  AppLocalizations l10n,
  PersonalConnectionsSession session,
  List<OpenWebUiAccountEntry>? accounts,
) => l10n.personalConnectionsStoredOn(
  session.accountName,
  configServerDisplayName(session.api.serverConfig, accounts),
);

// -- The list ---------------------------------------------------------------

/// What the list of personal connections shows.
@immutable
@visibleForTesting
final class PersonalConnectionsListState {
  const PersonalConnectionsListState({
    required this.advanced,
    this.block,
    this.snapshot,
    this.loading = false,
    this.failed = false,
    this.accounts,
    this.cleared = const [],
    this.pending = const {},
    this.notice,
    this.noticeIsError = false,
  });

  final bool advanced;
  final PersonalConnectionsBlock? block;
  final PersonalConnectionsSnapshot? snapshot;
  final bool loading;
  final bool failed;
  final List<OpenWebUiAccountEntry>? accounts;

  /// Selections in chat cleared since a server they named went away.
  final List<String> cleared;

  /// Switches moved from a row's menu and not yet answered, by editor key,
  /// with the state each was moved to.
  final Map<String, bool> pending;
  final String? notice;
  final bool noticeIsError;
}

/// The account's personal tool servers and terminals: each opening its
/// editor, turned on or off from its menu, and a row adding one of each.
@visibleForTesting
NativeSheetDetailConfig buildPersonalConnectionsPage(
  AppLocalizations l10n,
  PersonalConnectionsListState state,
) {
  const pageId = personalConnectionsPageId;
  const key = personalConnectionsListKey;
  final block = state.block;
  if (!state.advanced || block != null) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: l10n.personalConnectionsTitle,
      items: [
        _note(
          '$pageId-unavailable',
          !state.advanced
              ? l10n.advancedRequiredMessage(l10n.personalConnectionsTitle)
              : personalConnectionsBlockText(l10n, block!),
          !state.advanced ? 'slider.horizontal.3' : 'lock',
        ),
      ],
    );
  }
  final snapshot = state.snapshot;
  if (snapshot == null) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: l10n.personalConnectionsTitle,
      items: [
        if (state.failed) ...[
          _note(
            '$pageId-failed',
            l10n.personalConnectionsLoadFailed,
            'exclamationmark.triangle',
          ),
          NativeSheetItemConfig(
            id: personalConnectionRowId('retry', key),
            title: l10n.retry,
            sfSymbol: 'arrow.clockwise',
            accent: true,
            showsDisclosure: false,
          ),
        ] else
          buildNativeLoadingItem(l10n, id: '$pageId-loading'),
      ],
    );
  }
  NativeSheetSectionConfig section(
    PersonalConnectionKind kind, {
    required String title,
    required String emptyText,
    required String emptyHint,
    required String addLabel,
    String? footer,
  }) {
    final entries = snapshot.entriesOf(kind);
    final add = NativeSheetItemConfig(
      id: personalConnectionEditorPageId(kind, null),
      title: entries.isEmpty ? emptyText : addLabel,
      subtitle: entries.isEmpty ? emptyHint : null,
      sfSymbol: 'plus.circle',
      accent: true,
    );
    return NativeSheetSectionConfig(
      title: title,
      footer: footer,
      items: [for (final entry in entries) _entryRow(l10n, state, entry), add],
    );
  }

  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.personalConnectionsTitle,
    announcement: state.notice,
    sections: [
      NativeSheetSectionConfig(
        footer: l10n.personalConnectionsKeyStorageNote,
        items: [
          _note(
            '$pageId-account',
            _storedOn(l10n, snapshot.session, state.accounts),
            'person.crop.circle',
          ),
          if (state.notice != null)
            _note(
              '$pageId-notice',
              state.notice!,
              state.noticeIsError ? 'exclamationmark.triangle' : 'info.circle',
            ),
        ],
      ),
      if (state.cleared.isNotEmpty)
        NativeSheetSectionConfig(
          items: [
            _note(
              '$pageId-cleared',
              l10n.personalConnectionsSelectionCleared(
                personalSelectionNoticeText(l10n, state.cleared),
              ),
            ),
            NativeSheetItemConfig(
              id: personalConnectionRowId('cleared-ok', key),
              title: l10n.ok,
              sfSymbol: 'checkmark',
              accent: true,
              showsDisclosure: false,
            ),
          ],
        ),
      section(
        PersonalConnectionKind.toolServer,
        title: l10n.toolServers,
        emptyText: l10n.personalConnectionsEmptyToolServers,
        emptyHint: l10n.personalConnectionsEmptyToolServersHint,
        addLabel: l10n.personalConnectionsAddToolServer,
      ),
      section(
        PersonalConnectionKind.terminal,
        title: l10n.personalConnectionsTerminals,
        emptyText: l10n.personalConnectionsEmptyTerminals,
        emptyHint: l10n.personalConnectionsEmptyTerminalsHint,
        addLabel: l10n.personalConnectionsAddTerminal,
        footer: snapshot.terminals.length > 1
            ? l10n.personalConnectionsTerminalOneActive
            : null,
      ),
    ],
  );
}

NativeSheetItemConfig _entryRow(
  AppLocalizations l10n,
  PersonalConnectionsListState state,
  PersonalConnectionEntry entry,
) {
  final key = personalConnectionEditorKey(entry.kind, entry.identity);
  final pending = state.pending[key];
  final enabled = pending ?? entry.enabled;
  return NativeSheetItemConfig(
    id: personalConnectionEditorPageId(entry.kind, entry.identity),
    title: entry.displayName,
    subtitle: [
      entry.editable
          ? personalConnectionPublicEndpoint(entry.url)
          : l10n.personalConnectionsUnsupported,
      if (!enabled) l10n.disabled,
    ].join('\n'),
    sfSymbol: entry.kind == PersonalConnectionKind.toolServer
        ? 'wrench.and.screwdriver'
        : 'terminal',
    pending: pending == null ? null : true,
    rowActions: [
      if (pending == null)
        NativeSheetRowAction(
          id: personalConnectionRowId(
            'enabled',
            key,
            entry.enabled ? 'off' : 'on',
          ),
          label: entry.enabled
              ? l10n.personalConnectionsTurnOff
              : l10n.personalConnectionsTurnOn,
          sfSymbol: entry.enabled ? 'pause.circle' : 'play.circle',
        ),
    ],
  );
}

// -- The editor ---------------------------------------------------------------

/// How a Test went.
enum _TestState { idle, testing, passed, failed }

/// One personal tool server or terminal, as the form holds it.
///
/// The entry is named by identity, not by list position, so the form keeps
/// editing the same connection if the list is reordered while it is open. A
/// stored key is never loaded into the form; it stays as saved unless the
/// user types a new one or removes it. The form belongs to the account that
/// was signed in when it opened, and acts for it or not at all.
final class _ConnectionEditor {
  _ConnectionEditor(this.key, this.kind, this.identity, this.owner);

  final String key;
  final PersonalConnectionKind kind;

  /// The identity of the connection, or [personalConnectionNewRouteValue].
  final String identity;

  /// The account the form acts for. Opened before any account had loaded,
  /// it is the one whose list first fills it.
  PersonalConnectionsSession? owner;

  /// Given to a tool server that has none: the reference editor keeps it
  /// under `info.id`, so it survives edits made in the Open WebUI client.
  final String stampKey = 'conduit-${const Uuid().v4().replaceAll('-', '')}';

  /// The entry as the server last listed it.
  PersonalConnectionEntry? existing;

  /// The entry as it was when the fields were filled from it. Save sends
  /// only what the user changed from it.
  Map<String, dynamic>? opened;
  List<Object?>? start;
  bool initialized = false;

  String name = '';
  String description = '';
  String url = '';
  String path = '';
  String spec = '';
  String keyText = '';
  PersonalConnectionSecretMode keyMode = PersonalConnectionSecretMode.replace;
  String authType = 'bearer';
  String specType = 'url';
  bool enabled = true;

  bool saving = false;
  bool deleting = false;
  bool? pendingEnabled;
  _TestState test = _TestState.idle;
  String? testText;

  /// Set by the first Save or Test: from then on each field shows its issue.
  bool attempted = false;
  String? message;
  bool messageIsError = false;

  bool get isNew => identity == personalConnectionNewRouteValue;
  bool get isTool => kind == PersonalConnectionKind.toolServer;
  bool get busy => saving || test == _TestState.testing || deleting;
  bool get readOnly => existing != null && !existing!.editable;
  bool get ownerChanged {
    final owner = this.owner;
    return owner != null && !owner.isCurrent();
  }

  bool get hasStoredKey =>
      (existing?.raw['key']?.toString() ?? '').trim().isNotEmpty;

  List<Object?> values() => [
    name,
    description,
    url,
    path,
    spec,
    keyText,
    keyMode,
    authType,
    specType,
    enabled,
  ];

  /// Whether leaving now would lose something the user entered.
  bool get edited {
    final start = this.start;
    if (start == null || readOnly) return false;
    return !const ListEquality<Object?>().equals(start, values());
  }

  /// Fills the form from [snapshot] once, then follows the entry through
  /// later reads of the list, within the account that opened the form.
  void initialize(PersonalConnectionsSnapshot snapshot) {
    owner ??= snapshot.session;
    if (initialized) {
      if (ownerChanged) return;
      final current = snapshot.find(kind, identity);
      if (current != null) existing = current;
      return;
    }
    if (isNew) {
      initialized = true;
      if (isTool) {
        const draft = PersonalToolServerDraft();
        path = draft.path;
        authType = draft.authType;
        specType = draft.specType;
      } else {
        path = const PersonalTerminalDraft().path;
      }
      start = values();
      return;
    }
    final entry = existing = snapshot.find(kind, identity);
    // Nothing to fill the fields from yet: wait for the entry to be listed
    // rather than showing it with empty fields that Save would write.
    if (entry == null) return;
    initialized = true;
    opened = entry.raw;
    keyMode = PersonalConnectionSecretMode.keep;
    if (isTool) {
      final draft = PersonalToolServerDraft.fromEntry(entry.raw);
      name = draft.name;
      description = draft.description;
      url = draft.url;
      path = draft.path;
      spec = draft.spec;
      authType = draft.authType;
      specType = draft.specType;
      enabled = draft.enabled;
    } else {
      final draft = PersonalTerminalDraft.fromEntry(entry.raw);
      name = draft.name;
      url = draft.url;
      path = draft.path;
      enabled = draft.enabled;
    }
    start = values();
  }

  PersonalToolServerDraft toolDraft() => PersonalToolServerDraft(
    name: name,
    description: description,
    url: url,
    specType: specType,
    path: path,
    spec: spec,
    authType: authType,
    key: keyText,
    keyMode: keyMode,
    enabled: enabled,
  );

  PersonalTerminalDraft terminalDraft() => PersonalTerminalDraft(
    name: name,
    url: url,
    path: path,
    key: keyText,
    keyMode: keyMode,
    enabled: enabled,
  );

  PersonalConnectionDraftIssue? validate() =>
      isTool ? toolDraft().validate() : terminalDraft().validate();

  Map<String, dynamic> patch(Map<String, dynamic> previous) => isTool
      ? toolDraft().toPatch(previous)
      : terminalDraft().toPatch(previous);

  Map<String, dynamic> newEntry() => isTool
      ? toolDraft().toNewEntry(id: stampKey)
      : terminalDraft().toNewEntry();

  /// Counts edits: a Test answered after one is about other values.
  int revision = 0;

  /// Any edit makes an earlier test result and message out of date.
  void changed() {
    revision++;
    test = _TestState.idle;
    testText = null;
    message = null;
  }

  /// Drops what the form holds, the typed key included.
  void forget() {
    keyText = '';
    spec = '';
  }

  /// Each field's own issue once the user has tried to save or test.
  ///
  /// The draft reports only its first issue, so the URL is checked with a
  /// stand-in path and the path or document with a stand-in URL: each field
  /// then shows its own problem whatever the other holds.
  ({String? url, String? path, String? spec}) fieldErrors(
    AppLocalizations l10n,
  ) {
    if (!attempted) return (url: null, path: null, spec: null);
    const validUrl = 'https://example.com';
    final PersonalConnectionDraftIssue? urlIssue;
    final PersonalConnectionDraftIssue? restIssue;
    if (isTool) {
      final draft = toolDraft();
      urlIssue = draft
          .copyWith(specType: 'url', path: 'openapi.json')
          .validate();
      restIssue = draft.copyWith(url: validUrl).validate();
    } else {
      final draft = terminalDraft();
      urlIssue = draft.copyWith(path: '/openapi.json').validate();
      restIssue = draft.copyWith(url: validUrl).validate();
    }
    String? text(PersonalConnectionDraftIssue? issue) =>
        issue == null ? null : personalConnectionIssueText(l10n, issue);
    return (
      url: text(urlIssue),
      path: restIssue == PersonalConnectionDraftIssue.pathRequired
          ? text(restIssue)
          : null,
      spec: restIssue == PersonalConnectionDraftIssue.specInvalid
          ? text(restIssue)
          : null,
    );
  }
}

NativeSheetDetailConfig _buildEditorPage(
  AppLocalizations l10n,
  _ConnectionEditor editor, {
  required PersonalConnectionsSession? session,
  required List<OpenWebUiAccountEntry>? accounts,
  required bool loading,
  required bool failed,
  required PersonalConnectionsBlock? block,
  bool advanced = true,
}) {
  final pageId = '$personalConnectionEditorPagePrefix${editor.key}';
  final key = editor.key;
  final title = editor.isNew
      ? (editor.isTool
            ? l10n.personalConnectionsAddToolServer
            : l10n.personalConnectionsAddTerminal)
      : (editor.isTool
            ? l10n.personalConnectionsEditToolServer
            : l10n.personalConnectionsEditTerminal);
  NativeSheetDetailConfig only(List<NativeSheetItemConfig> items) =>
      NativeSheetDetailConfig(id: pageId, title: title, items: items);
  // Advanced off, the form is closed as the list is, opened by a link
  // included.
  if (!advanced) {
    return only([
      _note(
        '$pageId-advanced',
        l10n.advancedRequiredMessage(l10n.personalConnectionsTitle),
        'slider.horizontal.3',
      ),
    ]);
  }
  final ownerChanged = editor.ownerChanged;
  if (ownerChanged && !editor.initialized) {
    // The account changed before the list arrived: nothing of theirs to keep,
    // and nothing of the new account's to show in their form.
    return only([
      _note(
        '$pageId-owner',
        l10n.personalConnectionsOwnerChanged,
        'exclamationmark.triangle',
      ),
    ]);
  }
  if (!ownerChanged && block != null) {
    return only([
      _note(
        '$pageId-blocked',
        personalConnectionsBlockText(l10n, block),
        'lock',
      ),
    ]);
  }
  if (!editor.initialized) {
    if (failed) {
      return only([
        _note(
          '$pageId-failed',
          l10n.personalConnectionsLoadFailed,
          'exclamationmark.triangle',
        ),
        NativeSheetItemConfig(
          id: personalConnectionRowId('retry', key),
          title: l10n.retry,
          sfSymbol: 'arrow.clockwise',
          accent: true,
          showsDisclosure: false,
        ),
      ]);
    }
    if (loading || !editor.isNew) {
      return only([
        if (loading)
          buildNativeLoadingItem(l10n, id: '$pageId-loading')
        else
          _note(
            '$pageId-missing',
            l10n.personalConnectionsNotFound,
            'questionmark.circle',
          ),
      ]);
    }
  }
  final owner = editor.owner ?? session;
  final storedOn = owner == null ? null : _storedOn(l10n, owner, accounts);
  final notices = NativeSheetSectionConfig(
    items: [
      if (ownerChanged)
        _note(
          '$pageId-owner',
          l10n.personalConnectionsOwnerChanged,
          'exclamationmark.triangle',
        ),
      if (editor.message != null)
        _note(
          '$pageId-message',
          editor.message!,
          editor.messageIsError ? 'exclamationmark.triangle' : 'info.circle',
        ),
    ],
  );
  final delete = NativeSheetSectionConfig(
    items: [
      NativeSheetItemConfig(
        id: personalConnectionRowId('delete', key),
        title: l10n.delete,
        sfSymbol: 'trash',
        destructive: true,
        showsDisclosure: false,
        pending: editor.deleting ? true : null,
        disabled: editor.saving || editor.test == _TestState.testing,
        confirmMessage: l10n.personalConnectionsDeleteMessage(
          editor.existing?.displayName ?? editor.name,
        ),
      ),
    ],
  );
  if (editor.readOnly) {
    final existing = editor.existing!;
    return NativeSheetDetailConfig(
      id: pageId,
      title: title,
      announcement: editor.message,
      sections: [
        if (notices.items.isNotEmpty) notices,
        NativeSheetSectionConfig(
          footer: storedOn,
          items: [
            _note('$pageId-unsupported', l10n.personalConnectionsUnsupported),
            NativeSheetItemConfig(
              id: personalConnectionRowId('enabled-now', key),
              title: l10n.enabledLabel,
              sfSymbol: 'power',
              kind: NativeSheetItemKind.toggle,
              value: editor.pendingEnabled ?? existing.enabled,
              disabled: editor.pendingEnabled != null || editor.deleting,
            ),
            _note(
              '$pageId-name',
              l10n.name,
              'textformat',
              existing.displayName,
            ),
            _note(
              '$pageId-url',
              l10n.personalConnectionsUrl,
              'link',
              personalConnectionPublicEndpoint(existing.url),
            ),
          ],
        ),
        delete,
      ],
    );
  }
  final errors = editor.fieldErrors(l10n);
  final showKey = !editor.isTool || editor.authType == 'bearer';
  final removing = editor.keyMode == PersonalConnectionSecretMode.clear;
  final keeping =
      editor.keyMode == PersonalConnectionSecretMode.keep &&
      editor.hasStoredKey;
  final testing = editor.test == _TestState.testing;
  return NativeSheetDetailConfig(
    id: pageId,
    title: title,
    confirmActionId: personalConnectionRowId('save', key),
    confirmActionLabel: l10n.save,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: editor.saving,
    edited: editor.edited,
    announcement: editor.message ?? editor.testText,
    sections: [
      if (notices.items.isNotEmpty) notices,
      NativeSheetSectionConfig(
        footer: editor.isTool
            ? null
            : l10n.personalConnectionsTerminalOneActive,
        items: [
          NativeSheetItemConfig(
            id: personalConnectionRowId('enabled', key),
            title: l10n.enabledLabel,
            sfSymbol: 'power',
            kind: NativeSheetItemKind.toggle,
            value: editor.enabled,
          ),
          NativeSheetItemConfig(
            id: personalConnectionRowId('name', key),
            title: l10n.name,
            sfSymbol: 'textformat',
            kind: NativeSheetItemKind.textField,
            value: editor.name,
            placeholder: l10n.name,
          ),
          if (editor.isTool)
            NativeSheetItemConfig(
              id: personalConnectionRowId('description', key),
              title: l10n.personalConnectionsDescriptionField,
              sfSymbol: 'text.alignleft',
              kind: NativeSheetItemKind.textField,
              value: editor.description,
              placeholder: l10n.personalConnectionsDescriptionField,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        footer: storedOn,
        items: [
          NativeSheetItemConfig(
            id: personalConnectionRowId('url', key),
            title: l10n.personalConnectionsUrl,
            subtitle: errors.url,
            sfSymbol: 'link',
            kind: NativeSheetItemKind.textField,
            value: editor.url,
            placeholder: 'https://',
            keyboard: NativeSheetKeyboard.url,
          ),
          if (editor.isTool)
            NativeSheetItemConfig(
              id: personalConnectionRowId('auth', key),
              title: l10n.personalConnectionsAuth,
              sfSymbol: 'lock',
              kind: NativeSheetItemKind.segment,
              value: editor.authType,
              options: [
                NativeSheetOptionConfig(
                  id: 'bearer',
                  label: l10n.directMcpAuthBearer,
                ),
                NativeSheetOptionConfig(
                  id: 'none',
                  label: l10n.directMcpAuthNone,
                ),
              ],
            ),
          if (showKey)
            NativeSheetItemConfig(
              id: personalConnectionRowId('key', key),
              title: l10n.apiKey,
              sfSymbol: 'key',
              kind: NativeSheetItemKind.secureTextField,
              value: editor.keyText,
              // The stored key never reaches the form; the placeholder says
              // what happens to it instead.
              placeholder: removing
                  ? l10n.personalConnectionsKeyWillRemove
                  : keeping
                  ? l10n.personalConnectionsKeyKept
                  : l10n.apiKey,
              disabled: removing,
            ),
          if (showKey && editor.hasStoredKey)
            NativeSheetItemConfig(
              id: personalConnectionRowId('key-mode', key),
              title: removing
                  ? l10n.personalConnectionsKeyKeep
                  : l10n.personalConnectionsKeyRemove,
              sfSymbol: removing ? 'arrow.uturn.backward' : 'key.slash',
              destructive: !removing,
              accent: removing,
              showsDisclosure: false,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          if (editor.isTool)
            NativeSheetItemConfig(
              id: personalConnectionRowId('spec-source', key),
              title: l10n.personalConnectionsSpecSource,
              sfSymbol: 'doc.text',
              kind: NativeSheetItemKind.segment,
              value: editor.specType,
              options: [
                NativeSheetOptionConfig(
                  id: 'url',
                  label: l10n.personalConnectionsSpecFromUrl,
                ),
                NativeSheetOptionConfig(
                  id: 'json',
                  label: l10n.personalConnectionsSpecInline,
                ),
              ],
            ),
          if (!editor.isTool || editor.specType == 'url')
            NativeSheetItemConfig(
              id: personalConnectionRowId('path', key),
              title: l10n.personalConnectionsPath,
              subtitle: errors.path,
              sfSymbol: 'point.topleft.down.to.point.bottomright.curvepath',
              kind: NativeSheetItemKind.textField,
              value: editor.path,
              placeholder: l10n.personalConnectionsPath,
            )
          else
            NativeSheetItemConfig(
              id: personalConnectionRowId('spec', key),
              title: l10n.personalConnectionsSpecJson,
              subtitle: errors.spec,
              sfSymbol: 'curlybraces',
              kind: NativeSheetItemKind.multilineTextField,
              value: editor.spec,
              placeholder: '{"openapi": "3.1.0", "paths": {}}',
            ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: personalConnectionRowId('test', key),
            title: l10n.personalConnectionsTestConnection,
            sfSymbol: 'bolt.horizontal',
            accent: true,
            showsDisclosure: false,
            pending: testing ? true : null,
            disabled: editor.saving || editor.deleting || testing,
          ),
          if (editor.testText != null)
            _note(
              '$pageId-test-result',
              editor.testText!,
              switch (editor.test) {
                _TestState.passed => 'checkmark.circle',
                _TestState.failed => 'exclamationmark.triangle',
                _ => 'hourglass',
              },
            ),
        ],
      ),
      if (!editor.isNew) delete,
    ],
  );
}

// -- The module ---------------------------------------------------------------

/// The signed-in account's personal tool servers and terminals, in pages of
/// Settings: the list, and an editor for each. The pages belong to the
/// Advanced disclosure and to the server's own rule for who may keep
/// personal connections. Every write acts for the account the page opened
/// for, or not at all.
class PersonalConnectionSettingsPages extends SettingsPageModule {
  PersonalConnectionSettingsPages(this._ref);

  final Ref _ref;
  AppLocalizations? _l10n;
  bool _listShown = false;

  /// The account the list was last drawn for: its switches act for it.
  PersonalConnectionsSession? _drawnFor;

  final Map<String, bool> _pending = {};
  String? _notice;
  bool _noticeIsError = false;
  final Map<String, _ConnectionEditor> _editors = {};
  final List<ProviderSubscription<Object?>> _following = [];
  bool _redrawQueued = false;

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);
  PersonalConnectionsController get _controller =>
      _ref.read(personalConnectionsProvider.notifier);

  @override
  bool ownsPage(String detailId) =>
      detailId == personalConnectionsPageId ||
      detailId.startsWith(personalConnectionEditorPagePrefix);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    _follow();
    if (detailId == personalConnectionsPageId) {
      _listShown = true;
      await _applyList(l10n);
      return;
    }
    final key = detailId.substring(personalConnectionEditorPagePrefix.length);
    final parsed = _parseKey(key);
    if (parsed == null) return;
    final editor = _editors[key] ??= _ConnectionEditor(
      key,
      parsed.kind,
      parsed.identity,
      _ref.read(personalConnectionsSessionProvider),
    );
    await _applyEditor(l10n, editor);
  }

  @override
  void pageLeft(String detailId) {
    if (detailId == personalConnectionsPageId) {
      _listShown = false;
      _notice = null;
    } else if (detailId.startsWith(personalConnectionEditorPagePrefix)) {
      // Left, the edit is abandoned, and a typed key with it.
      _editors
          .remove(detailId.substring(personalConnectionEditorPagePrefix.length))
          ?.forget();
    }
    _stopFollowingWhenIdle();
  }

  @override
  void settingsClosed() {
    _listShown = false;
    _notice = null;
    for (final editor in _editors.values) {
      editor.forget();
    }
    _editors.clear();
    _stopFollowingWhenIdle();
  }

  void _follow() {
    if (_following.isNotEmpty) return;
    void redraw(Object? _, Object? _) => _queueRedraw();
    _following.addAll([
      _ref.listen(personalConnectionsProvider, redraw),
      _ref.listen(personalConnectionsAccessProvider, redraw),
      _ref.listen(personalConnectionsSessionProvider, redraw),
      _ref.listen(personalSelectionNoticeProvider, redraw),
      _ref.listen(openWebUiAccountsProvider, redraw),
      _ref.listen(
        appSettingsProvider.select((s) => s.advancedFeaturesEnabled),
        redraw,
      ),
    ]);
  }

  void _stopFollowingWhenIdle() {
    if (_listShown || _editors.isNotEmpty) return;
    for (final subscription in _following) {
      subscription.close();
    }
    _following.clear();
  }

  void _queueRedraw() {
    if (_redrawQueued) return;
    _redrawQueued = true;
    scheduleMicrotask(() {
      _redrawQueued = false;
      final l10n = _l10n;
      if (l10n == null) return;
      unawaited(() async {
        if (_listShown) await _applyList(l10n);
        for (final editor in _editors.values.toList()) {
          await _applyEditor(l10n, editor);
        }
      }());
    });
  }

  Future<void> _applyList(AppLocalizations l10n) async {
    final connections = _ref.read(personalConnectionsProvider);
    final snapshot = connections.asData?.value;
    final state = PersonalConnectionsListState(
      advanced: _ref.read(appSettingsProvider).advancedFeaturesEnabled,
      block: _ref.read(personalConnectionsAccessProvider).block,
      snapshot: snapshot,
      loading: connections.isLoading,
      failed: connections.hasError && snapshot == null,
      accounts: _ref.read(openWebUiAccountsProvider).value,
      cleared: _ref.read(personalSelectionNoticeProvider),
      pending: Map.of(_pending),
      notice: _notice,
      noticeIsError: _noticeIsError,
    );
    _drawnFor = snapshot?.session;
    await _surface.applyDetail(
      buildPersonalConnectionsPage(l10n, state),
      detailSheets: [
        for (final kind in PersonalConnectionKind.values) ...[
          for (final entry
              in snapshot?.entriesOf(kind) ?? const <PersonalConnectionEntry>[])
            buildNativeLoadingDetail(
              l10n: l10n,
              id: personalConnectionEditorPageId(kind, entry.identity),
              title: entry.displayName,
            ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: personalConnectionEditorPageId(kind, null),
            title: kind == PersonalConnectionKind.toolServer
                ? l10n.personalConnectionsAddToolServer
                : l10n.personalConnectionsAddTerminal,
          ),
        ],
      ],
    );
  }

  Future<void> _applyEditor(
    AppLocalizations l10n,
    _ConnectionEditor editor,
  ) async {
    if (!identical(_editors[editor.key], editor)) return;
    final connections = _ref.read(personalConnectionsProvider);
    final snapshot = connections.asData?.value;
    // A form that opened with no account to claim takes the first that
    // appears, before its list can have loaded.
    if (!editor.ownerChanged && snapshot != null) {
      editor.initialize(snapshot);
    }
    await _surface.applyDetail(
      _buildEditorPage(
        l10n,
        editor,
        session: _ref.read(personalConnectionsSessionProvider),
        accounts: _ref.read(openWebUiAccountsProvider).value,
        loading: connections.isLoading || snapshot == null,
        failed: connections.hasError && snapshot == null,
        block: _ref.read(personalConnectionsAccessProvider).block,
        advanced: _advanced,
      ),
    );
  }

  bool get _advanced => _ref.read(appSettingsProvider).advancedFeaturesEnabled;

  Future<void> _setEnabledFromList(
    AppLocalizations l10n,
    String key,
    bool value,
  ) async {
    final parsed = _parseKey(key);
    final snapshot = _ref.read(personalConnectionsProvider).asData?.value;
    if (parsed == null || snapshot == null || _pending.containsKey(key)) {
      return;
    }
    // The row belongs to the list it was drawn from; a switch drawn for an
    // account that has since gone is refused, not applied to the new one.
    final owner = _drawnFor;
    if (owner == null) return;
    _pending[key] = value;
    _notice = null;
    await _applyList(l10n);
    try {
      final outcome = await _controller.save(
        owner,
        parsed.kind,
        SetPersonalConnectionEnabled(parsed.identity, value),
      );
      if (outcome.stale) {
        _notice = l10n.personalConnectionsSavedForPreviousAccount;
        _noticeIsError = false;
      }
    } catch (error) {
      _notice = personalConnectionSaveError(l10n, error);
      _noticeIsError = true;
    } finally {
      _pending.remove(key);
    }
    if (_listShown) await _applyList(l10n);
  }

  /// The form's account: the one that opened it, while it is signed in.
  PersonalConnectionsSession? _owner(_ConnectionEditor editor) =>
      editor.owner ?? _ref.read(personalConnectionsSessionProvider);

  Future<void> _save(AppLocalizations l10n, _ConnectionEditor editor) async {
    final owner = _owner(editor);
    if (owner == null || editor.busy || !editor.initialized) return;
    if (editor.validate() != null) {
      editor.attempted = true;
      await _applyEditor(l10n, editor);
      return;
    }
    final PersonalConnectionEdit edit;
    final existing = editor.existing;
    final opened = editor.opened;
    if (editor.isNew) {
      edit = AddPersonalConnection(editor.newEntry());
    } else if (existing != null && opened != null) {
      final patch = editor.patch(opened);
      if (patch.isEmpty) {
        _editors.remove(editor.key)?.forget();
        await _surface.closeDetail(
          '$personalConnectionEditorPagePrefix${editor.key}',
        );
        return;
      }
      edit = PatchPersonalConnection(
        existing.identity,
        patch,
        stampKey: editor.isTool ? editor.stampKey : null,
      );
    } else {
      return;
    }
    editor
      ..attempted = true
      ..saving = true
      ..message = null;
    await _applyEditor(l10n, editor);
    try {
      final outcome = await _controller.save(owner, editor.kind, edit);
      if (!identical(_editors[editor.key], editor)) return;
      if (outcome.stale) {
        // The write reached the account that opened the form, and nothing
        // for the account signed in now. The form stays to say so.
        editor
          ..message = l10n.personalConnectionsSavedForPreviousAccount
          ..messageIsError = false;
      } else {
        _editors.remove(editor.key)?.forget();
        await _surface.closeDetail(
          '$personalConnectionEditorPagePrefix${editor.key}',
        );
        return;
      }
    } catch (error) {
      if (!identical(_editors[editor.key], editor)) return;
      editor
        ..message = personalConnectionSaveError(l10n, error)
        ..messageIsError = true;
    } finally {
      editor.saving = false;
    }
    await _applyEditor(l10n, editor);
  }

  Future<void> _test(AppLocalizations l10n, _ConnectionEditor editor) async {
    final owner = _owner(editor);
    if (owner == null || editor.busy || !editor.initialized) return;
    if (editor.validate() != null) {
      editor
        ..attempted = true
        ..test = _TestState.idle
        ..testText = null;
      await _applyEditor(l10n, editor);
      return;
    }
    final existing = editor.existing;
    final opened = editor.opened;
    final entry = existing == null || opened == null
        ? editor.newEntry()
        : mergePersonalConnectionPatch(existing.raw, editor.patch(opened));
    editor
      ..attempted = true
      ..test = _TestState.testing
      ..testText = l10n.connecting
      ..message = null;
    await _applyEditor(l10n, editor);
    final revision = editor.revision;
    try {
      final result = await _controller.testConnection(
        owner,
        editor.kind,
        entry,
      );
      if (!identical(_editors[editor.key], editor)) return;
      // Edited while it was tested: the answer is about other values.
      if (editor.revision != revision) return;
      final error = result.error;
      editor
        ..test = error != null ? _TestState.failed : _TestState.passed
        ..testText = error != null
            ? personalConnectionProbeText(l10n, error)
            : result.operationCount != null
            ? l10n.personalConnectionsTestOk(result.operationCount!)
            : l10n.personalConnectionsTestOkTerminal;
    } catch (error) {
      if (!identical(_editors[editor.key], editor) ||
          editor.revision != revision) {
        return;
      }
      // Categorized, so nothing from the host or the stored key is shown.
      editor
        ..test = _TestState.failed
        ..testText = personalConnectionSaveError(l10n, error);
    }
    await _applyEditor(l10n, editor);
  }

  Future<void> _delete(AppLocalizations l10n, _ConnectionEditor editor) async {
    final owner = _owner(editor);
    final existing = editor.existing;
    if (owner == null || existing == null || editor.busy) return;
    editor
      ..deleting = true
      ..message = null;
    await _applyEditor(l10n, editor);
    try {
      final outcome = await _controller.save(
        owner,
        editor.kind,
        RemovePersonalConnection(existing.identity),
      );
      if (!identical(_editors[editor.key], editor)) return;
      if (outcome.stale) {
        editor
          ..message = l10n.personalConnectionsSavedForPreviousAccount
          ..messageIsError = false;
      } else {
        _editors.remove(editor.key)?.forget();
        await _surface.closeDetail(
          '$personalConnectionEditorPagePrefix${editor.key}',
        );
        return;
      }
    } catch (error) {
      if (!identical(_editors[editor.key], editor)) return;
      editor
        ..message = personalConnectionSaveError(l10n, error)
        ..messageIsError = true;
    } finally {
      editor.deleting = false;
    }
    await _applyEditor(l10n, editor);
  }

  /// Switches an entry the form cannot edit, without touching its fields.
  Future<void> _setEnabledNow(
    AppLocalizations l10n,
    _ConnectionEditor editor,
    bool value,
  ) async {
    final owner = _owner(editor);
    final existing = editor.existing;
    if (owner == null || existing == null || editor.pendingEnabled != null) {
      return;
    }
    editor
      ..pendingEnabled = value
      ..message = null;
    await _applyEditor(l10n, editor);
    try {
      final outcome = await _controller.save(
        owner,
        editor.kind,
        SetPersonalConnectionEnabled(existing.identity, value),
      );
      if (!identical(_editors[editor.key], editor)) return;
      if (outcome.stale) {
        editor
          ..message = l10n.personalConnectionsSavedForPreviousAccount
          ..messageIsError = false;
      }
    } catch (error) {
      if (!identical(_editors[editor.key], editor)) return;
      editor
        ..message = personalConnectionSaveError(l10n, error)
        ..messageIsError = true;
    } finally {
      editor.pendingEnabled = null;
    }
    await _applyEditor(l10n, editor);
  }

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    if (!id.startsWith(personalConnectionRowPrefix)) return false;
    _l10n = l10n;
    final parts = id.substring(personalConnectionRowPrefix.length).split(':');
    if (parts.length < 2) return true;
    final field = parts[0];
    final key = parts[1];
    final extra = parts.length > 2 ? Uri.decodeComponent(parts[2]) : null;
    if (key == personalConnectionsListKey) {
      switch (field) {
        case 'retry':
          _ref.invalidate(personalConnectionsProvider);
        case 'cleared-ok':
          _ref.read(personalSelectionNoticeProvider.notifier).clear();
      }
      return true;
    }
    if (field == 'enabled' && extra != null) {
      await _setEnabledFromList(l10n, key, extra == 'on');
      return true;
    }
    final editor = _editors[key];
    if (editor == null) return true;
    if (field == 'retry') {
      _ref.invalidate(personalConnectionsProvider);
      return true;
    }
    // Text typed while a request runs is kept as the form's; the request
    // acts on what was sent.
    final shown =
        editor.attempted ||
        editor.test != _TestState.idle ||
        editor.message != null;
    switch (field) {
      case 'name' when value is String:
        editor.name = value;
      case 'description' when value is String:
        editor.description = value;
      case 'url' when value is String:
        editor.url = value;
      case 'path' when value is String:
        editor.path = value;
      case 'spec' when value is String:
        editor.spec = value;
      case 'key' when value is String:
        editor
          ..keyText = value
          ..keyMode = value.isEmpty && !editor.isNew
              ? PersonalConnectionSecretMode.keep
              : PersonalConnectionSecretMode.replace;
      case 'enabled' when value is bool:
        editor.enabled = value;
      case 'auth' when value is String:
        editor
          ..authType = value
          ..changed();
        await _applyEditor(l10n, editor);
        return true;
      case 'spec-source' when value is String:
        editor
          ..specType = value
          ..changed();
        await _applyEditor(l10n, editor);
        return true;
      case 'key-mode':
        final removing = editor.keyMode == PersonalConnectionSecretMode.clear;
        editor
          ..keyText = ''
          ..keyMode = removing
              ? PersonalConnectionSecretMode.keep
              : PersonalConnectionSecretMode.clear
          ..changed();
        await _applyEditor(l10n, editor);
        return true;
      case 'enabled-now' when value is bool:
        await _setEnabledNow(l10n, editor, value);
        return true;
      case 'test':
        await _test(l10n, editor);
        return true;
      case 'save':
        await _save(l10n, editor);
        return true;
      case 'delete':
        await _delete(l10n, editor);
        return true;
      default:
        return true;
    }
    editor.changed();
    // An issue, test result or message on show follows the text.
    if (shown) await _applyEditor(l10n, editor);
    return true;
  }
}
