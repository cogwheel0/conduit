import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/models/channel.dart';

/// Name shown for [channel] in the list and its page header. Direct messages
/// carry no channel name, so they are titled by their participants.
///
/// [fallback] is used when neither participants nor a name are available,
/// such as a DM response that omits `users`, so the title is never blank.
String channelDisplayName(Channel channel, {required String fallback}) {
  final users = channel.users;
  if (channel.isDm && users != null && users.isNotEmpty) {
    final names = users
        .map((u) => u['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    if (names.isNotEmpty) return names.join(', ');
  }
  final name = channel.name.trim();
  return name.isEmpty ? fallback : name;
}

/// Whether [channel] matches a lowercase search [query], by its channel name
/// or by the title the list shows (a DM's participants).
bool channelMatchesQuery(
  Channel channel,
  String query, {
  required String fallback,
}) =>
    channel.name.toLowerCase().contains(query) ||
    channelDisplayName(
      channel,
      fallback: fallback,
    ).toLowerCase().contains(query);

/// Leading glyph that distinguishes DMs, groups, and private channels.
IconData channelIcon(Channel channel) {
  if (channel.isDm) return Icons.person_outline;
  if (channel.isGroup) return Icons.group_outlined;
  return channel.isPrivate ? Icons.lock_outlined : Icons.tag;
}
