import 'dart:convert';

import 'package:collection/collection.dart' show DeepCollectionEquality;
import 'package:drift/drift.dart';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart'
    show OutboxKind, kFolderExpandedKey;
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/models/chat_comparison.dart'
    show
        kCompletionHeldMetadataKey,
        kSettledHereMetadataKey,
        kTakenFromServerMetadataKey,
        kStoppedHereMetadataKey;
import 'package:conduit_core/models/openwebui_chat_prompt.dart'
    show openWebUiChatStopRejectsPrompt;
import 'package:conduit_core/services/answer_copies.dart'
    show storedAnswerHoldsMoreThan, storedAnswerShows;

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/chat_merger.dart'
    show answerAt, withDerivedChildren;

import 'package:conduit_core/sync/clock.dart';

import 'package:conduit_core/sync/id_remapper.dart';

import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/sync_api_client.dart';

const int _sqliteVariableBatchSize = 900;

/// Per-kind outbox push handlers (CDT-RFC-001 §7.2/§7.3/§7.4).
///
/// Every handler acquires the chat (or folder) lock internally so push
/// reconstruct/serialize serializes with pull-merge and stream-echo for the
/// same id (REQ §10). Constructor injection only — no Riverpod here, mirroring
/// [PullSync].
///
/// §3.iii is the governing invariant: createChat and updateChat ALWAYS send
/// the COMPLETE blob reconstructed live from rows via
/// [ChatBlobMapper.rowsToBlob] at push time. Outbox payloads are empty; the
/// blob is never snapshotted at enqueue, so the latest committed rows are what
/// reach the server even after coalescing collapsed several ops into one.
class PushSync {
  PushSync({
    required SyncApiClient client,
    required AppDatabase db,
    required ConversationLocks chatLocks,
    required FolderLocks folderLocks,
    required SyncClock clock,
    required IdRemapper remapper,
  }) : _client = client,
       _db = db,
       _chatLocks = chatLocks,
       _folderLocks = folderLocks,
       _clock = clock,
       _remapper = remapper;

  final SyncApiClient _client;
  final AppDatabase _db;
  final ConversationLocks _chatLocks;
  final FolderLocks _folderLocks;

  /// Held for signature parity + future use. The dirty/serverUpdatedAt rule
  /// uses the server response `updated_at`, never a device clock (§7.2
  /// timestamp rule), so push handlers do not read this yet.
  // ignore: unused_field
  final SyncClock _clock;
  final IdRemapper _remapper;

  // ---- createChat (§7.3) ----

  /// Pushes the new local chat [localId], remaps it to the server id, and
  /// clears dirty for the reconstructed snapshot. Returns the server id.
  ///
  /// The reconstruct+POST run under the [localId] lock, and the SERVER id lock
  /// is acquired before releasing it so a pull cannot fast-forward the server
  /// row between POST and remap. The §7.3 transaction commits before the
  /// drainer marks the op done.
  Future<String?> pushCreateChat(String localId, {String? contentHash}) async {
    // Re-run idempotency (§7.3): the remap repoints this op's chat_id from
    // local:<uuid> to the server id INSIDE the §7.3 transaction, which commits
    // BEFORE the drainer markDone()s the op. A crash (or a pull-side crash-heal)
    // between that commit and markDone leaves the op live with a NON-local id.
    // Re-running must NOT POST a second chat: a non-local id means the server
    // chat already exists, so the create is already satisfied — return it as-is.
    if (!localId.startsWith('local:')) {
      return _chatLocks.runExclusive(localId, () async {
        DebugLogger.log(
          'create-already-satisfied',
          scope: 'sync/push',
          data: {'chatId': localId},
        );
        final chat = await _db.chatsDao.getChat(localId);
        if (chat != null) {
          final messages = await _db.messagesDao.getForChat(localId);
          // The server holds what the create sent: the snapshot its
          // fingerprint names. Rows that match it are those, so their dirt
          // goes. The chat's own dirt goes only if no update is owed
          // besides: the snapshot leaves out the folder, pin and archive,
          // and an update still owed is a change the create did not send. A
          // chat left dirty keeps that change through a pull (one asked for
          // by name refreshes a clean chat) until its update sends it.
          final sent = _snapshotMatches(chat, messages, contentHash);
          final owed = await _db.outboxDao.hasUnconfirmedUpdate(localId);
          await _clearDirty(
            chatId: localId,
            messageIds: sent ? [for (final m in messages) m.id] : const [],
            serverUpdatedAt: chat.serverUpdatedAt ?? chat.updatedAt,
            chatRow: sent && !owed,
          );
        }
        return localId;
      });
    }

    final client = _ownedClient(localId);
    return _chatLocks.runExclusive(localId, () async {
      final chat = await _db.chatsDao.getChat(localId);
      if (chat == null) {
        // Annihilated by a delete before we ran, or already remapped.
        return null;
      }
      final messages = await _db.messagesDao.getForChat(localId);
      final rows = chatRowsFromDb(chat, messages);
      final blob = ChatBlobMapper.rowsToBlob(rows)..['id'] = '';
      if (chat.folderId != null && chat.folderId!.startsWith('local:')) {
        DebugLogger.log(
          'create-defer-local-folder',
          scope: 'sync/push',
          data: {'chatId': localId, 'folderId': chat.folderId},
        );
        throw _OutboxDeferred(
          'createChat deferred until folder remap completes: $localId',
        );
      }
      final resp = await client.createChat(blob, folderId: chat.folderId);
      final serverId = resp['id'];
      if (serverId is! String || serverId.isEmpty) {
        throw StateError('createChat response without a string id');
      }
      final pushed = _CreatePush(
        serverId: serverId,
        serverCreatedAt: _epoch(resp['created_at']) ?? chat.createdAt,
        serverUpdatedAt: _epoch(resp['updated_at']) ?? chat.updatedAt,
        capturedMessageIds: [for (final m in messages) m.id],
      );

      // Keep the local-id lock while acquiring the server-id lock for remap.
      // Pull-side crash-heal claims a pending createChat before trying localId;
      // once this push worker owns the op as inFlight, crash-heal exits before
      // taking localId and cannot form an opposite-order cycle.
      await _chatLocks.runExclusive(pushed.serverId, () async {
        final remapResult = await _remapper.remapChat(
          localId: localId,
          serverId: pushed.serverId,
          serverCreatedAt: pushed.serverCreatedAt,
          serverUpdatedAt: pushed.serverUpdatedAt,
        );
        switch (remapResult) {
          case ChatRemapResult.sourceMissing:
            // The POST is already an authoritative remote success. There is
            // no local row left to adopt or dirty-clear, and retrying cannot
            // make that row reappear; it can only repeat the remote side
            // effect if stale local state is restored. Consume this create as
            // satisfied, matching pull-side crash-heal's orphan handling.
            DebugLogger.warning(
              'create-remap-source-missing-consumed',
              scope: 'sync/push',
              data: {'from': localId, 'createdServerId': pushed.serverId},
            );
            return;
          case ChatRemapResult.rewritten:
          case ChatRemapResult.alreadyCommitted:
            break;
        }
        // Dirty-clear (§7.2): the whole reconstruct+POST happened under one
        // local-id lock span, and remap+clear share this server-id lock span.
        // Clear only the captured message snapshot (now living under serverId)
        // and the chat row.
        _db.chatsDao.notePushLanded(pushed.serverId);
        await _clearDirty(
          chatId: pushed.serverId,
          messageIds: pushed.capturedMessageIds,
          serverUpdatedAt: pushed.serverUpdatedAt,
        );
      });

      return pushed.serverId;
    });
  }

  // ---- updateChat (§3.iii + §7.2) ----

  /// Pushes the FULL reconstructed blob for [chatId] and applies the
  /// dirty/serverUpdatedAt rule. The entire reconstruct -> POST -> clear runs
  /// under one lock span, so no stream-echo can interleave: "rows dirtied
  /// mid-flight stay dirty" holds because only the captured snapshot's dirty
  /// is cleared.
  ///
  /// CONFLICT GATE (§7.2, Phase 2 stub per §11): pushUpdateChat does NOT
  /// re-pull, and it refuses to push envelope-only stubs. Once a full body pull
  /// has set `bodySynced=true`, the current rows are the merged result; this
  /// reconstructs from those rows (which already overlay local dirty edits) and
  /// pushes the complete blob.
  Future<void> pushUpdateChat(String chatId) async {
    final client = _ownedClient(chatId);
    await _chatLocks.runExclusive(chatId, () async {
      final chat = await _db.chatsDao.getChat(chatId);
      if (chat == null || chat.deleted) {
        // A deleteChat op will handle a tombstoned/absent chat.
        return;
      }
      if (!chat.bodySynced) {
        throw _OutboxDeferred(
          'updateChat deferred until body sync completes: $chatId',
        );
      }
      if (chat.folderId != null && chat.folderId!.startsWith('local:')) {
        DebugLogger.log(
          'update-defer-local-folder',
          scope: 'sync/push',
          data: {'chatId': chatId, 'folderId': chat.folderId},
        );
        throw _OutboxDeferred(
          'updateChat deferred until folder remap completes: $chatId',
        );
      }
      final messages = await _db.messagesDao.getForChat(chatId);
      final capturedMessageIds = [for (final m in messages) m.id];
      // A held turn's empty answers never go back: Open WebUI answers a held
      // message only while nothing answers it. One whose delete landed may
      // still be here, its settle unfinished.
      final heldAnswers = {
        ...await _db.outboxDao.unsentMessageDeletes(chatId),
        for (final m in messages)
          if (_isHeldAnswer(m)) m.id,
      };
      final stop = _ChatStop(
        client,
        chatId,
        onTaken: () => _db.chatsDao.notePushLanded(chatId),
      );
      var rows = chatRowsFromDb(chat, messages).withoutMessages(heldAnswers);
      // The answers this device finished itself, stopped or cut off.
      final settled = {
        for (final message in rows.messages)
          if (_isStoppedHere(message) || _isSettledHere(message)) message.id,
      };
      rows = await _withSettledAnswers(client, chatId, rows, settled, stop);

      var resp = await client.updateChat(
        chatId,
        ChatBlobMapper.rowsToBlob(_forServer(rows)),
      );
      if (resp == null) {
        // 404: chat gone server-side. Phase 2 treats this as terminal (log +
        // let the drainer markDone); Phase 3 reconciles.
        DebugLogger.warning(
          'update-404',
          scope: 'sync/push',
          data: {'chatId': chatId},
        );
        return;
      }
      // The server holds these rows now, whatever happens to the reconcile
      // below: a copy read before this is older than them, even should a
      // pin or a move fail and leave the push to run again.
      _db.chatsDao.notePushLanded(chatId);

      // Open WebUI keeps its own copy of an answer it holds as not done,
      // whatever an update sends: one its server stopped in the middle of
      // stays so, often empty, until the chat's stop finishes it. That stop
      // is chat-wide ([_ChatStop]); until it may be asked the push stays
      // owed.
      var kept = _answersKeptUnfinished(rows, resp);
      final recovered = {...settled, ...kept};
      if (kept.isNotEmpty && !stop.asked) {
        final before = _serverMessages(chatId, resp['chat']);
        final outcome = await stop.ask(resp);
        if (outcome != _StopOutcome.taken) {
          throw _AnswersOwed(chatId, outcome.name);
        }
        rows = await _afterStop(
          client,
          chatId,
          rows,
          stop,
          before: before,
          ours: {...settled, ...kept},
        );
        final again = await client.updateChat(
          chatId,
          ChatBlobMapper.rowsToBlob(_forServer(rows)),
        );
        if (again == null) {
          DebugLogger.warning(
            'update-404',
            scope: 'sync/push',
            data: {'chatId': chatId},
          );
          return;
        }
        _db.chatsDao.notePushLanded(chatId);
        resp = again;
        kept = _answersKeptUnfinished(rows, resp);
      }
      if (stop.owed) {
        throw _AnswersOwed(chatId, 'a Stop waits for the chat');
      }
      if (kept.isNotEmpty) {
        // The stop was taken and finished every answer of the account's:
        // these are another person's, which the server never takes an update
        // of.
        DebugLogger.warning(
          'update-kept-unfinished',
          scope: 'sync/push',
          data: {'chatId': chatId, 'count': kept.length},
        );
      }
      final serverUpdatedAt = _epoch(resp['updated_at']) ?? chat.updatedAt;

      try {
        // folder-move delta runs BEFORE the pin/archive reconcile: the server's
        // update_chat_folder_id forces pinned=false on every move (vendored
        // models/chats.py), so a pin reconcile must run AFTER the move to re-
        // assert the desired pinned state — otherwise a pinned chat that is
        // moved in the same coalesced update silently loses its pin.
        //
        // update_chat IGNORES folder_id, so a changed folder must go through
        // the dedicated /folder endpoint.
        //
        // FOLDER-BEFORE-CHAT ORDERING (§7.6, non-negotiable 6): never send a
        // `local:`-prefixed folder id — the folder's createChat hasn't been
        // drained+remapped yet, so the server would 400/404 the move. The
        // pre-flight guard above throws before updateChat so the drainer backs
        // off this same op until IdRemapper rewrites chats.folderId to the real
        // server id.
        final serverFolderId = resp['folder_id'] is String
            ? resp['folder_id'] as String
            : null;
        final movedFolder = chat.folderId != serverFolderId;
        if (movedFolder) {
          await client.moveChatToFolder(chatId, chat.folderId);
        }

        // pin/archive toggle-delta (B1): the server only exposes stateless
        // toggle endpoints for these axes, so the sync path always drives them
        // through desired-state reconcilers that probe before toggling and
        // confirm after. A retry after a post-toggle timeout re-probes and
        // therefore cannot double-flip. After a folder move the server pin is
        // known to be false, so treat it as such (the pre-move ChatResponse
        // copy is stale).
        final serverPinned = movedFolder ? false : resp['pinned'] == true;
        final serverArchived = resp['archived'] == true;
        final needsPinCheck = chat.pinned != serverPinned;
        final needsArchiveCheck = chat.archived != serverArchived;

        if (needsPinCheck && !needsArchiveCheck) {
          // Pin lives in a join table; confirm against /pinned (authoritative)
          // rather than the ChatResponse copy. This path intentionally skips
          // getChatRaw; no archive liveness check is needed for a pin-only
          // delta.
          await _setChatPinned(client, chatId, desired: chat.pinned);
        } else if (needsArchiveCheck) {
          // A liveness fetch is needed only for archive reconciliation: the
          // archive flag rides the ChatResponse, while pin has a dedicated
          // authoritative endpoint below.
          final liveRaw = await client.getChatRaw(chatId);
          if (liveRaw != null) {
            if (needsPinCheck) {
              await _setChatPinned(client, chatId, desired: chat.pinned);
            }
            await _setChatArchived(
              client,
              chatId,
              desired: chat.archived,
              initialRaw: liveRaw,
            );
          }
        }
      } finally {
        // Noted again however this ends: the folder move, pin and archive
        // above write too, and one may land before a later request fails, so
        // a copy or list read between them and the update is older than the
        // chat as pushed.
        _db.chatsDao.notePushLanded(chatId);
      }

      // Store serverUpdatedAt + clear dirty ONLY for the captured snapshot:
      // any row dirtied after the capture (none possible inside this single
      // lock span, but defensively) stays dirty.
      final sent = [
        for (final id in capturedMessageIds)
          if (!stop.unsent.contains(id) && !kept.contains(id)) id,
      ];
      final taken = {
        for (final message in rows.messages)
          if (_isTakenFromServer(message)) message.id,
      };
      // The push moved the server's date. It is this device's own save only
      // when the server holds nothing else: Open WebUI keeps the messages an
      // update leaves out (`merge_history`), and its own copy of an answer
      // it holds as not done, which a running task may have written on.
      final pushed = {for (final message in rows.messages) message.id: message};
      final landed = resp['chat'] is Map
          ? _serverMessages(chatId, resp['chat'])
          : null;
      final ownSave =
          landed != null &&
          landed.entries.every((stored) {
            final sent = pushed[stored.key];
            return sent != null && !_showsOther(stored.value, sent);
          });
      // At once, so the marks go only with the landing that settles them.
      await _db.transaction(() async {
        await _clearSettledMarks(chatId, sent.where(recovered.contains));
        await _clearMarks(
          chatId,
          sent.where(taken.contains),
          kTakenFromServerMetadataKey,
        );
        await _clearDirty(
          chatId: chatId,
          messageIds: sent,
          serverUpdatedAt: serverUpdatedAt,
        );
        // Text it took from the server's copy (marked, so a failed attempt's
        // take still counts) is news while the chat is still held unread
        // from when that text was stored: no read here since.
        final unseen =
            taken.isNotEmpty &&
            ((await _db.chatsDao.getChat(chatId))?.heldUnread ?? false);
        if (unseen) {
          await _db.chatsDao.dateThroughPushOfServerText(
            chatId,
            serverUpdatedAt,
          );
        } else if (ownSave) {
          await _db.chatsDao.keepReadThroughOwnPush(chatId, serverUpdatedAt);
        } else if (landed != null) {
          // The server's copy holds what this device never sent or showed:
          // news, whatever the dates say once a pull stores it.
          await _db.chatsDao.holdUnread(chatId);
        }
      });
    });
  }

  Future<void> _setChatPinned(
    SyncApiClient client,
    String chatId, {
    required bool desired,
  }) async {
    var livePinned = await client.getChatPinned(chatId);
    if (livePinned != desired) {
      await client.togglePin(chatId);
      livePinned = await client.getChatPinned(chatId);
    }
    if (livePinned != desired) {
      DebugLogger.warning(
        'pin-confirm-mismatch',
        scope: 'sync/push',
        data: {'chatId': chatId, 'desired': desired, 'actual': livePinned},
      );
      await _storeChatPinMirror(chatId, livePinned);
    }
  }

  Future<void> _setChatArchived(
    SyncApiClient client,
    String chatId, {
    required bool desired,
    Map<String, dynamic>? initialRaw,
  }) async {
    var liveRaw = initialRaw ?? await client.getChatRaw(chatId);
    if (liveRaw == null) {
      DebugLogger.warning(
        'archive-confirm-404',
        scope: 'sync/push',
        data: {'chatId': chatId},
      );
      return;
    }

    var liveArchived = liveRaw['archived'] == true;
    if (liveArchived != desired) {
      await client.toggleArchive(chatId);
      liveRaw = await client.getChatRaw(chatId);
      if (liveRaw == null) {
        DebugLogger.warning(
          'archive-post-toggle-404',
          scope: 'sync/push',
          data: {'chatId': chatId},
        );
        return;
      }
      liveArchived = liveRaw['archived'] == true;
    }

    if (liveArchived != desired) {
      DebugLogger.warning(
        'archive-confirm-mismatch',
        scope: 'sync/push',
        data: {'chatId': chatId, 'desired': desired, 'actual': liveArchived},
      );
      await _storeChatArchiveMirror(chatId, liveArchived);
    }
  }

  /// The client one chat push sends with, taken as it starts: bound to the
  /// session that owns this account's database then
  /// ([SyncApiClient.ownedBy]). While none does, the push waits, unsent.
  SyncApiClient _ownedClient(String chatId) {
    final client = _client.ownedBy(_db);
    if (client == null) {
      throw _OutboxDeferred('no session owns the account of chat $chatId');
    }
    return client;
  }

  /// [rows] with each answer this device finished itself ([settled]: stopped
  /// or cut off, [kStoppedHereMetadataKey], [kSettledHereMetadataKey]) as it
  /// is to go to the server, against the server's copy of the chat read now
  /// with the [client] this push sends with.
  ///
  /// The push replaces the chat's whole history, and the server holds a
  /// finished answer as the client sends it. So an answer settled here goes
  /// as the fuller of the two copies ([_finishedOver]), never one that holds
  /// less than the server's. One the server does not have yet goes as it is.
  ///
  /// One stopped here whose Stop the server never took: while the server
  /// holds it not done, that stop is asked again ([stop]), and the chat is
  /// read again once it is taken ([_afterStop]). Until then the answer goes
  /// as the server holds it, its finish kept on this device alone and the
  /// push left owed; one the server does not have stays out.
  ///
  /// Every other answer goes as the server holds it when the server holds it
  /// finished and this device does not ([_caughtUp]).
  Future<ChatRows> _withSettledAnswers(
    SyncApiClient client,
    String chatId,
    ChatRows rows,
    Set<String> settled,
    _ChatStop stop,
  ) async {
    if (settled.isEmpty) return rows;
    final raw = await client.getChatRaw(chatId);
    final server = _serverMessages(chatId, raw?['chat']);
    // One the server holds not finished, `done: false` or a copy saved
    // while it streamed: its Stop is still owed.
    final stopOwed = rows.messages.any((message) {
      final copy = server[message.id];
      return _isStoppedHere(message) &&
          copy != null &&
          copy.payload['done'] != true;
    });
    if (stopOwed) {
      if (await stop.ask(raw) == _StopOutcome.taken) {
        return _afterStop(
          client,
          chatId,
          rows,
          stop,
          before: server,
          ours: settled,
        );
      }
      stop.owed = true;
    }
    final absent = <String>{};
    final messages = <MessageRowData>[];
    for (final message in rows.messages) {
      final copy = server[message.id];
      if (!settled.contains(message.id)) {
        messages.add(await _caughtUp(message, copy, rows.messages));
      } else if (copy == null) {
        if (_isStoppedHere(message)) {
          absent.add(message.id);
          stop.unsent.add(message.id);
        }
        messages.add(message);
      } else if (_isStoppedHere(message) && copy.payload['done'] != true) {
        stop.unsent.add(message.id);
        messages.add(
          withDerivedChildren(answerAt(copy, message), rows.messages),
        );
      } else {
        messages.add(await _settledOver(message, copy, rows.messages));
      }
    }
    return _withRows(rows, messages).withoutMessages(absent);
  }

  /// [rows] for the update that follows a stop the server took, built on the
  /// chat as the server holds it once that stop is done, read again now:
  /// [before], the copy the stop was asked over, may have moved since.
  ///
  /// The answers this device finished ([ours]) go as the fuller copy
  /// ([_finishedOver]). Every other answer goes as the server holds it now
  /// when the server holds it finished and this device does not
  /// ([_caughtUp]), whether this stop finished it or it was finished before.
  Future<ChatRows> _afterStop(
    SyncApiClient client,
    String chatId,
    ChatRows rows,
    _ChatStop stop, {
    required Map<String, MessageRowData> before,
    required Set<String> ours,
  }) async {
    final after = _serverMessages(
      chatId,
      (await client.getChatRaw(chatId))?['chat'],
    );
    final absent = <String>{};
    final messages = <MessageRowData>[];
    for (final message in rows.messages) {
      final copy = after[message.id];
      if (copy == null) {
        if (_isStoppedHere(message)) {
          absent.add(message.id);
          stop.unsent.add(message.id);
        }
        messages.add(message);
      } else if (ours.contains(message.id)) {
        final held = before[message.id];
        // Finished by this stop alone, with the text it held: still the
        // unfinished copy a settle finishes, and not another device's answer.
        final finishedByStop =
            held != null &&
            held.payload['done'] == false &&
            held.content == copy.content &&
            _deepEquality.equals(
              held.payload['output'],
              copy.payload['output'],
            );
        messages.add(
          await _settledOver(
            message,
            copy,
            rows.messages,
            serverFinished: !finishedByStop,
          ),
        );
      } else {
        messages.add(await _caughtUp(message, copy, rows.messages));
      }
    }
    return _withRows(rows, messages).withoutMessages(absent);
  }

  /// [local], an answer this device finished, as it goes over [server]
  /// ([_finishedOver]), where it sits in [all]; stored here when that is not
  /// the row it was, so a later push sends it again until one lands.
  Future<MessageRowData> _settledOver(
    MessageRowData local,
    MessageRowData server,
    List<MessageRowData> all, {
    bool serverFinished = true,
  }) async {
    var finished = withDerivedChildren(
      _finishedOver(local, server, serverFinished: serverFinished),
      all,
    );
    final news = _showsOther(finished, local);
    if (news || _isTakenFromServer(local)) {
      finished = _marked(finished, kTakenFromServerMetadataKey);
    }
    if (_differs(finished, local)) await _storeFinished(finished, news: news);
    return finished;
  }

  /// [rows] with [messages] in place of its own.
  static ChatRows _withRows(ChatRows rows, List<MessageRowData> messages) =>
      ChatRows(
        chat: rows.chat,
        messages: messages,
        unmappableMessages: rows.unmappableMessages,
        unmappableMessageOrder: rows.unmappableMessageOrder,
        blobHadTitle: rows.blobHadTitle,
        blobTitleValue: rows.blobTitleValue,
        blobHadHistory: rows.blobHadHistory,
        historyHadMessages: rows.historyHadMessages,
        historyHadCurrentId: rows.historyHadCurrentId,
        historyExtra: rows.historyExtra,
      );

  /// [rows] as the server is sent them: without the marks this device keeps
  /// on the answers it settled, or took from the server's copy.
  static ChatRows _forServer(ChatRows rows) => _withRows(rows, [
    for (final message in rows.messages)
      _isSettledHere(message) || _isTakenFromServer(message)
          ? _withoutMark(
              _withoutMark(message, kSettledHereMetadataKey),
              kTakenFromServerMetadataKey,
            )
          : message,
  ]);

  static bool _isStoppedHere(MessageRowData message) =>
      _metadataOf(message.payload)?[kStoppedHereMetadataKey] == true;

  static bool _isSettledHere(MessageRowData message) =>
      _metadataOf(message.payload)?[kSettledHereMetadataKey] == true;

  static bool _isTakenFromServer(MessageRowData message) =>
      _metadataOf(message.payload)?[kTakenFromServerMetadataKey] == true;

  static Map<dynamic, dynamic>? _metadataOf(Map<String, dynamic> payload) {
    final metadata = payload['metadata'];
    return metadata is Map ? metadata : null;
  }

  /// [payload] without the metadata [key], and without metadata left empty.
  static Map<String, dynamic> _payloadWithout(
    Map<String, dynamic> payload,
    String key,
  ) {
    final metadata = _metadataOf(payload);
    if (metadata == null || !metadata.containsKey(key)) return payload;
    final rest = <String, dynamic>{
      for (final entry in metadata.entries)
        if (entry.key != key) '${entry.key}': entry.value,
    };
    return <String, dynamic>{...payload}
      ..remove('metadata')
      ..addAll({if (rest.isNotEmpty) 'metadata': rest});
  }

  static MessageRowData _settledMarked(MessageRowData message) =>
      _marked(message, kSettledHereMetadataKey);

  /// [message] with the metadata mark [key].
  static MessageRowData _marked(MessageRowData message, String key) {
    final metadata = _metadataOf(message.payload);
    return _rowWith(
      message,
      content: message.content,
      payload: <String, dynamic>{
        ...message.payload,
        'metadata': <String, dynamic>{
          if (metadata != null)
            for (final entry in metadata.entries) '${entry.key}': entry.value,
          key: true,
        },
      },
    );
  }

  static MessageRowData _withoutMark(MessageRowData message, String key) =>
      _rowWith(
        message,
        content: message.content,
        payload: _payloadWithout(message.payload, key),
      );

  static MessageRowData _rowWith(
    MessageRowData row, {
    required String content,
    required Map<String, dynamic> payload,
  }) => MessageRowData(
    id: row.id,
    chatId: row.chatId,
    parentId: row.parentId,
    role: row.role,
    content: content,
    model: row.model,
    createdAt: row.createdAt,
    orderIndex: row.orderIndex,
    payload: payload,
  );

  /// [message], an answer this device did not settle, as it is to go over
  /// [copy], the server's: as the server holds it, stored so, when the server
  /// holds it finished and this device does not. This device's copy is then
  /// older, perhaps an empty placeholder, which the server would take over its
  /// own: a stop, this push's or an earlier one whose read after it was lost,
  /// or another device may have finished it there.
  Future<MessageRowData> _caughtUp(
    MessageRowData message,
    MessageRowData? copy,
    List<MessageRowData> rows,
  ) async {
    if (copy == null ||
        message.role != 'assistant' ||
        message.payload['done'] == true ||
        copy.payload['done'] != true) {
      return message;
    }
    var taken = withDerivedChildren(answerAt(copy, message), rows);
    final news = _showsOther(taken, message);
    if (news || _isTakenFromServer(message)) {
      taken = _marked(taken, kTakenFromServerMetadataKey);
    }
    if (_differs(taken, message)) {
      await _db.transaction(() async {
        await _db.messagesDao.upsertLocalEcho(taken);
        if (news) await _db.chatsDao.holdUnread(taken.chatId);
      });
    }
    return taken;
  }

  static const DeepCollectionEquality _deepEquality = DeepCollectionEquality();

  /// Whether answer [a] reads otherwise than [b]: its text, reasoning or
  /// tool calls.
  static bool _showsOther(MessageRowData a, MessageRowData b) =>
      storedAnswerShows(a.content, _outputOf(a)) !=
      storedAnswerShows(b.content, _outputOf(b));

  static bool _differs(MessageRowData a, MessageRowData b) =>
      a.content != b.content || !_deepEquality.equals(a.payload, b.payload);

  /// The answers [rows] sent finished that [response], the chat as the
  /// server stored it, still holds as not done.
  static Set<String> _answersKeptUnfinished(
    ChatRows rows,
    Map<String, dynamic> response,
  ) {
    final stored = _serverMessages(rows.chat.id, response['chat']);
    return {
      for (final message in rows.messages)
        if (message.role == 'assistant' &&
            message.payload['done'] == true &&
            stored[message.id]?.payload['done'] == false)
          message.id,
    };
  }

  /// The messages of [chat], a chat's blob as the server sent it, by id.
  static Map<String, MessageRowData> _serverMessages(
    String chatId,
    Object? chat,
  ) => <String, MessageRowData>{
    if (chat is Map)
      for (final message in ChatBlobMapper.blobToRows(
        chatId: chatId,
        blob: Map<String, dynamic>.from(chat),
        title: '',
        createdAt: 0,
        updatedAt: 0,
      ).messages)
        message.id: message,
  };

  /// [local], an answer this device finished, as it is to go over [server],
  /// the server's copy of it: never holding less than that copy.
  ///
  /// - The server's copy holds more and is finished: it is the answer, as
  ///   another device finished it or the server did.
  /// - It holds more and is not done, or was finished only by this push's
  ///   stop (![serverFinished]): [local] finished with its text and output
  ///   (as a cut-off answer is settled), its own error kept.
  /// - Otherwise [local], finished, over the fields of the server's copy it
  ///   does not model; its own output or none, as its text is read from one.
  ///
  /// It is no longer marked stopped here, and is marked settled here
  /// whichever copy it is, so that until its update lands every push weighs
  /// it against the server's copy again, which may hold more by then.
  static MessageRowData _finishedOver(
    MessageRowData local,
    MessageRowData server, {
    bool serverFinished = true,
  }) {
    if (storedAnswerHoldsMoreThan(
      server.content,
      _outputOf(server),
      local.content,
      _outputOf(local),
    )) {
      if (serverFinished && server.payload['done'] == true) {
        return _settledMarked(answerAt(server, local));
      }
      final payload = <String, dynamic>{
        ..._payloadWithout(local.payload, kStoppedHereMetadataKey),
        'done': true,
        'content': server.content,
      }..remove('output');
      final output = server.payload['output'];
      if (output is List) payload['output'] = output;
      return _settledMarked(
        _rowWith(local, content: server.content, payload: payload),
      );
    }
    final payload = <String, dynamic>{
      ...server.payload,
      ..._payloadWithout(local.payload, kStoppedHereMetadataKey),
      'done': true,
    };
    if (!local.payload.containsKey('output')) payload.remove('output');
    return _settledMarked(
      _rowWith(local, content: local.content, payload: payload),
    );
  }

  /// Stores [answer] as an edit still to push: a pull keeps it over the
  /// server's copy, which the stop finished with the text it had, until the
  /// push lands.
  /// Stores [answer] finished here; with [news], text taken from the
  /// server's copy that was never shown here, its chat is held unread with
  /// it, until it is read here.
  Future<void> _storeFinished(MessageRowData answer, {required bool news}) =>
      _db.transaction(() async {
        await _db.messagesDao.upsertLocalEcho(answer, keepDirty: true);
        await (_db.update(_db.messages)..where(
              (t) => t.chatId.equals(answer.chatId) & t.id.equals(answer.id),
            ))
            .write(const MessagesCompanion(dirty: Value(true)));
        if (news) await _db.chatsDao.holdUnread(answer.chatId);
      });

  /// Drops the mark of each answer [ids] of [chatId] settled here, sent and
  /// landed now: it holds what the server holds, and a later edit of it goes
  /// as made.
  Future<void> _clearSettledMarks(String chatId, Iterable<String> ids) =>
      _clearMarks(chatId, ids, kSettledHereMetadataKey);

  /// Drops the metadata mark [key] from the messages [ids] of chat [chatId]
  /// that carry it, in one transaction.
  Future<void> _clearMarks(String chatId, Iterable<String> ids, String key) =>
      _db.transaction(() async {
        for (final id in ids) {
          final row = await _db.messagesDao.getMessage(chatId, id);
          final payload = row == null ? null : jsonDecode(row.payload);
          if (payload is! Map<String, dynamic> ||
              _metadataOf(payload)?[key] != true) {
            continue;
          }
          await (_db.update(
            _db.messages,
          )..where((t) => t.chatId.equals(chatId) & t.id.equals(id))).write(
            MessagesCompanion(
              payload: Value(jsonEncode(_payloadWithout(payload, key))),
            ),
          );
        }
      });

  static bool _isHeldAnswer(MessageRow message) {
    if (message.role != 'assistant') return false;
    try {
      final payload = jsonDecode(message.payload);
      final metadata = payload is Map ? payload['metadata'] : null;
      return metadata is Map && metadata[kCompletionHeldMetadataKey] == true;
    } on FormatException {
      return false;
    }
  }

  // ---- deleteChat (§7.5) ----

  /// Confirms the server delete (or 404 already-gone), then purges the local
  /// rows. On a terminal 401/403 the [SyncTerminalException] propagates so the
  /// drainer parks the op; the rows stay tombstoned (NOT purged).
  Future<void> pushDeleteChat(String chatId) async {
    final client = _ownedClient(chatId);
    await _chatLocks.runExclusive(chatId, () async {
      // 404 -> false (already gone) -> still proceed to purge. 401/403 throws
      // and aborts the purge.
      await client.deleteChat(chatId);
      await _db.chatsDao.purgeReconciledChat(chatId);
    });
  }

  /// Deletes [messageIds] from the server's copy of [chatId], all as one
  /// session. A message (or chat) already gone counts as deleted
  /// ([SyncApiClient.deleteChatMessages]).
  /// The local rows are not touched: whoever recorded the op already removed
  /// them, and a pull keeps them out while the op waits
  /// ([OutboxDao.unsentMessageDeletes]). Once the deletes land, a copy read
  /// before them is a stale read, as one read before a push is.
  Future<void> pushDeleteMessages(
    String chatId,
    List<String> messageIds,
  ) async {
    await _ownedClient(chatId).deleteChatMessages(chatId, messageIds);
    _db.chatsDao.noteMessageDeletesLanded(chatId, messageIds);
  }

  /// Sends again each `deleteMessages` op parked on a refusal whose chat this
  /// session still owns ([ChatOwnershipProbe]): Open WebUI refuses a delete
  /// whose write failed as it refuses one the session may not make. One whose
  /// chat it doesn't own, or can't say it owns, stays parked. Returns whether
  /// a chat's check could not tell, so a later pass may ask again.
  Future<bool> rearmOwnedMessageDeletes({required int nowEpochSeconds}) async {
    final probe = switch (_client) {
      final ChatOwnershipProbe probe => probe,
      _ => null,
    };
    if (probe == null) return false;
    final ownership = <String, ChatOwnership>{};
    var undecided = false;
    for (final op in await _db.outboxDao.parkedOfKind(
      OutboxKind.deleteMessages,
    )) {
      final chatId = op.chatId;
      if (chatId == null) continue;
      switch (ownership[chatId] ??= await probe.chatOwnership(chatId)) {
        case ChatOwnership.owns:
          await _db.outboxDao.requeueParked(
            op.seq,
            nowEpochSeconds: nowEpochSeconds,
          );
        case ChatOwnership.unknown:
          undecided = true;
        case ChatOwnership.notOwner:
          break;
      }
    }
    return undecided;
  }

  // ---- folderUpsert / folderDelete (§7.6) ----

  /// Pushes a folder create-or-update. A `local:` folder with
  /// `createIfAbsent` is created server-side then remapped; otherwise the name,
  /// parent and expanded deltas are pushed. Clears `folders.dirty` on success.
  Future<void> pushFolderUpsert(Map<String, dynamic> payload) async {
    final folderId = payload['folderId'];
    if (folderId is! String || folderId.isEmpty) {
      DebugLogger.warning('folder-upsert-no-id', scope: 'sync/push');
      return;
    }
    await _folderLocks.runExclusive(folderId, () async {
      final createIfAbsent = payload['createIfAbsent'] == true;
      final name = payload['name'] is String ? payload['name'] as String : null;
      final parentId = payload['parentId'] is String
          ? payload['parentId'] as String
          : null;
      final data = _asMap(payload['data']);
      final meta = _asMap(payload['meta']);

      if (createIfAbsent && folderId.startsWith('local:')) {
        final resolvedName = name;
        if (resolvedName == null || resolvedName.trim().isEmpty) {
          throw SyncTerminalException(
            statusCode: 400,
            message: 'malformed folderUpsert op: missing folder name',
          );
        }
        if (parentId != null && parentId.startsWith('local:')) {
          DebugLogger.log(
            'folder-create-defer-local-parent',
            scope: 'sync/push',
            data: {'folderId': folderId, 'parentId': parentId},
          );
          throw _OutboxDeferred(
            'createFolder deferred until parent remap completes: $folderId',
          );
        }
        final resp = await _client.createFolder(
          name: resolvedName,
          parentId: parentId,
          data: data,
          meta: meta,
        );
        final serverId = resp['id'];
        if (serverId is! String || serverId.isEmpty) {
          throw StateError('createFolder response without a string id');
        }
        final serverUpdatedAt = _epoch(resp['updated_at']) ?? 0;
        // Remap under the SERVER folder lock (we already hold the local one),
        // committing the §7.3 transaction before the op is marked done.
        await _folderLocks.runExclusive(serverId, () async {
          await _remapper.remapFolder(
            localId: folderId,
            serverId: serverId,
            serverUpdatedAt: serverUpdatedAt,
          );
          await _clearFolderDirty(serverId);
        });
        return;
      }

      final hasFolderPatch = name != null || data != null || meta != null;
      if (hasFolderPatch) {
        final folderResp = await _client.updateFolder(
          folderId,
          name: name,
          data: data,
          meta: meta,
        );
        if (folderResp == null) {
          DebugLogger.warning(
            'folder-update-404',
            scope: 'sync/push',
            data: {'folderId': folderId},
          );
          await _db.foldersDao.purgeReconciledFolder(folderId);
          return;
        }
      }
      if (parentId != null || payload.containsKey('parentId')) {
        if (parentId != null && parentId.startsWith('local:')) {
          DebugLogger.log(
            'folder-parent-defer-local-parent',
            scope: 'sync/push',
            data: {'folderId': folderId, 'parentId': parentId},
          );
          throw _OutboxDeferred(
            'updateFolderParent deferred until parent remap completes: '
            '$folderId',
          );
        }
        final parentUpdated = await _client.updateFolderParent(
          folderId,
          parentId,
        );
        if (!parentUpdated) {
          DebugLogger.warning(
            'folder-update-404',
            scope: 'sync/push',
            data: {'folderId': folderId},
          );
          await _db.foldersDao.purgeReconciledFolder(folderId);
          return;
        }
      }
      final isExpanded = payload[kFolderExpandedKey];
      if (isExpanded is bool) {
        final expandedUpdated = await _client.updateFolderExpanded(
          folderId,
          isExpanded,
        );
        if (!expandedUpdated) {
          DebugLogger.warning(
            'folder-update-404',
            scope: 'sync/push',
            data: {'folderId': folderId},
          );
          await _db.foldersDao.purgeReconciledFolder(folderId);
          return;
        }
      }
      await _clearFolderDirty(folderId);
    });
  }

  /// Deletes the folder server-side with `delete_contents=false` (BINDING: the
  /// server default `true` would also delete contained chats), then purges the
  /// local folder row. A 404 already-gone response is still a successful delete.
  Future<void> pushFolderDelete(String folderId) async {
    await _folderLocks.runExclusive(folderId, () async {
      await _client.deleteFolder(folderId, deleteContents: false);
      await _db.foldersDao.purgeReconciledFolder(folderId);
    });
  }

  // ---- helpers ----

  /// Caller holds the chat lock. Stores [serverUpdatedAt] + clears dirty for
  /// the chat row (unless [chatRow] is false) and exactly [messageIds] in ONE
  /// transaction (REQ §7.2/§10).
  ///
  /// A push that reached the server notes it first
  /// ([ChatsDao.notePushLanded]): a copy read before then is older than the
  /// base stored here, even one stamped the same second. A create found
  /// satisfied already sent nothing, so a copy read before it is current.
  Future<void> _clearDirty({
    required String chatId,
    required List<String> messageIds,
    required int serverUpdatedAt,
    bool chatRow = true,
  }) {
    return _db.transaction(() async {
      await _db.customUpdate(
        chatRow
            ? 'UPDATE chats SET server_updated_at = ?, dirty = 0 WHERE id = ?'
            : 'UPDATE chats SET server_updated_at = ? WHERE id = ?',
        variables: [
          Variable.withInt(serverUpdatedAt),
          Variable.withString(chatId),
        ],
        updates: {_db.chats},
        updateKind: UpdateKind.update,
      );
      if (messageIds.isEmpty) return;
      for (
        var start = 0;
        start < messageIds.length;
        start += _sqliteVariableBatchSize
      ) {
        final end = start + _sqliteVariableBatchSize;
        final batch = messageIds.sublist(
          start,
          end > messageIds.length ? messageIds.length : end,
        );
        await (_db.update(_db.messages)
              ..where((t) => t.chatId.equals(chatId) & t.id.isIn(batch)))
            .write(const MessagesCompanion(dirty: Value(false)));
      }
    });
  }

  Future<void> _clearFolderDirty(String folderId) {
    return (_db.update(_db.folders)..where((t) => t.id.equals(folderId))).write(
      const FoldersCompanion(dirty: Value(false)),
    );
  }

  Future<void> _storeChatArchiveMirror(String chatId, bool archived) {
    return (_db.update(_db.chats)..where((t) => t.id.equals(chatId))).write(
      ChatsCompanion(archived: Value(archived)),
    );
  }

  Future<void> _storeChatPinMirror(String chatId, bool pinned) {
    return (_db.update(_db.chats)..where((t) => t.id.equals(chatId))).write(
      ChatsCompanion(pinned: Value(pinned)),
    );
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  /// Whether [chat] and [messages] are still the snapshot [contentHash]
  /// fingerprints: the blob a create sent. Unknown without a fingerprint.
  static bool _snapshotMatches(
    ChatRow chat,
    List<MessageRow> messages,
    String? contentHash,
  ) {
    if (contentHash == null || contentHash.isEmpty) return false;
    final currentHash = createChatContentHash(chatRowsFromDb(chat, messages));
    if (currentHash != contentHash) {
      DebugLogger.log(
        'create-already-satisfied-hash-changed',
        scope: 'sync/push',
        data: {'chatId': chat.id},
      );
      return false;
    }
    return true;
  }

  static int? _epoch(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

enum _StopOutcome {
  /// The server took the chat's stop.
  taken,

  /// The account runs a task in the chat, so it was not asked.
  taskRuns,

  /// An answer in the chat waits for a tool's approval, which the stop
  /// would reject, so it was not asked.
  promptWaits,
}

/// The chat's stop for one push, asked at most once. It is chat-wide, so it
/// is asked only while the account runs no task in the chat (another
/// device's answer would stop with it) and no answer there waits for a
/// tool's approval (Open WebUI's stop rejects the call). [onTaken] runs as
/// soon as the server has taken it: the answers it finished changed there.
final class _ChatStop {
  _ChatStop(this._client, this._chatId, {required this.onTaken});

  final SyncApiClient _client;
  final String _chatId;
  final void Function() onTaken;
  Future<_StopOutcome>? _outcome;

  /// Set when an answer stopped here still waits for this stop as the push
  /// ends.
  bool owed = false;

  /// The answers stopped here that the push carries as the server has them:
  /// not sent, so their rows stay as dirty as they were.
  final Set<String> unsent = <String>{};

  bool get asked => _outcome != null;

  /// Asks the stop of the chat as the server holds it, [chat] (a
  /// `ChatResponse`), unless something above says not to. A task list the
  /// server does not answer as one says nothing either way: the push stays
  /// owed. Any other failed request throws as it is, and the push is tried
  /// again.
  Future<_StopOutcome> ask(Map<String, dynamic>? chat) =>
      _outcome ??= () async {
        // Another person's waiting answer is left as it is, so it holds
        // nothing back. Who the session is is asked only when some answer
        // waits.
        if (openWebUiChatStopRejectsPrompt(chat) &&
            openWebUiChatStopRejectsPrompt(
              chat,
              userId: await _client.sessionUserId(),
            )) {
          return _StopOutcome.promptWaits;
        }
        final List<String> running;
        try {
          running = await _client.getChatTaskIds(_chatId);
        } on FormatException catch (error) {
          throw _AnswersOwed(_chatId, 'no task list: ${error.message}');
        }
        if (running.isNotEmpty) return _StopOutcome.taskRuns;
        await _client.stopChatTasks(_chatId);
        onTaken();
        return _StopOutcome.taken;
      }();
}

/// A push whose answers the server still holds unfinished until the chat's
/// stop may be asked: not a failure, so it spends no attempt and goes again
/// at the next drain from a second on, such as the one a change of the chat
/// prompts when what held it up ends.
class _AnswersOwed implements OutboxDeferralException {
  const _AnswersOwed(this.chatId, this.reason);

  final String chatId;
  final String reason;

  @override
  String toString() => 'unfinished answers owed to chat $chatId: $reason';
}

class _OutboxDeferred implements OutboxDeferralException {
  const _OutboxDeferred(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of the createChat POST carried out of the local-id lock span.
class _CreatePush {
  const _CreatePush({
    required this.serverId,
    required this.serverCreatedAt,
    required this.serverUpdatedAt,
    required this.capturedMessageIds,
  });

  final String serverId;
  final int serverCreatedAt;
  final int serverUpdatedAt;
  final List<String> capturedMessageIds;
}

List<Map<String, dynamic>>? _outputOf(MessageRowData message) {
  final output = message.payload['output'];
  return output is List
      ? <Map<String, dynamic>>[
          for (final item in output)
            if (item is Map) Map<String, dynamic>.from(item),
        ]
      : null;
}
