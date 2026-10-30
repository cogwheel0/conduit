import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/composer_drafts.dart';

part 'composer_drafts_dao.g.dart';

@DriftAccessor(tables: [ComposerDrafts])
class ComposerDraftsDao extends DatabaseAccessor<AppDatabase>
    with _$ComposerDraftsDaoMixin {
  ComposerDraftsDao(super.db);

  Future<ComposerDraft?> readDraft(String scope, String chatId) =>
      attachedDatabase.transaction(() async {
        final resolved = await resolveChatId(scope, chatId);
        return _readExact(scope, resolved);
      });

  Future<String> resolveChatId(String scope, String chatId) async {
    if (scope != 'chat') return chatId;
    var current = chatId;
    final seen = <String>{};
    while (seen.add(current)) {
      final next = await attachedDatabase.syncMetaDao.getChatRemapTarget(
        current,
      );
      if (next == null) return current;
      current = next;
    }
    throw StateError('Invalid chat draft ownership');
  }

  Future<ComposerDraft?> _readExact(String scope, String chatId) =>
      (select(composerDrafts)..where(
            (row) => row.scope.equals(scope) & row.chatId.equals(chatId),
          ))
          .getSingleOrNull();

  Future<void> saveDraft({
    required String scope,
    required String chatId,
    required String content,
    required int updatedAt,
  }) => attachedDatabase.transaction(() async {
    final resolved = await resolveChatId(scope, chatId);
    if (scope == 'chat' && content.isNotEmpty) {
      final chat = await attachedDatabase.chatsDao.getChat(resolved);
      if (chat == null || chat.deleted) {
        throw StateError('The chat is no longer available for draft edits');
      }
    }
    if (content.isEmpty) {
      await (delete(composerDrafts)..where(
            (row) => row.scope.equals(scope) & row.chatId.equals(resolved),
          ))
          .go();
      return;
    }
    await into(composerDrafts).insertOnConflictUpdate(
      ComposerDraftsCompanion.insert(
        scope: scope,
        chatId: resolved,
        content: content,
        updatedAt: updatedAt,
      ),
    );
  });

  Future<void> deleteChatDraft(String chatId) => deleteDraft('chat', chatId);

  Future<void> deleteDraft(String scope, String chatId) => attachedDatabase.transaction(() async {
    final resolved = await resolveChatId(scope, chatId);
    await attachedDatabase.composerRecordingsDao.discardChat(scope, resolved);
    await (delete(composerDrafts)..where(
      (row) => row.scope.equals(scope) & row.chatId.equals(resolved),
    )).go();
  });

  /// Runs inside the owning remap's transaction. Keep the newest input if
  /// a crash-recovered server identity already has a draft.
  Future<void> remapDraft(String scope, String localId, String serverId) async {
    await attachedDatabase.composerRecordingsDao.remap(
      scope,
      localId,
      serverId,
    );
    final source = await _readExact(scope, localId);
    if (source == null) return;
    final destination = await _readExact(scope, serverId);
    if (destination == null || source.updatedAt >= destination.updatedAt) {
      await saveDraft(
        scope: scope,
        chatId: serverId,
        content: source.content,
        updatedAt: source.updatedAt,
      );
    }
    await (delete(
          composerDrafts,
        )..where((row) => row.scope.equals(scope) & row.chatId.equals(localId)))
        .go();
  }
}
