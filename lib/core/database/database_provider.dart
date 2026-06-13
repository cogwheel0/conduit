import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/app_providers.dart';
import 'app_database.dart';
import 'database_manager.dart';

part 'database_provider.g.dart';

/// Owns per-server database lifecycle; never recreated (keepAlive).
@Riverpod(keepAlive: true)
DatabaseManager databaseManager(Ref ref) => DatabaseManager();

/// The active server's database, or null when no active server / reviewer
/// mode (mirrors `apiServiceProvider`'s gate).
///
/// Rebuilds on active-server change; the manager swaps the open database and
/// every downstream Drift stream re-derives automatically. This provider does
/// NOT close the database in onDispose — the manager owns lifecycle.
@Riverpod(keepAlive: true)
AppDatabase? appDatabase(Ref ref) {
  final reviewerMode = ref.watch(reviewerModeProvider);
  if (reviewerMode) {
    return null;
  }
  final activeServer = ref.watch(activeServerProvider);
  final manager = ref.watch(databaseManagerProvider);
  return activeServer.maybeWhen(
    data: (server) {
      if (server == null) return null;
      return manager.openFor(server);
    },
    orElse: () => null,
  );
}
