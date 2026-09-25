import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/models/channel.dart';

/// Name shown for [channel] in the list and its page header. Direct messages
/// carry no channel name, so they are titled by their participants.
String channelDisplayName(Channel channel) {
  final users = channel.users;
  if (channel.isDm && users != null && users.isNotEmpty) {
    final names = users
        .map((u) => u['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    if (names.isNotEmpty) return names.join(', ');
  }
  return channel.name;
}

/// Leading glyph that distinguishes DMs, groups, and private channels.
IconData channelIcon(Channel channel) {
  if (channel.isDm) return Icons.person_outline;
  if (channel.isGroup) return Icons.group_outlined;
  return channel.isPrivate ? Icons.lock_outlined : Icons.tag;
}
