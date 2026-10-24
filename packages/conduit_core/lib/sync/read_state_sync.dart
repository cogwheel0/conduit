import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/chats_dao.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/sync/chat_locks.dart';

/// Applies the `last_read_at` values Open WebUI reported on chat-list rows.
///
/// Reading a chat or marking it unread on another device changes
/// `last_read_at` without advancing `updated_at`, so the watermark pull never
/// re-fetches that chat for it. [localBefore] must be captured with
/// [ChatsDao.serverChatLastReadAts] before the list is requested: a chat read
/// or marked unread on this device while the list loads no longer holds its
/// captured value, so it keeps its newer local state.
///
/// Rows missing from [localBefore] are left to the regular chat merge.
/// Returns how many chats changed.
Future<int> applyServerReadStates({
  required AppDatabase db,
  required ChatLocks locks,
  required Map<String, int> serverLastReadAts,
  required Map<String, int?> localBefore,
  required String scope,
}) async {
  var updated = 0;
  for (final MapEntry(key: id, value: server) in serverLastReadAts.entries) {
    if (!localBefore.containsKey(id)) continue;
    final local = localBefore[id];
    final merged = ChatsDao.mergeServerLastReadAt(local, server);
    if (merged == local) continue;
    try {
      final changed = await locks.runExclusive(
        id,
        () => db.chatsDao.replaceLastReadAt(id, expected: local, value: merged),
      );
      if (changed) updated++;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'read-state-failed',
        scope: scope,
        error: error,
        stackTrace: stackTrace,
        data: {'chatId': id},
      );
    }
  }
  return updated;
}
