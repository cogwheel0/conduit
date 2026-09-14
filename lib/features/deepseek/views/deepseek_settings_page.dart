import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../models/deepseek_config.dart';
import '../models/deepseek_probe.dart';
import '../providers/deepseek_providers.dart';

/// Settings for the optional self-hosted DeepSeek harness (DSH) backend:
/// enable toggle, server URL, trusted host, self-signed certificate trust,
/// and a live connection check against the `dsh web` server root.
///
/// Leaner than the Hermes settings page: DSH authenticates with a host
/// allowlist (no API key), and every field persists as it changes, so there
/// is no draft/save round-trip.
class DeepSeekSettingsPage extends ConsumerStatefulWidget {
  const DeepSeekSettingsPage({super.key, this.isOnboarding = false});

  /// When true, the page is shown as a first-run setup step: the enable
  /// toggle is implicit, and a "Connect" button finishes onboarding into the
  /// app after a successful probe.
  final bool isOnboarding;

  @override
  ConsumerState<DeepSeekSettingsPage> createState() =>
      _DeepSeekSettingsPageState();
}

class _DeepSeekSettingsPageState extends ConsumerState<DeepSeekSettingsPage> {
  late final TextEditingController _urlController;
  late final TextEditingController _trustedHostController;

  @override
  void initState() {
    super.initState();
    final config = ref.read(deepseekConfigProvider);
    _urlController = TextEditingController(text: config.baseUrl);
    _trustedHostController =
        TextEditingController(text: config.trustedHost ?? '');
  }

  @override
  void dispose() {
    _urlController.dispose();
    _trustedHostController.dispose();
    super.dispose();
  }

  /// Toggle the DeepSeek harness. When disabling it while the preference
  /// still points at 'deepseek', reset the preference to 'unset' so the
  /// backend chooser is shown rather than leaving a stale value.
  Future<void> _setDeepseekEnabled(bool value) async {
    await ref.read(deepseekConfigProvider.notifier).setEnabled(value);
    if (!value &&
        ref.read(preferredBackendProvider) == PreferredBackend.deepseek) {
      await ref
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.unset);
    }
  }

  Future<void> _testConnection() =>
      ref.read(deepseekProbeProvider.notifier).runProbe();

  Future<void> _finishOnboarding() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final l10n = AppLocalizations.of(context)!;
    await ref.read(deepseekConfigProvider.notifier).setEnabled(true);
    final result = await ref.read(deepseekProbeProvider.notifier).runProbe();
    if (!mounted) return;
    if (result?.ok ?? false) {
      await ref
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.deepseek);
      if (!mounted) return;
      context.go(Routes.chat);
    } else {
      AdaptiveSnackBar.show(
        context,
        message: result?.error ?? l10n.couldNotConnectGeneric,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  void _leaveOnboarding() {
    FocusManager.instance.primaryFocus?.unfocus();
    context.go(Routes.backendChooser);
  }

  bool get _canProbe =>
      DeepSeekConfig.connectionOrigin(_urlController.text) != null;

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(deepseekConfigProvider);
    final probe = ref.watch(deepseekProbeProvider);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final probing = probe.status == DeepSeekProbeStatus.probing;

    final urlField = AccessibleFormField(
      enabled: !probing,
      label: l10n.deepseekServerUrlTitle,
      hint: 'http://127.0.0.1:3080',
      controller: _urlController,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      onChanged: (value) =>
          ref.read(deepseekConfigProvider.notifier).setBaseUrl(value),
      isRequired: true,
      iosSettingsRow: PlatformInfo.isIOS,
    );
    final trustedHostField = AccessibleFormField(
      enabled: !probing,
      label: l10n.deepseekTrustedHostTitle,
      hint: 'dsh.local',
      controller: _trustedHostController,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      onChanged: (value) =>
          ref.read(deepseekConfigProvider.notifier).setTrustedHost(value),
      iosSettingsRow: PlatformInfo.isIOS,
    );
    final selfSignedRow = UtilityRow(
      title: l10n.allowSelfSignedCertificates,
      subtitle: l10n.allowSelfSignedCertificatesDescription,
      trailing: AdaptiveSwitch(
        value: config.allowSelfSignedCertificates,
        onChanged: (value) => ref
            .read(deepseekConfigProvider.notifier)
            .setAllowSelfSignedCertificates(value),
      ),
      onTap: () => _toggleSelfSigned(!config.allowSelfSignedCertificates),
    );

    final (statusText, statusColor) = _statusPresentation(probe, theme, l10n);
    final probeSection = InsetGroupedSection(
      title: l10n.deepseekProbeTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (probing) ...[
                const CupertinoActivityIndicator(radius: 8),
                const SizedBox(width: Spacing.sm),
              ],
              Expanded(
                child: Text(
                  statusText,
                  style: AppTypography.bodyMediumStyle.copyWith(
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          if (!widget.isOnboarding) ...[
            const SizedBox(height: Spacing.md),
            ConduitButton(
              text: l10n.testDirectConnection,
              isSecondary: true,
              isLoading: probing,
              isFullWidth: true,
              onPressed: _canProbe && !probing ? _testConnection : null,
            ),
          ],
        ],
      ),
    );

    final content = <Widget>[
      if (!widget.isOnboarding)
        InsetGroupedList(
          footer: PlatformInfo.isIOS ? l10n.deepseekEnableSubtitle : null,
          children: [
            UtilityRow(
              title: l10n.deepseekEnableTitle,
              subtitle:
                  PlatformInfo.isIOS ? null : l10n.deepseekEnableSubtitle,
              titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
              trailing: AdaptiveSwitch(
                value: config.enabled,
                onChanged: _setDeepseekEnabled,
              ),
              onTap: () => _setDeepseekEnabled(!config.enabled),
            ),
          ],
        ),
      if (!widget.isOnboarding)
        SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
      if (PlatformInfo.isIOS)
        InsetGroupedList(
          useNativeSurface: true,
          children: [
            urlField,
            trustedHostField,
          ],
        )
      else
        InsetGroupedSection(
          title: l10n.deepseekConnectionDetailsTitle,
          flat: true,
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              urlField,
              const SizedBox(height: Spacing.md),
              trustedHostField,
              const SizedBox(height: Spacing.sm),
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: Text(
                  l10n.deepseekTrustedHostDescription,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
      if (PlatformInfo.isIOS)
        InsetGroupedList(
          useNativeSurface: true,
          children: [
            selfSignedRow,
          ],
        )
      else
        InsetGroupedList(
          children: [
            selfSignedRow,
          ],
        ),
      SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
      probeSection,
    ];

    if (widget.isOnboarding) {
      final failure = _lastFailureMessage(probe, l10n);
      return UtilityPageScaffold.auth(
        title: l10n.backendChooserDeepSeekTitle,
        backNavigation: UtilityBackNavigation(
          label: l10n.back,
          buttonKey: const ValueKey<String>(
            'deepseek-onboarding-back-button',
          ),
          onPressed: _leaveOnboarding,
        ),
        bottomAction: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failure != null) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Text(
                  failure,
                  textAlign: TextAlign.center,
                  style: AppTypography.bodyMediumStyle.copyWith(
                    color: theme.error,
                  ),
                ),
              ),
              const SizedBox(height: Spacing.sm),
            ],
            ConduitButton(
              text: l10n.deepseekConnectAction,
              isFullWidth: true,
              isLoading: probing,
              onPressed: _canProbe && !probing ? _finishOnboarding : null,
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: content,
        ),
      );
    }

    return UtilityPageScaffold.settings(
      title: l10n.deepseekAgentSettingsTitle,
      children: content,
    );
  }

  (String, Color) _statusPresentation(
    DeepSeekProbeState probe,
    ConduitThemeExtension theme,
    AppLocalizations l10n,
  ) {
    return switch (probe.status) {
      DeepSeekProbeStatus.idle =>
        (l10n.deepseekProbeIdle, theme.textSecondary),
      DeepSeekProbeStatus.probing =>
        (l10n.connecting, theme.textSecondary),
      DeepSeekProbeStatus.connected =>
        (l10n.connectedToServer, theme.success),
      DeepSeekProbeStatus.unreachable =>
        (l10n.couldNotConnectGeneric, theme.error),
      DeepSeekProbeStatus.error => (
        probe.lastResult?.error ?? l10n.deepseekProbeInvalid,
        theme.error,
      ),
    };
  }

  void _toggleSelfSigned(bool value) => ref
      .read(deepseekConfigProvider.notifier)
      .setAllowSelfSignedCertificates(value);

  String? _lastFailureMessage(
    DeepSeekProbeState probe,
    AppLocalizations l10n,
  ) {
    final last = probe.lastResult;
    if (probe.status == DeepSeekProbeStatus.probing || last == null) {
      return null;
    }
    if (last.ok) return null;
    return last.error ?? l10n.couldNotConnectGeneric;
  }
}