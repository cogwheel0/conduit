import 'package:drift/drift.dart' show Value;

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/pull_sync.dart'
    show PullFetchMemo, kOpenWebUiChatListPageSize;
import 'package:conduit_core/sync/sync_api_client.dart';

/// Brings the pins and archives of the account's chats held here in line
/// with Open WebUI's.
///
/// Open WebUI 0.13.4 pins and archives a chat without moving its
/// `updated_at` (`toggle_chat_pinned_by_id`, `toggle_chat_archive_by_id`),
/// so the watermark pull never reads the chat again for either. The server
/// holds the truth for every chat of [accountId]: Conduit pins and archives
/// an Open WebUI chat on the server first and never queues either.
///
/// Each cycle reads the pinned list, which comes whole, and the number of
/// archived chats. The archived list is read, to its last page, only when
/// that number differs from the archived chats held here. A chat the lists
/// leave in doubt is read itself, and takes that copy's pin, archive, folder
/// and owner: one held as archived that the archived list no longer names
/// (unarchived or deleted elsewhere), and one held as pinned that the pinned
/// list leaves out (unpinned or archived elsewhere, or another user's chat,
/// which keeps its owner's pin). Counts a complete reading could not bring
/// together are not read for again while every cycle sees them unchanged
/// ([PullFetchMemo.archivedCountsUnsettled]); a read that failed or a write
/// held back leaves them to the next cycle.
///
/// Nothing read is written over a chat changed here after the first request
/// ([ChatsDao.envelopeChangedSince], checked under the chat's lock), or after
/// an account-wide change that ended since [generation]. Best effort: a
/// failure leaves rows as they are. Returns how many chats changed.
Future<int> syncServerPinsAndArchives({
  required SyncApiClient client,
  required AppDatabase db,
  required ConversationLocks locks,
  required String accountId,
  required int generation,
  PullFetchMemo? memo,
}) async {
  final since = db.chatsDao.localEnvelopeClock;
  final local = await db.chatsDao.serverChatPinsAndArchives();
  bool othersChat(String id) {
    final owner = local[id]?.userId;
    return owner != null && owner != accountId;
  }

  int archivedHere() => local.entries
      .where((entry) => entry.value.archived && !othersChat(entry.key))
      .length;

  int? archivedOnServer;
  try {
    archivedOnServer = await client.getArchivedChatCount();
  } catch (error, stackTrace) {
    DebugLogger.error(
      'archived-count-failed',
      scope: 'sync/pull',
      error: error,
      stackTrace: stackTrace,
    );
  }
  final countedHere = archivedHere();
  final unsettled =
      memo?.archivedCountsUnsettled(archivedOnServer, countedHere) ?? false;
  Set<String>? archived;
  if (archivedOnServer != null &&
      archivedOnServer != countedHere &&
      !unsettled) {
    try {
      archived = await _archivedChatIds(client);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'archived-list-failed',
        scope: 'sync/pull',
        error: error,
        stackTrace: stackTrace,
      );
    }
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

  /// False when the write failed or was held back, so a later cycle tries
  /// again.
  Future<bool> apply(
    String id, {
    bool? pinned,
    bool? archived,
    Value<String?> folderId = const Value.absent(),
    String? ownerId,
  }) async {
    try {
      final stored = await locks.runExclusive(id, () async {
        if (locks.generation != generation ||
            db.chatsDao.envelopeChangedSince(id, since)) {
          return null;
        }
        return db.chatsDao.applyServerPinAndArchive(
          id,
          pinned: pinned,
          archived: archived,
          folderId: folderId,
          ownerId: ownerId,
        );
      });
      if (stored == null) return false;
      if (stored) {
        changed++;
        final row = local[id]!;
        local[id] = (
          pinned: pinned ?? row.pinned,
          archived: archived ?? row.archived,
          userId: row.userId ?? ownerId,
        );
      }
      return true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'pin-archive-failed',
        scope: 'sync/pull',
        error: error,
        stackTrace: stackTrace,
        data: {'chatId': id},
      );
      return false;
    }
  }

  /// Reads chat [id] and takes its copy. False when the read failed and may
  /// not next time; a chat the server no longer has leaves nothing to do.
  Future<bool> adopt(String id) async {
    final Map<String, dynamic>? raw;
    try {
      raw = await client.getChatRaw(id);
    } catch (error) {
      // Open WebUI answers 401 for a chat it no longer has.
      bool gone;
      try {
        gone = !await client.probeChatExists(id);
      } catch (_) {
        gone = false;
      }
      DebugLogger.log(
        'pin-archive-read-failed',
        scope: 'sync/pull',
        data: {'chatId': id, 'gone': gone},
      );
      return gone;
    }
    if (raw == null) return true;
    final folderId = raw['folder_id'];
    final ownerId = raw['user_id'];
    return apply(
      id,
      pinned: raw['pinned'] == true,
      archived: raw['archived'] == true,
      folderId: Value(folderId is String ? folderId : null),
      ownerId: ownerId is String && ownerId.isNotEmpty ? ownerId : null,
    );
  }

  if (archived != null) {
    var settled = true;
    for (final id in archived) {
      final row = local[id];
      // A chat not held here comes from the archived loop, as a stub.
      if (row == null || row.archived) continue;
      // Its own copy carries the pin, which the archived list leaves out
      // and a later push of the chat would put back on the server.
      if (!await adopt(id)) settled = false;
    }
    final unlisted = [
      for (final MapEntry(key: id, value: row) in local.entries)
        if (row.archived && !othersChat(id) && !archived.contains(id)) id,
    ];
    for (final id in unlisted) {
      if (!await adopt(id)) settled = false;
    }
    final here = archivedHere();
    if (settled && here != archivedOnServer) {
      memo?.noteArchivedCountsUnsettled(archivedOnServer!, here);
    }
  }

  if (pinned != null) {
    for (final MapEntry(key: id, value: row) in local.entries.toList()) {
      // The pinned list leaves archived chats out, pinned or not.
      if (row.archived || (archived?.contains(id) ?? false)) continue;
      final listed = pinned.contains(id);
      if (row.pinned == listed) continue;
      if (listed) {
        await apply(id, pinned: true);
      } else if (!othersChat(id)) {
        // Unpinned, or archived, elsewhere, or another user's chat stored
        // before rows kept their owner: its own copy says which.
        await adopt(id);
      }
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
