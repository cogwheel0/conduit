import 'dart:io';

import 'package:conduit_core/ports/database_opener.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import '../daemon_paths.dart';

/// The desktop [DatabaseOpenerPort].
///
/// Same file layout as mobile -- `<dir>/<serverId>.sqlite`, the name still
/// derived by `DatabaseManager.fileNameFor` -- but under Electron's
/// `userData` rather than the iOS application-support directory, and opened
/// with drift's plain `NativeDatabase` instead of `drift_flutter`.
///
/// `createInBackground` puts SQLite on its own isolate. On mobile that is
/// about keeping the UI thread free; here it is about keeping the RPC event
/// loop free, so a long FTS build cannot stall the heartbeat and make a
/// healthy daemon look wedged.
final class DaemonDatabaseOpener implements DatabaseOpenerPort {
  const DaemonDatabaseOpener(this.directories);

  final DaemonDirectories directories;

  @override
  QueryExecutor open(String serverId) => NativeDatabase.createInBackground(
    File(p.join(directories.paths.database, '$serverId.sqlite')),
  );

  @override
  Future<Directory> databaseDirectory() async {
    final directory = Directory(directories.paths.database);
    if (!directory.existsSync()) directory.createSync(recursive: true);
    return directory;
  }
}
