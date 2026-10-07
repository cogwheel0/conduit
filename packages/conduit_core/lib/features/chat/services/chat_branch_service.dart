import 'dart:convert';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/pull_sync.dart'
    show ChatRowsParseOffload, parseChatRowsWorker;
import 'package:conduit_core/utils/message_tree_utils.dart';
import 'package:dio/dio.dart' show DioException;
import 'package:meta/meta.dart';

/// Why a branch operation did not happen.
enum ChatBranchFailure {
  /// Not a durable Open WebUI chat, or it has no stored copy to branch.
  unavailable,

  /// A response is still running on this chat. Branches never change under it.
  responseRunning,

  /// The server, account or sign-in session changed mid-operation.
  ownerChanged,

  /// The chat's stored graph has no such message.
  messageNotFound,

  /// The message is not a same-role alternative of the one displayed, so its id
  /// cannot be trusted as a branch.
  notAnAlternative,

  /// A fork needs the server and the device is offline.
  offline,

  /// 403: the account may not import (and so not fork) chats.
  forkForbidden,

  /// 401: the server does not know this chat for this account any more.
  forkSourceMissing,

  /// The server's fork route is absent (an older server).
  forkUnsupported,

  /// 409: a response is still running on the server.
  forkConflict,

  /// Any other failure of the fork request or of storing its answer.
  forkFailed,
}

final class ChatBranchException implements Exception {
  const ChatBranchException(this.reason);

  final ChatBranchFailure reason;

  @override
  String toString() => 'ChatBranchException(${reason.name})';
}

/// The message graph of one chat: every message, not the presentation window.
///
/// Holds only ids, parents, roles, ordered children and a short text preview,
/// so it is cheap to build from a stored envelope and safe to hand across an
/// isolate. Reading it never
/// modifies the stored graph, and malformed input (a missing child, a cycle, an
/// orphan) only shortens a walk.
@immutable
final class ChatBranchGraph {
  const ChatBranchGraph._(this._nodes);

  /// Builds the graph from a chat envelope as [buildChatResponseEnvelope] (or
  /// the server) produces it: the messages of `chat.history`.
  factory ChatBranchGraph.fromEnvelope(Map<String, dynamic> envelope) {
    final chat = envelope['chat'];
    final history = chat is Map ? chat['history'] : null;
    final rawMessages = history is Map ? history['messages'] : null;
    final declared = <String, _Node>{};
    final pointingAt = <String, List<String>>{};
    if (rawMessages is Map) {
      rawMessages.forEach((key, value) {
        final id = normalizeMessageId(key);
        if (id == null || value is! Map) return;
        final parentId = normalizeMessageId(value['parentId']);
        declared[id] = (
          parentId: parentId,
          role: normalizeMessageId(value['role']) ?? '',
          childrenIds: coerceMessageIdList(value['childrenIds']),
          preview: _previewOf(value['content']),
        );
        if (parentId != null) {
          pointingAt.putIfAbsent(parentId, () => <String>[]).add(id);
        }
      });
    }

    // A child the parent does not list (a stale `childrenIds`) is still its
    // child: append it after the listed ones, in message order.
    final nodes = <String, _Node>{};
    for (final entry in declared.entries) {
      final listed = entry.value.childrenIds
          .where(declared.containsKey)
          .toList();
      final seen = listed.toSet();
      for (final childId in pointingAt[entry.key] ?? const <String>[]) {
        if (seen.add(childId)) listed.add(childId);
      }
      nodes[entry.key] = (
        parentId: entry.value.parentId,
        role: entry.value.role,
        childrenIds: List<String>.unmodifiable(listed),
        preview: entry.value.preview,
      );
    }
    return ChatBranchGraph._(Map<String, _Node>.unmodifiable(nodes));
  }

  final Map<String, _Node> _nodes;

  bool contains(String messageId) => _nodes.containsKey(messageId);

  /// The leaf selecting [messageId] leads to: from it, always the last child.
  String? leafBelow(String messageId) => deepestLastChildId<_Node>(
    messageId,
    messagesById: _nodes,
    childrenIdsOf: (node) => node.childrenIds,
  );

  /// Ids sharing [messageId]'s parent in display order, [messageId] included.
  List<String> siblingIdsOf(String messageId) => orderedSiblingIds<_Node>(
    messageId,
    messagesById: _nodes,
    parentIdOf: (node) => node.parentId,
    childrenIdsOf: (node) => node.childrenIds,
  );

  /// Whether [candidateId] is another message answering the same parent in the
  /// same role as [displayedId]: the only thing a displayed alternative may be.
  bool isAlternativeOf(String candidateId, String displayedId) {
    if (candidateId == displayedId) return false;
    final candidate = _nodes[candidateId];
    final displayed = _nodes[displayedId];
    if (candidate == null || displayed == null) return false;
    return candidate.parentId == displayed.parentId &&
        candidate.role == displayed.role &&
        siblingIdsOf(displayedId).contains(candidateId);
  }

  /// The alternatives to [messageId] (same parent, same role, [messageId]
  /// included) in display order, or null when it is not in the graph.
  ChatBranchSiblings? siblingsOf(String messageId) {
    final displayed = _nodes[messageId];
    if (displayed == null) return null;
    final ids = [
      for (final id in siblingIdsOf(messageId))
        if (_nodes[id]!.role == displayed.role) id,
    ];
    return ChatBranchSiblings(
      messageId: messageId,
      ids: ids,
      previews: {
        for (final id in ids)
          if (_nodes[id]!.preview.isNotEmpty) id: _nodes[id]!.preview,
      },
    );
  }
}

typedef _Node = ({
  String? parentId,
  String role,
  List<String> childrenIds,
  String preview,
});

/// Longest preview kept per message: enough for a two-line subtitle, small
/// enough that a long chat's graph stays cheap to pass between isolates.
const int _previewLength = 160;

/// A message's text on one line, shortened to [_previewLength]. Only plain text
/// parts count; attachments and other parts have nothing to show here.
String _previewOf(Object? content) {
  final String text;
  if (content is String) {
    text = content;
  } else if (content is List) {
    text = content
        .whereType<Map>()
        .where((part) => part['type'] == 'text')
        .map((part) => part['text'])
        .whereType<String>()
        .join(' ');
  } else {
    return '';
  }
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= _previewLength) return collapsed;
  // Never cut a surrogate pair in half.
  final lead = collapsed.codeUnitAt(_previewLength - 1);
  final end = lead >= 0xD800 && lead <= 0xDBFF
      ? _previewLength - 1
      : _previewLength;
  return '${collapsed.substring(0, end).trimRight()}…';
}

/// The alternatives to one displayed message, identified by their real message
/// ids, in the order Open WebUI shows them.
@immutable
final class ChatBranchSiblings {
  const ChatBranchSiblings({
    required this.messageId,
    required this.ids,
    this.previews = const <String, String>{},
  });

  /// The message these are alternatives to.
  final String messageId;

  /// Same parent and role, [messageId] included.
  final List<String> ids;

  /// A short one-line excerpt of each version's text, by id. A version with no
  /// text (only attachments, say) has no entry.
  final Map<String, String> previews;

  /// [messageId]'s 0-based position among [ids].
  int get index => ids.indexOf(messageId);

  bool contains(String candidateId) => ids.contains(candidateId);
}

/// Top-level so a worker isolate can run it.
ChatBranchGraph parseChatBranchGraphWorker(Map<String, dynamic> envelope) =>
    ChatBranchGraph.fromEnvelope(envelope);

typedef ChatBranchGraphOffload = Future<ChatBranchGraph> Function(
  Map<String, dynamic> envelope,
);

/// Fetches the chat's authoritative envelope for the account that started the
/// operation (never whoever is signed in by the time the answer arrives).
typedef ChatEnvelopeLoader = Future<Map<String, dynamic>?> Function(
  String chatId,
);

/// Sends the fork request for the account that started the operation.
typedef ChatForkRequest = Future<Map<String, dynamic>> Function(
  String chatId,
  String messageId,
);

@immutable
final class ChatBranchSelection {
  const ChatBranchSelection({required this.leafId, required this.changed});

  /// The leaf now (or already) active: where the chosen branch ends.
  final String leafId;

  /// False when the chat already was on [leafId]; nothing was written.
  final bool changed;
}

@immutable
final class ChatForkOutcome {
  const ChatForkOutcome({required this.chatId});

  /// The new chat's server id, already stored locally.
  final String chatId;
}

/// Branch operations on one Open WebUI chat, bound to the owner that began
/// them.
///
/// Every read and write goes through the one database that owner captured, and
/// [ownerIsCurrent] is asked after each await and immediately before each write
/// so a server, account or session change in between aborts without touching
/// anything. The service is built per operation and holds no state.
final class ChatBranchService {
  const ChatBranchService({
    required this.database,
    required this.locks,
    required this.ownerIsCurrent,
    required this.nowEpochSeconds,
    this.graphOffload,
    this.rowsParseOffload,
    this.authoritativeLoader,
    this.responseIsRunning,
  });

  final AppDatabase database;
  final ChatLocks locks;
  final bool Function() ownerIsCurrent;
  final int Function() nowEpochSeconds;

  /// Parses a large graph off the UI isolate. Null parses inline.
  final ChatBranchGraphOffload? graphOffload;

  /// Decomposes a large server envelope off the UI isolate. Null parses inline.
  final ChatRowsParseOffload? rowsParseOffload;

  /// Loads a chat whose body is not stored yet. Without one, such a chat has no
  /// graph to branch.
  final ChatEnvelopeLoader? authoritativeLoader;

  /// Whether a response is running on the chat in memory (a stream the database
  /// does not know about yet). Queued completions are found in the database.
  final bool Function(String chatId)? responseIsRunning;

  void _requireOwner() {
    if (!ownerIsCurrent()) {
      throw const ChatBranchException(ChatBranchFailure.ownerChanged);
    }
  }

  /// The complete graph of [chatId], read in one database snapshot, or null when
  /// the chat is absent or has no stored body. A chat whose body is not stored
  /// is first loaded authoritatively and merged through the database contract.
  Future<ChatBranchGraph?> readGraph(String chatId) async {
    _requireOwner();
    var graph = await _readStoredGraph(chatId);
    if (graph == null && await _needsBody(chatId)) {
      await _materialize(chatId);
      graph = await _readStoredGraph(chatId);
    }
    _requireOwner();
    return graph;
  }

  /// The complete envelope of [chatId] as stored on this device, read in one
  /// database snapshot: every message and branch, edits not yet sent, params and
  /// timestamps, never the visible window. Null when the chat is absent. A chat
  /// whose body is not stored yet is first loaded authoritatively and merged
  /// through the database contract, like [readGraph].
  Future<Map<String, dynamic>?> readEnvelope(String chatId) async {
    _requireOwner();
    var stored = await _readStoredRows(chatId);
    if (stored == null && await _needsBody(chatId)) {
      await _materialize(chatId);
      stored = await _readStoredRows(chatId);
    }
    _requireOwner();
    return stored == null
        ? null
        : buildChatResponseEnvelope(stored.chat, stored.rows);
  }

  /// Makes [messageId] the chat's active branch: its leaf becomes `currentId`.
  ///
  /// One locked unit: the owner and the running-response check, the graph read,
  /// the leaf resolution and the transactional write. A running response on the
  /// chat blocks it, and it never stops one.
  Future<ChatBranchSelection> selectBranch({
    required String chatId,
    required String messageId,
    String? alternativeTo,
  }) async {
    _requireOwner();
    if (await _needsBody(chatId)) await _materialize(chatId);
    return locks.runExclusive(chatId, () async {
      _requireOwner();
      if (await _responseIsRunning(chatId)) {
        throw const ChatBranchException(ChatBranchFailure.responseRunning);
      }
      final graph = await _readStoredGraph(chatId);
      if (graph == null) {
        throw const ChatBranchException(ChatBranchFailure.unavailable);
      }
      if (!graph.contains(messageId)) {
        throw const ChatBranchException(ChatBranchFailure.messageNotFound);
      }
      if (alternativeTo != null &&
          !graph.isAlternativeOf(messageId, alternativeTo)) {
        throw const ChatBranchException(ChatBranchFailure.notAnAlternative);
      }
      final leafId = graph.leafBelow(messageId);
      if (leafId == null) {
        throw const ChatBranchException(ChatBranchFailure.messageNotFound);
      }
      final written = await database.chatsDao.patchChatCurrentMessageWithOutbox(
        chatId,
        leafId,
        updatedAt: nowEpochSeconds(),
      );
      if (written == null) {
        throw const ChatBranchException(ChatBranchFailure.unavailable);
      }
      return ChatBranchSelection(leafId: leafId, changed: written);
    });
  }

  /// Forks [chatId] at [messageId] on the server and stores the answer.
  ///
  /// Sends [request] exactly once and never falls back to a whole-chat clone. A
  /// stopped response, a missing source and an unsupported server each surface
  /// as their own [ChatBranchFailure]. The returned envelope is the whole
  /// authoritative chat: it is stored as given (id, folder, title, params and
  /// full graph), never rebuilt from what is on screen. If the owner changed
  /// while the request was in flight nothing is stored: the fork exists on that
  /// account's server and its next sync brings it in.
  Future<ChatForkOutcome> forkAt({
    required String chatId,
    required String messageId,
    required ChatForkRequest request,
  }) async {
    _requireOwner();
    final graph = await readGraph(chatId);
    if (graph == null) {
      throw const ChatBranchException(ChatBranchFailure.unavailable);
    }
    if (!graph.contains(messageId)) {
      throw const ChatBranchException(ChatBranchFailure.messageNotFound);
    }

    final readGeneration = locks.generation;
    final Map<String, dynamic> envelope;
    try {
      envelope = await request(chatId, messageId);
    } on ChatBranchException {
      rethrow;
    } catch (error) {
      throw ChatBranchException(chatBranchFailureForForkError(error));
    }
    _requireOwner();

    final forkId = envelope['id'];
    if (forkId is! String || forkId.isEmpty || forkId == chatId) {
      throw const ChatBranchException(ChatBranchFailure.forkFailed);
    }
    try {
      await _storeEnvelope(
        forkId,
        envelope,
        readGeneration: readGeneration,
        staleFailure: ChatBranchFailure.forkFailed,
      );
    } on ChatBranchException {
      rethrow;
    } catch (_) {
      throw const ChatBranchException(ChatBranchFailure.forkFailed);
    }
    return ChatForkOutcome(chatId: forkId);
  }

  Future<bool> _responseIsRunning(String chatId) async {
    if (responseIsRunning?.call(chatId) == true) return true;
    final active = await database.outboxDao.activeForChat(
      chatId,
      domainKind: OutboxKind.requestCompletion,
    );
    return active.any(
      (op) => OutboxKind.fromName(op.kind) == OutboxKind.requestCompletion,
    );
  }

  Future<bool> _needsBody(String chatId) async {
    final row = await database.chatsDao.getChat(chatId);
    return row != null && !row.deleted && !row.bodySynced;
  }

  Future<({ChatRow chat, List<MessageRow> rows})?> _readStoredRows(
    String chatId,
  ) async {
    final stored = await database.transaction(() async {
      final chat = await database.chatsDao.getChat(chatId);
      if (chat == null || chat.deleted || !chat.bodySynced) return null;
      final rows = await database.messagesDao.getForChat(chatId);
      return (chat: chat, rows: rows);
    });
    _requireOwner();
    return stored;
  }

  Future<ChatBranchGraph?> _readStoredGraph(String chatId) async {
    final stored = await _readStoredRows(chatId);
    if (stored == null) return null;
    final envelope = buildChatResponseEnvelope(stored.chat, stored.rows);
    final offload = graphOffload;
    final graph =
        offload != null &&
            stored.rows.length > kLocalConversationWorkerThreshold
        ? await offload(envelope)
        : ChatBranchGraph.fromEnvelope(envelope);
    _requireOwner();
    return graph;
  }

  Future<void> _materialize(String chatId) async {
    final loader = authoritativeLoader;
    if (loader == null) {
      throw const ChatBranchException(ChatBranchFailure.unavailable);
    }
    final readGeneration = locks.generation;
    final envelope = await loader(chatId);
    _requireOwner();
    if (envelope == null || envelope['id'] != chatId) {
      throw const ChatBranchException(ChatBranchFailure.unavailable);
    }
    await _storeEnvelope(chatId, envelope, readGeneration: readGeneration);
  }

  /// Stores a server envelope through the database's three-way merge, under the
  /// chat's lock, so a local edit already queued for this chat is kept.
  ///
  /// [readGeneration] is the lock generation from before the envelope was
  /// requested. An account-wide change that ended since may have deleted the
  /// chat, so a stale read is dropped with [staleFailure] instead of bringing it
  /// back.
  Future<void> _storeEnvelope(
    String chatId,
    Map<String, dynamic> envelope, {
    int? readGeneration,
    ChatBranchFailure staleFailure = ChatBranchFailure.unavailable,
  }) async {
    final chat = envelope['chat'];
    final messageCount = switch (chat) {
      {'history': {'messages': final Map<dynamic, dynamic> messages}} =>
        messages.length,
      _ => 0,
    };
    final offload = rowsParseOffload;
    final rows =
        offload != null && messageCount > kLocalConversationWorkerThreshold
        ? await offload(envelope)
        : parseChatRowsWorker(envelope);
    _requireOwner();

    final rawMeta = envelope['meta'];
    final meta = rawMeta is Map
        ? <String, dynamic>{
            for (final entry in rawMeta.entries)
              entry.key.toString(): entry.value,
          }
        : null;
    meta?.remove('_conduit_tasks');
    final shareId = envelope['share_id'];
    await locks.runExclusive(chatId, () async {
      _requireOwner();
      if (readGeneration != null && readGeneration != locks.generation) {
        throw ChatBranchException(staleFailure);
      }
      await database.chatsDao.mergeServerChat(
        server: rows,
        shareId: shareId is String ? shareId : null,
        userId: envelope['user_id']?.toString(),
        meta: meta,
      );
    });
  }
}

/// Classifies a failed fork request. The route answers 403 without
/// `chat.import`, 401 for a chat the account does not own, 404 for an unknown
/// message, 409 while a response runs, and is simply absent on older servers.
@visibleForTesting
ChatBranchFailure chatBranchFailureForForkError(Object error) {
  if (error is! DioException) return ChatBranchFailure.forkFailed;
  final status = error.response?.statusCode;
  switch (status) {
    case 403:
      return ChatBranchFailure.forkForbidden;
    case 401:
      return ChatBranchFailure.forkSourceMissing;
    case 409:
      return ChatBranchFailure.forkConflict;
    case 405:
      return ChatBranchFailure.forkUnsupported;
    case 404:
      return _responseDetail(error.response?.data) == 'message not found'
          ? ChatBranchFailure.messageNotFound
          : ChatBranchFailure.forkUnsupported;
    default:
      return ChatBranchFailure.forkFailed;
  }
}

String? _responseDetail(Object? data) {
  Object? decoded = data;
  if (decoded is List<int>) {
    try {
      decoded = jsonDecode(utf8.decode(decoded, allowMalformed: true));
    } on FormatException {
      return null;
    }
  } else if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      return decoded.toString();
    }
  }
  if (decoded is Map) {
    final detail = decoded['detail'];
    return detail is String ? detail : null;
  }
  return null;
}
