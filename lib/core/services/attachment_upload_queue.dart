import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import '../database/app_database.dart';
import '../database/daos/attachment_queue_dao.dart';
import '../utils/debug_logger.dart';
import 'share_staging_cleanup.dart';

const Object _queuedAttachmentUnset = Object();

/// Status of a queued attachment upload
enum QueuedAttachmentStatus { pending, uploading, completed, failed, cancelled }

/// Metadata for a queued attachment
class QueuedAttachment {
  final String id; // local queue id
  final String filePath;
  final String fileName;
  final int fileSize;
  final String? mimeType;
  final String? checksum;
  final String? durableKey;
  final DateTime enqueuedAt;

  // Upload state
  int retryCount;
  DateTime? nextRetryAt;
  QueuedAttachmentStatus status;
  String? lastError;
  String? fileId; // server-side file id once uploaded
  bool receiptHeld;

  QueuedAttachment({
    required this.id,
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    this.mimeType,
    this.checksum,
    this.durableKey,
    DateTime? enqueuedAt,
    this.retryCount = 0,
    this.nextRetryAt,
    this.status = QueuedAttachmentStatus.pending,
    this.lastError,
    this.fileId,
    this.receiptHeld = false,
  }) : enqueuedAt = enqueuedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'filePath': filePath,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
    'checksum': checksum,
    'durableKey': durableKey,
    'enqueuedAt': enqueuedAt.toIso8601String(),
    'retryCount': retryCount,
    'nextRetryAt': nextRetryAt?.toIso8601String(),
    'status': status.name,
    'lastError': lastError,
    'fileId': fileId,
    'receiptHeld': receiptHeld,
  };

  factory QueuedAttachment.fromJson(Map<String, dynamic> json) =>
      QueuedAttachment(
        id: json['id'] as String,
        filePath: json['filePath'] as String,
        fileName: json['fileName'] as String,
        fileSize: (json['fileSize'] as num).toInt(),
        mimeType: json['mimeType'] as String?,
        checksum: json['checksum'] as String?,
        durableKey: json['durableKey'] as String?,
        enqueuedAt:
            DateTime.tryParse(json['enqueuedAt'] ?? '') ?? DateTime.now(),
        retryCount: (json['retryCount'] as num?)?.toInt() ?? 0,
        nextRetryAt: json['nextRetryAt'] != null
            ? DateTime.tryParse(json['nextRetryAt'])
            : null,
        status: QueuedAttachmentStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => QueuedAttachmentStatus.pending,
        ),
        lastError: json['lastError'] as String?,
        fileId: json['fileId'] as String?,
        receiptHeld: json['receiptHeld'] == true,
      );

  QueuedAttachment copyWith({
    int? retryCount,
    Object? nextRetryAt = _queuedAttachmentUnset,
    QueuedAttachmentStatus? status,
    Object? lastError = _queuedAttachmentUnset,
    Object? fileId = _queuedAttachmentUnset,
  }) => QueuedAttachment(
    id: id,
    filePath: filePath,
    fileName: fileName,
    fileSize: fileSize,
    mimeType: mimeType,
    checksum: checksum,
    durableKey: durableKey,
    enqueuedAt: enqueuedAt,
    retryCount: retryCount ?? this.retryCount,
    nextRetryAt: identical(nextRetryAt, _queuedAttachmentUnset)
        ? this.nextRetryAt
        : nextRetryAt as DateTime?,
    status: status ?? this.status,
    lastError: identical(lastError, _queuedAttachmentUnset)
        ? this.lastError
        : lastError as String?,
    fileId: identical(fileId, _queuedAttachmentUnset)
        ? this.fileId
        : fileId as String?,
    receiptHeld: receiptHeld,
  );
}

/// Result of an idempotent durable enqueue.
///
/// [inserted] is false when an earlier process/attempt already persisted the
/// exact [QueuedAttachment.durableKey]. The caller must then join that row
/// instead of creating a second non-idempotent server upload.
typedef DurableAttachmentEnqueueResult = ({
  QueuedAttachment item,
  bool inserted,
});

typedef UploadCallback =
    Future<String> Function(
      String filePath,
      String fileName, {
      CancelToken? cancelToken,
    });
typedef AttachmentsEventCallback = void Function(List<QueuedAttachment> queue);
typedef _TerminalAttachmentCleanupWithAdmission =
    Future<bool> Function(
      String filePath, {
      required Future<void> Function() beforeDeleteAdmission,
      required bool Function() canDelete,
    });

Future<bool> _cleanupTerminalAttachmentWithAdmission(
  String filePath, {
  required Future<void> Function() beforeDeleteAdmission,
  required bool Function() canDelete,
}) {
  return cleanupTerminalAttachmentFile(
    filePath,
    beforeDeleteAdmission: (_) => beforeDeleteAdmission(),
    canDelete: (_) => canDelete(),
  );
}

_TerminalAttachmentCleanupWithAdmission _adaptTerminalAttachmentCleanup(
  TerminalAttachmentCleanup cleanup,
) {
  return (
    String filePath, {
    required Future<void> Function() beforeDeleteAdmission,
    required bool Function() canDelete,
  }) async {
    await beforeDeleteAdmission();
    if (!canDelete()) {
      // The durable terminal row no longer owns this pathname. Match the
      // production cleanup contract: the row may be discarded while the
      // replacement bytes deliberately remain untouched.
      return true;
    }
    return cleanup(filePath);
  };
}

enum _RestoredIdentityState { unchecked, matches, differs, indeterminate }

/// Content-identity admission for a terminal row restored after process death.
///
/// Hashing is asynchronous and streaming. The final synchronous stat check is
/// intentionally adjacent to the cleanup helper's synchronous unlink, closing
/// the in-process replacement gap without retaining whole iOS media files.
final class _RestoredAttachmentIdentityAdmission {
  _RestoredAttachmentIdentityAdmission(this.item);

  static final RegExp _canonicalSha256 = RegExp(r'^[0-9a-fA-F]{64}$');

  final QueuedAttachment item;
  _RestoredIdentityState state = _RestoredIdentityState.unchecked;
  FileStat? _verifiedStat;
  bool _verifiedAbsent = false;

  bool get hasDurableIdentity {
    final checksum = item.checksum;
    return checksum != null && _canonicalSha256.hasMatch(checksum);
  }

  Future<void> verifyBeforeDelete() async {
    state = _RestoredIdentityState.unchecked;
    _verifiedStat = null;
    _verifiedAbsent = false;
    if (!hasDurableIdentity) {
      state = _RestoredIdentityState.differs;
      return;
    }

    try {
      final initialType = await FileSystemEntity.type(
        item.filePath,
        followLinks: false,
      );
      if (initialType == FileSystemEntityType.notFound) {
        _verifiedAbsent = true;
        state = _RestoredIdentityState.matches;
        return;
      }
      if (initialType != FileSystemEntityType.file) {
        state = _RestoredIdentityState.differs;
        return;
      }

      final file = File(item.filePath);
      final before = await file.stat();
      if (before.type != FileSystemEntityType.file ||
          before.size != item.fileSize) {
        state = _RestoredIdentityState.differs;
        return;
      }
      final digest = (await sha256.bind(file.openRead()).first).toString();
      final afterType = await FileSystemEntity.type(
        item.filePath,
        followLinks: false,
      );
      final after = await file.stat();
      if (afterType != FileSystemEntityType.file ||
          !_sameFileSnapshot(before, after) ||
          digest.toLowerCase() != item.checksum!.toLowerCase()) {
        state = _RestoredIdentityState.differs;
        return;
      }
      _verifiedStat = after;
      state = _RestoredIdentityState.matches;
    } on FileSystemException {
      state = _RestoredIdentityState.indeterminate;
    }
  }

  bool canDeleteNow() {
    if (state != _RestoredIdentityState.matches) return false;
    try {
      final currentType = FileSystemEntity.typeSync(
        item.filePath,
        followLinks: false,
      );
      if (_verifiedAbsent) {
        return currentType == FileSystemEntityType.notFound;
      }
      final verified = _verifiedStat;
      return verified != null &&
          currentType == FileSystemEntityType.file &&
          _sameFileSnapshot(verified, File(item.filePath).statSync());
    } on FileSystemException {
      state = _RestoredIdentityState.indeterminate;
      return false;
    }
  }

  static bool _sameFileSnapshot(FileStat first, FileStat second) {
    return first.type == second.type &&
        first.size == second.size &&
        first.mode == second.mode &&
        first.modified == second.modified &&
        first.changed == second.changed;
  }
}

/// A lightweight background queue to upload attachments when back online.
///
/// One instance per active server, owned by `attachmentUploadQueueProvider`,
/// which constructs it, awaits [initialize], and [dispose]s it (closing the
/// stream and cancelling in-flight uploads) when the server changes.
class AttachmentUploadQueue {
  AttachmentUploadQueue({
    DateTime Function()? now,
    Random? random,
    String Function()? idGenerator,
    TerminalAttachmentCleanup? terminalAttachmentCleanup,
    Future<void> Function()? initialLoadBarrier,
    int maxRetries = _defaultMaxRetries,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random(),
       _idGenerator = idGenerator ?? const Uuid().v4,
       _terminalAttachmentCleanup = terminalAttachmentCleanup == null
           ? _cleanupTerminalAttachmentWithAdmission
           : _adaptTerminalAttachmentCleanup(terminalAttachmentCleanup),
       _initialLoadBarrier = initialLoadBarrier,
       _maxRetries = maxRetries,
       assert(maxRetries > 0);

  static const int _defaultMaxRetries = 4;
  static const Duration _baseRetryDelay = Duration(seconds: 5);
  static const Duration _maxRetryDelay = Duration(minutes: 5);
  static const String _interruptedUploadError =
      'Upload was interrupted after it started; automatic retry is disabled '
      'because the server outcome is unknown.';

  /// Resolves the active server's Drift database. Re-supplied on each
  /// [initialize] (the owning provider re-runs on server switch), so the queue
  /// reloads and persists against the active server's `attachment_queue` table.
  AppDatabase? Function()? _databaseResolver;
  final DateTime Function() _now;
  final Random _random;
  final String Function() _idGenerator;
  final _TerminalAttachmentCleanupWithAdmission _terminalAttachmentCleanup;
  final Future<void> Function()? _initialLoadBarrier;
  final int _maxRetries;
  final List<QueuedAttachment> _queue = [];
  final Set<String> _initialPersistencePendingIds = <String>{};
  final Map<String, int> _consecutiveTransportFailures = <String, int>{};
  Timer? _retryTimer;
  bool _isProcessing = false;
  final Map<String, CancelToken> _cancelTokens = <String, CancelToken>{};
  final Set<String> _ownerHeldIds = <String>{};
  final Set<String> _removalPendingIds = <String>{};

  // Dependencies
  UploadCallback? _onUpload;
  AttachmentsEventCallback? _onQueueChanged;

  // Streams
  final _queueController = StreamController<List<QueuedAttachment>>.broadcast();
  Stream<List<QueuedAttachment>> get queueStream => _queueController.stream;

  bool _disposed = false;
  Future<void>? _readyFuture;
  Future<void> _persistenceTail = Future<void>.value();

  List<QueuedAttachment> get queue => List.unmodifiable(_queue);

  /// Completes once the initial load from Drift has finished (or immediately if
  /// [initialize] has not run). Callers `await` this before enqueueing so an
  /// upload never races the load. It is owned by this instance (not the owning
  /// provider), so it can never be orphaned by the provider rebuilding — unlike
  /// a `FutureProvider.future`, awaiting it cannot hang across a server switch.
  Future<void> get ready => _readyFuture ?? Future<void>.value();

  Future<void> initialize({
    required UploadCallback onUpload,
    required AppDatabase? Function() database,
    AttachmentsEventCallback? onQueueChanged,
  }) {
    _onUpload = onUpload;
    _onQueueChanged = onQueueChanged;
    _databaseResolver = database;
    final future = _initInternal();
    _readyFuture = future;
    return future;
  }

  Future<void> _initInternal() async {
    try {
      await _initialLoadBarrier?.call();
      await _load();
      if (_disposed) return;
      // Replay durable terminal outcomes before any restore-time cleanup. A
      // consumer may need the completed file ID or failure state to settle its
      // own UI. Cleanup may release the staging bytes, but the row itself stays
      // durable until that consumer explicitly acknowledges it.
      _notify();
      await _cleanupRestoredTerminalEntries();
      _scheduleNextProcessing();
      DebugLogger.log(
        'AttachmentUploadQueue initialized with ${_queue.length} items',
        scope: 'attachments/queue',
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'attachment-queue-init-failed',
        scope: 'attachments/queue',
        error: error,
        stackTrace: stackTrace,
      );
      // Preserve the failure on `ready`: callers must abort before enqueueing,
      // otherwise enqueueing after a partial load could mix an incomplete
      // in-memory snapshot with the persisted queue.
      rethrow;
    }
  }

  AttachmentQueueDao? get _attachmentDao =>
      _databaseResolver?.call()?.attachmentQueueDao;

  Future<String> enqueue({
    required String filePath,
    required String fileName,
    required int fileSize,
    String? mimeType,
    String? checksum,
    bool holdForOwner = false,
    String? durableKey,
    bool receiptHeld = false,
  }) async {
    final result = await enqueueOrJoin(
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      checksum: checksum,
      holdForOwner: holdForOwner,
      durableKey: durableKey,
      receiptHeld: receiptHeld,
    );
    return result.item.id;
  }

  /// Persists a new upload or joins the row that already owns [durableKey].
  ///
  /// The lookup and in-memory insertion run without an await between them, so
  /// concurrent callers in this isolate cannot both pass the admission check.
  /// The database UNIQUE constraint is the final cross-process guard.
  Future<DurableAttachmentEnqueueResult> enqueueOrJoin({
    required String filePath,
    required String fileName,
    required int fileSize,
    String? mimeType,
    String? checksum,
    bool holdForOwner = false,
    String? durableKey,
    bool receiptHeld = false,
  }) async {
    if (_disposed) {
      // The queue was torn down (server switch / logout). Fail loudly rather
      // than adding an item that persistence/notification/processing skip;
      // that would look enqueued but silently never persist or upload.
      throw StateError('Cannot enqueue on a disposed AttachmentUploadQueue');
    }
    if (durableKey != null && durableKey.isEmpty) {
      throw ArgumentError.value(durableKey, 'durableKey', 'must not be empty');
    }
    if (durableKey != null) {
      final existing = _queue
          .where((item) => item.durableKey == durableKey)
          .firstOrNull;
      if (existing != null) {
        // Durable keys are content-independent (native payload id + item
        // ordinal): in-place image conversion re-encodes re-delivered payload
        // bytes, so size/checksum may legitimately differ while the existing
        // row still owns this exact share item. Join it; a second row would
        // duplicate a non-idempotent server upload.
        if (existing.fileSize != fileSize || existing.checksum != checksum) {
          DebugLogger.warning(
            'durable-attachment-join-metadata-differs',
            scope: 'attachments/queue',
            data: {'id': existing.id},
          );
        }
        return (item: existing, inserted: false);
      }
    }
    final enqueuedAt = _now();
    final id = _idGenerator();
    final item = QueuedAttachment(
      id: id,
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      checksum: checksum,
      durableKey: durableKey,
      enqueuedAt: enqueuedAt,
      status: QueuedAttachmentStatus.pending,
      receiptHeld: receiptHeld,
    );
    _queue.add(item);
    if (holdForOwner) _ownerHeldIds.add(item.id);
    _initialPersistencePendingIds.add(item.id);
    try {
      await _persist(item);
    } catch (_) {
      // A row must never remain runnable in memory when its first durable
      // insert fails. Remove only this exact enqueue snapshot: a concurrent
      // mutation may already have superseded it.
      _queue.removeWhere((current) => identical(current, item));
      _ownerHeldIds.remove(item.id);
      _initialPersistencePendingIds.remove(item.id);
      _scheduleNextProcessing();
      rethrow;
    }
    _initialPersistencePendingIds.remove(item.id);
    _notify();
    _processSafe();
    return (item: item, inserted: true);
  }

  /// Releases an enqueue held while its caller installs cancellation and UI
  /// ownership. Held rows are durable but cannot start network I/O.
  void releaseOwnerHold(String id) {
    if (!_ownerHeldIds.remove(id)) return;
    _processSafe();
  }

  Future<void> processQueue() async {
    if (_isProcessing) return;
    if (_onUpload == null) return;

    _isProcessing = true;
    try {
      final now = _now();
      final pending = _queue.where(
        (e) =>
            !_initialPersistencePendingIds.contains(e.id) &&
            !_ownerHeldIds.contains(e.id) &&
            !_removalPendingIds.contains(e.id) &&
            e.status == QueuedAttachmentStatus.pending &&
            (e.nextRetryAt == null || !now.isBefore(e.nextRetryAt!)),
      );

      for (final item in List<QueuedAttachment>.from(pending)) {
        await _processSingle(item);
      }
    } finally {
      _isProcessing = false;
      _scheduleNextProcessing();
    }
  }

  Future<void> _processSingle(QueuedAttachment item) async {
    if (_onUpload == null) return;
    // [processQueue] snapshots pending rows before awaiting each upload. A
    // later row may be removed, cancelled, cleared, or retried while an earlier
    // upload is in flight; only the exact still-current snapshot may start.
    if (_initialPersistencePendingIds.contains(item.id) ||
        _ownerHeldIds.contains(item.id) ||
        _removalPendingIds.contains(item.id) ||
        !_isCurrent(item) ||
        item.status != QueuedAttachmentStatus.pending ||
        _isCancelled(item.id)) {
      return;
    }
    final cancelToken = CancelToken();
    _cancelTokens[item.id] = cancelToken;
    final uploading = item.copyWith(status: QueuedAttachmentStatus.uploading);
    try {
      _update(item.id, uploading);
      final uploadingPersisted = await _persistTransitionAndNotify(
        uploading,
        failureEvent: 'attachment-uploading-persistence-failed',
      );
      if (!uploadingPersisted) {
        // Never start network I/O unless the indeterminate in-flight state is
        // durable. Try to publish a terminal local failure; even if that second
        // write also fails, listeners settle and no upload can be duplicated.
        final failed = item.copyWith(
          status: QueuedAttachmentStatus.failed,
          nextRetryAt: null,
          lastError: 'Could not persist attachment upload state.',
        );
        _update(item.id, failed);
        await _persistTransitionAndNotify(
          failed,
          failureEvent: 'attachment-failed-persistence-failed',
        );
        return;
      }
      if (cancelToken.isCancelled || !_isCurrent(uploading)) return;

      final fileId = await _onUpload!.call(
        item.filePath,
        item.fileName,
        cancelToken: cancelToken,
      );
      if (cancelToken.isCancelled || !_isCurrent(uploading)) {
        return;
      }

      final completed = item.copyWith(
        status: QueuedAttachmentStatus.completed,
        fileId: fileId,
        retryCount: 0,
        nextRetryAt: null,
        lastError: null,
      );
      _consecutiveTransportFailures.remove(item.id);
      _update(item.id, completed);
      final completedPersisted = await _persistTransitionAndNotify(
        completed,
        failureEvent: 'attachment-terminal-persistence-failed',
      );
      if (!completedPersisted) {
        // The server upload has already succeeded. Never route a terminal
        // storage failure through the upload retry logic: that could upload the
        // same bytes twice, and replacing [uploading] with [completed] makes the
        // outer catch's stale-snapshot guard intentionally reject it. The
        // helper already published the terminal result so the media controller
        // can consume the file ID and acknowledge/delete the stale durable row.
        // If the process exits first, restored `uploading` rows are treated as
        // indeterminate below.
        return;
      }
      DebugLogger.log(
        'Attachment ${item.id} uploaded successfully',
        scope: 'attachments/queue',
      );
    } catch (e) {
      if (cancelToken.isCancelled || _isCancelled(item.id)) {
        await _markCancelled(item.id);
        return;
      }
      if (!_isCurrent(uploading)) return;

      if (_isIndeterminateUploadFailure(e)) {
        // Open WebUI's upload route creates a fresh UUID for every request and
        // does not support idempotency keys or duplicate reconciliation. A
        // timeout/error after bytes may have been sent therefore cannot be
        // retried safely: doing so can create duplicate server files. Preserve
        // the row as failed so the user can inspect and explicitly retry it.
        _consecutiveTransportFailures.remove(item.id);
        final failed = item.copyWith(
          status: QueuedAttachmentStatus.failed,
          nextRetryAt: null,
          lastError:
              'Upload outcome is indeterminate; automatic retry '
              'disabled: $e',
        );
        _update(item.id, failed);
        await _persistTransitionAndNotify(
          failed,
          failureEvent: 'attachment-failed-persistence-failed',
        );
        DebugLogger.warning(
          'Attachment ${item.id} may already exist on the server; automatic '
          'retry disabled',
          scope: 'attachments/queue',
        );
        return;
      }

      if (_isSafeTransientTransportFailure(e)) {
        // Connectivity failures are not evidence that the attachment itself is
        // bad. Keep it durably pending without consuming its finite retry
        // budget, while still assigning a future deadline to prevent a hot
        // process/fail loop when the network remains unavailable.
        final consecutiveFailures =
            (_consecutiveTransportFailures[item.id] ?? 0) + 1;
        _consecutiveTransportFailures[item.id] = consecutiveFailures;
        final delay = _retryDelayWithJitter(consecutiveFailures);
        final pendingTransportRetry = item.copyWith(
          status: QueuedAttachmentStatus.pending,
          retryCount: item.retryCount,
          nextRetryAt: _now().add(delay),
          lastError: e.toString(),
        );
        _update(item.id, pendingTransportRetry);
        await _persistTransitionAndNotify(
          pendingTransportRetry,
          failureEvent: 'attachment-retry-persistence-failed',
        );
        DebugLogger.log(
          'Deferred attachment ${item.id} until transport recovers',
          scope: 'attachments/queue',
        );
        return;
      }

      _consecutiveTransportFailures.remove(item.id);
      final retries = item.retryCount + 1;
      if (retries >= _maxRetries) {
        final failed = item.copyWith(
          status: QueuedAttachmentStatus.failed,
          retryCount: retries,
          nextRetryAt: null,
          lastError: e.toString(),
        );
        _update(item.id, failed);
        await _persistTransitionAndNotify(
          failed,
          failureEvent: 'attachment-failed-persistence-failed',
        );
        DebugLogger.log(
          'WARNING: Attachment ${item.id} failed after $_maxRetries attempts',
          scope: 'attachments/queue',
        );
        return;
      }

      final delay = _retryDelayWithJitter(retries);
      final pendingRetry = item.copyWith(
        status: QueuedAttachmentStatus.pending,
        retryCount: retries,
        nextRetryAt: _now().add(delay),
        lastError: e.toString(),
      );
      _update(item.id, pendingRetry);
      await _persistTransitionAndNotify(
        pendingRetry,
        failureEvent: 'attachment-retry-persistence-failed',
      );
      DebugLogger.log(
        'Scheduled retry for attachment ${item.id} in ${delay.inSeconds}s',
        scope: 'attachments/queue',
      );
    } finally {
      _cancelTokens.remove(item.id);
    }
  }

  bool _isSafeTransientTransportFailure(Object error) {
    if (error is! DioException) return false;
    // These failures surface before a connection to the server is established,
    // so no request byte can have reached the upload route and the server
    // cannot hold the file. They are pure connectivity outages: keep the row
    // pending and defer (without consuming the retry budget) so the upload
    // resumes when the network returns.
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.unknown =>
        error.error is SocketException || error.error is HandshakeException,
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout ||
      DioExceptionType.badCertificate ||
      DioExceptionType.badResponse ||
      DioExceptionType.cancel => false,
    };
  }

  bool _isIndeterminateUploadFailure(Object error) {
    // Pre-connection connectivity failures are never indeterminate: bytes were
    // not sent, so the "server may already hold the file" rationale does not
    // apply. Classify them first so they take the safe deferral path.
    if (_isSafeTransientTransportFailure(error)) return false;
    if (_isTransientIoFailure(error)) return true;
    if (error is! DioException) return false;
    return switch (error.type) {
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout => true,
      DioExceptionType.unknown => _isTransientIoFailure(error.error),
      DioExceptionType.connectionTimeout ||
      DioExceptionType.connectionError ||
      DioExceptionType.badCertificate ||
      DioExceptionType.badResponse ||
      DioExceptionType.cancel => false,
    };
  }

  bool _isTransientIoFailure(Object? error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException ||
      error is HttpException;

  Duration _retryDelayWithJitter(int retryCount) {
    final base = _baseRetryDelay.inMilliseconds;
    final exp = min(
      base * pow(2, retryCount - 1),
      _maxRetryDelay.inMilliseconds.toDouble(),
    ).toInt();
    final jitter = _random.nextInt(1000); // up to 1s jitter
    return Duration(milliseconds: exp + jitter);
  }

  void _scheduleNextProcessing({bool immediate = false}) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_disposed || _isProcessing) return;

    final pending = _queue.where(
      (item) =>
          !_initialPersistencePendingIds.contains(item.id) &&
          !_ownerHeldIds.contains(item.id) &&
          !_removalPendingIds.contains(item.id) &&
          item.status == QueuedAttachmentStatus.pending,
    );
    if (pending.isEmpty) return;

    final now = _now();
    Duration? delay;
    for (final item in pending) {
      final candidate = immediate || item.nextRetryAt == null
          ? Duration.zero
          : item.nextRetryAt!.difference(now);
      final normalized = candidate.isNegative ? Duration.zero : candidate;
      if (delay == null || normalized < delay) delay = normalized;
    }
    _retryTimer = Timer(delay ?? Duration.zero, _processSafe);
  }

  /// Tears down this per-server queue instance.
  ///
  /// The owning `attachmentUploadQueueProvider` calls this via `ref.onDispose`
  /// when the active server changes (server switch / logout). Cancels the
  /// pending retry timer, aborts in-flight uploads via their [CancelToken]s (so
  /// nothing completes against the account just left), and closes [queueStream]
  /// so any listener awaiting an upload (e.g. a `MediaUploadController`
  /// completer) resolves via `onDone` instead of hanging. Persisted queue rows
  /// are left untouched: the next server-scoped instance reloads and resumes
  /// them from that server's Drift table. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    for (final token in _cancelTokens.values) {
      token.cancel('attachment queue disposed');
    }
    _cancelTokens.clear();
    _ownerHeldIds.clear();
    _removalPendingIds.clear();
    _consecutiveTransportFailures.clear();
    _onUpload = null;
    _onQueueChanged = null;
    _databaseResolver = null;
    _queueController.close();
    DebugLogger.log(
      'AttachmentUploadQueue disposed',
      scope: 'attachments/queue',
    );
  }

  void _processSafe() {
    if (_disposed) return;
    unawaited(
      processQueue().catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'attachment-queue-processing-failed',
          scope: 'attachments/queue',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  void _update(String id, QueuedAttachment updated) {
    final idx = _queue.indexWhere((e) => e.id == id);
    if (idx != -1) {
      _queue[idx] = updated;
    }
  }

  bool _isCancelled(String id) {
    final idx = _queue.indexWhere((e) => e.id == id);
    return idx != -1 && _queue[idx].status == QueuedAttachmentStatus.cancelled;
  }

  bool _isCurrent(QueuedAttachment expected) =>
      _queue.any((item) => identical(item, expected));

  Future<bool> _markCancelled(String id) async {
    final idx = _queue.indexWhere((e) => e.id == id);
    if (idx == -1) return false;
    final current = _queue[idx];
    if (current.status != QueuedAttachmentStatus.pending &&
        current.status != QueuedAttachmentStatus.uploading) {
      // Completion publishes fileId in memory before its serialized Drift
      // write settles. A concurrent cancellation must join that terminal owner
      // instead of replacing it with a cancelled row and losing the fileId.
      return current.status == QueuedAttachmentStatus.completed ||
          current.status == QueuedAttachmentStatus.failed ||
          current.status == QueuedAttachmentStatus.cancelled;
    }
    _queue[idx] = current.copyWith(
      status: QueuedAttachmentStatus.cancelled,
      nextRetryAt: null,
      lastError: 'cancelled',
    );
    _consecutiveTransportFailures.remove(id);
    final persisted = await _persistTransitionAndNotify(
      _queue[idx],
      failureEvent: 'attachment-cancel-persistence-failed',
    );
    _scheduleNextProcessing();
    return persisted;
  }

  Future<void> remove(String id) async {
    // Fail before mutating the live snapshot when its durable owner has gone
    // away unexpectedly. The persisted row can then be recovered on restart.
    _resolveAttachmentDaoForPersistence();
    final ownsLiveRow = _queue.any((item) => item.id == id);
    if (ownsLiveRow) {
      // Tombstone before awaiting Drift. A failed delete must leave a live,
      // non-runnable owner that [cancel] can durably transition instead of an
      // orphaned pending row that replays after restart.
      _removalPendingIds.add(id);
      _ownerHeldIds.add(id);
    }
    _cancelTokens.remove(id)?.cancel('Upload removed');
    await _deletePersisted(id);
    _queue.removeWhere((e) => e.id == id);
    _removalPendingIds.remove(id);
    _ownerHeldIds.remove(id);
    _consecutiveTransportFailures.remove(id);
    _notify();
    _scheduleNextProcessing();
  }

  Future<bool> cancel(String id) async {
    _removalPendingIds.remove(id);
    _ownerHeldIds.remove(id);
    _cancelTokens.remove(id)?.cancel('Upload cancelled');
    final persisted = await _markCancelled(id);
    if (!persisted && _queue.any((item) => item.id == id)) {
      // The durable row may still be pending. Keep its live counterpart
      // tombstoned so no work starts until a later durable mutation resolves
      // the uncertainty.
      _removalPendingIds.add(id);
      _ownerHeldIds.add(id);
    }
    return persisted;
  }

  Future<void> retry(String id) async {
    final idx = _queue.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    final failed = _queue[idx];
    // Only an explicitly failed request has a retryable terminal outcome.
    // Superseding pending/uploading/completed state can discard a live server
    // response and issue the same non-idempotent upload a second time.
    if (failed.status != QueuedAttachmentStatus.failed) return;
    _removalPendingIds.remove(id);
    _ownerHeldIds.remove(id);
    final pending = failed.copyWith(
      status: QueuedAttachmentStatus.pending,
      retryCount: 0,
      nextRetryAt: null,
      lastError: null,
    );
    _queue[idx] = pending;
    _initialPersistencePendingIds.add(id);
    _consecutiveTransportFailures.remove(id);
    try {
      await _persist(pending);
    } catch (_) {
      // Keep the last durable terminal snapshot live when its retry transition
      // could not be stored. It must not become runnable after another queue
      // mutation wakes processing.
      if (_isCurrent(pending)) _update(id, failed);
      rethrow;
    } finally {
      _initialPersistencePendingIds.remove(id);
    }
    _notify();
    _processSafe();
  }

  Future<void> clearFailed() async {
    final ids = _queue
        .where((e) => e.status == QueuedAttachmentStatus.failed)
        .map((e) => e.id)
        .toList(growable: false);
    if (ids.isEmpty) return;
    _resolveDatabaseForPersistence();
    _removalPendingIds.addAll(ids);
    _ownerHeldIds.addAll(ids);
    await _deletePersistedBatch(ids);
    final idSet = ids.toSet();
    _queue.removeWhere((e) => idSet.contains(e.id));
    for (final id in ids) {
      _removalPendingIds.remove(id);
      _consecutiveTransportFailures.remove(id);
      _ownerHeldIds.remove(id);
    }
    _notify();
  }

  Future<void> clearAll() async {
    final dao = _resolveAttachmentDaoForPersistence();
    final ids = _queue.map((item) => item.id).toList(growable: false);
    _retryTimer?.cancel();
    _retryTimer = null;
    _removalPendingIds.addAll(ids);
    _ownerHeldIds.addAll(ids);
    for (final id in ids) {
      _cancelTokens.remove(id)?.cancel('Attachment queue cleared');
    }
    await _serializePersistence(() async {
      if (dao == null) return;
      await dao.clearAll();
    });
    final idSet = ids.toSet();
    _queue.removeWhere((item) => idSet.contains(item.id));
    for (final id in ids) {
      _removalPendingIds.remove(id);
      _ownerHeldIds.remove(id);
      _consecutiveTransportFailures.remove(id);
    }
    _notify();
    _scheduleNextProcessing();
  }

  /// Removes a terminal entry after its consumer has reflected the result.
  ///
  /// The media controller calls this only after app-owned staging cleanup is
  /// confirmed. If cleanup fails, leaving the row unacknowledged preserves the
  /// only durable path needed to retry on a later launch.
  Future<void> acknowledgeTerminal(String id) async {
    final index = _queue.indexWhere((item) => item.id == id);
    if (index == -1) return;
    final item = _queue[index];
    final status = item.status;
    if (status != QueuedAttachmentStatus.completed &&
        status != QueuedAttachmentStatus.failed &&
        status != QueuedAttachmentStatus.cancelled) {
      return;
    }
    // Native storage is still the recovery oracle until its exact-ID ack
    // succeeds. Retain this terminal row as a dedupe receipt so a crash/retry
    // cannot issue the same non-idempotent server upload twice.
    if (item.receiptHeld) return;
    _resolveAttachmentDaoForPersistence();
    _removalPendingIds.add(id);
    _ownerHeldIds.add(id);
    await _deletePersisted(id);
    _queue.removeWhere((item) => item.id == id);
    _removalPendingIds.remove(id);
    _ownerHeldIds.remove(id);
    _consecutiveTransportFailures.remove(id);
    _notify();
  }

  /// Releases native-import receipts only after the native exact-ID ack.
  ///
  /// Active rows keep uploading with the same object identity (important for
  /// in-flight transition fences); terminal rows are pruned immediately. If a
  /// persistence write fails after native ack, the old `receiptHeld=true` row
  /// remains on disk, which may leak a receipt but cannot duplicate or lose
  /// the attachment.
  Future<void> releaseDurableReceipts(Iterable<String> durableKeys) async {
    final keys = durableKeys.where((key) => key.isNotEmpty).toSet();
    if (keys.isEmpty) return;
    _resolveAttachmentDaoForPersistence();

    final released = <QueuedAttachment>[];
    for (final item in _queue) {
      if (!keys.contains(item.durableKey) || !item.receiptHeld) continue;
      item.receiptHeld = false;
      released.add(item);
    }
    if (released.isEmpty) return;

    try {
      // Serialize each upsert with upload transitions. _persist snapshots the
      // latest mutable status inside the persistence turn, so releasing a
      // receipt cannot overwrite a concurrent completed/failed transition.
      for (final item in released) {
        await _persist(item);
      }
    } catch (_) {
      // Restore the conservative in-memory state to match the durable receipt.
      // A later explicit release can retry; pruning early would be unsafe.
      for (final item in released) {
        if (_queue.any((current) => identical(current, item))) {
          item.receiptHeld = true;
        }
      }
      rethrow;
    }

    for (final item in released.toList(growable: false)) {
      await acknowledgeTerminal(item.id);
    }
    _notify();
    _processSafe();
  }

  // Utilities
  Future<void> _load() async {
    final dao = _resolveAttachmentDaoForPersistence();
    if (dao == null) return;
    final rows = await dao.getAll();
    // Stage the full conversion before replacing the in-memory queue. If the
    // read or JSON conversion fails, `ready` rejects and the existing snapshot
    // remains intact — a later enqueue cannot mirror a partial/empty snapshot
    // over the persisted table.
    final loaded = rows
        .map(_rowToModel)
        .map(
          (item) => item.status == QueuedAttachmentStatus.uploading
              // A process death can happen after the server accepted the file
              // but before the terminal row was persisted. Retrying an
              // `uploading` row automatically can therefore create a duplicate
              // Open WebUI file; require explicit recovery instead.
              ? item.copyWith(
                  status: QueuedAttachmentStatus.failed,
                  nextRetryAt: null,
                  lastError: _interruptedUploadError,
                )
              : item,
        )
        .toList(growable: false);
    _queue
      ..clear()
      ..addAll(loaded);
    _ownerHeldIds.clear();
    _removalPendingIds.clear();
  }

  Future<void> _persist(QueuedAttachment item) async {
    // Resolve the owning database before joining the persistence queue. The
    // provider may dispose this queue while an earlier write is still draining;
    // clearing the resolver must not silently drop an already-submitted write.
    final dao = _resolveAttachmentDaoForPersistence();
    await _serializePersistence(() async {
      // A clear/remove/cancel may have superseded this write while an upload
      // callback was settling. Only the exact current row may reach Drift.
      if (_removalPendingIds.contains(item.id) ||
          !_queue.any((current) => identical(current, item))) {
        return;
      }
      if (dao == null) {
        // The queue was disposed (server switch / logout) before this write
        // could resolve its dao. Reporting success here would let callers
        // treat unpersisted state — notably a cancellation — as durable and
        // delete staged bytes that the old server's still-pending row needs
        // when it is next restored.
        throw StateError(
          'Attachment queue persistence is unavailable after dispose',
        );
      }
      await dao.upsert(_modelToCompanion(item));
    });
  }

  /// Persists a live state transition and publishes it even when Drift rejects
  /// the write. Once a network operation has started, withholding the terminal
  /// snapshot would strand MediaUploadController listeners forever. Restored
  /// `uploading` rows fail closed, so publishing the in-memory state cannot
  /// create an automatic duplicate after restart.
  Future<bool> _persistTransitionAndNotify(
    QueuedAttachment item, {
    required String failureEvent,
  }) async {
    try {
      await _persist(item);
      _notify();
      return true;
    } catch (error) {
      _notify();
      DebugLogger.warning(
        failureEvent,
        scope: 'attachments/queue',
        data: {
          'id': item.id,
          'status': item.status.name,
          'errorType': error.runtimeType.toString(),
        },
      );
      return false;
    }
  }

  Future<void> _deletePersisted(String id) async {
    final dao = _resolveAttachmentDaoForPersistence();
    await _serializePersistence(() async {
      if (dao == null) return;
      await dao.deleteById(id);
    });
  }

  Future<void> _deletePersistedBatch(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = _resolveDatabaseForPersistence();
    await _serializePersistence(() async {
      if (db == null) return;
      await db.transaction(() async {
        for (final id in ids) {
          await db.attachmentQueueDao.deleteById(id);
        }
      });
    });
  }

  AttachmentQueueDao? _resolveAttachmentDaoForPersistence() {
    if (_disposed) return null;
    final dao = _attachmentDao;
    if (dao == null) {
      throw StateError(
        'Attachment queue persistence is unavailable for a live operation',
      );
    }
    return dao;
  }

  AppDatabase? _resolveDatabaseForPersistence() {
    if (_disposed) return null;
    final database = _databaseResolver?.call();
    if (database == null) {
      throw StateError(
        'Attachment queue persistence is unavailable for a live operation',
      );
    }
    return database;
  }

  Future<void> _serializePersistence(Future<void> Function() operation) {
    final result = _persistenceTail.then((_) => operation());
    // A failed row operation must remain visible to its caller without
    // poisoning every later queue mutation.
    _persistenceTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _cleanupRestoredTerminalEntries() async {
    final protectedPaths = _queue
        .where(
          (item) =>
              item.status == QueuedAttachmentStatus.pending ||
              item.status == QueuedAttachmentStatus.uploading ||
              item.status == QueuedAttachmentStatus.failed,
        )
        .map((item) => path.normalize(path.absolute(item.filePath)))
        .toSet();
    final terminal = _queue
        .where(
          (item) =>
              item.status == QueuedAttachmentStatus.completed ||
              item.status == QueuedAttachmentStatus.cancelled,
        )
        .toList(growable: false);
    if (terminal.isEmpty) return;
    for (final item in terminal) {
      if (protectedPaths.contains(
        path.normalize(path.absolute(item.filePath)),
      )) {
        // A newer durable row owns this pathname. Keep the terminal row for
        // consumer acknowledgement, and never unlink the replacement bytes.
        continue;
      }
      var cleaned = false;
      final identityAdmission = _RestoredAttachmentIdentityAdmission(item);
      try {
        cleaned = await _terminalAttachmentCleanup(
          item.filePath,
          beforeDeleteAdmission: identityAdmission.verifyBeforeDelete,
          canDelete: identityAdmission.canDeleteNow,
        );
        if (identityAdmission.state == _RestoredIdentityState.indeterminate) {
          // A transient read/stat error is not proof that the durable owner is
          // stale. Keep the row so a later launch can verify and clean it.
          cleaned = false;
        }
      } catch (error, stackTrace) {
        DebugLogger.error(
          'restored-terminal-attachment-cleanup-failed',
          scope: 'attachments/queue',
          stackTrace: stackTrace,
          data: {'id': item.id, 'errorType': error.runtimeType.toString()},
        );
      }
      if (cleaned) {
        if (!identityAdmission.hasDurableIdentity ||
            identityAdmission.state == _RestoredIdentityState.differs) {
          DebugLogger.warning(
            'restored-terminal-attachment-identity-mismatch',
            scope: 'attachments/queue',
            data: {'id': item.id},
          );
        }
      } else {
        DebugLogger.warning(
          'restored-terminal-attachment-cleanup-deferred',
          scope: 'attachments/queue',
          data: {'id': item.id},
        );
      }
    }
  }

  static QueuedAttachment _rowToModel(AttachmentQueueData row) {
    return QueuedAttachment(
      id: row.id,
      filePath: row.filePath,
      fileName: row.fileName,
      fileSize: row.fileSize,
      mimeType: row.mimeType,
      checksum: row.checksum,
      durableKey: row.durableKey,
      enqueuedAt: DateTime.fromMillisecondsSinceEpoch(row.enqueuedAt),
      retryCount: row.retryCount,
      nextRetryAt: row.nextRetryAt != null
          ? DateTime.fromMillisecondsSinceEpoch(row.nextRetryAt!)
          : null,
      status: QueuedAttachmentStatus.values.firstWhere(
        (e) => e.name == row.status,
        orElse: () => QueuedAttachmentStatus.pending,
      ),
      lastError: row.lastError,
      fileId: row.fileId,
      receiptHeld: row.receiptHeld,
    );
  }

  /// Maps a legacy Hive attachment-queue JSON entry to a Drift row companion.
  /// Used by the one-time Hive → Drift migration.
  static AttachmentQueueCompanion companionFromLegacyJson(
    Map<String, dynamic> json,
  ) => _modelToCompanion(QueuedAttachment.fromJson(json));

  static AttachmentQueueCompanion _modelToCompanion(QueuedAttachment item) {
    return AttachmentQueueCompanion.insert(
      id: item.id,
      filePath: item.filePath,
      fileName: item.fileName,
      fileSize: item.fileSize,
      mimeType: Value(item.mimeType),
      checksum: Value(item.checksum),
      durableKey: Value(item.durableKey),
      receiptHeld: Value(item.receiptHeld),
      status: item.status.name,
      retryCount: Value(item.retryCount),
      nextRetryAt: Value(item.nextRetryAt?.millisecondsSinceEpoch),
      lastError: Value(item.lastError),
      fileId: Value(item.fileId),
      enqueuedAt: item.enqueuedAt.millisecondsSinceEpoch,
    );
  }

  void _notify() {
    if (_disposed) return;
    final snapshot = queue;
    try {
      _onQueueChanged?.call(snapshot);
    } catch (error) {
      // A synchronous observer must not prevent stream consumers (notably the
      // MediaUploadController terminal completer) from seeing this snapshot.
      DebugLogger.warning(
        'attachment-queue-observer-failed',
        scope: 'attachments/queue',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    if (!_queueController.isClosed) {
      _queueController.add(snapshot);
    }
  }
}
