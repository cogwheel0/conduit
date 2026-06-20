import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../profile/widgets/customization_tile.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../models/hermes_capabilities.dart';
import '../providers/hermes_providers.dart';

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

  bool _testing = false;
  bool? _testResult;

  @override
  void initState() {
    super.initState();
    final config = ref.read(hermesConfigProvider);
    _urlController = TextEditingController(text: config.baseUrl);
    if (widget.isOnboarding) {
      // Onboarding implies enabling; the toggle is hidden in this mode.
      ref.read(hermesConfigProvider.notifier).setEnabled(true);
    }
  }

  Future<void> _finishOnboarding() async {
    final notifier = ref.read(hermesConfigProvider.notifier);
    await notifier.setEnabled(true);
    await notifier.ensureSessionKey();
    await ref
        .read(preferredBackendProvider.notifier)
        .set(PreferredBackend.hermes);
    if (!mounted) return;
    context.go(Routes.chat);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    final service = ref.read(hermesApiServiceProvider);
    if (service == null) {
      setState(() => _testResult = false);
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    bool ok;
    try {
      ok = await service.health();
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
    final notifier = ref.read(hermesConfigProvider.notifier);
    final theme = context.conduitTheme;

    return SettingsPageScaffold(
      title: 'Hermes Agent',
      children: [
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
            leading: _badge(context, Icons.smart_toy_outlined),
            title: 'Enable Hermes Agent',
            subtitle:
                'Connect directly to your self-hosted Hermes agent and use it '
                'as a model in the picker.',
            trailing: AdaptiveSwitch(
              value: config.enabled,
              onChanged: (value) => notifier.setEnabled(value),
            ),
            showChevron: false,
            onTap: () => notifier.setEnabled(!config.enabled),
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
          onChanged: (value) {
            notifier.setBaseUrl(value);
            if (_testResult != null) setState(() => _testResult = null);
          },
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          label: 'API key',
          hint: config.apiKey == null || config.apiKey!.isEmpty
              ? 'Enter API_SERVER_KEY'
              : 'Configured — enter to replace',
          obscureText: true,
          onChanged: (value) {
            notifier.setApiKey(value);
            if (_testResult != null) setState(() => _testResult = null);
          },
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          label: 'Memory key (optional)',
          hint: config.sessionKey == null || config.sessionKey!.isEmpty
              ? 'Auto-generated if left blank'
              : 'Configured — enter to replace',
          obscureText: true,
          onChanged: (value) => notifier.setSessionKey(value),
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
            ConduitButton(
              text: 'Test connection',
              isSecondary: true,
              isLoading: _testing,
              onPressed: config.isUsable ? _testConnection : null,
            ),
            const SizedBox(width: Spacing.md),
            if (_testResult != null)
              Expanded(
                child: Text(
                  _testResult == true
                      ? 'Connected ✓'
                      : 'Could not reach the server',
                  style: AppTypography.standard.copyWith(
                    color: _testResult == true ? theme.success : theme.error,
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
            onPressed: config.isUsable ? _finishOnboarding : null,
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
