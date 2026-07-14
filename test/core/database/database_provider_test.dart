import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_manager.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _alpha = ServerConfig(
  id: 'alpha',
  name: 'Alpha',
  url: 'https://alpha.example',
);
const _beta = ServerConfig(
  id: 'beta',
  name: 'Beta',
  url: 'https://beta.example',
);

final _serverSelectionProvider =
    NotifierProvider<_ServerSelection, ServerConfig>(_ServerSelection.new);

class _ServerSelection extends Notifier<ServerConfig> {
  @override
  ServerConfig build() => _alpha;

  void set(ServerConfig server) => state = server;
}

final class _BlockingCloseDatabase extends AppDatabase {
  _BlockingCloseDatabase() : super(NativeDatabase.memory());

  Completer<void>? closeGate;
  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls += 1;
    final gate = closeGate;
    closeGate = null;
    if (gate != null) await gate.future;
    await super.close();
  }
}

void main() {
  test(
    'app database becomes temporarily unavailable during rapid switch-back',
    () async {
      final opened = <String, List<_BlockingCloseDatabase>>{};
      final manager = DatabaseManager(
        openDatabase: (fileName) {
          final database = _BlockingCloseDatabase();
          opened.putIfAbsent(fileName, () => []).add(database);
          return database;
        },
      );
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith(
            (ref) async => ref.watch(_serverSelectionProvider),
          ),
          databaseManagerProvider.overrideWithValue(manager),
        ],
      );
      final subscription = container.listen<AppDatabase?>(
        appDatabaseProvider,
        (_, _) {},
        fireImmediately: true,
      );
      final alphaFile = DatabaseManager.fileNameFor(_alpha.id);
      final alphaCloseGate = Completer<void>();

      addTearDown(() async {
        if (!alphaCloseGate.isCompleted) alphaCloseGate.complete();
        subscription.close();
        container.dispose();
        await manager.closeActive();
      });

      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set(_alpha.id);
      final originalAlpha = await _waitForDatabase(container, _alpha.id);
      await originalAlpha.customSelect('SELECT 1').get();
      opened[alphaFile]!.single.closeGate = alphaCloseGate;

      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set(_beta.id);
      container.read(_serverSelectionProvider.notifier).set(_beta);
      await _waitForDatabase(container, _beta.id);
      await _waitForCloseCall(opened[alphaFile]!.single);

      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set(_alpha.id);
      container.read(_serverSelectionProvider.notifier).set(_alpha);
      await _waitForActiveServer(container, _alpha.id);

      // The old alpha executor still owns the SQLite path. The provider must
      // represent that as temporary unavailability, not throw from its build
      // or open a second executor concurrently.
      check(container.read(appDatabaseProvider)).isNull();
      check(opened[alphaFile]!.length).equals(1);

      alphaCloseGate.complete();
      final reopenedAlpha = await _waitForDatabase(container, _alpha.id);

      check(identical(reopenedAlpha, originalAlpha)).isFalse();
      check(opened[alphaFile]!.length).equals(2);
      check((await reopenedAlpha.customSelect('SELECT 1').get())).isNotEmpty();
    },
  );
}

Future<void> _waitForCloseCall(_BlockingCloseDatabase database) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (database.closeCalls == 0) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('database close never started');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitForActiveServer(
  ProviderContainer container,
  String serverId,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (container.read(activeServerProvider).asData?.value?.id != serverId) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('active server never became $serverId');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

Future<AppDatabase> _waitForDatabase(
  ProviderContainer container,
  String serverId,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final database = container.read(appDatabaseProvider);
    if (database != null &&
        container.read(databaseManagerProvider).serverIdForDatabase(database) ==
            serverId) {
      return database;
    }
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('database for $serverId never became available');
    }
    await Future<void>.delayed(Duration.zero);
  }
}
