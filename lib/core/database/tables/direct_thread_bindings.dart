import 'package:drift/drift.dart';

import 'chats.dart';

/// Durable ChatGPT transport state for a Conduit-owned direct chat branch.
@DataClassName('DirectThreadBindingRow')
class DirectThreadBindings extends Table {
  TextColumn get localChatId =>
      text().references(Chats, #id, onDelete: KeyAction.cascade)();
  TextColumn get profileId => text()();
  TextColumn get headMessageId => text()();
  TextColumn get transportSessionId => text()();
  TextColumn get checkpointThroughMessageId => text().nullable()();
  BlobColumn get compactCheckpoint => blob().nullable()();
  IntColumn get lastInputTokens => integer().nullable()();
  TextColumn get modelId => text()();
  TextColumn get accountFingerprint => text()();
  BoolColumn get webSearchEnabled =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get imageGenerationEnabled =>
      boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {localChatId, profileId, headMessageId};
}
