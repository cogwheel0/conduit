import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
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
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../models/direct_connection_profile.dart';
import '../models/openwebui_direct_connection.dart';
import '../providers/direct_connection_providers.dart';

const String openWebUiDirectConnectionSourceQueryValue = 'openwebui';

Widget _buildDirectConnectionsScaffold(
  BuildContext context, {
  required bool isOnboarding,
  required List<Widget> children,
  Widget bottomAction = const SizedBox.shrink(),
}) {
  final l10n = AppLocalizations.of(context)!;
  if (isOnboarding) {
    return UtilityPageScaffold.auth(
      title: l10n.backendChooserDirectTitle,
      backLabel: l10n.back,
      backButtonKey: const ValueKey<String>('direct-onboarding-back-button'),
      onBack: () => context.go(Routes.backendChooser),
      bottomAction: bottomAction,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
  return UtilityPageScaffold.settings(
    title: l10n.directConnectionsTitle,
    children: children,
  );
}

class DirectConnectionsPage extends ConsumerStatefulWidget {
  const DirectConnectionsPage({super.key, this.isOnboarding = false});

  final bool isOnboarding;

  @override
  ConsumerState<DirectConnectionsPage> createState() =>
      _DirectConnectionsPageState();
}

class _DirectConnectionsPageState extends ConsumerState<DirectConnectionsPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshOpenWebUiConnections());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshOpenWebUiConnections());
    }
  }

  Future<void> _refreshOpenWebUiConnections() async {
    if (!mounted || !ref.read(openWebUiDirectConnectionsAvailableProvider)) {
      return;
    }
    try {
      await ref.read(openWebUiDirectConnectionsProvider.notifier).reload();
    } catch (_) {
      // The controller publishes its error state for the inline retry UI.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final profiles = ref.watch(directConnectionProfilesProvider);
    final openWebUiConnections = ref.watch(openWebUiDirectConnectionsProvider);
    final showOpenWebUi = ref.watch(
      openWebUiDirectConnectionsAvailableProvider,
    );
    final effectiveProfiles = ref.watch(
      effectiveDirectConnectionProfilesProvider,
    );
    final historyPolicy = ref.watch(directHistoryPolicyProvider);

    return profiles.when(
      loading: () => _buildDirectConnectionsScaffold(
        context,
        isOnboarding: widget.isOnboarding,
        children: const [
          SizedBox(height: Spacing.xxl),
          Center(child: CircularProgressIndicator.adaptive()),
        ],
        bottomAction: ConduitButton(
          text: l10n.finishDirectSetup,
          isFullWidth: true,
          isLoading: true,
          useNativeLabel: true,
        ),
      ),
      error: (error, _) => _buildDirectConnectionsScaffold(
        context,
        isOnboarding: widget.isOnboarding,
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
        openWebUiConnections: openWebUiConnections,
        showOpenWebUi: showOpenWebUi,
        showHistorySync: showOpenWebUi,
        syncWithOpenWebUi:
            historyPolicy == DirectHistoryPolicy.syncWithOpenWebUI,
        isOnboarding: widget.isOnboarding,
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
        onAddOpenWebUi: () => _openEditor(context, 'new', isOpenWebUi: true),
        onEdit: (id) => _openEditor(context, id),
        onEditOpenWebUi: (id) => _openEditor(context, id, isOpenWebUi: true),
        onRetryOpenWebUi: () => unawaited(_refreshOpenWebUiConnections()),
        onFinishOnboarding:
            (effectiveProfiles.value?.any((profile) => profile.isUsable) ??
                false)
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

  Future<void> _openEditor(
    BuildContext context,
    String id, {
    bool isOpenWebUi = false,
  }) async {
    await context.pushNamed(
      RouteNames.directConnectionEditor,
      pathParameters: {'id': id},
      queryParameters: {
        if (widget.isOnboarding) 'onboarding': 'true',
        if (isOpenWebUi) 'source': openWebUiDirectConnectionSourceQueryValue,
      },
      extra: const NativeSheetNavigationOrigin(),
    );
  }
}

class DirectConnectionsContent extends StatelessWidget {
  const DirectConnectionsContent({
    super.key,
    required this.profiles,
    this.openWebUiConnections = const AsyncValue.data(null),
    this.showOpenWebUi = false,
    this.showHistorySync = false,
    required this.syncWithOpenWebUi,
    required this.isOnboarding,
    required this.onSyncChanged,
    required this.onAdd,
    required this.onEdit,
    this.onAddOpenWebUi,
    this.onEditOpenWebUi,
    this.onRetryOpenWebUi,
    this.onFinishOnboarding,
  });

  final List<DirectConnectionProfile> profiles;
  final AsyncValue<OpenWebUiDirectConnectionsSnapshot?> openWebUiConnections;
  final bool showOpenWebUi;
  final bool showHistorySync;
  final bool syncWithOpenWebUi;
  final bool isOnboarding;
  final ValueChanged<bool> onSyncChanged;
  final VoidCallback onAdd;
  final ValueChanged<String> onEdit;
  final VoidCallback? onAddOpenWebUi;
  final ValueChanged<String>? onEditOpenWebUi;
  final VoidCallback? onRetryOpenWebUi;
  final VoidCallback? onFinishOnboarding;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final content = <Widget>[
      UtilityIdentityHeader(
        leading: ConnectionMark(
          child: Icon(
            context.usesCupertinoChrome
                ? CupertinoIcons.link
                : Icons.link_rounded,
            color: theme.buttonPrimary,
            size: IconSize.medium,
          ),
        ),
        title: l10n.directConnectionsTitle,
        subtitle: l10n.directConnectionsCombinedDescription,
      ),
      const SizedBox(height: Spacing.xl),
      if (showHistorySync) ...[
        InsetGroupedSection(
          title: l10n.syncDirectHistory,
          child: InkWell(
            onTap: () => onSyncChanged(!syncWithOpenWebUi),
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.syncDirectHistory,
                        style: theme.bodyMedium?.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: Spacing.xxs),
                      Text(
                        syncWithOpenWebUi
                            ? l10n.syncDirectHistorySubtitle
                            : l10n.directHistoryLocalOnlySubtitle,
                        style: theme.bodySmall?.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.md),
                AdaptiveSwitch(
                  value: syncWithOpenWebUi,
                  onChanged: onSyncChanged,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Spacing.lg),
      ],
      if (showOpenWebUi) ...[
        _OpenWebUiDirectConnectionSection(
          connections: openWebUiConnections,
          onAdd: onAddOpenWebUi ?? onAdd,
          onEdit: onEditOpenWebUi ?? onEdit,
          onRetry: onRetryOpenWebUi,
        ),
        const SizedBox(height: Spacing.xl),
      ],
      _DirectConnectionSection(
        title: l10n.deviceDirectConnectionsSectionTitle,
        description: l10n.deviceDirectConnectionsSectionDescription,
        profiles: profiles,
        sourceLabel: l10n.deviceDirectConnectionSourceLabel,
        emptyTitle: l10n.directProfilesEmptyTitle,
        emptySubtitle: l10n.directProfilesEmptySubtitle,
        onAdd: onAdd,
        onEdit: onEdit,
      ),
    ];

    return _buildDirectConnectionsScaffold(
      context,
      isOnboarding: isOnboarding,
      children: content,
      bottomAction: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onFinishOnboarding == null) ...[
            Text(
              l10n.directSetupRequiresConnection,
              textAlign: TextAlign.center,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
            const SizedBox(height: Spacing.sm),
          ],
          ConduitButton(
            key: const ValueKey<String>('finish-direct-onboarding-button'),
            text: l10n.finishDirectSetup,
            isFullWidth: true,
            useNativeLabel: true,
            onPressed: onFinishOnboarding,
          ),
        ],
      ),
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

class _OpenWebUiDirectConnectionSection extends StatelessWidget {
  const _OpenWebUiDirectConnectionSection({
    required this.connections,
    required this.onAdd,
    required this.onEdit,
    this.onRetry,
  });

  final AsyncValue<OpenWebUiDirectConnectionsSnapshot?> connections;
  final VoidCallback onAdd;
  final ValueChanged<String> onEdit;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final snapshot = connections.value;
    final records =
        snapshot?.records ?? const <OpenWebUiDirectConnectionRecord>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DirectConnectionSectionHeader(
          title: l10n.openWebUiDirectConnectionsSectionTitle,
          description: l10n.openWebUiDirectConnectionsSectionDescription,
          onAdd: records.isNotEmpty ? onAdd : null,
        ),
        const SizedBox(height: Spacing.sm),
        if (connections.isLoading && snapshot == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.xl),
            child: Center(child: CircularProgressIndicator.adaptive()),
          )
        else if (connections.hasError && snapshot == null)
          _OpenWebUiDirectConnectionsError(onRetry: onRetry)
        else if (records.isEmpty) ...[
          _DirectConnectionsEmptyState(
            title: l10n.openWebUiDirectProfilesEmptyTitle,
            subtitle: l10n.openWebUiDirectProfilesEmptySubtitle,
            onAdd: onAdd,
          ),
          if (connections.hasError) ...[
            const SizedBox(height: Spacing.sm),
            _OpenWebUiDirectConnectionsError(onRetry: onRetry),
          ],
        ] else ...[
          _DirectConnectionListSurface(
            children: [
              for (var index = 0; index < records.length; index++)
                _DirectConnectionTile(
                  profile: records[index].profile,
                  sourceLabel: l10n.openWebUiDirectConnectionSourceLabel,
                  isCompatible: records[index].isCompatible,
                  showDivider: index != records.length - 1,
                  onTap: () => onEdit(records[index].profile.id),
                ),
            ],
          ),
          if (connections.hasError) ...[
            const SizedBox(height: Spacing.sm),
            _OpenWebUiDirectConnectionsError(onRetry: onRetry),
          ],
        ],
      ],
    );
  }
}

class _DirectConnectionSection extends StatelessWidget {
  const _DirectConnectionSection({
    required this.title,
    required this.description,
    required this.profiles,
    required this.sourceLabel,
    required this.emptyTitle,
    required this.emptySubtitle,
    required this.onAdd,
    required this.onEdit,
  });

  final String title;
  final String description;
  final List<DirectConnectionProfile> profiles;
  final String sourceLabel;
  final String emptyTitle;
  final String emptySubtitle;
  final VoidCallback onAdd;
  final ValueChanged<String> onEdit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DirectConnectionSectionHeader(
          title: title,
          description: description,
          onAdd: profiles.isNotEmpty ? onAdd : null,
        ),
        const SizedBox(height: Spacing.sm),
        if (profiles.isEmpty)
          _DirectConnectionsEmptyState(
            title: emptyTitle,
            subtitle: emptySubtitle,
            onAdd: onAdd,
          )
        else
          _DirectConnectionListSurface(
            children: [
              for (var index = 0; index < profiles.length; index++)
                _DirectConnectionTile(
                  profile: profiles[index],
                  sourceLabel: sourceLabel,
                  showDivider: index != profiles.length - 1,
                  onTap: () => onEdit(profiles[index].id),
                ),
            ],
          ),
      ],
    );
  }
}

class _DirectConnectionSectionHeader extends StatelessWidget {
  const _DirectConnectionSectionHeader({
    required this.title,
    required this.description,
    this.onAdd,
  });

  final String title;
  final String description;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Expanded(child: SettingsSectionHeader(title: title)),
              if (onAdd != null) ...[
                const SizedBox(width: Spacing.sm),
                if (constraints.maxWidth < 330)
                  ConduitIconButton(
                    icon: Icons.add,
                    tooltip: l10n.addDirectConnection,
                    onPressed: onAdd,
                    isCompact: true,
                    isCircular: false,
                    backgroundColor: theme.surfaceContainer,
                    iconColor: theme.buttonPrimary,
                  )
                else
                  ConduitButton(
                    text: l10n.addDirectConnection,
                    icon: Icons.add,
                    isCompact: true,
                    isSecondary: true,
                    onPressed: onAdd,
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Spacing.xxs),
        Text(
          description,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
      ],
    );
  }
}

class _OpenWebUiDirectConnectionsError extends StatelessWidget {
  const _OpenWebUiDirectConnectionsError({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        children: [
          Icon(Icons.sync_problem_outlined, color: theme.error),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              l10n.openWebUiDirectConnectionsLoadFailed,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: Spacing.sm),
            ConduitButton(
              text: l10n.retry,
              isCompact: true,
              isSecondary: true,
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }
}

class _DirectConnectionsEmptyState extends StatelessWidget {
  const _DirectConnectionsEmptyState({
    required this.title,
    required this.subtitle,
    required this.onAdd,
  });

  final String title;
  final String subtitle;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: theme.surfaceContainer.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.headingSmall?.copyWith(color: theme.textPrimary),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            subtitle,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
          const SizedBox(height: Spacing.md),
          ConduitButton(
            text: l10n.addDirectConnection,
            useNativeLabel: true,
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

class _DirectConnectionTile extends StatelessWidget {
  const _DirectConnectionTile({
    required this.profile,
    required this.sourceLabel,
    required this.onTap,
    this.isCompatible = true,
    this.showDivider = false,
  });

  final DirectConnectionProfile profile;
  final String sourceLabel;
  final bool isCompatible;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final isOllama = profile.adapterKey == kOllamaAdapterKey;
    final provider = isOllama ? l10n.ollama : l10n.openAICompatible;
    final status = !isCompatible
        ? l10n.directConnectionUnavailableLabel
        : profile.enabled
        ? l10n.enabledLabel
        : l10n.disabledLabel;

    return UtilitySelectionRow(
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
        color: profile.enabled && isCompatible
            ? theme.buttonPrimary
            : theme.iconSecondary,
      ),
      title: profile.name,
      subtitle: '$provider · $status\n${profile.baseUrl}',
      selected: false,
      showSelectionIndicator: false,
      showDivider: showDivider,
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            sourceLabel,
            style: theme.bodySmall?.copyWith(color: theme.textTertiary),
          ),
          const SizedBox(height: Spacing.xs),
          Icon(
            context.usesCupertinoChrome
                ? CupertinoIcons.chevron_forward
                : Icons.chevron_right,
            color: theme.iconSecondary,
            size: IconSize.small,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _DirectConnectionListSurface extends StatelessWidget {
  const _DirectConnectionListSurface({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      decoration: BoxDecoration(
        color: theme.surfaceContainer.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: theme.cardBorder, width: BorderWidth.thin),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

String _friendlyLoadError(AppLocalizations l10n, Object error) {
  if (error is FormatException) {
    return l10n.directSavedDataUnreadable;
  }
  return l10n.directSecureStorageUnavailable;
}
