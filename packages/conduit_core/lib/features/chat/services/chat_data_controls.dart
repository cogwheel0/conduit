import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:meta/meta.dart';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/chats_dao.dart'
    show ServerChatBulkScope;
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/features/chat/services/chat_backup.dart';
import 'package:conduit_core/features/chat/services/chat_branch_service.dart';
import 'package:conduit_core/features/chat/services/message_batch_service.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/services/conversation_parsing.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/pull_sync.dart'
    show ChatRowsParseOffload, parseChatRowsWorker;
import 'package:conduit_core/utils/debug_logger.dart';

/// Why a data-controls operation did not happen, or did not finish.
enum ChatDataControlsFailure {
  /// The server, account or sign-in session changed while it ran.
  ownerChanged,

  /// The signed-in account has no id the app can match stored chats against,
  /// so it cannot tell which stored chats a server-wide action covers.
  accountUnknown,

  /// The account may not do this (401 or 403).
  forbidden,

  /// Delete all would discard queued edits or responses the server does not
  /// have, and the user did not choose to discard them.
  pendingWork,

  /// A response is being sent or is still generating on the server, which
  /// delete all cannot discard safely. The user has to stop it first.
  responseRunning,

  /// A chat that existed only on this device became a server chat while the
  /// action waited for sync to settle, so the server-wide action would now
  /// reach it.
  localWorkChanged,

  /// The server answered that it could not do it. Nothing changed.
  serverRefused,

  /// The request got no answer. The server may or may not have acted.
  outcomeUnknown,

  /// The chat has no stored copy and none could be loaded.
  unavailable,
}

final class ChatDataControlsException implements Exception {
  const ChatDataControlsException(this.failure, {this.scope});

  final ChatDataControlsFailure failure;

  /// What the action would reach, for [ChatDataControlsFailure.pendingWork],
  /// [ChatDataControlsFailure.responseRunning] and
  /// [ChatDataControlsFailure.localWorkChanged].
  final ServerChatBulkScope? scope;

  @override
  String toString() => 'ChatDataControlsException(${failure.name})';
}

/// The Open WebUI requests data controls make, for one account. An
/// implementation sends every request with the credentials captured when the
/// surface opened.
abstract interface class ChatDataControlsApi {
  Future<Stream<List<int>>> openLibraryExport({CancelToken? cancelToken});

  Future<Map<String, dynamic>?> getChatRaw(String chatId);

  Future<List<Map<String, dynamic>>> importChats(Uint8List body);

  Future<bool> archiveAllChats();

  Future<bool> unarchiveAllChats();

  Future<bool> unshareAllChats();

  Future<bool> deleteAllChats();
}

/// [ChatDataControlsApi] over [ApiService], bound to [auth].
final class ApiChatDataControls implements ChatDataControlsApi {
  const ApiChatDataControls(this.api, this.auth);

  final ApiService api;
  final ApiAuthSnapshot auth;

  @override
  Future<Stream<List<int>>> openLibraryExport({CancelToken? cancelToken}) =>
      api.openChatLibraryExport(authSnapshot: auth, cancelToken: cancelToken);

  @override
  Future<Map<String, dynamic>?> getChatRaw(String chatId) =>
      api.getChatRaw(chatId, authSnapshot: auth);

  @override
  Future<List<Map<String, dynamic>>> importChats(Uint8List body) =>
      api.importChatsRaw(body, authSnapshot: auth);

  @override
  Future<bool> archiveAllChats() => api.archiveAllChatsRaw(authSnapshot: auth);

  @override
  Future<bool> unarchiveAllChats() =>
      api.unarchiveAllChatsRaw(authSnapshot: auth);

  @override
  Future<bool> unshareAllChats() => api.unshareAllChatsRaw(authSnapshot: auth);

  @override
  Future<bool> deleteAllChats() => api.deleteAllChatsRaw(authSnapshot: auth);
}

/// One chat as a backup file holds it.
@immutable
final class ChatExport {
  const ChatExport({
    required this.envelope,
    required this.hasUnsyncedChanges,
    required this.fromServer,
  });

  /// The chat's complete `ChatResponse` envelope: every response branch and
  /// message, params, timestamps and every field the app does not model.
  final Map<String, dynamic> envelope;

  /// The copy includes edits or a first send the server does not have yet.
  final bool hasUnsyncedChanges;

  /// The envelope is the server's own answer rather than the device's copy.
  final bool fromServer;

  String get title {
    final value = envelope['title'];
    return value is String ? value : '';
  }

  /// The file's text: a one-element array, as Open WebUI's own export writes.
  String toJson() => encodeChatBackupJson(<Map<String, dynamic>>[envelope]);
}

/// What an archive, unarchive, unshare or delete-all changed on this device.
@immutable
final class ChatBulkOutcome {
  const ChatBulkOutcome({
    required this.changed,
    this.removedChatIds = const [],
  });

  /// Stored chats changed (or, for delete all, removed).
  final int changed;

  /// For delete all: the ids removed, so the surface can leave a chat that no
  /// longer exists.
  final List<String> removedChatIds;
}

/// What a restore did.
@immutable
final class ChatImportResult {
  const ChatImportResult({required this.imported, required this.stored});

  /// Chats the server created.
  final int imported;

  /// Of [imported], those also stored on this device from the server's answer.
  /// The rest arrive with the next sync that sees them.
  final int stored;
}

/// Data controls for one Open WebUI account: library backup and restore, a
/// single chat's export, and the account-wide archive, unlink and delete.
///
/// Built per operation for the owner that began it. Every request carries that
/// owner's credentials, [ownerIsCurrent] is asked after each await and before
/// each local change, and an answer for an account that is no longer signed in
/// is never stored.
final class ChatDataControlsService {
  const ChatDataControlsService({
    required this.database,
    required this.locks,
    required this.api,
    required this.accountId,
    required this.ownerIsCurrent,
    required this.activeChatIds,
    required this.nowEpochSeconds,
    this.decodeOffload,
    this.rowsParseOffload,
    this.graphOffload,
    this.conversationOffload,
  });

  final AppDatabase database;
  final ConversationLocks locks;
  final ChatDataControlsApi api;

  /// The signed-in account's server user id, or null when it is not known.
  /// Without it a server-wide action cannot tell which stored chats are the
  /// account's own.
  final String? accountId;
  final bool Function() ownerIsCurrent;

  /// The chats the signed-in account has a response running for, read fresh
  /// each time. Task transport records a response here when the server accepts
  /// it and then lets its request op complete, so this is the only record of a
  /// response that is still generating. It is emptied whenever the server or
  /// account changes, so while [ownerIsCurrent] holds it is this account's.
  final Set<String> Function() activeChatIds;
  final int Function() nowEpochSeconds;

  /// Decodes a large JSON document off the UI isolate. Null decodes inline.
  final ChatBackupDecoder? decodeOffload;
  final ChatRowsParseOffload? rowsParseOffload;
  final ChatBranchGraphOffload? graphOffload;
  final ConversationParseOffload? conversationOffload;

  /// Documents below this size decode inline.
  static const int _inlineDecodeLimit = 50 * 1024;

  void _requireOwner() {
    if (!ownerIsCurrent()) {
      throw const ChatDataControlsException(
        ChatDataControlsFailure.ownerChanged,
      );
    }
  }

  String _requireAccount() {
    final id = accountId;
    if (id == null || id.isEmpty) {
      throw const ChatDataControlsException(
        ChatDataControlsFailure.accountUnknown,
      );
    }
    return id;
  }

  /// What a server-wide action would reach and what it would leave out or
  /// discard: the count the user is shown before backing up or confirming.
  Future<ServerChatBulkScope> scope() async {
    _requireOwner();
    final scope = await database.chatsDao.serverWideScope(_requireAccount());
    _requireOwner();
    return scope;
  }

  // ---- Library backup ----

  /// Streams the account's whole library from the server into [sink].
  ///
  /// This is the server's history only: chats that exist just on this device
  /// and edits the server has not received are not in it ([scope] counts them).
  /// Nothing is delivered unless every line arrived intact; a cut-off, malformed
  /// or interrupted export, a stop through [cancelToken] and an account change
  /// all discard what was written.
  Future<ChatLibraryBackupResult> exportLibrary(
    ChatBackupSink sink, {
    CancelToken? cancelToken,
  }) async {
    _requireOwner();
    void checkpoint() {
      if (cancelToken?.isCancelled == true) {
        throw const ChatBackupException(ChatBackupFailure.cancelled);
      }
      if (!ownerIsCurrent()) {
        throw const ChatBackupException(ChatBackupFailure.ownerChanged);
      }
    }

    try {
      final body = await api.openLibraryExport(cancelToken: cancelToken);
      checkpoint();
      return await writeChatLibraryBackup(
        body: body,
        sink: sink,
        decode: _decode,
        checkpoint: checkpoint,
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        throw const ChatBackupException(ChatBackupFailure.cancelled);
      }
      if (!ownerIsCurrent()) {
        throw const ChatBackupException(ChatBackupFailure.ownerChanged);
      }
      rethrow;
    }
  }

  Future<Object?> _decode(String json) {
    final offload = decodeOffload;
    if (offload != null && json.length >= _inlineDecodeLimit) {
      return offload(json);
    }
    return Future<Object?>.sync(() => jsonDecode(json));
  }

  // ---- One chat ----

  /// [chatId]'s complete envelope, including branches outside the visible
  /// window and edits not yet sent. Never the visible conversation.
  ///
  /// A chat the server holds and the device has not edited is read from the
  /// server, so fields this app does not model come with it; if that read
  /// fails the device's complete stored copy is used. A chat with unsent edits,
  /// or never sent, is exported from the device's copy, which is the only one
  /// that has them.
  Future<ChatExport> exportChat(String chatId) async {
    _requireOwner();
    final row = await database.chatsDao.getChat(chatId);
    _requireOwner();
    if (row == null || row.deleted) {
      throw const ChatDataControlsException(
        ChatDataControlsFailure.unavailable,
      );
    }
    final unsynced =
        chatId.startsWith('local:') ||
        row.dirty ||
        await _hasQueuedWork(chatId);
    _requireOwner();

    if (!unsynced && row.bodySynced) {
      Map<String, dynamic>? server;
      try {
        server = await api.getChatRaw(chatId);
      } catch (error) {
        DebugLogger.log(
          'export-server-copy-unavailable',
          scope: 'chat/export',
          data: {'type': error.runtimeType.toString()},
        );
      }
      _requireOwner();
      if (_isChatEnvelope(server) && server!['id'] == chatId) {
        return ChatExport(
          envelope: server,
          hasUnsyncedChanges: false,
          fromServer: true,
        );
      }
    }

    final envelope = await _branchService().readEnvelope(chatId);
    if (envelope == null) {
      throw const ChatDataControlsException(
        ChatDataControlsFailure.unavailable,
      );
    }
    return ChatExport(
      envelope: _asUpstreamEnvelope(envelope),
      hasUnsyncedChanges: unsynced,
      fromServer: false,
    );
  }

  /// A Markdown transcript of [chatId]'s active branch, from the complete
  /// stored chat rather than the visible window. It is not a backup: branches
  /// the chat is not on, params and every other field are left out.
  Future<String> exportChatTranscript(String chatId) async {
    final export = await exportChat(chatId);
    final envelope = export.envelope;
    final offload = conversationOffload;
    final conversation = offload != null
        ? await offload(envelope)
        : parseFullConversationModel(envelope);
    _requireOwner();
    final result = await MessageBatchService().exportMessages(
      messages: conversation.messages,
      format: ExportFormat.markdown,
      options: const ExportOptions(includeTimestamps: false),
    );
    final content = result.data?['content'];
    if (!result.success || content is! String) {
      throw const ChatDataControlsException(
        ChatDataControlsFailure.unavailable,
      );
    }
    final title = _titleOf(conversation);
    return '# $title\n\n$content';
  }

  String _titleOf(Conversation conversation) {
    final title = conversation.title.trim();
    return title.isEmpty ? 'Chat' : title;
  }

  Future<bool> _hasQueuedWork(String chatId) async {
    final ops = await (database.select(
      database.outboxOps,
    )..where((t) => t.chatId.equals(chatId))).get();
    return ops.any((op) {
      final kind = OutboxKind.fromName(op.kind);
      return kind == OutboxKind.createChat ||
          kind == OutboxKind.updateChat ||
          kind == OutboxKind.requestCompletion;
    });
  }

  ChatBranchService _branchService() => ChatBranchService(
    database: database,
    locks: locks,
    ownerIsCurrent: ownerIsCurrent,
    nowEpochSeconds: nowEpochSeconds,
    graphOffload: graphOffload,
    rowsParseOffload: rowsParseOffload,
    authoritativeLoader: api.getChatRaw,
  );

  /// The device's rebuilt envelope in the shape the server exports: without the
  /// private fields the app adds for its own use.
  Map<String, dynamic> _asUpstreamEnvelope(Map<String, dynamic> built) {
    return <String, dynamic>{
      for (final entry in built.entries)
        if (entry.key != 'tasks' && entry.key != 'last_read_at')
          entry.key: entry.value,
    };
  }

  // ---- Restore ----

  /// Sends [preview] to the server once and stores what it created.
  ///
  /// The request is never repeated: a failure with no answer may have created
  /// some or all of the chats, so it is reported as unknown and left for the
  /// user to check. What the server answers is stored for the account that sent
  /// it, so chats with old timestamps appear without waiting for a sync that
  /// would not look that far back.
  Future<ChatImportResult> importChats(ChatImportPreview preview) async {
    _requireOwner();
    final readGeneration = locks.generation;
    final List<Map<String, dynamic>> created;
    try {
      created = await api.importChats(preview.body);
    } on DioException catch (error) {
      throw _classify(error);
    }
    _requireOwner();

    var stored = 0;
    for (final envelope in created) {
      try {
        if (await _storeServerEnvelope(envelope, readGeneration)) stored++;
      } on ChatDataControlsException {
        rethrow;
      } catch (error) {
        DebugLogger.log(
          'import-store-failed',
          scope: 'chat/import',
          data: {'type': error.runtimeType.toString()},
        );
      }
    }
    return ChatImportResult(imported: created.length, stored: stored);
  }

  Future<bool> _storeServerEnvelope(
    Map<String, dynamic> envelope,
    int readGeneration,
  ) async {
    final id = envelope['id'];
    if (id is! String || id.isEmpty || envelope['chat'] is! Map) return false;
    final messages = switch (envelope['chat']) {
      {'history': {'messages': final Map<dynamic, dynamic> stored}} =>
        stored.length,
      _ => 0,
    };
    final offload = rowsParseOffload;
    final rows = offload != null && messages > kLocalConversationWorkerThreshold
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
    return locks.runExclusive(id, () async {
      _requireOwner();
      if (locks.generation != readGeneration) return false;
      await database.chatsDao.mergeServerChat(
        server: rows,
        shareId: shareId is String ? shareId : null,
        userId: envelope['user_id']?.toString(),
        meta: meta,
      );
      return true;
    });
  }

  // ---- Account-wide changes ----

  /// Archives every chat of the account on the server, then on this device.
  Future<ChatBulkOutcome> archiveAll() => _runBulk(
    request: api.archiveAllChats,
    reconcile: (account) async => ChatBulkOutcome(
      changed: await database.chatsDao.applyServerWideArchive(
        account,
        archived: true,
      ),
    ),
  );

  /// Unarchives every chat of the account on the server, then on this device.
  Future<ChatBulkOutcome> unarchiveAll() => _runBulk(
    request: api.unarchiveAllChats,
    reconcile: (account) async => ChatBulkOutcome(
      changed: await database.chatsDao.applyServerWideArchive(
        account,
        archived: false,
      ),
    ),
  );

  /// Removes every share link of the account on the server, then on this
  /// device. The chats stay.
  Future<ChatBulkOutcome> unshareAll() => _runBulk(
    request: api.unshareAllChats,
    reconcile: (account) async => ChatBulkOutcome(
      changed: await database.chatsDao.clearServerWideShareLinks(account),
    ),
  );

  /// Deletes every chat of the account on the server, then on this device.
  ///
  /// Chats that exist only on this device stay. Queued edits and responses for
  /// the chats being deleted are discarded only when [discardUnsyncedWork] is
  /// true; otherwise their presence refuses the action before anything is
  /// sent. [knownLocalOnlyChatIds] are the device-only chats the user was shown;
  /// if one of them reached the server while the action waited for sync to
  /// settle, the action is refused rather than delete it.
  Future<ChatBulkOutcome> deleteAll({
    required bool discardUnsyncedWork,
    Set<String> knownLocalOnlyChatIds = const <String>{},
  }) => _runBulk(
    precheck: (scope) {
      // Runs after the barrier wait and the scope read, in the same synchronous
      // step as the final owner check and the DELETE, so a response the
      // registry learns of later than this read cannot slip in between.
      if (scope.runningResponses > 0 || activeChatIds().isNotEmpty) {
        throw ChatDataControlsException(
          ChatDataControlsFailure.responseRunning,
          scope: scope,
        );
      }
      if (scope.hasWorkTheServerLacks && !discardUnsyncedWork) {
        throw ChatDataControlsException(
          ChatDataControlsFailure.pendingWork,
          scope: scope,
        );
      }
      final stillLocal = scope.localOnlyChatIds.toSet();
      if (knownLocalOnlyChatIds.any((id) => !stillLocal.contains(id))) {
        throw ChatDataControlsException(
          ChatDataControlsFailure.localWorkChanged,
          scope: scope,
        );
      }
    },
    request: api.deleteAllChats,
    reconcile: (account) async {
      final removed = await database.chatsDao.purgeServerWideChats(account);
      return ChatBulkOutcome(changed: removed.length, removedChatIds: removed);
    },
  );

  /// Runs one server-wide change as a single unit of the account's chats.
  ///
  /// The barrier lets every chat write already admitted finish, holds back any
  /// new send, pull merge or drain push, and drops reads that began before it
  /// ends. Inside it the scope is read, the server is asked once, and only an
  /// answer of `true` changes the stored chats; any failure leaves them as they
  /// were.
  Future<ChatBulkOutcome> _runBulk({
    required Future<bool> Function() request,
    required Future<ChatBulkOutcome> Function(String accountId) reconcile,
    void Function(ServerChatBulkScope scope)? precheck,
  }) async {
    final account = _requireAccount();
    _requireOwner();
    return locks.runBarrier(() async {
      _requireOwner();
      if (precheck != null) {
        precheck(await database.chatsDao.serverWideScope(account));
        _requireOwner();
      }
      final bool accepted;
      try {
        accepted = await request();
      } on DioException catch (error) {
        throw _classify(error);
      }
      if (!accepted) {
        throw const ChatDataControlsException(
          ChatDataControlsFailure.serverRefused,
        );
      }
      // The server has acted for the account that asked. If that account is no
      // longer the signed-in one, its stored chats are not this device's to
      // rewrite from here; they follow the account's own sync.
      _requireOwner();
      return reconcile(account);
    });
  }

  ChatDataControlsException _classify(DioException error) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      return const ChatDataControlsException(ChatDataControlsFailure.forbidden);
    }
    if (status == null) {
      return const ChatDataControlsException(
        ChatDataControlsFailure.outcomeUnknown,
      );
    }
    return const ChatDataControlsException(
      ChatDataControlsFailure.serverRefused,
    );
  }
}

bool _isChatEnvelope(Map<String, dynamic>? value) =>
    value != null &&
    value['id'] is String &&
    (value['id'] as String).isNotEmpty &&
    value['chat'] is Map;
