/// Pure-Dart mapping between Open WebUI chat blobs and normalized row data.
///
/// Implements CDT-RFC-001 §6.1 (Phase 0 foundations). The "blob" is the
/// `chat` JSON column of the upstream `chat` table (the dict exposed as
/// `ChatResponse.chat`); the upstream server enforces no schema on its
/// contents, so this mapper must preserve unknown and malformed data
/// verbatim. The governing invariant is lossless round-tripping:
///
/// ```dart
/// DeepCollectionEquality().equals(
///   ChatBlobMapper.rowsToBlob(ChatBlobMapper.blobToRows(...)),
///   originalBlob,
/// ) == true
/// ```
///
/// This library is intentionally free of drift and Flutter imports so it can
/// be unit-tested as plain Dart.
library;

import 'dart:convert';

/// Normalized chat-level row data (CDT-RFC-001 §6.1).
///
/// Envelope fields ([title], [folderId], [pinned], [archived], [createdAt],
/// [updatedAt]) come from the API envelope (`ChatResponse` /
/// `ChatTitleIdResponse`), never from the blob itself. Timestamps are epoch
/// seconds, matching the upstream chat row.
class ChatRowData {
  const ChatRowData({
    required this.id,
    required this.title,
    this.folderId,
    this.pinned = false,
    this.archived = false,
    this.currentMessageId,
    required this.createdAt,
    required this.updatedAt,
    this.rawExtra = const <String, dynamic>{},
  });

  /// Server-assigned chat id.
  final String id;

  /// Title from the API envelope. The blob's own `title` VALUE is stashed
  /// verbatim in [ChatRows.blobTitleValue] for reconstruction; this field is
  /// never used to rebuild the blob.
  final String title;

  /// Folder id from the API envelope, if any.
  final String? folderId;

  /// Pinned flag from the API envelope.
  final bool pinned;

  /// Archived flag from the API envelope.
  final bool archived;

  /// `blob['history']['currentId']` — the leaf message id of the active
  /// branch, when present and well-formed (a `String` or `null`).
  final String? currentMessageId;

  /// Envelope `created_at`, epoch seconds.
  final int createdAt;

  /// Envelope `updated_at`, epoch seconds.
  final int updatedAt;

  /// All top-level blob keys except `title` and (well-formed) `history`,
  /// verbatim — e.g. `models`, `params`, legacy linear `messages`, `tags`,
  /// `timestamp`, `files`, `system`, and any unknown future keys.
  ///
  /// As a defensive special case, a malformed `history` value that is not a
  /// `Map` (e.g. `null` or a list) — or a `Map` with any non-`String` key,
  /// which can only come from Dart-built blobs, never from `jsonDecode` —
  /// is preserved verbatim here instead, with [ChatRows.blobHadHistory] left
  /// `false`, so the round-trip invariant still holds for corrupt blobs.
  final Map<String, dynamic> rawExtra;
}

/// Normalized message-level row data (CDT-RFC-001 §6.1).
class MessageRowData {
  const MessageRowData({
    required this.id,
    required this.chatId,
    this.parentId,
    required this.role,
    required this.content,
    this.model,
    required this.createdAt,
    required this.orderIndex,
    this.payload = const <String, dynamic>{},
  });

  /// Message id — the entry's key in `history.messages`, which is canonical
  /// upstream even when the embedded `message['id']` disagrees with it.
  final String id;

  /// Owning chat id.
  final String chatId;

  /// `message['parentId']` when it is a `String`; `null` otherwise (roots
  /// have `parentId: null` upstream).
  final String? parentId;

  /// `message['role']` (`user`, `assistant`, ...). Entries without a
  /// `String` role never become rows; see [ChatRows.unmappableMessages].
  final String role;

  /// Query/FTS projection of `message['content']`: the value itself when it
  /// is a `String`, otherwise `jsonEncode` of it. [payload] remains the
  /// source of truth.
  final String content;

  /// `message['model']` when it is a `String` (assistant messages).
  final String? model;

  /// `message['timestamp']` (upstream epoch seconds, stored verbatim without
  /// unit normalization); falls back to the chat envelope `created_at` when
  /// absent or non-numeric.
  final int createdAt;

  /// Iteration position of this entry in the original `history.messages`
  /// map (counting unmappable entries too).
  final int orderIndex;

  /// The complete original message JSON, verbatim and untouched.
  final Map<String, dynamic> payload;
}

/// Result of decomposing one chat blob into rows (CDT-RFC-001 §6.1).
class ChatRows {
  const ChatRows({
    required this.chat,
    this.messages = const <MessageRowData>[],
    this.unmappableMessages = const <String, dynamic>{},
    this.unmappableMessageOrder = const <String, int>{},
    required this.blobHadTitle,
    this.blobTitleValue,
    required this.blobHadHistory,
    this.historyHadMessages = false,
    this.historyHadCurrentId = false,
    this.historyExtra = const <String, dynamic>{},
  });

  /// Chat-level row.
  final ChatRowData chat;

  /// Message rows derived from `blob['history']['messages']`.
  final List<MessageRowData> messages;

  /// Entries of `history.messages` that cannot become rows (value is not a
  /// `Map`, its `role` is not a `String` — e.g. `null` garbage or partial
  /// "ghost" nodes written by upstream upserts — or, defensively, a Dart-built
  /// message `Map` with a non-`String` key), preserved verbatim and keyed by
  /// their original key.
  final Map<String, dynamic> unmappableMessages;

  /// Original iteration position for each [unmappableMessages] entry.
  ///
  /// Old persisted rows may not have this metadata; [rowsToBlob] falls back to
  /// appending those entries after mapped messages in insertion order.
  final Map<String, int> unmappableMessageOrder;

  /// Whether the original blob had a top-level `title` key. [rowsToBlob]
  /// only re-emits `title` when this is `true`, so the mapper never invents
  /// the key. The re-emitted value is [blobTitleValue], never
  /// [ChatRowData.title]: upstream enforces no schema, so a blob `title` can
  /// be `null`, a non-string, or diverge from the envelope title.
  final bool blobHadTitle;

  /// The verbatim value of the blob's own top-level `title` key (only
  /// meaningful when [blobHadTitle] is `true`). Usually identical to the
  /// envelope title, but preserved exactly so the round trip holds when it
  /// is `null`, a non-string, or a divergent string.
  final Object? blobTitleValue;

  /// Whether the original blob had a well-formed (`Map`, all-`String`-keyed)
  /// top-level `history` key. [rowsToBlob] only rebuilds `history` when this
  /// is `true`. Legacy blobs with no `history` at all yield zero message
  /// rows and `false` here.
  final bool blobHadHistory;

  /// Whether `blob['history']` itself contained a `messages` key.
  /// [rowsToBlob] only synthesizes the rebuilt `messages` map when this is
  /// `true`, so a history that never had the key does not gain one.
  final bool historyHadMessages;

  /// Whether `blob['history']` itself contained a `currentId` key.
  /// [rowsToBlob] only re-emits `currentId` when this is `true`, so
  /// absent-vs-`null` is not conflated.
  final bool historyHadCurrentId;

  /// Extra keys that lived inside `blob['history']` besides `messages` and
  /// `currentId`, verbatim.
  ///
  /// Defensive special cases for corrupt data: a non-`Map`
  /// `history['messages']` value (or a Dart-built `Map` with non-`String`
  /// keys) or a non-`String`, non-null `history['currentId']` value is
  /// preserved verbatim here under its original key, and [rowsToBlob] will
  /// not overwrite it.
  final Map<String, dynamic> historyExtra;
}

/// Pure mapping between Open WebUI chat blobs and normalized rows
/// (CDT-RFC-001 §6.1).
class ChatBlobMapper {
  const ChatBlobMapper._();

  /// Decomposes a server `ChatResponse.chat` [blob] into normalized rows.
  ///
  /// Envelope fields ([title], [folderId], [pinned], [archived],
  /// [createdAt], [updatedAt]) come from the API envelope, not the blob.
  /// Message rows come from `blob['history']['messages']` (a map keyed by
  /// message id); everything that cannot be mapped losslessly is preserved
  /// verbatim so [rowsToBlob] can reconstruct the exact original blob.
  static ChatRows blobToRows({
    required String chatId,
    required Map<String, dynamic> blob,
    required String title,
    String? folderId,
    bool pinned = false,
    bool archived = false,
    required int createdAt,
    required int updatedAt,
  }) {
    final blobHadTitle = blob.containsKey('title');
    final blobTitleValue = blob['title'];
    final historyValue = blob['history'];
    // Non-String keys cannot come from jsonDecode, but Dart-built blobs can
    // carry them; treat such a history as malformed and keep it verbatim.
    final blobHadHistory =
        blob.containsKey('history') &&
        historyValue is Map &&
        _hasOnlyStringKeys(historyValue);

    final rawExtra = <String, dynamic>{};
    for (final entry in blob.entries) {
      if (entry.key == 'title') continue;
      // A well-formed history is decomposed below; a malformed (non-Map or
      // non-String-keyed) history value rides along verbatim in rawExtra so
      // the round trip stays exact.
      if (entry.key == 'history' && blobHadHistory) continue;
      rawExtra[entry.key] = entry.value;
    }

    final historyExtra = <String, dynamic>{};
    final messages = <MessageRowData>[];
    final unmappableMessages = <String, dynamic>{};
    final unmappableMessageOrder = <String, int>{};
    String? currentMessageId;
    var historyHadMessages = false;
    var historyHadCurrentId = false;

    if (blobHadHistory) {
      for (final entry in historyValue.entries) {
        final key = entry.key as String;
        final value = entry.value;
        if (key == 'currentId') {
          historyHadCurrentId = true;
          if (value == null || value is String) {
            currentMessageId = value as String?;
          } else {
            // Corrupt non-string currentId: preserve verbatim.
            historyExtra[key] = value;
          }
        } else if (key == 'messages') {
          historyHadMessages = true;
          if (value is Map && _hasOnlyStringKeys(value)) {
            var orderIndex = 0;
            for (final messageEntry in value.entries) {
              final messageKey = messageEntry.key as String;
              final messageValue = messageEntry.value;
              if (messageValue is Map &&
                  messageValue['role'] is String &&
                  _hasOnlyStringKeys(messageValue)) {
                // The map key is the canonical id upstream, even when the
                // embedded message['id'] disagrees with it.
                final payload = Map<String, dynamic>.from(messageValue);
                final contentValue = payload['content'];
                final timestampValue = payload['timestamp'];
                messages.add(
                  MessageRowData(
                    id: messageKey,
                    chatId: chatId,
                    parentId: payload['parentId'] is String
                        ? payload['parentId'] as String
                        : null,
                    role: payload['role'] as String,
                    content: contentValue is String
                        ? contentValue
                        : jsonEncode(contentValue),
                    model: payload['model'] is String
                        ? payload['model'] as String
                        : null,
                    createdAt: timestampValue is num
                        ? timestampValue.toInt()
                        : createdAt,
                    orderIndex: orderIndex,
                    payload: payload,
                  ),
                );
              } else {
                // Not a Map, no String role (null garbage, partial ghost
                // nodes, etc.), or a Dart-built Map with non-String keys:
                // cannot become a row; keep verbatim.
                unmappableMessages[messageKey] = messageValue;
                unmappableMessageOrder[messageKey] = orderIndex;
              }
              orderIndex++;
            }
          } else {
            // Corrupt messages container (non-Map, or non-String-keyed):
            // preserve verbatim.
            historyExtra[key] = value;
          }
        } else {
          historyExtra[key] = value;
        }
      }
    }

    return ChatRows(
      chat: ChatRowData(
        id: chatId,
        title: title,
        folderId: folderId,
        pinned: pinned,
        archived: archived,
        currentMessageId: currentMessageId,
        createdAt: createdAt,
        updatedAt: updatedAt,
        rawExtra: rawExtra,
      ),
      messages: messages,
      unmappableMessages: unmappableMessages,
      unmappableMessageOrder: unmappableMessageOrder,
      blobHadTitle: blobHadTitle,
      blobTitleValue: blobTitleValue,
      blobHadHistory: blobHadHistory,
      historyHadMessages: historyHadMessages,
      historyHadCurrentId: historyHadCurrentId,
      historyExtra: historyExtra,
    );
  }

  /// Whether every key of [map] is a `String`. JSON objects always satisfy
  /// this; Dart-built maps may not, and such maps are treated as malformed
  /// and preserved verbatim instead of being decomposed.
  static bool _hasOnlyStringKeys(Map<dynamic, dynamic> map) =>
      map.keys.every((key) => key is String);

  /// Reconstructs the original blob from [rows] (CDT-RFC-001 §6.1).
  ///
  /// Starts from [ChatRowData.rawExtra]; re-emits the verbatim
  /// [ChatRows.blobTitleValue] only when [ChatRows.blobHadTitle] is `true`;
  /// rebuilds `history` (extra keys first, then `messages` in original order
  /// followed by unmappable entries, then `currentId`) only when
  /// [ChatRows.blobHadHistory] is `true`, and only synthesizes the
  /// `messages` / `currentId` sub-keys when the original history actually
  /// contained them ([ChatRows.historyHadMessages] /
  /// [ChatRows.historyHadCurrentId]). Satisfies the round-trip invariant
  /// `DeepCollectionEquality().equals(rowsToBlob(blobToRows(...)), blob)`.
  static Map<String, dynamic> rowsToBlob(ChatRows rows) {
    final blob = <String, dynamic>{...rows.chat.rawExtra};

    if (rows.blobHadTitle) {
      blob['title'] = rows.blobTitleValue;
    }

    if (rows.blobHadHistory) {
      final history = <String, dynamic>{...rows.historyExtra};

      // historyExtra only carries `messages`/`currentId` when the originals
      // were malformed and preserved verbatim; never overwrite those. And
      // never invent a sub-key the original history did not have.
      if (rows.historyHadMessages && !history.containsKey('messages')) {
        final messages = <String, dynamic>{};
        final ordered =
            <({int orderIndex, String id, Object? payload})>[
              for (final message in rows.messages)
                (
                  orderIndex: message.orderIndex,
                  id: message.id,
                  payload: message.payload,
                ),
              for (final entry in rows.unmappableMessages.entries)
                (
                  orderIndex: rows.unmappableMessageOrder[entry.key] ?? 1 << 30,
                  id: entry.key,
                  payload: entry.value,
                ),
            ]..sort((a, b) {
              final byOrder = a.orderIndex.compareTo(b.orderIndex);
              if (byOrder != 0) return byOrder;
              return a.id.compareTo(b.id);
            });
        for (final entry in ordered) {
          messages[entry.id] = entry.payload;
        }
        history['messages'] = messages;
      }
      if (rows.historyHadCurrentId && !history.containsKey('currentId')) {
        history['currentId'] = rows.chat.currentMessageId;
      }

      blob['history'] = history;
    }

    return blob;
  }

  /// Returns the ids of [parentId]'s children among [all], ordered by
  /// `createdAt` ascending with ties broken by `orderIndex` ascending
  /// (CDT-RFC-001 §6.1).
  ///
  /// Used by later phases to rebuild `childrenIds` deterministically after
  /// local tree edits.
  static List<String> deriveChildrenIds(
    String parentId,
    List<MessageRowData> all,
  ) {
    final children = all.where((m) => m.parentId == parentId).toList()
      ..sort((a, b) {
        final byCreatedAt = a.createdAt.compareTo(b.createdAt);
        if (byCreatedAt != 0) return byCreatedAt;
        return a.orderIndex.compareTo(b.orderIndex);
      });
    return [for (final child in children) child.id];
  }

  /// Whether the message tree inside [blob] is internally consistent
  /// (CDT-RFC-001 §6.1).
  ///
  /// Returns `true` iff every message's `childrenIds` exactly matches the
  /// set of messages whose `parentId` points at it (order ignored), and
  /// `history.currentId` (if set) exists in `history.messages`.
  ///
  /// Only map-shaped entries of `history.messages` participate as messages;
  /// the entry key is treated as the canonical id. A blob without a
  /// well-formed `history` map has no tree to validate and is vacuously
  /// consistent. A `childrenIds` value that is present but not a list of
  /// strings is inconsistent.
  static bool treeIsConsistent(Map<String, dynamic> blob) {
    final history = blob['history'];
    if (history is! Map) return true;

    final messagesValue = history['messages'];
    final messages = messagesValue is Map
        ? messagesValue
        : const <String, dynamic>{};

    final currentId = history['currentId'];
    if (currentId != null && !messages.containsKey(currentId)) {
      return false;
    }

    // Actual parent -> children mapping derived from parentId pointers.
    final childrenByParent = <Object?, Set<Object?>>{};
    for (final entry in messages.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final parentId = value['parentId'];
      if (parentId == null) continue;
      childrenByParent.putIfAbsent(parentId, () => <Object?>{}).add(entry.key);
    }

    for (final entry in messages.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final declaredValue = value['childrenIds'];
      final declared = <Object?>{};
      if (declaredValue is List) {
        declared.addAll(declaredValue);
      } else if (declaredValue != null) {
        // childrenIds present but not a list: malformed tree.
        return false;
      }
      final actual = childrenByParent[entry.key] ?? const <Object?>{};
      if (declared.length != actual.length || !declared.containsAll(actual)) {
        return false;
      }
    }

    return true;
  }
}
