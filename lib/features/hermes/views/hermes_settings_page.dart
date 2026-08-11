import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../auth/widgets/adaptive_auth_scaffold.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../controllers/hermes_connection_controller.dart';
import '../models/hermes_capabilities.dart';
import '../providers/hermes_providers.dart';
import '../services/hermes_connection_service.dart';

/// Settings for the optional direct Hermes Agent backend: enable toggle, server
/// URL, API key, long-term memory key, and a connection test.
class HermesSettingsPage extends ConsumerStatefulWidget {
  const HermesSettingsPage({super.key, this.isOnboarding = false});

  /// When true, the page is shown as a first-run setup step: the enable toggle
  /// is implicit, and a "Finish setup" button completes onboarding into the app.
  final bool isOnboarding;

  @override
  ConsumerState<HermesSettingsPage> createState() => _HermesSettingsPageState();
}

class _HermesSettingsPageState extends ConsumerState<HermesSettingsPage> {
  late final HermesConnectionController _connectionController;

  @override
  void initState() {
    super.initState();
    _connectionController = HermesConnectionController(
      initialConfig: ref.read(hermesConfigProvider),
      gateway: ref.read(hermesConnectionGatewayProvider),
    )..addListener(_handleConnectionChanged);
  }

  void _handleConnectionChanged() {
    if (mounted) setState(() {});
  }

  HermesConnectionMessages _messages(AppLocalizations l10n) =>
      HermesConnectionMessages(
        connecting: l10n.connecting,
        connected: l10n.connectedToServer,
        unreachable: l10n.couldNotConnectGeneric,
        persistenceFailed: l10n.directConnectionSaveFailed,
        activationFailed: l10n.hermesOnboardingFailed,
      );

  Future<void> _finishOnboarding() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await _connectionController.finishOnboarding(
      saved: ref.read(hermesConfigProvider),
      messages: _messages(l10n),
    );
    if (!mounted) return;
    if (result.outcome == HermesConnectionOutcome.success) {
      context.go(Routes.chat);
    }
  }

  void _leaveOnboarding() {
    _connectionController.cancelPendingOperation();
    context.go(Routes.backendChooser);
  }

  @override
  void dispose() {
    _connectionController.removeListener(_handleConnectionChanged);
    _connectionController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    await _connectionController.save(ref.read(hermesConfigProvider));
  }

  Future<void> _retrySecrets() =>
      ref.read(hermesConfigProvider.notifier).retrySecrets();

  /// Toggle the Hermes backend. When disabling a Hermes-only backend (no OWUI
  /// server, so the preference is still 'hermes'), reset the preference to
  /// 'unset' so the backend chooser is shown rather than leaving a stale value.
  Future<void> _setHermesEnabled(bool value) async {
    await ref.read(hermesConfigProvider.notifier).setEnabled(value);
    if (!value &&
        ref.read(preferredBackendProvider) == PreferredBackend.hermes) {
      await ref
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.unset);
    }
  }

  Future<void> _testConnection() async {
    await _connectionController.testConnection(
      saved: ref.read(hermesConfigProvider),
      messages: _messages(AppLocalizations.of(context)!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(hermesConfigProvider);
    final secretsError = ref.watch(hermesSecretsErrorProvider);
    final secretsLoading = ref.watch(hermesSecretsLoadingProvider);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final urlError = switch (_connectionController.validationIssue) {
      HermesConnectionValidationIssue.invalidUrl =>
        l10n.directConnectionUrlInvalid,
      HermesConnectionValidationIssue.credentialsReentryRequired =>
        l10n.directConnectionCredentialsReentryRequired,
      HermesConnectionValidationIssue.persistenceFailed =>
        l10n.directConnectionSaveFailed,
      null => null,
    };

    final content = <Widget>[
      if (secretsError != null)
        Container(
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
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              ConduitButton(
                text: l10n.retry,
                isSecondary: true,
                isLoading: secretsLoading,
                onPressed: secretsLoading ? null : _retrySecrets,
              ),
            ],
          ),
        ),
      UtilityIdentityHeader(
        leading: ConnectionMark(
          color: theme.surfaceContainerHighest,
          child: Image.asset(
            'assets/icons/hermes_agent.png',
            width: 28,
            height: 28,
            fit: BoxFit.contain,
            color: theme.textPrimary,
            colorBlendMode: BlendMode.srcIn,
            filterQuality: FilterQuality.medium,
            excludeFromSemantics: true,
          ),
        ),
        title: widget.isOnboarding
            ? l10n.backendChooserHermesTitle
            : l10n.hermesAgentSettingsTitle,
        subtitle: widget.isOnboarding
            ? l10n.backendChooserHermesSubtitle
            : l10n.hermesAgentSettingsSubtitle,
      ),
      const SizedBox(height: Spacing.xl),
      if (!widget.isOnboarding) ...[
        InsetGroupedSection(
          title: l10n.enabledLabel,
          child: InkWell(
            onTap: () => _setHermesEnabled(!config.enabled),
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.hermesEnableTitle,
                        style: AppTypography.bodyMediumStyle.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: Spacing.xxs),
                      Text(
                        l10n.hermesEnableSubtitle,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.md),
                AdaptiveSwitch(
                  value: config.enabled,
                  onChanged: _setHermesEnabled,
                ),
              ],
            ),
          ),
        ),
        if (config.enabled && _capabilities.jobs) ...[
          const SizedBox(height: Spacing.lg),
          InsetGroupedSection(
            title: l10n.hermesScheduledAgentsTitle,
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: UtilitySelectionRow(
              leading: _badge(context, Icons.schedule),
              title: l10n.hermesScheduledAgentsTitle,
              subtitle: l10n.hermesReviewSchedules,
              selected: false,
              showSelectionIndicator: false,
              trailing: Icon(
                context.usesCupertinoChrome
                    ? CupertinoIcons.chevron_forward
                    : Icons.chevron_right,
                color: theme.iconSecondary,
                size: IconSize.small,
              ),
              onTap: () => context.pushNamed(RouteNames.hermesJobs),
            ),
          ),
        ],
        const SizedBox(height: Spacing.lg),
      ],
      InsetGroupedSection(
        title: l10n.hermesConnectionDetailsTitle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AccessibleFormField(
              enabled: !_connectionController.operation.isBusy,
              label: l10n.hermesServerUrlTitle,
              hint: 'http://192.168.1.10:8642',
              controller: _connectionController.url,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              errorText: urlError,
              onChanged: (_) => _connectionController.markUrlChanged(),
            ),
            const SizedBox(height: Spacing.md),
            AccessibleFormField(
              enabled: !_connectionController.operation.isBusy,
              label: l10n.hermesApiKeyTitle,
              hint: config.apiKey == null || config.apiKey!.isEmpty
                  ? l10n.hermesApiKeyPlaceholder
                  : l10n.hermesConfiguredReplacePlaceholder,
              obscureText: true,
              controller: _connectionController.apiKey,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              onChanged: (_) => _connectionController.markApiKeyChanged(),
            ),
          ],
        ),
      ),
      const SizedBox(height: Spacing.lg),
      UtilityDisclosureSection(
        key: const ValueKey<String>('hermes-memory-key-disclosure'),
        title: l10n.hermesMemoryKeyTitle,
        subtitle: l10n.hermesMemoryKeyShortDescription,
        leading: Icon(
          context.usesCupertinoChrome
              ? CupertinoIcons.person_crop_circle
              : Icons.key_outlined,
          color: theme.iconSecondary,
          size: IconSize.medium,
        ),
        expanded: _connectionController.showMemoryKey,
        onChanged: _connectionController.setShowMemoryKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AccessibleFormField(
              enabled: !_connectionController.operation.isBusy,
              label: l10n.hermesMemoryKeyTitle,
              hint: config.sessionKey == null || config.sessionKey!.isEmpty
                  ? l10n.hermesMemoryKeyPlaceholder
                  : l10n.hermesConfiguredReplacePlaceholder,
              obscureText: true,
              controller: _connectionController.sessionKey,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              onChanged: (_) => _connectionController.markSessionKeyChanged(),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              l10n.hermesMemoryKeyDescription,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ],
        ),
      ),
      if (!widget.isOnboarding) ...[
        const SizedBox(height: Spacing.lg),
        Wrap(
          spacing: Spacing.md,
          runSpacing: Spacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConduitButton(
              text: l10n.save,
              isLoading:
                  _connectionController.operation ==
                  HermesConnectionOperation.saving,
              onPressed:
                  _connectionController.draftIsUsable(config) &&
                      !_connectionController.operation.isBusy
                  ? _saveSettings
                  : null,
            ),
            ConduitButton(
              text: l10n.testDirectConnection,
              isSecondary: true,
              isLoading:
                  _connectionController.operation ==
                  HermesConnectionOperation.testing,
              useNativeLabel: true,
              onPressed:
                  _connectionController.draftIsUsable(config) &&
                      !_connectionController.operation.isBusy
                  ? _testConnection
                  : null,
            ),
            if (_connectionController.operation ==
                    HermesConnectionOperation.saved &&
                !_connectionController.attempt.isVisible)
              ConnectionAttemptBanner(
                state: ConnectionAttemptState.connected(l10n.saved),
              )
            else if (_connectionController.attempt.isVisible)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: ConnectionAttemptBanner(
                  state: _connectionController.attempt,
                ),
              ),
          ],
        ),
      ],
      if (config.isUsable) ...[
        const SizedBox(height: Spacing.xl),
        _capabilitiesSection(),
        const SizedBox(height: Spacing.lg),
        _toolsetsSection(),
        const SizedBox(height: Spacing.lg),
        _serverStatusSection(),
      ],
    ];

    if (widget.isOnboarding) {
      return AdaptiveAuthScaffold(
        title: l10n.backendChooserHermesTitle,
        backLabel: l10n.back,
        backButtonKey: const ValueKey<String>('hermes-onboarding-back-button'),
        onBack: _leaveOnboarding,
        bottomAction: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConnectionAttemptBanner(state: _connectionController.attempt),
            if (_connectionController.attempt.isVisible)
              const SizedBox(height: Spacing.sm),
            ConduitButton(
              text: l10n.hermesConnectAction,
              isFullWidth: true,
              isLoading:
                  _connectionController.operation ==
                  HermesConnectionOperation.finishing,
              useNativeLabel: true,
              onPressed:
                  _connectionController.draftIsUsable(config) &&
                      !_connectionController.operation.isBusy
                  ? _finishOnboarding
                  : null,
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: content,
        ),
      );
    }

    return SettingsPageScaffold(
      title: l10n.hermesAgentSettingsTitle,
      children: content,
    );
  }

  HermesCapabilities get _capabilities =>
      ref.watch(hermesCapabilitiesProvider).asData?.value ??
      HermesCapabilities.enabledByDefault;

  Widget _capabilitiesSection() {
    final caps = _capabilities;
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedSection(
      title: l10n.hermesCapabilitiesTitle,
      child: Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.xs,
        children: [
          _capabilityChip(l10n.hermesCapabilityApproval, caps.runApproval),
          _capabilityChip(l10n.hermesCapabilitySkills, caps.skills),
          _capabilityChip(l10n.hermesCapabilityToolsets, caps.toolsets),
          _capabilityChip(l10n.hermesCapabilityJobs, caps.jobs),
          _capabilityChip(l10n.hermesCapabilitySessions, caps.sessions),
        ],
      ),
    );
  }

  Widget _capabilityChip(String label, bool enabled) {
    final theme = context.conduitTheme;
    final color = enabled ? theme.success : theme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppBorderRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(enabled ? Icons.check : Icons.remove, size: 14, color: color),
          const SizedBox(width: Spacing.xs),
          Text(label, style: AppTypography.captionStyle.copyWith(color: color)),
        ],
      ),
    );
  }

  Widget _toolsetsSection() {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final toolsetsAsync = ref.watch(hermesToolsetsProvider);
    return InsetGroupedSection(
      title: l10n.hermesCapabilityToolsets,
      child: toolsetsAsync.when(
        data: (toolsets) {
          if (toolsets.isEmpty) {
            return Text(
              l10n.hermesNoToolsets,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final toolset in toolsets)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.xs),
                  child: Text(
                    '${toolset.label}  ·  ${l10n.hermesToolCount(toolset.tools.length)}'
                    '${toolset.enabled ? '' : ' (${l10n.disabledLabel})'}',
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.textPrimary,
                    ),
                  ),
                ),
            ],
          );
        },
        loading: () => const SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        error: (_, _) => Text(
          l10n.directConnectionUnavailableLabel,
          style: AppTypography.bodySmallStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _serverStatusSection() {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final statusAsync = ref.watch(hermesServerStatusProvider);
    return InsetGroupedSection(
      title: l10n.hermesServerStatusTitle,
      child: statusAsync.when(
        data: (status) {
          final entries = status.entries
              .where(
                (e) => e.value is num || e.value is String || e.value is bool,
              )
              .toList();
          if (entries.isEmpty) {
            return Text(
              l10n.hermesNoServerStatus,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.xs),
                  child: Text(
                    '${_humanize(entry.key)}: ${entry.value}',
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.textPrimary,
                    ),
                  ),
                ),
            ],
          );
        },
        loading: () => const SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        error: (_, _) => Text(
          l10n.directConnectionUnavailableLabel,
          style: AppTypography.bodySmallStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
      ),
    );
  }

  String _humanize(String key) {
    return key
        .replaceAll('_', ' ')
        .replaceFirstMapped(RegExp('^.'), (m) => m.group(0)!.toUpperCase());
  }

  Widget _badge(BuildContext context, IconData icon) {
    final theme = context.conduitTheme;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: theme.buttonPrimary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppBorderRadius.sm),
      ),
      child: Icon(icon, size: 18, color: theme.buttonPrimary),
    );
  }
}
