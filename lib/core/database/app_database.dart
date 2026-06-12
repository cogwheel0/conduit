import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'tables/sync_meta.dart';

part 'app_database.g.dart';

/// Conduit's per-server local database (CDT-RFC-001).
///
/// Phase 0 scaffold: codegen wired, sync_meta only. Tables for chats,
/// messages, folders, and the outbox arrive in Phase 1; the schema version
/// stays at 1 until the first release that ships them.
///
/// One database file exists per [ServerConfig]; lifecycle (open/close/delete
/// on server switch or removal) is owned by the Phase 1 DatabaseManager.
@DriftDatabase(tables: [SyncMeta])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Opens the database file for [serverId] on a background isolate.
  ///
  /// This function is the single seam where at-rest encryption (SQLCipher)
  /// can be introduced later (CDT-RFC-001 D-08).
  factory AppDatabase.forServer(String serverId) {
    return AppDatabase(
      driftDatabase(
        name: serverId,
        native: DriftNativeOptions(
          databaseDirectory: getApplicationSupportDirectory,
        ),
      ),
    );
  }

  @override
  int get schemaVersion => 1;
}
