import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../profile/widgets/customization_tile.dart';
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
      error: error,
    );
    return (success: false, error: error);
  }
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
  bool? _testResult;
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
    if (widget.isOnboarding) {
      // Onboarding implies enabling; the toggle is hidden in this mode.
      ref.read(hermesConfigProvider.notifier).setEnabled(true);
    }
  }

  Future<void> _finishOnboarding() async {
    if (_finishing || _testing) return;
    setState(() {
      _finishing = true;
      _onboardingError = null;
    });

    if (!await _commitConnection()) {
      if (mounted) setState(() => _finishing = false);
      return;
    }
    if (!mounted) return;

    final notifier = ref.read(hermesConfigProvider.notifier);
    final result = await completeHermesOnboarding(
      enable: () => notifier.setEnabled(true),
      ensureSessionKey: () async {
        await notifier.ensureSessionKey();
      },
      selectHermes: () => ref
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.hermes),
    );
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _finishing = false;
        _onboardingError =
            'Could not finish Hermes setup. Check secure storage and try again.';
      });
      return;
    }
    context.go(Routes.chat);
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
      setState(() => _urlError = 'Use a valid http:// or https:// server URL');
      return false;
    }
    final originChanged = _originChanged(config);
    if ((originChanged || _apiKeyDirty) &&
        _apiKeyController.text.trim().isEmpty) {
      setState(() {
        _urlError = originChanged
            ? 'Enter the API key for the new server'
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
        setState(() => _urlError = 'Could not save Hermes settings');
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
      _testResult = null;
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
      _testResult = ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(hermesConfigProvider);
    final secretsError = ref.watch(hermesSecretsErrorProvider);
    final secretsLoading = ref.watch(hermesSecretsLoadingProvider);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return SettingsPageScaffold(
      title: 'Hermes Agent',
      children: [
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
        if (widget.isOnboarding)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.lg),
            child: Text(
              'Enter your self-hosted Hermes agent\'s address and API key to '
              'start using it. You can add an Open WebUI server later in '
              'settings.',
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          )
        else ...[
          CustomizationTile(
            title: 'Enable Hermes Agent',
            subtitle:
                'Connect directly to your self-hosted Hermes agent and use it '
                'as a model in the picker.',
            trailing: AdaptiveSwitch(
              value: config.enabled,
              onChanged: (value) => _setHermesEnabled(value),
            ),
            showChevron: false,
            onTap: () => _setHermesEnabled(!config.enabled),
          ),
          if (config.enabled && _capabilities.jobs) ...[
            const SizedBox(height: Spacing.sm),
            CustomizationTile(
              leading: _badge(context, Icons.schedule),
              title: 'Scheduled Agents',
              subtitle: 'Run prompts on a cron schedule.',
              onTap: () => context.pushNamed(RouteNames.hermesJobs),
            ),
          ],
          const SizedBox(height: Spacing.lg),
        ],
        ConduitInput(
          label: 'Server URL',
          hint: 'http://192.168.1.10:8642',
          controller: _urlController,
          keyboardType: TextInputType.url,
          errorText: _urlError,
          onChanged: (value) {
            setState(() {
              _urlError = null;
              _saved = false;
              _testResult = null;
            });
          },
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          label: 'API key',
          hint: config.apiKey == null || config.apiKey!.isEmpty
              ? 'Enter API_SERVER_KEY'
              : 'Configured — enter to replace',
          obscureText: true,
          controller: _apiKeyController,
          onChanged: (value) {
            setState(() {
              _apiKeyDirty = true;
              _saved = false;
              _testResult = null;
            });
          },
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          label: 'Memory key (optional)',
          hint: config.sessionKey == null || config.sessionKey!.isEmpty
              ? 'Auto-generated if left blank'
              : 'Configured — enter to replace',
          obscureText: true,
          controller: _sessionKeyController,
          onChanged: (value) => setState(() {
            _sessionKeyDirty = true;
            _saved = false;
          }),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          'The memory key scopes the agent\'s long-term memory to you '
          '(X-Hermes-Session-Key). A stable key is generated automatically the '
          'first time you chat if you leave this blank.',
          style: AppTypography.captionStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
        const SizedBox(height: Spacing.lg),
        Row(
          children: [
            if (!widget.isOnboarding) ...[
              ConduitButton(
                text: 'Save',
                isLoading: _saving,
                onPressed: _draftIsUsable(config) ? _saveSettings : null,
              ),
              const SizedBox(width: Spacing.md),
            ],
            ConduitButton(
              text: 'Test connection',
              isSecondary: true,
              isLoading: _testing,
              onPressed: _draftIsUsable(config) && !_saving && !_finishing
                  ? _testConnection
                  : null,
            ),
            const SizedBox(width: Spacing.md),
            if (_testResult != null || _saved)
              Expanded(
                child: Text(
                  _testResult == null
                      ? 'Saved ✓'
                      : _testResult == true
                      ? 'Connected ✓'
                      : 'Could not reach the server',
                  style: AppTypography.standard.copyWith(
                    color: _testResult == false ? theme.error : theme.success,
                  ),
                ),
              ),
          ],
        ),
        if (widget.isOnboarding) ...[
          const SizedBox(height: Spacing.lg),
          ConduitButton(
            text: 'Finish setup',
            icon: Icons.check,
            isFullWidth: true,
            isLoading: _finishing,
            onPressed:
                _draftIsUsable(config) && !_saving && !_finishing && !_testing
                ? _finishOnboarding
                : null,
          ),
          if (_onboardingError != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              _onboardingError!,
              textAlign: TextAlign.center,
              style: AppTypography.bodySmallStyle.copyWith(color: theme.error),
            ),
          ],
        ],
        if (config.isUsable) ...[
          const SizedBox(height: Spacing.xl),
          _capabilitiesSection(),
          const SizedBox(height: Spacing.lg),
          _toolsetsSection(),
          const SizedBox(height: Spacing.lg),
          _serverStatusSection(),
        ],
      ],
    );
  }

  HermesCapabilities get _capabilities =>
      ref.watch(hermesCapabilitiesProvider).asData?.value ??
      HermesCapabilities.enabledByDefault;

  Widget _capabilitiesSection() {
    final caps = _capabilities;
    return _Section(
      title: 'Server capabilities',
      child: Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.xs,
        children: [
          _capabilityChip('Approval gates', caps.runApproval),
          _capabilityChip('Skills', caps.skills),
          _capabilityChip('Toolsets', caps.toolsets),
          _capabilityChip('Scheduled jobs', caps.jobs),
          _capabilityChip('Sessions', caps.sessions),
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
    final toolsetsAsync = ref.watch(hermesToolsetsProvider);
    return _Section(
      title: 'Toolsets',
      child: toolsetsAsync.when(
        data: (toolsets) {
          if (toolsets.isEmpty) {
            return Text(
              'No toolsets reported.',
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
                    '${toolset.label}  ·  ${toolset.tools.length} tools'
                    '${toolset.enabled ? '' : ' (disabled)'}',
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
          'Unavailable.',
          style: AppTypography.bodySmallStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _serverStatusSection() {
    final theme = context.conduitTheme;
    final statusAsync = ref.watch(hermesServerStatusProvider);
    return _Section(
      title: 'Server status',
      child: statusAsync.when(
        data: (status) {
          final entries = status.entries
              .where(
                (e) => e.value is num || e.value is String || e.value is bool,
              )
              .toList();
          if (entries.isEmpty) {
            return Text(
              'No status reported.',
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
          'Unavailable.',
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

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: AppTypography.captionStyle.copyWith(
            color: theme.textSecondary,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        child,
      ],
    );
  }
}
