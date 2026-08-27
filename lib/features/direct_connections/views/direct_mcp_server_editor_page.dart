import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import '../models/direct_mcp_server.dart';
import '../providers/direct_mcp_providers.dart';
import '../services/direct_mcp_client.dart';
import '../services/direct_mcp_oauth.dart';

class DirectMcpServerEditorPage extends ConsumerStatefulWidget {
  const DirectMcpServerEditorPage({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<DirectMcpServerEditorPage> createState() =>
      _DirectMcpServerEditorPageState();
}

class _DirectMcpServerEditorPageState
    extends ConsumerState<DirectMcpServerEditorPage> {
  final _name = TextEditingController();
  final _endpoint = TextEditingController();
  final _token = TextEditingController();
  final _headers = TextEditingController();
  final _newServerId = const Uuid().v4();
  DirectMcpServer? _previous;
  bool _enabled = true;
  DirectMcpAuthMode _authMode = DirectMcpAuthMode.none;
  bool _initialized = false;
  bool _busy = false;
  bool _oauthPending = false;
  int _oauthAttempt = 0;
  String? _message;

  bool get _isNew => widget.serverId == 'new';

  @override
  void didUpdateWidget(covariant DirectMcpServerEditorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId) return;
    _initialized = false;
    _previous = null;
  }

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _token.dispose();
    _headers.dispose();
    super.dispose();
  }

  void _initialize(List<DirectMcpServer> servers) {
    if (_initialized) {
      final previous = _previous;
      if (previous != null) {
        final persisted = servers
            .where((server) => server.id == widget.serverId)
            .firstOrNull;
        if (persisted != null &&
            _sameServerExceptSecureState(previous, persisted)) {
          _previous = persisted;
        }
      }
      return;
    }
    _initialized = true;
    if (_isNew) return;
    _previous = servers
        .where((server) => server.id == widget.serverId)
        .firstOrNull;
    final server = _previous;
    if (server == null) return;
    _name.text = server.name;
    _endpoint.text = server.endpoint;
    _authMode = server.authMode;
    _token.text = server.authMode == DirectMcpAuthMode.bearer
        ? server.bearerToken ?? ''
        : '';
    _headers.text = server.customHeaders.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
    _enabled = server.enabled;
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

  DirectMcpServer _draft({bool forceEnabled = false}) {
    final l10n = AppLocalizations.of(context)!;
    final id = _isNew ? _newServerId : widget.serverId;
    final customHeaders = <String, String>{};
    final normalizedHeaderNames = <String>{};
    for (final rawLine in _headers.text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final separator = line.indexOf(':');
      if (separator <= 0) {
        throw FormatException(l10n.directMcpCustomHeadersHint);
      }
      final name = line.substring(0, separator).trim();
      if (!normalizedHeaderNames.add(name.toLowerCase())) {
        throw FormatException(l10n.headerAlreadyExists(name));
      }
      customHeaders[name] = line.substring(separator + 1).trim();
    }
    final previous = _previous;
    final keepsInsecureConfirmation =
        previous?.allowInsecureCredentials == true &&
        previous!.endpoint.trim() == _endpoint.text.trim() &&
        previous.authMode == _authMode &&
        previous.bearerToken ==
            (_authMode == DirectMcpAuthMode.bearer
                ? (_token.text.isEmpty ? null : _token.text)
                : null) &&
        previous.customHeaders.length == customHeaders.length &&
        previous.customHeaders.entries.every(
          (entry) => customHeaders[entry.key] == entry.value,
        );
    final server = DirectMcpServer(
      id: id,
      name: _name.text.trim(),
      endpoint: _endpoint.text.trim(),
      enabled: forceEnabled || _enabled,
      authMode: _authMode,
      bearerToken: _authMode == DirectMcpAuthMode.bearer
          ? (_token.text.isEmpty ? null : _token.text)
          : null,
      oauthTokens: _authMode == DirectMcpAuthMode.oauth
          ? (_previous?.oauthTokens?.appliesToEndpoint(_endpoint.text) == true
                ? _previous!.oauthTokens
                : null)
          : null,
      allowInsecureCredentials: keepsInsecureConfirmation,
      customHeaders: customHeaders,
      rememberedApprovals: _previous?.rememberedApprovals ?? const [],
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
  ) async {
    if (!server.requiresInsecureCredentialConfirmation ||
        server.allowInsecureCredentials) {
      return server;
    }
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.directMcpInsecureCredentialsTitle,
      message: l10n.directMcpInsecureCredentialsMessage,
      confirmText: l10n.directMcpInsecureCredentialsConfirm,
      barrierDismissible: false,
    );
    if (!confirmed || !mounted) return null;
    return server.copyWith(allowInsecureCredentials: true);
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    DirectMcpServer draft;
    try {
      draft = _draft();
    } on FormatException catch (error) {
      setState(() => _message = error.message);
      return;
    }

    var confirmed = false;
    final previous = _previous;
    if (previous != null && previous.origin != draft.origin) {
      confirmed = await ThemedDialogs.confirm(
        context,
        title: l10n.directMcpCredentialTransferTitle,
        message: l10n.directMcpCredentialTransferMessage,
        confirmText: l10n.directMcpCredentialTransferConfirm,
        barrierDismissible: false,
      );
      if (!confirmed) draft = draft.withoutSecrets();
    }
    if (!mounted) return;
    final confirmedDraft = await _confirmInsecureTransport(draft);
    if (confirmedDraft == null || !mounted) return;
    draft = confirmedDraft;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref
          .read(directMcpServersProvider.notifier)
          .upsert(
            draft,
            expectedPrevious: previous,
            secretsConfirmedForNewOrigin: confirmed,
          );
      if (mounted) context.pop(true);
    } catch (_) {
      if (mounted) setState(() => _message = l10n.directMcpSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    final l10n = AppLocalizations.of(context)!;
    DirectMcpServer draft;
    try {
      draft = _draft(forceEnabled: true);
    } on FormatException catch (error) {
      setState(() => _message = error.message);
      return;
    }
    final confirmedDraft = await _confirmInsecureTransport(draft);
    if (confirmedDraft == null || !mounted) return;
    draft = confirmedDraft;
    setState(() {
      _busy = true;
      _message = l10n.directMcpTesting;
    });
    try {
      final oauth = ref.read(directMcpOAuthCoordinatorProvider);
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
        if (mounted) {
          setState(
            () => _message = l10n.directMcpTestSucceeded(
              session.definitions.length,
            ),
          );
        }
      } finally {
        await session.close();
      }
    } catch (_) {
      if (mounted) setState(() => _message = l10n.directMcpTestFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final previous = _previous;
    if (previous == null) return;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.directMcpDeleteTitle,
      message: l10n.directMcpDeleteMessage(previous.name),
      confirmText: l10n.delete,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(directMcpServersProvider.notifier).remove(previous.id);
      if (mounted) context.pop(true);
    } catch (_) {
      if (mounted) setState(() => _message = l10n.directMcpDeleteFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectOAuth() async {
    final l10n = AppLocalizations.of(context)!;
    final servers = ref.read(directMcpServersProvider.notifier);
    final oauth = ref.read(directMcpOAuthCoordinatorProvider);
    DirectMcpServer draft;
    try {
      draft = _draft();
    } on FormatException catch (error) {
      setState(() => _message = error.message);
      return;
    }
    final confirmedDraft = await _confirmInsecureTransport(draft);
    if (confirmedDraft == null || !mounted) return;
    draft = confirmedDraft;
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
        );
        if (mounted) {
          _previous = restored.firstWhere((server) => server.id == previous.id);
        }
      } catch (_) {}
    }

    setState(() {
      _oauthPending = true;
      _message = l10n.directMcpOAuthPending;
    });
    try {
      final saved = await servers.upsert(draft, expectedPrevious: _previous);
      final persisted = saved.firstWhere((server) => server.id == draft.id);
      interim = persisted;
      if (_isNew) {
        if (!mounted) return;
        context.replaceNamed(
          RouteNames.directMcpServerEditor,
          pathParameters: {'id': persisted.id},
          extra: const NativeSheetNavigationOrigin(),
        );
      }
      if (!mounted || oauthAttempt != _oauthAttempt || !_oauthPending) {
        await restorePreviousBearer();
        return;
      }
      final connected = await oauth.connect(persisted);
      oauthCompleted = true;
      await servers.reload();
      if (mounted) {
        setState(() {
          _previous = connected;
          _message = l10n.directMcpOAuthConnected;
        });
      }
    } catch (error) {
      if (!oauthCompleted) await restorePreviousBearer();
      if (mounted) {
        setState(
          () => _message = switch (error) {
            FormatException() => error.message,
            DirectMcpOAuthException() => error.message,
            _ => l10n.directMcpOAuthConnectFailed,
          },
        );
      }
    } finally {
      if (mounted) setState(() => _oauthPending = false);
    }
  }

  Future<void> _cancelOAuth() async {
    final oauth = ref.read(directMcpOAuthCoordinatorProvider);
    _oauthAttempt++;
    await oauth.cancel(_isNew ? _newServerId : widget.serverId);
    if (mounted) {
      setState(() {
        _oauthPending = false;
        _message = null;
      });
    }
  }

  Future<void> _disconnectOAuth() async {
    final l10n = AppLocalizations.of(context)!;
    final previous = _previous;
    if (previous == null) return;
    final servers = ref.read(directMcpServersProvider.notifier);
    final oauth = ref.read(directMcpOAuthCoordinatorProvider);
    setState(() => _busy = true);
    try {
      final disconnected = await oauth.disconnect(previous);
      await servers.reload();
      if (mounted) {
        setState(() {
          _previous = disconnected;
          _message = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = l10n.directMcpOAuthDisconnectFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokeRememberedApproval(String? digest) async {
    final l10n = AppLocalizations.of(context)!;
    final previous = _previous;
    if (previous == null) return;
    final servers = ref.read(directMcpServersProvider.notifier);
    setState(() => _busy = true);
    try {
      final updated = digest == null
          ? await servers.revokeAllRememberedApprovals(previous)
          : await servers.revokeRememberedApproval(previous, digest);
      if (mounted) {
        setState(() {
          _previous = updated.firstWhere((server) => server.id == previous.id);
          _message = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = l10n.directMcpRememberedApprovalRevokeFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final servers = ref.watch(directMcpServersProvider);
    return servers.when(
      loading: () => UtilityPageScaffold.settings(
        title: l10n.directMcpEditorTitle,
        children: const [Center(child: CircularProgressIndicator.adaptive())],
      ),
      error: (_, _) => UtilityPageScaffold.settings(
        title: l10n.directMcpEditorTitle,
        children: [Text(l10n.directMcpLoadFailed)],
      ),
      data: (items) {
        _initialize(items);
        final oauthPending =
            _oauthPending ||
            ref
                .watch(directMcpOAuthCoordinatorProvider)
                .isPending(_isNew ? _newServerId : widget.serverId);
        if (!_isNew && _previous == null) {
          return UtilityPageScaffold.settings(
            title: l10n.directMcpEditorTitle,
            children: [Text(l10n.directMcpMissing)],
          );
        }
        return UtilityPageScaffold.settings(
          title: _isNew ? l10n.directMcpAddTitle : l10n.directMcpEditorTitle,
          children: [
            Material(
              type: MaterialType.transparency,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.directMcpReachabilityHelp),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('direct-mcp-name'),
                    controller: _name,
                    enabled: !_busy,
                    decoration: InputDecoration(labelText: l10n.directMcpName),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('direct-mcp-endpoint'),
                    controller: _endpoint,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.directMcpEndpoint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<DirectMcpAuthMode>(
                    key: ValueKey(
                      'direct-mcp-auth-mode-${widget.serverId}-${_authMode.name}',
                    ),
                    initialValue: _authMode,
                    decoration: InputDecoration(
                      labelText: l10n.directMcpAuthMode,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: DirectMcpAuthMode.none,
                        child: Text(l10n.directMcpAuthNone),
                      ),
                      DropdownMenuItem(
                        value: DirectMcpAuthMode.bearer,
                        child: Text(l10n.directMcpAuthBearer),
                      ),
                      DropdownMenuItem(
                        value: DirectMcpAuthMode.oauth,
                        child: Text(l10n.directMcpAuthOAuth),
                      ),
                    ],
                    onChanged: _busy || oauthPending
                        ? null
                        : (mode) {
                            if (mode == null) return;
                            setState(() {
                              _authMode = mode;
                              _message = null;
                              if (mode != DirectMcpAuthMode.bearer) {
                                _token.clear();
                              }
                            });
                          },
                  ),
                  if (_authMode == DirectMcpAuthMode.bearer) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('direct-mcp-token'),
                      controller: _token,
                      enabled: !_busy,
                      obscureText: true,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: l10n.directMcpBearerToken,
                      ),
                    ),
                  ],
                  if (_authMode == DirectMcpAuthMode.oauth) ...[
                    const SizedBox(height: 12),
                    if (_previous?.oauthTokens case final tokens?) ...[
                      Text(
                        l10n.directMcpOAuthConnectionDetails(
                          Uri.parse(tokens.authorizationServerIssuer).host,
                          tokens.grantedScope ?? l10n.directMcpOAuthNoScopes,
                        ),
                        key: const ValueKey('direct-mcp-oauth-details'),
                      ),
                      const SizedBox(height: 8),
                    ],
                    ConduitButton(
                      key: const ValueKey('direct-mcp-oauth-connect'),
                      text: oauthPending
                          ? l10n.cancel
                          : (_previous?.oauthTokens == null
                                ? l10n.directMcpOAuthConnect
                                : l10n.directMcpOAuthReconnect),
                      isSecondary: true,
                      onPressed: _busy
                          ? null
                          : (oauthPending ? _cancelOAuth : _connectOAuth),
                    ),
                    if (_previous?.oauthTokens != null && !oauthPending) ...[
                      const SizedBox(height: 8),
                      ConduitButton(
                        key: const ValueKey('direct-mcp-oauth-disconnect'),
                        text: l10n.directMcpOAuthDisconnect,
                        isDestructive: true,
                        onPressed: _busy ? null : _disconnectOAuth,
                      ),
                    ],
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('direct-mcp-headers'),
                    controller: _headers,
                    enabled: !_busy,
                    minLines: 2,
                    maxLines: 5,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.directMcpCustomHeaders,
                      hintText: l10n.directMcpCustomHeadersHint,
                    ),
                  ),
                  if (_previous?.rememberedApprovals case final approvals?
                      when approvals.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      l10n.directMcpRememberedApprovalsTitle,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.directMcpRememberedApprovalsSubtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    for (final approval in approvals)
                      ListTile(
                        key: ValueKey(
                          'direct-mcp-remembered-${approval.digest}',
                        ),
                        contentPadding: EdgeInsets.zero,
                        title: Text(approval.displayName),
                        subtitle: Text(
                          '${approval.remoteToolName} · ${MaterialLocalizations.of(context).formatCompactDate(approval.createdAt.toLocal())}',
                        ),
                        trailing: TextButton(
                          onPressed: _busy
                              ? null
                              : () =>
                                    _revokeRememberedApproval(approval.digest),
                          child: Text(l10n.directMcpRememberedApprovalRevoke),
                        ),
                      ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        key: const ValueKey('direct-mcp-remembered-revoke-all'),
                        onPressed: _busy
                            ? null
                            : () => _revokeRememberedApproval(null),
                        child: Text(l10n.directMcpRememberedApprovalsRevokeAll),
                      ),
                    ),
                  ],
                  SwitchListTile.adaptive(
                    key: const ValueKey('direct-mcp-enabled'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.enabledLabel),
                    value: _enabled,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _enabled = value),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 8),
                    Semantics(liveRegion: true, child: Text(_message!)),
                  ],
                  const SizedBox(height: 16),
                  ConduitButton(
                    key: const ValueKey('direct-mcp-test'),
                    text: l10n.directMcpTestConnection,
                    isSecondary: true,
                    isLoading: _busy,
                    onPressed: _busy ? null : _testConnection,
                  ),
                  const SizedBox(height: 8),
                  ConduitButton(
                    key: const ValueKey('direct-mcp-save'),
                    text: l10n.save,
                    isLoading: _busy,
                    onPressed: _busy || oauthPending ? null : _save,
                  ),
                  if (!_isNew) ...[
                    const SizedBox(height: 8),
                    ConduitButton(
                      key: const ValueKey('direct-mcp-delete'),
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
      },
    );
  }
}
