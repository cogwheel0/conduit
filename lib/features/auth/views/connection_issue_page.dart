import 'dart:io' show Platform;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';

import '../../../platform/webview_cookie_helper.dart';

import 'package:conduit_core/auth/proxy_session.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';

import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../../l10n/app_localizations.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import 'proxy_auth_page.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sign_out_options_dialog.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/utility_components.dart';

class ConnectionIssuePage extends ConsumerStatefulWidget {
  const ConnectionIssuePage({super.key});

  @override
  ConsumerState<ConnectionIssuePage> createState() =>
      _ConnectionIssuePageState();
}

/// Whether [config] carries a reverse-proxy session cookie, i.e. was set up
/// through the proxy sign-in flow and can be re-authenticated in place.
bool serverConfigHasProxyCookie(ServerConfig? config) {
  if (config == null) return false;
  return config.customHeaders.keys.any((key) => key.toLowerCase() == 'cookie');
}

class _ConnectionIssuePageState extends ConsumerState<ConnectionIssuePage> {
  bool _isLoggingOut = false;
  bool _isRetrying = false;
  String? _statusMessage;

  bool get _busy => _isLoggingOut || _isRetrying;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connectivity = ref.watch(connectivityStatusProvider);
    final activeServerAsync = ref.watch(activeServerProvider);
    final activeServer = activeServerAsync.asData?.value;

    return UtilityPageScaffold.auth(
      title: l10n.connectionIssueTitle,
      bottomAction: _buildActions(context, l10n, activeServer),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtilityIdentityHeader(
            leading: const OpenWebUiConnectionMark(),
            title: l10n.backendChooserOpenWebUITitle,
            subtitle: l10n.connectionIssueSubtitle,
          ),
          const SizedBox(height: Spacing.xl),
          ConnectionAttemptBanner(
            state: _isRetrying
                ? ConnectionAttemptState.connecting(l10n.connecting)
                : ConnectionAttemptState.failed(
                    _statusMessage ?? _statusLabel(connectivity, l10n),
                  ),
          ),
          if (activeServer != null) ...[
            const SizedBox(height: Spacing.xl),
            _buildServerDetails(context, activeServer),
          ],
        ],
      ),
    );
  }

  Widget _buildServerDetails(BuildContext context, ServerConfig server) {
    final host = _resolveHost(server);

    return InsetGroupedSection(
      title: AppLocalizations.of(context)!.openWebUIServer,
      child: Column(
        children: [
          UtilityValueRow(
            label: AppLocalizations.of(context)!.serverNameLabel,
            value: host,
          ),
          Divider(color: context.conduitTheme.dividerColor),
          UtilityValueRow(
            label: AppLocalizations.of(context)!.serverUrl,
            value: server.url,
            monospace: true,
          ),
        ],
      ),
    );
  }

  Widget _buildActions(
    BuildContext context,
    AppLocalizations l10n,
    ServerConfig? activeServer,
  ) {
    final canReauthenticateProxy =
        isWebViewSupported && serverConfigHasProxyCookie(activeServer);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (canReauthenticateProxy) ...[
          ConduitButton(
            text: l10n.proxyAuthSignInAgain,
            onPressed: _busy
                ? null
                : () => _reauthenticateProxy(activeServer!, l10n),
            icon: Platform.isIOS ? CupertinoIcons.lock_shield : Icons.shield,
            isFullWidth: true,
          ),
          const SizedBox(height: Spacing.sm),
        ],
        ConduitButton(
          text: l10n.retry,
          onPressed: _busy ? null : _retryConnection,
          isLoading: _isRetrying,
          icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh_rounded,
          isFullWidth: true,
          isSecondary: canReauthenticateProxy,
        ),
        const SizedBox(height: Spacing.sm),
        ConduitButton(
          text: l10n.signOut,
          onPressed: _busy ? null : () => _logout(l10n),
          isLoading: _isLoggingOut,
          isSecondary: true,
          icon: Platform.isIOS
              ? CupertinoIcons.arrow_turn_up_left
              : Icons.logout,
          isFullWidth: true,
          isCompact: true,
        ),
      ],
    );
  }

  /// Reopens the reverse-proxy sign-in for the current server and stores the
  /// fresh cookies in place, so an expired proxy session is renewed without
  /// signing out of Conduit (issues #690, #698).
  Future<void> _reauthenticateProxy(
    ServerConfig activeServer,
    AppLocalizations l10n,
  ) async {
    final result = await context.pushNamed<ProxyAuthResult>(
      RouteNames.proxyAuth,
      extra: ProxyAuthConfig(serverConfig: activeServer),
    );
    if (!mounted) return;
    final cookies = result?.cookies ?? const <String, String>{};
    if (result == null ||
        !result.success ||
        (cookies.isEmpty && !result.isFullyAuthenticated)) {
      setState(() => _statusMessage = l10n.proxyAuthFailed);
      return;
    }

    setState(() {
      _isRetrying = true;
      _statusMessage = null;
    });
    try {
      final updatedServer = activeServer.copyWith(
        customHeaders: mergeCapturedProxyCookiesIntoHeaders(
          headers: activeServer.customHeaders,
          capturedCookies: cookies,
        ),
      );
      final storage = ref.read(optimizedStorageServiceProvider);
      final configs = await storage.getServerConfigsStrict();
      // Same server identity: the storage layer keeps the account session
      // when only custom headers change.
      await storage.saveServerConfigs([
        for (final config in configs)
          if (config.id == updatedServer.id) updatedServer else config,
      ]);
      ref.invalidate(serverConfigsProvider);
      ref.invalidate(activeServerProvider);
      await ref.read(activeServerProvider.future);
      if (!mounted) return;

      final authManager = ref.read(authStateManagerProvider.notifier);
      authManager.resetRetryCounter();
      if (result.isFullyAuthenticated) {
        // The proxy WebView completed Open WebUI SSO too; adopt that session
        // the same way the first-time connect flow does.
        final api = ApiService(
          serverConfig: updatedServer,
          workerManager: ref.read(workerManagerProvider),
          authToken: result.jwtToken,
        );
        try {
          final user = await api.getCurrentUser(
            suppressAuthFailureNotification: true,
          );
          await ref
              .read(authActionsProvider)
              .commitPrevalidatedProxySession(
                serverConfig: updatedServer,
                token: result.jwtToken!,
                user: user,
              );
        } finally {
          api.dispose();
        }
      } else {
        await authManager.refresh();
      }
      DebugLogger.auth(
        'Proxy session renewed in place',
        scope: 'auth/connection',
      );
    } catch (error) {
      DebugLogger.error(
        'proxy-reauth-failed',
        scope: 'auth/connection',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (!mounted) return;
      setState(() => _statusMessage = l10n.couldNotConnectGeneric);
    } finally {
      if (mounted) {
        setState(() => _isRetrying = false);
      }
    }
  }

  Future<void> _retryConnection() async {
    final l10n = AppLocalizations.of(context)!;

    setState(() {
      _isRetrying = true;
      _statusMessage = null;
    });

    try {
      final authManager = ref.read(authStateManagerProvider.notifier);
      final authState = ref.read(authStateManagerProvider);
      final hasValidToken = authState.maybeWhen(
        data: (state) => state.hasValidToken,
        orElse: () => false,
      );

      // Reset retry counter for manual retry attempts
      authManager.resetRetryCounter();

      if (hasValidToken) {
        // User has a valid token - just refresh to verify connection
        await authManager.refresh();
      } else {
        // No valid token - attempt silent login with saved credentials
        await authManager.silentLogin();
      }

      // If successful, router will automatically navigate to chat
      if (!mounted) return;

      // Small delay to show loading state
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _statusMessage = l10n.couldNotConnectGeneric;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRetrying = false;
        });
      }
    }
  }

  Future<void> _logout(AppLocalizations l10n) async {
    final keepServerDetails = await showSignOutOptionsDialog(context);

    if (!mounted) return;
    if (keepServerDetails == null) return;

    setState(() {
      _isLoggingOut = true;
      _statusMessage = null;
    });

    try {
      await ref
          .read(signOutCoordinatorProvider)
          .signOut(keepServerDetails: keepServerDetails);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _statusMessage = l10n.couldNotConnectGeneric;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoggingOut = false;
        });
      }
    }
  }

  String _resolveHost(ServerConfig? config) {
    final url = config?.url;
    if (url == null || url.isEmpty) {
      return AppLocalizations.of(context)!.backendChooserOpenWebUITitle;
    }

    try {
      final uri = Uri.parse(url);
      if (uri.host.isNotEmpty) {
        return uri.host;
      }
      return url;
    } catch (_) {
      return url;
    }
  }

  String _statusLabel(ConnectivityStatus? status, AppLocalizations l10n) {
    if (status == null) return l10n.couldNotConnectGeneric;
    switch (status) {
      case ConnectivityStatus.online:
        return l10n.couldNotConnectGeneric;
      case ConnectivityStatus.offline:
        return l10n.pleaseCheckConnection;
    }
  }
}
