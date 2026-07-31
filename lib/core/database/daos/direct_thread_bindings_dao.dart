import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/chats.dart';
import '../tables/direct_thread_bindings.dart';

part 'direct_thread_bindings_dao.g.dart';

@DriftAccessor(tables: [DirectThreadBindings, Chats])
class DirectThreadBindingsDao extends DatabaseAccessor<AppDatabase>
    with _$DirectThreadBindingsDaoMixin {
  DirectThreadBindingsDao(super.db);

  Future<DirectThreadBindingRow?> getBinding({
    required String localChatId,
    required String profileId,
    required String headMessageId,
  }) =>
      (select(directThreadBindings)..where(
            (table) =>
                table.localChatId.equals(localChatId) &
                table.profileId.equals(profileId) &
                table.headMessageId.equals(headMessageId),
          ))
          .getSingleOrNull();

  Future<DirectThreadBindingRow?> getLatestBinding({
    required String localChatId,
    required String profileId,
  }) =>
      (select(directThreadBindings)
            ..where(
              (table) =>
                  table.localChatId.equals(localChatId) &
                  table.profileId.equals(profileId),
            )
            ..orderBy([
              (table) => OrderingTerm.desc(table.updatedAt),
              (table) => OrderingTerm.desc(table.createdAt),
              (table) => OrderingTerm.desc(table.headMessageId),
            ])
            ..limit(1))
          .getSingleOrNull();

  Future<void> putBinding(DirectThreadBindingsCompanion binding) =>
      into(directThreadBindings).insertOnConflictUpdate(binding);

  Future<void> deleteBinding({
    required String localChatId,
    required String profileId,
    required String headMessageId,
  }) =>
      (delete(directThreadBindings)..where(
            (table) =>
                table.localChatId.equals(localChatId) &
                table.profileId.equals(profileId) &
                table.headMessageId.equals(headMessageId),
          ))
          .go();

  /// Deletes only chats owned by one ChatGPT account. Message rows and
  /// bindings cascade from the chat envelope; unrelated direct chats remain.
  Future<int> deleteAccountChats(String accountFingerprint) async {
    return transaction(() async {
      final bindings =
          await (select(directThreadBindings)..where(
                (table) => table.accountFingerprint.equals(accountFingerprint),
              ))
              .get();
      final candidateChatIds = bindings
          .map((binding) => binding.localChatId)
          .toSet();
      await (delete(directThreadBindings)..where(
            (table) => table.accountFingerprint.equals(accountFingerprint),
          ))
          .go();

      var deleted = 0;
      for (final chatId in candidateChatIds) {
        final remainingBinding =
            await (select(directThreadBindings)
                  ..where((table) => table.localChatId.equals(chatId))
                  ..limit(1))
                .getSingleOrNull();
        if (remainingBinding != null) continue;
        deleted += await (delete(
          chats,
        )..where((table) => table.id.equals(chatId))).go();
      }
      return deleted;
    });
  }

  /// Deletes every chat carrying a ChatGPT transport ownership binding. This is
  /// used only to resume a single-account disconnect whose non-secret
  /// fingerprint tombstone could not be written before termination.
  Future<int> deleteAllBoundChats() async {
    return transaction(() async {
      final bindings = await select(directThreadBindings).get();
      final candidateChatIds = bindings
          .map((binding) => binding.localChatId)
          .toSet();
      await delete(directThreadBindings).go();

      var deleted = 0;
      for (final chatId in candidateChatIds) {
        deleted += await (delete(
          chats,
        )..where((table) => table.id.equals(chatId))).go();
      }
      return deleted;
    });
  }
}
