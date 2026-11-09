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
import 'package:conduit_core/sync/pull_sync.dart';
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
    Future<void> Function()? Function()? holdDatabase,
    RequestCompletionRunner? completion,
    this.reconcileInterval = const Duration(minutes: 15),
  }) : locks = locks ?? ChatLocks(),
       _clock = clock ?? SystemSyncClock(),
       _isOnline = isOnline ?? _alwaysOnline,
       _isGenerating = isGenerating ?? _neverGenerating,
       _holdDatabase = holdDatabase {
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

  /// Keeps [db] open until the returned release is called; null when it
  /// cannot be held (or needs no holding).
  final Future<void> Function()? Function()? _holdDatabase;

  /// A forced reconciliation asked for while a pull ran, for the pass that
  /// follows it.
  bool _forceReconcileAgain = false;

  /// Conversations a pull passed over because local work held them (a reply
  /// generating, a queued edit). Their changes are behind the watermark now,
  /// so they are fetched on their own once that work is done.
  ///
  /// One list per database, as its saved copy is: a quick return to an
  /// account can hand a new engine the database a departing one still
  /// pulls in, and each saving its own list would drop the other's.
  late final _DeferredIds _deferredIds = _deferredByDatabase[db] ??=
      _DeferredIds();

  Set<String> get _deferred => _deferredIds.ids;

  static final Expando<_DeferredIds> _deferredByDatabase =
      Expando<_DeferredIds>('librechat-deferred');

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
  Future<PullResult>? _pull;
  bool _pullAgain = false;
  Future<void>? _drain;
  bool _drainAgain = false;
  bool _closed = false;

  static bool _alwaysOnline() => true;
  static bool _neverGenerating(String _) => false;

  /// The drain last started on each database, by whichever engine. A quick
  /// return to an account can hand a new engine the database a departing
  /// one is still draining. A new drainer first takes back every op left in
  /// flight, so it waits for that drain to end rather than take back, and
  /// send again, an op still being pushed.
  static final Expando<Future<void>> _drainsByDatabase =
      Expando<Future<void>>('librechat-drains');

  /// `sync_meta` keys.
  static const String watermarkKey = 'librechat_pull_watermark';
  static const String reconciledAtKey = 'librechat_reconciled_at';
  static const String archivedWatermarkKey =
      'librechat_archived_pull_watermark';
  static const String deferredKey = 'librechat_deferred_ids';

  /// Stops new work; work already running finishes.
  void close() => _closed = true;

  static const PullResult _notPulled = PullResult(
    success: false,
    watermarkAdvanced: false,
  );

  /// Pulls what changed. Overlapping calls share one pull, plus at most one
  /// more after it. Reports how the last pass went; offline, nothing is
  /// pulled and the result says so.
  Future<PullResult> pull({bool forceReconcile = false}) {
    if (_closed) return Future<PullResult>.value(_notPulled);
    final running = _pull;
    if (running != null) {
      _pullAgain = true;
      if (forceReconcile) _forceReconcileAgain = true;
      return running;
    }
    // Set before the run starts: one that ends before its first await (a
    // hold that fails) clears it then, and must not be stored after that.
    final run = Completer<PullResult>();
    _pull = run.future;
    run.complete(_runPulls(forceReconcile));
    return run.future;
  }

  Future<PullResult> _runPulls(bool forceReconcile) async {
    var result = _notPulled;
    // Held open to the end, so leaving the account mid-pull cannot close
    // the database before the passed-over chats are saved. Taken inside the
    // try: a hold that fails still clears the pull, so the next one runs.
    Future<void> Function()? release;
    try {
      release = _holdDatabase?.call();
      do {
        _pullAgain = false;
        result = await _pullOnce(forceReconcile);
        forceReconcile = _forceReconcileAgain;
        _forceReconcileAgain = false;
      } while (_pullAgain && !_closed);
    } finally {
      // Cleared as the loop ends, so a call from now on starts a new pull
      // rather than joining one that will not look again.
      _pull = null;
      await _keepDeferred();
      await release?.call();
    }
    return result;
  }

  /// Saves the conversations a pull passed over however it ended -- one cut
  /// short when the account is left included: its watermark has moved past
  /// them, so only this list brings them back.
  Future<void> _keepDeferred() async {
    if (_deferred.isEmpty) return;
    try {
      await _loadDeferred();
      await _saveDeferred();
    } catch (error) {
      DebugLogger.warning(
        'deferred-save-failed',
        scope: 'librechat/sync',
        data: {'error': error.runtimeType.toString()},
      );
    }
  }

  Future<PullResult> _pullOnce(bool forceReconcile) async {
    if (!_isOnline()) return _notPulled;
    // A list's first sync brings in what the user already had, read as it
    // stands: LibreChat keeps no read state, and every chat would show as
    // unread. Only chats new or changed after it are. Until a pass over the
    // list succeeds it has no watermark, so a first sync cut short or failed
    // is still the first next time, and what it brings then starts read too.
    final firstSync = await db.syncMetaDao.getValue(watermarkKey) == null;
    final firstArchiveSync =
        await db.syncMetaDao.getValue(archivedWatermarkKey) == null;
    final pass = await runPullFor(_adapter, db: db);
    if (firstSync) await _markAllRead(archived: false);
    final result = PullResult(
      success: pass.success && pass.failedFetches == 0,
      changedChats: pass.changed,
      failedFetches: pass.failedFetches,
      watermarkAdvanced: pass.watermarkAdvanced,
    );
    if (!pass.success || _closed) return result;
    // Search reads the full-text index, which a new database builds once
    // (live writes index themselves after that), as Open WebUI's sync does.
    await db.buildFtsIfNeeded();
    if (_closed) return result;
    await _reconcilePins();
    if (_closed) return result;
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
    if (_closed) return result;
    // The archive is listed apart from the active conversations, so it has
    // its own pass and watermark; without it a chat archived before the
    // first sync would never arrive. Its failures count as the pull's.
    final archivedPass = await runPullFor(_archivedAdapter, db: db);
    if (firstArchiveSync) await _markAllRead(archived: true);
    final combined = PullResult(
      success:
          result.success &&
          archivedPass.success &&
          archivedPass.failedFetches == 0,
      changedChats: result.changedChats + archivedPass.changed,
      failedFetches: result.failedFetches + archivedPass.failedFetches,
      watermarkAdvanced:
          result.watermarkAdvanced || archivedPass.watermarkAdvanced,
    );
    if (_closed) return combined;
    final deferredFailures = await _pullDeferred();
    if (deferredFailures == 0) return combined;
    // A conversation passed over earlier that still could not be fetched
    // leaves history behind: the pull did not fully succeed.
    return PullResult(
      success: false,
      changedChats: combined.changedChats,
      failedFetches: combined.failedFetches + deferredFailures,
      watermarkAdvanced: combined.watermarkAdvanced,
    );
  }

  /// Marks every chat stored so far in the active list, or with [archived]
  /// in the archive, read up to its last change.
  Future<void> _markAllRead({required bool archived}) => db.customUpdate(
    'UPDATE chats SET last_read_at = updated_at '
    'WHERE last_read_at IS NULL AND archived = ?',
    variables: [Variable.withBool(archived)],
    updates: {db.chats},
    updateKind: UpdateKind.update,
  );

  /// Fetches the conversations earlier pulls passed over, now that the
  /// local work that held them is done. Returns how many could not be
  /// fetched; they are tried again later.
  Future<int> _pullDeferred() async {
    await _loadDeferred();
    var failures = 0;
    // One no pass stored, such as a chat moved between the lists while they
    // were read, is behind both watermarks and would never arrive.
    for (final id in _unstored) {
      if (await db.chatsDao.getChat(id) == null) await _defer(id);
    }
    _unstored.clear();
    for (final id in _deferred.toList()) {
      if (_closed) return failures;
      if (_isGenerating(id) || await _hasQueuedWork(id)) continue;
      _deferred.remove(id);
      try {
        await pullChat(id);
      } catch (error) {
        // Kept however the fetch failed: the list is saved as the pull ends,
        // and an id left off it would never be fetched.
        _deferred.add(id);
        if (error is! LibreChatApiException) rethrow;
        failures++;
      }
    }
    await _saveDeferred();
    return failures;
  }

  /// Puts conversation [id] on the list fetched once local work lets it, and
  /// saves the list straight away: the pull that passed it over may write a
  /// watermark past it before it ends, and a process killed in between
  /// would otherwise never fetch it.
  Future<void> _defer(String id) async {
    await _loadDeferred();
    if (_deferred.add(id)) await _saveDeferred();
  }

  /// Merges the saved list into the one in memory, once per database. Every
  /// caller waits for the same read, so none saves the list before it is
  /// in; a read that fails is tried again by the next.
  Future<void> _loadDeferred() {
    final deferred = _deferredIds;
    return deferred.load ??= _readDeferred(deferred);
  }

  Future<void> _readDeferred(_DeferredIds deferred) async {
    try {
      final raw = await db.syncMetaDao.getValue(deferredKey);
      if (raw == null || raw.isEmpty) return;
      try {
        final ids = jsonDecode(raw);
        if (ids is List) deferred.ids.addAll(ids.whereType<String>());
      } on FormatException {
        // A damaged list is dropped; the next full pass catches up.
      }
    } catch (_) {
      deferred.load = null;
      rethrow;
    }
  }

  Future<void> _saveDeferred() =>
      db.syncMetaDao.setValue(deferredKey, jsonEncode(_deferred.toList()));

  /// Fetches conversation [id] now and stores it, unless it has queued work
  /// or a reply generating. Returns whether the server has it.
  Future<bool> pullChat(String id) => _holdingDatabase(() async {
    final pushesSeen = _pushesOf(id);
    final conversation = await api.conversation(id);
    if (conversation == null) return false;
    await _adapter.storeConversation(conversation, pushesSeen: pushesSeen);
    return true;
  });

  /// Runs [work] with [db] held open, so leaving the account meanwhile
  /// cannot close it under a write.
  Future<T> _holdingDatabase<T>(Future<T> Function() work) async {
    final release = _holdDatabase?.call();
    try {
      return await work();
    } finally {
      await release?.call();
    }
  }

  /// Connectivity is back: queued changes waiting out a retry delay are due
  /// now, then the outbox runs.
  Future<void> drainNow() async {
    if (_closed) return;
    await _holdingDatabase(() async {
      await db.outboxDao.resetBackoffForPending(
        nowEpochSeconds: _clock.nowEpochSeconds(),
      );
      await drain();
    });
  }

  /// Runs the outbox: queued renames, pins, archives, deletes and sends.
  ///
  /// Completes once the work queued when it was called has run: a call made
  /// while a drain runs joins it, and one more pass follows.
  Future<void> drain() {
    if (_closed) return Future<void>.value();
    final running = _drain;
    if (running != null) {
      _drainAgain = true;
      return running;
    }
    // Set before the run starts, as a pull's.
    final run = Completer<void>();
    _drain = run.future;
    run.complete(_runDrains());
    return run.future;
  }

  Future<void> _runDrains() async {
    final before = _drainsByDatabase[db];
    final done = Completer<void>();
    _drainsByDatabase[db] = done.future;
    Future<void> Function()? release;
    try {
      // Inside the try, as a pull's: a hold that fails still clears the
      // drain.
      release = _holdDatabase?.call();
      await before;
      do {
        _drainAgain = false;
        await _drainer.drain();
      } while (_drainAgain && !_closed);
    } finally {
      // Cleared as the loop ends, before the release yields, so a call from
      // now on starts a new drain rather than joining one that will not run
      // again.
      _drain = null;
      // A push can leave a chat to fetch again (one archived here, which the
      // archived list's watermark may pass by): kept, as a pull keeps those
      // it put off, so a restart before the next pull still fetches it.
      await _keepDeferred();
      done.complete();
      await release?.call();
    }
  }

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
        await _defer(entry.id);
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

  /// The conversations deleted on the server in this run, by any engine on
  /// this database. A pull that fetched one before the delete went through
  /// must not store it again -- one an engine left behind is still running
  /// included -- and its id never comes back.
  Set<String> get _deletedOnServer =>
      _deletedByDatabase[db] ??= <String>{};

  static final Expando<Set<String>> _deletedByDatabase =
      Expando<Set<String>>('librechat-deleted');

  /// How many pushes of each conversation ended in this run, by any engine on
  /// this database. A copy of the chat read before one of them ended is older
  /// than what the push left on the server and in the chat.
  Map<String, int> get _pushes => _pushesByDatabase[db] ??= <String, int>{};

  static final Expando<Map<String, int>> _pushesByDatabase =
      Expando<Map<String, int>>('librechat-pushes');

  int _pushesOf(String id) => _pushes[id] ?? 0;

  /// Whether conversation [id] has outbox work not yet confirmed; with
  /// [besidesEnvelopeEdits], other than a rename, pin or archive still
  /// waiting to go out. One being sent counts: a copy of the chat listed
  /// before it landed would put back the baseline the push records.
  Future<bool> _hasQueuedWork(
    String id, {
    bool besidesEnvelopeEdits = false,
  }) async {
    final ops =
        await (db.select(db.outboxOps)..where(
              (t) =>
                  t.chatId.equals(id) &
                  t.status.isIn([OutboxStatus.pending, OutboxStatus.inFlight]),
            ))
            .get();
    return ops.any(
      (op) =>
          !besidesEnvelopeEdits ||
          op.kind != OutboxKind.updateChat.name ||
          op.status == OutboxStatus.inFlight,
    );
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

  /// For each conversation listed, how many of its pushes had ended when the
  /// list was read.
  final Map<String, int> _listedPushes = <String, int>{};

  static const String _pushesSeenKey = 'pushesSeen';

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
      _listedPushes.clear();
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
    _listedPushes[conversation.conversationId] = _engine._pushesOf(
      conversation.conversationId,
    );
    return SyncListItem(
      id: conversation.conversationId,
      updatedAt: conversation.updatedAt!.millisecondsSinceEpoch ~/ 1000,
    );
  }

  @override
  Future<Map<String, dynamic>?> fetchRaw(String id) async {
    final listed = _listed[id];
    final pushesSeen = listed == null
        ? _engine._pushesOf(id)
        : _listedPushes[id] ?? 0;
    final conversation = listed ?? await _engine.api.conversation(id);
    if (conversation == null) return null;
    final messages = await _engine.api.messages(id);
    return <String, dynamic>{
      'conversation': conversation.raw,
      'messages': [for (final message in messages) message.raw],
      _pushesSeenKey: pushesSeen,
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
    final pushesSeen = raw[_pushesSeenKey];
    return store(
      conversation,
      messages,
      pushesSeen: pushesSeen is int ? pushesSeen : null,
    );
  }

  /// Fetches [conversation]'s messages and stores both. [pushesSeen] as for
  /// [store].
  Future<bool> storeConversation(
    LibreChatConversation conversation, {
    int? pushesSeen,
  }) async {
    final messages = await _engine.api.messages(conversation.conversationId);
    return store(conversation, messages, pushesSeen: pushesSeen);
  }

  /// Stores [conversation] with [messages] unless local work owns it right
  /// now, in which case it is fetched again once that work is done. Returns
  /// whether local work is still owed to the server.
  ///
  /// A chat with a local envelope edit the server has not taken (one still
  /// queued, or one it refused) takes the server's messages and the fields
  /// the user did not change, but keeps the ones they did, so the edit can
  /// still be pushed or retried.
  ///
  /// [pushesSeen] is how many pushes of the chat had ended when
  /// [conversation] was read from the server. A copy read before one more
  /// ended is older than what that push left there, and is fetched again.
  Future<bool> store(
    LibreChatConversation conversation,
    List<LibreChatMessage> messages, {
    int? pushesSeen,
  }) {
    final id = conversation.conversationId;
    if (_engine._isGenerating(id)) {
      return _engine._defer(id).then((_) => false);
    }
    return _engine.locks.runExclusive(id, () async {
      // A queued send or delete holds the chat as it shows it until it is
      // through: the server's copy would undo it. So does a rename, pin or
      // archive being sent. One still waiting lets the messages in -- kept
      // below as the user left them -- or a new chat edited before its
      // first reply was saved could not be opened until the edit went
      // through.
      if (await _engine._hasQueuedWork(id, besidesEnvelopeEdits: true)) {
        await _engine._defer(id);
        return true;
      }
      if (pushesSeen != null && _engine._pushesOf(id) != pushesSeen) {
        await _engine._defer(id);
        return false;
      }
      if (_engine._deletedOnServer.contains(id)) return false;
      final existing = await _db.chatsDao.getChat(id);
      if (existing != null && existing.deleted) return true;
      final rows = LibreChatMessageMapper.chatRows(conversation, messages);
      final meta = existing == null
          ? <String, dynamic>{}
          : LibreChatSyncEngine._decode(existing.meta);
      // What the server had when the chat was last stored. A field the user
      // has not changed since still matches it, and takes the server's new
      // value: a pin waiting to go out must not undo a rename made elsewhere.
      final previous = Map<String, dynamic>.from(
        meta[kLibreChatEnvelopeBaselineKey] as Map? ?? const {},
      );
      meta[kLibreChatEnvelopeBaselineKey] = <String, dynamic>{
        'title': conversation.title,
        'pinned': conversation.pinned,
        'archived': conversation.isArchived,
      };
      // LibreChat's conversation does not carry its share link; the one the
      // app made or found stays, so the chat can still delete it.
      await _db.chatsDao.upsertServerChat(
        rows: rows,
        meta: meta,
        shareId: existing?.shareId,
      );
      if (existing == null || !existing.dirty) return false;
      await (_db.update(_db.chats)..where((t) => t.id.equals(id))).write(
        ChatsCompanion(
          title: _editedHere(previous, 'title', existing.title),
          pinned: _editedHere(previous, 'pinned', existing.pinned),
          archived: _editedHere(previous, 'archived', existing.archived),
          dirty: const Value(true),
        ),
      );
      return true;
    });
  }

  /// [local], when it is not what the server had for [field] at the last
  /// store ([previous]): an edit made here. Absent otherwise, so the server's
  /// value stands.
  static Value<T> _editedHere<T>(
    Map<String, dynamic> previous,
    String field,
    T local,
  ) => previous[field] == local ? Value<T>.absent() : Value<T>(local);

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
    try {
      await _pushEnvelopeChanges(id);
    } finally {
      // Whatever reached the server, a copy of the chat read before now is
      // older than it.
      _engine._pushes.update(id, (count) => count + 1, ifAbsent: () => 1);
    }
  }

  Future<void> _pushEnvelopeChanges(String id) async {
    // Read under the chat's lock: a pull storing the server's copy puts the
    // local edit back only after writing the server's fields, and the row
    // between the two would look like nothing to send.
    final row = await _engine.locks.runExclusive(
      id,
      () => _db.chatsDao.getChat(id),
    );
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
      await _engine._defer(id);
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

/// The conversations passed over on one database, and whether its saved
/// list has been read into them.
final class _DeferredIds {
  final Set<String> ids = <String>{};

  /// The read of the saved list, shared until it succeeds.
  Future<void>? load;
}
