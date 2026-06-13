/// In-memory fake of the Open WebUI chats API for unit tests.
///
/// Semantics are mirrored from the vendored server source
/// (`openwebui-src/backend/open_webui/routers/chats.py` and
/// `openwebui-src/backend/open_webui/models/chats.py`):
///
/// * `getChatList` mirrors `GET /api/v1/chats/list`
///   (`get_session_user_chat_list` -> `get_chat_title_id_list_by_user_id`):
///   archived chats are always excluded, chats with a `folder_id` are
///   excluded unless `includeFolders`, pinned chats are excluded unless
///   `includePinned`, ordering is `updated_at DESC, id ASC`, and when a
///   page is given the page size is exactly 60 with `skip = (page - 1) * 60`.
/// * `createChat` mirrors `POST /api/v1/chats/new` (`create_new_chat` ->
///   `insert_new_chat`): the server generates the row id with uuid4 (any
///   `id` inside the blob is stored verbatim inside the blob but never used
///   as the row id), title is `blob['title']` when the key is present else
///   `'New Chat'`, and `created_at`/`updated_at` are stamped from the clock.
///   A non-null `folderId` must reference a folder registered via
///   [FakeOpenWebUiServer.seedFolder]; otherwise a
///   [FakeOpenWebUiHttpException] with status 404 is thrown, mirroring the
///   folder ownership check in `routers/chats.py` (`create_new_chat`:
///   `if form_data.folder_id is not None: if not await
///   Folders.get_folder_by_id_and_user_id(...): raise HTTPException(404)`).
/// * `updateChat` mirrors `POST /api/v1/chats/{id}` (`update_chat_by_id`
///   route): the stored blob becomes `{**existing, **incoming}` — a SHALLOW
///   top-level merge, not a full replace. Then, before persisting, every
///   assistant message in `merged['history']['messages']` whose `output` is
///   a non-empty list AND deep-differs from the same message id's `output`
///   in the previously stored blob gets `content` rewritten to
///   `serialize_output(output)` (the route's output-to-content
///   re-derivation; `utils/middleware.py` `serialize_output`). Finally
///   `updated_at` is restamped and the title re-derived from the merged
///   blob. There is no concurrency control: stale writes are never
///   rejected.
/// * `deleteChat` mirrors `DELETE /api/v1/chats/{id}`: missing ids fail
///   (the route raises 404), existing ids are removed.
///
/// Null bytes in strings are stripped on write, mirroring
/// `ChatTable._clean_null_bytes` / `sanitize_data_for_db`.
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';

/// Error equivalent of an upstream `HTTPException` (e.g. the 404 raised by
/// `create_new_chat` for an unknown or unowned `folder_id`).
class FakeOpenWebUiHttpException implements Exception {
  FakeOpenWebUiHttpException(this.statusCode, this.detail);

  final int statusCode;
  final String detail;

  @override
  String toString() => 'FakeOpenWebUiHttpException($statusCode): $detail';
}

/// Internal mutable chat row, shaped like the vendored `Chat` table.
class _ChatRecord {
  _ChatRecord({
    required this.id,
    required this.title,
    required this.chat,
    required this.createdAt,
    required this.updatedAt,
    this.folderId,
    this.pinned = false,
    this.archived = false,
  });

  final String id;
  String title;
  Map<String, dynamic> chat;
  int createdAt;
  int updatedAt;
  String? folderId;
  bool pinned;
  bool archived;
}

class FakeOpenWebUiServer {
  /// [nowEpochSeconds] injects an external clock. When omitted, an internal
  /// monotonic counter is used, advanced explicitly via [tick].
  FakeOpenWebUiServer({int Function()? nowEpochSeconds})
    : _externalClock = nowEpochSeconds;

  static const String userId = 'fake-user';

  /// Page size used by `get_session_user_chat_list` when `page` is provided.
  static const int pageSize = 60;

  final int Function()? _externalClock;
  int _internalClock = 0;
  final Uuid _uuid = const Uuid();
  final Map<String, _ChatRecord> _chats = <String, _ChatRecord>{};
  final Map<String, Map<String, dynamic>> _folders =
      <String, Map<String, dynamic>>{};

  static const DeepCollectionEquality _deepEq = DeepCollectionEquality();

  /// Advances the internal clock. Only meaningful when no external clock
  /// was injected.
  void tick([int seconds = 1]) {
    _internalClock += seconds;
  }

  /// Test helper: registers [id] as an existing folder owned by the fake
  /// user, so [createChat] accepts it as a `folderId`. A minimal raw folder
  /// map is synthesized for [getFolders].
  void seedFolder(String id) {
    _folders.putIfAbsent(
      id,
      () => <String, dynamic>{
        'id': id,
        'name': id,
        'parent_id': null,
        'created_at': _now(),
        'updated_at': _now(),
      },
    );
  }

  /// Test helper: registers a verbatim raw folder map (must carry a String
  /// `id`), mirroring what `GET /api/v1/folders/` would return.
  void seedFolderRaw(Map<String, dynamic> raw) {
    final id = raw['id'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError.value(raw, 'raw', 'folder map needs a String id');
    }
    _folders[id] = _deepCopy(raw);
  }

  /// Mirrors `GET /api/v1/folders/`: every folder owned by the fake user as
  /// raw maps.
  List<Map<String, dynamic>> getFolders() {
    return [for (final raw in _folders.values) _deepCopy(raw)];
  }

  int _now() => _externalClock?.call() ?? _internalClock;

  /// Mirrors `GET /api/v1/chats/list` semantics from
  /// `get_chat_title_id_list_by_user_id`.
  List<Map<String, dynamic>> getChatList({
    int? page,
    bool includePinned = false,
    bool includeFolders = false,
  }) {
    var records = _chats.values
        // include_archived defaults to false on this route.
        .where((c) => !c.archived)
        // `filter_by(folder_id=None)` unless include_folders.
        .where((c) => includeFolders || c.folderId == null)
        // `or_(pinned == False, pinned == None)` unless include_pinned.
        .where((c) => includePinned || !c.pinned)
        .toList();

    // `order_by(Chat.updated_at.desc(), Chat.id)`.
    records.sort((a, b) {
      final byUpdated = b.updatedAt.compareTo(a.updatedAt);
      if (byUpdated != 0) return byUpdated;
      return a.id.compareTo(b.id);
    });

    if (page != null) {
      final skip = (page - 1) * pageSize;
      if (skip >= records.length || skip < 0) {
        records = <_ChatRecord>[];
      } else {
        records = records.sublist(skip).take(pageSize).toList();
      }
    }

    // `ChatTitleIdResponse` shape.
    return records
        .map(
          (c) => <String, dynamic>{
            'id': c.id,
            'title': c.title,
            'updated_at': c.updatedAt,
            'created_at': c.createdAt,
            'last_read_at': null,
          },
        )
        .toList();
  }

  /// Mirrors `GET /api/v1/chats/archived` semantics from
  /// `get_archived_session_user_chat_list` ->
  /// `get_archived_chat_list_by_user_id` (`routers/chats.py` /
  /// `models/chats.py`): archived-only, default ordering
  /// `updated_at DESC, id ASC` (the sync client always sends
  /// `order_by=updated_at&direction=desc`, which matches), page size exactly
  /// 60 with `skip = (page - 1) * 60` (a missing page defaults to 1
  /// upstream), `ChatTitleIdResponse` shape. The upstream archived query
  /// selects no `last_read_at`, so the validated model carries its `null`
  /// default.
  List<Map<String, dynamic>> getArchivedChatList({int? page}) {
    var records = _chats.values.where((c) => c.archived).toList();

    // `order_by(Chat.updated_at.desc(), Chat.id)`.
    records.sort((a, b) {
      final byUpdated = b.updatedAt.compareTo(a.updatedAt);
      if (byUpdated != 0) return byUpdated;
      return a.id.compareTo(b.id);
    });

    final skip = ((page ?? 1) - 1) * pageSize;
    if (skip >= records.length || skip < 0) {
      records = <_ChatRecord>[];
    } else {
      records = records.sublist(skip).take(pageSize).toList();
    }

    return records
        .map(
          (c) => <String, dynamic>{
            'id': c.id,
            'title': c.title,
            'updated_at': c.updatedAt,
            'created_at': c.createdAt,
            'last_read_at': null,
          },
        )
        .toList();
  }

  /// Mirrors `POST /api/v1/chats/new`. The id is always server-generated.
  ///
  /// Throws [FakeOpenWebUiHttpException] (404) when [folderId] is non-null
  /// and not registered via [seedFolder], mirroring the route's
  /// `Folders.get_folder_by_id_and_user_id` ownership check in
  /// `routers/chats.py` (`create_new_chat`).
  Map<String, dynamic> createChat(
    Map<String, dynamic> chatBlob, {
    String? folderId,
  }) {
    if (folderId != null && !_folders.containsKey(folderId)) {
      throw FakeOpenWebUiHttpException(404, 'Not found');
    }
    final blob = _cleanNullBytes(_deepCopy(chatBlob)) as Map<String, dynamic>;
    final now = _now();
    final record = _ChatRecord(
      id: _uuid.v4(),
      title: _titleFromBlob(blob),
      chat: blob,
      createdAt: now,
      updatedAt: now,
      folderId: folderId,
    );
    _chats[record.id] = record;
    return _toChatResponse(record);
  }

  /// Mirrors `GET /api/v1/chats/{id}`. Returns null when missing/deleted.
  Map<String, dynamic>? getChatById(String id) {
    final record = _chats[id];
    if (record == null) return null;
    return _toChatResponse(record);
  }

  /// Mirrors `POST /api/v1/chats/{id}`: the stored blob becomes
  /// `{**existing, **incoming}` (shallow top-level merge); then assistant
  /// messages whose `output` changed get `content` re-derived via
  /// [serializeOutput] (the route's output-to-content re-derivation —
  /// content set independently of output, e.g. by a `replace` event or an
  /// outlet filter, is NOT reverted when output is unchanged); finally
  /// `updated_at` is restamped from the clock and the title re-derived from
  /// the merged blob. Stale writes are never rejected.
  Map<String, dynamic>? updateChat(String id, Map<String, dynamic> blob) {
    final record = _chats[id];
    if (record == null) return null;

    final incoming = _cleanNullBytes(_deepCopy(blob)) as Map<String, dynamic>;
    final merged = <String, dynamic>{...record.chat, ...incoming};
    _rederiveContentFromOutput(existing: record.chat, merged: merged);
    record.chat = merged;
    record.title = _titleFromBlob(merged);
    record.updatedAt = _now();
    return _toChatResponse(record);
  }

  /// The `update_chat_by_id` route's output-to-content pass
  /// (`routers/chats.py`): for every assistant message in
  /// `merged['history']['messages']` whose `output` is a non-empty list and
  /// deep-differs from the previously stored message's `output`, rewrite
  /// `content = serialize_output(output)`.
  ///
  /// Non-Map `history`/`messages` containers are skipped (upstream would
  /// raise a 500 on those; the fake tolerates them since the chats table
  /// enforces no schema and other routes accept such blobs).
  static void _rederiveContentFromOutput({
    required Map<String, dynamic> existing,
    required Map<String, dynamic> merged,
  }) {
    final existingHistory = existing['history'];
    final existingMessages =
        existingHistory is Map ? existingHistory['messages'] : null;

    final mergedHistory = merged['history'];
    if (mergedHistory is! Map) return;
    final mergedMessages = mergedHistory['messages'];
    if (mergedMessages is! Map) return;

    for (final entry in mergedMessages.entries) {
      final message = entry.value;
      if (message is! Map || message['role'] != 'assistant') continue;
      // Python `msg.get('output')` truthiness: only a non-empty list reaches
      // serialize_output without erroring upstream.
      final output = message['output'];
      if (output is! List || output.isEmpty) continue;

      final existingMessage =
          existingMessages is Map ? existingMessages[entry.key] : null;
      final existingOutput =
          existingMessage is Map ? existingMessage['output'] : null;
      if (!_deepEq.equals(output, existingOutput)) {
        message['content'] = serializeOutput(output);
      }
    }
  }

  /// Mirrors `DELETE /api/v1/chats/{id}`: false when the id does not exist
  /// (the vendored route raises 404), true after removal.
  bool deleteChat(String id) => _chats.remove(id) != null;

  /// Mirrors `GET /api/v1/chats/{id}/pinned`
  /// (`get_pinned_status_by_id`): the chat's `pinned` flag; throws 401 when
  /// the chat is missing/unowned (the route raises
  /// `HTTP_401_UNAUTHORIZED`).
  bool getChatPinned(String id) {
    final record = _chats[id];
    if (record == null) {
      throw FakeOpenWebUiHttpException(401, 'Unauthorized');
    }
    return record.pinned;
  }

  /// Mirrors `POST /api/v1/chats/{id}/pin` (`pin_chat_by_id` ->
  /// `toggle_chat_pinned_by_id`): a STATELESS TOGGLE that IGNORES the body.
  /// Returns the `ChatResponse` after the flip; null on a missing id.
  Map<String, dynamic>? togglePin(String id) {
    final record = _chats[id];
    if (record == null) return null;
    record.pinned = !record.pinned;
    return _toChatResponse(record);
  }

  /// Mirrors `POST /api/v1/chats/{id}/archive` (`archive_chat_by_id` ->
  /// `toggle_chat_archive_by_id`): a STATELESS TOGGLE that IGNORES the body.
  /// Returns the `ChatResponse` after the flip; null on a missing id.
  Map<String, dynamic>? toggleArchive(String id) {
    final record = _chats[id];
    if (record == null) return null;
    record.archived = !record.archived;
    return _toChatResponse(record);
  }

  /// Mirrors `POST /api/v1/chats/{id}/folder` (`update_chat_folder_id_by_id`):
  /// sets the chat's `folder_id` (a non-null target must reference a seeded
  /// folder, mirroring the ownership check). Returns the `ChatResponse`; null
  /// on a missing chat id.
  Map<String, dynamic>? moveChatToFolder(String id, String? folderId) {
    final record = _chats[id];
    if (record == null) return null;
    if (folderId != null && !_folders.containsKey(folderId)) {
      throw FakeOpenWebUiHttpException(404, 'Not found');
    }
    record.folderId = folderId;
    record.updatedAt = _now();
    return _toChatResponse(record);
  }

  /// Mirrors `POST /api/v1/folders/` (`create_folder`): the server mints the
  /// id; returns the raw folder map.
  Map<String, dynamic> createFolder({required String name, String? parentId}) {
    final now = _now();
    final id = _uuid.v4();
    final folder = <String, dynamic>{
      'id': id,
      'name': name,
      'parent_id': parentId,
      'created_at': now,
      'updated_at': now,
    };
    _folders[id] = folder;
    return _deepCopy(folder);
  }

  /// Mirrors `POST /api/v1/folders/{id}/update` (`update_folder_by_id`):
  /// shallow-updates name/data/meta. No-op on a missing id.
  void updateFolder(
    String id, {
    String? name,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) {
    final folder = _folders[id];
    if (folder == null) return;
    if (name != null) folder['name'] = name;
    if (data != null) folder['data'] = _deepCopy(data);
    if (meta != null) folder['meta'] = _deepCopy(meta);
    folder['updated_at'] = _now();
  }

  /// Mirrors `POST /api/v1/folders/{id}/update/parent`. No-op on a missing id.
  void updateFolderParent(String id, String? parentId) {
    final folder = _folders[id];
    if (folder == null) return;
    folder['parent_id'] = parentId;
    folder['updated_at'] = _now();
  }

  /// Mirrors `DELETE /api/v1/folders/{id}?delete_contents=<flag>`
  /// (`delete_folder_by_id`): removes the folder. When [deleteContents] is
  /// true, contained chats are deleted; when false, they are re-parented to
  /// root (`folder_id = null`). Returns false on a missing id.
  bool deleteFolder(String id, {bool deleteContents = true}) {
    if (!_folders.containsKey(id)) return false;
    for (final record in _chats.values) {
      if (record.folderId == id) {
        if (deleteContents) {
          // Tombstone-by-removal happens after iteration to avoid mutating
          // during traversal.
        } else {
          record.folderId = null;
        }
      }
    }
    if (deleteContents) {
      _chats.removeWhere((_, record) => record.folderId == id);
    }
    _folders.remove(id);
    return true;
  }

  /// Test helper: seeds a chat row with explicit timestamps and flags,
  /// bypassing the clock and folder validation ([folderId], when given, is
  /// registered as an existing folder as a side effect).
  void seedChat({
    required String id,
    required Map<String, dynamic> blob,
    required int createdAt,
    required int updatedAt,
    String? folderId,
    bool pinned = false,
    bool archived = false,
  }) {
    if (folderId != null) {
      seedFolder(folderId);
    }
    final copy = _cleanNullBytes(_deepCopy(blob)) as Map<String, dynamic>;
    _chats[id] = _ChatRecord(
      id: id,
      title: _titleFromBlob(copy),
      chat: copy,
      createdAt: createdAt,
      updatedAt: updatedAt,
      folderId: folderId,
      pinned: pinned,
      archived: archived,
    );
  }

  /// Dart port of `serialize_output` from
  /// `openwebui-src/backend/open_webui/utils/middleware.py` for the item
  /// types the fixtures exercise:
  ///
  /// * `message` — the trimmed `text` of each content part carrying a
  ///   `text` key is appended verbatim (no HTML escaping upstream).
  /// * `reasoning` — text parts of `summary` (or `content` as fallback) are
  ///   concatenated, trimmed, each line prefixed with `> ` unless it already
  ///   starts with `>`, then HTML-escaped (Python `html.escape` semantics,
  ///   including `"`/`'`) and wrapped in a `<details type="reasoning">`
  ///   block whose done-ness mirrors upstream (`status == 'completed'`, a
  ///   present `duration`, or not being the last item).
  /// * `function_call_output` — skipped here (upstream renders it inline
  ///   with its matching `function_call`).
  /// * Unknown item types — silently skipped, exactly like upstream's
  ///   if/elif chain.
  ///
  /// Item types whose exact HTML/`json.dumps` rendering is NOT ported
  /// (`function_call`, `web_search_call`, `file_search_call`,
  /// `computer_call`, `open_webui:code_interpreter`) throw
  /// [UnsupportedError] so the fake can never silently diverge from the
  /// vendored source; extend the port if a test needs them.
  ///
  /// Parts are joined with `\n` and the result trimmed, mirroring
  /// `'\n'.join(parts).strip()`.
  static String serializeOutput(List<dynamic> output) {
    final parts = <String>[];

    for (var idx = 0; idx < output.length; idx++) {
      final item = output[idx];
      if (item is! Map) continue;
      final itemType = item['type'] ?? '';

      switch (itemType) {
        case 'message':
          final content = item['content'];
          if (content is List) {
            for (final part in content) {
              if (part is Map && part.containsKey('text')) {
                final textValue = part['text'];
                final text = textValue is String ? textValue.trim() : '';
                if (text.isNotEmpty) {
                  parts.add(text);
                }
              }
            }
          }
        case 'reasoning':
          // `item.get('summary', []) or item.get('content', [])`.
          final summaryValue = item['summary'];
          final contentValue = item['content'];
          final sourceList = (summaryValue is List && summaryValue.isNotEmpty)
              ? summaryValue
              : (contentValue is List ? contentValue : const <Object?>[]);

          final reasoningParts = <String>[];
          for (final part in sourceList) {
            if (part is Map && part.containsKey('text')) {
              final textValue = part['text'];
              if (textValue is String) {
                reasoningParts.add(textValue);
              }
            }
          }
          final reasoningContent = reasoningParts.join().trim();

          final duration = item['duration'];
          final status = item['status'] ?? 'in_progress';
          final isLastItem = idx == output.length - 1;

          final display = _pyHtmlEscape(
            const LineSplitter()
                .convert(reasoningContent)
                .map((line) => line.startsWith('>') ? line : '> $line')
                .join('\n'),
          );

          // Python `{duration or 0}`.
          final Object shownDuration =
              (duration == null || duration == 0) ? 0 : duration;

          if (status == 'completed' || duration != null || !isLastItem) {
            parts.add(
              '<details type="reasoning" done="true" '
              'duration="$shownDuration">\n'
              '<summary>Thought for $shownDuration seconds</summary>\n'
              '$display\n</details>',
            );
          } else {
            parts.add(
              '<details type="reasoning" done="false">\n'
              '<summary>Thinking…</summary>\n$display\n</details>',
            );
          }
        case 'function_call_output':
          // Rendered inline with its matching `function_call` upstream; on
          // its own it produces nothing.
          break;
        case 'function_call':
        case 'web_search_call':
        case 'file_search_call':
        case 'computer_call':
        case 'open_webui:code_interpreter':
          throw UnsupportedError(
            'FakeOpenWebUiServer.serializeOutput: output item type '
            '"$itemType" is not ported from serialize_output '
            '(utils/middleware.py); extend the port before using it in '
            'tests.',
          );
        default:
          // Unknown types fall through upstream's if/elif chain unrendered.
          break;
      }
    }

    return parts.join('\n').trim();
  }

  /// Python `html.escape(s)` with the default `quote=True`: `&`, `<`, `>`,
  /// `"`, and `'` are escaped (in that order, `&` first).
  static String _pyHtmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#x27;');

  /// `form_data.chat['title'] if 'title' in form_data.chat else 'New Chat'`
  /// — a key-presence check, mirroring `insert_new_chat`/`update_chat_by_id`.
  static String _titleFromBlob(Map<String, dynamic> blob) =>
      blob.containsKey('title') ? blob['title'] as String : 'New Chat';

  /// `ChatResponse` shape from the vendored `models/chats.py`.
  Map<String, dynamic> _toChatResponse(_ChatRecord record) =>
      <String, dynamic>{
        'id': record.id,
        'user_id': userId,
        'title': record.title,
        'chat': _deepCopy(record.chat),
        'updated_at': record.updatedAt,
        'created_at': record.createdAt,
        'share_id': null,
        'archived': record.archived,
        'pinned': record.pinned,
        'meta': <String, dynamic>{},
        'folder_id': record.folderId,
        'tasks': null,
        'summary': null,
      };

  /// Deep copy via JSON round-trip so callers can never alias server state.
  static Map<String, dynamic> _deepCopy(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  /// Mirrors `_clean_null_bytes` / `sanitize_data_for_db`: recursively strip
  /// null bytes from strings in nested dict/list structures.
  static Object? _cleanNullBytes(Object? value) {
    if (value is String) return value.replaceAll('\u0000', '');
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key as String: _cleanNullBytes(entry.value),
      };
    }
    if (value is List) return value.map(_cleanNullBytes).toList();
    return value;
  }
}
