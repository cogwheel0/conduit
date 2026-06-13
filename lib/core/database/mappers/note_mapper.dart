/// Pure mapping between Open WebUI note maps and normalized note row data
/// (CDT-RFC-001 Phase 5, mirrors `ChatBlobMapper`'s §6.1 round-trip invariant
/// pattern — but trivial: identity over a FLAT dict, no row explosion).
///
/// The governing invariant (non-neg 2):
///
/// ```dart
/// DeepCollectionEquality().equals(
///   noteRowToServer(serverToNoteRow(server)),  // up to typed-column keys
///   server,
/// ) == true   // access_grants + unknown top-level keys preserved
/// ```
///
/// Timestamps are NANOSECONDS end-to-end (R-09): no lossy unit conversion ever
/// happens here — `created_at`/`updated_at` are copied as raw int64.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_database.dart';

/// Top-level server keys that map to TYPED columns; every OTHER key (including
/// `access_grants`, `access_control`, `user`, `write_access`, and any unknown
/// future key) is preserved verbatim in [Notes.rawExtra].
const Set<String> _typedNoteKeys = <String>{
  'id',
  'title',
  'data',
  'meta',
  'is_pinned',
  'created_at',
  'updated_at',
};

/// Builds a [NotesCompanion] for a SERVER-origin note (all dirty flags false,
/// `serverUpdatedAt = updated_at`). EVERY key not in [_typedNoteKeys] is folded
/// into `rawExtra`. `data`/`meta` are stored as the raw JSON sub-objects.
///
/// [overrideId] lets the caller key the row under a different id (e.g. a
/// `local:<uuid>` conflict copy) while still pulling typed fields from
/// [server].
NotesCompanion serverToNoteRow(
  Map<String, dynamic> server, {
  String? overrideId,
}) {
  final id = overrideId ?? (server['id'] as String);
  final rawExtra = <String, dynamic>{
    for (final entry in server.entries)
      if (!_typedNoteKeys.contains(entry.key)) entry.key: entry.value,
  };
  return NotesCompanion.insert(
    id: id,
    title: server['title'] is String ? server['title'] as String : '',
    data: Value(jsonEncode(_asMap(server['data']))),
    meta: Value(jsonEncode(_asMap(server['meta']))),
    isPinned: Value(server['is_pinned'] == true),
    createdAt: _asNs(server['created_at']) ?? 0,
    updatedAt: _asNs(server['updated_at']) ?? 0,
    serverUpdatedAt: Value(_asNs(server['updated_at'])),
    dirtyTitle: const Value(false),
    dirtyData: const Value(false),
    dirtyPinned: const Value(false),
    deleted: const Value(false),
    rawExtra: Value(jsonEncode(rawExtra)),
  );
}

/// Reconstructs the full server-shaped map from a stored row. `rawExtra` is
/// spread back at the TOP LEVEL so unknown keys (access_grants etc.) reappear
/// byte-equivalent (non-neg 2). Typed columns win over any same-named rawExtra
/// key (rawExtra never holds a typed key, so there is no real collision).
Map<String, dynamic> noteRowToServer(NoteRow row) {
  return <String, dynamic>{
    ..._decodeMap(row.rawExtra),
    'id': row.id,
    'title': row.title,
    'data': _decodeMap(row.data),
    'meta': _decodeMap(row.meta),
    'is_pinned': row.isPinned,
    'created_at': row.createdAt,
    'updated_at': row.updatedAt,
  };
}

/// The PATCH MAP a `noteUpdate` op carries / the push handler sends. ALWAYS
/// includes `title` (WARNING B: the router validates against `NoteForm` where
/// `title` is REQUIRED, so a title-less update fails validation), and includes
/// `data` only when the data axis is dirty. Never includes `meta`/access keys
/// (own-notes sync never touches them).
Map<String, dynamic> noteRowToPatch(
  NoteRow row, {
  required bool includeData,
}) {
  return <String, dynamic>{
    'title': row.title,
    if (includeData) 'data': _decodeMap(row.data),
  };
}

/// Decodes a row's stored `data` JSON string into the server-shaped `data`
/// dict (the full `{content: {md, html, json}, ...}` sub-object) for the
/// create/update POST body. Tolerant of corrupt JSON (empty map).
Map<String, dynamic> decodeNoteData(String raw) => _decodeMap(raw);

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

Map<String, dynamic> _decodeMap(String raw) => decodeJsonMap(raw);

/// Decodes a JSON string into a `Map<String, dynamic>`, tolerant of corrupt
/// JSON (returns an empty map rather than throwing) and of `Map`s whose static
/// type is not already `Map<String, dynamic>`. Shared across the database
/// mappers/DAOs so the decode contract stays in one place.
Map<String, dynamic> decodeJsonMap(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {
    // Corrupt JSON: fall through to empty rather than crash a merge.
  }
  return <String, dynamic>{};
}

/// Raw int64 nanoseconds — NO unit conversion (R-09). Tolerates a `num` that
/// arrived as double from JSON. Shared with the notes DAO.
int? asNs(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

int? _asNs(Object? value) => asNs(value);
