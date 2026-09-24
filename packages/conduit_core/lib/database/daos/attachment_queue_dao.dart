import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/attachment_queue.dart';

part 'attachment_queue_dao.g.dart';

/// Accessor for the per-server [AttachmentQueue] table.
@DriftAccessor(tables: [AttachmentQueue])
class AttachmentQueueDao extends DatabaseAccessor<AppDatabase>
    with _$AttachmentQueueDaoMixin {
  AttachmentQueueDao(super.db);

  /// All queued attachments, oldest first.
  Future<List<AttachmentQueueData>> getAll() {
    return (select(
      attachmentQueue,
    )..orderBy([(t) => OrderingTerm.asc(t.enqueuedAt)])).get();
  }

  Future<void> upsert(AttachmentQueueCompanion row) {
    return into(attachmentQueue).insertOnConflictUpdate(row);
  }

  Future<void> deleteById(String id) {
    return (delete(attachmentQueue)..where((t) => t.id.equals(id))).go();
  }

  Future<void> clearAll() {
    return delete(attachmentQueue).go();
  }
}
