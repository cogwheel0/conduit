import 'dart:io';

import 'package:drift/drift.dart';

/// Where the database lives and how it is opened.
///
/// The core owns the schema, the migrations and the FTS DDL, but it must not
/// know whether it is running inside a Flutter app or the `conduitd` sidecar.
/// Those two answer "where does this file go" very differently — `drift_flutter`
/// plus `path_provider` on mobile, an Electron-supplied `userData` directory on
/// desktop — and only this port sees the difference.
///
/// Implementations live outside the core: `lib/platform/` for the Flutter app
/// and `apps/daemon` for the desktop sidecar.
abstract interface class DatabaseOpenerPort {
  /// Opens, creating if needed, the executor backing [serverId]'s database.
  ///
  /// Synchronous because drift's own openers are lazy: the file is not touched
  /// until the first query runs.
  QueryExecutor open(String serverId);

  /// The directory [open] writes into.
  ///
  /// Exposed separately because the lifecycle manager deletes and renames
  /// database files directly when a server is removed, which it cannot do
  /// through a [QueryExecutor].
  Future<Directory> databaseDirectory();
}
