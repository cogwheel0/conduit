import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/models/channel.dart';
import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../core/services/navigation_service.dart';
import '../providers/channel_providers.dart';

/// Sidebar tab that lists all channels with search and create support.
class ChannelListTab extends ConsumerStatefulWidget {
  const ChannelListTab({super.key});

  @override
  ConsumerState<ChannelListTab> createState() => _ChannelListTabState();
}

class _ChannelListTabState extends ConsumerState<ChannelListTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value.trim().toLowerCase());
  }

  void _onChannelTap(Channel channel) {
    ResponsiveDrawerLayout.of(context)?.close();
    NavigationService.router.go('/channel/${channel.id}');
  }

  Future<void> _showCreateChannelDialog() async {
    HapticFeedback.lightImpact();
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
                  decoration: InputDecoration(
                    labelText: l10n.channelName,
                  ),
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
                  onChanged: (v) =>
                      setDialogState(() => isPrivate = v),
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

    final name = nameController.text.trim();
    final description = descController.text.trim();

    nameController.dispose();
    descController.dispose();

    if (result != true || !mounted) return;
    if (name.isEmpty) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;
      final json = await api.createChannel(
        name: name,
        description: description,
        isPrivate: isPrivate,
      );
      final channel = Channel.fromJson(json);
      ref.read(channelsListProvider.notifier).addChannel(channel);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to create channel')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final channelsAsync = ref.watch(channelsListProvider);

    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  hintText: 'Search channels...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: theme.surfaceContainer,
                ),
              ),
            ),
            Expanded(
              child: channelsAsync.when(
                data: (channels) {
                  final filtered = _query.isEmpty
                      ? channels
                      : channels
                          .where(
                            (c) => c.name.toLowerCase().contains(_query),
                          )
                          .toList();

                  if (filtered.isEmpty) {
                    return Center(
                      child: Text(
                        l10n.channelEmptyState,
                        style: TextStyle(color: theme.textSecondary),
                      ),
                    );
                  }

                  return RefreshIndicator(
                    onRefresh: () async {
                      HapticFeedback.lightImpact();
                      await ref
                          .read(channelsListProvider.notifier)
                          .refresh();
                    },
                    child: ListView.builder(
                      itemCount: filtered.length,
                      padding: const EdgeInsets.only(bottom: 80),
                      itemBuilder: (context, index) {
                        return _ChannelTile(
                          channel: filtered[index],
                          onTap: () => _onChannelTap(filtered[index]),
                        );
                      },
                    ),
                  );
                },
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (err, _) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l10n.channelLoadError),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => ref
                            .read(channelsListProvider.notifier)
                            .refresh(),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            heroTag: 'channels_fab',
            onPressed: _showCreateChannelDialog,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }
}

class _ChannelTile extends ConsumerWidget {
  const _ChannelTile({required this.channel, required this.onTap});

  final Channel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final unreadAsync = ref.watch(
      channelUnreadCountProvider(channel.id),
    );
    final unread = unreadAsync.asData?.value ?? 0;

    return ListTile(
      leading: Icon(
        channel.isPrivate ? Icons.lock_outlined : Icons.tag,
        color: theme.textSecondary,
      ),
      title: Text(
        channel.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: channel.description.isNotEmpty
          ? Text(
              channel.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.textSecondary),
            )
          : null,
      trailing: unread > 0
          ? Container(
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
                style: TextStyle(
                  color:
                      Theme.of(context).colorScheme.onPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : null,
      onTap: onTap,
    );
  }
}
