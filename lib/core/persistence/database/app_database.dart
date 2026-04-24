import 'dart:async';
import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

  static const int _schemaVersion = 3;
  static const String _fileName = 'conduit.db';

  /// Opens (or creates) the database at the app's documents directory.
  ///
  /// On Android, switches sqflite to FFI mode so it uses the sqlite3 library
  /// bundled by [sqlite3_flutter_libs] instead of the system SQLite. The
  /// system SQLite on Android omits FTS5; the bundled one includes it.
  static Future<AppDatabase> open() async {
    if (Platform.isAndroid) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
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
    // v2 — FTS5 over message content for offline full-text search.
    await _createMessagesFtsAndTriggers(db);
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 3) {
      // Drop any partial FTS artifacts from a broken v2 schema (FTS5 failed
      // on Android because system SQLite omits that module).
      await db.execute('DROP TABLE IF EXISTS messages_fts');
      await db.execute('DROP TRIGGER IF EXISTS messages_ai');
      await db.execute('DROP TRIGGER IF EXISTS messages_ad');
      await db.execute('DROP TRIGGER IF EXISTS messages_au');
      await _createMessagesFtsAndTriggers(db);
      await _backfillMessagesFts(db);
    }
  }

  /// Phase 4b — FTS5 virtual table mirroring message text.
  ///
  /// External-content design: the index lives in [messages_fts] but the
  /// actual text stays in [messages.payload_json]. Triggers keep the two
  /// in sync; FTS5 reads the source via `json_extract` only when
  /// `snippet()` / `highlight()` need the original text. This avoids
  /// double-storing message bodies on disk.
  ///
  /// Tokenizer: porter + unicode61 — case-insensitive, stems English
  /// suffixes (`testing`/`tests`/`test` all match), strips diacritics.
  ///
  /// Requires FTS5 — on Android this is provided by [sqlite3_flutter_libs]
  /// which bundles a modern SQLite with FTS5 enabled via dart:ffi.
  static Future<void> _createMessagesFtsAndTriggers(Database db) async {
    final batch = db.batch();
    batch.execute('''
      CREATE VIRTUAL TABLE messages_fts USING fts5(
        content,
        content='messages',
        content_rowid='rowid',
        tokenize='porter unicode61'
      )
    ''');
    batch.execute('''
      CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
        INSERT INTO messages_fts(rowid, content)
        VALUES (
          new.rowid,
          COALESCE(json_extract(new.payload_json, '\$.content'), '')
        );
      END
    ''');
    batch.execute('''
      CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, content)
        VALUES (
          'delete',
          old.rowid,
          COALESCE(json_extract(old.payload_json, '\$.content'), '')
        );
      END
    ''');
    batch.execute('''
      CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, content)
        VALUES (
          'delete',
          old.rowid,
          COALESCE(json_extract(old.payload_json, '\$.content'), '')
        );
        INSERT INTO messages_fts(rowid, content)
        VALUES (
          new.rowid,
          COALESCE(json_extract(new.payload_json, '\$.content'), '')
        );
      END
    ''');
    await batch.commit(noResult: true);
  }

  /// Populates the FTS index from existing rows. Called from [_onUpgrade]
  /// when migrating an installed v1 database — fresh installs hit
  /// [_onCreate] which sets up the empty index and lets triggers fill it
  /// as messages are written.
  static Future<void> _backfillMessagesFts(Database db) async {
    await db.execute('''
      INSERT INTO messages_fts(rowid, content)
      SELECT rowid, COALESCE(json_extract(payload_json, '\$.content'), '')
      FROM messages
    ''');
  }
}
