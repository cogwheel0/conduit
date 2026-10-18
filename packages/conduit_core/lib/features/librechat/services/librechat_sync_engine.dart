import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/features/librechat/models/librechat_message.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_message_mapper.dart';
import 'package:conduit_core/sync/backoff.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:conduit_core/sync/sync_entity_adapter.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// The key, in a chat's stored `meta`, of what the server last said about
/// its envelope. A local rename, pin or archive is pushed as the difference
/// from it, since LibreChat takes each as its own call.
const String kLibreChatEnvelopeBaselineKey = 'libreChatEnvelope';

/// Keeps one LibreChat account's local database in step with its server.
///
/// A pull lists conversations newest-updated first by cursor, through the
/// shared watermark driver, and stores each changed one whole: its envelope
/// and every message (bodies sync eagerly, so offline reading and search
/// cover everything). LibreChat writes pins and archiving without touching
/// a conversation's `updatedAt`, so those never show up as changes: every
/// pull also reads the pinned list, and a full pass over every conversation
/// id (throttled) reconciles archiving and conversations deleted elsewhere.
///
/// Local renames, pins, archives and deletes queue in the outbox and drain
/// here as LibreChat calls. A conversation with queued work, or a reply
/// generating, is never overwritten by a pull; it is fetched again after.
final class LibreChatSyncEngine {
  LibreChatSyncEngine({
    required this.db,
    required this.api,
    ChatLocks? locks,
    SyncClock? clock,
    Backoff? backoff,
    bool Function()? isOnline,
    bool Function(String conversationId)? isGenerating,
    RequestCompletionRunner? completion,
    this.reconcileInterval = const Duration(minutes: 15),
  }) : locks = locks ?? ChatLocks(),
       _clock = clock ?? SystemSyncClock(),
       _isOnline = isOnline ?? _alwaysOnline,
       _isGenerating = isGenerating ?? _neverGenerating {
    _adapter = LibreChatChatAdapter(this);
    _drainer = OutboxDrainer(
      db: db,
      clock: _clock,
      backoff: backoff ?? Backoff(jitter: math.Random().nextDouble),
      isOnline: _isOnline,
      completion: completion ?? const _NoCompletionRunner(),
      adapters: [_adapter],
      terminalClassifier: _terminalStatus,
    );
  }

  final AppDatabase db;
  final LibreChatApiService api;
  final ChatLocks locks;
  final Duration reconcileInterval;
  final SyncClock _clock;
  final bool Function() _isOnline;
  final bool Function(String conversationId) _isGenerating;

  /// A forced reconciliation asked for while a pull ran, for the pass that
  /// follows it.
  bool _forceReconcileAgain = false;

  /// Conversations a pull passed over because local work held them (a reply
  /// generating, a queued edit). Their changes are behind the watermark now,
  /// so they are fetched on their own once that work is done.
  final Set<String> _deferred = <String>{};
  bool _deferredLoaded = false;

  /// Conversations the last full pass found on the server with no local
  /// copy. Those the archived pass after it does not store are fetched with
  /// the deferred ones.
  final Set<String> _unstored = <String>{};

  late final LibreChatChatAdapter _archivedAdapter = LibreChatChatAdapter(
    this,
    archived: true,
  );
  late final LibreChatChatAdapter _adapter;
  late final OutboxDrainer _drainer;
  Future<void>? _pull;
  bool _pullAgain = false;
  bool _closed = false;

  static bool _alwaysOnline() => true;
  static bool _neverGenerating(String _) => false;

  /// `sync_meta` keys.
  static const String watermarkKey = 'librechat_pull_watermark';
  static const String reconciledAtKey = 'librechat_reconciled_at';
  static const String archivedWatermarkKey =
      'librechat_archived_pull_watermark';
  static const String deferredKey = 'librechat_deferred_ids';

  /// Stops new work; work already running finishes.
  void close() => _closed = true;

  /// Pulls what changed. Overlapping calls share one pull, plus at most one
  /// more after it.
  Future<void> pull({bool forceReconcile = false}) {
    if (_closed) return Future<void>.value();
    final running = _pull;
    if (running != null) {
      _pullAgain = true;
      if (forceReconcile) _forceReconcileAgain = true;
      return running;
    }
    final pull = _runPulls(forceReconcile);
    _pull = pull;
    return pull.whenComplete(() => _pull = null);
  }

  Future<void> _runPulls(bool forceReconcile) async {
    do {
      _pullAgain = false;
      await _pullOnce(forceReconcile);
      forceReconcile = _forceReconcileAgain;
      _forceReconcileAgain = false;
    } while (_pullAgain && !_closed);
  }

  Future<void> _pullOnce(bool forceReconcile) async {
    if (!_isOnline()) return;
    final result = await runPullFor(_adapter, db: db);
    if (!result.success || _closed) return;
    await _reconcilePins();
    if (_closed) return;
    final now = _clock.nowEpochSeconds();
    final last = int.tryParse(
      await db.syncMetaDao.getValue(reconciledAtKey) ?? '',
    );
    if (forceReconcile ||
        last == null ||
        now - last >= reconcileInterval.inSeconds) {
      if (await _reconcileAll()) {
        await db.syncMetaDao.setValue(reconciledAtKey, '$now');
      }
    }
    if (_closed) return;
    // The archive is listed apart from the active conversations, so it has
    // its own pass and watermark; without it a chat archived before the
    // first sync would never arrive.
    await runPullFor(_archivedAdapter, db: db);
    if (_closed) return;
    await _pullDeferred();
  }

  /// Fetches the conversations earlier pulls passed over, now that the
  /// local work that held them is done.
  Future<void> _pullDeferred() async {
    await _loadDeferred();
    // One no pass stored, such as a chat moved between the lists while they
    // were read, is behind both watermarks and would never arrive.
    for (final id in _unstored) {
      if (await db.chatsDao.getChat(id) == null) _defer(id);
    }
    _unstored.clear();
    for (final id in _deferred.toList()) {
      if (_closed) return;
      if (_isGenerating(id) || await _hasQueuedWork(id)) continue;
      _deferred.remove(id);
      try {
        await pullChat(id);
      } on LibreChatApiException {
        _deferred.add(id);
      }
    }
    await _saveDeferred();
  }

  void _defer(String id) => _deferred.add(id);

  Future<void> _loadDeferred() async {
    if (_deferredLoaded) return;
    _deferredLoaded = true;
    final raw = await db.syncMetaDao.getValue(deferredKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final ids = jsonDecode(raw);
      if (ids is List) _deferred.addAll(ids.whereType<String>());
    } on FormatException {
      // A damaged list is dropped; the next full pass catches up.
    }
  }

  Future<void> _saveDeferred() =>
      db.syncMetaDao.setValue(deferredKey, jsonEncode(_deferred.toList()));

  /// Fetches conversation [id] now and stores it, unless it has queued work
  /// or a reply generating. Returns whether the server has it.
  Future<bool> pullChat(String id) async {
    final conversation = await api.conversation(id);
    if (conversation == null) return false;
    await _adapter.storeConversation(conversation);
    return true;
  }

  /// Runs the outbox: queued renames, pins, archives, deletes and sends.
  Future<void> drain() => _closed ? Future<void>.value() : _drainer.drain();

  /// Stores a conversation the caller already holds, with its [messages],
  /// as the server has it now (after a reply finished, say).
  Future<void> storeFetched(
    LibreChatConversation conversation,
    List<LibreChatMessage> messages,
  ) => _adapter.store(conversation, messages);

  Future<void> _reconcilePins() async {
    final Set<String> pinned;
    try {
      // The pinned list follows the archive filter, so an archived chat
      // still pinned is only in the archived one.
      pinned = {
        ...await _allIds(pinnedOnly: true),
        ...await _allIds(archived: true, pinnedOnly: true),
      };
    } on LibreChatApiException catch (error) {
      DebugLogger.warning(
        'pin-reconcile-failed',
        scope: 'librechat/sync',
        data: {'status': error.statusCode},
      );
      return;
    }
    final rows = await (db.select(
      db.chats,
    )..where((t) => t.deleted.equals(false) & t.dirty.equals(false))).get();
    for (final row in rows) {
      final serverPinned = pinned.contains(row.id);
      if (row.pinned == serverPinned) continue;
      await locks.runExclusive(row.id, () async {
        final current = await db.chatsDao.getChat(row.id);
        if (current == null || current.dirty || current.deleted) return;
        await _writeEnvelope(row.id, pinned: serverPinned);
      });
    }
  }

  /// One pass over every conversation id, active and archived: archive
  /// state set from the server, and clean local copies of conversations
  /// the server no longer has removed. Returns whether it completed.
  Future<bool> _reconcileAll() async {
    final Set<String> active;
    final Set<String> archived;
    try {
      active = await _allIds();
      archived = await _allIds(archived: true);
    } on LibreChatApiException catch (error) {
      DebugLogger.warning(
        'reconcile-list-failed',
        scope: 'librechat/sync',
        data: {'status': error.statusCode},
      );
      return false;
    }
    final local = await db.chatsDao.allServerChatReconcileEntries();
    _unstored
      ..clear()
      ..addAll(
        {...active, ...archived}.difference({
          for (final entry in local) entry.id,
        }),
      );
    final missing = [
      for (final entry in local)
        if (!entry.dirty &&
            !active.contains(entry.id) &&
            !archived.contains(entry.id))
          entry.id,
    ];
    // An empty answer against a populated cache is far more likely a server
    // or proxy fault than the user deleting everything elsewhere.
    if (active.isEmpty && archived.isEmpty && missing.length > 3) {
      DebugLogger.warning(
        'reconcile-safety-valve',
        scope: 'librechat/sync',
        data: {'local': local.length},
      );
      return false;
    }
    for (final id in missing) {
      if (_isGenerating(id)) continue;
      // A conversation archived or unarchived between the two lists is in
      // neither: only one the server no longer has goes.
      try {
        if (await api.conversation(id) != null) continue;
      } on LibreChatApiException {
        continue;
      }
      await locks.runExclusive(id, () async {
        final current = await db.chatsDao.getChat(id);
        if (current == null || current.dirty || await _hasQueuedWork(id)) {
          return;
        }
        await db.chatsDao.purgeReconciledChat(id);
      });
    }
    for (final entry in local) {
      final isArchived = archived.contains(entry.id);
      if (!isArchived && !active.contains(entry.id)) continue;
      await locks.runExclusive(entry.id, () async {
        final current = await db.chatsDao.getChat(entry.id);
        if (current == null ||
            current.dirty ||
            current.deleted ||
            current.archived == isArchived) {
          return;
        }
        await _writeEnvelope(entry.id, archived: isArchived);
        // Moving between the lists can leave it behind the new list's
        // watermark, with messages added before the move never pulled:
        // fetched whole once this pass is done.
        _defer(entry.id);
      });
    }
    return true;
  }

  Future<Set<String>> _allIds({
    bool archived = false,
    bool pinnedOnly = false,
  }) async {
    final ids = <String>{};
    String? cursor;
    for (var page = 0; page < 500; page++) {
      final result = await api.conversations(
        cursor: cursor,
        archived: archived,
        pinnedOnly: pinnedOnly,
      );
      for (final conversation in result.conversations) {
        ids.add(conversation.conversationId);
      }
      cursor = result.nextCursor;
      if (cursor == null) return ids;
    }
    // A list cut short would read as conversations deleted elsewhere.
    throw const LibreChatApiException(
      message: 'The conversation list has more pages than a sync reads.',
    );
  }

  /// Sets envelope flags the server reported, keeping the stored baseline
  /// in step so they are never pushed back.
  Future<void> _writeEnvelope(
    String id, {
    bool? pinned,
    bool? archived,
    String? title,
  }) async {
    final row = await db.chatsDao.getChat(id);
    if (row == null) return;
    final meta = _decode(row.meta);
    final baseline = Map<String, dynamic>.from(
      meta[kLibreChatEnvelopeBaselineKey] as Map? ?? const {},
    );
    if (pinned != null) baseline['pinned'] = pinned;
    if (archived != null) baseline['archived'] = archived;
    if (title != null) baseline['title'] = title;
    meta[kLibreChatEnvelopeBaselineKey] = baseline;
    await (db.update(db.chats)..where((t) => t.id.equals(id))).write(
      ChatsCompanion(
        pinned: pinned == null ? const Value.absent() : Value(pinned),
        archived: archived == null ? const Value.absent() : Value(archived),
        title: title == null ? const Value.absent() : Value(title),
        meta: Value(jsonEncode(meta)),
      ),
    );
  }

  /// The conversations this run deleted on the server. A pull that fetched
  /// one before the delete went through must not store it again, and its id
  /// never comes back.
  final Set<String> _deletedOnServer = <String>{};

  /// Whether conversation [id] has outbox work not yet confirmed.
  Future<bool> _hasQueuedWork(String id) async {
    final ops =
        await (db.select(db.outboxOps)..where(
              (t) =>
                  t.chatId.equals(id) &
                  t.status.isIn([OutboxStatus.pending, OutboxStatus.inFlight]),
            ))
            .get();
    return ops.isNotEmpty;
  }

  static Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  static int? _terminalStatus(Object error) {
    if (error is SyncTerminalException) return error.statusCode ?? 403;
    if (error is LibreChatApiException) {
      final status = error.statusCode;
      if (status == 403 || status == 404 || status == 400) return status;
    }
    return null;
  }
}

/// The LibreChat side of the shared pull driver and outbox: conversations
/// listed by cursor, each fetched with its messages and stored whole.
final class LibreChatChatAdapter implements SyncEntityAdapter {
  LibreChatChatAdapter(this._engine, {this.archived = false});

  final LibreChatSyncEngine _engine;

  /// Lists the archive instead of the active conversations.
  final bool archived;

  /// Each list page's cursor, by page number, for this pull.
  final Map<int, String?> _cursors = <int, String?>{1: null};

  /// The conversations the current pull listed, by id, so a changed one
  /// needs only its messages fetched.
  final Map<String, LibreChatConversation> _listed =
      <String, LibreChatConversation>{};

  AppDatabase get _db => _engine.db;

  @override
  String get watermarkKey => archived
      ? LibreChatSyncEngine.archivedWatermarkKey
      : LibreChatSyncEngine.watermarkKey;

  /// Seconds of overlap, so a conversation updated in the same second as the
  /// watermark is not skipped.
  @override
  int get pullOverlap => 60;

  @override
  int get listPageSize => 100;

  @override
  bool get listEnvelopeIsFullRaw => false;

  @override
  bool ownsKind(OutboxKind kind) =>
      kind == OutboxKind.updateChat || kind == OutboxKind.deleteChat;

  @override
  Future<List<SyncListItem>> getListPage(int page) async {
    if (page == 1) {
      _cursors
        ..clear()
        ..[1] = null;
      _listed.clear();
    }
    if (!_cursors.containsKey(page)) return const <SyncListItem>[];
    final result = await _engine.api.conversations(
      cursor: _cursors[page],
      archived: archived,
    );
    if (result.nextCursor != null) _cursors[page + 1] = result.nextCursor;
    return [
      for (final conversation in result.conversations)
        if (conversation.updatedAt == null)
          const SyncListItem.skip()
        else
          _listItem(conversation),
    ];
  }

  SyncListItem _listItem(LibreChatConversation conversation) {
    _listed[conversation.conversationId] = conversation;
    return SyncListItem(
      id: conversation.conversationId,
      updatedAt: conversation.updatedAt!.millisecondsSinceEpoch ~/ 1000,
    );
  }

  @override
  Future<Map<String, dynamic>?> fetchRaw(String id) async {
    final conversation =
        _listed[id] ?? await _engine.api.conversation(id);
    if (conversation == null) return null;
    final messages = await _engine.api.messages(id);
    return <String, dynamic>{
      'conversation': conversation.raw,
      'messages': [for (final message in messages) message.raw],
    };
  }

  @override
  Future<bool> mergeServer(Map<String, dynamic> raw) async {
    final conversation = LibreChatConversation.fromJson(raw['conversation']);
    if (conversation == null) return false;
    final list = raw['messages'];
    final messages = [
      if (list is List)
        for (final item in list) ?LibreChatMessage.fromJson(item),
    ];
    return store(conversation, messages);
  }

  /// Fetches [conversation]'s messages and stores both.
  Future<bool> storeConversation(LibreChatConversation conversation) async {
    final messages = await _engine.api.messages(conversation.conversationId);
    return store(conversation, messages);
  }

  /// Stores [conversation] with [messages] unless local work owns it right
  /// now, in which case it is fetched again once that work is done. Returns
  /// whether local work is still owed to the server.
  ///
  /// A chat with a local envelope edit the server has not taken (one still
  /// queued, or one it refused) takes the server's messages but keeps the
  /// edit, so the edit can still be pushed or retried.
  Future<bool> store(
    LibreChatConversation conversation,
    List<LibreChatMessage> messages,
  ) {
    final id = conversation.conversationId;
    if (_engine._isGenerating(id)) {
      _engine._defer(id);
      return Future<bool>.value(false);
    }
    return _engine.locks.runExclusive(id, () async {
      if (await _engine._hasQueuedWork(id)) {
        _engine._defer(id);
        return true;
      }
      if (_engine._deletedOnServer.contains(id)) return false;
      final existing = await _db.chatsDao.getChat(id);
      if (existing != null && existing.deleted) return true;
      final rows = LibreChatMessageMapper.chatRows(conversation, messages);
      final meta = existing == null
          ? <String, dynamic>{}
          : LibreChatSyncEngine._decode(existing.meta);
      meta[kLibreChatEnvelopeBaselineKey] = <String, dynamic>{
        'title': conversation.title,
        'pinned': conversation.pinned,
        'archived': conversation.isArchived,
      };
      await _db.chatsDao.upsertServerChat(rows: rows, meta: meta);
      if (existing == null || !existing.dirty) return false;
      await (_db.update(_db.chats)..where((t) => t.id.equals(id))).write(
        ChatsCompanion(
          title: Value(existing.title),
          pinned: Value(existing.pinned),
          archived: Value(existing.archived),
          dirty: const Value(true),
        ),
      );
      return true;
    });
  }

  @override
  Future<void> pushOp(OutboxOp op) async {
    final id = op.chatId;
    if (id == null) return;
    switch (OutboxKind.fromName(op.kind)) {
      case OutboxKind.deleteChat:
        await _engine.api.deleteConversation(id);
        await _engine.locks.runExclusive(id, () async {
          await _db.chatsDao.purgeReconciledChat(id);
          _engine._deletedOnServer.add(id);
        });
      case OutboxKind.updateChat:
        await _pushEnvelope(id);
      default:
        return;
    }
  }

  Future<void> _pushEnvelope(String id) async {
    final row = await _db.chatsDao.getChat(id);
    if (row == null || row.deleted) return;
    final meta = LibreChatSyncEngine._decode(row.meta);
    final baseline = Map<String, dynamic>.from(
      meta[kLibreChatEnvelopeBaselineKey] as Map? ?? const {},
    );
    if (baseline['title'] != row.title) {
      await _engine.api.renameConversation(id, row.title);
      await _recordBaseline(id, 'title', row.title);
    }
    if (baseline['pinned'] != row.pinned) {
      await _engine.api.setPinned(id, row.pinned);
      await _recordBaseline(id, 'pinned', row.pinned);
    }
    if (baseline['archived'] != row.archived) {
      await _engine.api.setArchived(id, row.archived);
      await _recordBaseline(id, 'archived', row.archived);
      // Moving between the lists can leave it behind the new list's
      // watermark, with messages the server gained before the move never
      // pulled: fetched whole by the next pull.
      _engine._defer(id);
    }
    await _engine.locks.runExclusive(id, () async {
      final current = await _db.chatsDao.getChat(id);
      if (current == null) return;
      final currentMeta = LibreChatSyncEngine._decode(current.meta);
      currentMeta[kLibreChatEnvelopeBaselineKey] = <String, dynamic>{
        'title': row.title,
        'pinned': row.pinned,
        'archived': row.archived,
      };
      // Still dirty if the user changed it again while this push ran; the
      // next updateChat op pushes that.
      final unchanged =
          current.title == row.title &&
          current.pinned == row.pinned &&
          current.archived == row.archived;
      await (_db.update(_db.chats)..where((t) => t.id.equals(id))).write(
        ChatsCompanion(
          meta: Value(jsonEncode(currentMeta)),
          dirty: unchanged ? const Value(false) : const Value.absent(),
        ),
      );
    });
  }

  /// Records that the server took [field] as [value], as soon as it did: a
  /// later call failing must not leave the baseline behind the server, or a
  /// retry after the user changed the field back would skip it.
  Future<void> _recordBaseline(String id, String field, Object value) =>
      _engine.locks.runExclusive(id, () async {
        final current = await _db.chatsDao.getChat(id);
        if (current == null) return;
        final meta = LibreChatSyncEngine._decode(current.meta);
        meta[kLibreChatEnvelopeBaselineKey] = <String, dynamic>{
          ...?meta[kLibreChatEnvelopeBaselineKey] as Map?,
          field: value,
        };
        await (_db.update(_db.chats)..where((t) => t.id.equals(id))).write(
          ChatsCompanion(meta: Value(jsonEncode(meta))),
        );
      });
}

/// Stands in when no runner was given. A queued send that reaches it fails,
/// so the drainer retries and then parks it rather than counting it sent.
final class _NoCompletionRunner implements RequestCompletionRunner {
  const _NoCompletionRunner();

  @override
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) async {
    DebugLogger.warning('no-completion-runner', scope: 'librechat/sync');
    throw StateError('No LibreChat completion runner is set up.');
  }
}
