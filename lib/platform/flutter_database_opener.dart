import 'dart:io';

import 'package:conduit_core/conduit_core.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// The Flutter app's [DatabaseOpenerPort].
///
/// Keeps `drift_flutter` and `path_provider` — both of which need a Flutter
/// engine — out of `lib/core`, so the database layer can be hosted by the
/// `conduitd` sidecar unchanged.
///
/// The file layout is unchanged from before the port existed:
/// `drift_flutter`'s `driftDatabase(name:)` writes
/// `<applicationSupportDirectory>/<serverId>.sqlite`, and
/// `DatabaseManager.fileNameFor` still derives the name. Existing installs
/// keep their databases.
class FlutterDatabaseOpener implements DatabaseOpenerPort {
  const FlutterDatabaseOpener();

  @override
  QueryExecutor open(String serverId) => driftDatabase(
    name: serverId,
    native: const DriftNativeOptions(
      databaseDirectory: getApplicationSupportDirectory,
    ),
  );

  @override
  Future<Directory> databaseDirectory() => getApplicationSupportDirectory();
}
