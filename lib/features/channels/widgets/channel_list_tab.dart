import 'package:flutter/material.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/models/channel.dart';
import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../core/services/navigation_service.dart';
import '../../navigation/widgets/sidebar_user_pill.dart';
import '../providers/channel_providers.dart';

/// Sidebar tab that lists all channels with search and create support.
class ChannelListTab extends ConsumerStatefulWidget {
  const ChannelListTab({super.key});

  @override
  ConsumerState<ChannelListTab> createState() => _ChannelListTabState();
}

class _ChannelListTabState extends ConsumerState<ChannelListTab>
    with AutomaticKeepAliveClientMixin {
  static final _channelRoutePattern = RegExp(r'^/channel/(.+)$');

  final TextEditingController _searchController = TextEditingController();
  String _query = '';
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
    _searchController.dispose();
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

  void _onSearchChanged(String value) {
    setState(() => _query = value.trim().toLowerCase());
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
    final l10n = AppLocalizations.of(context)!;
    final nameController = TextEditingController();
    final descController = TextEditingController();
    var isPrivate = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return ThemedDialogs.buildBase(
            context: ctx,
            title: l10n.channelCreateTitle,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(labelText: l10n.channelName),
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descController,
                  decoration: InputDecoration(
                    labelText: l10n.channelDescription,
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: Text(l10n.channelPrivate),
                  value: isPrivate,
                  onChanged: (v) => setDialogState(() => isPrivate = v),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l10n.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.channelCreateTitle),
              ),
            ],
          );
        },
      ),
    );

    // Don't dispose controllers here — the dialog's exit animation
    // may still reference them. They'll be GC'd with the dialog tree.
    final name = nameController.text.trim();
    final description = descController.text.trim();

    if (result != true || !mounted) return;
    if (name.isEmpty) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;
      final json = await api.createChannel(
        name: name,
        type: 'group',
        description: description,
        isPrivate: isPrivate,
      );
      final channel = Channel.fromJson(json);
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final bottomInset = sidebarUserPillContentInset(context, ref);
    final channelsAsync = ref.watch(channelsListProvider);

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: ConduitGlassSearchField(
                    controller: _searchController,
                    hintText: l10n.searchChannels,
                    onChanged: _onSearchChanged,
                    query: _query,
                    onClear: () {
                      _searchController.clear();
                      _onSearchChanged('');
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FloatingAppBarIconButton(
                  icon: UiUtils.newChannelIcon,
                  onTap: _showCreateChannelDialog,
                ),
              ],
            ),
          ),
          Expanded(
            child: channelsAsync.when(
              data: (channels) {
                final filtered = _query.isEmpty
                    ? channels
                    : channels
                          .where((c) => c.name.toLowerCase().contains(_query))
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
                    itemCount: filtered.length,
                    padding: EdgeInsets.zero,
                    itemBuilder: (context, index) {
                      final ch = filtered[index];
                      return _ChannelTile(
                        channel: ch,
                        selected: ch.id == _activeChannelId,
                        onTap: () => _onChannelTap(ch),
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
        ],
      ),
    );
  }
}

class _ChannelTile extends ConsumerWidget {
  const _ChannelTile({
    required this.channel,
    required this.selected,
    required this.onTap,
  });

  final Channel channel;
  final bool selected;
  final VoidCallback onTap;

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

    return Padding(
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
    );
  }
}
