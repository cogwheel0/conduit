import 'package:drift/drift.dart';

/// Audio belongs to the unsent input, outside chat history and sync payloads.
/// PCM chunks commit independently, so a killed process never leaves an
/// unplayable media container.
class ComposerRecordings extends Table {
  TextColumn get id => text()();
  TextColumn get scope => text()();
  TextColumn get chatId => text()();
  IntColumn get createdAt => integer()();
  IntColumn get byteCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class ComposerRecordingChunks extends Table {
  TextColumn get recordingId =>
      text().references(ComposerRecordings, #id, onDelete: KeyAction.cascade)();
  IntColumn get sequence => integer()();
  BlobColumn get pcm => blob()();

  @override
  Set<Column> get primaryKey => {recordingId, sequence};
}
