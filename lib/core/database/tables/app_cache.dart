import 'package:drift/drift.dart';

/// Per-server key-value cache for non-sync app data that was previously held in
/// the Hive `caches` box (local user, avatar, backend config, tools, default
/// model, models). The database is already per-server, so no `serverId` column
/// is needed — the file IS the server scope.
///
/// Values are JSON strings (or a plain string for the avatar URL). These are
/// offline-fallback caches: re-fetched from the network when stale, so losing
/// a non-active server's cache on migration is acceptable.
class AppCache extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  /// Epoch milliseconds of the last write (advisory; not used for invalidation).
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {key};
}
