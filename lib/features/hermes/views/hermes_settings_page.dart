import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../auth/widgets/adaptive_auth_scaffold.dart';
import '../../auth/widgets/connection_setup_components.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../models/hermes_capabilities.dart';
import '../models/hermes_config.dart';
import '../providers/hermes_providers.dart';
import '../services/hermes_api_service.dart';

@visibleForTesting
HermesConfig buildHermesConnectionDraft({
  required HermesConfig saved,
  required String baseUrl,
  required bool apiKeyChanged,
  required String apiKey,
  required bool sessionKeyChanged,
  required String sessionKey,
}) {
  final trimmedUrl = baseUrl.trim();
  final originChanged =
      HermesConfigController.connectionOrigin(saved.baseUrl) !=
      HermesConfigController.connectionOrigin(trimmedUrl);
  final trimmedApiKey = apiKey.trim();
  final trimmedSessionKey = sessionKey.trim();
  return HermesConfig(
    enabled: true,
    baseUrl: trimmedUrl,
    apiKey: originChanged || apiKeyChanged
        ? (trimmedApiKey.isEmpty ? null : trimmedApiKey)
        : saved.apiKey,
    sessionKey: originChanged
        ? (sessionKeyChanged && trimmedSessionKey.isNotEmpty
              ? trimmedSessionKey
              : null)
        : sessionKeyChanged
        ? (trimmedSessionKey.isEmpty ? null : trimmedSessionKey)
        : saved.sessionKey,
  );
}

@visibleForTesting
Future<({bool success, Object? error})> completeHermesOnboarding({
  required Future<void> Function() enable,
  required Future<void> Function() ensureSessionKey,
  required Future<void> Function() selectHermes,
}) async {
  try {
    await enable();
    await ensureSessionKey();
    await selectHermes();
    return (success: true, error: null);
  } catch (error) {
    DebugLogger.error(
      'onboarding-failed',
      scope: 'hermes/onboarding',
      data: {'errorType': error.runtimeType.toString()},
    );
    return (success: false, error: error);
  }
}

enum HermesConnectionOnboardingOutcome {
  unreachable,
  persistenceFailed,
  activationFailed,
  success,
}

@immutable
class HermesConnectionOnboardingResult {
  const HermesConnectionOnboardingResult(this.outcome, [this.error]);

  final HermesConnectionOnboardingOutcome outcome;
  final Object? error;
}

@visibleForTesting
Future<HermesConnectionOnboardingResult> connectHermesOnboarding({
  required Future<bool> Function() probe,
  required Future<bool> Function() persist,
  required Future<void> Function() enable,
  required Future<void> Function() ensureSessionKey,
  required Future<void> Function() selectHermes,
  void Function()? onReachable,
}) async {
  try {
    if (!await probe()) {
      return const HermesConnectionOnboardingResult(
        HermesConnectionOnboardingOutcome.unreachable,
      );
    }
  } catch (error) {
    return HermesConnectionOnboardingResult(
      HermesConnectionOnboardingOutcome.unreachable,
      error,
    );
  }
  onReachable?.call();

  try {
    if (!await persist()) {
      return const HermesConnectionOnboardingResult(
        HermesConnectionOnboardingOutcome.persistenceFailed,
      );
    }
  } catch (error) {
    return HermesConnectionOnboardingResult(
      HermesConnectionOnboardingOutcome.persistenceFailed,
      error,
    );
  }

  final activation = await completeHermesOnboarding(
    enable: enable,
    ensureSessionKey: ensureSessionKey,
    selectHermes: selectHermes,
  );
  return HermesConnectionOnboardingResult(
    activation.success
        ? HermesConnectionOnboardingOutcome.success
        : HermesConnectionOnboardingOutcome.activationFailed,
    activation.error,
  );
}

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
  late final TextEditingController _urlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _sessionKeyController;

  bool _testing = false;
  bool _saving = false;
  bool _finishing = false;
  bool _apiKeyDirty = false;
  bool _sessionKeyDirty = false;
  bool _showMemoryKey = false;
  ConnectionAttemptState _attempt = const ConnectionAttemptState.idle();
  bool _saved = false;
  String? _urlError;
  String? _onboardingError;

  @override
  void initState() {
    super.initState();
    final config = ref.read(hermesConfigProvider);
    _urlController = TextEditingController(text: config.baseUrl);
    _apiKeyController = TextEditingController();
    _sessionKeyController = TextEditingController();
  }

  Future<void> _finishOnboarding() async {
    if (_finishing || _testing) return;
    setState(() {
      _finishing = true;
      _onboardingError = null;
      _attempt = ConnectionAttemptState.connecting(
        AppLocalizations.of(context)!.connecting,
      );
    });

    final saved = ref.read(hermesConfigProvider);
    final draft = buildHermesConnectionDraft(
      saved: saved,
      baseUrl: _urlController.text,
      apiKeyChanged: _apiKeyDirty,
      apiKey: _apiKeyController.text,
      sessionKeyChanged: _sessionKeyDirty,
      sessionKey: _sessionKeyController.text,
    );
    final notifier = ref.read(hermesConfigProvider.notifier);
    final result = await connectHermesOnboarding(
      probe: () => testHermesDraftConnection(draft),
      persist: _commitConnection,
      onReachable: () {
        if (!mounted) return;
        setState(
          () => _attempt = ConnectionAttemptState.connected(
            AppLocalizations.of(context)!.connectedToServer,
          ),
        );
      },
      enable: () => notifier.setEnabled(true),
      ensureSessionKey: () async {
        await notifier.ensureSessionKey();
      },
      selectHermes: () => ref
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.hermes),
    );
    if (!mounted) return;
    switch (result.outcome) {
      case HermesConnectionOnboardingOutcome.unreachable:
        setState(() {
          _finishing = false;
          _attempt = ConnectionAttemptState.failed(
            AppLocalizations.of(context)!.couldNotConnectGeneric,
          );
        });
        return;
      case HermesConnectionOnboardingOutcome.persistenceFailed:
        setState(() {
          _finishing = false;
          _attempt = ConnectionAttemptState.failed(
            AppLocalizations.of(context)!.directConnectionSaveFailed,
          );
        });
        return;
      case HermesConnectionOnboardingOutcome.activationFailed:
        setState(() {
          _finishing = false;
          _onboardingError = AppLocalizations.of(
            context,
          )!.hermesOnboardingFailed;
          _attempt = ConnectionAttemptState.failed(_onboardingError!);
        });
        return;
      case HermesConnectionOnboardingOutcome.success:
        context.go(Routes.chat);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiKeyController.dispose();
    _sessionKeyController.dispose();
    super.dispose();
  }

  bool _originChanged(HermesConfig config) =>
      HermesConfigController.connectionOrigin(config.baseUrl) !=
      HermesConfigController.connectionOrigin(_urlController.text);

  bool _draftIsUsable(HermesConfig config) {
    if (HermesConfigController.connectionOrigin(_urlController.text) == null) {
      return false;
    }
    final apiKey = _apiKeyDirty || _originChanged(config)
        ? _apiKeyController.text.trim()
        : config.apiKey?.trim() ?? '';
    return apiKey.isNotEmpty;
  }

  Future<bool> _commitConnection() async {
    if (_saving) return false;
    final config = ref.read(hermesConfigProvider);
    if (HermesConfigController.connectionOrigin(_urlController.text) == null) {
      setState(
        () => _urlError = AppLocalizations.of(
          context,
        )!.directConnectionUrlInvalid,
      );
      return false;
    }
    final originChanged = _originChanged(config);
    if ((originChanged || _apiKeyDirty) &&
        _apiKeyController.text.trim().isEmpty) {
      setState(() {
        _urlError = originChanged
            ? AppLocalizations.of(
                context,
              )!.directConnectionCredentialsReentryRequired
            : null;
      });
      return false;
    }

    setState(() {
      _saving = true;
      _saved = false;
      _urlError = null;
    });
    try {
      await ref
          .read(hermesConfigProvider.notifier)
          .saveConnection(
            baseUrl: _urlController.text,
            apiKeyChanged: originChanged || _apiKeyDirty,
            apiKey: _apiKeyController.text,
            sessionKeyChanged: _sessionKeyDirty,
            sessionKey: _sessionKeyController.text,
          );
      if (!mounted) return true;
      _apiKeyController.clear();
      _sessionKeyController.clear();
      setState(() {
        _apiKeyDirty = false;
        _sessionKeyDirty = false;
        _saved = true;
      });
      return true;
    } catch (_) {
      if (mounted) {
        setState(
          () => _urlError = AppLocalizations.of(
            context,
          )!.directConnectionSaveFailed,
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveSettings() async {
    await _commitConnection();
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
    if (_finishing) return;
    final saved = ref.read(hermesConfigProvider);
    final draft = buildHermesConnectionDraft(
      saved: saved,
      baseUrl: _urlController.text,
      apiKeyChanged: _apiKeyDirty,
      apiKey: _apiKeyController.text,
      sessionKeyChanged: _sessionKeyDirty,
      sessionKey: _sessionKeyController.text,
    );
    setState(() {
      _testing = true;
      _attempt = ConnectionAttemptState.connecting(
        AppLocalizations.of(context)!.connecting,
      );
    });
    bool ok;
    try {
      ok = await testHermesDraftConnection(draft);
    } catch (_) {
      // A thrown health check (network/Dio error) must still clear the spinner.
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _attempt = ok
          ? ConnectionAttemptState.connected(
              AppLocalizations.of(context)!.connectedToServer,
            )
          : ConnectionAttemptState.failed(
              AppLocalizations.of(context)!.couldNotConnectGeneric,
            );
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(hermesConfigProvider);
    final secretsError = ref.watch(hermesSecretsErrorProvider);
    final secretsLoading = ref.watch(hermesSecretsLoadingProvider);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

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
      ConnectionIdentityHeader(
        mark: ConnectionMark(
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
        ConnectionSection(
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
          ConnectionSection(
            title: l10n.hermesScheduledAgentsTitle,
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: ConnectionChoiceRow(
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
      ConnectionSection(
        title: l10n.hermesConnectionDetailsTitle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AccessibleFormField(
              enabled: !_finishing,
              label: l10n.hermesServerUrlTitle,
              hint: 'http://192.168.1.10:8642',
              controller: _urlController,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              errorText: _urlError,
              onChanged: (value) {
                setState(() {
                  _urlError = null;
                  _saved = false;
                  _attempt = const ConnectionAttemptState.idle();
                });
              },
            ),
            const SizedBox(height: Spacing.md),
            AccessibleFormField(
              enabled: !_finishing,
              label: l10n.hermesApiKeyTitle,
              hint: config.apiKey == null || config.apiKey!.isEmpty
                  ? l10n.hermesApiKeyPlaceholder
                  : l10n.hermesConfiguredReplacePlaceholder,
              obscureText: true,
              controller: _apiKeyController,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              onChanged: (value) {
                setState(() {
                  _apiKeyDirty = true;
                  _saved = false;
                  _attempt = const ConnectionAttemptState.idle();
                });
              },
            ),
          ],
        ),
      ),
      const SizedBox(height: Spacing.lg),
      ConnectionDisclosure(
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
        expanded: _showMemoryKey,
        onChanged: (value) => setState(() => _showMemoryKey = value),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AccessibleFormField(
              enabled: !_finishing,
              label: l10n.hermesMemoryKeyTitle,
              hint: config.sessionKey == null || config.sessionKey!.isEmpty
                  ? l10n.hermesMemoryKeyPlaceholder
                  : l10n.hermesConfiguredReplacePlaceholder,
              obscureText: true,
              controller: _sessionKeyController,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              onChanged: (value) => setState(() {
                _sessionKeyDirty = true;
                _saved = false;
                _attempt = const ConnectionAttemptState.idle();
              }),
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
              isLoading: _saving,
              onPressed: _draftIsUsable(config) ? _saveSettings : null,
            ),
            ConduitButton(
              text: l10n.testDirectConnection,
              isSecondary: true,
              isLoading: _testing,
              useNativeLabel: true,
              onPressed: _draftIsUsable(config) && !_saving && !_finishing
                  ? _testConnection
                  : null,
            ),
            if (_saved && !_attempt.isVisible)
              ConnectionAttemptBanner(
                state: ConnectionAttemptState.connected(l10n.saved),
              )
            else if (_attempt.isVisible)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: ConnectionAttemptBanner(state: _attempt),
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
        onBack: () => context.go(Routes.backendChooser),
        bottomAction: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConnectionAttemptBanner(state: _attempt),
            if (_attempt.isVisible) const SizedBox(height: Spacing.sm),
            ConduitButton(
              text: l10n.hermesConnectAction,
              isFullWidth: true,
              isLoading: _finishing,
              useNativeLabel: true,
              onPressed:
                  _draftIsUsable(config) && !_saving && !_finishing && !_testing
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
    return ConnectionSection(
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
    return ConnectionSection(
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
    return ConnectionSection(
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
