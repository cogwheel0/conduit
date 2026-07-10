import 'dart:async';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import '../database/app_database.dart';
import '../database/daos/attachment_queue_dao.dart';
import '../utils/debug_logger.dart';

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
  final DateTime enqueuedAt;

  // Upload state
  int retryCount;
  DateTime? nextRetryAt;
  QueuedAttachmentStatus status;
  String? lastError;
  String? fileId; // server-side file id once uploaded

  QueuedAttachment({
    required this.id,
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    this.mimeType,
    this.checksum,
    DateTime? enqueuedAt,
    this.retryCount = 0,
    this.nextRetryAt,
    this.status = QueuedAttachmentStatus.pending,
    this.lastError,
    this.fileId,
  }) : enqueuedAt = enqueuedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'filePath': filePath,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
    'checksum': checksum,
    'enqueuedAt': enqueuedAt.toIso8601String(),
    'retryCount': retryCount,
    'nextRetryAt': nextRetryAt?.toIso8601String(),
    'status': status.name,
    'lastError': lastError,
    'fileId': fileId,
  };

  factory QueuedAttachment.fromJson(Map<String, dynamic> json) =>
      QueuedAttachment(
        id: json['id'] as String,
        filePath: json['filePath'] as String,
        fileName: json['fileName'] as String,
        fileSize: (json['fileSize'] as num).toInt(),
        mimeType: json['mimeType'] as String?,
        checksum: json['checksum'] as String?,
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
      );

  QueuedAttachment copyWith({
    int? retryCount,
    DateTime? nextRetryAt,
    QueuedAttachmentStatus? status,
    String? lastError,
    String? fileId,
  }) => QueuedAttachment(
    id: id,
    filePath: filePath,
    fileName: fileName,
    fileSize: fileSize,
    mimeType: mimeType,
    checksum: checksum,
    enqueuedAt: enqueuedAt,
    retryCount: retryCount ?? this.retryCount,
    nextRetryAt: nextRetryAt ?? this.nextRetryAt,
    status: status ?? this.status,
    lastError: lastError ?? this.lastError,
    fileId: fileId ?? this.fileId,
  );
}

typedef UploadCallback =
    Future<String> Function(
      String filePath,
      String fileName, {
      CancelToken? cancelToken,
    });
typedef AttachmentsEventCallback = void Function(List<QueuedAttachment> queue);

/// A lightweight background queue to upload attachments when back online.
///
/// One instance per active server, owned by `attachmentUploadQueueProvider`,
/// which constructs it, awaits [initialize], and [dispose]s it (closing the
/// stream and cancelling in-flight uploads) when the server changes.
class AttachmentUploadQueue {
  AttachmentUploadQueue();

  static const int _maxRetries = 4;
  static const Duration _baseRetryDelay = Duration(seconds: 5);
  static const Duration _maxRetryDelay = Duration(minutes: 5);

  /// Resolves the active server's Drift database. Re-supplied on each
  /// [initialize] (the owning provider re-runs on server switch), so the queue
  /// reloads and persists against the active server's `attachment_queue` table.
  AppDatabase? Function()? _databaseResolver;
  final List<QueuedAttachment> _queue = [];
  Timer? _retryTimer;
  bool _isProcessing = false;
  final Map<String, CancelToken> _cancelTokens = <String, CancelToken>{};

  // Dependencies
  UploadCallback? _onUpload;
  AttachmentsEventCallback? _onQueueChanged;

  // Streams
  final _queueController = StreamController<List<QueuedAttachment>>.broadcast();
  Stream<List<QueuedAttachment>> get queueStream => _queueController.stream;

  bool _disposed = false;
  Future<void>? _readyFuture;

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
      await _load();
      if (_disposed) return;
      _startPeriodicProcessing();
      DebugLogger.log(
        'AttachmentUploadQueue initialized with ${_queue.length} items',
        scope: 'attachments/queue',
      );
    } catch (error, stackTrace) {
      // Swallow init failures (e.g. a Drift load error) so the fire-and-forget
      // initialize() future never surfaces as an uncaught async error and
      // `ready` always completes. The queue degrades to empty; the next
      // server-scoped instance re-loads.
      DebugLogger.error(
        'attachment-queue-init-failed',
        scope: 'attachments/queue',
        error: error,
        stackTrace: stackTrace,
      );
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
  }) async {
    if (_disposed) {
      // The queue was torn down (server switch / logout). Fail loudly rather
      // than adding an item that _save/_notify/_processSafe all skip, which
      // would look enqueued but silently never persist or upload.
      throw StateError('Cannot enqueue on a disposed AttachmentUploadQueue');
    }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final item = QueuedAttachment(
      id: id,
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      checksum: checksum,
      status: QueuedAttachmentStatus.pending,
    );
    _queue.add(item);
    await _save();
    _notify();
    _processSafe();
    return id;
  }

  Future<void> processQueue() async {
    if (_isProcessing) return;
    if (_onUpload == null) return;

    _isProcessing = true;
    try {
      // Quick network probe using Dio HEAD to common health path if possible
      final dio = Dio();
      try {
        await dio.head('/api/health').timeout(const Duration(seconds: 3));
      } catch (_) {
        // Best effort; continue and let upload fail if actually offline
      }

      final now = DateTime.now();
      final pending = _queue.where(
        (e) =>
            (e.status == QueuedAttachmentStatus.pending ||
                e.status == QueuedAttachmentStatus.failed) &&
            (e.nextRetryAt == null || now.isAfter(e.nextRetryAt!)),
      );

      for (final item in List<QueuedAttachment>.from(pending)) {
        await _processSingle(item);
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _processSingle(QueuedAttachment item) async {
    if (_onUpload == null) return;
    if (_isCancelled(item.id)) return;
    final cancelToken = CancelToken();
    _cancelTokens[item.id] = cancelToken;
    try {
      _update(item.id, item.copyWith(status: QueuedAttachmentStatus.uploading));

      final fileId = await _onUpload!.call(
        item.filePath,
        item.fileName,
        cancelToken: cancelToken,
      );
      if (cancelToken.isCancelled || _isCancelled(item.id)) {
        return;
      }

      _update(
        item.id,
        item.copyWith(
          status: QueuedAttachmentStatus.completed,
          fileId: fileId,
          retryCount: 0,
          nextRetryAt: null,
          lastError: null,
        ),
      );

      await _save();
      _notify();
      DebugLogger.log(
        'Attachment ${item.id} uploaded successfully (fileId=$fileId)',
        scope: 'attachments/queue',
      );
    } catch (e) {
      if (cancelToken.isCancelled || _isCancelled(item.id)) {
        await _markCancelled(item.id);
        return;
      }
      final retries = item.retryCount + 1;
      if (retries >= _maxRetries) {
        _update(
          item.id,
          item.copyWith(
            status: QueuedAttachmentStatus.failed,
            retryCount: retries,
            lastError: e.toString(),
          ),
        );
        await _save();
        _notify();
        DebugLogger.log(
          'WARNING: Attachment ${item.id} failed after $_maxRetries attempts',
          scope: 'attachments/queue',
        );
        return;
      }

      final delay = _retryDelayWithJitter(retries);
      _update(
        item.id,
        item.copyWith(
          status: QueuedAttachmentStatus.pending,
          retryCount: retries,
          nextRetryAt: DateTime.now().add(delay),
          lastError: e.toString(),
        ),
      );
      await _save();
      _notify();
      DebugLogger.log(
        'Scheduled retry for attachment ${item.id} in ${delay.inSeconds}s',
        scope: 'attachments/queue',
      );
    } finally {
      _cancelTokens.remove(item.id);
    }
  }

  Duration _retryDelayWithJitter(int retryCount) {
    final base = _baseRetryDelay.inMilliseconds;
    final exp = min(
      base * pow(2, retryCount - 1),
      _maxRetryDelay.inMilliseconds.toDouble(),
    ).toInt();
    final jitter = Random().nextInt(1000); // up to 1s jitter
    return Duration(milliseconds: exp + jitter);
  }

  void _startPeriodicProcessing() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _processSafe(),
    );
    // Also kick once after a short delay
    Timer(const Duration(milliseconds: 500), _processSafe);
  }

  /// Tears down this per-server queue instance.
  ///
  /// The owning `attachmentUploadQueueProvider` calls this via `ref.onDispose`
  /// when the active server changes (server switch / logout). Cancels the
  /// periodic timer, aborts in-flight uploads via their [CancelToken]s (so
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
    // Fire and forget
    unawaited(processQueue());
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

  Future<void> _markCancelled(String id) async {
    final idx = _queue.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    _queue[idx] = _queue[idx].copyWith(
      status: QueuedAttachmentStatus.cancelled,
      nextRetryAt: null,
      lastError: 'cancelled',
    );
    await _save();
    _notify();
  }

  Future<void> remove(String id) async {
    _queue.removeWhere((e) => e.id == id);
    _cancelTokens.remove(id)?.cancel('Upload removed');
    await _save();
    _notify();
  }

  Future<void> cancel(String id) async {
    _cancelTokens.remove(id)?.cancel('Upload cancelled');
    await _markCancelled(id);
  }

  Future<void> retry(String id) async {
    final idx = _queue.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    _queue[idx] = _queue[idx].copyWith(
      status: QueuedAttachmentStatus.pending,
      retryCount: 0,
      nextRetryAt: null,
      lastError: null,
    );
    await _save();
    _notify();
    _processSafe();
  }

  Future<void> clearFailed() async {
    _queue.removeWhere((e) => e.status == QueuedAttachmentStatus.failed);
    await _save();
    _notify();
  }

  Future<void> clearAll() async {
    _queue.clear();
    await _save();
    _notify();
  }

  // Utilities
  Future<void> _load() async {
    _queue.clear();
    final dao = _attachmentDao;
    if (dao == null) return;
    final rows = await dao.getAll();
    // An item persisted as `uploading` means a prior session ended mid-upload
    // (deactivate on server switch/logout, or an app crash). Reset it to
    // `pending` on load so processQueue can retry it instead of leaving it
    // stuck in a non-terminal status that is never reprocessed.
    _queue.addAll(
      rows.map(_rowToModel).map(
            (item) => item.status == QueuedAttachmentStatus.uploading
                ? item.copyWith(status: QueuedAttachmentStatus.pending)
                : item,
          ),
    );
  }

  Future<void> _save() async {
    final db = _databaseResolver?.call();
    if (db == null) return;
    // The in-memory list is the source of truth; mirror it wholesale.
    final snapshot = List<QueuedAttachment>.from(_queue);
    await db.transaction(() async {
      await db.attachmentQueueDao.clearAll();
      for (final item in snapshot) {
        await db.attachmentQueueDao.upsert(_modelToCompanion(item));
      }
    });
  }

  static QueuedAttachment _rowToModel(AttachmentQueueData row) {
    return QueuedAttachment(
      id: row.id,
      filePath: row.filePath,
      fileName: row.fileName,
      fileSize: row.fileSize,
      mimeType: row.mimeType,
      checksum: row.checksum,
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
    _onQueueChanged?.call(queue);
    _queueController.add(queue);
  }
}
