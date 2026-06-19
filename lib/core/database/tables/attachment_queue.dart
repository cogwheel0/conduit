import 'package:drift/drift.dart';

/// Per-server durable queue of pending attachment uploads (previously the Hive
/// `attachment_queue` box). One row per queued attachment; the active server's
/// database owns its queue, so uploads always target the active server.
///
/// Mirrors the legacy `QueuedAttachment` model. `status` is the
/// `QueuedAttachmentStatus` name; `enqueuedAt`/`nextRetryAt` are epoch millis.
class AttachmentQueue extends Table {
  TextColumn get id => text()();
  TextColumn get filePath => text()();
  TextColumn get fileName => text()();
  IntColumn get fileSize => integer()();
  TextColumn get mimeType => text().nullable()();
  TextColumn get checksum => text().nullable()();

  TextColumn get status => text()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  IntColumn get nextRetryAt => integer().nullable()();
  TextColumn get lastError => text().nullable()();
  TextColumn get fileId => text().nullable()();

  IntColumn get enqueuedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}
