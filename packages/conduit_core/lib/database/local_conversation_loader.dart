import 'dart:async';

import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatDatabaseRepository, ChatStorageIdentity;
import 'package:conduit_core/database/database_provider.dart'
    show chatDatabaseRepositoryProvider;
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/models/chat_comparison.dart'
    show
        kMessageAuthorIdMetadataKey,
        kMessageMergedMetadataKey,
        kMessageModelIdxMetadataKey,
        kMessageUnfinishedAnswerAuthorsMetadataKey,
        kMessageUnfinishedAnswersMetadataKey;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';

import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/conversation_parsing.dart';
import 'package:conduit_core/services/worker_manager.dart';

import 'package:conduit_core/sync/pull_sync.dart'
    show
        chatResponseWithoutMessages,
        parseChatRowsWorker,
        questionHeldAgain,
        withQuestionHeldAgain;
import 'package:conduit_core/sync/sync_engine.dart';

import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:dio/dio.dart' show DioException;

// kLocalConversationWorkerThreshold is defined in
// mappers/conversation_assembler.dart and re-exported here for callers that
// already import local_conversation_loader.dart. Do NOT redeclare it.
export 'package:conduit_core/database/mappers/conversation_assembler.dart'
    show kLocalConversationWorkerThreshold;

/// Fire-and-forget background pull for one chat. Best-effort freshening:
/// swallows every failure (engine unavailable, network down) so DB-first
/// opens never degrade to network-first.
void schedulePullChatNow(
  dynamic ref,
  String id, {
  OpenWebUiConversationReadSnapshot? ownership,
}) {
  final effectiveOwnership = ownership ?? captureOpenWebUiConversationRead(ref);
  if (effectiveOwnership == null ||
      !openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) {
    return;
  }
  try {
    final future =
        ref.read(syncEngineProvider.notifier).pullChatNow(id)
            as Future<Object?>;
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'background-pull-failed',
          scope: 'db/conversation',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
        return null;
      }),
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'background-pull-unavailable',
      scope: 'db/conversation',
      error: error,
      stackTrace: stackTrace,
      data: {'id': id},
    );
  }
}

/// Stored message JSON longer than this is checked for server changes with a
/// pull cycle instead of being downloaded again on every open. A cycle reads
/// the recent, archived, folder and note lists (about 12 KB compressed on a
/// typical account); a chat this size costs more than that to download, while
/// smaller chats are cheaper to fetch directly.
const int kOpenRefreshDirectPullMaxPayloadLength = 64 * 1024;

/// Background freshening for a stored OpenWebUI chat that was just opened.
///
/// A large, clean, fully stored chat joins a pull cycle: the cycle lists what
/// changed since the last one and fetches this chat only if the server's copy
/// moved, and the open chat's message watch shows the result. Anything else
/// takes the single-chat pull. Either way a change made before the open is
/// seen, because the list is read after it. Awaiting this only sizes the chat.
Future<void> scheduleOpenedChatRefresh(
  dynamic ref,
  String id, {
  OpenWebUiConversationReadSnapshot? ownership,
}) async {
  final effectiveOwnership = ownership ?? captureOpenWebUiConversationRead(ref);
  if (effectiveOwnership == null ||
      !openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) {
    return;
  }
  final db = effectiveOwnership.database;
  var checkWithCycle = false;
  if (db != null) {
    try {
      final chat = await db.chatsDao.getChat(id);
      checkWithCycle =
          chat != null &&
          chat.bodySynced &&
          !chat.dirty &&
          !chat.deleted &&
          await db.messagesDao.payloadLengthForChat(id) >
              kOpenRefreshDirectPullMaxPayloadLength;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'open-refresh-size-failed',
        scope: 'db/conversation',
        error: error,
        stackTrace: stackTrace,
        data: {'id': id},
      );
    }
  }
  if (!checkWithCycle) {
    schedulePullChatNow(ref, id, ownership: effectiveOwnership);
    return;
  }
  if (!openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) return;
  DebugLogger.log(
    'open-refresh-cycle',
    scope: 'db/conversation',
    data: {'id': id},
  );
  try {
    final future =
        ref
                .read(syncEngineProvider.notifier)
                .requestPull(reason: 'open-large-chat')
            as Future<Object?>;
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'background-pull-failed',
          scope: 'db/conversation',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
        return null;
      }),
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'background-pull-unavailable',
      scope: 'db/conversation',
      error: error,
      stackTrace: stackTrace,
      data: {'id': id},
    );
  }
}

/// First open of an OpenWebUI chat with no stored body: one download through
/// the sync engine, which stores the chat when [storeIf] accepts the raw
/// response, so the next open is DB-first without fetching it a second time.
///
/// Returns null when the engine yields nothing (inert or unavailable, a 404,
/// a read outdated by a bulk change) or fails for a reason other than the
/// network, so the caller can fall back to its direct fetch. Network failures
/// propagate, as they would from that fetch.
Future<Conversation?> fetchChatNowForOpen(
  dynamic ref,
  String id, {
  required bool Function(Map<String, dynamic> response) storeIf,
}) async {
  try {
    final future =
        ref.read(syncEngineProvider.notifier).fetchChatNow(id, storeIf: storeIf)
            as Future<Conversation?>;
    return await future;
  } on DioException {
    rethrow;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'open-fetch-failed',
      scope: 'db/conversation',
      error: error,
      stackTrace: stackTrace,
      data: {'id': id},
    );
    return null;
  }
}

/// Chat [conversationId] (scoped or raw) as its own store holds it, parsed as
/// an open shows it; null when no open store holds its body. Unlike an open
/// ([loadConversationProvider]) it schedules no refresh and never asks the
/// server, so a caller that has just pulled the chat starts nothing it could
/// not wait for.
Future<Conversation?> readStoredConversation(
  dynamic ref,
  String conversationId,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final repository =
      ref.read(chatDatabaseRepositoryProvider) as ChatDatabaseRepository;
  final workerManager = ref.read(workerManagerProvider) as WorkerManager;
  final located = await repository.loadConversation(
    identity.rawId,
    preferred: identity.storage,
    offload: (envelope) => workerManager.schedule(
      parseFullConversationModelWorker,
      envelope,
      debugLabel: 'db.readStoredConversation',
    ),
  );
  return located?.conversation;
}

/// Freshen one chat through the sync engine, falling back to a direct API
/// fetch when the engine is inert/unavailable (no database, reviewer mode).
///
/// Returns the assembled [Conversation], or `null` when the engine yielded
/// nothing AND no API service is available. Shared by the passive/resume
/// refresh paths (CDT-RFC-001 Phase 1).
Future<Conversation?> pullChatOrFetch(dynamic ref, String id) async {
  final ownership = captureOpenWebUiConversationRead(ref);
  if (ownership == null) return null;
  final api = ownership.api;
  final syncEngine = ref.read(syncEngineProvider.notifier);

  Conversation? refreshed;
  try {
    refreshed = await syncEngine.pullChatNow(id);
  } catch (_) {
    refreshed = null;
  }
  if (!openWebUiConversationReadIsCurrent(ref, ownership)) return null;
  if (refreshed == null) {
    if (api == null) return null;
    // Bound to the session just checked: another can sign in while the
    // deletes still to land are read.
    final authSnapshot = api.captureAuthSnapshot();
    try {
      refreshed = await readChatWithoutUnsentDeletes(
        ref,
        api,
        ownership.database,
        id,
        authSnapshot: authSnapshot,
      );
    } catch (error, stackTrace) {
      if (!api.authSnapshotIsCurrent(authSnapshot)) return null;
      DebugLogger.error(
        'fallback-fetch-failed',
        scope: 'db/conversation',
        error: error,
        stackTrace: stackTrace,
        data: {'id': id},
      );
      return null;
    }
    if (!openWebUiConversationReadIsCurrent(ref, ownership)) return null;
  }
  return refreshed;
}

/// The messages of chat [chatId] whose delete on the server has not landed
/// yet ([OutboxDao.unsentMessageDeletes]).
Future<Set<String>> unsentMessageDeletesOf(
  AppDatabase? database,
  String chatId,
) async => database == null
    ? const <String>{}
    : await database.outboxDao.unsentMessageDeletes(chatId);

/// How many times [readChatWithoutUnsentDeletes] reads a chat while pushes
/// of it keep landing.
const int _kChatReadsWhilePushesLand = 3;

/// Chat [id] read straight from the server by [api], as the account
/// [authSnapshot] holds, without the messages whose delete there has not
/// landed yet, as a pull leaves them out: the server's copy still has them,
/// as answers and among answers' versions. What was pending as the read
/// started counts too: a delete that lands while the read is out leaves no op
/// behind, but the copy may still have the message. A copy that the last read
/// pushes allow still finds overtaken goes without every message whose
/// delete waits or has landed here by then.
Future<Conversation> readChatWithoutUnsentDeletes(
  dynamic ref,
  ApiService api,
  AppDatabase? database,
  String id, {
  required ApiAuthSnapshot authSnapshot,
}) async {
  for (var reads = 1; ; reads++) {
    final pushes = database?.chatsDao.pushVersion(id);
    final conversation = await _readChatWithoutUnsentDeletes(
      ref,
      api,
      database,
      id,
      authSnapshot: authSnapshot,
    );
    // A delete asked for and landed while the copy was read left no op to
    // name its message, only a push landed: the chat is read again.
    if (pushes == database?.chatsDao.pushVersion(id)) return conversation;
    if (reads == _kChatReadsWhilePushesLand) {
      return _withoutMessages(conversation, {
        ...await unsentMessageDeletesOf(database, id),
        ...?database?.chatsDao.landedMessageDeletes(id),
      });
    }
  }
}

Future<Conversation> _readChatWithoutUnsentDeletes(
  dynamic ref,
  ApiService api,
  AppDatabase? database,
  String id, {
  required ApiAuthSnapshot authSnapshot,
}) async {
  final pendingBefore = await unsentMessageDeletesOf(database, id);
  final conversation = await api.getConversation(
    id,
    authSnapshot: authSnapshot,
  );
  final ids = {...pendingBefore, ...await unsentMessageDeletesOf(database, id)};
  // A left-out answer kept beside other answers: Open WebUI makes its
  // parent's last child current once the delete lands, with the turns below
  // that child, which only the server's tree holds.
  final replaced = conversation.messages.any(
    (m) => ids.contains(m.id) && m.versions.any((v) => !ids.contains(v.id)),
  );
  Map<String, dynamic>? response;
  if (replaced) {
    try {
      response = await api.getChatRaw(id, authSnapshot: authSnapshot);
    } catch (error, stackTrace) {
      if (!api.authSnapshotIsCurrent(authSnapshot)) rethrow;
      DebugLogger.error(
        'direct-read-tree-failed',
        scope: 'db/conversation',
        error: error,
        stackTrace: stackTrace,
        data: {'id': id},
      );
    }
    // A delete asked for while that read was out counts, whether it read
    // the chat or not.
    ids.addAll(await unsentMessageDeletesOf(database, id));
  }
  // A chat gone meanwhile, or not read again, leaves the first copy.
  if (response == null) return _withoutMessages(conversation, ids);
  final history = (response['chat'] as Map?)?['history'];
  final messages = history is Map ? history['messages'] : null;
  if (messages is! Map ||
      messages.length <= kLocalConversationWorkerThreshold) {
    return _parseChatWithout({'response': response, 'ids': ids.toList()});
  }
  final workerManager = ref.read(workerManagerProvider) as WorkerManager;
  while (true) {
    final parsed = await workerManager.schedule(_parseChatWithout, {
      'response': response,
      'ids': ids.toList(),
    }, debugLabel: 'db.readChatWithout');
    // A delete asked for while the worker parsed counts too.
    final asked = await unsentMessageDeletesOf(database, id);
    if (ids.containsAll(asked)) return parsed;
    ids.addAll(asked);
  }
}

/// [payload]'s `response`, a chat as the server returns it, parsed without
/// the messages `ids`, as a pull stores it ([ChatRows.withoutMessages]).
Conversation _parseChatWithout(Map<String, dynamic> payload) {
  final response = payload['response'] as Map<String, dynamic>;
  final ids = {...(payload['ids'] as List).cast<String>()};
  final rows = parseChatRowsWorker(response);
  return withQuestionHeldAgain(
    parseFullConversationModel(
      chatResponseWithoutMessages(response, rows, ids),
    ),
    rows,
    ids,
  );
}

/// [conversation] without the messages [ids]. A left-out answer's newest
/// other version shows in its place ([_answerInPlaceOf]), without the turns
/// below it, which only the server's tree holds.
Conversation _withoutMessages(Conversation conversation, Set<String> ids) {
  if (!conversation.messages.any(
    (m) => ids.contains(m.id) || m.versions.any((v) => ids.contains(v.id)),
  )) {
    return conversation;
  }
  // Only a held turn's settle leaves such a delete waiting, so a question
  // whose only answer here was one of those waits again: the copy read it as
  // answered by that empty answer. One with another answer among the left-out
  // answer's versions is answered by it, and doesn't wait.
  final kept = <ChatMessage>[];
  final waiting = <int>{};
  for (final message in conversation.messages) {
    final leftOut = ids.contains(message.id);
    final shown = leftOut
        ? _answerInPlaceOf(message, ids)
        : _withoutVersions(message, ids);
    if (shown == null) {
      if (kept.isNotEmpty && kept.last.role == 'user') {
        waiting.add(kept.length - 1);
      }
      continue;
    }
    if (shown.role == 'assistant' && kept.isNotEmpty) {
      waiting.remove(kept.length - 1);
    }
    kept.add(shown);
    // What followed the left-out answer is its own branch, not the one shown
    // in its place, whose turns only the server's tree holds.
    if (leftOut) break;
  }
  for (final index in waiting) {
    kept[index] = questionHeldAgain(kept[index]);
  }
  return conversation.copyWith(messages: kept);
}

/// The answer shown in place of [leftOut], an answer left out by [ids]: the
/// last of its versions not left out, as Open WebUI makes the last child of
/// its parent current once the delete lands, keeping the others as versions.
/// Null when none is left. A version keeps no status history, no
/// attachments, and of the message's metadata only what is passed here.
ChatMessage? _answerInPlaceOf(ChatMessage leftOut, Set<String> ids) {
  final versions = [
    for (final version in leftOut.versions)
      if (!ids.contains(version.id)) version,
  ];
  if (versions.isEmpty) return null;
  final shown = versions.removeLast();
  final group = _withoutUnfinished(leftOut.metadata, ids);
  final authors = group?[kMessageUnfinishedAnswerAuthorsMetadataKey];
  final author = authors is Map ? authors[shown.id] : null;
  return ChatMessage(
    id: shown.id,
    role: leftOut.role,
    content: shown.content,
    timestamp: shown.timestamp,
    model: shown.model,
    files: shown.files,
    output: shown.output,
    embeds: shown.embeds,
    sources: shown.sources,
    followUps: shown.followUps,
    codeExecutions: shown.codeExecutions,
    usage: shown.usage,
    error: shown.error,
    versions: versions,
    metadata: {
      // What the answers share: their question, and which still run.
      for (final key in const [
        'parentId',
        kMessageUnfinishedAnswersMetadataKey,
        kMessageUnfinishedAnswerAuthorsMetadataKey,
      ])
        key: ?group?[key],
      'modelName': ?shown.modelName,
      kMessageModelIdxMetadataKey: ?shown.modelIdx,
      kMessageMergedMetadataKey: ?shown.merged,
      kMessageAuthorIdMetadataKey: ?(author is String ? author : null),
    },
  );
}

/// [message] without the versions [ids] leaves out.
ChatMessage _withoutVersions(ChatMessage message, Set<String> ids) {
  if (!message.versions.any((version) => ids.contains(version.id))) {
    return message;
  }
  return message.copyWith(
    versions: [
      for (final version in message.versions)
        if (!ids.contains(version.id)) version,
    ],
    metadata: _withoutUnfinished(message.metadata, ids),
  );
}

/// [metadata] without [ids] among the answers it says still run.
Map<String, dynamic>? _withoutUnfinished(
  Map<String, dynamic>? metadata,
  Set<String> ids,
) {
  if (metadata == null) return null;
  final unfinished = metadata[kMessageUnfinishedAnswersMetadataKey];
  final authors = metadata[kMessageUnfinishedAnswerAuthorsMetadataKey];
  final left = [
    if (unfinished is List)
      for (final id in unfinished)
        if (!ids.contains(id)) id,
  ];
  final leftAuthors = {
    if (authors is Map)
      for (final entry in authors.entries)
        if (!ids.contains(entry.key)) entry.key: entry.value,
  };
  return {
    for (final entry in metadata.entries)
      if (entry.key != kMessageUnfinishedAnswersMetadataKey &&
          entry.key != kMessageUnfinishedAnswerAuthorsMetadataKey)
        entry.key: entry.value,
    if (left.isNotEmpty) kMessageUnfinishedAnswersMetadataKey: left,
    if (leftAuthors.isNotEmpty)
      kMessageUnfinishedAnswerAuthorsMetadataKey: leftAuthors,
  };
}

/// DB-first conversation open (CDT-RFC-001 Phase 1, acceptance 1).
///
/// Returns the assembled [Conversation] when the local row exists and its
/// body is synced; `null` otherwise so the caller can fall back to the
/// network path. Accepts any Riverpod ref/container via dynamic dispatch
/// (mirrors `refreshConversationsCache`).
Future<Conversation?> loadLocalConversation(
  dynamic ref,
  String id, {
  OpenWebUiConversationReadSnapshot? ownership,
}) async {
  final effectiveOwnership = ownership ?? captureOpenWebUiConversationRead(ref);
  final db = effectiveOwnership?.database;
  if (effectiveOwnership == null ||
      db == null ||
      !openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) {
    return null;
  }
  try {
    final chat = await db.chatsDao.getChat(id);
    if (!openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) {
      return null;
    }
    if (chat == null || !chat.bodySynced) return null;
    final messages = await db.messagesDao.getForChat(id);
    if (!openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) {
      return null;
    }
    late final Conversation conversation;
    if (messages.length > kLocalConversationWorkerThreshold) {
      final envelope = buildChatResponseEnvelope(chat, messages);
      final workerManager = ref.read(workerManagerProvider);
      conversation = await workerManager.schedule(
        parseFullConversationModelWorker,
        envelope,
        debugLabel: 'db.assembleConversation',
      );
    } else {
      conversation = assembleConversation(chat, messages);
    }
    return openWebUiConversationReadIsCurrent(ref, effectiveOwnership)
        ? conversation
        : null;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'local-load-failed',
      scope: 'db/conversation',
      error: error,
      stackTrace: stackTrace,
      data: {'id': id},
    );
    return null;
  }
}
