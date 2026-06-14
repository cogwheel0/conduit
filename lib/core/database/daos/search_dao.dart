import 'package:drift/drift.dart';

import '../app_database.dart';
import '../fts/fts_ddl.dart';
import '../fts/fts_query.dart';
import '../tables/chats.dart';
import '../tables/notes.dart';

part 'search_dao.g.dart';

/// One ranked full-text search result, grouped to a single chat
/// (CDT-RFC-001 Phase 4 §F).
///
/// Carries the SAME narrow [ChatListEntry] envelope fields (so it maps to
/// `Conversation` via `conversationFromListEntry`'s shape; REQ §10.2 — no
/// message bodies leak into the list/search projection) PLUS the
/// search-specific [snippet], [messageId] of the best-scoring hit, and the
/// bm25 [rank].
enum SearchHitKind { chat, note }

class SearchHit {
  const SearchHit({
    required this.chatId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.pinned,
    required this.archived,
    required this.rank,
    this.kind = SearchHitKind.chat,
    this.folderId,
    this.lastReadAt,
    this.snippet,
    this.messageId,
  });

  /// Whether this hit is a chat or a note (CDT-RFC-001 Phase 5). The UI routes
  /// a note hit to the note editor and a chat hit to the conversation.
  final SearchHitKind kind;

  /// The entity id: a chat id when [kind] is chat, a note id when note. Named
  /// `chatId` for source-compat with the Phase 4 consumers; treat it as the
  /// entity id.
  final String chatId;
  final String title;

  /// Timestamp unit depends on [kind]: chat hits use epoch seconds; note hits
  /// use server nanoseconds (R-09). Branch on [kind] before formatting.
  final int createdAt;

  /// Timestamp unit depends on [kind]: chat hits use epoch seconds; note hits
  /// use server nanoseconds (R-09). Branch on [kind] before formatting.
  final int updatedAt;
  final bool pinned;
  final bool archived;
  final String? folderId;

  /// Epoch seconds.
  final int? lastReadAt;

  /// FTS5 snippet around the best-scoring hit; `null` for a title-only match.
  final String? snippet;

  /// Message id of the best-scoring hit; `''`/`null` when the best hit was the
  /// chat title row.
  final String? messageId;

  /// bm25 score of the best hit for this chat. LOWER is more relevant.
  final double rank;
}

/// Offline full-text search accessor (CDT-RFC-001 Phase 4 §F).
///
/// `chat_fts` is a raw FTS5 virtual table (NOT a drift table), so queries go
/// through [customSelect]. The JOIN to `chats` is declared so drift tracks the
/// table for stream invalidation and supplies the narrow envelope fields plus
/// the deleted-tombstone filter.
@DriftAccessor(tables: [Chats, Notes])
class SearchDao extends DatabaseAccessor<AppDatabase> with _$SearchDaoMixin {
  SearchDao(super.db);

  /// bm25 column weight for the single `text` column. Title and message rows
  /// share the same scale (both live in the one indexed column).
  static const double _kTextWeight = 10.0;

  /// Default result limit — parity with the server search `limit: 50`.
  static const int _kDefaultLimit = 50;

  /// Ranked full-text search over message content + chat titles.
  ///
  /// [raw] is arbitrary user input; it is sanitized via [toFtsMatchQuery] to a
  /// safe MATCH expression and BOUND as a parameter (never concatenated), so
  /// quotes / FTS operators / injection attempts cannot crash or mis-parse.
  /// Empty / all-punctuation input short-circuits to `[]` (never runs
  /// `MATCH ''`).
  ///
  /// Results are grouped to one row per chat (the best-scoring hit wins),
  /// ordered by bm25 ascending (most relevant first), and exclude tombstoned
  /// chats (`chats.deleted = 0`).
  Future<List<SearchHit>> search(
    String raw, {
    int limit = _kDefaultLimit,
    int offset = 0,
  }) async {
    final match = toFtsMatchQuery(raw);
    if (match.isEmpty) return const [];

    // §10.6 / perfContract Budget 4: the `chat_fts` vtable is created only once
    // the post-first-sync population gate (`buildFtsIfNeeded`) runs. Querying it
    // before then raises "no such table: chat_fts". Gate on the dedicated
    // `fts_built` flag so a not-yet-built index returns [] gracefully instead of
    // throwing — search simply yields nothing until the first sync populates it.
    final built = await attachedDatabase.syncMetaDao.getValue(kFtsBuiltKey);
    if (built != '1') return const [];

    final rows = await customSelect(
      // The bm25()/snippet() FTS5 auxiliary functions can ONLY be evaluated in
      // the query that directly MATCHes the vtable. The `hits` CTE is forced
      // MATERIALIZED so those values are computed exactly once and become plain
      // columns; downstream CTEs must never reference the FTS functions again
      // (doing so raises "unable to use function bm25 in the requested
      // context"). A window ROW_NUMBER picks the single best-scoring hit per
      // chat without correlated FTS-function subqueries.
      // snippet col index 0 = `text`; bm25 single-col weight (lower = better).
      'WITH hits AS MATERIALIZED ('
      '  SELECT chat_id, message_id, '
      // U+2068/U+2069 (first/second strong isolate) bracket the matched term
      // so it is identifiable in the snippet without injecting markup the UI
      // would have to strip; escaped to keep the source ASCII + bidi-safe.
      "         snippet(chat_fts, 0, '\u2068', '\u2069', '…', 12) AS snip, "
      '         bm25(chat_fts, ?) AS score '
      "  FROM chat_fts WHERE chat_fts MATCH ? AND kind IN ('msg', 'title')"
      '), '
      'ranked AS ('
      '  SELECT chat_id, message_id, snip, score, '
      '         ROW_NUMBER() OVER ('
      '           PARTITION BY chat_id ORDER BY score ASC'
      '         ) AS rn '
      '  FROM hits'
      ') '
      'SELECT c.id, c.title, c.created_at, c.updated_at, c.pinned, c.archived, '
      '       c.folder_id, c.last_read_at, '
      '       r.score AS rank, r.snip AS snippet, r.message_id AS message_id '
      'FROM ranked r JOIN chats c ON c.id = r.chat_id '
      'WHERE r.rn = 1 AND c.deleted = 0 '
      'ORDER BY r.score ASC '
      'LIMIT ? OFFSET ?',
      variables: [
        Variable.withReal(_kTextWeight),
        Variable.withString(match),
        Variable.withInt(limit),
        Variable.withInt(offset),
      ],
      readsFrom: {chats},
    ).get();

    return rows.map(_hitFromRow).toList(growable: false);
  }

  /// Ranked full-text search over NOTE titles + extracted note bodies
  /// (CDT-RFC-001 Phase 5). Same `chat_fts` vtable + bm25/snippet machinery as
  /// [search], but the MATCH is filtered to the note kinds and the result joins
  /// `notes` (excluding tombstones). The hit's `chatId` carries the NOTE id and
  /// `kind` is [SearchHitKind.note]. Note timestamps are NANOSECONDS (R-09 —
  /// never unit-converted; the consumer distinguishes by `kind`).
  Future<List<SearchHit>> searchNotes(
    String raw, {
    int limit = _kDefaultLimit,
    int offset = 0,
  }) async {
    final match = toFtsMatchQuery(raw);
    if (match.isEmpty) return const [];
    final built = await attachedDatabase.syncMetaDao.getValue(kFtsBuiltKey);
    if (built != '1') return const [];

    final rows = await customSelect(
      'WITH hits AS MATERIALIZED ('
      '  SELECT chat_id, kind, '
      "         snippet(chat_fts, 0, '\u2068', '\u2069', '…', 12) AS snip, "
      '         bm25(chat_fts, ?) AS score '
      '  FROM chat_fts '
      "  WHERE chat_fts MATCH ? AND kind IN ('note_title', 'note_text')"
      '), '
      'ranked AS ('
      '  SELECT chat_id, kind, snip, score, '
      '         ROW_NUMBER() OVER ('
      '           PARTITION BY chat_id ORDER BY score ASC'
      '         ) AS rn '
      '  FROM hits'
      ') '
      'SELECT n.id, n.title, n.created_at, n.updated_at, n.is_pinned, '
      '       r.score AS rank, r.snip AS snippet, r.kind AS kind '
      'FROM ranked r JOIN notes n ON n.id = r.chat_id '
      'WHERE r.rn = 1 AND n.deleted = 0 '
      'ORDER BY r.score ASC '
      'LIMIT ? OFFSET ?',
      variables: [
        Variable.withReal(_kTextWeight),
        Variable.withString(match),
        Variable.withInt(limit),
        Variable.withInt(offset),
      ],
      readsFrom: {notes},
    ).get();

    return rows.map(_noteHitFromRow).toList(growable: false);
  }

  /// Combined offline search returning NOTE hits alongside CHAT hits
  /// (CDT-RFC-001 §11 Phase 5 acceptance), merged and re-ranked by bm25 (lower
  /// is better). Runs the two entity queries independently (each owns its
  /// JOIN/clock) and merges in Dart — the result set is bounded by [limit] so a
  /// Dart-side merge is cheap and keeps each query's SQL simple.
  Future<List<SearchHit>> searchAll(
    String raw, {
    int limit = _kDefaultLimit,
  }) async {
    final results = await Future.wait([
      search(raw, limit: limit),
      searchNotes(raw, limit: limit),
    ]);
    final merged = [...results[0], ...results[1]]
      ..sort((a, b) => a.rank.compareTo(b.rank));
    if (merged.length <= limit) return merged;
    return merged.sublist(0, limit);
  }

  SearchHit _hitFromRow(QueryRow row) {
    final messageId = row.read<String?>('message_id');
    return SearchHit(
      chatId: row.read<String>('id'),
      title: row.read<String>('title'),
      createdAt: row.read<int>('created_at'),
      updatedAt: row.read<int>('updated_at'),
      pinned: row.read<bool>('pinned'),
      archived: row.read<bool>('archived'),
      folderId: row.read<String?>('folder_id'),
      lastReadAt: row.read<int?>('last_read_at'),
      snippet: row.read<String?>('snippet'),
      messageId: (messageId == null || messageId.isEmpty) ? null : messageId,
      rank: row.read<double>('rank'),
    );
  }

  SearchHit _noteHitFromRow(QueryRow row) {
    return SearchHit(
      kind: SearchHitKind.note,
      chatId: row.read<String>('id'),
      title: row.read<String>('title'),
      // NANOSECONDS (note clock; R-09 — not converted).
      createdAt: row.read<int>('created_at'),
      updatedAt: row.read<int>('updated_at'),
      pinned: row.read<bool>('is_pinned'),
      archived: false,
      snippet: row.read<String?>('snippet'),
      rank: row.read<double>('rank'),
    );
  }
}
