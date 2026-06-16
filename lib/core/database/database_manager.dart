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
  }) : _databaseDirectory = databaseDirectory ?? getApplicationSupportDirectory,
       _openDatabase = openDatabase ?? AppDatabase.forServer;

  final Future<Directory> Function() _databaseDirectory;
  final AppDatabase Function(String fileName) _openDatabase;

  AppDatabase? _active;
  String? _activeServerId;
  Future<void>? _pendingClose;

  /// Sync, lazy-open accessor for [server]'s database.
  AppDatabase openFor(ServerConfig server) {
    final existing = _active;
    if (existing != null && _activeServerId == server.id) {
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
      _pendingClose = existing.close().catchError((Object error) {
        DebugLogger.error(
          'close-failed',
          scope: 'db/manager',
          error: error,
          data: {'serverId': previousId},
        );
      });
    }
    DebugLogger.log('open', scope: 'db/manager', data: {'serverId': server.id});
    final db = _openDatabase(fileNameFor(server.id));
    _active = db;
    _activeServerId = server.id;
    return db;
  }

  Future<void> closeActive() async {
    final active = _active;
    _active = null;
    _activeServerId = null;
    _pendingClose = null;
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
    final base = p.join(directory.path, '${fileNameFor(serverId)}.sqlite');
    for (final path in [base, '$base-wal', '$base-shm']) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
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
