import 'package:drift/drift.dart' show Value;

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/pull_sync.dart'
    show PullFetchMemo, kOpenWebUiChatListPageSize;
import 'package:conduit_core/sync/sync_api_client.dart';

/// Brings the pins and archives of the account's chats held here in line
/// with Open WebUI's pinned and archived lists.
///
/// Open WebUI 0.13.4 pins and archives a chat without moving its
/// `updated_at` (`toggle_chat_pinned_by_id`, `toggle_chat_archive_by_id`),
/// so the watermark pull never reads the chat again for either. The server's
/// lists hold the truth for every chat of [accountId]: Conduit pins and
/// archives an Open WebUI chat on the server first and never queues either.
/// Another user's chat, reached through a shared folder, is on neither list
/// and keeps its owner's pin.
///
/// Each cycle reads the pinned list, which comes whole, and the number of
/// archived chats. The archived list is read, to its last page, only when
/// that number differs from the archived chats held here. A chat this device
/// holds as archived that the list no longer names was unarchived or deleted
/// elsewhere: it is read once to tell which. Counts a full read could not
/// bring together are not read for again until either changes
/// ([PullFetchMemo.archivedCountsUnsettled]).
///
/// [since] is [ChatsDao.localEnvelopeClock] and [generation] is
/// [ConversationLocks.generation], both taken before any list was requested:
/// a pin or archive made here after, or an account-wide change that ended
/// after, keeps what it did. Best effort: a failure leaves rows as they are.
/// Returns how many chats changed.
Future<int> syncServerPinsAndArchives({
  required SyncApiClient client,
  required AppDatabase db,
  required ConversationLocks locks,
  required String accountId,
  required int since,
  required int generation,
  PullFetchMemo? memo,
}) async {
  final local = await db.chatsDao.serverChatPinsAndArchives();
  bool owned(String id) {
    final owner = local[id]?.userId;
    return owner == null || owner == accountId;
  }

  int archivedHere() => local.entries
      .where((entry) => entry.value.archived && owned(entry.key))
      .length;

  int? archivedOnServer;
  Set<String>? archived;
  try {
    archivedOnServer = await client.getArchivedChatCount();
    final here = archivedHere();
    if (archivedOnServer != null &&
        archivedOnServer != here &&
        !(memo?.archivedCountsUnsettled(archivedOnServer, here) ?? false)) {
      archived = await _archivedChatIds(client);
    }
  } catch (error, stackTrace) {
    DebugLogger.error(
      'archived-state-failed',
      scope: 'sync/pull',
      error: error,
      stackTrace: stackTrace,
    );
  }

  Set<String>? pinned;
  try {
    pinned = await client.getPinnedChatIds();
  } catch (error, stackTrace) {
    DebugLogger.error(
      'pinned-list-failed',
      scope: 'sync/pull',
      error: error,
      stackTrace: stackTrace,
    );
  }

  var changed = 0;
  Future<void> apply(
    String id, {
    bool? pinned,
    bool? archived,
    Value<String?> folderId = const Value.absent(),
  }) async {
    try {
      final stored = await locks.runExclusive(id, () async {
        if (locks.generation != generation) return false;
        return db.chatsDao.applyServerPinAndArchive(
          id,
          pinned: pinned,
          archived: archived,
          folderId: folderId,
          since: since,
        );
      });
      if (!stored) return;
      changed++;
      final row = local[id]!;
      local[id] = (
        pinned: pinned ?? row.pinned,
        archived: archived ?? row.archived,
        userId: row.userId,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'pin-archive-failed',
        scope: 'sync/pull',
        error: error,
        stackTrace: stackTrace,
        data: {'chatId': id},
      );
    }
  }

  if (archived != null && archivedOnServer != null) {
    for (final id in archived) {
      final row = local[id];
      // A chat not held here comes from the archived loop, as a stub.
      if (row == null || row.archived) continue;
      // The server takes an archived chat out of its folder.
      await apply(id, archived: true, folderId: const Value(null));
    }
    final gone = [
      for (final MapEntry(key: id, value: row) in local.entries)
        if (row.archived && owned(id) && !archived.contains(id)) id,
    ];
    for (final id in gone) {
      final Map<String, dynamic>? raw;
      try {
        raw = await client.getChatRaw(id);
      } catch (error) {
        // Deleted elsewhere, most likely (Open WebUI answers 401): the
        // deletion reconcile removes it.
        DebugLogger.log(
          'unarchived-read-failed',
          scope: 'sync/pull',
          data: {'chatId': id, 'error': error.runtimeType.toString()},
        );
        continue;
      }
      if (raw == null) continue;
      final folderId = raw['folder_id'];
      await apply(
        id,
        pinned: raw['pinned'] == true,
        archived: raw['archived'] == true,
        folderId: Value(folderId is String ? folderId : null),
      );
    }
    final here = archivedHere();
    memo?.noteArchivedCountsUnsettled(
      here == archivedOnServer ? null : (server: archivedOnServer, local: here),
    );
  }

  if (pinned != null) {
    for (final MapEntry(key: id, value: row) in local.entries.toList()) {
      // The pinned list leaves archived chats out, pinned or not.
      if (row.archived || (archived?.contains(id) ?? false)) continue;
      final serverPinned = pinned.contains(id);
      if (row.pinned == serverPinned) continue;
      if (!serverPinned && !owned(id)) continue;
      await apply(id, pinned: serverPinned);
    }
  }
  return changed;
}

/// The ids on the archived list, read to its last page.
Future<Set<String>> _archivedChatIds(SyncApiClient client) async {
  final ids = <String>{};
  var page = 1;
  while (true) {
    final items = await client.getArchivedChatListPage(page);
    final before = ids.length;
    for (final item in items) {
      if (item['id'] case final String id when id.isNotEmpty) ids.add(id);
    }
    if (items.length < kOpenWebUiChatListPageSize || ids.length == before) {
      return ids;
    }
    page++;
  }
}
