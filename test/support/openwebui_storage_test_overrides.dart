import 'dart:async';

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/misc.dart';

/// Opens an unmanaged in-memory Open WebUI store for narrow provider tests.
///
/// Production databases are opened only after the account-isolation
/// coordinator certifies their server/account owner. Tests that exercise that
/// coordinator should not use this helper; provider tests that deliberately
/// replace [appDatabaseProvider] with an unmanaged database may use it to make
/// their authenticated storage assumption explicit.
List<Override> openWebUiStorageOpenOverrides({AppDatabase? database}) => [
  openWebUiDatabaseAccessProvider.overrideWith(_OpenWebUiDatabaseAccess.new),
  if (database != null)
    appDatabaseProvider.overrideWithValue(database)
  else
    appDatabaseProvider.overrideWith((ref) {
      final testDatabase = AppDatabase(NativeDatabase.memory());
      ref.onDispose(() => unawaited(testDatabase.close()));
      return testDatabase;
    }),
];

class _OpenWebUiDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}
