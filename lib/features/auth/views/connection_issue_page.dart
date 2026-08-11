import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_state_manager.dart';
import '../../../core/models/server_config.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../l10n/app_localizations.dart';
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

class _ConnectionIssuePageState extends ConsumerState<ConnectionIssuePage> {
  bool _isLoggingOut = false;
  bool _isRetrying = false;
  String? _statusMessage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connectivity = ref.watch(connectivityStatusProvider);
    final activeServerAsync = ref.watch(activeServerProvider);
    final activeServer = activeServerAsync.asData?.value;

    return UtilityPageScaffold.auth(
      title: l10n.connectionIssueTitle,
      bottomAction: _buildActions(context, l10n),
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

  Widget _buildActions(BuildContext context, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConduitButton(
          text: l10n.retry,
          onPressed: (_isLoggingOut || _isRetrying) ? null : _retryConnection,
          isLoading: _isRetrying,
          icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh_rounded,
          isFullWidth: true,
        ),
        const SizedBox(height: Spacing.sm),
        ConduitButton(
          text: l10n.signOut,
          onPressed: (_isLoggingOut || _isRetrying)
              ? null
              : () => _logout(l10n),
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
