import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/adaptive_dropdown_field.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart' as adaptive;
import '../../../shared/widgets/utility_components.dart';
import '../controllers/direct_mcp_server_editor.dart';

import 'package:conduit_core/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart'
    show nativeIosTextMagnifierConfiguration;

class DirectMcpServerEditorPage extends ConsumerStatefulWidget {
  const DirectMcpServerEditorPage({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<DirectMcpServerEditorPage> createState() =>
      _DirectMcpServerEditorPageState();
}

class _DirectMcpServerEditorPageState
    extends ConsumerState<DirectMcpServerEditorPage> {
  late DirectMcpServerEditor _editor;

  @override
  void initState() {
    super.initState();
    _editor = _createEditor();
  }

  DirectMcpServerEditor _createEditor() => DirectMcpServerEditor(
    ProviderScope.containerOf(context, listen: false),
    serverId: widget.serverId,
  )..addListener(_editorChanged);

  void _editorChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant DirectMcpServerEditorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId) return;
    _editor
      ..removeListener(_editorChanged)
      ..dispose();
    _editor = _createEditor();
  }

  @override
  void dispose() {
    _editor
      ..removeListener(_editorChanged)
      ..dispose();
    super.dispose();
  }

  Future<bool> _confirm(DirectMcpEditorQuestion question) {
    final l10n = AppLocalizations.of(context)!;
    return switch (question) {
      DirectMcpEditorQuestion.credentialTransfer => ThemedDialogs.confirm(
        context,
        title: l10n.directMcpCredentialTransferTitle,
        message: l10n.directMcpCredentialTransferMessage,
        confirmText: l10n.directMcpCredentialTransferConfirm,
        barrierDismissible: false,
      ),
      DirectMcpEditorQuestion.insecureCredentials => ThemedDialogs.confirm(
        context,
        title: l10n.directMcpInsecureCredentialsTitle,
        message: l10n.directMcpInsecureCredentialsMessage,
        confirmText: l10n.directMcpInsecureCredentialsConfirm,
        barrierDismissible: false,
      ),
    };
  }

  Future<void> _save() async {
    final saved = await _editor.save(
      AppLocalizations.of(context)!,
      confirm: _confirm,
    );
    if (saved && mounted) unawaited(Navigator.of(context).maybePop(true));
  }

  Future<void> _testConnection() =>
      _editor.test(AppLocalizations.of(context)!, confirm: _confirm);

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final deleted = await _editor.delete(
      l10n,
      confirmDelete: (server) => ThemedDialogs.confirm(
        context,
        title: l10n.directMcpDeleteTitle,
        message: l10n.directMcpDeleteMessage(server.name),
        confirmText: l10n.delete,
        isDestructive: true,
      ),
    );
    if (deleted && mounted) unawaited(Navigator.of(context).maybePop(true));
  }

  Future<void> _connectOAuth() => _editor.connectOAuth(
    AppLocalizations.of(context)!,
    confirm: _confirm,
    // The page goes on as the stored server's, as onboarding opens it.
    onStored: (stored) {
      if (!mounted) return;
      context.replaceNamed(
        RouteNames.directMcpServerEditor,
        pathParameters: {'id': stored.id},
        queryParameters: const {'onboarding': 'true'},
        extra: const NativeSheetNavigationOrigin(),
      );
    },
  );

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
        _editor.observe(items);
        final oauthPending = _editor.oauthPending;
        if (_editor.missing) {
          return UtilityPageScaffold.settings(
            title: l10n.directMcpEditorTitle,
            children: [Text(l10n.directMcpMissing)],
          );
        }
        return UtilityPageScaffold.settings(
          title: _editor.createsServer
              ? l10n.directMcpAddTitle
              : l10n.directMcpEditorTitle,
          children: [
            Material(
              type: MaterialType.transparency,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.directMcpReachabilityHelp),
                  const SizedBox(height: 16),
                  TextField(
                    magnifierConfiguration: nativeIosTextMagnifierConfiguration,
                    key: const ValueKey('direct-mcp-name'),
                    controller: _editor.name,
                    enabled: !_editor.busy,
                    decoration: InputDecoration(labelText: l10n.directMcpName),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    magnifierConfiguration: nativeIosTextMagnifierConfiguration,
                    key: const ValueKey('direct-mcp-endpoint'),
                    controller: _editor.endpoint,
                    enabled: !_editor.busy && !oauthPending,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.directMcpEndpoint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  AdaptiveDropdownField<DirectMcpAuthMode>(
                    key: ValueKey(
                      'direct-mcp-auth-mode-${widget.serverId}-${_editor.authMode.name}',
                    ),
                    value: _editor.authMode,
                    decoration: adaptive.InputDecoration(
                      labelText: l10n.directMcpAuthMode,
                    ),
                    options: [
                      AdaptiveDropdownOption(
                        value: DirectMcpAuthMode.none,
                        label: l10n.directMcpAuthNone,
                      ),
                      AdaptiveDropdownOption(
                        value: DirectMcpAuthMode.bearer,
                        label: l10n.directMcpAuthBearer,
                      ),
                      AdaptiveDropdownOption(
                        value: DirectMcpAuthMode.oauth,
                        label: l10n.directMcpAuthOAuth,
                      ),
                    ],
                    onChanged: _editor.busy || oauthPending
                        ? null
                        : _editor.setAuthMode,
                  ),
                  if (_editor.authMode == DirectMcpAuthMode.bearer) ...[
                    const SizedBox(height: 12),
                    TextField(
                      magnifierConfiguration:
                          nativeIosTextMagnifierConfiguration,
                      key: const ValueKey('direct-mcp-token'),
                      controller: _editor.token,
                      enabled: !_editor.busy,
                      obscureText: true,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: l10n.directMcpBearerToken,
                      ),
                    ),
                  ],
                  if (_editor.authMode == DirectMcpAuthMode.oauth) ...[
                    const SizedBox(height: 12),
                    if (_editor.previous?.oauthTokens case final tokens?) ...[
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
                          : (_editor.previous?.oauthTokens == null
                                ? l10n.directMcpOAuthConnect
                                : l10n.directMcpOAuthReconnect),
                      isSecondary: true,
                      onPressed: _editor.busy
                          ? null
                          : (oauthPending
                                ? _editor.cancelOAuth
                                : _connectOAuth),
                    ),
                    if (_editor.previous?.oauthTokens != null &&
                        !oauthPending) ...[
                      const SizedBox(height: 8),
                      ConduitButton(
                        key: const ValueKey('direct-mcp-oauth-disconnect'),
                        text: l10n.directMcpOAuthDisconnect,
                        isDestructive: true,
                        onPressed: _editor.busy
                            ? null
                            : () => _editor.disconnectOAuth(l10n),
                      ),
                    ],
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    magnifierConfiguration: nativeIosTextMagnifierConfiguration,
                    key: const ValueKey('direct-mcp-headers'),
                    controller: _editor.headers,
                    enabled: !_editor.busy,
                    minLines: 2,
                    maxLines: 5,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.directMcpCustomHeaders,
                      hintText: l10n.directMcpCustomHeadersHint,
                    ),
                  ),
                  if (_editor.previous?.rememberedApprovals
                      case final approvals? when approvals.isNotEmpty) ...[
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
                          onPressed: _editor.busy || oauthPending
                              ? null
                              : () => _editor.revokeApproval(
                                  l10n,
                                  approval.digest,
                                ),
                          child: Text(l10n.directMcpRememberedApprovalRevoke),
                        ),
                      ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        key: const ValueKey('direct-mcp-remembered-revoke-all'),
                        onPressed: _editor.busy || oauthPending
                            ? null
                            : () => _editor.revokeApproval(l10n, null),
                        child: Text(l10n.directMcpRememberedApprovalsRevokeAll),
                      ),
                    ),
                  ],
                  MergeSemantics(
                    child: ListTile(
                      key: const ValueKey('direct-mcp-enabled'),
                      enabled: !_editor.busy,
                      contentPadding: EdgeInsets.zero,
                      title: ExcludeSemantics(child: Text(l10n.enabledLabel)),
                      trailing: adaptive.AdaptiveSwitch(
                        value: _editor.enabled,
                        semanticLabel: l10n.enabledLabel,
                        onChanged: _editor.busy ? null : _editor.setEnabled,
                      ),
                      onTap: _editor.busy
                          ? null
                          : () => _editor.setEnabled(!_editor.enabled),
                    ),
                  ),
                  if (_editor.message != null) ...[
                    const SizedBox(height: 8),
                    Semantics(liveRegion: true, child: Text(_editor.message!)),
                  ],
                  const SizedBox(height: 16),
                  ConduitButton(
                    key: const ValueKey('direct-mcp-test'),
                    text: l10n.directMcpTestConnection,
                    isSecondary: true,
                    isLoading: _editor.busy,
                    onPressed: _editor.busy ? null : _testConnection,
                  ),
                  const SizedBox(height: 8),
                  ConduitButton(
                    key: const ValueKey('direct-mcp-save'),
                    text: l10n.save,
                    isLoading: _editor.busy,
                    onPressed: _editor.busy || oauthPending ? null : _save,
                  ),
                  if (!_editor.createsServer) ...[
                    const SizedBox(height: 8),
                    ConduitButton(
                      key: const ValueKey('direct-mcp-delete'),
                      text: l10n.delete,
                      isDestructive: true,
                      onPressed: _editor.busy ? null : _delete,
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
