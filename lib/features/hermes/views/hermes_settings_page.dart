import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../controllers/hermes_connection_controller.dart';
import '../models/hermes_capabilities.dart';
import '../models/hermes_config.dart';
import '../providers/hermes_providers.dart';
import '../services/hermes_connection_service.dart';
import 'hermes_desktop_connection_section.dart';
import 'hermes_settings_sections.dart';

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
        saved: l10n.saved,
        unreachable: l10n.couldNotConnectGeneric,
        persistenceFailed: l10n.directConnectionSaveFailed,
        activationFailed: l10n.hermesOnboardingFailed,
      );

  Future<void> _finishOnboarding() async {
    FocusManager.instance.primaryFocus?.unfocus();
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
    _connectionController.cancelPendingOnboarding();
    context.go(Routes.backendChooser);
  }

  @override
  void dispose() {
    _connectionController.removeListener(_handleConnectionChanged);
    _connectionController.dispose();
    super.dispose();
  }

  Future<bool> _saveSettings() async {
    final l10n = AppLocalizations.of(context)!;
    return _connectionController.save(
      ref.read(hermesConfigProvider),
      messages: _messages(l10n),
    );
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
    ref.invalidate(hermesServerStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(hermesConfigProvider);
    final secretsError = ref.watch(hermesSecretsErrorProvider);
    final secretsLoading = ref.watch(hermesSecretsLoadingProvider);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final capabilities =
        ref.watch(hermesCapabilitiesProvider).asData?.value ??
        (config.mode == HermesBackendMode.desktopGateway
            ? HermesCapabilities.desktopCoreOnly
            : HermesCapabilities.enabledByDefault);
    final urlError = switch (_connectionController.validationIssue) {
      HermesConnectionValidationIssue.invalidUrl =>
        l10n.directConnectionUrlInvalid,
      HermesConnectionValidationIssue.credentialsReentryRequired =>
        l10n.directConnectionCredentialsReentryRequired,
      null => null,
    };
    final serverUrlField = AccessibleFormField(
      enabled: !_connectionController.operation.isBusy,
      label: l10n.hermesServerUrlTitle,
      hint: 'http://192.168.1.10:8642',
      controller: _connectionController.url,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      errorText: urlError,
      onChanged: (_) => _connectionController.markUrlChanged(),
      isRequired: true,
      iosSettingsRow: PlatformInfo.isIOS,
    );
    final apiKeyField = AccessibleFormField(
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
      isRequired: true,
      iosSettingsRow: PlatformInfo.isIOS,
    );
    final desktopTokenField = AccessibleFormField(
      enabled: !_connectionController.operation.isBusy,
      label: 'Legacy session token',
      hint: config.desktopCredentials?.legacyToken?.isNotEmpty == true
          ? l10n.hermesConfiguredReplacePlaceholder
          : 'Paste the Hermes session token',
      obscureText: true,
      controller: _connectionController.desktopLegacyToken,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      onChanged: (_) => _connectionController.markDesktopLegacyTokenChanged(),
      isRequired:
          _connectionController.desktopAuthKind ==
          HermesDesktopAuthKind.legacyToken,
      iosSettingsRow: PlatformInfo.isIOS,
    );

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
      InsetGroupedSection(
        title: 'Hermes connection mode',
        flat: true,
        padding: EdgeInsets.zero,
        child: AdaptiveSegmentedControl(
          key: const ValueKey<String>('hermes-backend-mode-selector'),
          labels: const ['Responses API', 'Desktop Gateway'],
          selectedIndex:
              _connectionController.mode == HermesBackendMode.responsesApi
              ? 0
              : 1,
          enabled: !_connectionController.operation.isBusy,
          onValueChanged: (index) => _connectionController.setMode(
            index == 0
                ? HermesBackendMode.responsesApi
                : HermesBackendMode.desktopGateway,
          ),
        ),
      ),
      SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
      if (!widget.isOnboarding) ...[
        InsetGroupedList(
          footer: PlatformInfo.isIOS ? l10n.hermesEnableSubtitle : null,
          children: [
            UtilityRow(
              title: l10n.hermesEnableTitle,
              subtitle: PlatformInfo.isIOS ? null : l10n.hermesEnableSubtitle,
              titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
              trailing: AdaptiveSwitch(
                value: config.enabled,
                onChanged: _setHermesEnabled,
              ),
              onTap: () => _setHermesEnabled(!config.enabled),
            ),
          ],
        ),
        if (config.enabled && capabilities.jobs) ...[
          SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
          InsetGroupedList(
            title: l10n.hermesScheduledAgentsTitle,
            children: [
              UtilityRow(
                leading: _badge(context, Icons.schedule),
                title: l10n.hermesReviewSchedules,
                showChevron: true,
                onTap: () => context.pushNamed(RouteNames.hermesJobs),
              ),
            ],
          ),
        ],
        SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
      ],
      if (PlatformInfo.isIOS)
        InsetGroupedList(
          useNativeSurface: true,
          children: [
            serverUrlField,
            if (_connectionController.mode == HermesBackendMode.responsesApi)
              apiKeyField
            else if (_connectionController.desktopAuthKind ==
                HermesDesktopAuthKind.legacyToken)
              desktopTokenField,
          ],
        )
      else
        InsetGroupedSection(
          title: l10n.hermesConnectionDetailsTitle,
          flat: true,
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              serverUrlField,
              if (_connectionController.mode ==
                  HermesBackendMode.responsesApi) ...[
                const SizedBox(height: Spacing.md),
                apiKeyField,
              ] else if (_connectionController.desktopAuthKind ==
                  HermesDesktopAuthKind.legacyToken) ...[
                const SizedBox(height: Spacing.md),
                desktopTokenField,
              ],
            ],
          ),
        ),
      if (_connectionController.mode == HermesBackendMode.desktopGateway) ...[
        SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
        HermesDesktopConnectionSection(
          controller: _connectionController,
          saveSettings: _saveSettings,
          testConnection: _testConnection,
        ),
      ],
      if (_connectionController.mode == HermesBackendMode.responsesApi) ...[
        SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
        UtilityDisclosureSection(
          key: const ValueKey<String>('hermes-memory-key-disclosure'),
          title: l10n.hermesMemoryKeyTitle,
          subtitle: l10n.hermesMemoryKeyShortDescription,
          flat: !PlatformInfo.isIOS,
          useNativeSurface: PlatformInfo.isIOS,
          contentPadding: PlatformInfo.isIOS
              ? EdgeInsets.zero
              : const EdgeInsets.only(top: Spacing.md),
          expanded: _connectionController.showMemoryKey,
          onChanged: _connectionController.setShowMemoryKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AccessibleFormField(
                enabled: !_connectionController.operation.isBusy,
                label: l10n.hermesMemoryKeyFieldLabel,
                hint: config.sessionKey == null || config.sessionKey!.isEmpty
                    ? l10n.hermesMemoryKeyPlaceholder
                    : l10n.hermesConfiguredReplacePlaceholder,
                obscureText: true,
                controller: _connectionController.sessionKey,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                onChanged: (_) => _connectionController.markSessionKeyChanged(),
                iosSettingsRow: PlatformInfo.isIOS,
              ),
              Padding(
                padding: PlatformInfo.isIOS
                    ? const EdgeInsets.fromLTRB(
                        Spacing.md,
                        Spacing.xs,
                        Spacing.md,
                        Spacing.md,
                      )
                    : const EdgeInsets.only(top: Spacing.sm),
                child: Text(
                  l10n.hermesMemoryKeyDescription,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
      if (!widget.isOnboarding) ...[
        SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
        if (PlatformInfo.isIOS)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InsetGroupedList(
                useNativeSurface: true,
                children: [
                  UtilityRow(
                    title: l10n.testDirectConnection,
                    titleFontWeight: FontWeight.w400,
                    foregroundColor: CupertinoColors.activeBlue.resolveFrom(
                      context,
                    ),
                    enabled:
                        _connectionController.draftIsUsable(config) &&
                        !_connectionController.operation.isBusy,
                    status:
                        _connectionController.operation ==
                            HermesConnectionOperation.testing
                        ? const CupertinoActivityIndicator(radius: 8)
                        : null,
                    onTap:
                        _connectionController.draftIsUsable(config) &&
                            !_connectionController.operation.isBusy
                        ? _testConnection
                        : null,
                  ),
                ],
              ),
              if (_connectionController.attempt.isVisible) ...[
                const SizedBox(height: Spacing.sm),
                ConnectionAttemptBanner(state: _connectionController.attempt),
              ],
            ],
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConduitButton(
                text: l10n.testDirectConnection,
                isSecondary: true,
                isLoading:
                    _connectionController.operation ==
                    HermesConnectionOperation.testing,
                isFullWidth: true,
                onPressed:
                    _connectionController.draftIsUsable(config) &&
                        !_connectionController.operation.isBusy
                    ? _testConnection
                    : null,
              ),
              const SizedBox(height: Spacing.sm),
              ConduitButton(
                text: l10n.save,
                isLoading:
                    _connectionController.operation ==
                    HermesConnectionOperation.saving,
                isFullWidth: true,
                onPressed:
                    _connectionController.draftIsUsable(config) &&
                        !_connectionController.operation.isBusy
                    ? _saveSettings
                    : null,
              ),
              if (_connectionController.attempt.isVisible) ...[
                const SizedBox(height: Spacing.sm),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: ConnectionAttemptBanner(
                    state: _connectionController.attempt,
                  ),
                ),
              ],
            ],
          ),
      ],
      if (config.isUsable) ...[
        const SizedBox(height: Spacing.xl),
        const HermesCapabilitiesSection(),
        const SizedBox(height: Spacing.lg),
        const HermesToolsetsSection(),
        if (config.mode == HermesBackendMode.desktopGateway) ...[
          const SizedBox(height: Spacing.lg),
          const HermesDesktopManagementSection(),
        ],
        const SizedBox(height: Spacing.lg),
        const HermesServerStatusSection(),
      ],
    ];

    if (widget.isOnboarding) {
      return UtilityPageScaffold.auth(
        title: l10n.backendChooserHermesTitle,
        backNavigation: UtilityBackNavigation(
          label: l10n.back,
          buttonKey: const ValueKey<String>('hermes-onboarding-back-button'),
          onPressed: _leaveOnboarding,
        ),
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

    return UtilityPageScaffold.settings(
      title: l10n.hermesAgentSettingsTitle,
      trailing: PlatformInfo.isIOS
          ? CupertinoButton(
              key: const ValueKey<String>('hermes-save-toolbar-button'),
              padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
              minimumSize: const Size(0, TouchTarget.minimum),
              onPressed:
                  _connectionController.draftIsUsable(config) &&
                      !_connectionController.operation.isBusy
                  ? _saveSettings
                  : null,
              child:
                  _connectionController.operation ==
                      HermesConnectionOperation.saving
                  ? const CupertinoActivityIndicator(radius: 8)
                  : Text(
                      l10n.save,
                      style: TextStyle(
                        color:
                            _connectionController.draftIsUsable(config) &&
                                !_connectionController.operation.isBusy
                            ? CupertinoColors.activeBlue.resolveFrom(context)
                            : CupertinoColors.inactiveGray.resolveFrom(context),
                      ),
                    ),
            )
          : null,
      children: content,
    );
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
