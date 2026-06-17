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

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../utils/debug_logger.dart';
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
  final rawId = overrideId ?? server['id'];
  if (rawId is! String || rawId.isEmpty) {
    throw ArgumentError.value(
      rawId,
      'server[id]',
      'must be a non-empty String',
    );
  }
  final rawExtra = <String, dynamic>{
    for (final entry in server.entries)
      if (!_typedNoteKeys.contains(entry.key)) entry.key: entry.value,
  };
  final data = _serverJsonObjectOrEmpty(server['data']);
  final meta = _serverJsonObjectOrEmpty(server['meta']);
  return NotesCompanion.insert(
    id: rawId,
    title: server['title'] is String ? server['title'] as String : '',
    data: Value(jsonEncode(data)),
    meta: Value(jsonEncode(meta)),
    isPinned: Value(server['is_pinned'] == true),
    createdAt: asNs(server['created_at']) ?? 0,
    updatedAt: asNs(server['updated_at']) ?? 0,
    serverUpdatedAt: Value(asNs(server['updated_at'])),
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
    ...decodeJsonMap(row.rawExtra),
    'id': row.id,
    'title': row.title,
    'data': decodeJsonMap(row.data),
    'meta': decodeJsonMap(row.meta),
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
Map<String, dynamic> noteRowToPatch(NoteRow row, {required bool includeData}) {
  return <String, dynamic>{
    'title': row.title,
    if (includeData) 'data': decodeJsonMap(row.data),
  };
}

/// Stable fingerprint for `noteCreate` crash-heal. Hashes only the fields sent
/// by `NotePushSync.pushNoteCreate`: title and data. Server-minted id/timestamps
/// and metadata never participate.
String noteCreateContentHashFromRow(NoteRow row) {
  return noteCreateContentHash(title: row.title, data: decodeJsonMap(row.data));
}

/// Server-shaped counterpart to [noteCreateContentHashFromRow].
String noteCreateContentHashFromServer(Map<String, dynamic> server) {
  return noteCreateContentHash(
    title: server['title'] is String ? server['title'] as String : '',
    data: _serverJsonObjectOrEmpty(server['data']),
  );
}

String noteCreateContentHash({
  required String title,
  required Map<String, dynamic> data,
}) {
  final stable = <String, dynamic>{'title': title, 'data': data};
  return sha256.convert(utf8.encode(_canonicalJson(stable))).toString();
}

/// Decodes a row's stored `data` JSON string into the server-shaped `data`
/// dict (the full `{content: {md, html, json}, ...}` sub-object) for the
/// create/update POST body. Tolerant of corrupt JSON (empty map).
Map<String, dynamic> decodeNoteData(String raw) => decodeJsonMap(raw);

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

Map<String, dynamic> _serverJsonObjectOrEmpty(Object? value) {
  return _asMap(value);
}

/// Decodes a JSON string into a `Map<String, dynamic>`, tolerant of corrupt
/// JSON (returns an empty map rather than throwing) and of `Map`s whose static
/// type is not already `Map<String, dynamic>`. Shared across the database
/// mappers/DAOs so the decode contract stays in one place.
Map<String, dynamic> decodeJsonMap(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (error) {
    // Corrupt JSON: fall through to empty rather than crash a merge.
    DebugLogger.warning(
      'decode-json-failed',
      scope: 'database/mapper',
      data: {'length': raw.length, 'errorType': error.runtimeType.toString()},
    );
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

String _canonicalJson(Object? value) {
  final buffer = StringBuffer();
  _writeCanonical(value, buffer);
  return buffer.toString();
}

void _writeCanonical(Object? value, StringBuffer out) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    out.write('{');
    var first = true;
    for (final key in keys) {
      if (!first) out.write(',');
      first = false;
      out
        ..write(jsonEncode(key))
        ..write(':');
      _writeCanonical(value[key], out);
    }
    out.write('}');
    return;
  }
  if (value is Iterable && value is! String) {
    out.write('[');
    var first = true;
    for (final item in value) {
      if (!first) out.write(',');
      first = false;
      _writeCanonical(item, out);
    }
    out.write(']');
    return;
  }
  out.write(jsonEncode(value));
}
