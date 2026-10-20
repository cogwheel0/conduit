import 'package:drift/drift.dart';

import 'chats.dart';

/// Message rows decomposed from the chat blob (CDT-RFC-001 §6, amendment A4).
@DataClassName('MessageRow')
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get chatId =>
      text().references(Chats, #id, onDelete: KeyAction.cascade)();
  TextColumn get parentId => text().nullable()();
  TextColumn get role => text()();
  TextColumn get content => text()();
  TextColumn get model => text().nullable()();

  /// Epoch seconds, server clock (message `timestamp`).
  IntColumn get createdAt => integer()();

  /// Amendment A4: load-bearing for `rowsToBlob` ordering and the
  /// `watchForChat` tiebreak.
  IntColumn get orderIndex => integer()();

  /// FULL original message JSON (source of truth).
  TextColumn get payload => text()();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {chatId, id};
}
