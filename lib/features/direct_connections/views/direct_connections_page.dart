import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../profile/widgets/customization_tile.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../models/direct_connection_profile.dart';
import '../providers/direct_connection_providers.dart';

class DirectConnectionsPage extends ConsumerWidget {
  const DirectConnectionsPage({super.key, this.isOnboarding = false});

  final bool isOnboarding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final profiles = ref.watch(directConnectionProfilesProvider);
    final historyPolicy = ref.watch(directHistoryPolicyProvider);

    return profiles.when(
      loading: () => SettingsPageScaffold(
        title: l10n.directConnectionsTitle,
        children: const [
          SizedBox(height: Spacing.xxl),
          Center(child: CircularProgressIndicator.adaptive()),
        ],
      ),
      error: (error, _) => SettingsPageScaffold(
        title: l10n.directConnectionsTitle,
        children: [
          DirectConnectionsError(
            message: _friendlyLoadError(l10n, error),
            onRetry: () =>
                ref.read(directConnectionProfilesProvider.notifier).reload(),
          ),
        ],
      ),
      data: (items) => DirectConnectionsContent(
        profiles: items,
        syncWithOpenWebUi:
            historyPolicy == DirectHistoryPolicy.syncWithOpenWebUI,
        isOnboarding: isOnboarding,
        onSyncChanged: (sync) {
          ref
              .read(directHistoryPolicyProvider.notifier)
              .setPolicy(
                sync
                    ? DirectHistoryPolicy.syncWithOpenWebUI
                    : DirectHistoryPolicy.localOnly,
              );
        },
        onAdd: () => _openEditor(context, 'new'),
        onEdit: (id) => _openEditor(context, id),
        onFinishOnboarding: items.any((profile) => profile.isUsable)
            ? () async {
                await ref
                    .read(preferredBackendProvider.notifier)
                    .set(PreferredBackend.direct);
                if (context.mounted) context.go(Routes.chat);
              }
            : null,
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, String id) async {
    await context.pushNamed(
      RouteNames.directConnectionEditor,
      pathParameters: {'id': id},
      queryParameters: {if (isOnboarding) 'onboarding': 'true'},
    );
  }
}

class DirectConnectionsContent extends StatelessWidget {
  const DirectConnectionsContent({
    super.key,
    required this.profiles,
    required this.syncWithOpenWebUi,
    required this.isOnboarding,
    required this.onSyncChanged,
    required this.onAdd,
    required this.onEdit,
    this.onFinishOnboarding,
  });

  final List<DirectConnectionProfile> profiles;
  final bool syncWithOpenWebUi;
  final bool isOnboarding;
  final ValueChanged<bool> onSyncChanged;
  final VoidCallback onAdd;
  final ValueChanged<String> onEdit;
  final VoidCallback? onFinishOnboarding;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return SettingsPageScaffold(
      title: l10n.directConnectionsTitle,
      children: [
        Text(
          l10n.directConnectionsDescription,
          style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.lg),
        CustomizationTile(
          leading: SettingsIconBadge(
            icon: UiUtils.platformIcon(
              ios: CupertinoIcons.arrow_2_circlepath,
              android: Icons.sync_outlined,
            ),
            color: theme.buttonPrimary,
          ),
          title: l10n.syncDirectHistory,
          subtitle: syncWithOpenWebUi
              ? l10n.syncDirectHistorySubtitle
              : l10n.directHistoryLocalOnlySubtitle,
          trailing: AdaptiveSwitch(
            value: syncWithOpenWebUi,
            onChanged: onSyncChanged,
          ),
          showChevron: false,
        ),
        const SizedBox(height: Spacing.lg),
        Row(
          children: [
            Expanded(
              child: SettingsSectionHeader(
                title: l10n.directConnectionsSectionTitle,
              ),
            ),
            ConduitButton(
              text: l10n.addDirectConnection,
              icon: Icons.add,
              isCompact: true,
              isSecondary: true,
              onPressed: onAdd,
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        if (profiles.isEmpty)
          _DirectConnectionsEmptyState(onAdd: onAdd)
        else
          for (var index = 0; index < profiles.length; index++) ...[
            _DirectConnectionTile(
              profile: profiles[index],
              onTap: () => onEdit(profiles[index].id),
            ),
            if (index != profiles.length - 1)
              const SizedBox(height: Spacing.md),
          ],
        if (isOnboarding) ...[
          const SizedBox(height: Spacing.xl),
          ConduitButton(
            text: l10n.finishDirectSetup,
            icon: Icons.arrow_forward,
            isFullWidth: true,
            onPressed: onFinishOnboarding,
          ),
          if (onFinishOnboarding == null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              l10n.directSetupRequiresConnection,
              textAlign: TextAlign.center,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ],
        ],
      ],
    );
  }
}

class DirectConnectionsError extends StatelessWidget {
  const DirectConnectionsError({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        const SizedBox(height: Spacing.xl),
        Text(
          l10n.directConnectionError,
          textAlign: TextAlign.center,
          style: theme.headingSmall?.copyWith(color: theme.textPrimary),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          message,
          textAlign: TextAlign.center,
          style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.lg),
        ConduitButton(
          text: l10n.retry,
          icon: Icons.refresh,
          onPressed: onRetry,
        ),
      ],
    );
  }
}

class _DirectConnectionsEmptyState extends StatelessWidget {
  const _DirectConnectionsEmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.directProfilesEmptyTitle,
            style: theme.headingSmall?.copyWith(color: theme.textPrimary),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            l10n.directProfilesEmptySubtitle,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
          const SizedBox(height: Spacing.md),
          ConduitButton(
            text: l10n.addDirectConnection,
            icon: Icons.add,
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

class _DirectConnectionTile extends StatelessWidget {
  const _DirectConnectionTile({required this.profile, required this.onTap});

  final DirectConnectionProfile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final isOllama = profile.adapterKey == kOllamaAdapterKey;
    final provider = isOllama ? l10n.ollama : l10n.openAICompatible;
    final status = profile.enabled ? l10n.enabledLabel : l10n.disabledLabel;

    return CustomizationTile(
      leading: SettingsIconBadge(
        icon: isOllama
            ? UiUtils.platformIcon(
                ios: CupertinoIcons.desktopcomputer,
                android: Icons.computer_outlined,
              )
            : UiUtils.platformIcon(
                ios: CupertinoIcons.cloud,
                android: Icons.cloud_outlined,
              ),
        color: profile.enabled ? theme.buttonPrimary : theme.iconSecondary,
      ),
      title: profile.name,
      subtitle: '$provider · $status\n${profile.baseUrl}',
      onTap: onTap,
    );
  }
}

String _friendlyLoadError(AppLocalizations l10n, Object error) {
  if (error is FormatException) {
    return l10n.directSavedDataUnreadable;
  }
  return l10n.directSecureStorageUnavailable;
}
