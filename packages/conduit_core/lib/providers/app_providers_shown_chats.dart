part of 'app_providers.dart';

/// The chats on screen, each by the view showing it: a window's chat pane, a
/// panel, a phone's chat page.
///
/// A chat on screen is being read. When its stored copy changes while it
/// shows (Open WebUI's own save of a finished answer, brought by a pull;
/// another device's message), it is read up to that copy, here and on the
/// server, once per change. A chat marked unread stays so until it is read
/// again, as opening it does. Nothing is read in another account's database.
final shownChatsProvider = NotifierProvider<ShownChats, Map<String, String>>(
  ShownChats.new,
);

class ShownChats extends Notifier<Map<String, String>> {
  /// Where each view's chat was read when it was shown.
  final Map<String, AppDatabase?> _databases = <String, AppDatabase?>{};

  /// The copy each view last read, by its date, so a read that could not be
  /// stored is not asked again until the copy changes.
  final Map<String, DateTime> _readCopies = <String, DateTime>{};

  @override
  Map<String, String> build() {
    ref.listen<AppDatabase?>(appDatabaseProvider, (previous, next) {
      if (!identical(previous, next)) _forgetAll();
    });
    ref.listen<AsyncValue<List<Conversation>>>(conversationsProvider, (
      _,
      next,
    ) {
      final listed = next.asData?.value;
      if (listed != null) _readChanged(listed);
    });
    return const <String, String>{};
  }

  /// [view] shows chat [chatId] now, or no chat (null).
  void show(String view, String? chatId) {
    final id = chatId?.trim() ?? '';
    if (state[view] == id) return;
    _readCopies.remove(view);
    if (id.isEmpty || isTemporaryChat(ChatStorageIdentity.parse(id).rawId)) {
      _databases.remove(view);
      if (state.containsKey(view)) state = {...state}..remove(view);
      return;
    }
    _databases[view] = ref
        .read(conversationsProvider.notifier)
        ._readDatabaseOf(id);
    state = {...state, view: id};
    final listed = ref.read(conversationsProvider).asData?.value;
    if (listed != null) _readChanged(listed);
  }

  void _forgetAll() {
    _databases.clear();
    _readCopies.clear();
    if (state.isNotEmpty) state = const <String, String>{};
  }

  void _readChanged(List<Conversation> listed) {
    for (final MapEntry(key: view, value: id) in state.entries) {
      final index = _conversationIndexForSelection(listed, id);
      if (index < 0) continue;
      final chat = listed[index];
      final read = chat.lastReadAt;
      // Open WebUI's explicit unread (`last_read_at = 0`).
      if (read != null && read.millisecondsSinceEpoch == 0) continue;
      if (read != null && !chat.updatedAt.isAfter(read)) continue;
      if (_readCopies[view] == chat.updatedAt) continue;
      final conversations = ref.read(conversationsProvider.notifier);
      if (!identical(conversations._readDatabaseOf(id), _databases[view])) {
        continue;
      }
      _readCopies[view] = chat.updatedAt;
      final now = DateTime.now();
      // Up to the copy shown, whichever clock dated it.
      final readAt = now.isAfter(chat.updatedAt) ? now : chat.updatedAt;
      // Not while the list is still telling its listeners of this change.
      scheduleMicrotask(() {
        if (!ref.mounted || state[view] != id) return;
        unawaited(markConversationRead(ref, id, readAt: readAt));
      });
    }
  }
}
