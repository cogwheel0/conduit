import 'dart:collection';
import 'dart:math';

import 'package:conduit_core/features/integrations/personal_connection_client.dart';
import 'package:conduit_core/features/integrations/personal_connection_display.dart';
import 'package:conduit_core/features/integrations/personal_connection_drafts.dart';
import 'package:conduit_core/features/integrations/personal_connection_edits.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart'
    hide PersonalConnectionTestResult;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'account_scope.dart';
import 'server_rules.dart';
import 'settled.dart';

/// `integrations.*`: the account's personal tool servers (OpenAPI) and
/// terminals, through core's `PersonalConnectionsController`, as the phone's
/// Personal Connections page edits them.
///
/// The account a list was read for (core's `PersonalConnectionsSession`) is
/// handed to the window as an opaque `owner`; every change and test sends it
/// back, and is refused before anything is sent once another account is
/// signed in. The drafts, validation, patches and probes are core's.
///
/// Running a personal tool for a chat needs nothing here: core's socket
/// service answers Open WebUI's `execute:tool` for the requests the turns
/// sent, under the same access rule.
final class IntegrationsService {
  IntegrationsService(this._container);

  final ProviderContainer _container;

  final LinkedHashMap<String, PersonalConnectionsSession> _owners =
      LinkedHashMap<String, PersonalConnectionsSession>();
  int _nextOwner = 0;
  static const int _maxOwners = 16;
  final Random _random = Random.secure();

  PersonalConnectionsController get _controller =>
      _container.read(personalConnectionsProvider.notifier);

  /// Whether the account may use personal connections now (one rule with
  /// the composer's, [readPersonalConnectionsAccess]).
  Future<PersonalConnectionsAccess> _access() =>
      readPersonalConnectionsAccess(_container);

  static PersonalAccess _accessDto(PersonalConnectionsAccess access) =>
      switch (access.block) {
        null => PersonalAccess.allowed,
        PersonalConnectionsBlock.noAccount => PersonalAccess.noAccount,
        PersonalConnectionsBlock.serverDisabled =>
          PersonalAccess.serverDisabled,
        PersonalConnectionsBlock.noPermission => PersonalAccess.noPermission,
        PersonalConnectionsBlock.movedToTether => PersonalAccess.movedToTether,
      };

  String _remember(PersonalConnectionsSession owner) {
    for (final entry in _owners.entries) {
      if (identical(entry.value, owner)) return entry.key;
    }
    final token = 'p${++_nextOwner}';
    _owners[token] = owner;
    while (_owners.length > _maxOwners) {
      _owners.remove(_owners.keys.first);
    }
    return token;
  }

  static const RpcError _accountChanged = RpcError(
    code: ConduitErrorCodes.conflict,
    debugMessage: 'another account is signed in now',
    args: <String, String>{'reason': 'accountChanged'},
  );

  PersonalConnectionsSession _owner(String token) {
    final owner = _owners[token];
    if (owner == null || !owner.isCurrent()) throw _accountChanged;
    return owner;
  }

  static PersonalConnectionKind _kind(PersonalKind kind) => switch (kind) {
    PersonalKind.toolServer => PersonalConnectionKind.toolServer,
    PersonalKind.terminal => PersonalConnectionKind.terminal,
  };

  static PersonalConnectionDto _entry(PersonalConnectionEntry entry) {
    final raw = entry.raw;
    final hasKey = (raw['key']?.toString() ?? '').trim().isNotEmpty;
    switch (entry.kind) {
      case PersonalConnectionKind.toolServer:
        final draft = PersonalToolServerDraft.fromEntry(raw);
        return PersonalConnectionDto(
          kind: PersonalKind.toolServer,
          identity: entry.identity,
          name: entry.displayName,
          endpoint: personalConnectionPublicEndpoint(entry.url),
          enabled: entry.enabled,
          editable: entry.editable,
          description: draft.description,
          url: draft.url,
          specType: draft.specType,
          path: draft.path,
          spec: draft.spec,
          authType: draft.authType,
          hasKey: hasKey,
          fingerprint: personalConnectionFingerprint(raw),
        );
      case PersonalConnectionKind.terminal:
        final draft = PersonalTerminalDraft.fromEntry(raw);
        return PersonalConnectionDto(
          kind: PersonalKind.terminal,
          identity: entry.identity,
          name: entry.displayName,
          endpoint: personalConnectionPublicEndpoint(entry.url),
          enabled: entry.enabled,
          editable: entry.editable,
          url: draft.url,
          path: draft.path,
          hasKey: hasKey,
          fingerprint: personalConnectionFingerprint(raw),
        );
    }
  }

  PersonalConnections _list(
    PersonalConnectionsSnapshot snapshot, {
    bool savedForPreviousAccount = false,
    bool moved = false,
  }) {
    final server = snapshot.session.api.serverConfig;
    final name = server.name.trim();
    final readOnly = moved || snapshot.session.readOnly;
    return PersonalConnections(
      access: readOnly ? PersonalAccess.movedToTether : PersonalAccess.allowed,
      // A list to read only hands out no owner, so nothing can be changed.
      owner: readOnly ? '' : _remember(snapshot.session),
      accountName: snapshot.accountName,
      serverName: name.isNotEmpty
          ? name
          : (Uri.tryParse(server.url)?.host ?? ''),
      toolServers: <PersonalConnectionDto>[
        for (final entry in snapshot.toolServers) _entry(entry),
      ],
      terminals: <PersonalConnectionDto>[
        for (final entry in snapshot.terminals) _entry(entry),
      ],
      cleared: List<String>.of(
        _container.read(personalSelectionNoticeProvider),
      ),
      savedForPreviousAccount: savedForPreviousAccount,
    );
  }

  /// The connections, read again from the server.
  ///
  /// Bound to the account it was asked under ([AccountScope]): once another
  /// account is in charge after any wait, it is refused.
  Future<PersonalConnections> list() async {
    final account = AccountScope.capture(_container);
    final access = await _access();
    account.require('the personal connections are read');
    final moved = access.block == PersonalConnectionsBlock.movedToTether;
    if (!access.available && !moved) {
      return PersonalConnections(access: _accessDto(access));
    }
    final failed = PersonalConnections(
      access: _accessDto(access),
      failed: true,
    );
    try {
      final PersonalConnectionsSnapshot? snapshot;
      if (moved) {
        _container.invalidate(movedPersonalConnectionsProvider);
        snapshot = await readSettled(
          _container,
          movedPersonalConnectionsProvider.future,
        );
      } else {
        _container.invalidate(personalConnectionsProvider);
        snapshot = await readSettled(
          _container,
          personalConnectionsProvider.future,
        );
      }
      account.require('the personal connections are answered');
      if (snapshot == null) return failed;
      return _list(snapshot, moved: moved);
    } on RpcError {
      rethrow;
    } on Object {
      account.require('the personal connections are answered');
      return failed;
    }
  }

  /// The list as the controller holds it now, without reading again.
  Future<PersonalConnections> _current({
    bool savedForPreviousAccount = false,
  }) async {
    final snapshot = _container.read(personalConnectionsProvider).asData?.value;
    if (snapshot == null) {
      // Read again; a save that reached the previous account still says so.
      final fresh = await list();
      return savedForPreviousAccount
          ? fresh.copyWith(savedForPreviousAccount: true)
          : fresh;
    }
    return _list(snapshot, savedForPreviousAccount: savedForPreviousAccount);
  }

  Future<PersonalConnections> clearNotice() {
    _container.read(personalSelectionNoticeProvider.notifier).clear();
    return _current();
  }

  /// A new tool server's stable key, as the phone stamps one.
  String _stampKey() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'conduit-$hex';
  }

  static PersonalConnectionSecretMode _keyMode(PersonalKeyMode mode) =>
      switch (mode) {
        PersonalKeyMode.keep => PersonalConnectionSecretMode.keep,
        PersonalKeyMode.replace => PersonalConnectionSecretMode.replace,
        PersonalKeyMode.clear => PersonalConnectionSecretMode.clear,
      };

  /// A tool server form names only the modes it offers: another is refused
  /// before anything else, never read as the default (a key meant for
  /// another mode would otherwise go out as a bearer token).
  static void _modes(PersonalConnectionKind kind, PersonalConnectionDraft d) {
    if (kind != PersonalConnectionKind.toolServer) return;
    if (!const <String>{'url', 'json'}.contains(d.specType) ||
        !const <String>{'bearer', 'none'}.contains(d.authType)) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'the form names a mode it does not offer',
        args: <String, String>{'reason': 'unsupportedMode'},
      );
    }
  }

  /// The tool server form as core drafts it ([_modes] checked first).
  static PersonalToolServerDraft _toolDraft(PersonalConnectionDraft d) {
    return PersonalToolServerDraft(
      name: d.name,
      description: d.description,
      url: d.url,
      specType: d.specType,
      path: d.path,
      spec: d.spec,
      authType: d.authType,
      key: d.key,
      keyMode: _keyMode(d.keyMode),
      enabled: d.enabled,
    );
  }

  static PersonalTerminalDraft _terminalDraft(PersonalConnectionDraft d) =>
      PersonalTerminalDraft(
        name: d.name,
        url: d.url,
        path: d.path,
        key: d.key,
        keyMode: _keyMode(d.keyMode),
        enabled: d.enabled,
      );

  /// Each field's own issue, as the phone's form shows them: the URL checked
  /// with a stand-in path, the path or document with a stand-in URL.
  static void _validate(
    PersonalConnectionKind kind,
    PersonalConnectionDraft d,
  ) {
    const validUrl = 'https://example.com';
    final PersonalConnectionDraftIssue? urlIssue;
    final PersonalConnectionDraftIssue? restIssue;
    if (kind == PersonalConnectionKind.toolServer) {
      final draft = _toolDraft(d);
      urlIssue = draft
          .copyWith(specType: 'url', path: 'openapi.json')
          .validate();
      restIssue = draft.copyWith(url: validUrl).validate();
    } else {
      final draft = _terminalDraft(d);
      urlIssue = draft.copyWith(path: '/openapi.json').validate();
      restIssue = draft.copyWith(url: validUrl).validate();
    }
    if (urlIssue == null && restIssue == null) return;
    throw RpcError(
      code: ConduitErrorCodes.invalidParams,
      debugMessage: 'the form has a problem',
      args: <String, String>{
        'url': ?urlIssue?.name,
        if (restIssue == PersonalConnectionDraftIssue.pathRequired)
          'path': restIssue!.name,
        if (restIssue == PersonalConnectionDraftIssue.specInvalid)
          'spec': restIssue!.name,
      },
    );
  }

  PersonalConnectionEntry _existing(
    PersonalConnectionKind kind,
    String? identity,
  ) {
    final snapshot = _container.read(personalConnectionsProvider).asData?.value;
    final entry = identity == null ? null : snapshot?.find(kind, identity);
    if (entry == null) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'that connection is no longer listed',
        args: <String, String>{'reason': 'notFound'},
      );
    }
    return entry;
  }

  /// [entry], unless the editor opened it with another [fingerprint]
  /// (another window saved it since): then refused, as the save's own edit
  /// would be ([PersonalConnectionEditFailure.changed]), and the editor
  /// reads it again. Nothing is built from, or probed with, a stale draft.
  PersonalConnectionEntry _unchanged(
    PersonalConnectionEntry entry,
    String? fingerprint,
  ) {
    if (fingerprint == null ||
        personalConnectionFingerprint(entry.raw) == fingerprint) {
      return entry;
    }
    throw RpcError(
      code: ConduitErrorCodes.conflict,
      debugMessage: 'the connection changed since it was opened',
      args: <String, String>{
        'reason': PersonalConnectionEditFailure.changed.name,
      },
    );
  }

  Future<PersonalConnections> save(PersonalConnectionSave params) async {
    final kind = _kind(params.kind);
    if (params.draft case final draft?) _modes(kind, draft);
    final owner = _owner(params.owner);
    final isTool = kind == PersonalConnectionKind.toolServer;
    final PersonalConnectionEdit edit;
    switch (params.op) {
      case PersonalEditOp.add:
        final draft = params.draft ?? const PersonalConnectionDraft();
        _validate(kind, draft);
        edit = AddPersonalConnection(
          isTool
              ? _toolDraft(draft).toNewEntry(id: _stampKey())
              : _terminalDraft(draft).toNewEntry(),
        );
      case PersonalEditOp.patch:
        final draft = params.draft ?? const PersonalConnectionDraft();
        _validate(kind, draft);
        final entry = _unchanged(
          _existing(kind, params.identity),
          params.fingerprint,
        );
        final patch = isTool
            ? _toolDraft(draft).toPatch(entry.raw)
            : _terminalDraft(draft).toPatch(entry.raw);
        // Nothing changed: nothing to send.
        if (patch.isEmpty) return _current();
        edit = PatchPersonalConnection(
          entry.identity,
          patch,
          stampKey: isTool ? _stampKey() : null,
          // Checked again against the server's latest copy as it is written.
          fingerprint: params.fingerprint,
        );
      case PersonalEditOp.remove:
        edit = RemovePersonalConnection(
          _existing(kind, params.identity).identity,
        );
      case PersonalEditOp.setEnabled:
        final enabled = params.enabled;
        if (enabled == null) {
          throw const RpcError(
            code: ConduitErrorCodes.invalidParams,
            debugMessage: 'setEnabled needs `enabled`',
          );
        }
        edit = SetPersonalConnectionEnabled(
          _existing(kind, params.identity).identity,
          enabled,
        );
    }
    try {
      final outcome = await _controller.save(owner, kind, edit);
      return await _current(savedForPreviousAccount: outcome.stale);
    } on PersonalConnectionsOwnerChanged {
      throw _accountChanged;
    } on PersonalConnectionEditException catch (error) {
      throw _refused(error);
    } on PersonalConnectionsWriteRejected {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'the server did not keep the list',
        args: <String, String>{'reason': 'rejected'},
      );
    } on RpcError {
      rethrow;
    } on Object {
      throw const RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: 'the save failed',
        args: <String, String>{'reason': 'failed'},
      );
    }
  }

  /// Reads the OpenAPI document, or checks the terminal, with the form as it
  /// stands. An edit keeps the stored key unless the form replaces it.
  Future<PersonalConnectionTestResult> test(
    PersonalConnectionTest params,
  ) async {
    final kind = _kind(params.kind);
    _modes(kind, params.draft);
    final owner = _owner(params.owner);
    final isTool = kind == PersonalConnectionKind.toolServer;
    _validate(kind, params.draft);
    // A stored entry is tested as Save would store the form: its edit runs
    // against settings read again, refused once the entry changed since
    // the editor opened it, so a stale form's key is sent nowhere.
    final PatchPersonalConnection? edit;
    if (params.identity == null) {
      edit = null;
    } else {
      final existing = _unchanged(
        _existing(kind, params.identity),
        params.fingerprint,
      );
      edit = PatchPersonalConnection(
        existing.identity,
        isTool
            ? _toolDraft(params.draft).toPatch(existing.raw)
            : _terminalDraft(params.draft).toPatch(existing.raw),
        fingerprint: params.fingerprint,
      );
    }
    final account = AccountScope.capture(_container);
    try {
      final outcome = edit == null
          ? await _controller.testConnection(
              owner,
              kind,
              isTool
                  ? _toolDraft(params.draft).toNewEntry(id: _stampKey())
                  : _terminalDraft(params.draft).toNewEntry(),
            )
          : await _controller.testEdit(owner, kind, edit);
      // A probe made for the previous account is not that account's answer
      // to show under the next one.
      account.require('a connection test is answered');
      return PersonalConnectionTestResult(
        ok: outcome.succeeded,
        operationCount: outcome.operationCount,
        failure: switch (outcome.error?.failure) {
          null => null,
          PersonalConnectionProbeFailure.invalidTarget =>
            PersonalProbeFailure.invalidTarget,
          PersonalConnectionProbeFailure.unsupportedAuth =>
            PersonalProbeFailure.unsupportedAuth,
          PersonalConnectionProbeFailure.unauthorized =>
            PersonalProbeFailure.unauthorized,
          PersonalConnectionProbeFailure.unreachable =>
            PersonalProbeFailure.unreachable,
          PersonalConnectionProbeFailure.invalidSpec =>
            PersonalProbeFailure.invalidSpec,
        },
      );
    } on PersonalConnectionsOwnerChanged {
      throw _accountChanged;
    } on PersonalConnectionEditException catch (error) {
      throw _refused(error);
    }
  }

  /// A refused edit, as Save and Test answer it.
  static RpcError _refused(PersonalConnectionEditException error) => RpcError(
    code: error.failure == PersonalConnectionEditFailure.notFound
        ? ConduitErrorCodes.notFound
        : ConduitErrorCodes.conflict,
    debugMessage: 'the edit was refused',
    args: <String, String>{'reason': error.failure.name},
  );
}
