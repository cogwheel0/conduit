import 'package:conduit_core/models/channel.dart';

/// Name shown for [channel] in the list and its page header. Direct messages
/// carry no channel name, so they are titled by their participants.
///
/// [excludingUserId] leaves that participant out of a direct message's
/// title, as Open WebUI's own sidebar leaves out the signed-in user; a
/// conversation with only that participant still names them.
///
/// [fallback] is used when neither participants nor a name are available,
/// such as a DM response that omits `users`, so the title is never blank.
String channelDisplayName(
  Channel channel, {
  required String fallback,
  String? excludingUserId,
}) {
  final users = channel.users;
  if (channel.isDm && users != null && users.isNotEmpty) {
    List<String> namesOf(Iterable<Map<String, dynamic>> people) => people
        .map((u) => u['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    final others = excludingUserId == null
        ? users
        : users.where((u) => u['id'] != excludingUserId);
    var names = namesOf(others);
    if (names.isEmpty && excludingUserId != null) names = namesOf(users);
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
