/// Row -> model mapping layer (CDT-RFC-001 §8, Phase 1).
///
/// Pure Dart, no Flutter imports: rebuilds the exact `ChatResponse`-shaped
/// map the app parses today from Drift rows, then funnels it through the
/// existing `parseFullConversationModel` entry point so UI code never sees
/// Drift row classes.
library;

import 'dart:convert';

import '../../models/conversation.dart';
import '../../models/folder.dart';
import '../../services/conversation_parsing.dart';
import '../app_database.dart';
import '../daos/chats_dao.dart';
import '../daos/search_dao.dart';
import 'chat_blob_mapper.dart';

/// Message count above which assembly MUST be offloaded to a worker isolate.
/// (`ApiService` uses a separate payload byte-size heuristic for the same
/// purpose.) Single source of truth — `local_conversation_loader.dart`
/// re-exports this constant for callers that already import from there.
const int kLocalConversationWorkerThreshold = 100;

/// Inverse of `ChatsDao.upsertServerChat`'s decomposition: rebuilds
/// [ChatRows] from a [ChatRow] + its [MessageRow]s (payload jsonDecoded per
/// row; bookkeeping from `blobMeta` per amendment A3; `'{}'` blobMeta -> all
/// flags false/empty).
ChatRows chatRowsFromDb(ChatRow chat, List<MessageRow> messages) {
  final blobMeta = _decodeJsonMap(chat.blobMeta);
  return ChatRows(
    chat: ChatRowData(
      id: chat.id,
      title: chat.title,
      folderId: chat.folderId,
      pinned: chat.pinned,
      archived: chat.archived,
      currentMessageId: chat.currentMessageId,
      createdAt: chat.createdAt,
      updatedAt: chat.updatedAt,
      rawExtra: _decodeJsonMap(chat.rawExtra),
    ),
    messages: [
      for (final message in messages)
        MessageRowData(
          id: message.id,
          chatId: message.chatId,
          parentId: message.parentId,
          role: message.role,
          content: message.content,
          model: message.model,
          createdAt: message.createdAt,
          orderIndex: message.orderIndex,
          payload: _decodeJsonMap(message.payload),
        ),
    ],
    unmappableMessages: _asJsonMap(blobMeta['unmappableMessages']),
    unmappableMessageOrder: _asStringIntMap(blobMeta['unmappableMessageOrder']),
    blobHadTitle: blobMeta['blobHadTitle'] == true,
    blobTitleValue: blobMeta['blobTitleValue'],
    blobHadHistory: blobMeta['blobHadHistory'] == true,
    historyHadMessages: blobMeta['historyHadMessages'] == true,
    historyHadCurrentId: blobMeta['historyHadCurrentId'] == true,
    historyExtra: _asJsonMap(blobMeta['historyExtra']),
  );
}

/// Rebuilds the exact `ChatResponse`-shaped map the app parses today; ints
/// stay epoch seconds.
Map<String, dynamic> buildChatResponseEnvelope(
  ChatRow chat,
  List<MessageRow> messages,
) {
  return <String, dynamic>{
    'id': chat.id,
    'title': chat.title,
    'chat': ChatBlobMapper.rowsToBlob(chatRowsFromDb(chat, messages)),
    'updated_at': chat.updatedAt,
    'created_at': chat.createdAt,
    'last_read_at': chat.lastReadAt,
    'pinned': chat.pinned,
    'archived': chat.archived,
    'folder_id': chat.folderId,
    'share_id': chat.shareId,
    'meta': _decodeJsonMap(chat.meta),
  };
}

/// `parseFullConversationModel(buildChatResponseEnvelope(...))` — the parse
/// entry point in `conversation_parsing.dart`.
///
/// **New call sites MUST use [assembleConversationGuarded] instead.**
/// Raw calls here violate the worker contract when `messages.length >
/// [kLocalConversationWorkerThreshold]` and will block the UI isolate on large
/// conversations.
Conversation assembleConversation(ChatRow chat, List<MessageRow> messages) {
  return parseFullConversationModel(buildChatResponseEnvelope(chat, messages));
}

/// Closure type for offloading a pre-built envelope to a worker isolate.
/// The caller is responsible for routing through [parseFullConversationModelWorker]
/// via [WorkerManager.schedule].
typedef ConversationParseOffload = Future<Conversation> Function(
  Object? envelope,
);

/// Contract-enforcing wrapper around [assembleConversation]: offloads via
/// [offload] when `messages.length` exceeds [kLocalConversationWorkerThreshold],
/// otherwise parses synchronously inline.
///
/// Callers that cannot supply an offload pass `null` and accept the documented
/// jank risk (equivalent to the old raw [assembleConversation] call).
Future<Conversation> assembleConversationGuarded(
  ChatRow chat,
  List<MessageRow> messages, {
  required ConversationParseOffload? offload,
}) {
  if (offload != null && messages.length > kLocalConversationWorkerThreshold) {
    return offload(buildChatResponseEnvelope(chat, messages));
  }
  return Future.value(assembleConversation(chat, messages));
}

/// Shared body-less summary builder. Timestamps are epoch SECONDS (scaled to
/// millis), matching `_parseTimestamp` (local tz). Used by both the list-entry
/// and search-hit mappers, whose envelopes are identical apart from field
/// names.
Conversation _summaryConversation({
  required String id,
  required String title,
  required int createdAtSec,
  required int updatedAtSec,
  required int? lastReadAtSec,
  required bool pinned,
  required bool archived,
  required String? folderId,
}) {
  return Conversation(
    id: id,
    title: title,
    createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtSec * 1000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtSec * 1000),
    lastReadAt: lastReadAtSec == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastReadAtSec * 1000),
    pinned: pinned,
    archived: archived,
    folderId: folderId,
    messages: const [],
    tags: const [],
    metadata: const {},
  );
}

/// List-summary mapper: identical shape to today's server summaries
/// (messages/tags/metadata empty).
Conversation conversationFromListEntry(ChatListEntry e) {
  return _summaryConversation(
    id: e.id,
    title: e.title,
    createdAtSec: e.createdAt,
    updatedAtSec: e.updatedAt,
    lastReadAtSec: e.lastReadAt,
    pinned: e.pinned,
    archived: e.archived,
    folderId: e.folderId,
  );
}

/// Offline full-text search hit -> list-summary model (CDT-RFC-001 Phase 4).
///
/// [SearchHit] carries the SAME narrow envelope as [ChatListEntry] (no message
/// bodies — REQ §10.2), so the resulting [Conversation] is shape-identical to a
/// server search summary and slots straight into the existing search results
/// UI. The bm25 [SearchHit.rank] / [SearchHit.snippet] are intentionally NOT
/// surfaced on [Conversation]; ordering is preserved by the list order the
/// caller hands in (already bm25-ascending).
Conversation conversationFromSearchHit(SearchHit hit) {
  return _summaryConversation(
    id: hit.chatId,
    title: hit.title,
    createdAtSec: hit.createdAt,
    updatedAtSec: hit.updatedAt,
    lastReadAtSec: hit.lastReadAt,
    pinned: hit.pinned,
    archived: hit.archived,
    folderId: hit.folderId,
  );
}

/// Folder row -> model. Do NOT synthesize `conversationIds` in Phase 1.
Folder folderFromRow(FolderRow r) {
  return Folder.fromJson(<String, dynamic>{
    ..._decodeJsonMap(r.rawExtra),
    'id': r.id,
    'name': r.name,
    'parent_id': r.parentId,
    'created_at': r.createdAt,
    'updated_at': r.updatedAt,
  });
}

Map<String, dynamic> _decodeJsonMap(String raw) {
  if (raw.isEmpty) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(raw);
    return _asJsonMap(decoded);
  } catch (_) {
    return <String, dynamic>{};
  }
}

Map<String, dynamic> _asJsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  return <String, dynamic>{};
}

Map<String, int> _asStringIntMap(Object? value) {
  if (value is! Map) return <String, int>{};
  return <String, int>{
    for (final entry in value.entries)
      if (entry.value is num)
        entry.key.toString(): (entry.value as num).toInt(),
  };
}
