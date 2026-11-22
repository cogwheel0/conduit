part of 'app_providers.dart';

/// The chats on screen, each by the view showing it: a window's chat pane, a
/// panel, a phone's chat page.
///
/// A chat on screen is being read. When its stored copy changes while it
/// shows (Open WebUI's own save of a finished answer, brought by a pull;
/// another device's message), it is read up to that copy, here and on the
/// server, once per change however many views show it. Each shown chat's own
/// stored row is watched, so one the chat list does not hold (archived, or
/// past its loaded page) is read too. A chat marked unread stays so until it
/// is read again, as opening it does. Nothing is read in another account's
/// database.
final shownChatsProvider = NotifierProvider<ShownChats, Map<String, String>>(
  ShownChats.new,
);

/// A shown chat's stored row: the database its reads go to, and its id there.
typedef _StoredChat = (AppDatabase, String);

class ShownChats extends Notifier<Map<String, String>> {
  /// Where each view's chat is stored, as it was when it was shown.
  final Map<String, _StoredChat> _stored = <String, _StoredChat>{};

  /// One watch of each shown chat's stored row, shared by every view that
  /// shows it.
  final Map<_StoredChat, _StoredRowWatch> _watches =
      <_StoredChat, _StoredRowWatch>{};

  @override
  Map<String, String> build() {
    // A Ref's listener can stall while this notifier is only read, as
    // conduitd reads it: the database check before each read is what keeps
    // reads in their account.
    ref.listen<AppDatabase?>(appDatabaseProvider, (previous, next) {
      if (!identical(previous, next)) _forgetAll();
    });
    ref.onDispose(() {
      _stored.clear();
      _followStoredRows();
    });
    return const <String, String>{};
  }

  /// [view] shows chat [chatId] now, or no chat (null).
  void show(String view, String? chatId) {
    final id = chatId?.trim() ?? '';
    final rawId = ChatStorageIdentity.parse(id).rawId;
    final shows = id.isNotEmpty && !isTemporaryChat(rawId);
    if (shows ? state[view] == id : !state.containsKey(view)) return;
    final db = shows
        ? ref.read(conversationsProvider.notifier)._readDatabaseOf(id)
        : null;
    if (db == null) {
      _stored.remove(view);
    } else {
      _stored[view] = (db, rawId);
    }
    state = shows ? {...state, view: id} : ({...state}..remove(view));
    _followStoredRows();
  }

  void _forgetAll() {
    _stored.clear();
    _followStoredRows();
    if (state.isNotEmpty) state = const <String, String>{};
  }

  /// Watches the stored row of each chat a view shows, and of no other.
  void _followStoredRows() {
    final shown = _stored.values.toSet();
    _watches.removeWhere((chat, watch) {
      if (shown.contains(chat)) return false;
      unawaited(watch.subscription.cancel());
      return true;
    });
    for (final chat in shown) {
      if (_watches.containsKey(chat)) continue;
      final (db, rawId) = chat;
      final watch = _StoredRowWatch();
      watch.subscription = db.chatsDao
          .watchChatMeta(rawId)
          .listen(
            (entry) => _seen(chat, watch, entry),
            onError: (Object error, StackTrace stackTrace) {
              DebugLogger.error(
                'shown-chat-watch-failed',
                scope: 'conversations/shown',
                error: error,
                stackTrace: stackTrace,
              );
            },
          );
      _watches[chat] = watch;
    }
  }

  void _seen(_StoredChat chat, _StoredRowWatch watch, ChatListEntry? entry) {
    if (entry == null || !identical(_watches[chat], watch)) return;
    if (!_unreadCopy(entry)) {
      // Read, or marked unread: no read is pending. A later change at the
      // same date (unseen text held unread, a refused mark's rollback) is
      // read anew.
      watch.readCopy = null;
      return;
    }
    if (watch.readCopy == entry.updatedAt) return;
    watch.readCopy = entry.updatedAt;
    unawaited(_read(chat, watch, entry.updatedAt));
  }

  /// Reads [chat] up to its stored copy dated [copy] (epoch seconds), if it
  /// still needs it.
  Future<void> _read(_StoredChat chat, _StoredRowWatch watch, int copy) async {
    final (db, rawId) = chat;
    final ChatListEntry? stored;
    try {
      stored = await db.chatsDao.getChatMeta(rawId);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'shown-chat-read-failed',
        scope: 'conversations/shown',
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }
    if (!ref.mounted || !identical(_watches[chat], watch)) return;
    if (db.chatsDao.isMarkingUnread(rawId)) {
      // A refused mark puts the earlier read back without a new copy: read
      // the copy then. Checked first, since the mark may already be stored.
      watch.readCopy = null;
      return;
    }
    // As the chat is stored now: a mark of unread may have landed since
    // the copy was seen, and the read would raise it again.
    if (stored == null || stored.updatedAt != copy || !_unreadCopy(stored)) {
      return;
    }
    final conversations = ref.read(conversationsProvider.notifier);
    final id = _stored.entries
        .where((shown) => shown.value == chat)
        .map((shown) => state[shown.key])
        .nonNulls
        .where((id) => identical(conversations._readDatabaseOf(id), db))
        .firstOrNull;
    if (id == null) return;
    final shownAt = DateTime.fromMillisecondsSinceEpoch(copy * 1000);
    final now = DateTime.now();
    // Up to the copy shown, whichever clock dated it.
    unawaited(
      markConversationRead(
        ref,
        id,
        readAt: now.isAfter(shownAt) ? now : shownAt,
      ),
    );
  }
}

/// Whether [entry]'s copy is newer than its read. Open WebUI's explicit
/// unread (`last_read_at = 0`) is no read to raise.
bool _unreadCopy(ChatListEntry entry) {
  final read = entry.lastReadAt;
  if (read == 0) return false;
  return read == null || entry.updatedAt > read;
}

final class _StoredRowWatch {
  late final StreamSubscription<ChatListEntry?> subscription;

  /// The copy (its date, epoch seconds) asked to be read and not yet shown
  /// read, so a read that could not be stored is not asked again until the
  /// copy changes. Cleared once the row shows it read or marked unread.
  int? readCopy;
}
