import 'dart:async';

import 'package:collection/collection.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/integrations/personal_connection_drafts.dart';
import 'package:conduit_core/features/integrations/personal_connection_edits.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_dropdown_field.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/discard_changes.dart';
import '../../../shared/widgets/editor_form_widgets.dart';
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

  // The entry as the server last listed it: its identity and whether the form
  // can edit it follow later reads of the list.
  PersonalConnectionEntry? _existing;

  // The entry as it was when the fields were filled from it. The fields are
  // this plus what the user typed, so Save compares them to this and sends only
  // what the user changed. Another client's later edit to a field the user left
  // alone is then kept, not written back to its opening value.
  Map<String, dynamic>? _opened;

  // Every field as the form was filled, to tell whether anything was typed.
  List<Object?>? _start;
  bool _initialized = false;
  bool _enabled = true;
  String _authType = 'bearer';
  String _specType = 'url';
  PersonalConnectionSecretMode _keyMode = PersonalConnectionSecretMode.replace;
  bool _showKey = false;

  bool _saving = false;
  bool _testing = false;
  bool _deleting = false;

  /// The state the read-only entry's switch was moved to, until the server
  /// answers.
  bool? _pendingEnabled;
  ConnectionAttemptState _attempt = const ConnectionAttemptState.idle();

  /// Set by the first Save or Test. From then on each field shows its own
  /// issue, and updates as the user types.
  bool _attempted = false;

  /// Set once a save or delete went through, so leaving does not ask about
  /// discarding.
  bool _saved = false;
  String? _message;
  bool _messageIsError = false;

  bool get _isNew => widget.identity == personalConnectionNewRouteValue;
  bool get _isTool => widget.kind == PersonalConnectionKind.toolServer;
  bool get _busy => _saving || _testing || _deleting;

  bool get _hasStoredKey =>
      (_existing?.raw['key']?.toString() ?? '').trim().isNotEmpty;

  bool get _readOnly => _existing != null && !_existing!.editable;

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
      _opened = null;
      _start = null;
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
      _start = _values();
      return;
    }
    _existing = snapshot.find(widget.kind, widget.identity);
    final entry = _existing;
    if (entry == null) {
      // Nothing to fill the fields from yet. Wait for the entry to be listed,
      // rather than showing it later with empty fields that Save would write.
      _initialized = false;
      return;
    }
    _opened = entry.raw;
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
    _start = _values();
  }

  List<Object?> _values() => [
    _name.text,
    _description.text,
    _url.text,
    _path.text,
    _spec.text,
    _key.text,
    _keyMode,
    _authType,
    _specType,
    _enabled,
  ];

  /// Whether leaving now would lose something the user entered.
  bool get _dirty {
    final start = _start;
    if (start == null || _saved || _readOnly) return false;
    return !const ListEquality<Object?>().equals(start, _values());
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

  /// Each field's own issue once the user has tried to save or test.
  ///
  /// The draft reports only its first issue, so the URL is checked with a
  /// stand-in path and the path or document with a stand-in URL: each field
  /// then shows its own problem whatever the other holds.
  ({String? url, String? path, String? spec}) _fieldErrors(
    AppLocalizations l10n,
  ) {
    if (!_attempted) return (url: null, path: null, spec: null);
    const validUrl = 'https://example.com';
    final PersonalConnectionDraftIssue? urlIssue;
    final PersonalConnectionDraftIssue? restIssue;
    if (_isTool) {
      final draft = _toolDraft();
      urlIssue = draft
          .copyWith(specType: 'url', path: 'openapi.json')
          .validate();
      restIssue = draft.copyWith(url: validUrl).validate();
    } else {
      final draft = _terminalDraft();
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

  Map<String, dynamic> _patch(Map<String, dynamic> previous) => _isTool
      ? _toolDraft().toPatch(previous)
      : _terminalDraft().toPatch(previous);

  Map<String, dynamic> _newEntry() => _isTool
      ? _toolDraft().toNewEntry(id: _stampKey)
      : _terminalDraft().toNewEntry();

  /// Any edit makes an earlier test result and message out of date.
  void _fieldChanged([Object? _]) => setState(() {
    _attempt = const ConnectionAttemptState.idle();
    _message = null;
  });

  void _show(String text, {bool error = false}) => setState(() {
    _message = text;
    _messageIsError = error;
  });

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final owner = _owner;
    if (owner == null || _busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_validate() != null) {
      setState(() => _attempted = true);
      return;
    }
    final PersonalConnectionEdit edit;
    final existing = _existing;
    final opened = _opened;
    if (_isNew) {
      edit = AddPersonalConnection(_newEntry());
    } else if (existing != null && opened != null) {
      final patch = _patch(opened);
      if (patch.isEmpty) {
        setState(() => _saved = true);
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
      _attempted = true;
      _saving = true;
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
        setState(() => _saved = true);
        // A pressed ConduitButton already gave its own feedback; the iOS
        // toolbar button gives none, so the save is confirmed there.
        if (PlatformInfo.isIOS) unawaited(ConduitHaptics.success());
        context.pop();
      }
    } catch (error) {
      if (mounted) {
        _show(personalConnectionSaveError(l10n, error), error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    final l10n = AppLocalizations.of(context)!;
    final owner = _owner;
    if (owner == null || _busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_validate() != null) {
      setState(() {
        _attempted = true;
        _attempt = const ConnectionAttemptState.idle();
      });
      return;
    }
    final existing = _existing;
    final opened = _opened;
    final entry = existing == null || opened == null
        ? _newEntry()
        : mergePersonalConnectionPatch(existing.raw, _patch(opened));
    setState(() {
      _attempted = true;
      _testing = true;
      _message = null;
      _attempt = ConnectionAttemptState.connecting(l10n.connecting);
    });
    final PersonalConnectionTestResult result;
    try {
      result = await ref
          .read(personalConnectionsProvider.notifier)
          .testConnection(owner, widget.kind, entry);
    } catch (error) {
      if (mounted) {
        setState(() {
          _testing = false;
          // Categorized, so nothing from the host or the stored key is shown.
          _attempt = ConnectionAttemptState.failed(
            personalConnectionSaveError(l10n, error),
          );
        });
      }
      return;
    }
    if (!mounted) return;
    final error = result.error;
    setState(() {
      _testing = false;
      _attempt = error != null
          ? ConnectionAttemptState.failed(
              personalConnectionProbeText(l10n, error),
            )
          : ConnectionAttemptState.connected(
              result.operationCount != null
                  ? l10n.personalConnectionsTestOk(result.operationCount!)
                  : l10n.personalConnectionsTestOkTerminal,
            );
    });
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final owner = _owner;
    final existing = _existing;
    if (owner == null || existing == null || _busy) return;
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
      _deleting = true;
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
        setState(() => _saved = true);
        context.pop();
      }
    } catch (error) {
      if (mounted) {
        _show(personalConnectionSaveError(l10n, error), error: true);
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  /// Switches an entry the form cannot edit, without touching its fields. The
  /// switch moves at once and goes back if the server refuses.
  Future<void> _toggleReadOnly(bool value) async {
    final l10n = AppLocalizations.of(context)!;
    final owner = _owner;
    final existing = _existing;
    if (owner == null || existing == null || _pendingEnabled != null) return;
    setState(() => _pendingEnabled = value);
    try {
      final outcome = await ref
          .read(personalConnectionsProvider.notifier)
          .save(
            owner,
            widget.kind,
            SetPersonalConnectionEnabled(existing.identity, value),
          );
      if (!mounted) return;
      if (outcome.stale) {
        _show(l10n.personalConnectionsSavedForPreviousAccount);
      } else if (PlatformInfo.isIOS) {
        // Android's switch already clicked when it moved.
        unawaited(ConduitHaptics.success());
      }
    } catch (error) {
      if (mounted) {
        UiUtils.showMessage(
          context,
          personalConnectionSaveError(l10n, error),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _pendingEnabled = null);
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
        children: [_ownerChangedBanner(l10n)],
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
        children: const [
          Center(child: ConduitLoadingIndicator(isCompact: true)),
        ],
      ),
      error: (_, _) => UtilityPageScaffold.settings(
        title: title,
        children: [
          Text(l10n.personalConnectionsLoadFailed),
          const SizedBox(height: Spacing.md),
          ConduitButton(
            key: const Key('personal-connection-retry'),
            text: l10n.retry,
            onPressed: () => ref.invalidate(personalConnectionsProvider),
          ),
        ],
      ),
      data: (snapshot) {
        if (snapshot == null) {
          return UtilityPageScaffold.settings(
            title: title,
            children: const [
              Center(child: ConduitLoadingIndicator(isCompact: true)),
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

  Widget _ownerChangedBanner(AppLocalizations l10n) => UtilityStatusBanner(
    key: const Key('personal-connection-owner-changed'),
    message: l10n.personalConnectionsOwnerChanged,
    tone: UtilityStatusTone.warning,
  );

  Widget _form(
    AppLocalizations l10n,
    String title,
    PersonalConnectionsSession owner, {
    bool ownerChanged = false,
  }) {
    final readOnly = _readOnly;
    final storedOn = l10n.personalConnectionsStoredOn(
      owner.accountName,
      owner.api.serverConfig.name,
    );
    return DiscardChangesScope(
      dirty: _dirty,
      child: UtilityPageScaffold.settings(
        title: title,
        trailing: PlatformInfo.isIOS && !readOnly
            ? CupertinoButton(
                key: const Key('personal-connection-save'),
                padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                minimumSize: const Size(0, TouchTarget.minimum),
                onPressed: _busy ? null : _save,
                child: _saving
                    ? const ConduitLoadingIndicator(
                        size: IconSize.small,
                        isCompact: true,
                      )
                    : Text(l10n.save),
              )
            : null,
        children: [
          if (ownerChanged) ...[
            _ownerChangedBanner(l10n),
            const SizedBox(height: Spacing.md),
          ],
          if (readOnly)
            ..._readOnlyFields(l10n, storedOn)
          else
            ..._fields(l10n, storedOn),
          if (_message case final message?) ...[
            const SizedBox(height: Spacing.md),
            UtilityStatusBanner(
              key: const Key('personal-connection-message'),
              message: message,
              tone: _messageIsError
                  ? UtilityStatusTone.error
                  : UtilityStatusTone.info,
            ),
          ],
          if (!readOnly) ...[
            const SizedBox(height: Spacing.lg),
            ..._actions(l10n),
          ],
          if (!_isNew) ...[
            const SizedBox(height: Spacing.xl),
            _deleteControl(l10n),
          ],
        ],
      ),
    );
  }

  List<Widget> _actions(AppLocalizations l10n) {
    if (PlatformInfo.isIOS) {
      return [
        InsetGroupedList(
          useNativeSurface: true,
          children: [
            UtilityRow(
              key: const Key('personal-connection-test'),
              title: l10n.personalConnectionsTestConnection,
              titleFontWeight: FontWeight.w400,
              foregroundColor: context.conduitTheme.buttonPrimary,
              enabled: !_saving && !_deleting,
              status: _testing ? const _Spinner() : null,
              onTap: _busy ? null : _test,
            ),
          ],
        ),
        if (_attempt.isVisible) ...[
          const SizedBox(height: Spacing.sm),
          ConnectionAttemptBanner(state: _attempt),
        ],
      ];
    }
    return [
      Wrap(
        spacing: Spacing.md,
        runSpacing: Spacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConduitButton(
            key: const Key('personal-connection-save'),
            text: l10n.save,
            isLoading: _saving,
            onPressed: _testing || _deleting ? null : _save,
          ),
          ConduitButton(
            key: const Key('personal-connection-test'),
            text: l10n.personalConnectionsTestConnection,
            isSecondary: true,
            isLoading: _testing,
            onPressed: _saving || _deleting ? null : _test,
          ),
        ],
      ),
      if (_attempt.isVisible) ...[
        const SizedBox(height: Spacing.sm),
        ConnectionAttemptBanner(state: _attempt),
      ],
    ];
  }

  Widget _deleteControl(AppLocalizations l10n) {
    if (PlatformInfo.isIOS) {
      return InsetGroupedList(
        useNativeSurface: true,
        children: [
          UtilityRow(
            key: const Key('personal-connection-delete'),
            title: l10n.delete,
            titleFontWeight: FontWeight.w400,
            destructive: true,
            enabled: !_saving && !_testing,
            status: _deleting ? const _Spinner() : null,
            onTap: _busy ? null : _delete,
          ),
        ],
      );
    }
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConduitButton(
        key: const Key('personal-connection-delete'),
        text: l10n.delete,
        isDestructive: true,
        isLoading: _deleting,
        onPressed: _saving || _testing ? null : _delete,
      ),
    );
  }

  List<Widget> _readOnlyFields(AppLocalizations l10n, String storedOn) {
    final existing = _existing!;
    final pending = _pendingEnabled;
    return [
      UtilityStatusBanner(
        key: const Key('personal-connection-unsupported'),
        message: l10n.personalConnectionsUnsupported,
        tone: UtilityStatusTone.info,
      ),
      const SizedBox(height: Spacing.md),
      InsetGroupedList(
        useNativeSurface: PlatformInfo.isIOS,
        footer: storedOn,
        children: [
          UtilityRow(
            title: l10n.enabledLabel,
            titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
            status: pending == null ? null : const _Spinner(),
            trailing: AdaptiveSwitch(
              key: const Key('personal-connection-enabled'),
              value: pending ?? existing.enabled,
              semanticLabel: l10n.enabledLabel,
              onChanged: pending != null || _deleting ? null : _toggleReadOnly,
            ),
            preserveTrailingSemantics: true,
          ),
          UtilityValueRow(label: l10n.name, value: existing.displayName),
          UtilityValueRow(
            label: l10n.personalConnectionsUrl,
            value: personalConnectionPublicEndpoint(existing.url),
          ),
        ],
      ),
    ];
  }

  List<Widget> _fields(AppLocalizations l10n, String storedOn) {
    final native = PlatformInfo.isIOS;
    final theme = context.conduitTheme;
    final errors = _fieldErrors(l10n);
    final showKey = !_isTool || _authType == 'bearer';
    return [
      InsetGroupedList(
        useNativeSurface: native,
        footer: _isTool ? null : l10n.personalConnectionsTerminalOneActive,
        children: [
          UtilityRow(
            title: l10n.enabledLabel,
            titleFontWeight: native ? FontWeight.w400 : null,
            trailing: AdaptiveSwitch(
              key: const Key('personal-connection-enabled'),
              value: _enabled,
              semanticLabel: l10n.enabledLabel,
              onChanged: _busy
                  ? null
                  : (value) {
                      _enabled = value;
                      _fieldChanged();
                    },
            ),
            preserveTrailingSemantics: true,
          ),
          editorGroupField(
            AccessibleFormField(
              key: const Key('personal-connection-name'),
              controller: _name,
              label: l10n.name,
              enabled: !_busy,
              iosSettingsRow: native,
              textInputAction: TextInputAction.next,
              onChanged: _fieldChanged,
            ),
          ),
          if (_isTool)
            editorGroupField(
              AccessibleFormField(
                key: const Key('personal-connection-description'),
                controller: _description,
                label: l10n.personalConnectionsDescriptionField,
                enabled: !_busy,
                iosSettingsRow: native,
                textInputAction: TextInputAction.next,
                onChanged: _fieldChanged,
              ),
            ),
        ],
      ),
      SizedBox(height: native ? Spacing.md : Spacing.lg),
      InsetGroupedList(
        useNativeSurface: native,
        footer: storedOn,
        children: [
          editorGroupField(
            AccessibleFormField(
              key: const Key('personal-connection-url'),
              controller: _url,
              label: l10n.personalConnectionsUrl,
              hint: 'https://',
              enabled: !_busy,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              isRequired: true,
              errorText: errors.url,
              iosSettingsRow: native,
              onChanged: _fieldChanged,
            ),
          ),
          if (_isTool)
            _choice<String>(
              key: ValueKey('personal-connection-auth-$_authType'),
              label: l10n.personalConnectionsAuth,
              value: _authType,
              options: [
                AdaptiveDropdownOption(
                  value: 'bearer',
                  label: l10n.directMcpAuthBearer,
                ),
                AdaptiveDropdownOption(
                  value: 'none',
                  label: l10n.directMcpAuthNone,
                ),
              ],
              onChanged: (value) {
                _authType = value;
                _fieldChanged();
              },
            ),
          if (showKey) ..._keyRows(l10n, theme),
        ],
      ),
      SizedBox(height: native ? Spacing.md : Spacing.lg),
      InsetGroupedList(
        useNativeSurface: native,
        children: [
          if (_isTool)
            _choice<String>(
              key: ValueKey('personal-connection-spec-$_specType'),
              label: l10n.personalConnectionsSpecSource,
              value: _specType,
              options: [
                AdaptiveDropdownOption(
                  value: 'url',
                  label: l10n.personalConnectionsSpecFromUrl,
                ),
                AdaptiveDropdownOption(
                  value: 'json',
                  label: l10n.personalConnectionsSpecInline,
                ),
              ],
              onChanged: (value) {
                _specType = value;
                _fieldChanged();
              },
            ),
          if (!_isTool || _specType == 'url')
            editorGroupField(
              AccessibleFormField(
                key: const Key('personal-connection-path'),
                controller: _path,
                label: l10n.personalConnectionsPath,
                enabled: !_busy,
                autocorrect: false,
                isRequired: true,
                errorText: errors.path,
                iosSettingsRow: native,
                textInputAction: TextInputAction.done,
                onChanged: _fieldChanged,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: CodeEntryField(
                key: const Key('personal-connection-spec'),
                controller: _spec,
                label: l10n.personalConnectionsSpecJson,
                hint: '{"openapi": "3.1.0", "paths": {}}',
                errorText: errors.spec,
                enabled: !_busy,
                minLines: 4,
                maxLines: 10,
                onChanged: _fieldChanged,
              ),
            ),
        ],
      ),
    ];
  }

  List<Widget> _keyRows(AppLocalizations l10n, ConduitThemeExtension theme) {
    final native = PlatformInfo.isIOS;
    final removing = _keyMode == PersonalConnectionSecretMode.clear;
    final keeping =
        _keyMode == PersonalConnectionSecretMode.keep && _hasStoredKey;
    return [
      editorGroupField(
        AccessibleFormField(
          key: const Key('personal-connection-key'),
          controller: _key,
          label: l10n.apiKey,
          // The stored key never reaches the form; the placeholder says what
          // happens to it instead.
          hint: removing
              ? l10n.personalConnectionsKeyWillRemove
              : keeping
              ? l10n.personalConnectionsKeyKept
              : null,
          enabled: !_busy && !removing,
          obscureText: !_showKey,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          iosSettingsRow: native,
          suffixIcon: ConduitIconButton(
            tooltip: _showKey ? l10n.hidePassword : l10n.showPassword,
            onPressed: () => setState(() => _showKey = !_showKey),
            icon: _showKey
                ? (context.usesCupertinoChrome
                      ? CupertinoIcons.eye_slash
                      : Icons.visibility_off)
                : (context.usesCupertinoChrome
                      ? CupertinoIcons.eye
                      : Icons.visibility),
            backgroundColor: native ? Colors.transparent : null,
            iconColor: native ? theme.iconSecondary : null,
            isCompact: native,
          ),
          onChanged: (value) {
            _keyMode = value.isEmpty && !_isNew
                ? PersonalConnectionSecretMode.keep
                : PersonalConnectionSecretMode.replace;
            _fieldChanged();
          },
        ),
      ),
      if (_hasStoredKey)
        UtilityRow(
          key: const Key('personal-connection-key-toggle'),
          title: removing
              ? l10n.personalConnectionsKeyKeep
              : l10n.personalConnectionsKeyRemove,
          titleFontWeight: native ? FontWeight.w400 : null,
          destructive: !removing,
          foregroundColor: removing ? theme.buttonPrimary : null,
          enabled: !_busy,
          onTap: () {
            _key.clear();
            _keyMode = removing
                ? PersonalConnectionSecretMode.keep
                : PersonalConnectionSecretMode.clear;
            _fieldChanged();
          },
        ),
    ];
  }

  /// A single choice: a native menu from a settings row on iOS, a dropdown
  /// elsewhere.
  Widget _choice<T>({
    required Key key,
    required String label,
    required T value,
    required List<AdaptiveDropdownOption<T>> options,
    required ValueChanged<T> onChanged,
  }) {
    final current =
        options.firstWhereOrNull((option) => option.value == value)?.label ??
        '';
    if (PlatformInfo.isIOS) {
      return IgnorePointer(
        key: key,
        ignoring: _busy,
        child: AdaptiveSingleChoiceTrigger<T>(
          value: value,
          options: options,
          onChanged: onChanged,
          nativeTitle: label,
          semanticLabel: '$label, $current',
          child: UtilityValueRow(
            label: label,
            value: current,
            titleFontWeight: FontWeight.w400,
            valueFontWeight: FontWeight.w400,
            valueTextStyle: AppTypography.bodyMediumStyle,
            selectable: false,
            showChevron: true,
          ),
        ),
      );
    }
    final theme = context.conduitTheme;
    return editorGroupField(
      DropdownButtonFormField<T>(
        key: key,
        initialValue: value,
        isExpanded: true,
        decoration: context.conduitInputStyles.standard().copyWith(
          labelText: label,
        ),
        dropdownColor: theme.surfaceBackground,
        items: [
          for (final option in options)
            DropdownMenuItem(
              value: option.value,
              enabled: option.enabled,
              child: Text(option.label),
            ),
        ],
        onChanged: _busy
            ? null
            : (next) {
                if (next == null || next == value) return;
                ConduitHaptics.selectionClick();
                onChanged(next);
              },
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const ConduitLoadingIndicator(size: IconSize.small, isCompact: true);
}
