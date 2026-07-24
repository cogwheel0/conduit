import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:path/path.dart' as path;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../../features/chat/services/file_attachment_service.dart';
import '../../features/direct_connections/direct_connections.dart';
import '../../features/hermes/models/hermes_chat_input.dart';
import '../../features/hermes/models/hermes_model.dart';
import '../../features/hermes/providers/hermes_providers.dart';
import '../../features/hermes/services/hermes_local_document_service.dart';
import '../models/file_info.dart';
import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';
import 'api_service.dart';
import 'attachment_upload_queue.dart';
import 'image_attachment_cache_service.dart';
import 'share_staging_cleanup.dart';

part 'media_upload_controller.g.dart';

typedef DirectImageDataUrlEncoder = Future<String?> Function(File file);
typedef ImageUploadConverter = Future<String?> Function(String filePath);
typedef StagingFileCopy =
    Future<File> Function(File source, String destinationPath);
typedef OwnedStagingConversionReplacer =
    Future<OwnedStagingConversionReplacementResult> Function({
      required String originalPath,
      required String convertedPath,
      bool Function()? canReplace,
    });

const int kUploadImagePrecacheMaxBytes = 4 * 1024 * 1024;

String _localDocumentOpaqueId(File file, FileStat stat) => sha256
    .convert(
      utf8.encode(
        '${file.path}\u0000${stat.size}\u0000'
        '${stat.modified.microsecondsSinceEpoch}',
      ),
    )
    .toString();

/// Stable native-import identity used to derive a per-server Drift receipt.
final class NativeShareUploadIdentity {
  const NativeShareUploadIdentity({
    required this.payloadId,
    required this.itemOrdinal,
  });

  final String payloadId;
  final int itemOrdinal;
}

String _nativeShareReceiptKey(NativeShareUploadIdentity identity) {
  if (identity.itemOrdinal < 0) {
    throw ArgumentError.value(
      identity.itemOrdinal,
      'itemOrdinal',
      'must not be negative',
    );
  }
  final payloadDigest = sha256
      .convert(utf8.encode(identity.payloadId))
      .toString();
  // v2 deliberately omits any content checksum. Image conversion rewrites
  // owned staging files in place, so a payload re-delivered after a process
  // death re-encodes to different bytes; a content-derived key would then miss
  // the persisted row and duplicate the upload while leaking its receipt. The
  // native payload id + item ordinal are durable and unique per import item,
  // so they alone identify the row across restarts — even when the same item
  // is re-delivered with genuinely different bytes, the row IS that item.
  return 'native-share-v2:$payloadDigest:${identity.itemOrdinal}';
}

/// Crash-safe acceptance returned to the native share coordinator.
final class NativeShareUploadAcceptance {
  const NativeShareUploadAcceptance({
    required this.receiptKey,
    required this.providedPathOwned,
  });

  final String receiptKey;

  /// Whether the controller/queue now owns the caller's newly staged path.
  /// False means this attempt joined an earlier row and skipped publishing a
  /// duplicate composer attachment; the caller may roll this extra copy back.
  final bool providedPathOwned;
}

/// Local Direct/Hermes composer state is not a crash-durable native owner.
final class NativeShareDurableOwnershipUnavailable implements Exception {
  const NativeShareDurableOwnershipUnavailable();

  @override
  String toString() =>
      'Native shared files require a server-backed model before import.';
}

typedef UploadImagePrecacheReader =
    Future<Uint8List?> Function(String filePath, int maxBytes);
typedef MediaUploadAttachmentCleanup =
    Future<bool> Function(
      String filePath, {
      required Future<void> Function() beforeDeleteAdmission,
      required bool Function() canDelete,
    });
typedef MediaUploadCleanupBarrier = Future<void> Function(String filePath);

final uploadImagePrecacheReaderProvider = Provider<UploadImagePrecacheReader>(
  (ref) => (filePath, maxBytes) async {
    final file = File(filePath);
    if (await file.length() > maxBytes) return null;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, maxBytes + 1)) {
      builder.add(chunk);
      if (builder.length > maxBytes) return null;
    }
    return builder.takeBytes();
  },
);

enum OwnedStagingConversionReplacementResult { notOwned, replaced, failed }

typedef _UploadFileIdentity = ({int fileSize, String checksum});

Future<_UploadFileIdentity> _streamUploadFileIdentity(File file) async {
  final initialType = await FileSystemEntity.type(
    file.path,
    followLinks: false,
  );
  if (initialType != FileSystemEntityType.file) {
    throw FileSystemException('Upload source is not a regular file', file.path);
  }
  final before = await file.stat();
  final checksum = (await sha256.bind(file.openRead()).first).toString();
  final finalType = await FileSystemEntity.type(file.path, followLinks: false);
  final after = await file.stat();
  if (finalType != FileSystemEntityType.file ||
      before.type != after.type ||
      before.size != after.size ||
      before.mode != after.mode ||
      before.modified != after.modified ||
      before.changed != after.changed) {
    throw FileSystemException(
      'Upload source changed while its durable identity was captured',
      file.path,
    );
  }
  return (fileSize: after.size, checksum: checksum);
}

/// Atomically replaces an app-owned staging file with its converted upload
/// bytes while preserving the original durable cleanup path.
///
/// Conversion normally produces a separate system-temp file. Persisting that
/// path would make a restored terminal queue row unable to clean the original
/// native-paste/App-Intent/App-Group source. A sibling copy keeps the final
/// rename on the staging volume, then removes the now-empty conversion temp
/// directory. Non-owned sources are left untouched and use the normal temp
/// path flow.
Future<OwnedStagingConversionReplacementResult>
replaceOwnedStagingFileWithConvertedUpload({
  required String originalPath,
  required String convertedPath,
  StagingFileCopy? copyFile,
  bool Function()? canReplace,
}) async {
  final ownership = await classifyShareStagingPath(originalPath);
  if (canReplace?.call() == false) {
    return OwnedStagingConversionReplacementResult.failed;
  }
  switch (ownership) {
    case ShareStagingPathOwnership.notOwned:
      return OwnedStagingConversionReplacementResult.notOwned;
    case ShareStagingPathOwnership.indeterminate:
      return OwnedStagingConversionReplacementResult.failed;
    case ShareStagingPathOwnership.owned:
      break;
  }

  final converted = await resolveConvertedUploadFile(convertedPath);
  if (canReplace?.call() == false) {
    return OwnedStagingConversionReplacementResult.failed;
  }
  if (converted == null) {
    DebugLogger.warning(
      'owned-staging-conversion-path-rejected',
      scope: 'media/upload',
      data: {'fileName': path.basename(convertedPath)},
    );
    return OwnedStagingConversionReplacementResult.failed;
  }

  final original = File(originalPath);
  final replacement = File('$originalPath.${const Uuid().v4()}.replacement');
  try {
    if (copyFile != null) {
      await copyFile(converted, replacement.path);
    } else {
      await converted.copy(replacement.path);
    }
    if (canReplace?.call() == false) {
      if (await replacement.exists()) await replacement.delete();
      return OwnedStagingConversionReplacementResult.failed;
    }
    // The final operation-identity admission and pathname replacement must be
    // one synchronous turn. Awaiting an async rename here lets a newer upload
    // re-stage [originalPath] after admission and then be overwritten by this
    // retired conversion.
    replacement.renameSync(original.path);
  } catch (error, stackTrace) {
    try {
      if (await replacement.exists()) await replacement.delete();
    } catch (_) {}
    DebugLogger.error(
      'owned-staging-conversion-replacement-failed',
      scope: 'media/upload',
      error: error,
      stackTrace: stackTrace,
      data: {'fileName': original.uri.pathSegments.last},
    );
    return OwnedStagingConversionReplacementResult.failed;
  }

  // [converted] was validated above as the exact regular conversion artifact.
  // Delete only that file and then its now-empty parent; never recursively
  // remove a caller-derived directory.
  try {
    await converted.delete();
    await converted.parent.delete();
  } catch (error) {
    DebugLogger.warning(
      'owned-staging-conversion-temp-cleanup-deferred',
      scope: 'media/upload',
      data: {
        'fileName': original.uri.pathSegments.last,
        'error': error.toString(),
      },
    );
  }
  return OwnedStagingConversionReplacementResult.replaced;
}

/// Encoding seam used to prove oversized files are rejected before base64
/// allocation. Production keeps the existing compatibility conversion path.
final directImageDataUrlEncoderProvider = Provider<DirectImageDataUrlEncoder>(
  (ref) => convertImageFileToDataUrl,
);

final imageUploadConverterProvider = Provider<ImageUploadConverter>(
  (ref) => convertImageForUpload,
);

final ownedStagingConversionReplacerProvider =
    Provider<OwnedStagingConversionReplacer>(
      (ref) => replaceOwnedStagingFileWithConvertedUpload,
    );

/// Cleanup seam for terminal uploads. The boolean is deliberately stronger
/// than "delete attempted": `false` keeps the durable queue row for a later
/// launch to retry.
final terminalAttachmentCleanupProvider =
    Provider<MediaUploadAttachmentCleanup>(
      (ref) =>
          (filePath, {required beforeDeleteAdmission, required canDelete}) =>
              cleanupTerminalAttachmentFile(
                filePath,
                beforeDeleteAdmission: (_) => beforeDeleteAdmission(),
                canDelete: (_) => canDelete(),
              ),
    );

/// Test seam placed after staging ownership/type checks and immediately before
/// the generation admission that guards the actual unlink.
final mediaUploadCleanupBarrierProvider = Provider<MediaUploadCleanupBarrier>(
  (ref) => (_) async {},
);

/// Validates an encoder result without allocating a second decoded image.
/// Returns the current image's decoded byte count for persisted UI metadata.
int validatePreparedDirectImageDataUrl(
  String dataUrl, {
  required int otherImageBytes,
  int maxDecodedImageBytes = kDirectMaxDecodedImageBytes,
}) {
  final decodedBytes = decodedImageByteLength(
    dataUrl,
    maxDecodedBytes: maxDecodedImageBytes - otherImageBytes,
  );
  if (otherImageBytes + decodedBytes > maxDecodedImageBytes) {
    throw DirectChatInputException(
      maxDecodedImageBytes == kDirectMaxDecodedImageBytes
          ? 'Direct chat images must be 20 MB or less in total.'
          : 'Direct chat images exceed the decoded byte limit.',
    );
  }
  return decodedBytes;
}

/// Shared media-upload controller (CDT-RFC-001 §7.2, Group 2 of the task_queue
/// retirement).
///
/// Media uploads are a FOLD-OUT, NOT an outbox op — the outbox never carries
/// `uploadMedia` (matches the migrator `droppedUpload` drop + design §7.2). This
/// controller owns the upload pipeline that used to live in
/// `task_worker._performUploadMediaInner` (+ `_shouldConvertImage` /
/// `_convertImageForUpload` + the `attachedFilesProvider` progress wiring),
/// driving an [AttachmentUploadQueue] and mutating [attachedFilesProvider] in
/// place exactly as before.
///
/// Cancellation: the legacy queue tracked a per-file `OutboundTask` it could
/// flip to cancelled and clean up share-staging for. Here the controller tracks
/// the in-flight upload per source [filePath] so [cancelUploadsForFile] can stop
/// it and perform the same `deleteShareStagingFile` cleanup the legacy queue did.
final class MediaAttachmentOwnershipSnapshot {
  const MediaAttachmentOwnershipSnapshot._(this._attachments);

  final List<_MediaAttachmentOwnership> _attachments;
}

typedef _MediaAttachmentOwnership = ({
  FileUploadState attachment,
  _InflightUpload? inflight,
  int? pathGeneration,
});

class MediaUploadController {
  MediaUploadController(this._ref);

  final Ref _ref;
  final Lock _localAttachmentPreparationLock = Lock();

  /// In-flight uploads keyed by the ORIGINAL source [filePath] (the key the UI
  /// + cancellation reference, never the converted temp path). Exact-path
  /// duplicates join the same operation: two queue rows must never consume and
  /// clean up the same staging file independently.
  final Map<String, _InflightUpload> _inflight = <String, _InflightUpload>{};

  /// Process-local composer publication fence for durable native receipts.
  /// The Drift row is the restart fence; this map additionally prevents a
  /// partial retry in the same composer from showing the same item twice.
  final Map<String, String> _nativeReceiptComposerPaths = <String, String>{};

  /// Monotonic per-path ABA fence. Cancellation removes the active operation
  /// immediately so a replacement may start without waiting for a slow local
  /// encoder, while this generation prevents that late continuation from
  /// mutating or deleting the replacement attachment.
  final Map<String, int> _pathGenerations = <String, int>{};
  int _nextGeneration = 0;

  @visibleForTesting
  int get debugTrackedPathGenerationCount => _pathGenerations.length;

  /// Captures the exact composer and upload owners present at an auth boundary.
  /// The snapshot can be retired later without touching attachments published
  /// by a session that authenticated in the meantime.
  MediaAttachmentOwnershipSnapshot captureAttachmentOwnership() {
    final attachments = _ref.read(attachedFilesProvider);
    return MediaAttachmentOwnershipSnapshot._(<_MediaAttachmentOwnership>[
      for (final attachment in attachments)
        () {
          final filePath = attachment.file.path;
          final inflight = _inflight[filePath];
          if (inflight != null) {
            _captureCurrentAttachment(filePath, inflight);
          }
          return (
            attachment: attachment,
            inflight: inflight,
            pathGeneration: _pathGenerations[filePath],
          );
        }(),
    ]);
  }

  /// Retires only owners captured by [captureAttachmentOwnership].
  Future<void> retireAttachmentOwnership(
    MediaAttachmentOwnershipSnapshot snapshot,
  ) {
    final notifier = _ref.read(attachedFilesProvider.notifier);
    final cleanups = <Future<void>>[];
    final retiredPaths = <String>{};

    for (final owner in snapshot._attachments) {
      final latestInflightAttachment = owner.inflight?.attachmentOwner;
      var removed = notifier.removeFileIfIdentical(owner.attachment);
      if (latestInflightAttachment != null &&
          !identical(latestInflightAttachment, owner.attachment)) {
        removed =
            notifier.removeFileIfIdentical(latestInflightAttachment) || removed;
      }
      final removedAttachment = latestInflightAttachment ?? owner.attachment;
      final filePath = owner.attachment.file.path;
      if (!removed ||
          owner.attachment.isRemote ||
          filePath.startsWith('remote://') ||
          !retiredPaths.add(filePath)) {
        continue;
      }
      cleanups.add(
        _retireCapturedAttachment(
          filePath: filePath,
          owner: owner,
          removedAttachment: removedAttachment,
        ),
      );
    }

    if (cleanups.isEmpty) return Future<void>.value();
    return Future.wait<void>(cleanups).then<void>((_) {});
  }

  Future<void> _retireCapturedAttachment({
    required String filePath,
    required _MediaAttachmentOwnership owner,
    required FileUploadState removedAttachment,
  }) async {
    var inflight = owner.inflight;
    var generation = owner.pathGeneration;
    final active = _inflight[filePath];

    // An upload can begin after the auth-boundary snapshot but before cleanup.
    // It still belongs to the old attachment only when it captured that exact
    // state object.
    if (inflight == null &&
        active != null &&
        identical(active.attachmentOwner, removedAttachment)) {
      inflight = active;
      generation = active.generation;
    }

    if (inflight != null &&
        identical(_inflight[filePath], inflight) &&
        _pathGenerations[filePath] == generation) {
      _inflight.remove(filePath);
      final hasReplacementAttachment = _currentAttachment(filePath) != null;
      final replacementFence = hasReplacementAttachment
          ? ++_nextGeneration
          : null;
      if (replacementFence != null) {
        // Prevent the old cancel handler from unlinking bytes now referenced by
        // a replacement state object at the same pathname.
        _pathGenerations[filePath] = replacementFence;
      }
      final queueOwnedCleanup = await inflight.cancel();
      if (!queueOwnedCleanup && !hasReplacementAttachment) {
        await _cleanupAttachmentForGeneration(
          targetPath: filePath,
          ownershipPath: filePath,
          inflight: inflight,
          fencePathIdentity: true,
        );
      }
      if (replacementFence != null &&
          _pathGenerations[filePath] == replacementFence &&
          !_inflight.containsKey(filePath)) {
        _pathGenerations.remove(filePath);
      }
      _tryPrunePathGeneration(filePath, inflight);
      return;
    }

    // A replacement operation/generation owns this pathname now. Preserve it.
    final currentGeneration = _pathGenerations[filePath];
    if (_currentAttachment(filePath) != null ||
        _inflight.containsKey(filePath) ||
        (generation != null &&
            currentGeneration != null &&
            currentGeneration != generation)) {
      return;
    }
    await cancelUploadsForFile(filePath);
  }

  /// Uploads [filePath] to the server, driving [attachedFilesProvider] progress
  /// in place. Behavior is identical to the legacy
  /// `task_worker._performUploadMediaInner`: image conversion for unsupported
  /// formats, instant-display byte pre-cache, share-staging cleanup on terminal
  /// status, and `userFilesProvider` sync on completion.
  Future<void> upload({
    required String filePath,
    required String fileName,
    int? fileSize,
    String? mimeType,
    String? checksum,
  }) {
    return _startUpload(
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      checksum: checksum,
    ).inflight.terminalFuture;
  }

  /// Takes durable ownership of an upload without waiting for its terminal
  /// network result.
  ///
  /// The returned future completes only after local/direct preparation has
  /// finished or the OpenWebUI queue row and its lifecycle listener have been
  /// installed. Terminal upload work continues in the background. Preparation
  /// failures update attachment state but retain app-owned staging so the
  /// visible failed attachment remains readable and explicitly retryable.
  Future<void> enqueueUpload({
    required String filePath,
    required String fileName,
    int? fileSize,
    String? mimeType,
    String? checksum,
    LocalAttachment? publishAttachment,
  }) async {
    await _enqueueUploadOwned(
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      checksum: checksum,
      publishAttachment: publishAttachment,
    );
  }

  /// Takes crash-safe ownership for one item in a durable native share.
  ///
  /// Its receipt remains in Drift through terminal upload cleanup and is
  /// released only after the native exact-ID acknowledgement succeeds.
  Future<NativeShareUploadAcceptance> enqueueNativeShareUpload({
    required String filePath,
    required String fileName,
    required NativeShareUploadIdentity identity,
    int? fileSize,
    String? mimeType,
    String? checksum,
    LocalAttachment? publishAttachment,
  }) async {
    final inflight = await _enqueueUploadOwned(
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      checksum: checksum,
      publishAttachment: publishAttachment,
      nativeShareIdentity: identity,
    );
    final receiptKey = inflight.nativeReceiptKey;
    if (receiptKey == null) {
      throw StateError('Native share upload was accepted without a receipt.');
    }
    return NativeShareUploadAcceptance(
      receiptKey: receiptKey,
      providedPathOwned: inflight.providedPathOwned,
    );
  }

  /// Releases receipts after native storage has irreversibly removed the
  /// corresponding payload. A failed release deliberately leaves held rows.
  Future<void> releaseNativeShareReceipts(Iterable<String> receiptKeys) async {
    final uploader = _ref.read(attachmentUploadQueueProvider);
    if (uploader == null) {
      throw StateError('Attachment upload queue is unavailable.');
    }
    await uploader.ready;
    await uploader.releaseDurableReceipts(receiptKeys);
    for (final key in receiptKeys) {
      _nativeReceiptComposerPaths.remove(key);
    }
  }

  /// Garbage-collects receipts stranded by a process death between the native
  /// exact-ID acknowledgement and [releaseNativeShareReceipts].
  ///
  /// Such receipts live only as terminal `receiptHeld` rows: the process-local
  /// key registry died with the old process, so nothing will ever release them
  /// explicitly. Releasing is safe only once native storage authoritatively
  /// reports no pending payloads — a receipt for a payload that IS still
  /// pending natively is exactly the dedupe fence receipts exist to provide.
  ///
  /// [confirmNoPendingNativePayloads] is evaluated after the candidate
  /// snapshot is taken. A payload that arrives afterwards creates its receipts
  /// outside the snapshot (native payload ids are unique per share event), so
  /// the confirmation ordering guarantees a live receipt is never released.
  /// Returns the number of receipts released.
  Future<int> releaseOrphanedNativeShareReceipts({
    required Future<bool> Function() confirmNoPendingNativePayloads,
  }) async {
    final uploader = _ref.read(attachmentUploadQueueProvider);
    if (uploader == null) return 0;
    await uploader.ready;
    final candidates = <String>{
      for (final item in uploader.queue)
        if (item.receiptHeld &&
            item.durableKey != null &&
            (item.status == QueuedAttachmentStatus.completed ||
                item.status == QueuedAttachmentStatus.failed ||
                item.status == QueuedAttachmentStatus.cancelled))
          item.durableKey!,
    };
    if (candidates.isEmpty) return 0;
    if (!await confirmNoPendingNativePayloads()) return 0;
    await releaseNativeShareReceipts(candidates);
    return candidates.length;
  }

  Future<_InflightUpload> _enqueueUploadOwned({
    required String filePath,
    required String fileName,
    required int? fileSize,
    required String? mimeType,
    required String? checksum,
    required LocalAttachment? publishAttachment,
    NativeShareUploadIdentity? nativeShareIdentity,
  }) {
    var attachmentPublished = false;

    void publishAttachmentOnce(_InflightUpload inflight) {
      final attachment = publishAttachment;
      if (attachment == null || attachmentPublished) return;
      final receiptKey = inflight.nativeReceiptKey;
      if (receiptKey != null) {
        final existingPath = _nativeReceiptComposerPaths[receiptKey];
        if (existingPath != null && _currentAttachment(existingPath) != null) {
          // A prior partial attempt already published this exact native item.
          // Keep the new staging copy rollback-owned by the current batch.
          inflight.markProvidedPathUnowned();
          return;
        }
        if (existingPath != null) {
          _nativeReceiptComposerPaths.remove(receiptKey);
        }
      }
      _ref.read(attachedFilesProvider.notifier).addFiles([attachment]);
      attachmentPublished = true;
      _captureCurrentAttachment(filePath, inflight);
      if (receiptKey != null) {
        _nativeReceiptComposerPaths[receiptKey] = filePath;
      }
    }

    final start = _startUpload(
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      checksum: checksum,
      nativeShareIdentity: nativeShareIdentity,
      onLocalOwnershipAcquired: publishAttachmentOnce,
      onQueueOwnershipAcquired: publishAttachmentOnce,
    );
    final inflight = start.inflight;
    if (start.started) {
      unawaited(
        inflight.terminalFuture.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            if (inflight.ownershipAccepted) {
              DebugLogger.error(
                'detached-upload-failed',
                scope: 'media/upload',
                error: error,
                stackTrace: stackTrace,
                data: {'fileName': fileName},
              );
            }
          },
        ),
      );
    }
    return () async {
      try {
        await inflight.waitUntilAccepted();
      } catch (error, stackTrace) {
        // Acceptance is the public ownership boundary. A preparation failure
        // must undo a publication before that failure reaches the caller; a
        // separate terminal listener has no ordering guarantee relative to
        // the acceptance future.
        if (attachmentPublished && !inflight.ownershipAccepted) {
          // `_runUploadOwned` settles (and removes itself from `_inflight`)
          // before its error reaches this acceptance waiter. Inspect the exact
          // published state object instead of requiring an active operation;
          // otherwise a successfully-installed failed state looks unowned and
          // is immediately removed again.
          final current = _currentAttachment(filePath);
          final ownsCurrent =
              current != null && identical(current, inflight.attachmentOwner);
          if (error is MediaUploadCancelledException ||
              (ownsCurrent && current.status != FileUploadStatus.failed)) {
            _removeAttachmentIfOwned(filePath, inflight);
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      return inflight;
    }();
  }

  _UploadStart _startUpload({
    required String filePath,
    required String fileName,
    required int? fileSize,
    required String? mimeType,
    required String? checksum,
    NativeShareUploadIdentity? nativeShareIdentity,
    void Function(_InflightUpload)? onLocalOwnershipAcquired,
    void Function(_InflightUpload)? onQueueOwnershipAcquired,
  }) {
    final existing = _inflight[filePath];
    if (existing != null && existing.isJoinable) {
      return (inflight: existing, started: false);
    }

    final generation = ++_nextGeneration;
    _pathGenerations[filePath] = generation;
    final inflight = _InflightUpload(generation: generation);
    _inflight[filePath] = inflight;
    _captureCurrentAttachment(filePath, inflight);
    final terminal = _runUploadOwned(
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      checksum: checksum,
      nativeShareIdentity: nativeShareIdentity,
      onLocalOwnershipAcquired: onLocalOwnershipAcquired,
      onQueueOwnershipAcquired: onQueueOwnershipAcquired,
      inflight: inflight,
    );
    inflight.bindTerminal(terminal);
    return (inflight: inflight, started: true);
  }

  Future<void> _runUploadOwned({
    required String filePath,
    required String fileName,
    required int? fileSize,
    required String? mimeType,
    required String? checksum,
    required NativeShareUploadIdentity? nativeShareIdentity,
    void Function(_InflightUpload)? onLocalOwnershipAcquired,
    void Function(_InflightUpload)? onQueueOwnershipAcquired,
    required _InflightUpload inflight,
  }) async {
    try {
      await _uploadInner(
        filePath: filePath,
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
        checksum: checksum,
        nativeShareIdentity: nativeShareIdentity,
        onLocalOwnershipAcquired: onLocalOwnershipAcquired,
        onQueueOwnershipAcquired: onQueueOwnershipAcquired,
        inflight: inflight,
      );
    } on MediaUploadCancelledException {
      // Explicit removal owns staging cleanup and intentionally does not turn a
      // disappearing composer row into a visible failed attachment.
      rethrow;
    } catch (error) {
      final existing = _ownedAttachment(filePath, inflight);
      if (existing != null && existing.status != FileUploadStatus.completed) {
        _updateAttachmentIfOwned(
          filePath,
          inflight,
          FileUploadState(
            file: existing.file,
            fileName: existing.fileName,
            fileSize: existing.fileSize,
            progress: existing.progress,
            status: FileUploadStatus.failed,
            fileId: existing.fileId,
            error: error.toString(),
            isImage: existing.isImage,
            base64DataUrl: existing.base64DataUrl,
          ),
        );
      }
      // Do not delete an app-owned source when preparation failed before a
      // durable queue/local owner accepted it. The composer already references
      // this file and exposes retry/removal UI; deleting it here would turn a
      // recoverable failure (for example a temporarily unavailable queue) into
      // permanent data loss. Terminal queue and explicit removal paths perform
      // cleanup once ownership is settled.
      rethrow;
    } finally {
      inflight.markExecutionSettled();
      if (identical(_inflight[filePath], inflight)) {
        _inflight.remove(filePath);
      }
      _tryPrunePathGeneration(filePath, inflight);
    }
  }

  /// Cancels any in-flight upload for [filePath] and performs the share-staging
  /// cleanup the legacy `task_queue.cancelUploadsForFile` did. Safe to call when
  /// no upload is in flight (still runs the staging cleanup, matching the
  /// legacy "always delete the staged copy" behavior on attachment removal).
  Future<void> cancelUploadsForFile(String filePath) async {
    var inflight = _inflight.remove(filePath);
    if (inflight == null) {
      inflight = _InflightUpload(generation: ++_nextGeneration)
        ..markExecutionSettled();
      _pathGenerations[filePath] = inflight.generation;
    }
    var queueOwnedCleanup = false;
    queueOwnedCleanup = await inflight.cancel();
    if (!queueOwnedCleanup) {
      await _cleanupAttachmentForGeneration(
        targetPath: filePath,
        ownershipPath: filePath,
        inflight: inflight,
        fencePathIdentity: true,
      );
    }
    _tryPrunePathGeneration(filePath, inflight);
  }

  /// Synchronously removes one composer attachment, then retires every local
  /// owner through the controller's durable-queue and generation fences.
  ///
  /// Keeping the notifier state-only is important: a detached pathname unlink
  /// cannot distinguish this retired attachment from different bytes staged at
  /// the same path by a newer generation.
  Future<void> removeAttachment(String filePath) {
    final isRemote = _ref
        .read(attachedFilesProvider)
        .any(
          (attachment) =>
              attachment.file.path == filePath && attachment.isRemote,
        );
    _ref.read(attachedFilesProvider.notifier).removeFile(filePath);
    if (isRemote || filePath.startsWith('remote://')) {
      return Future<void>.value();
    }
    return cancelUploadsForFile(filePath);
  }

  /// Synchronously clears composer state and asynchronously retires all local
  /// attachment owners. Callers may detach the returned cleanup after the
  /// message/navigation ownership transfer that authorized the clear.
  Future<void> clearAttachments() {
    final localPaths = <String>{
      for (final attachment in _ref.read(attachedFilesProvider))
        if (!attachment.isRemote &&
            !attachment.file.path.startsWith('remote://'))
          attachment.file.path,
    };
    _ref.read(attachedFilesProvider.notifier).clearAll();
    if (localPaths.isEmpty) return Future<void>.value();
    return Future.wait<void>(
      localPaths.map(cancelUploadsForFile),
    ).then<void>((_) {});
  }

  Future<bool> _cleanupAttachmentForGeneration({
    required String targetPath,
    required String ownershipPath,
    required _InflightUpload inflight,
    required bool fencePathIdentity,
  }) async {
    inflight.beginCleanup();
    try {
      final barrier = _ref.read(mediaUploadCleanupBarrierProvider);
      final cleanup = _ref.read(terminalAttachmentCleanupProvider);
      return await cleanup(
        targetPath,
        beforeDeleteAdmission: () async {
          if (fencePathIdentity) await barrier(targetPath);
        },
        canDelete: () {
          if (!fencePathIdentity) return true;
          return _pathGenerations[ownershipPath] == inflight.generation &&
              (_inflight[ownershipPath] == null ||
                  identical(_inflight[ownershipPath], inflight));
        },
      );
    } finally {
      inflight.endCleanup();
      _tryPrunePathGeneration(ownershipPath, inflight);
    }
  }

  void _tryPrunePathGeneration(String filePath, _InflightUpload inflight) {
    if (!inflight.executionSettled ||
        inflight.cleanupInProgress ||
        _inflight.containsKey(filePath) ||
        _pathGenerations[filePath] != inflight.generation) {
      return;
    }
    _pathGenerations.remove(filePath);
  }

  bool _isLatestGeneration(String filePath, _InflightUpload inflight) =>
      _pathGenerations[filePath] == inflight.generation;

  bool _isOperationActive(String filePath, _InflightUpload inflight) =>
      !inflight.isCancelled &&
      _isLatestGeneration(filePath, inflight) &&
      identical(_inflight[filePath], inflight);

  void _throwIfOperationNotActive(String filePath, _InflightUpload inflight) {
    if (!_isOperationActive(filePath, inflight)) {
      throw const MediaUploadCancelledException();
    }
  }

  FileUploadState? _currentAttachment(String filePath) => _ref
      .read(attachedFilesProvider)
      .where((attachment) => attachment.file.path == filePath)
      .firstOrNull;

  void _captureCurrentAttachment(String filePath, _InflightUpload inflight) {
    final attachment = _currentAttachment(filePath);
    if (attachment != null) inflight.captureAttachment(attachment);
  }

  FileUploadState? _ownedAttachment(String filePath, _InflightUpload inflight) {
    if (!_isOperationActive(filePath, inflight)) return null;
    final current = _currentAttachment(filePath);
    final expected = inflight.attachmentOwner;
    if (current == null ||
        (expected != null && !identical(current, expected))) {
      return null;
    }
    if (expected == null) inflight.captureAttachment(current);
    return current;
  }

  bool _updateAttachmentIfOwned(
    String filePath,
    _InflightUpload inflight,
    FileUploadState newState,
  ) {
    if (_ownedAttachment(filePath, inflight) == null) return false;
    _throwIfOperationNotActive(filePath, inflight);
    if (newState.status == FileUploadStatus.completed ||
        newState.status == FileUploadStatus.failed) {
      inflight.markNonJoinable();
    }
    _ref
        .read(attachedFilesProvider.notifier)
        .updateFileState(filePath, newState);
    inflight.captureAttachment(newState);
    return true;
  }

  void _removeAttachmentIfOwned(String filePath, _InflightUpload inflight) {
    final active = _inflight[filePath];
    if (active != null && !identical(active, inflight)) return;
    final generation = _pathGenerations[filePath];
    if (generation != null && generation != inflight.generation) return;
    final current = _currentAttachment(filePath);
    final expected = inflight.attachmentOwner;
    if (current == null || expected == null || !identical(current, expected)) {
      return;
    }
    _ref.read(attachedFilesProvider.notifier).removeFile(filePath);
  }

  Future<void> _uploadInner({
    required String filePath,
    required String fileName,
    required int? fileSize,
    required String? mimeType,
    required String? checksum,
    required NativeShareUploadIdentity? nativeShareIdentity,
    void Function(_InflightUpload)? onLocalOwnershipAcquired,
    void Function(_InflightUpload)? onQueueOwnershipAcquired,
    required _InflightUpload inflight,
  }) async {
    _throwIfOperationNotActive(filePath, inflight);
    final lowerName = fileName.toLowerCase();
    final bool isImage = allSupportedImageFormats.any(lowerName.endsWith);

    final selectedModel = _ref.read(selectedModelProvider);
    if (nativeShareIdentity != null &&
        selectedModel != null &&
        (isHermesModel(selectedModel) ||
            hasReservedDirectIdentity(selectedModel))) {
      // Direct/Hermes attachment data currently lives only in composer memory.
      // A native exact-ID acknowledgement would therefore lose the recovery
      // oracle on process death. Fail before publication and leave the native
      // payload/source retryable until a server-backed model is selected.
      throw const NativeShareDurableOwnershipUnavailable();
    }
    if (selectedModel != null && isHermesModel(selectedModel)) {
      await _localAttachmentPreparationLock.synchronized(() async {
        _throwIfOperationNotActive(filePath, inflight);
        // A local attachment must never fall through to a different backend
        // after a model switch: it may contain private bytes intended only for
        // the selected Hermes connection.
        final currentModel = _ref.read(selectedModelProvider);
        if (currentModel == null || !isHermesModel(currentModel)) {
          throw const HermesChatInputException(
            'The selected backend changed while preparing this attachment.',
          );
        }
        onLocalOwnershipAcquired?.call(inflight);
        _captureCurrentAttachment(filePath, inflight);
        _throwIfOperationNotActive(filePath, inflight);
        await _prepareHermesAttachment(
          filePath: filePath,
          fileName: fileName,
          isImage: isImage,
          inflight: inflight,
        );
        _throwIfOperationNotActive(filePath, inflight);
        inflight.markAccepted();
      });
      _throwIfOperationNotActive(filePath, inflight);
      return;
    }
    if (selectedModel != null && hasReservedDirectIdentity(selectedModel)) {
      final preparedDirect = await _localAttachmentPreparationLock.synchronized(
        () async {
          _throwIfOperationNotActive(filePath, inflight);
          // Waiting for an earlier image can outlive a model switch. Resolve
          // the route only after this upload owns the preparation lock so a
          // queued item cannot write a direct data URL into an OpenWebUI send.
          final currentModel = _ref.read(selectedModelProvider);
          if (currentModel == null ||
              !hasReservedDirectIdentity(currentModel)) {
            return false;
          }
          final directBinding = _ref
              .read(directModelRegistryProvider)
              .resolve(currentModel);
          if (directBinding == null) {
            throw const DirectChatInputException(
              'The selected direct model is no longer available.',
            );
          }
          onLocalOwnershipAcquired?.call(inflight);
          _captureCurrentAttachment(filePath, inflight);
          _throwIfOperationNotActive(filePath, inflight);
          await _prepareDirectAttachment(
            filePath: filePath,
            fileName: fileName,
            isImage: isImage,
            selectedModelSupportsImages: currentModel.isMultimodal == true,
            inflight: inflight,
          );
          _throwIfOperationNotActive(filePath, inflight);
          inflight.markAccepted();
          return true;
        },
      );
      _throwIfOperationNotActive(filePath, inflight);
      if (preparedDirect) return;
    }

    // Upload all files (including images) to the server — mirrors OpenWebUI:
    // images go to /api/v1/files/ and the server resolves them when sending to
    // the LLM. The queue is owned by attachmentUploadQueueProvider (one
    // fully-initialized instance per active server); awaiting `.future` avoids
    // the enqueue-before-load race and gives a queue already wired to the
    // active server's API + Drift table.
    final uploader = _ref.read(attachmentUploadQueueProvider);
    if (uploader == null) {
      throw Exception('API not available');
    }
    // Capture the OpenWebUI owner when this upload commits to the server path,
    // not when it later reaches a terminal queue snapshot. An account switch
    // during upload must never place the old response bytes in the new owner's
    // image cache. Local/direct routes intentionally do not initialize the API.
    final uploadApi = _ref.read(apiServiceProvider);
    final imageCacheScope = ImageAttachmentCacheScope(
      api: uploadApi,
      authSessionEpoch: _ref.read(openWebUiAuthSessionEpochProvider),
    );
    final fileCacheOwnership = uploadApi == null
        ? null
        : captureOpenWebUiCacheOwnership(
            _ref,
            api: uploadApi,
            requireAuthenticated: false,
          );
    // Wait for the queue's initial Drift load before enqueueing. `ready` is
    // owned by the queue instance, so awaiting it cannot hang if the owning
    // provider rebuilds on a server switch (unlike a FutureProvider.future).
    await uploader.ready;
    _throwIfOperationNotActive(filePath, inflight);

    // For images: convert unsupported formats to JPEG for compatibility.
    String uploadPath = filePath;
    String uploadFileName = fileName;
    String? uploadMimeType = mimeType;
    String? convertedTempPath;
    if (isImage) {
      final shouldConvert = await _shouldConvertImage(lowerName, fileSize);
      _throwIfOperationNotActive(filePath, inflight);
      if (shouldConvert) {
        final convertedPath = await _ref.read(imageUploadConverterProvider)(
          filePath,
        );
        if (!_isOperationActive(filePath, inflight)) {
          if (convertedPath != null) {
            await cleanupTerminalAttachmentFile(convertedPath);
          }
          throw const MediaUploadCancelledException();
        }
        if (convertedPath != null) {
          final replacementResult =
              await _ref.read(ownedStagingConversionReplacerProvider)(
                originalPath: filePath,
                convertedPath: convertedPath,
                canReplace: () => _isOperationActive(filePath, inflight),
              );
          if (!_isOperationActive(filePath, inflight)) {
            await cleanupTerminalAttachmentFile(convertedPath);
            throw const MediaUploadCancelledException();
          }
          switch (replacementResult) {
            case OwnedStagingConversionReplacementResult.replaced:
              // The durable queue row keeps pointing at the app-owned path, so
              // restored cleanup can release it after a process death.
              uploadPath = filePath;
              break;
            case OwnedStagingConversionReplacementResult.notOwned:
              uploadPath = convertedPath;
              convertedTempPath = convertedPath;
              break;
            case OwnedStagingConversionReplacementResult.failed:
              // Never trade a durable owned path for a conversion temp path
              // when replacement was attempted but failed. Uploading the
              // original preserves restart cleanup and retry ownership.
              uploadPath = filePath;
              final convertedCleaned = await cleanupTerminalAttachmentFile(
                convertedPath,
              );
              _throwIfOperationNotActive(filePath, inflight);
              if (!convertedCleaned) {
                DebugLogger.warning(
                  'failed-conversion-temp-cleanup-deferred',
                  scope: 'media/upload',
                  data: {'fileName': fileName},
                );
              }
              break;
          }
          if (replacementResult !=
              OwnedStagingConversionReplacementResult.failed) {
            final baseName = fileName.contains('.')
                ? fileName.substring(0, fileName.lastIndexOf('.'))
                : fileName;
            uploadFileName = '$baseName.jpg';
            uploadMimeType = 'image/jpeg';
          }
        }
      }
    }

    // Capture the exact bytes the durable row will upload. The SHA-256 stream
    // is memory-bounded for large iOS photos/documents and lets restore-time
    // cleanup reject a pathname that was replaced while the app was dead.
    final int queuedFileSize;
    final String queuedChecksum;
    final String id;
    final bool insertedQueueRow;
    var durableOwnershipEstablished = false;
    var durableOwnershipReleased = false;
    try {
      final identity = await _streamUploadFileIdentity(File(uploadPath));
      queuedFileSize = identity.fileSize;
      queuedChecksum = identity.checksum;
      _throwIfOperationNotActive(filePath, inflight);
      if (checksum != null && checksum != queuedChecksum) {
        DebugLogger.warning(
          'upload-source-checksum-refreshed',
          scope: 'media/upload',
          data: {'fileName': uploadFileName},
        );
      }

      // Once durable acquisition begins, cancellation must wait for a handler
      // that can retire/tombstone the held row before any owned path is
      // unlinked. The owner hold itself is memory-only and cannot close this
      // crash window.
      inflight.expectCancelHandler();
      final durableKey = nativeShareIdentity == null
          ? null
          : _nativeShareReceiptKey(nativeShareIdentity);
      final enqueueResult = await uploader.enqueueOrJoin(
        filePath: uploadPath,
        fileName: uploadFileName,
        fileSize: queuedFileSize,
        mimeType: uploadMimeType,
        checksum: queuedChecksum,
        holdForOwner: true,
        durableKey: durableKey,
        receiptHeld: durableKey != null,
      );
      id = enqueueResult.item.id;
      insertedQueueRow = enqueueResult.inserted;
      // Joinability must consult the queue's synchronous snapshot. Another
      // queue listener can observe a terminal publication and immediately
      // request a retry before this controller's stream listener runs.
      inflight.bindQueueItem(uploader, id);
      if (durableKey != null) {
        inflight.setNativeReceipt(durableKey);
      }
      durableOwnershipEstablished = true;
      await inflight.installCancelHandler(() async {
        var cancellationPersisted = false;
        try {
          cancellationPersisted = await uploader.cancel(id);
        } catch (error, stackTrace) {
          DebugLogger.error(
            'cancelled-held-upload-tombstone-failed',
            scope: 'media/upload',
            error: error,
            stackTrace: stackTrace,
            data: {'id': id, 'fileName': uploadFileName},
          );
        }
        if (!cancellationPersisted) return;

        final sourceCleaned = await _cleanupAttachmentForGeneration(
          targetPath: filePath,
          ownershipPath: filePath,
          inflight: inflight,
          fencePathIdentity: true,
        );
        if (!sourceCleaned) return;
        if (convertedTempPath != null) {
          final tempCleaned = await _cleanupAttachmentForGeneration(
            targetPath: convertedTempPath,
            ownershipPath: filePath,
            inflight: inflight,
            fencePathIdentity: false,
          );
          if (!tempCleaned) return;
        }
        try {
          await uploader.acknowledgeTerminal(id);
          durableOwnershipReleased = true;
        } catch (error, stackTrace) {
          // The cancelled row remains the durable cleanup owner. Restore will
          // observe the now-absent source and retry only the acknowledgement.
          DebugLogger.error(
            'cancelled-held-upload-acknowledgement-failed',
            scope: 'media/upload',
            error: error,
            stackTrace: stackTrace,
            data: {'id': id, 'fileName': uploadFileName},
          );
        }
      });
      if (!_isOperationActive(filePath, inflight)) {
        await inflight.cancel();
        throw const MediaUploadCancelledException();
      }
    } catch (_) {
      if (!durableOwnershipEstablished) {
        inflight.resolveCancelHandlerUnavailable();
      }
      if (convertedTempPath != null &&
          (!durableOwnershipEstablished || durableOwnershipReleased)) {
        try {
          await cleanupTerminalAttachmentFile(convertedTempPath);
        } catch (_) {}
      }
      rethrow;
    }

    final completer = Completer<void>();
    final displayFileName = uploadFileName;
    final tempFilePath = uploadPath != filePath ? uploadPath : null;

    QueuedAttachment? terminalEntryForFinalization;
    Future<void>? terminalFinalization;
    Future<void> finalizeTerminalOwnership({QueuedAttachment? terminalEntry}) {
      terminalEntryForFinalization ??= terminalEntry;
      return terminalFinalization ??= () async {
        final entry = terminalEntryForFinalization;
        if (isImage &&
            _isLatestGeneration(filePath, inflight) &&
            entry?.status == QueuedAttachmentStatus.completed &&
            entry?.fileId != null) {
          try {
            final bytes = await _ref.read(uploadImagePrecacheReaderProvider)(
              uploadPath,
              kUploadImagePrecacheMaxBytes,
            );
            if (bytes != null && _isLatestGeneration(filePath, inflight)) {
              preCacheImageBytes(entry!.fileId!, bytes, scope: imageCacheScope);
            }
          } catch (error, stackTrace) {
            DebugLogger.error(
              'terminal-image-precache-failed',
              scope: 'media/upload',
              error: error,
              stackTrace: stackTrace,
              data: {'fileName': displayFileName},
            );
          }
        }

        // Keep the durable terminal row until every app-owned source/temp path
        // is confirmed absent. A failed cleanup is retried when this server's
        // queue is restored on a later launch.
        final sourceCleaned = await _cleanupAttachmentForGeneration(
          targetPath: filePath,
          ownershipPath: filePath,
          inflight: inflight,
          fencePathIdentity: true,
        );
        if (!sourceCleaned) {
          DebugLogger.warning(
            'terminal-upload-cleanup-deferred',
            scope: 'media/upload',
            data: {'id': id, 'fileName': displayFileName},
          );
          return;
        }

        if (tempFilePath != null) {
          final tempCleaned = await _cleanupAttachmentForGeneration(
            targetPath: tempFilePath,
            ownershipPath: filePath,
            inflight: inflight,
            fencePathIdentity: false,
          );
          if (!tempCleaned) {
            DebugLogger.warning(
              'terminal-upload-cleanup-deferred',
              scope: 'media/upload',
              data: {'id': id, 'fileName': displayFileName},
            );
            return;
          }
        }

        await uploader.acknowledgeTerminal(id);
      }();
    }

    void finalizeTerminalOwnershipDetached(QueuedAttachment terminalEntry) {
      unawaited(() async {
        try {
          await finalizeTerminalOwnership(terminalEntry: terminalEntry);
        } catch (error, stackTrace) {
          DebugLogger.error(
            'terminal-upload-cleanup-failed',
            scope: 'media/upload',
            error: error,
            stackTrace: stackTrace,
            data: {'id': id, 'fileName': displayFileName},
          );
        } finally {
          if (!completer.isCompleted) completer.complete();
        }
      }());
    }

    late final StreamSubscription<List<QueuedAttachment>> sub;

    void reflectQueueSnapshot(List<QueuedAttachment> items) {
      final entry = items.where((e) => e.id == id).firstOrNull;
      if (entry == null) return;

      if (entry.status == QueuedAttachmentStatus.completed ||
          entry.status == QueuedAttachmentStatus.failed ||
          entry.status == QueuedAttachmentStatus.cancelled) {
        // Close the retry/join window before terminal composer publication.
        inflight.markNonJoinable();
      }

      try {
        final existing = _ownedAttachment(filePath, inflight);
        if (existing != null) {
          final status = switch (entry.status) {
            QueuedAttachmentStatus.pending ||
            QueuedAttachmentStatus.uploading => FileUploadStatus.uploading,
            QueuedAttachmentStatus.completed => FileUploadStatus.completed,
            QueuedAttachmentStatus.failed => FileUploadStatus.failed,
            QueuedAttachmentStatus.cancelled => FileUploadStatus.failed,
          };

          if (status == FileUploadStatus.completed && entry.fileId != null) {
            unawaited(
              _syncUploadedFile(
                entry.fileId!,
                api: uploadApi,
                ownership: fileCacheOwnership,
              ),
            );
          }

          final newState = FileUploadState(
            file: File(filePath),
            fileName: displayFileName,
            fileSize: queuedFileSize,
            progress: status == FileUploadStatus.completed
                ? 1.0
                : existing.progress,
            status: status,
            fileId: entry.fileId ?? existing.fileId,
            error: entry.lastError,
            isImage: isImage,
          );
          _updateAttachmentIfOwned(filePath, inflight, newState);
        }
      } catch (error, stackTrace) {
        DebugLogger.error(
          'file-upload-state-update-failed',
          scope: 'media/upload',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
      }

      switch (entry.status) {
        case QueuedAttachmentStatus.completed:
        case QueuedAttachmentStatus.cancelled:
          unawaited(sub.cancel());
          finalizeTerminalOwnershipDetached(entry);
          break;
        case QueuedAttachmentStatus.failed:
          // Failed rows are explicitly retryable. Keep their source and Drift
          // row intact; only settle this execution/listener so a later retry
          // can start a fresh controller generation.
          unawaited(sub.cancel());
          if (!completer.isCompleted) completer.complete();
          break;
        default:
          break;
      }
    }

    sub = uploader.queueStream.listen(
      reflectQueueSnapshot,
      onDone: () {
        // The queue was disposed (server switch / logout) before this upload
        // reached a terminal status. Resolve the awaiting caller so it does not
        // hang; the item stays in the previous server's Drift table and resumes
        // when that server is next active. Do not clean converted temp files
        // here: the kept row still points at the file, which must survive for
        // the resume to succeed. (An interrupted-and-never-resumed upload leaks
        // the temp dir until OS cleanup — preferable to losing the attachment.)
        if (!completer.isCompleted) completer.complete();
      },
    );

    // Wire the cancel path before publishing the attachment so every visible
    // queued item already has terminal and explicit-cancel ownership.
    await inflight.installCancelHandler(() async {
      try {
        final cancellationPersisted = await uploader.cancel(id);
        await sub.cancel();
        if (!cancellationPersisted) {
          DebugLogger.warning(
            'cancelled-upload-persistence-deferred',
            scope: 'media/upload',
            data: {'id': id, 'fileName': displayFileName},
          );
          return;
        }
        final cancelledEntry = uploader.queue
            .where((entry) => entry.id == id)
            .firstOrNull;
        await finalizeTerminalOwnership(terminalEntry: cancelledEntry);
      } finally {
        // Cancellation/finalization errors still propagate to the explicit
        // caller, but the upload execution must settle so its generation and
        // controller resources cannot remain retained forever.
        if (!completer.isCompleted) completer.complete();
      }
    });
    if (!_isOperationActive(filePath, inflight)) {
      try {
        await inflight.cancel();
      } finally {
        // A cancellation already handled by the acquisition-phase handler has
        // no queue-stream terminal event to settle this later completer.
        if (!completer.isCompleted) completer.complete();
      }
      throw const MediaUploadCancelledException();
    }

    // Publishing here transfers UI/staging ownership only after the durable
    // row exists and its terminal listener is installed. Local direct/Hermes
    // routes publish earlier through [onLocalOwnershipAcquired] because their
    // preparation updates the attachment in place.
    try {
      _throwIfOperationNotActive(filePath, inflight);
      onQueueOwnershipAcquired?.call(inflight);
      _captureCurrentAttachment(filePath, inflight);
      _throwIfOperationNotActive(filePath, inflight);
    } catch (error, stackTrace) {
      // The durable row and its lifecycle listener already own the source.
      // A provider teardown or synchronous publication failure must not make
      // the caller reclaim/delete a file that the queue will still consume.
      DebugLogger.error(
        'queued-upload-publication-failed',
        scope: 'media/upload',
        error: error,
        stackTrace: stackTrace,
        data: {'id': id, 'fileName': displayFileName},
      );
    }

    // The queue stream is broadcast and does not replay. A fast upload can
    // become terminal between enqueue() and listener registration, so reflect
    // the queue's retained snapshot once after the subscription is installed.
    reflectQueueSnapshot(uploader.queue);

    // enqueue() has persisted the queue row and this controller has installed
    // its terminal/cancellation ownership before the caller is acknowledged.
    try {
      _throwIfOperationNotActive(filePath, inflight);
      inflight.markAccepted();
    } finally {
      if (insertedQueueRow) uploader.releaseOwnerHold(id);
    }
    await completer.future;
  }

  Future<void> _prepareDirectAttachment({
    required String filePath,
    required String fileName,
    required bool isImage,
    required bool selectedModelSupportsImages,
    required _InflightUpload inflight,
  }) async {
    if (!isImage) {
      if (!isDirectLocalDocumentFileNameSupported(fileName)) {
        throw const DirectChatInputException(
          'Direct chats support local UTF-8 text and DOCX documents.',
        );
      }
      final attachments = _ref.read(attachedFilesProvider);
      final documentPaths = <String>{
        for (final attachment in attachments)
          if (attachment.isImage != true &&
              attachment.status != FileUploadStatus.failed)
            attachment.file.path,
        filePath,
      };
      if (documentPaths.length > kDirectMaxLocalDocuments) {
        throw const DirectChatInputException(
          'Direct chats support up to 4 local documents per message.',
        );
      }
      final file = File(filePath);
      final stat = await file.stat();
      _throwIfOperationNotActive(filePath, inflight);
      if (stat.size > kDirectMaxLocalDocumentBytes) {
        throw const DirectChatInputException(
          'This document exceeds the Direct local-document size limit.',
        );
      }
      final opaqueId = _localDocumentOpaqueId(file, stat);
      _updatePreparedDirectState(
        filePath: filePath,
        fileName: fileName,
        fileSize: stat.size,
        fileId: '$kDirectLocalDocumentAttachmentPrefix$opaqueId',
        isImage: false,
        inflight: inflight,
      );
      return;
    }

    if (!selectedModelSupportsImages) {
      throw const DirectChatInputException(
        'This direct model does not support image attachments.',
      );
    }

    final attachments = _ref.read(attachedFilesProvider);
    final imagesByPath = <String, FileUploadState>{
      for (final attachment in attachments)
        if (attachment.isImage == true &&
            attachment.status != FileUploadStatus.failed)
          attachment.file.path: attachment,
    };
    final imagePaths = <String>{...imagesByPath.keys, filePath};
    if (imagePaths.length > kDirectMaxImages) {
      throw const DirectChatInputException(
        'Direct chats support up to 4 images per request.',
      );
    }

    var measuredTotalBytes = 0;
    var currentSourceBytes = 0;
    for (final path in imagePaths) {
      final attachment = imagesByPath[path];
      final preparedDataUrl =
          attachment?.base64DataUrl ??
          ((attachment?.fileId?.startsWith('data:image/') ?? false)
              ? attachment!.fileId
              : null);
      final bytes = preparedDataUrl != null
          ? decodedImageByteLength(
              preparedDataUrl,
              maxDecodedBytes: kDirectMaxDecodedImageBytes - measuredTotalBytes,
            )
          : await File(path).length();
      _throwIfOperationNotActive(filePath, inflight);
      measuredTotalBytes += bytes;
      if (path == filePath) currentSourceBytes = bytes;
      if (measuredTotalBytes > kDirectMaxDecodedImageBytes) {
        throw const DirectChatInputException(
          'Direct chat images must be 20 MB or less in total.',
        );
      }
    }

    final dataUrl = await _ref.read(directImageDataUrlEncoderProvider)(
      File(filePath),
    );
    _throwIfOperationNotActive(filePath, inflight);
    if (dataUrl == null) {
      throw const DirectChatInputException(
        'The selected image could not be prepared for this direct model.',
      );
    }
    final decodedBytes = validatePreparedDirectImageDataUrl(
      dataUrl,
      otherImageBytes: measuredTotalBytes - currentSourceBytes,
    );

    final existing = _ownedAttachment(filePath, inflight);
    if (existing != null) {
      _updatePreparedDirectState(
        filePath: filePath,
        fileName: existing.fileName,
        fileSize: decodedBytes,
        fileId: dataUrl,
        isImage: true,
        base64DataUrl: dataUrl,
        inflight: inflight,
      );
    }
    // Keep the local staging file composer-owned until removal/clear. Eager
    // deletion from this async continuation cannot be made atomic with a user
    // cancelling and re-staging different bytes at the exact same pathname.
  }

  void _updatePreparedDirectState({
    required String filePath,
    required String fileName,
    required int fileSize,
    required String fileId,
    required bool isImage,
    required _InflightUpload inflight,
    String? base64DataUrl,
  }) {
    final existing = _ownedAttachment(filePath, inflight);
    if (existing == null) return;
    _updateAttachmentIfOwned(
      filePath,
      inflight,
      FileUploadState(
        file: existing.file,
        fileName: fileName,
        fileSize: fileSize,
        progress: 1,
        status: FileUploadStatus.completed,
        fileId: fileId,
        isImage: isImage,
        base64DataUrl: base64DataUrl,
      ),
    );
  }

  Future<void> _prepareHermesAttachment({
    required String filePath,
    required String fileName,
    required bool isImage,
    required _InflightUpload inflight,
  }) async {
    final attachments = _ref.read(attachedFilesProvider);
    final activeAttachments = attachments
        .where((attachment) => attachment.status != FileUploadStatus.failed)
        .toList(growable: false);

    if (!isImage) {
      if (!isHermesLocalDocumentFileNameSupported(fileName)) {
        throw const HermesChatInputException(
          'Hermes supports local UTF-8 text and DOCX documents.',
        );
      }
      final documentPaths = <String>{
        for (final attachment in activeAttachments)
          if (attachment.isImage != true) attachment.file.path,
        filePath,
      };
      if (documentPaths.length > kHermesMaxLocalDocuments) {
        throw const HermesChatInputException(
          'Hermes supports up to 4 local documents per message.',
        );
      }
      final file = File(filePath);
      final stat = await file.stat();
      _throwIfOperationNotActive(filePath, inflight);
      if (stat.size > kHermesMaxLocalDocumentBytes) {
        throw const HermesChatInputException(
          'This document exceeds the Hermes local-document size limit.',
        );
      }
      final opaqueId = _localDocumentOpaqueId(file, stat);
      _updatePreparedHermesState(
        filePath: filePath,
        fileName: fileName,
        fileSize: stat.size,
        fileId: '$kHermesLocalDocumentIdPrefix$opaqueId',
        isImage: false,
        inflight: inflight,
      );
      return;
    }

    final capabilities = hermesCapabilitiesNow(_ref);
    if (!capabilities.inputImages) {
      throw const HermesChatInputException(
        'This Hermes server does not advertise image input support.',
      );
    }

    final imagesByPath = <String, FileUploadState>{
      for (final attachment in activeAttachments)
        if (attachment.isImage == true) attachment.file.path: attachment,
    };
    final imagePaths = <String>{...imagesByPath.keys, filePath};
    if (imagePaths.length > kHermesMaxInlineImages) {
      throw const HermesChatInputException(
        'Hermes supports up to 4 images per message.',
      );
    }

    var measuredTotalBytes = 0;
    var currentSourceBytes = 0;
    for (final path in imagePaths) {
      final attachment = imagesByPath[path];
      final preparedDataUrl =
          attachment?.base64DataUrl ??
          ((attachment?.fileId?.startsWith('data:image/') ?? false)
              ? attachment!.fileId
              : null);
      final int bytes;
      try {
        bytes = preparedDataUrl != null
            ? decodedImageByteLength(
                preparedDataUrl,
                maxDecodedBytes:
                    kHermesMaxDecodedImageBytes - measuredTotalBytes,
              )
            : await File(path).length();
      } on DirectChatInputException catch (error) {
        throw HermesChatInputException(error.message);
      }
      _throwIfOperationNotActive(filePath, inflight);
      measuredTotalBytes += bytes;
      if (path == filePath) currentSourceBytes = bytes;
      if (measuredTotalBytes > kHermesMaxDecodedImageBytes) {
        throw const HermesChatInputException(
          'Hermes images must be 6 MB or less in total.',
        );
      }
    }

    final dataUrl = await _ref.read(directImageDataUrlEncoderProvider)(
      File(filePath),
    );
    _throwIfOperationNotActive(filePath, inflight);
    if (dataUrl == null) {
      throw const HermesChatInputException(
        'The selected image could not be prepared for Hermes.',
      );
    }
    final int decodedBytes;
    try {
      decodedBytes = decodedImageByteLength(
        dataUrl,
        maxDecodedBytes:
            kHermesMaxDecodedImageBytes -
            (measuredTotalBytes - currentSourceBytes),
      );
    } on DirectChatInputException catch (error) {
      throw HermesChatInputException(error.message);
    }
    if (measuredTotalBytes - currentSourceBytes + decodedBytes >
        kHermesMaxDecodedImageBytes) {
      throw const HermesChatInputException(
        'Hermes images must be 6 MB or less in total.',
      );
    }
    _updatePreparedHermesState(
      filePath: filePath,
      fileName: fileName,
      fileSize: decodedBytes,
      fileId: dataUrl,
      isImage: true,
      base64DataUrl: dataUrl,
      inflight: inflight,
    );
    // Composer removal owns cleanup; a cancelled encoder must never delete a
    // newly re-staged image that happens to reuse the same pathname.
  }

  void _updatePreparedHermesState({
    required String filePath,
    required String fileName,
    required int fileSize,
    required String fileId,
    required bool isImage,
    required _InflightUpload inflight,
    String? base64DataUrl,
  }) {
    final existing = _ownedAttachment(filePath, inflight);
    if (existing == null) return;
    _updateAttachmentIfOwned(
      filePath,
      inflight,
      FileUploadState(
        file: existing.file,
        fileName: fileName,
        fileSize: fileSize,
        progress: 1,
        status: FileUploadStatus.completed,
        fileId: fileId,
        isImage: isImage,
        base64DataUrl: base64DataUrl,
      ),
    );
  }

  Future<void> _syncUploadedFile(
    String fileId, {
    required ApiService? api,
    required OpenWebUiCacheOwnershipSnapshot? ownership,
  }) async {
    if (api == null || ownership == null) return;
    try {
      final raw = await api.getFileInfo(fileId);
      if (!openWebUiCacheOwnershipIsCurrent(_ref, ownership)) return;
      final file = FileInfo.fromJson(raw);
      if (!openWebUiCacheOwnershipIsCurrent(_ref, ownership)) return;
      _ref.read(userFilesProvider.notifier).upsert(file);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'upload-sync-failed',
        scope: 'files',
        error: error,
        stackTrace: stackTrace,
        data: {'fileId': fileId},
      );
    }
  }

  /// Whether [lowerName] should be converted to JPEG before upload (carried
  /// verbatim from `task_worker._shouldConvertImage`).
  Future<bool> _shouldConvertImage(String lowerName, int? fileSize) async {
    const alwaysConvert = {
      '.heic',
      '.heif',
      '.dng',
      '.raw',
      '.cr2',
      '.nef',
      '.arw',
      '.orf',
      '.rw2',
      '.bmp',
    };
    if (alwaysConvert.any(lowerName.endsWith)) {
      return true;
    }

    const neverConvert = {'.webp', '.gif'};
    if (neverConvert.any(lowerName.endsWith)) {
      return false;
    }

    const optimizeThreshold = 500 * 1024;
    const optimizableFormats = {'.jpg', '.jpeg', '.png'};
    if (optimizableFormats.any(lowerName.endsWith)) {
      final size = fileSize ?? 0;
      return size > optimizeThreshold;
    }

    return false;
  }
}

/// Converts [filePath] to JPEG for upload (carried verbatim from
/// `task_worker._convertImageForUpload`).
Future<String?> convertImageForUpload(String filePath) async {
  Directory? createdTempDirectory;
  String? completedPath;
  try {
    final file = File(filePath);
    final result = await FlutterImageCompress.compressWithFile(
      file.absolute.path,
      format: CompressFormat.jpeg,
      quality: 90,
    );

    if (result != null && result.isNotEmpty) {
      final tempDir = await Directory.systemTemp.createTemp('conduit_img_');
      createdTempDirectory = tempDir;
      final tempFile = File('${tempDir.path}/converted.jpg');
      await tempFile.writeAsBytes(result);

      DebugLogger.log(
        'Converted image for upload',
        scope: 'media/upload',
        data: {
          'originalFileName': path.basename(filePath),
          'convertedFileName': path.basename(tempFile.path),
          'originalSize': await file.length(),
          'convertedSize': result.length,
        },
      );

      completedPath = tempFile.path;
      return completedPath;
    }
  } catch (e) {
    DebugLogger.error(
      'image-conversion-failed',
      scope: 'media/upload',
      error: e,
    );
  } finally {
    final tempDirectory = createdTempDirectory;
    if (completedPath == null && tempDirectory != null) {
      try {
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      } catch (error) {
        DebugLogger.warning(
          'failed-image-conversion-temp-cleanup-deferred',
          scope: 'media/upload',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    }
  }
  return null;
}

/// Tracks an in-flight upload so [MediaUploadController.cancelUploadsForFile]
/// can stop it.
class _InflightUpload {
  _InflightUpload({required this.generation});

  final int generation;
  bool _cancelled = false;
  bool _joinable = true;
  bool _cancelHandlerStarted = false;
  Future<void> Function()? _onCancel;
  Future<void>? _cancelHandlerFuture;
  Completer<void>? _cancelHandlerReadiness;
  late final Future<void> terminalFuture;
  final Completer<_UploadAcceptance> _acceptance =
      Completer<_UploadAcceptance>();
  FileUploadState? _attachmentOwner;
  AttachmentUploadQueue? _queueOwner;
  String? _queueItemId;
  String? _nativeReceiptKey;
  bool _providedPathOwned = true;
  bool _ownershipAccepted = false;
  bool _executionSettled = false;
  int _cleanupCount = 0;

  bool get isCancelled => _cancelled;
  bool get isJoinable {
    if (_cancelled || !_joinable) return false;
    final queue = _queueOwner;
    final queueItemId = _queueItemId;
    if (queue == null || queueItemId == null) return true;
    final item = queue.queue
        .where((entry) => entry.id == queueItemId)
        .firstOrNull;
    return item != null &&
        item.status != QueuedAttachmentStatus.completed &&
        item.status != QueuedAttachmentStatus.failed &&
        item.status != QueuedAttachmentStatus.cancelled;
  }

  bool get ownershipAccepted => _ownershipAccepted;
  FileUploadState? get attachmentOwner => _attachmentOwner;
  String? get nativeReceiptKey => _nativeReceiptKey;
  bool get providedPathOwned => _providedPathOwned;
  bool get executionSettled => _executionSettled;
  bool get cleanupInProgress => _cleanupCount > 0;

  void bindTerminal(Future<void> terminal) {
    terminalFuture = terminal;
    unawaited(
      terminal.then<void>(
        (_) => markAccepted(),
        onError: (Object error, StackTrace stackTrace) {
          if (!_acceptance.isCompleted) {
            _acceptance.complete((error: error, stackTrace: stackTrace));
          }
        },
      ),
    );
  }

  void captureAttachment(FileUploadState attachment) {
    _attachmentOwner = attachment;
  }

  void bindQueueItem(AttachmentUploadQueue queue, String id) {
    _queueOwner ??= queue;
    _queueItemId ??= id;
    if (!identical(_queueOwner, queue) || _queueItemId != id) {
      throw StateError('An upload cannot join two attachment queue rows.');
    }
  }

  void setNativeReceipt(String receiptKey) {
    _nativeReceiptKey ??= receiptKey;
    if (_nativeReceiptKey != receiptKey) {
      throw StateError('An upload cannot join two native share receipts.');
    }
  }

  void markProvidedPathUnowned() {
    _providedPathOwned = false;
  }

  void markNonJoinable() {
    _joinable = false;
  }

  void markAccepted() {
    _ownershipAccepted = true;
    if (!_acceptance.isCompleted) {
      _acceptance.complete((error: null, stackTrace: null));
    }
  }

  void markExecutionSettled() {
    _executionSettled = true;
  }

  void beginCleanup() {
    _cleanupCount++;
  }

  void endCleanup() {
    assert(_cleanupCount > 0, 'cleanup ownership must be balanced');
    if (_cleanupCount > 0) _cleanupCount--;
  }

  Future<void> waitUntilAccepted() async {
    final result = await _acceptance.future;
    final error = result.error;
    if (error != null) {
      Error.throwWithStackTrace(error, result.stackTrace ?? StackTrace.current);
    }
  }

  Future<void> installCancelHandler(Future<void> Function() handler) async {
    _onCancel = handler;
    final readiness = _cancelHandlerReadiness;
    _cancelHandlerReadiness = null;
    if (readiness != null && !readiness.isCompleted) readiness.complete();
    await _invokeCancelHandlerIfReady();
  }

  void expectCancelHandler() {
    if (_onCancel == null) {
      _cancelHandlerReadiness ??= Completer<void>();
    }
  }

  void resolveCancelHandlerUnavailable() {
    final readiness = _cancelHandlerReadiness;
    _cancelHandlerReadiness = null;
    if (readiness != null && !readiness.isCompleted) readiness.complete();
  }

  Future<bool> cancel() async {
    _cancelled = true;
    _joinable = false;
    final readiness = _cancelHandlerReadiness;
    if (_onCancel == null && readiness != null) {
      await readiness.future;
    }
    return _invokeCancelHandlerIfReady();
  }

  Future<bool> _invokeCancelHandlerIfReady() async {
    final handler = _onCancel;
    if (!_cancelled || handler == null) return false;
    if (_cancelHandlerStarted) {
      await (_cancelHandlerFuture ?? Future<void>.value());
      return true;
    }
    _cancelHandlerStarted = true;
    await (_cancelHandlerFuture = Future<void>.sync(handler));
    return true;
  }
}

typedef _UploadStart = ({_InflightUpload inflight, bool started});
typedef _UploadAcceptance = ({Object? error, StackTrace? stackTrace});

final class MediaUploadCancelledException implements Exception {
  const MediaUploadCancelledException();
}

/// `keepAlive` so the controller's in-flight tracking + `ref` survive across
/// rebuilds (an upload can outlive the widget that started it). Every former
/// `enqueueUploadMedia` call site reads this instead.
@Riverpod(keepAlive: true)
MediaUploadController mediaUploadController(Ref ref) =>
    MediaUploadController(ref);
