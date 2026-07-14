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

/// Access phases for the server-scoped OpenWebUI database.
///
/// During bootstrap only the optimized auth cache may inspect the database so
/// a saved session can restore offline. Chat/sync providers remain closed until
/// that session is certified. A terminal unauthenticated transition moves to
/// [purging], where neither path may reopen the file while it is being deleted.
enum OpenWebUiDatabaseAccessPhase { bootstrap, purging, closed, open }

extension OpenWebUiDatabaseAccessPhaseX on OpenWebUiDatabaseAccessPhase {
  bool get allowsAppDatabase => this == OpenWebUiDatabaseAccessPhase.open;

  bool get allowsStorageDatabase =>
      this == OpenWebUiDatabaseAccessPhase.bootstrap || allowsAppDatabase;
}

final openWebUiDatabaseAccessProvider =
    NotifierProvider<
      OpenWebUiDatabaseAccessNotifier,
      OpenWebUiDatabaseAccessPhase
    >(OpenWebUiDatabaseAccessNotifier.new);

final openWebUiCertifiedDatabaseServerProvider =
    NotifierProvider<OpenWebUiCertifiedDatabaseServerNotifier, String?>(
      OpenWebUiCertifiedDatabaseServerNotifier.new,
    );

class OpenWebUiCertifiedDatabaseServerNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String serverId) => state = serverId;

  void clear() => state = null;
}

class OpenWebUiDatabaseAccessNotifier
    extends Notifier<OpenWebUiDatabaseAccessPhase> {
  @override
  OpenWebUiDatabaseAccessPhase build() =>
      OpenWebUiDatabaseAccessPhase.bootstrap;

  void beginPurge() => state = OpenWebUiDatabaseAccessPhase.purging;

  void close() => state = OpenWebUiDatabaseAccessPhase.closed;

  void open() => state = OpenWebUiDatabaseAccessPhase.open;
}

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

typedef OpenWebUiDatabasePurge = Future<void> Function(String serverId);

/// Testable deletion boundary used by account-session isolation.
final openWebUiDatabasePurgeProvider = Provider<OpenWebUiDatabasePurge>((ref) {
  final manager = ref.watch(databaseManagerProvider);
  return manager.deleteFor;
});

/// The active server's database, or null when no active server / reviewer
/// mode (mirrors `apiServiceProvider`'s gate).
///
/// Rebuilds on active-server change; the manager swaps the open database and
/// every downstream Drift stream re-derives automatically. This provider does
/// NOT close the database in onDispose — the manager owns lifecycle.
@Riverpod(keepAlive: true)
AppDatabase? appDatabase(Ref ref) {
  if (!ref.watch(openWebUiDatabaseAccessProvider).allowsAppDatabase) {
    return null;
  }
  final reviewerMode = ref.watch(reviewerModeProvider);
  if (reviewerMode) {
    return null;
  }
  final activeServer = ref.watch(activeServerProvider);
  final certifiedServerId = ref.watch(openWebUiCertifiedDatabaseServerProvider);
  final manager = ref.watch(databaseManagerProvider);
  return activeServer.maybeWhen(
    data: (server) {
      if (server == null || server.id != certifiedServerId) return null;
      return switch (manager.openForIfReady(server)) {
        DatabaseOpenReady(:final database) => database,
        DatabaseOpenDeferred(:final retryAfter) => _retryAppDatabaseOpen(
          ref,
          retryAfter,
        ),
      };
    },
    orElse: () => null,
  );
}

AppDatabase? _retryAppDatabaseOpen(Ref ref, Future<void> retryAfter) {
  // Keep the provider synchronous for its many Drift consumers, but represent
  // an overlapping close as temporary unavailability. Once the old executor
  // has completely released its SQLite file, rebuild against whichever server
  // is current at that point. Both success and failure are retryable here: the
  // manager owns close-failure recovery and the primary deletion caller owns
  // reporting deletion failures.
  unawaited(
    retryAfter.then<void>(
      (_) {
        if (ref.mounted) ref.invalidateSelf();
      },
      onError: (Object _, StackTrace _) {
        if (ref.mounted) ref.invalidateSelf();
      },
    ),
  );
  return null;
}

/// Provenance-aware resolver over the active Open WebUI database (if any) and
/// the independent direct-local database.
final chatDatabaseRepositoryProvider = Provider<ChatDatabaseRepository>((ref) {
  return ChatDatabaseRepository(
    openWebUiDatabase: ref.watch(appDatabaseProvider),
    directLocalDatabase: ref.watch(directLocalDatabaseProvider),
  );
});
