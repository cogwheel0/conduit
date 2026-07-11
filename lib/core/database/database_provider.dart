import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/app_providers.dart';
import 'app_database.dart';
import 'chat_database_repository.dart';
import 'database_manager.dart';

part 'database_provider.g.dart';

/// Stable logical id and filename for chats created against direct providers
/// without an Open WebUI backend. This is a separate AppDatabase instance, so
/// switching the active Open WebUI server never closes it.
const String kDirectLocalDatabaseId = 'direct-local';
const String kDirectLocalDatabaseFileName = 'direct_local_v1';

/// Independent lifecycle owner for the permanent local-direct database.
final directLocalDatabaseManagerProvider = Provider<DatabaseManager>((ref) {
  final manager = DatabaseManager(
    databaseFileName: (_) => kDirectLocalDatabaseFileName,
  );
  ref.onDispose(() => unawaited(manager.closeActive()));
  return manager;
});

/// Always-available storage for chats that must not depend on Open WebUI.
final directLocalDatabaseProvider = Provider<AppDatabase>((ref) {
  // Flutter unit/widget tests do not register path_provider. Keep the provider
  // override-friendly while giving existing provider tests an isolated store
  // without requiring every ProviderContainer to repeat the same override.
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final database = AppDatabase(NativeDatabase.memory());
    ref.onDispose(() => unawaited(database.close()));
    return database;
  }
  final manager = ref.watch(directLocalDatabaseManagerProvider);
  return manager.openForServerId(kDirectLocalDatabaseId);
});

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

/// Provenance-aware resolver over the active Open WebUI database (if any) and
/// the independent direct-local database.
final chatDatabaseRepositoryProvider = Provider<ChatDatabaseRepository>((ref) {
  return ChatDatabaseRepository(
    openWebUiDatabase: ref.watch(appDatabaseProvider),
    directLocalDatabase: ref.watch(directLocalDatabaseProvider),
  );
});
