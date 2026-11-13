import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../controllers/hermes_connection_controller.dart';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

/// Custom request headers and TLS trust for the Hermes server, mirroring the
/// equivalent Open WebUI and direct-connection settings. Applies to both
/// backend modes.
class HermesTransportSection extends StatefulWidget {
  const HermesTransportSection({super.key, required this.controller});

  final HermesConnectionController controller;

  @override
  State<HermesTransportSection> createState() => _HermesTransportSectionState();
}

class _HermesTransportSectionState extends State<HermesTransportSection> {
  final _headerName = TextEditingController();
  final _headerValue = TextEditingController();
  String? _headerError;
  late bool _expanded = widget.controller.accessHeaders.isNotEmpty;

  HermesConnectionController get _controller => widget.controller;

  @override
  void dispose() {
    _headerName.dispose();
    _headerValue.dispose();
    super.dispose();
  }

  void _addAccessHeader() {
    final name = _headerName.text.trim();
    if (name.isEmpty) return;
    final error = _controller.setAccessHeaders({
      ..._controller.accessHeaders,
      name: _headerValue.text,
    });
    setState(() {
      _headerError = error;
      if (error == null) {
        _headerName.clear();
        _headerValue.clear();
        // Native PKCE cannot traverse a header-protected gateway.
        if (_controller.mode == HermesBackendMode.desktopGateway &&
            _controller.desktopAuthKind == HermesDesktopAuthKind.nativePkce) {
          _controller.setDesktopAuthKind(HermesDesktopAuthKind.dashboardCookie);
        }
      }
    });
  }

  void _removeAccessHeader(String name) {
    _controller.setAccessHeaders({..._controller.accessHeaders}..remove(name));
    setState(() => _headerError = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return UtilityDisclosureSection(
      key: const ValueKey<String>('hermes-access-headers-disclosure'),
      title: l10n.hermesGatewayAccessHeaders,
      subtitle: l10n.hermesGatewayAccessHeadersHelp,
      leading: Icon(
        context.usesCupertinoChrome
            ? CupertinoIcons.gear_alt
            : Icons.tune_rounded,
        color: theme.iconSecondary,
        size: IconSize.medium,
      ),
      expanded: _expanded,
      onChanged: (value) => setState(() => _expanded = value),
      flat: !PlatformInfo.isIOS,
      useNativeSurface: PlatformInfo.isIOS,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AccessibleFormField(
            label: l10n.headerName,
            controller: _headerName,
            autocorrect: false,
            errorText: _headerError,
          ),
          const SizedBox(height: Spacing.sm),
          AccessibleFormField(
            label: l10n.headerValue,
            controller: _headerValue,
            obscureText: true,
            autocorrect: false,
          ),
          const SizedBox(height: Spacing.sm),
          ConduitButton(
            text: l10n.addHeader,
            isSecondary: true,
            onPressed:
                _controller.accessHeaders.length >=
                    HermesConfig.maxAccessHeaders
                ? null
                : _addAccessHeader,
          ),
          for (final entry in _controller.accessHeaders.entries)
            UtilityRow(
              title: entry.key,
              subtitle: '••••••',
              trailing: ConduitIconButton(
                icon: Icons.close,
                tooltip: l10n.removeHeader,
                onPressed: () => _removeAccessHeader(entry.key),
                isCompact: true,
              ),
            ),
          const SizedBox(height: Spacing.sm),
          UtilityRow(
            key: const ValueKey<String>('hermes-allow-self-signed'),
            title: l10n.allowSelfSignedCertificates,
            subtitle: l10n.allowSelfSignedCertificatesDescription,
            toggled: _controller.allowSelfSignedCertificates,
            trailing: AdaptiveSwitch(
              value: _controller.allowSelfSignedCertificates,
              semanticLabel: l10n.allowSelfSignedCertificates,
              onChanged: _controller.setAllowSelfSignedCertificates,
            ),
            onTap: () => _controller.setAllowSelfSignedCertificates(
              !_controller.allowSelfSignedCertificates,
            ),
          ),
        ],
      ),
    );
  }
}

/// Explains a secure-storage outage that keeps Hermes credentials unreadable
/// and offers a retry. Renders nothing while credentials are readable.
class HermesSecretsErrorBanner extends ConsumerWidget {
  const HermesSecretsErrorBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final secretsError = ref.watch(hermesSecretsErrorProvider);
    if (secretsError == null) return const SizedBox.shrink();
    final secretsLoading = ref.watch(hermesSecretsLoadingProvider);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.lg),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.error.withValues(alpha: 0.08),
        border: Border.all(color: theme.error.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, color: theme.error),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              l10n.hermesSecretsUnavailable,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          ConduitButton(
            text: l10n.retry,
            isSecondary: true,
            isLoading: secretsLoading,
            onPressed: secretsLoading
                ? null
                : () => ref.read(hermesConfigProvider.notifier).retrySecrets(),
          ),
        ],
      ),
    );
  }
}
