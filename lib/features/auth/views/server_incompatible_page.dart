import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/server_config.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/server_version_compat.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';

/// Full-screen blocking gate shown when the connected Open WebUI server reports
/// a version newer than this app build supports (see [ServerVersionCompat]).
///
/// The router redirects every in-app route here while the active server is
/// incompatible, so the user genuinely cannot use the app. From here they can
/// recheck (after downgrading the server) or point the app at a different
/// server.
class ServerIncompatiblePage extends ConsumerStatefulWidget {
  const ServerIncompatiblePage({super.key});

  @override
  ConsumerState<ServerIncompatiblePage> createState() =>
      _ServerIncompatiblePageState();
}

class _ServerIncompatiblePageState
    extends ConsumerState<ServerIncompatiblePage> {
  bool _isRechecking = false;
  String? _statusMessage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final activeServer = ref.watch(activeServerProvider).asData?.value;
    final serverVersion = ref
        .watch(backendConfigProvider)
        .asData
        ?.value
        ?.version;
    final maxVersion = ServerVersionCompat.maxSupportedVersion;

    return ErrorBoundary(
      child: AdaptiveRouteShell(
        bodySafeArea: true,
        body: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.pagePadding,
            vertical: Spacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildHeader(context, l10n),
                          if (activeServer != null) ...[
                            const SizedBox(height: Spacing.sm),
                            _buildServerDetails(context, activeServer),
                          ],
                          const SizedBox(height: Spacing.lg),
                          Text(
                            l10n.serverIncompatibleMessage(
                              _displayVersion(serverVersion),
                              maxVersion,
                            ),
                            textAlign: TextAlign.center,
                            style: context.conduitTheme.bodyMedium?.copyWith(
                              color: context.conduitTheme.textSecondary,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: Spacing.sm),
                          Text(
                            l10n.serverIncompatibleResolution(maxVersion),
                            textAlign: TextAlign.center,
                            style: context.conduitTheme.bodyMedium?.copyWith(
                              color: context.conduitTheme.textSecondary,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _buildActions(context, l10n),
              if (_statusMessage != null) ...[
                const SizedBox(height: Spacing.sm),
                _buildStatusMessage(context, _statusMessage!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppLocalizations l10n) {
    final iconColor = context.conduitTheme.warning;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.1),
            shape: BoxShape.circle,
            border: Border.all(
              color: iconColor.withValues(alpha: 0.2),
              width: BorderWidth.thin,
            ),
          ),
          child: Icon(
            Platform.isIOS
                ? CupertinoIcons.exclamationmark_triangle
                : Icons.warning_amber_rounded,
            color: iconColor,
            size: 28,
          ),
        ),
        const SizedBox(height: Spacing.lg),
        Text(
          l10n.serverIncompatibleTitle,
          textAlign: TextAlign.center,
          style: context.conduitTheme.headingMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: context.conduitTheme.textPrimary,
          ),
        ),
      ],
    );
  }

  Widget _buildServerDetails(BuildContext context, ServerConfig server) {
    final host = _resolveHost(server);

    return Column(
      children: [
        Text(
          host,
          textAlign: TextAlign.center,
          style: context.conduitTheme.bodyMedium?.copyWith(
            color: context.conduitTheme.textPrimary,
            fontFamily: AppTypography.monospaceFontFamily,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          server.url,
          textAlign: TextAlign.center,
          style: context.conduitTheme.bodySmall?.copyWith(
            color: context.conduitTheme.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildActions(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConduitButton(
            text: l10n.serverIncompatibleRecheck,
            onPressed: _isRechecking ? null : _recheck,
            isLoading: _isRechecking,
            icon: Platform.isIOS
                ? CupertinoIcons.refresh
                : Icons.refresh_rounded,
            isFullWidth: true,
          ),
          const SizedBox(height: Spacing.sm),
          ConduitButton(
            text: l10n.serverIncompatibleSwitchServer,
            onPressed: _isRechecking ? null : _switchServer,
            isSecondary: true,
            icon: Platform.isIOS
                ? CupertinoIcons.arrow_2_circlepath
                : Icons.swap_horiz_rounded,
            isFullWidth: true,
            isCompact: true,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusMessage(BuildContext context, String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: context.conduitTheme.bodySmall?.copyWith(
          color: context.conduitTheme.textSecondary,
        ),
      ),
    );
  }

  Future<void> _recheck() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _isRechecking = true;
      _statusMessage = null;
    });

    try {
      // Re-fetch /api/config. If the server was downgraded to a supported
      // version, serverIncompatibleProvider flips and the router redirects
      // away from this page automatically.
      await ref.read(backendConfigProvider.notifier).refresh();
    } catch (_) {
      // Ignore — handled by the still-incompatible message below.
    }

    if (!mounted) return;

    final stillIncompatible = ref.read(serverIncompatibleProvider);
    setState(() {
      _isRechecking = false;
      _statusMessage = stillIncompatible
          ? l10n.serverIncompatibleStillUnsupported
          : null;
    });
  }

  void _switchServer() {
    // The router permits the server-connection route even while the active
    // server is incompatible, so the user can point the app at a different
    // (supported) server from there.
    context.goNamed(RouteNames.serverConnection);
  }

  String _displayVersion(String? version) {
    final trimmed = version?.trim();
    if (trimmed == null || trimmed.isEmpty) return '?';
    return trimmed;
  }

  String _resolveHost(ServerConfig? config) {
    final url = config?.url;
    if (url == null || url.isEmpty) {
      return 'Open WebUI';
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
}

/// Shows a blocking dialog explaining that the just-probed server is newer than
/// this app supports. Used at connection time (before a server is saved) so the
/// user is told why the connection was refused.
///
/// The dialog cannot be dismissed by tapping outside; it has a single
/// acknowledge action that returns the user to the connection form.
Future<void> showServerIncompatibleDialog(
  BuildContext context, {
  required String? serverVersion,
}) {
  final l10n = AppLocalizations.of(context);
  final maxVersion = ServerVersionCompat.maxSupportedVersion;
  final trimmed = serverVersion?.trim();
  final version = (trimmed == null || trimmed.isEmpty) ? '?' : trimmed;

  return ThemedDialogs.show<void>(
    context,
    title: l10n?.serverIncompatibleTitle ?? 'Server not supported',
    barrierDismissible: false,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n?.serverIncompatibleMessage(version, maxVersion) ??
              'This server runs Open WebUI $version, which is newer than '
                  'this app supports (up to $maxVersion).',
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          l10n?.serverIncompatibleResolution(maxVersion) ??
              'Downgrade your server to $maxVersion or earlier, or wait for '
                  'an app update that adds support.',
        ),
      ],
    ),
    actions: [
      ConduitTextButton(
        text: l10n?.ok ?? 'OK',
        onPressed: () => Navigator.of(context).pop(),
        isPrimary: true,
      ),
    ],
  );
}
