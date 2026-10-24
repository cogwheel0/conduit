import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/chats_dao.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/sync/chat_locks.dart';

/// Applies the `last_read_at` values Open WebUI reported on chat-list rows.
///
/// Reading a chat or marking it unread on another device changes
/// `last_read_at` without advancing `updated_at`, so the watermark pull never
/// re-fetches that chat for it. [since] is [ChatsDao.localReadStateClock]
/// captured before the list was requested: a chat read or marked unread on
/// this device after that, or whose unread request is still on its way, keeps
/// its local state.
///
/// Rows this device does not hold are left to the regular chat merge.
/// Returns how many chats changed.
Future<int> applyServerReadStates({
  required AppDatabase db,
  required ChatLocks locks,
  required Map<String, int> serverLastReadAts,
  required int since,
  required String scope,
}) async {
  if (serverLastReadAts.isEmpty) return 0;
  final local = await db.chatsDao.serverChatLastReadAts();
  var updated = 0;
  for (final MapEntry(key: id, value: server) in serverLastReadAts.entries) {
    if (!local.containsKey(id)) continue;
    final current = local[id];
    if (ChatsDao.mergeServerLastReadAt(current, server) == current) continue;
    try {
      final changed = await locks.runExclusive(
        id,
        () => db.chatsDao.applyListedLastReadAt(id, server, since: since),
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
