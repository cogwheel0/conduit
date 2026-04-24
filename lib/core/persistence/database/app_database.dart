import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../utils/debug_logger.dart';

/// Owns the app's SQLite database connection and schema.
///
/// Uses sqflite directly (no codegen). Schema and migrations are declared
/// as raw SQL in [_onCreate] / [_onUpgrade]. Bump [_schemaVersion] when
/// changing tables.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  /// Underlying connection. Prefer the typed methods on
  /// [ConversationStore]; this is exposed for tests and migrations.
  Database get raw => _db;

  static const int _schemaVersion = 1;
  static const String _fileName = 'conduit.db';

  /// Opens (or creates) the database at the app's documents directory.
  static Future<AppDatabase> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _fileName);
    final db = await openDatabase(
      path,
      version: _schemaVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    DebugLogger.log('Opened database at $path', scope: 'persistence/db');
    return AppDatabase._(db);
  }

  /// Opens an in-memory database. For unit tests only — callers must arrange
  /// for `databaseFactoryFfi` to be installed before this is used outside of
  /// the iOS/Android runtime.
  static Future<AppDatabase> openInMemory({
    DatabaseFactory? factoryOverride,
  }) async {
    final factory = factoryOverride ?? databaseFactory;
    final db = await factory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return AppDatabase._(db);
  }

  Future<void> close() => _db.close();

  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        cached_at INTEGER NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        message_count INTEGER NOT NULL DEFAULT 0,
        last_message_preview TEXT,
        payload_json TEXT NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY NOT NULL,
        conversation_id TEXT NOT NULL
          REFERENCES conversations (id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        parent_id TEXT,
        payload_json TEXT NOT NULL
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_msg_conv_ts ON messages (conversation_id, timestamp)',
    );
    batch.execute('CREATE INDEX idx_msg_parent ON messages (parent_id)');
    batch.execute(
      'CREATE INDEX idx_conv_updated ON conversations (updated_at DESC)',
    );
    batch.execute(
      'CREATE INDEX idx_conv_pinned_updated '
      'ON conversations (pinned DESC, updated_at DESC)',
    );
    await batch.commit(noResult: true);
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // No upgrade steps yet — schema v1 is the first release.
    // When adding a v2 table change, add a step here:
    //   if (oldVersion < 2) { await db.execute('ALTER TABLE ...'); }
  }
}
