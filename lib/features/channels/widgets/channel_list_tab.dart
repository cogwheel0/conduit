import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/models/channel.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/sidebar_primary_circle_button.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../core/services/navigation_service.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../navigation/providers/sidebar_providers.dart';
import '../providers/channel_providers.dart';
import 'channel_form_dialog.dart';

/// Sidebar tab that lists all channels with search and create support.
class ChannelListTab extends ConsumerStatefulWidget {
  const ChannelListTab({super.key});

  @override
  ConsumerState<ChannelListTab> createState() => _ChannelListTabState();
}

class _ChannelListTabState extends ConsumerState<ChannelListTab>
    with AutomaticKeepAliveClientMixin {
  static final _channelRoutePattern = RegExp(r'^/channel/(.+)$');

  String? _activeChannelId;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _activeChannelId = _parseChannelId(_currentPath);
    NavigationService.router.routeInformationProvider.addListener(
      _onRouteChanged,
    );
  }

  @override
  void dispose() {
    NavigationService.router.routeInformationProvider.removeListener(
      _onRouteChanged,
    );
    super.dispose();
  }

  String get _currentPath =>
      NavigationService.router.routeInformationProvider.value.uri.path;

  static String? _parseChannelId(String location) =>
      _channelRoutePattern.firstMatch(location)?.group(1);

  void _onRouteChanged() {
    final newId = _parseChannelId(_currentPath);
    if (newId != _activeChannelId) {
      setState(() => _activeChannelId = newId);
    }
  }

  void _onChannelTap(Channel channel) {
    final isTablet = MediaQuery.of(context).size.shortestSide >= 600;
    if (!isTablet) {
      ResponsiveDrawerLayout.of(context)?.close();
    }
    NavigationService.router.go('/channel/${channel.id}');
  }

  Future<void> _showCreateChannelDialog() async {
    ConduitHaptics.lightImpact();
    final result = await showCreateChannelFormDialog(context);
    if (result == null || !mounted) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;
      final json = await api.createChannel(
        name: result.name,
        type: 'group',
        description: result.description,
        isPrivate: result.isPrivate,
      );
      final channel = Channel.fromJson(json);
      if (!mounted) return;
      ref.read(channelsListProvider.notifier).addChannel(channel);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.channelCreateError),
          ),
        );
      }
    }
  }

  List<ConduitContextMenuAction> _buildChannelActions(Channel channel) {
    final l10n = AppLocalizations.of(context)!;
    if (channel.isDm) {
      return [
        ConduitContextMenuAction(
          cupertinoIcon: CupertinoIcons.xmark,
          materialIcon: Icons.close_rounded,
          label: l10n.channelLeave,
          onSelected: () async => _leaveChannel(channel),
        ),
      ];
    }

    final user = ref.read(currentUserProvider2);
    final canManage =
        user?.role == 'admin' ||
        channel.userId == user?.id ||
        channel.isManager;
    if (!canManage) {
      return [];
    }

    return [
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.gear,
        materialIcon: Icons.settings_rounded,
        label: l10n.channelEdit,
        onSelected: () async => _editChannel(channel),
      ),
    ];
  }

  Future<void> _leaveChannel(Channel channel) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.channelLeave,
      message: l10n.channelLeaveConfirm,
    );
    if (!confirmed || !mounted) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;
      await api.updateMemberActiveStatus(channel.id, isActive: false);
      if (!mounted) return;
      ref.read(channelsListProvider.notifier).removeChannel(channel.id);
      if (_activeChannelId == channel.id) {
        ref.read(activeChannelProvider.notifier).clear();
        NavigationService.router.go(Routes.chat);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'leave-channel-failed',
        scope: 'channels/list-tab',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      _showChannelActionError(l10n.errorMessage);
    }
  }

  Future<void> _editChannel(Channel channel) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showEditChannelFormDialog(context, channel: channel);
    if (result == null || !mounted) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;
      final json = await api.updateChannel(
        channel.id,
        name: result.name,
        description: result.description,
        isPrivate: result.isPrivate,
      );
      final updated = Channel.fromJson(json);
      if (!mounted) return;
      ref.read(channelsListProvider.notifier).updateChannel(updated);
      final activeChannel = ref.read(activeChannelProvider);
      if (activeChannel?.id == updated.id) {
        ref.read(activeChannelProvider.notifier).set(updated);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'edit-channel-failed',
        scope: 'channels/list-tab',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      _showChannelActionError(l10n.errorMessage);
    }
  }

  void _showChannelActionError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final channelsAsync = ref.watch(channelsListProvider);
    final searchController = ref.watch(sidebarSearchFieldControllerProvider);

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: searchController,
      builder: (context, value, _) {
        final queryLower = value.text.trim().toLowerCase();

        return Stack(
          children: [
            Positioned.fill(
              child: channelsAsync.when(
                data: (channels) {
                  final filtered = queryLower.isEmpty
                      ? channels
                      : channels
                            .where(
                              (c) => c.name.toLowerCase().contains(queryLower),
                            )
                            .toList();

                  if (filtered.isEmpty) {
                    return Center(
                      child: Text(
                        l10n.channelEmptyState,
                        style: AppTypography.sidebarSupportingStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    );
                  }

                  return RefreshIndicator(
                    onRefresh: () async {
                      ConduitHaptics.lightImpact();
                      await ref.read(channelsListProvider.notifier).refresh();
                    },
                    child: ListView.builder(
                      itemExtent: 72,
                      itemCount: filtered.length,
                      padding: EdgeInsets.only(
                        top: Spacing.sm,
                        bottom: sidebarPrimaryCircleButtonScrollPadding(
                          context,
                        ),
                      ),
                      itemBuilder: (context, index) {
                        final ch = filtered[index];
                        return _ChannelTile(
                          channel: ch,
                          selected: ch.id == _activeChannelId,
                          onTap: () => _onChannelTap(ch),
                          actions: _buildChannelActions(ch),
                        );
                      },
                    ),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l10n.channelLoadError),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () =>
                            ref.read(channelsListProvider.notifier).refresh(),
                        child: Text(l10n.retry),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.directional(
              textDirection: Directionality.of(context),
              end: Spacing.md,
              bottom: Spacing.md,
              child: SidebarPrimaryCircleButton(
                onPressed: _showCreateChannelDialog,
                icon: UiUtils.newChannelIcon,
                tooltip: l10n.channelCreateTitle,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ChannelTile extends ConsumerWidget {
  const _ChannelTile({
    required this.channel,
    required this.selected,
    required this.onTap,
    required this.actions,
  });

  final Channel channel;
  final bool selected;
  final VoidCallback onTap;
  final List<ConduitContextMenuAction> actions;

  IconData _channelIcon() {
    if (channel.isDm) return Icons.person_outline;
    if (channel.isGroup) return Icons.group_outlined;
    return channel.isPrivate ? Icons.lock_outlined : Icons.tag;
  }

  String _channelDisplayName() {
    if (channel.isDm && channel.users != null && channel.users!.isNotEmpty) {
      final names = channel.users!
          .map((u) => u['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
      return names.join(', ');
    }
    return channel.name;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final unread = channel.unreadCount;

    final background = selected
        ? Color.alphaBlend(
            theme.buttonPrimary.withValues(alpha: 0.1),
            theme.surfaceContainer,
          )
        : theme.surfaceContainer;

    return ConduitContextMenu(
      actions: actions,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppBorderRadius.md),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(
                      _channelIcon(),
                      color: selected ? theme.textPrimary : theme.textSecondary,
                      size: IconSize.listItem,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _channelDisplayName(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.sidebarTitleStyle.copyWith(
                              color: selected
                                  ? theme.textPrimary
                                  : theme.textSecondary,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                          if (channel.description.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              channel.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.sidebarSupportingStyle
                                  .copyWith(color: theme.textSecondary),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (unread > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          unread > 99 ? '99+' : '$unread',
                          style: AppTypography.sidebarBadgeStyle.copyWith(
                            color: Theme.of(context).colorScheme.onPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
