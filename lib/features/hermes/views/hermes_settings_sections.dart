import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/utility_components.dart';
import '../models/hermes_capabilities.dart';
import '../models/hermes_config.dart';
import '../providers/hermes_providers.dart';
import '../services/hermes_desktop_api_service.dart';

class HermesCapabilitiesSection extends ConsumerWidget {
  const HermesCapabilitiesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(hermesConfigProvider);
    final capabilities =
        ref.watch(hermesCapabilitiesProvider).asData?.value ??
        (config.mode == HermesBackendMode.desktopGateway
            ? HermesCapabilities.desktopCoreOnly
            : HermesCapabilities.enabledByDefault);
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedSection(
      title: l10n.hermesCapabilitiesTitle,
      child: Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.xs,
        children: [
          _CapabilityChip(
            l10n.hermesCapabilityApproval,
            capabilities.runApproval,
          ),
          _CapabilityChip(l10n.hermesCapabilitySkills, capabilities.skills),
          _CapabilityChip(l10n.hermesCapabilityToolsets, capabilities.toolsets),
          _CapabilityChip(l10n.hermesCapabilityJobs, capabilities.jobs),
          _CapabilityChip(l10n.hermesCapabilitySessions, capabilities.sessions),
        ],
      ),
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip(this.label, this.enabled);

  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
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
}

class HermesToolsetsSection extends ConsumerStatefulWidget {
  const HermesToolsetsSection({super.key});

  @override
  ConsumerState<HermesToolsetsSection> createState() =>
      _HermesToolsetsSectionState();
}

class _HermesToolsetsSectionState extends ConsumerState<HermesToolsetsSection> {
  final Set<String> _pending = {};

  Future<void> _configure(String name, bool enabled) async {
    if (!_pending.add(name)) return;
    setState(() {});
    try {
      final service = ref.read(hermesApiServiceProvider);
      if (service is! HermesDesktopApiService) return;
      await service.configureTools([name], enabled: enabled);
      ref.invalidate(hermesToolsetsProvider);
    } catch (error) {
      DebugLogger.warning(
        'toolset-update-failed',
        scope: 'hermes/settings',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.hermesToolsetUpdateFailed,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pending.remove(name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final desktop =
        ref.watch(hermesConfigProvider).mode ==
        HermesBackendMode.desktopGateway;
    return InsetGroupedSection(
      title: l10n.hermesCapabilityToolsets,
      child: ref
          .watch(hermesToolsetsProvider)
          .when(
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
                  Text(
                    l10n.hermesToolsetsNewSessions,
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                  for (final toolset in toolsets)
                    UtilityRow(
                      title: toolset.label,
                      subtitle: l10n.hermesToolCount(toolset.tools.length),
                      trailing: desktop
                          ? AdaptiveSwitch(
                              value: toolset.enabled,
                              onChanged: _pending.contains(toolset.name)
                                  ? null
                                  : (enabled) =>
                                        _configure(toolset.name, enabled),
                            )
                          : null,
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
}

class HermesDesktopManagementSection extends ConsumerStatefulWidget {
  const HermesDesktopManagementSection({super.key});

  @override
  ConsumerState<HermesDesktopManagementSection> createState() =>
      _HermesDesktopManagementSectionState();
}

class _HermesDesktopManagementSectionState
    extends ConsumerState<HermesDesktopManagementSection> {
  bool _pending = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_pending) return;
    setState(() => _pending = true);
    try {
      await action();
    } catch (error) {
      DebugLogger.warning(
        'desktop-action-failed',
        scope: 'hermes/settings',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.hermesActionFailed),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final skills =
        ref.watch(hermesInstalledSkillsProvider).asData?.value ?? const [];
    return InsetGroupedList(
      title: l10n.hermesDesktopGateway,
      children: [
        UtilityRow(
          title: l10n.hermesReloadSkills,
          subtitle: skills.isEmpty
              ? l10n.hermesNoInstalledSkills
              : skills.map((skill) => '/${skill['name']}').join(', '),
          leading: const _SettingsBadge(Icons.refresh),
          onTap: _pending
              ? null
              : () => _run(() async {
                  final service = ref.read(hermesApiServiceProvider);
                  if (service is! HermesDesktopApiService) return;
                  await service.reloadSkills();
                  ref.invalidate(hermesSkillPromptsProvider);
                  ref.invalidate(hermesInstalledSkillsProvider);
                }),
        ),
        UtilityRow(
          title: l10n.hermesMcpServers,
          leading: const _SettingsBadge(Icons.hub_outlined),
          showChevron: true,
          onTap: () => context.pushNamed(RouteNames.hermesMcp),
        ),
        UtilityRow(
          title: l10n.hermesSignOut,
          leading: const _SettingsBadge(Icons.logout),
          onTap: _pending
              ? null
              : () => _run(
                  () =>
                      ref.read(hermesConfigProvider.notifier).signOutDesktop(),
                ),
        ),
      ],
    );
  }
}

class HermesServerStatusSection extends ConsumerWidget {
  const HermesServerStatusSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedSection(
      title: l10n.hermesServerStatusTitle,
      child: ref
          .watch(hermesServerStatusProvider)
          .when(
            data: (status) {
              final entries = status.entries
                  .where(
                    (entry) =>
                        entry.value is num ||
                        entry.value is String ||
                        entry.value is bool,
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

  String _humanize(String key) => key
      .replaceAll('_', ' ')
      .replaceFirstMapped(
        RegExp('^.'),
        (match) => match.group(0)!.toUpperCase(),
      );
}

class _SettingsBadge extends StatelessWidget {
  const _SettingsBadge(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
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
