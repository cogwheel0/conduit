import 'package:drift/drift.dart';

/// Unsent input, local to this database's account. Never part of a chat blob
/// or an outbox operation. Empty chat ids identify the new-chat input.
class ComposerDrafts extends Table {
  TextColumn get scope => text()();
  TextColumn get chatId => text()();
  TextColumn get content => text()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {scope, chatId};
}
