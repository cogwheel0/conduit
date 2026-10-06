import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import 'package:conduit_core/features/integrations/personal_connection_drafts.dart';
import 'package:conduit_core/features/integrations/personal_connection_edits.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import 'personal_connection_messages.dart';

/// Form for one personal tool server or terminal.
///
/// The entry is named by identity, not by list position, so the form keeps
/// editing the same connection if the list is reordered while it is open. A
/// stored key is never loaded into the form; it stays as saved unless the user
/// types a new one or removes it.
///
/// The form belongs to the account that was signed in when it opened. Save,
/// Test, delete and the enable switch all act for that account, or not at all:
/// once another account is active they send nothing, and the form keeps what
/// the user typed instead of reloading it from the new account's list.
class PersonalConnectionEditorPage extends ConsumerStatefulWidget {
  const PersonalConnectionEditorPage({
    super.key,
    required this.kind,
    required this.identity,
  });

  final PersonalConnectionKind kind;

  /// Identity of the connection, or [personalConnectionNewRouteValue].
  final String identity;

  @override
  ConsumerState<PersonalConnectionEditorPage> createState() =>
      _PersonalConnectionEditorPageState();
}

class _PersonalConnectionEditorPageState
    extends ConsumerState<PersonalConnectionEditorPage> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _url = TextEditingController();
  final _path = TextEditingController();
  final _spec = TextEditingController();
  final _key = TextEditingController();
  // Identity given to a tool server that has none: the reference editor keeps
  // it under `info.id`, so it survives edits made in the Open WebUI client.
  final _stampKey = 'conduit-${const Uuid().v4().replaceAll('-', '')}';

  // The account this form opened under. Fixed when the form opens, before any
  // list is loaded, so an account that signs in while the load is pending can
  // neither fill the form nor be mistaken for its owner.
  PersonalConnectionsSession? _owner;
  PersonalConnectionEntry? _existing;
  bool _initialized = false;
  bool _enabled = true;
  String _authType = 'bearer';
  String _specType = 'url';
  PersonalConnectionSecretMode _keyMode = PersonalConnectionSecretMode.replace;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  bool get _isNew => widget.identity == personalConnectionNewRouteValue;
  bool get _isTool => widget.kind == PersonalConnectionKind.toolServer;

  bool get _hasStoredKey =>
      (_existing?.raw['key']?.toString() ?? '').trim().isNotEmpty;

  /// The account that opened this form no longer is the active one.
  bool get _ownerChanged {
    final owner = _owner;
    return owner != null && !owner.isCurrent();
  }

  @override
  void initState() {
    super.initState();
    _owner = ref.read(personalConnectionsSessionProvider);
  }

  @override
  void didUpdateWidget(covariant PersonalConnectionEditorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity ||
        oldWidget.kind != widget.kind) {
      _initialized = false;
      _existing = null;
      _owner = ref.read(personalConnectionsSessionProvider);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _url.dispose();
    _path.dispose();
    _spec.dispose();
    _key.dispose();
    super.dispose();
  }

  void _initialize(PersonalConnectionsSnapshot snapshot) {
    if (_initialized) {
      // Follow the entry through list changes so Save patches the right one,
      // but only within the account that opened the form: another account's
      // list says nothing about the entry this form is editing.
      if (_ownerChanged) return;
      final current = snapshot.find(widget.kind, widget.identity);
      if (current != null) _existing = current;
      return;
    }
    _initialized = true;
    if (_isNew) {
      if (_isTool) {
        const draft = PersonalToolServerDraft();
        _path.text = draft.path;
        _authType = draft.authType;
        _specType = draft.specType;
      } else {
        _path.text = const PersonalTerminalDraft().path;
      }
      return;
    }
    _existing = snapshot.find(widget.kind, widget.identity);
    final entry = _existing;
    if (entry == null) return;
    _keyMode = PersonalConnectionSecretMode.keep;
    if (_isTool) {
      final draft = PersonalToolServerDraft.fromEntry(entry.raw);
      _name.text = draft.name;
      _description.text = draft.description;
      _url.text = draft.url;
      _path.text = draft.path;
      _spec.text = draft.spec;
      _authType = draft.authType;
      _specType = draft.specType;
      _enabled = draft.enabled;
    } else {
      final draft = PersonalTerminalDraft.fromEntry(entry.raw);
      _name.text = draft.name;
      _url.text = draft.url;
      _path.text = draft.path;
      _enabled = draft.enabled;
    }
  }

  PersonalToolServerDraft _toolDraft() => PersonalToolServerDraft(
    name: _name.text,
    description: _description.text,
    url: _url.text,
    specType: _specType,
    path: _path.text,
    spec: _spec.text,
    authType: _authType,
    key: _key.text,
    keyMode: _keyMode,
    enabled: _enabled,
  );

  PersonalTerminalDraft _terminalDraft() => PersonalTerminalDraft(
    name: _name.text,
    url: _url.text,
    path: _path.text,
    key: _key.text,
    keyMode: _keyMode,
    enabled: _enabled,
  );

  PersonalConnectionDraftIssue? _validate() =>
      _isTool ? _toolDraft().validate() : _terminalDraft().validate();

  Map<String, dynamic> _patch(Map<String, dynamic> previous) => _isTool
      ? _toolDraft().toPatch(previous)
      : _terminalDraft().toPatch(previous);

  Map<String, dynamic> _newEntry() => _isTool
      ? _toolDraft().toNewEntry(id: _stampKey)
      : _terminalDraft().toNewEntry();

  void _show(String text, {bool error = false}) => setState(() {
    _message = text;
    _messageIsError = error;
  });

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final owner = _owner;
    if (owner == null) return;
    final issue = _validate();
    if (issue != null) {
      _show(personalConnectionIssueText(l10n, issue), error: true);
      return;
    }
    final PersonalConnectionEdit edit;
    final existing = _existing;
    if (_isNew) {
      edit = AddPersonalConnection(_newEntry());
    } else if (existing != null) {
      final patch = _patch(existing.raw);
      if (patch.isEmpty) {
        context.pop();
        return;
      }
      edit = PatchPersonalConnection(
        existing.identity,
        patch,
        stampKey: _isTool ? _stampKey : null,
      );
    } else {
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final outcome = await ref
          .read(personalConnectionsProvider.notifier)
          .save(owner, widget.kind, edit);
      if (!mounted) return;
      if (outcome.stale) {
        // The write reached the account that opened the form, and nothing for
        // the account signed in now. The form stays to say so.
        _show(l10n.personalConnectionsSavedForPreviousAccount);
      } else {
        context.pop();
      }
    } catch (error) {
      if (mounted) {
        _show(personalConnectionSaveError(l10n, error), error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    final l10n = AppLocalizations.of(context)!;
    final owner = _owner;
    if (owner == null) return;
    final issue = _validate();
    if (issue != null) {
      _show(personalConnectionIssueText(l10n, issue), error: true);
      return;
    }
    final existing = _existing;
    final entry = existing == null
        ? _newEntry()
        : mergePersonalConnectionPatch(existing.raw, _patch(existing.raw));
    setState(() {
      _busy = true;
      _message = null;
    });
    final PersonalConnectionTestResult result;
    try {
      result = await ref
          .read(personalConnectionsProvider.notifier)
          .testConnection(owner, widget.kind, entry);
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        _show(personalConnectionSaveError(l10n, error), error: true);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final error = result.error;
    if (error != null) {
      _show(personalConnectionProbeText(l10n, error), error: true);
    } else if (result.operationCount != null) {
      _show(l10n.personalConnectionsTestOk(result.operationCount!));
    } else {
      _show(l10n.personalConnectionsTestOkTerminal);
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final owner = _owner;
    final existing = _existing;
    if (owner == null || existing == null) return;
    // The confirmation can stay open while the account changes. Both the entry
    // and the owner were fixed before it, so the answer applies to them or to
    // nothing.
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.personalConnectionsDeleteTitle,
      message: l10n.personalConnectionsDeleteMessage(existing.displayName),
      confirmText: l10n.delete,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final outcome = await ref
          .read(personalConnectionsProvider.notifier)
          .save(
            owner,
            widget.kind,
            RemovePersonalConnection(existing.identity),
          );
      if (!mounted) return;
      if (outcome.stale) {
        _show(l10n.personalConnectionsSavedForPreviousAccount);
      } else {
        context.pop();
      }
    } catch (error) {
      if (mounted) {
        _show(personalConnectionSaveError(l10n, error), error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Switches an entry the form cannot edit, without touching its fields.
  Future<void> _toggleReadOnly(bool value) async {
    final l10n = AppLocalizations.of(context)!;
    final owner = _owner;
    final existing = _existing;
    if (owner == null || existing == null) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(personalConnectionsProvider.notifier)
          .save(
            owner,
            widget.kind,
            SetPersonalConnectionEnabled(existing.identity, value),
          );
    } catch (error) {
      if (mounted) {
        UiUtils.showMessage(
          context,
          personalConnectionSaveError(l10n, error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = _isNew
        ? (_isTool
              ? l10n.personalConnectionsAddToolServer
              : l10n.personalConnectionsAddTerminal)
        : (_isTool
              ? l10n.personalConnectionsEditToolServer
              : l10n.personalConnectionsEditTerminal);
    // Rebuild when the account changes, so a form left open notices it. A form
    // that opened with no account to claim takes the first one that appears,
    // before its list can have loaded.
    final session = ref.watch(personalConnectionsSessionProvider);
    if (!_initialized) _owner ??= session;
    if (_ownerChanged) {
      if (_initialized) {
        // Whatever is signed in now, the form stays as typed. It belongs to
        // the account that opened it, and its actions refuse to run for
        // another.
        return _form(l10n, title, _owner!, ownerChanged: true);
      }
      // The account changed before the list arrived, so there is nothing of
      // theirs to keep and nothing of the new account's to show in their form.
      return UtilityPageScaffold.settings(
        title: title,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              l10n.personalConnectionsOwnerChanged,
              key: const Key('personal-connection-owner-changed'),
              style: TextStyle(color: context.conduitTheme.error),
            ),
          ),
        ],
      );
    }
    final access = ref.watch(personalConnectionsAccessProvider);
    if (access.block case final block?) {
      return UtilityPageScaffold.settings(
        title: title,
        children: [Text(personalConnectionsBlockText(l10n, block))],
      );
    }
    final connections = ref.watch(personalConnectionsProvider);
    return connections.when(
      loading: () => UtilityPageScaffold.settings(
        title: title,
        children: const [Center(child: CircularProgressIndicator.adaptive())],
      ),
      error: (_, _) => UtilityPageScaffold.settings(
        title: title,
        children: [Text(l10n.personalConnectionsLoadFailed)],
      ),
      data: (snapshot) {
        if (snapshot == null) {
          return UtilityPageScaffold.settings(
            title: title,
            children: const [
              Center(child: CircularProgressIndicator.adaptive()),
            ],
          );
        }
        _initialize(snapshot);
        if (!_isNew && _existing == null) {
          return UtilityPageScaffold.settings(
            title: title,
            children: [Text(l10n.personalConnectionsNotFound)],
          );
        }
        return _form(l10n, title, snapshot.session);
      },
    );
  }

  Widget _form(
    AppLocalizations l10n,
    String title,
    PersonalConnectionsSession owner, {
    bool ownerChanged = false,
  }) {
    final readOnly = _existing != null && !_existing!.editable;
    return UtilityPageScaffold.settings(
      title: title,
      children: [
        Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.personalConnectionsStoredOn(
                  owner.accountName,
                  owner.api.serverConfig.name,
                ),
              ),
              if (ownerChanged) ...[
                const SizedBox(height: Spacing.sm),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n.personalConnectionsOwnerChanged,
                    key: const Key('personal-connection-owner-changed'),
                    style: TextStyle(color: context.conduitTheme.error),
                  ),
                ),
              ],
              const SizedBox(height: Spacing.md),
              if (readOnly) ..._readOnlyFields(l10n) else ..._fields(l10n),
              if (_message != null) ...[
                const SizedBox(height: Spacing.sm),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _message!,
                    key: const Key('personal-connection-message'),
                    style: TextStyle(
                      color: _messageIsError
                          ? context.conduitTheme.error
                          : context.conduitTheme.textPrimary,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: Spacing.md),
              if (!readOnly) ...[
                ConduitButton(
                  key: const Key('personal-connection-test'),
                  text: l10n.personalConnectionsTestConnection,
                  isSecondary: true,
                  isLoading: _busy,
                  onPressed: _busy ? null : _test,
                ),
                const SizedBox(height: Spacing.sm),
                ConduitButton(
                  key: const Key('personal-connection-save'),
                  text: l10n.save,
                  isLoading: _busy,
                  onPressed: _busy ? null : _save,
                ),
              ],
              if (!_isNew) ...[
                const SizedBox(height: Spacing.sm),
                ConduitButton(
                  key: const Key('personal-connection-delete'),
                  text: l10n.delete,
                  isDestructive: true,
                  onPressed: _busy ? null : _delete,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _readOnlyFields(AppLocalizations l10n) => [
    Text(_existing!.displayName),
    const SizedBox(height: Spacing.xs),
    Text(_existing!.url),
    const SizedBox(height: Spacing.sm),
    Text(
      l10n.personalConnectionsUnsupported,
      key: const Key('personal-connection-unsupported'),
    ),
    SwitchListTile.adaptive(
      key: const Key('personal-connection-enabled'),
      contentPadding: EdgeInsets.zero,
      title: Text(l10n.enabledLabel),
      value: _existing!.enabled,
      onChanged: _busy ? null : _toggleReadOnly,
    ),
  ];

  List<Widget> _fields(AppLocalizations l10n) {
    final showKey = !_isTool || _authType == 'bearer';
    return [
      TextField(
        key: const Key('personal-connection-name'),
        controller: _name,
        enabled: !_busy,
        decoration: InputDecoration(labelText: l10n.name),
      ),
      const SizedBox(height: Spacing.sm),
      if (_isTool) ...[
        TextField(
          key: const Key('personal-connection-description'),
          controller: _description,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: l10n.personalConnectionsDescriptionField,
          ),
        ),
        const SizedBox(height: Spacing.sm),
      ],
      TextField(
        key: const Key('personal-connection-url'),
        controller: _url,
        enabled: !_busy,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(labelText: l10n.personalConnectionsUrl),
      ),
      const SizedBox(height: Spacing.sm),
      if (_isTool) ...[
        DropdownButtonFormField<String>(
          key: ValueKey('personal-connection-auth-$_authType'),
          initialValue: _authType,
          decoration: InputDecoration(labelText: l10n.personalConnectionsAuth),
          items: [
            DropdownMenuItem(
              value: 'bearer',
              child: Text(l10n.directMcpAuthBearer),
            ),
            DropdownMenuItem(
              value: 'none',
              child: Text(l10n.directMcpAuthNone),
            ),
          ],
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null) setState(() => _authType = value);
                },
        ),
        const SizedBox(height: Spacing.sm),
      ],
      if (showKey) ...[..._keyField(l10n), const SizedBox(height: Spacing.sm)],
      if (_isTool) ...[
        DropdownButtonFormField<String>(
          key: ValueKey('personal-connection-spec-$_specType'),
          initialValue: _specType,
          decoration: InputDecoration(
            labelText: l10n.personalConnectionsSpecSource,
          ),
          items: [
            DropdownMenuItem(
              value: 'url',
              child: Text(l10n.personalConnectionsSpecFromUrl),
            ),
            DropdownMenuItem(
              value: 'json',
              child: Text(l10n.personalConnectionsSpecInline),
            ),
          ],
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null) setState(() => _specType = value);
                },
        ),
        const SizedBox(height: Spacing.sm),
      ],
      if (!_isTool || _specType == 'url')
        TextField(
          key: const Key('personal-connection-path'),
          controller: _path,
          enabled: !_busy,
          autocorrect: false,
          decoration: InputDecoration(labelText: l10n.personalConnectionsPath),
        )
      else
        TextField(
          key: const Key('personal-connection-spec'),
          controller: _spec,
          enabled: !_busy,
          minLines: 4,
          maxLines: 10,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: l10n.personalConnectionsSpecJson,
          ),
        ),
      SwitchListTile.adaptive(
        key: const Key('personal-connection-enabled'),
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.enabledLabel),
        subtitle: _isTool
            ? null
            : Text(l10n.personalConnectionsTerminalOneActive),
        value: _enabled,
        onChanged: _busy ? null : (value) => setState(() => _enabled = value),
      ),
    ];
  }

  List<Widget> _keyField(AppLocalizations l10n) {
    final removing = _keyMode == PersonalConnectionSecretMode.clear;
    final keeping =
        _keyMode == PersonalConnectionSecretMode.keep && _hasStoredKey;
    return [
      TextField(
        key: const Key('personal-connection-key'),
        controller: _key,
        enabled: !_busy && !removing,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: l10n.apiKey,
          helperText: removing
              ? l10n.personalConnectionsKeyWillRemove
              : keeping
              ? l10n.personalConnectionsKeyKept
              : null,
        ),
        onChanged: (value) {
          setState(() {
            _keyMode = value.isEmpty && !_isNew
                ? PersonalConnectionSecretMode.keep
                : PersonalConnectionSecretMode.replace;
          });
        },
      ),
      if (_hasStoredKey) ...[
        const SizedBox(height: Spacing.xs),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const Key('personal-connection-key-toggle'),
            onPressed: _busy
                ? null
                : () => setState(() {
                    _key.clear();
                    _keyMode = removing
                        ? PersonalConnectionSecretMode.keep
                        : PersonalConnectionSecretMode.clear;
                  }),
            child: Text(
              removing
                  ? l10n.personalConnectionsKeyKeep
                  : l10n.personalConnectionsKeyRemove,
            ),
          ),
        ),
      ],
    ];
  }
}
