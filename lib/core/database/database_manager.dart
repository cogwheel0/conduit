import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/server_config.dart';
import '../utils/debug_logger.dart';
import 'app_database.dart';

/// Owns the per-server [AppDatabase] lifecycle (CDT-RFC-001 §6, D-08).
///
/// At most ONE database is open at a time. The same `server.id` returns the
/// cached instance; a different id schedules the previous database's close
/// and opens a new one.
class DatabaseManager {
  /// [databaseDirectory] and [openDatabase] are test seams; production code
  /// uses the defaults (`getApplicationSupportDirectory`, matching
  /// `AppDatabase.forServer`'s `driftDatabase(name:)` location).
  DatabaseManager({
    Future<Directory> Function()? databaseDirectory,
    AppDatabase Function(String fileName)? openDatabase,
    String Function(String serverId)? databaseFileName,
  }) : _databaseDirectory = databaseDirectory ?? getApplicationSupportDirectory,
       _openDatabase = openDatabase ?? AppDatabase.forServer,
       _databaseFileName = databaseFileName ?? fileNameFor;

  final Future<Directory> Function() _databaseDirectory;
  final AppDatabase Function(String fileName) _openDatabase;
  final String Function(String serverId) _databaseFileName;

  AppDatabase? _active;
  String? _activeServerId;
  Future<void>? _pendingClose;
  final Map<String, String> _fileOwners = <String, String>{};

  /// Sync, lazy-open accessor for [server]'s database.
  AppDatabase openFor(ServerConfig server) => openForServerId(server.id);

  /// Sync, lazy-open accessor when only the stable server id is available.
  AppDatabase openForServerId(String serverId) {
    final fileName = _databaseFileName(serverId);
    final owner = _fileOwners[fileName];
    if (owner != null && owner != serverId) {
      throw StateError(
        'Database file $fileName is already owned by logical id $owner.',
      );
    }
    final existing = _active;
    if (existing != null && _activeServerId == serverId) {
      return existing;
    }
    if (existing != null) {
      final previousId = _activeServerId;
      DebugLogger.log(
        'close-previous',
        scope: 'db/manager',
        data: {'serverId': previousId},
      );
      // Fire-and-forget: downstream streams re-derive from the new database.
      // Tracked via [_pendingClose] so [deleteFor] can await an in-flight
      // close before deleting the previous server's files.
      final prior = _pendingClose;
      _pendingClose =
          (prior == null
                  ? existing.close()
                  : prior.then((_) => existing.close()))
              .catchError((Object error) {
                DebugLogger.error(
                  'close-failed',
                  scope: 'db/manager',
                  error: error,
                  data: {'serverId': previousId},
                );
              });
    }
    DebugLogger.log('open', scope: 'db/manager', data: {'serverId': serverId});
    final claimedFile = owner == null;
    if (claimedFile) _fileOwners[fileName] = serverId;
    late final AppDatabase db;
    try {
      db = _openDatabase(fileName);
    } catch (_) {
      if (claimedFile) _fileOwners.remove(fileName);
      rethrow;
    }
    _active = db;
    _activeServerId = serverId;
    return db;
  }

  Future<void> closeActive() async {
    final active = _active;
    final pending = _pendingClose;
    _active = null;
    _activeServerId = null;
    _pendingClose = null;
    if (pending != null) {
      await pending;
    }
    if (active != null) {
      DebugLogger.log('close-active', scope: 'db/manager');
      await active.close();
    }
  }

  /// Closes the active database when it belongs to [serverId], then deletes
  /// the database file plus its `-wal` and `-shm` siblings.
  ///
  /// `drift_flutter`'s `driftDatabase(name:)` stores the file as
  /// `<directory>/<name>.sqlite` (verified against drift_flutter 0.x
  /// `_openConnection`); WAL mode produces `.sqlite-wal` / `.sqlite-shm`
  /// siblings.
  Future<void> deleteFor(String serverId) async {
    final fileName = _databaseFileName(serverId);
    final owner = _fileOwners[fileName];
    if (owner != null && owner != serverId) {
      throw StateError(
        'Cannot delete database file $fileName owned by logical id $owner.',
      );
    }
    if (_activeServerId == serverId) {
      await closeActive();
    }
    // Await any in-flight close from a prior server switch ([openFor]) so we
    // never delete files while the previous database is still closing.
    final pending = _pendingClose;
    _pendingClose = null;
    if (pending != null) {
      await pending;
    }
    final directory = await _databaseDirectory();
    final base = p.join(directory.path, '$fileName.sqlite');
    for (final path in [base, '$base-wal', '$base-shm']) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
    if (owner == serverId) _fileOwners.remove(fileName);
    DebugLogger.log(
      'deleted',
      scope: 'db/manager',
      data: {'serverId': serverId},
    );
  }

  /// Filesystem-safe, collision-free encoding of [serverId].
  static String fileNameFor(String serverId) {
    final encoded = base64Url.encode(utf8.encode(serverId)).replaceAll('=', '');
    return 'server_$encoded';
  }
}
