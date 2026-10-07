import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../widgets/hermes_connection_switcher.dart';
import 'hermes_settings_sections.dart';

/// Hermes Agent settings: the global switch, the saved connections (the
/// active one checked), and the active connection's scheduled agents.
///
/// Tapping an inactive connection switches to it; tapping the active one, or
/// any connection's edit button, opens its editor.
class HermesConnectionsPage extends ConsumerWidget {
  const HermesConnectionsPage({super.key});

  /// Toggle the Hermes backend. When disabling a Hermes-only backend (no OWUI
  /// server, so the preference is still 'hermes'), reset the preference to
  /// 'unset' so the backend chooser is shown rather than leaving a stale value.
  Future<void> _setEnabled(WidgetRef ref, bool value) async {
    await ref.read(hermesConfigProvider.notifier).setEnabled(value);
    if (!value &&
        ref.read(preferredBackendProvider) == PreferredBackend.hermes) {
      await ref
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.unset);
    }
  }

  void _openEditor(BuildContext context, String connectionId) {
    context.pushNamed(
      RouteNames.hermesConnectionEditor,
      pathParameters: {'id': connectionId},
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final config = ref.watch(hermesConfigProvider);
    final connections = ref.watch(hermesConnectionsProvider);
    final capabilities =
        ref.watch(hermesCapabilitiesProvider).asData?.value ??
        (config.mode == HermesBackendMode.desktopGateway
            ? HermesCapabilities.desktopCoreOnly
            : HermesCapabilities.enabledByDefault);
    final gap = SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg);
    void addConnection() => _openEditor(context, Routes.hermesNewConnectionId);

    return UtilityPageScaffold.settings(
      title: l10n.hermesAgentSettingsTitle,
      children: [
        const HermesSecretsErrorBanner(),
        InsetGroupedList(
          footer: PlatformInfo.isIOS ? l10n.hermesEnableSubtitle : null,
          children: [
            UtilityRow(
              title: l10n.hermesEnableTitle,
              subtitle: PlatformInfo.isIOS ? null : l10n.hermesEnableSubtitle,
              titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
              trailing: AdaptiveSwitch(
                value: config.enabled,
                onChanged: (value) => _setEnabled(ref, value),
              ),
              onTap: () => _setEnabled(ref, !config.enabled),
            ),
          ],
        ),
        gap,
        _ConnectionsHeader(onAdd: connections.isEmpty ? null : addConnection),
        const SizedBox(height: Spacing.sm),
        InsetGroupedList(
          useNativeSurface: PlatformInfo.isIOS,
          children: connections.isEmpty
              ? [
                  UtilityRow(
                    key: const ValueKey<String>('hermes-add-first-connection'),
                    title: l10n.hermesNoConnectionsTitle,
                    subtitle: l10n.hermesNoConnectionsSubtitle,
                    titleFontWeight: PlatformInfo.isIOS
                        ? FontWeight.w400
                        : null,
                    trailing: Icon(
                      context.usesCupertinoChrome
                          ? CupertinoIcons.add_circled
                          : Icons.add_circle_outline,
                      color: context.conduitTheme.buttonPrimary,
                      size: IconSize.medium,
                    ),
                    onTap: addConnection,
                  ),
                ]
              : [
                  for (final connection in connections)
                    _ConnectionTile(
                      connection: connection,
                      active: connection.id == config.connectionId,
                      onTap: connection.id == config.connectionId
                          ? () => _openEditor(context, connection.id)
                          : () => switchHermesConnection(
                              context,
                              ref,
                              connection.id,
                            ),
                      onEdit: () => _openEditor(context, connection.id),
                    ),
                ],
        ),
        if (config.enabled && config.isUsable && capabilities.jobs) ...[
          gap,
          InsetGroupedList(
            title: l10n.hermesScheduledAgentsTitle,
            children: [
              UtilityRow(
                leading: SizedBox(
                  width: IconSize.xl,
                  height: IconSize.xl,
                  child: Icon(
                    Icons.schedule,
                    size: IconSize.medium,
                    color: context.conduitTheme.buttonPrimary,
                  ),
                ),
                title: l10n.hermesReviewSchedules,
                showChevron: true,
                onTap: () => context.pushNamed(RouteNames.hermesJobs),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ConnectionsHeader extends StatelessWidget {
  const _ConnectionsHeader({this.onAdd});

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Row(
      children: [
        Expanded(
          child: SettingsSectionHeader(
            title: l10n.hermesConnectionsSectionTitle,
          ),
        ),
        if (onAdd != null) ...[
          const SizedBox(width: Spacing.sm),
          if (PlatformInfo.isIOS)
            AdaptiveButton.child(
              key: const ValueKey<String>('hermes-add-connection'),
              style: AdaptiveButtonStyle.plain,
              useSmoothRectangleBorder: false,
              padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
              minSize: const Size(0, TouchTarget.minimum),
              onPressed: onAdd,
              child: Text(
                l10n.hermesAddConnection,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.buttonPrimary,
                ),
              ),
            )
          else
            ConduitButton(
              key: const ValueKey<String>('hermes-add-connection'),
              text: l10n.hermesAddConnection,
              icon: Icons.add,
              isCompact: true,
              isSecondary: true,
              onPressed: onAdd,
            ),
        ],
      ],
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({
    required this.connection,
    required this.active,
    required this.onTap,
    required this.onEdit,
  });

  final HermesConnectionProfile connection;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return UtilityRow(
      key: ValueKey<String>('hermes-connection-${connection.id}'),
      title: connection.name,
      subtitle: active
          ? '${l10n.hermesActiveConnection} · ${hermesConnectionSummary(connection)}'
          : hermesConnectionSummary(connection),
      subtitleMaxLines: 2,
      titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
      selected: active,
      leading: SizedBox(
        width: IconSize.xl,
        height: IconSize.xl,
        child: active
            ? Icon(
                context.usesCupertinoChrome
                    ? CupertinoIcons.check_mark
                    : Icons.check,
                color: theme.buttonPrimary,
                size: IconSize.medium,
              )
            : null,
      ),
      trailing: AdaptiveButton.child(
        key: ValueKey<String>('hermes-edit-connection-${connection.id}'),
        style: AdaptiveButtonStyle.plain,
        useSmoothRectangleBorder: false,
        padding: EdgeInsets.zero,
        minSize: const Size.square(TouchTarget.comfortable),
        onPressed: onEdit,
        // Inside the button, so the tooltip names the button's own
        // accessibility node.
        child: AdaptiveTooltip(
          message: l10n.edit,
          child: SizedBox.square(
            dimension: TouchTarget.comfortable,
            child: Center(
              child: Icon(
                context.usesCupertinoChrome
                    ? CupertinoIcons.info_circle
                    : Icons.edit_outlined,
                color: theme.buttonPrimary,
                size: IconSize.medium,
              ),
            ),
          ),
        ),
      ),
      preserveTrailingSemantics: true,
      onTap: onTap,
    );
  }
}
