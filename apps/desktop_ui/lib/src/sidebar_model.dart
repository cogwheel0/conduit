import 'package:conduit_protocol/conduit_protocol.dart';

/// How long ago a conversation was last touched, as the sidebar groups it.
///
/// Open WebUI's own buckets, so a user moving between the web app and this
/// one finds a conversation under the same heading in both.
enum DateBucket { today, yesterday, previous7Days, previous30Days, older }

/// A folder with what is in it.
class FolderNode {
  FolderNode(this.folder);

  final FolderSummary folder;
  final List<FolderNode> children = <FolderNode>[];
  final List<ChatSummary> chats = <ChatSummary>[];

  /// Chats here and in every folder below, for the count beside the name.
  int get totalChats =>
      chats.length + children.fold(0, (sum, child) => sum + child.totalChats);
}

/// The sidebar, sorted into the sections it draws.
class SidebarModel {
  const SidebarModel({
    required this.pinned,
    required this.folders,
    required this.recent,
    required this.archived,
  });

  final List<ChatSummary> pinned;

  /// Top-level folders; nested ones hang off [FolderNode.children].
  final List<FolderNode> folders;

  /// Non-empty buckets only, newest first.
  final List<({DateBucket bucket, List<ChatSummary> chats})> recent;

  final List<ChatSummary> archived;
}

/// Sorts [list] into sections.
///
/// Every chat lands in exactly one section, and none is dropped -- the
/// rules below are mostly about the cases where the obvious placement does
/// not exist:
///
///  * Archived wins over everything. An archived chat that is also pinned
///    is still archived; showing it in Pinned would un-archive it in all
///    but name.
///  * Pinned wins over a folder, as it does in Open WebUI.
///  * A chat whose folder is unknown -- deleted elsewhere, or not synced
///    yet -- goes to the dated list rather than vanishing.
///  * A folder whose parent is unknown is shown at the top level, and a
///    parent cycle (which the server should prevent, and a half-applied
///    sync can briefly produce) is broken rather than followed forever.
SidebarModel buildSidebar(ChatList list, {required DateTime now}) {
  final nodes = <String, FolderNode>{
    for (final folder in list.folders) folder.id: FolderNode(folder),
  };

  final roots = <FolderNode>[];
  for (final node in nodes.values) {
    final parentId = node.folder.parentId;
    final parent = parentId == null ? null : nodes[parentId];
    if (parent == null || _createsCycle(node, parent, nodes)) {
      roots.add(node);
    } else {
      parent.children.add(node);
    }
  }

  final pinned = <ChatSummary>[];
  final archived = <ChatSummary>[];
  final dated = <DateBucket, List<ChatSummary>>{};
  for (final chat in list.chats) {
    if (chat.archived) {
      archived.add(chat);
    } else if (chat.pinned) {
      pinned.add(chat);
    } else if (chat.folderId case final id? when nodes.containsKey(id)) {
      nodes[id]!.chats.add(chat);
    } else {
      dated
          .putIfAbsent(bucketFor(chat.updatedAtMs, now: now), () => [])
          .add(chat);
    }
  }

  int byName(FolderNode a, FolderNode b) =>
      a.folder.name.toLowerCase().compareTo(b.folder.name.toLowerCase());
  void sortTree(List<FolderNode> level) {
    level.sort(byName);
    for (final node in level) {
      sortTree(node.children);
    }
  }

  sortTree(roots);

  return SidebarModel(
    pinned: pinned,
    folders: roots,
    recent: <({DateBucket bucket, List<ChatSummary> chats})>[
      for (final bucket in DateBucket.values)
        if (dated[bucket] case final chats?) (bucket: bucket, chats: chats),
    ],
    archived: archived,
  );
}

/// The folders, outermost first, that hold [chatId] in [roots], or null
/// when it is in none of them.
List<String>? folderPathTo(String chatId, List<FolderNode> roots) {
  for (final node in roots) {
    if (node.chats.any((chat) => chat.id == chatId)) {
      return <String>[node.folder.id];
    }
    if (folderPathTo(chatId, node.children) case final inner?) {
      return <String>[node.folder.id, ...inner];
    }
  }
  return null;
}

/// The desktop sidebar's coarser time groups.
enum RecentGroup { today, yesterday, earlier }

/// [recent] regrouped as Today, Yesterday and Earlier: the three older
/// buckets become one, newest first as they were.
List<({RecentGroup group, List<ChatSummary> chats})> groupRecent(
  List<({DateBucket bucket, List<ChatSummary> chats})> recent,
) {
  final today = <ChatSummary>[];
  final yesterday = <ChatSummary>[];
  final earlier = <ChatSummary>[];
  for (final entry in recent) {
    switch (entry.bucket) {
      case DateBucket.today:
        today.addAll(entry.chats);
      case DateBucket.yesterday:
        yesterday.addAll(entry.chats);
      case DateBucket.previous7Days ||
          DateBucket.previous30Days ||
          DateBucket.older:
        earlier.addAll(entry.chats);
    }
  }
  return <({RecentGroup group, List<ChatSummary> chats})>[
    if (today.isNotEmpty) (group: RecentGroup.today, chats: today),
    if (yesterday.isNotEmpty) (group: RecentGroup.yesterday, chats: yesterday),
    if (earlier.isNotEmpty) (group: RecentGroup.earlier, chats: earlier),
  ];
}

/// Which bucket a timestamp belongs to, measured in *calendar days*.
///
/// Not in elapsed hours: a chat from 23:50 last night is "Yesterday" at
/// 00:10 this morning, twenty minutes later, and a 24-hour window would
/// call it "Today" -- which is not what anyone means by the word.
DateBucket bucketFor(int updatedAtMs, {required DateTime now}) {
  final local = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  // Whole days, rounded: a daylight-saving change makes one day in the
  // year 23 or 25 hours long, and truncating would put it in the wrong
  // bucket for an hour.
  final days = (today.difference(day).inHours / 24).round();
  if (days <= 0) return DateBucket.today;
  if (days == 1) return DateBucket.yesterday;
  if (days < 7) return DateBucket.previous7Days;
  if (days < 30) return DateBucket.previous30Days;
  return DateBucket.older;
}

bool _createsCycle(
  FolderNode node,
  FolderNode parent,
  Map<String, FolderNode> nodes,
) {
  final seen = <String>{node.folder.id};
  FolderNode? cursor = parent;
  while (cursor != null) {
    if (!seen.add(cursor.folder.id)) return true;
    final next = cursor.folder.parentId;
    cursor = next == null ? null : nodes[next];
  }
  return false;
}
