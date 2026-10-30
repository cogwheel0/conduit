import 'dart:math' as math;

import '../../../database/app_database.dart';
import 'composer_recording_store.dart';

/// Serializes input writes so a slow older edit cannot replace a newer one.
/// The DAO is captured from the owning account's database, never resolved
/// again after an asynchronous boundary.
class ComposerDraftStore {
  ComposerDraftStore(this._database);

  final AppDatabase _database;
  late final recordings = ComposerRecordingStore(_database);
  Future<void> _pending = Future<void>.value();
  int _lastUpdatedAt = 0;

  Future<String?> read(String scope, String chatId) async {
    await _pending;
    return (await _database.composerDraftsDao.readDraft(
      scope,
      chatId,
    ))?.content;
  }

  Future<String> resolveChatId(String scope, String chatId) =>
      _database.composerDraftsDao.resolveChatId(scope, chatId);

  Future<void> save(String scope, String chatId, String content) {
    final updatedAt = math.max(
      DateTime.now().millisecondsSinceEpoch,
      _lastUpdatedAt + 1,
    );
    _lastUpdatedAt = updatedAt;
    return _queue(
      () => _database.composerDraftsDao.saveDraft(
        scope: scope,
        chatId: chatId,
        content: content,
        updatedAt: updatedAt,
      ),
    );
  }

  /// Native session remaps have no server outbox. Serialize their draft move
  /// with this input's edits, using the exact app-owned remap proof at the UI.
  Future<void> remap(String scope, String from, String to) => _queue(
    () => _database.transaction(
      () => _database.composerDraftsDao.remapDraft(scope, from, to),
    ),
  );

  Future<void> _queue(Future<void> Function() operation) {
    return _database.trackComposerDraftWrite(() {
      final write = _pending.then((_) => operation());
      // Later edits still run if an earlier disk write failed.
      _pending = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      return write;
    });
  }

  /// A send may finish after its editor is unmounted or a new editor opens.
  /// Only retire the exact snapshot that the committed turn admitted.
  Future<void> clearIfUnchanged(String scope, String chatId, String content) =>
      _queue(
        () => _database.transaction(() async {
          final row = await _database.composerDraftsDao.readDraft(
            scope,
            chatId,
          );
          if (row?.content == content) {
            await _database.composerDraftsDao.saveDraft(
              scope: scope,
              chatId: chatId,
              content: '',
              updatedAt: 0,
            );
          }
        }),
      );

  Future<void> flush() => _pending;
}
