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
import '../../../shared/utils/locale_display_formatters.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../../core/services/navigation_service.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../navigation/providers/sidebar_providers.dart';
import '../../navigation/providers/sidebar_tab_scroll_registry.dart';
import '../../navigation/widgets/conversation_tile.dart';
import '../providers/channel_providers.dart';
import '../utils/channel_request_owner.dart';
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
  final ScrollController _scrollController = ScrollController();
  late final SidebarTabScrollRegistry _scrollRegistry;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _activeChannelId = _parseChannelId(_currentPath);
    _scrollRegistry = ref.read(sidebarTabScrollRegistryProvider);
    _scrollRegistry.register(
      SidebarTabId.channels.name,
      owner: this,
      callback: _scrollToTop,
    );
    NavigationService.router.routeInformationProvider.addListener(
      _onRouteChanged,
    );
  }

  @override
  void dispose() {
    NavigationService.router.routeInformationProvider.removeListener(
      _onRouteChanged,
    );
    _scrollRegistry.unregister(SidebarTabId.channels.name, owner: this);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _scrollToTop() async {
    if (!_scrollController.hasClients) return;
    final duration = context.motionDuration(AnimationDuration.fast);
    if (duration == Duration.zero) {
      _scrollController.jumpTo(0);
      return;
    }
    await _scrollController.animateTo(
      0,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
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
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.channelLeave,
      message: l10n.channelLeaveConfirm,
    );
    if (!confirmed ||
        !mounted ||
        !isChannelRequestOwnerCurrent(
          ref: ref,
          api: api,
          authSessionEpoch: authSessionEpoch,
        )) {
      return;
    }
    try {
      await api.updateMemberActiveStatus(channel.id, isActive: false);
      if (!mounted ||
          !isChannelRequestOwnerCurrent(
            ref: ref,
            api: api,
            authSessionEpoch: authSessionEpoch,
          )) {
        return;
      }
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
      if (!mounted ||
          !isChannelRequestOwnerCurrent(
            ref: ref,
            api: api,
            authSessionEpoch: authSessionEpoch,
          )) {
        return;
      }
      _showChannelActionError(l10n.errorMessage);
    }
  }

  Future<void> _editChannel(Channel channel) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    final result = await showEditChannelFormDialog(context, channel: channel);
    if (result == null ||
        !mounted ||
        !isChannelRequestOwnerCurrent(
          ref: ref,
          api: api,
          authSessionEpoch: authSessionEpoch,
        )) {
      return;
    }
    try {
      final json = await api.updateChannel(
        channel.id,
        name: result.name,
        description: result.description,
        isPrivate: result.isPrivate,
      );
      final updated = Channel.fromJson(json);
      if (!mounted ||
          !isChannelRequestOwnerCurrent(
            ref: ref,
            api: api,
            authSessionEpoch: authSessionEpoch,
          )) {
        return;
      }
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
      if (!mounted ||
          !isChannelRequestOwnerCurrent(
            ref: ref,
            api: api,
            authSessionEpoch: authSessionEpoch,
          )) {
        return;
      }
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

        return channelsAsync.when(
          data: (channels) {
            final filtered = queryLower.isEmpty
                ? channels
                : channels
                      .where((c) => c.name.toLowerCase().contains(queryLower))
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

            final list = ListView.builder(
              controller: _scrollController,
              primary: false,
              itemCount: filtered.length,
              padding: EdgeInsets.only(
                top: sidebarTabContentTopPadding(context),
                bottom: sidebarTabContentBottomPadding(context),
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
            );
            final refreshable = RefreshIndicator.adaptive(
              edgeOffset: sidebarRefreshIndicatorEdgeOffset(context),
              onRefresh: () async {
                ConduitHaptics.lightImpact();
                await ref.read(channelsListProvider.notifier).refresh();
              },
              child: list,
            );
            final primary = PrimaryScrollController(
              controller: _scrollController,
              child: refreshable,
            );
            return context.usesCupertinoChrome
                ? CupertinoScrollbar(
                    controller: _scrollController,
                    child: primary,
                  )
                : Scrollbar(controller: _scrollController, child: primary);
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

    final displayName = _channelDisplayName();
    final description = channel.description.isEmpty
        ? null
        : channel.description;

    return ConduitContextMenu(
      actions: actions,
      previewBuilder: buildConversationTileContextPreview,
      child: ChatStyleSidebarTile(
        key: ValueKey<String>('channel-sidebar-row-${channel.id}'),
        selected: selected,
        onTap: onTap,
        semanticLabel: description == null
            ? displayName
            : '$displayName. $description',
        tintKey: ValueKey<String>('channel-sidebar-selected-${channel.id}'),
        pressedKey: ValueKey<String>('channel-sidebar-pressed-${channel.id}'),
        child: UtilityRow(
          leading: Icon(
            _channelIcon(),
            color: selected ? theme.textPrimary : theme.textSecondary,
            size: IconSize.listItem,
          ),
          title: displayName,
          subtitle: description,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          trailing: unread <= 0
              ? null
              : Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    unread > 99
                        ? '99+'
                        : LocaleDisplayFormatters.integer(context, unread),
                    style: AppTypography.sidebarBadgeStyle.copyWith(
                      color: Theme.of(context).colorScheme.onPrimary,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
