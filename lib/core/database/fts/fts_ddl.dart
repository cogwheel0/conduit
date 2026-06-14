/// FTS5 DDL for the offline full-text search index (CDT-RFC-001 Phase 4).
///
/// A STANDALONE (own-storage) FTS5 table is used — NOT external-content — for
/// the reasons spelled out in the Phase 4 FTS contract (§A):
///  1. the messages PK is a composite TEXT {chatId, id}; there is no stable
///     INTEGER rowid the app controls, so external-content cannot key reliably
///     and the delete-then-reinsert churn in the merge writers would desync the
///     shadow rowid map;
///  2. §6 requires indexing BOTH `messages.content` AND `chats.title` — two
///     sources, one query, which external-content over a single table cannot
///     express;
///  3. standalone lets us store chatId/messageId UNINDEXED so a hit maps
///     straight back to a chat row without a rowid join.
///
/// The duplicated content text storage cost is acceptable and bounded by the
/// same content already in `messages.content`.
///
/// All statements use IF NOT EXISTS and are safe to (re)run on every open.
library;

/// The single virtual table. One physical `text` column (not separate
/// content/title columns) keeps bm25 weighting simple and lets title + message
/// rows coexist; `kind` disambiguates for trigger-driven replacement.
///
/// Tokenizer: `unicode61 remove_diacritics 2` is the modern default. Porter
/// stemming is deliberately avoided — it surprises users searching code or
/// identifiers.
const String kCreateChatFts = '''
CREATE VIRTUAL TABLE IF NOT EXISTS chat_fts USING fts5(
  text,
  chat_id UNINDEXED,
  message_id UNINDEXED,
  kind UNINDEXED,
  tokenize = 'unicode61 remove_diacritics 2'
);
''';

/// The chat triggers covering EVERY write path. SQL triggers fire regardless of
/// the Dart path that issued the write.
///
/// FK-CASCADE GOTCHA: messages are deleted by FK cascade in
/// hardDelete/dropLocalChat/purgeReconciledChat. SQLite does NOT fire AFTER
/// DELETE row triggers for FK-cascade deletes unless PRAGMA
/// recursive_triggers=ON (only foreign_keys=ON is set). RESOLUTION: trigger #6
/// (chats AFTER DELETE) is the explicit, complete purge for BOTH the title row
/// and all message rows of a chat. The messages AFTER DELETE trigger (#2) still
/// correctly handles the per-message direct delete+reinsert churn in the merge
/// writers (those are direct deletes on `messages`, not cascades).
const List<String> kChatFtsTriggers = <String>[
  // 1. messages AFTER INSERT
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_msg_ai AFTER INSERT ON messages BEGIN
  INSERT INTO chat_fts(text, chat_id, message_id, kind)
  VALUES (new.content, new.chat_id, new.id, 'msg');
END;
''',
  // 2. messages AFTER DELETE (direct deletes only; see FK-cascade gotcha)
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_msg_ad AFTER DELETE ON messages BEGIN
  DELETE FROM chat_fts
  WHERE kind = 'msg' AND chat_id = old.chat_id AND message_id = old.id;
END;
''',
  // 3. messages AFTER UPDATE OF content — unconditional delete+insert.
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_msg_au AFTER UPDATE OF content ON messages
BEGIN
  DELETE FROM chat_fts
  WHERE kind = 'msg' AND chat_id = old.chat_id AND message_id = old.id;
  INSERT INTO chat_fts(text, chat_id, message_id, kind)
  VALUES (new.content, new.chat_id, new.id, 'msg');
END;
''',
  // 4. chats AFTER INSERT
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_chat_ai AFTER INSERT ON chats BEGIN
  INSERT INTO chat_fts(text, chat_id, message_id, kind)
  VALUES (new.title, new.id, '', 'title');
END;
''',
  // 5. chats AFTER UPDATE OF title (guarded so unrelated envelope writes skip)
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_chat_au AFTER UPDATE OF title ON chats
WHEN new.title <> old.title BEGIN
  DELETE FROM chat_fts WHERE kind = 'title' AND chat_id = old.id;
  INSERT INTO chat_fts(text, chat_id, message_id, kind)
  VALUES (new.title, new.id, '', 'title');
END;
''',
  // 6. chats AFTER UPDATE OF deleted — soft-delete purges title + msg rows.
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_chat_deleted_au
AFTER UPDATE OF deleted ON chats
WHEN new.deleted = 1 BEGIN
  DELETE FROM chat_fts
  WHERE chat_id = old.id AND kind IN ('title', 'msg');
END;
''',
  // 7. chats AFTER DELETE — purges BOTH title and all msg rows for the chat.
  //    This is the complete purge that covers FK-cascaded message deletes.
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_chat_ad AFTER DELETE ON chats BEGIN
  DELETE FROM chat_fts
  WHERE chat_id = old.id AND kind IN ('title', 'msg');
END;
''',
];

/// Phase 5 NOTES triggers (CDT-RFC-001 Phase 5 / uiContract §FTS).
///
/// Notes are flat documents (no message rows), so they reuse the SINGLE
/// `chat_fts` vtable rather than forking a parallel notes index (NON-NEG 6).
/// The vtable's `chat_id` column is mentally "owner_id"; a note keys its rows by
/// the note id in `chat_id` with `message_id = ''`. Two new kinds partition the
/// note rows from chat rows:
///   * `'note_title'` — the note's title.
///   * `'note_text'`  — the note body, extracted from the JSON `data` column via
///     `json_extract(data, '$.content.md')` (the body lives at
///     `data['content']['md']`, NOT the raw JSON blob).
///
/// COLLISION SAFETY: note ids and chat ids can overlap because both are
/// server-generated UUIDs. Every note maintenance statement is kind-scoped so
/// a note row never purges or rewrites chat title/message rows with the same id.
///
/// JSON1 note: `json_extract` ships in the default SQLite builds drift uses on
/// iOS/Android (sqlite3_flutter_libs bundles a JSON1-enabled amalgamation), so
/// extracting the markdown body in-trigger is safe. `coalesce(..., '')` guards a
/// missing/NULL path so the FTS row is never NULL (which FTS5 would reject).
const List<String> kNoteFtsTriggers = <String>[
  // 7. notes AFTER INSERT → title row + extracted-body text row.
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_note_ai AFTER INSERT ON notes BEGIN
  INSERT INTO chat_fts(text, chat_id, message_id, kind)
  VALUES (new.title, new.id, '', 'note_title');
  INSERT INTO chat_fts(text, chat_id, message_id, kind)
  VALUES (coalesce(json_extract(new.data, '\$.content.md'), ''),
          new.id, '', 'note_text');
END;
''',
  // 8. notes AFTER UPDATE OF title (guarded so unrelated column writes skip).
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_note_title_au AFTER UPDATE OF title ON notes
WHEN new.title <> old.title BEGIN
  DELETE FROM chat_fts WHERE kind = 'note_title' AND chat_id = old.id;
  INSERT INTO chat_fts(text, chat_id, message_id, kind)
  VALUES (new.title, new.id, '', 'note_title');
END;
''',
  // 9. notes AFTER UPDATE OF data — re-extract the body (guarded on raw data).
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_note_data_au AFTER UPDATE OF data ON notes
WHEN new.data <> old.data BEGIN
  DELETE FROM chat_fts WHERE kind = 'note_text' AND chat_id = old.id;
  INSERT INTO chat_fts(text, chat_id, message_id, kind)
  VALUES (coalesce(json_extract(new.data, '\$.content.md'), ''),
          new.id, '', 'note_text');
END;
''',
  // 10. notes AFTER UPDATE OF deleted — soft-delete purges both note kinds.
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_note_deleted_au
AFTER UPDATE OF deleted ON notes
WHEN new.deleted = 1 BEGIN
  DELETE FROM chat_fts
  WHERE chat_id = old.id AND kind IN ('note_title', 'note_text');
END;
''',
  // 11. notes AFTER DELETE — purges BOTH note kinds for the note id.
  '''
CREATE TRIGGER IF NOT EXISTS chat_fts_note_ad AFTER DELETE ON notes BEGIN
  DELETE FROM chat_fts
  WHERE chat_id = old.id AND kind IN ('note_title', 'note_text');
END;
''',
];

/// Backfill statements run once, post-first-sync (or in onUpgrade for installs
/// already past first sync). `INSERT ... SELECT` from the live tables.
const String kBackfillMessages = '''
INSERT INTO chat_fts(text, chat_id, message_id, kind)
SELECT m.content, m.chat_id, m.id, 'msg'
FROM messages m
JOIN chats c ON c.id = m.chat_id
WHERE c.deleted = 0;
''';

const String kBackfillTitles = '''
INSERT INTO chat_fts(text, chat_id, message_id, kind)
SELECT title, id, '', 'title' FROM chats WHERE deleted = 0;
''';

/// Phase 5 NOTES backfill (run in `onUpgrade from<5` and in
/// [buildFtsIfNeeded] alongside the chat backfills). `INSERT ... SELECT` from
/// the live `notes` table, excluding tombstones.
const String kBackfillNoteTitles = '''
INSERT INTO chat_fts(text, chat_id, message_id, kind)
SELECT title, id, '', 'note_title' FROM notes WHERE deleted = 0;
''';

const String kBackfillNoteText = '''
INSERT INTO chat_fts(text, chat_id, message_id, kind)
SELECT coalesce(json_extract(data, '\$.content.md'), ''), id, '', 'note_text'
FROM notes WHERE deleted = 0;
''';

/// `sync_meta` key marking the one-time FTS backfill as complete. Dedicated and
/// independent of `hive_cache_purged` so it is separately re-runnable on
/// failure.
const String kFtsBuiltKey = 'fts_built';
