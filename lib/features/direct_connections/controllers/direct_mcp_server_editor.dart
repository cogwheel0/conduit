import 'package:conduit_core/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_client.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_oauth.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../l10n/app_localizations.dart';
import 'direct_custom_headers_controller.dart';

/// The server id an editor adding an MCP server is opened with.
const directMcpNewServerId = 'new';

/// What an MCP editor asks before it goes on.
enum DirectMcpEditorQuestion {
  /// The server's credentials would go to a new endpoint.
  credentialTransfer,

  /// Credentials would travel without encryption.
  insecureCredentials,
}

/// Answers [question]: true goes ahead.
typedef DirectMcpEditorConfirm = Future<bool> Function(
  DirectMcpEditorQuestion question,
);

/// One MCP server being added or edited: its fields, the server as stored,
/// and what was last said about it. Onboarding's MCP page and Settings's
/// own both edit through it.
final class DirectMcpServerEditor extends ChangeNotifier {
  DirectMcpServerEditor(this._container, {required this.serverId});

  final ProviderContainer _container;

  /// The server edited, or [directMcpNewServerId] for one being added.
  final String serverId;

  final name = TextEditingController();
  final endpoint = TextEditingController();
  final token = TextEditingController();
  final headers = TextEditingController();
  final _newServerId = const Uuid().v4();

  DirectMcpServer? _previous;
  bool _enabled = true;
  DirectMcpAuthMode _authMode = DirectMcpAuthMode.none;
  bool _initialized = false;
  bool _busy = false;
  bool _oauthPending = false;
  int _oauthAttempt = 0;
  String? _message;
  bool _disposed = false;

  /// Whether the editor was opened to add a server.
  bool get createsServer => serverId == directMcpNewServerId;

  /// The id the server is saved under.
  String get id => createsServer ? _newServerId : serverId;

  /// The server as stored, once it is: an added one is stored when OAuth
  /// starts, before it is saved.
  DirectMcpServer? get previous => _previous;
  bool get enabled => _enabled;
  DirectMcpAuthMode get authMode => _authMode;
  bool get initialized => _initialized;
  bool get busy => _busy;

  /// The outcome of the last action, or why it failed.
  String? get message => _message;

  /// Whether the server edited is gone.
  bool get missing => _initialized && !createsServer && _previous == null;

  /// Whether a browser sign-in is under way for the server, from this
  /// editor or an earlier one.
  bool get oauthPending =>
      _oauthPending ||
      _container.read(directMcpOAuthCoordinatorProvider).isPending(id);

  /// Takes in [servers] as stored. The first time, the fields fill in from
  /// the server; after that only a reload that changed nothing but its
  /// secure state (tokens, approvals) is adopted. Returns whether the
  /// stored server it holds changed.
  bool observe(List<DirectMcpServer> servers) {
    if (_initialized) {
      final previous = _previous;
      if (previous == null) return false;
      final persisted = servers
          .where((server) => server.id == previous.id)
          .firstOrNull;
      if (persisted == null) {
        // Deleted elsewhere: there is nothing left to save to or delete.
        _previous = null;
        return true;
      }
      if (identical(persisted, previous) ||
          !_sameServerExceptSecureState(previous, persisted)) {
        return false;
      }
      _previous = persisted;
      return true;
    }
    _initialized = true;
    if (createsServer) return true;
    _previous = servers.where((server) => server.id == serverId).firstOrNull;
    final server = _previous;
    if (server == null) return true;
    name.text = server.name;
    endpoint.text = server.endpoint;
    _authMode = server.authMode;
    token.text = server.authMode == DirectMcpAuthMode.bearer
        ? server.bearerToken ?? ''
        : '';
    headers.text = server.customHeaders.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
    _enabled = server.enabled;
    return true;
  }

  bool _sameServerExceptSecureState(
    DirectMcpServer previous,
    DirectMcpServer persisted,
  ) => sameDirectMcpServerValues(
    previous.copyWith(
      oauthTokens: persisted.oauthTokens,
      rememberedApprovals: persisted.rememberedApprovals,
    ),
    persisted,
  );

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _changed();
  }

  /// The headers [headers] holds, one `Name: Value` line each, as rows.
  /// Lines that are not one are left out.
  List<MapEntry<String, String>> get headerEntries {
    final entries = <MapEntry<String, String>>[];
    for (final raw in headers.text.split('\n')) {
      final line = raw.trim();
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      entries.add(
        MapEntry(
          line.substring(0, separator).trim(),
          line.substring(separator + 1).trim(),
        ),
      );
    }
    return entries;
  }

  /// Adds header [name] with [value], checked as a provider's are; returns
  /// what is wrong with it instead when it cannot be added.
  DirectHeaderValidationError? addHeader(String name, String value) {
    final entries = headerEntries;
    final trimmedName = name.trim();
    final trimmedValue = value.trim();
    final problem = validateDirectCustomHeader(
      entries.map((entry) => entry.key),
      name: trimmedName,
      value: trimmedValue,
      reserved: DirectMcpServer.reservedHeaderNames,
    );
    if (problem != null) return problem;
    _setHeaders([...entries, MapEntry(trimmedName, trimmedValue)]);
    return null;
  }

  /// Removes header [name].
  void removeHeader(String name) =>
      _setHeaders(headerEntries.where((entry) => entry.key != name));

  void _setHeaders(Iterable<MapEntry<String, String>> entries) {
    headers.text = entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
    _changed();
  }

  void setAuthMode(DirectMcpAuthMode mode) {
    _authMode = mode;
    _message = null;
    if (mode != DirectMcpAuthMode.bearer) token.clear();
    _changed();
  }

  /// The server the fields describe. Throws a [FormatException] saying
  /// what is wrong with them.
  DirectMcpServer draft(AppLocalizations l10n, {bool forceEnabled = false}) {
    final customHeaders = <String, String>{};
    final normalizedHeaderNames = <String>{};
    for (final rawLine in headers.text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final separator = line.indexOf(':');
      if (separator <= 0) {
        throw FormatException(l10n.directMcpCustomHeadersHint);
      }
      final headerName = line.substring(0, separator).trim();
      if (!normalizedHeaderNames.add(headerName.toLowerCase())) {
        throw FormatException(l10n.headerAlreadyExists(headerName));
      }
      customHeaders[headerName] = line.substring(separator + 1).trim();
    }
    final previous = _previous;
    final bearerToken = _authMode == DirectMcpAuthMode.bearer
        ? (token.text.isEmpty ? null : token.text)
        : null;
    final keepsInsecureConfirmation =
        previous?.allowInsecureCredentials == true &&
        previous!.endpoint.trim() == endpoint.text.trim() &&
        previous.authMode == _authMode &&
        previous.bearerToken == bearerToken &&
        previous.customHeaders.length == customHeaders.length &&
        previous.customHeaders.entries.every(
          (entry) => customHeaders[entry.key] == entry.value,
        );
    final server = DirectMcpServer(
      id: id,
      name: name.text.trim(),
      endpoint: endpoint.text.trim(),
      enabled: forceEnabled || _enabled,
      authMode: _authMode,
      bearerToken: bearerToken,
      oauthTokens: _authMode == DirectMcpAuthMode.oauth
          ? (previous?.oauthTokens?.appliesToEndpoint(endpoint.text) == true
                ? previous!.oauthTokens
                : null)
          : null,
      allowInsecureCredentials: keepsInsecureConfirmation,
      customHeaders: customHeaders,
      rememberedApprovals: previous?.rememberedApprovals ?? const [],
    );
    if (server.requiresInsecureCredentialConfirmation &&
        !server.allowInsecureCredentials) {
      server.copyWith(allowInsecureCredentials: true).validate();
    } else {
      server.validate();
    }
    return server;
  }

  Future<DirectMcpServer?> _confirmInsecureTransport(
    DirectMcpServer server,
    DirectMcpEditorConfirm confirm,
  ) async {
    if (!server.requiresInsecureCredentialConfirmation ||
        server.allowInsecureCredentials) {
      return server;
    }
    final confirmed = await confirm(
      DirectMcpEditorQuestion.insecureCredentials,
    );
    if (!confirmed || _disposed) return null;
    return server.copyWith(allowInsecureCredentials: true);
  }

  /// Asks before the server's credentials go to a new endpoint; declined,
  /// the server goes there without them.
  Future<({DirectMcpServer server, bool confirmed})> _confirmCredentialTransfer(
    DirectMcpServer server,
    DirectMcpEditorConfirm confirm,
  ) async {
    final previous = _previous;
    if (previous == null ||
        !server.hasEndpointBoundCredentials ||
        sameDirectMcpCredentialEndpoint(previous.endpoint, server.endpoint)) {
      return (server: server, confirmed: false);
    }
    final confirmed = await confirm(DirectMcpEditorQuestion.credentialTransfer);
    return (
      server: confirmed ? server : server.withoutSecrets(),
      confirmed: confirmed,
    );
  }

  /// Saves the server. Returns whether it was saved; otherwise [message]
  /// says why, or the user declined a question.
  Future<bool> save(
    AppLocalizations l10n, {
    required DirectMcpEditorConfirm confirm,
  }) async {
    DirectMcpServer draft;
    try {
      draft = this.draft(l10n);
    } on FormatException catch (error) {
      _say(error.message);
      return false;
    }

    final previous = _previous;
    final transfer = await _confirmCredentialTransfer(draft, confirm);
    if (_disposed) return false;
    draft = transfer.server;
    final confirmedDraft = await _confirmInsecureTransport(draft, confirm);
    if (confirmedDraft == null || _disposed) return false;
    draft = confirmedDraft;
    _busy = true;
    _message = null;
    _changed();
    try {
      await _container
          .read(directMcpServersProvider.notifier)
          .upsert(
            draft,
            expectedPrevious: previous,
            endpointCredentialsConfirmed: transfer.confirmed,
          );
      return true;
    } catch (_) {
      _message = l10n.directMcpSaveFailed;
      return false;
    } finally {
      _busy = false;
      _changed();
    }
  }

  /// Connects to the server as the fields describe it and lists its tools,
  /// saying how it went in [message].
  Future<void> test(
    AppLocalizations l10n, {
    required DirectMcpEditorConfirm confirm,
  }) async {
    DirectMcpServer draft;
    try {
      draft = this.draft(l10n, forceEnabled: true);
    } on FormatException catch (error) {
      _say(error.message);
      return;
    }
    final transfer = await _confirmCredentialTransfer(draft, confirm);
    if (_disposed) return;
    draft = transfer.server;
    final confirmedDraft = await _confirmInsecureTransport(draft, confirm);
    if (confirmedDraft == null || _disposed) return;
    draft = confirmedDraft;
    _busy = true;
    _message = l10n.directMcpTesting;
    _changed();
    try {
      final oauth = _container.read(directMcpOAuthCoordinatorProvider);
      final credentialServer =
          draft.authMode == DirectMcpAuthMode.oauth && draft.oauthTokens != null
          ? _previous
          : null;
      final session = await DirectMcpToolSession.open(
        [draft],
        authorizationResolver: (server, {forceRefresh = false}) =>
            oauth.accessTokenFor(
              credentialServer ?? server,
              forceRefresh: forceRefresh,
            ),
      );
      try {
        _message = l10n.directMcpTestSucceeded(session.definitions.length);
      } finally {
        await session.close();
      }
    } catch (_) {
      _message = l10n.directMcpTestFailed;
    } finally {
      _busy = false;
      _changed();
    }
  }

  /// Deletes the stored server once [confirmDelete] agrees. Returns whether
  /// it is gone.
  Future<bool> delete(
    AppLocalizations l10n, {
    required Future<bool> Function(DirectMcpServer server) confirmDelete,
  }) async {
    final previous = _previous;
    if (previous == null) return false;
    final confirmed = await confirmDelete(previous);
    if (!confirmed || _disposed) return false;
    _busy = true;
    _changed();
    try {
      await _container
          .read(directMcpServersProvider.notifier)
          .remove(previous.id);
      return true;
    } catch (_) {
      _message = l10n.directMcpDeleteFailed;
      return false;
    } finally {
      _busy = false;
      _changed();
    }
  }

  /// Saves the server and signs in to it in the browser. A server being
  /// added is stored first, [onStored] hearing of it; a bearer token the
  /// sign-in would have replaced comes back if it does not finish.
  Future<void> connectOAuth(
    AppLocalizations l10n, {
    required DirectMcpEditorConfirm confirm,
    void Function(DirectMcpServer stored)? onStored,
  }) async {
    final servers = _container.read(directMcpServersProvider.notifier);
    final oauth = _container.read(directMcpOAuthCoordinatorProvider);
    DirectMcpServer draft;
    try {
      draft = this.draft(l10n);
    } on FormatException catch (error) {
      _say(error.message);
      return;
    }
    final confirmedDraft = await _confirmInsecureTransport(draft, confirm);
    if (confirmedDraft == null || _disposed) return;
    // The sign-in saves the server first; credentials go with a new
    // address only once agreed to, as Save and Test ask.
    final transfer = await _confirmCredentialTransfer(confirmedDraft, confirm);
    if (_disposed) return;
    draft = transfer.server;
    final previous = _previous;
    DirectMcpServer? interim;
    var oauthCompleted = false;
    final oauthAttempt = ++_oauthAttempt;
    Future<void> restorePreviousBearer() async {
      if (previous?.authMode != DirectMcpAuthMode.bearer || interim == null) {
        return;
      }
      try {
        final restored = await servers.upsert(
          previous!,
          expectedPrevious: interim,
          endpointCredentialsConfirmed: true,
        );
        if (!_disposed) {
          _previous = restored.firstWhere((server) => server.id == previous.id);
        }
      } catch (_) {}
    }

    _oauthPending = true;
    _message = l10n.directMcpOAuthPending;
    _changed();
    try {
      final saved = await servers.upsert(
        draft,
        expectedPrevious: _previous,
        endpointCredentialsConfirmed: transfer.confirmed,
      );
      final persisted = saved.firstWhere((server) => server.id == draft.id);
      interim = persisted;
      if (!_disposed && previous == null) {
        _previous = persisted;
        onStored?.call(persisted);
      }
      if (_disposed || oauthAttempt != _oauthAttempt || !_oauthPending) {
        await restorePreviousBearer();
        return;
      }
      final connected = await oauth.connect(persisted);
      oauthCompleted = true;
      await servers.reload();
      if (!_disposed) {
        _previous = connected;
        _message = l10n.directMcpOAuthConnected;
      }
    } catch (error) {
      if (!oauthCompleted) await restorePreviousBearer();
      if (!_disposed) {
        _message = switch (error) {
          FormatException() => error.message,
          DirectMcpOAuthException() => error.message,
          _ => l10n.directMcpOAuthConnectFailed,
        };
      }
    } finally {
      _oauthPending = false;
      _changed();
    }
  }

  /// Stops the browser sign-in under way.
  Future<void> cancelOAuth() async {
    final oauth = _container.read(directMcpOAuthCoordinatorProvider);
    _oauthAttempt++;
    await oauth.cancel(id);
    _oauthPending = false;
    _message = null;
    _changed();
  }

  /// Forgets the server's OAuth sign-in.
  Future<void> disconnectOAuth(AppLocalizations l10n) async {
    final previous = _previous;
    if (previous == null) return;
    final servers = _container.read(directMcpServersProvider.notifier);
    final oauth = _container.read(directMcpOAuthCoordinatorProvider);
    _busy = true;
    _changed();
    try {
      final disconnected = await oauth.disconnect(previous);
      await servers.reload();
      if (!_disposed) {
        _previous = disconnected;
        _message = null;
      }
    } catch (_) {
      _message = l10n.directMcpOAuthDisconnectFailed;
    } finally {
      _busy = false;
      _changed();
    }
  }

  /// Revokes the remembered approval [digest], or every one when null.
  Future<void> revokeApproval(AppLocalizations l10n, String? digest) async {
    final previous = _previous;
    if (previous == null) return;
    final servers = _container.read(directMcpServersProvider.notifier);
    _busy = true;
    _changed();
    try {
      final updated = digest == null
          ? await servers.revokeAllRememberedApprovals(previous)
          : await servers.revokeRememberedApproval(previous, digest);
      if (!_disposed) {
        _previous = updated.firstWhere((server) => server.id == previous.id);
        _message = null;
      }
    } catch (_) {
      _message = l10n.directMcpRememberedApprovalRevokeFailed;
    } finally {
      _busy = false;
      _changed();
    }
  }

  void _say(String message) {
    _message = message;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    name.dispose();
    endpoint.dispose();
    token.dispose();
    headers.dispose();
    super.dispose();
  }
}
