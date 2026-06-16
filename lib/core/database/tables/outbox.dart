import 'package:drift/drift.dart';

/// Outbox operation queue (CDT-RFC-001 §6, §7.2).
///
/// Ships in Phase 1 so the schema is final; drained in Phase 2. No DAO in
/// Phase 1.
@DataClassName('OutboxOp')
class OutboxOps extends Table {
  @override
  List<String> get customConstraints => const [
    "CHECK (kind IN ('createChat', 'updateChat', 'deleteChat', 'requestCompletion', 'folderUpsert', 'folderDelete', 'noteCreate', 'noteUpdate', 'noteDelete', 'notePin'))",
    "CHECK (status IN ('pending', 'inFlight', 'failed'))",
    'CHECK (attempts >= 0)',
  ];

  IntColumn get seq => integer().autoIncrement()();

  /// createChat|updateChat|deleteChat|requestCompletion|folderUpsert|folderDelete|noteCreate|noteUpdate|noteDelete|notePin
  TextColumn get kind => text()();
  TextColumn get chatId => text().nullable()();
  TextColumn get payload => text().withDefault(const Constant('{}'))();

  /// pending|inFlight|failed
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  IntColumn get nextAttemptAt => integer().nullable()();
  TextColumn get lastError => text().nullable()();

  /// Set ONLY on `createChat` ops: the §7.3 crash-heal fingerprint
  /// (`createChatContentHash`). A pull that merges a server chat whose blob
  /// hashes to this value remaps the local chat to the server id instead of
  /// inserting a duplicate. Null for every other kind.
  TextColumn get contentHash => text().nullable()();
}
