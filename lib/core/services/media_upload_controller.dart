import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:synchronized/synchronized.dart';

import '../../features/chat/services/file_attachment_service.dart';
import '../../features/chat/widgets/enhanced_image_attachment.dart';
import '../../features/direct_connections/direct_connections.dart';
import '../models/file_info.dart';
import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';
import 'attachment_upload_queue.dart';
import 'share_staging_cleanup.dart';

part 'media_upload_controller.g.dart';

typedef DirectImageDataUrlEncoder = Future<String?> Function(File file);

/// Encoding seam used to prove oversized files are rejected before base64
/// allocation. Production keeps the existing compatibility conversion path.
final directImageDataUrlEncoderProvider = Provider<DirectImageDataUrlEncoder>(
  (ref) => convertImageFileToDataUrl,
);

/// Validates an encoder result without allocating a second decoded image.
/// Returns the current image's decoded byte count for persisted UI metadata.
int validatePreparedDirectImageDataUrl(
  String dataUrl, {
  required int otherImageBytes,
  int maxDecodedImageBytes = kDirectMaxDecodedImageBytes,
}) {
  final decodedBytes = decodedImageByteLength(dataUrl);
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
class MediaUploadController {
  MediaUploadController(this._ref);

  final Ref _ref;
  final Lock _directImagePreparationLock = Lock();

  /// In-flight uploads keyed by the ORIGINAL source [filePath] (the key the UI
  /// + cancellation reference, never the converted temp path). Multiple callers
  /// can race the same source path, so cancellation owns every token for a path.
  final Map<String, Set<_InflightUpload>> _inflight =
      <String, Set<_InflightUpload>>{};

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
  }) async {
    try {
      await _uploadInner(
        filePath: filePath,
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
        checksum: checksum,
      );
    } catch (error) {
      final current = _ref.read(attachedFilesProvider);
      final existing = current
          .where((attachment) => attachment.file.path == filePath)
          .firstOrNull;
      if (existing != null && existing.status != FileUploadStatus.completed) {
        _ref
            .read(attachedFilesProvider.notifier)
            .updateFileState(
              filePath,
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
      unawaited(deleteShareStagingFile(filePath));
      rethrow;
    }
  }

  /// Cancels any in-flight upload for [filePath] and performs the share-staging
  /// cleanup the legacy `task_queue.cancelUploadsForFile` did. Safe to call when
  /// no upload is in flight (still runs the staging cleanup, matching the
  /// legacy "always delete the staged copy" behavior on attachment removal).
  Future<void> cancelUploadsForFile(String filePath) async {
    final inflights = _inflight.remove(filePath);
    if (inflights != null) {
      await Future.wait([for (final inflight in inflights) inflight.cancel()]);
    }
    unawaited(deleteShareStagingFile(filePath));
  }

  Future<void> _uploadInner({
    required String filePath,
    required String fileName,
    required int? fileSize,
    required String? mimeType,
    required String? checksum,
  }) async {
    final lowerName = fileName.toLowerCase();
    final bool isImage = allSupportedImageFormats.any(lowerName.endsWith);

    final selectedModel = _ref.read(selectedModelProvider);
    final directBinding = selectedModel == null
        ? null
        : _ref.read(directModelRegistryProvider).resolve(selectedModel);
    final reservedDirectIdentity =
        selectedModel != null && hasReservedDirectIdentity(selectedModel);
    if (reservedDirectIdentity) {
      if (directBinding == null) {
        throw const DirectChatInputException(
          'The selected direct model is no longer available.',
        );
      }
      await _directImagePreparationLock.synchronized(
        () => _prepareDirectImage(
          filePath: filePath,
          isImage: isImage,
          selectedModelSupportsImages: selectedModel.isMultimodal == true,
        ),
      );
      return;
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
    // Wait for the queue's initial Drift load before enqueueing. `ready` is
    // owned by the queue instance, so awaiting it cannot hang if the owning
    // provider rebuilds on a server switch (unlike a FutureProvider.future).
    await uploader.ready;

    // For images: convert unsupported formats to JPEG for compatibility.
    String uploadPath = filePath;
    String uploadFileName = fileName;
    String? uploadMimeType = mimeType;
    String? convertedTempPath;
    if (isImage) {
      final shouldConvert = await _shouldConvertImage(lowerName, fileSize);
      if (shouldConvert) {
        final convertedPath = await _convertImageForUpload(filePath);
        if (convertedPath != null) {
          uploadPath = convertedPath;
          convertedTempPath = convertedPath;
          final baseName = fileName.contains('.')
              ? fileName.substring(0, fileName.lastIndexOf('.'))
              : fileName;
          uploadFileName = '$baseName.jpg';
          uploadMimeType = 'image/jpeg';
        }
      }
    }

    // The work below (image-bytes read + enqueue) runs after the converted temp
    // dir exists but before the queueStream listener / onCancel cleanup is
    // wired. If any of it throws, control unwinds past the normal terminal
    // cleanup, so the converted conduit_img_* temp dir would leak. Clean it up
    // on this abort/error path only — never on the success path, where the queue
    // still reads the file asynchronously during processQueue.
    final Uint8List? imageBytes;
    final String id;
    try {
      // Read image bytes before upload for instant display cache.
      Uint8List? cachedImageBytes;
      if (isImage) {
        try {
          cachedImageBytes = await File(uploadPath).readAsBytes();
        } catch (error, stackTrace) {
          DebugLogger.error(
            'image-upload-cache-read-failed',
            scope: 'media/upload',
            error: error,
            stackTrace: stackTrace,
            data: {'fileName': uploadFileName},
          );
        }
      }
      imageBytes = cachedImageBytes;

      id = await uploader.enqueue(
        filePath: uploadPath,
        fileName: uploadFileName,
        fileSize: fileSize ?? 0,
        mimeType: uploadMimeType,
        checksum: checksum,
      );
    } catch (_) {
      if (convertedTempPath != null) {
        try {
          File(convertedTempPath).parent.deleteSync(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }

    final completer = Completer<void>();
    final displayFileName = uploadFileName;
    final tempFilePath = uploadPath != filePath ? uploadPath : null;

    final inflight = _InflightUpload();
    (_inflight[filePath] ??= <_InflightUpload>{}).add(inflight);

    void removeInflight() {
      final inflights = _inflight[filePath];
      if (inflights == null) return;
      inflights.remove(inflight);
      if (inflights.isEmpty) {
        _inflight.remove(filePath);
      }
    }

    void cleanupTemp() {
      if (tempFilePath != null) {
        try {
          File(tempFilePath).parent.deleteSync(recursive: true);
        } catch (_) {}
      }
    }

    late final StreamSubscription<List<QueuedAttachment>> sub;
    sub = uploader.queueStream.listen(
      (items) {
        final entry = items.where((e) => e.id == id).firstOrNull;
        if (entry == null) return;

        try {
          final current = _ref.read(attachedFilesProvider);
          final idx = current.indexWhere((f) => f.file.path == filePath);
          if (idx != -1) {
            final existing = current[idx];
            final status = switch (entry.status) {
              QueuedAttachmentStatus.pending ||
              QueuedAttachmentStatus.uploading => FileUploadStatus.uploading,
              QueuedAttachmentStatus.completed => FileUploadStatus.completed,
              QueuedAttachmentStatus.failed => FileUploadStatus.failed,
              QueuedAttachmentStatus.cancelled => FileUploadStatus.failed,
            };

            if (status == FileUploadStatus.completed &&
                entry.fileId != null &&
                imageBytes != null) {
              preCacheImageBytes(entry.fileId!, imageBytes);
            }

            if (status == FileUploadStatus.completed && entry.fileId != null) {
              unawaited(_syncUploadedFile(entry.fileId!));
            }

            final newState = FileUploadState(
              file: File(filePath),
              fileName: displayFileName,
              fileSize: fileSize ?? existing.fileSize,
              progress: status == FileUploadStatus.completed
                  ? 1.0
                  : existing.progress,
              status: status,
              fileId: entry.fileId ?? existing.fileId,
              error: entry.lastError,
              isImage: isImage,
            );
            _ref
                .read(attachedFilesProvider.notifier)
                .updateFileState(filePath, newState);
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
          case QueuedAttachmentStatus.failed:
          case QueuedAttachmentStatus.cancelled:
            unawaited(deleteShareStagingFile(filePath));
            unawaited(sub.cancel());
            cleanupTemp();
            removeInflight();
            if (!completer.isCompleted) completer.complete();
            break;
          default:
            break;
        }
      },
      onDone: () {
        // The queue was disposed (server switch / logout) before this upload
        // reached a terminal status. Resolve the awaiting caller so it does not
        // hang; the item stays in the previous server's Drift table and resumes
        // when that server is next active. Do NOT cleanupTemp() here: the kept
        // row still points at the converted temp file, which must survive for the
        // resume to succeed. (An interrupted-and-never-resumed upload leaks the
        // temp dir until OS cleanup — preferable to losing the attachment.)
        removeInflight();
        if (!completer.isCompleted) completer.complete();
      },
    );

    // Wire the cancel path: stop listening + temp cleanup, then complete so the
    // awaiting caller unblocks (the legacy cancel flipped task state and let the
    // queue settle; here we resolve the future).
    inflight.onCancel = () async {
      await uploader.cancel(id);
      await sub.cancel();
      cleanupTemp();
      removeInflight();
      if (!completer.isCompleted) completer.complete();
    };

    unawaited(uploader.processQueue());
    await completer.future;
  }

  Future<void> _prepareDirectImage({
    required String filePath,
    required bool isImage,
    required bool selectedModelSupportsImages,
  }) async {
    if (!selectedModelSupportsImages) {
      throw const DirectChatInputException(
        'This direct model does not support image attachments.',
      );
    }
    if (!isImage) {
      throw const DirectChatInputException(
        'Direct chats support image attachments only.',
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
          ? decodedImageByteLength(preparedDataUrl)
          : await File(path).length();
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
    if (dataUrl == null) {
      throw const DirectChatInputException(
        'The selected image could not be prepared for this direct model.',
      );
    }
    final decodedBytes = validatePreparedDirectImageDataUrl(
      dataUrl,
      otherImageBytes: measuredTotalBytes - currentSourceBytes,
    );

    final current = _ref.read(attachedFilesProvider);
    final existing = current
        .where((attachment) => attachment.file.path == filePath)
        .firstOrNull;
    if (existing != null) {
      _ref
          .read(attachedFilesProvider.notifier)
          .updateFileState(
            filePath,
            FileUploadState(
              file: existing.file,
              fileName: existing.fileName,
              fileSize: decodedBytes,
              progress: 1,
              status: FileUploadStatus.completed,
              fileId: dataUrl,
              isImage: true,
              base64DataUrl: dataUrl,
            ),
          );
    }
    // Shared-intent and camera staging files are no longer needed once the
    // direct attachment owns an in-memory data URL.
    unawaited(deleteShareStagingFile(filePath));
  }

  Future<void> _syncUploadedFile(String fileId) async {
    final api = _ref.read(apiServiceProvider);
    if (api == null) return;
    try {
      final raw = await api.getFileInfo(fileId);
      final file = FileInfo.fromJson(raw);
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

  /// Converts [filePath] to JPEG for upload (carried verbatim from
  /// `task_worker._convertImageForUpload`).
  Future<String?> _convertImageForUpload(String filePath) async {
    try {
      final file = File(filePath);
      final result = await FlutterImageCompress.compressWithFile(
        file.absolute.path,
        format: CompressFormat.jpeg,
        quality: 90,
      );

      if (result != null && result.isNotEmpty) {
        final tempDir = await Directory.systemTemp.createTemp('conduit_img_');
        final tempFile = File('${tempDir.path}/converted.jpg');
        await tempFile.writeAsBytes(result);

        DebugLogger.log(
          'Converted image for upload',
          scope: 'media/upload',
          data: {
            'original': filePath,
            'converted': tempFile.path,
            'originalSize': await file.length(),
            'convertedSize': result.length,
          },
        );

        return tempFile.path;
      }
    } catch (e) {
      DebugLogger.error(
        'image-conversion-failed',
        scope: 'media/upload',
        error: e,
      );
    }
    return null;
  }
}

/// Tracks an in-flight upload so [MediaUploadController.cancelUploadsForFile]
/// can stop it.
class _InflightUpload {
  Future<void> Function()? onCancel;

  Future<void> cancel() async {
    final fn = onCancel;
    if (fn != null) await fn();
  }
}

/// `keepAlive` so the controller's in-flight tracking + `ref` survive across
/// rebuilds (an upload can outlive the widget that started it). Every former
/// `enqueueUploadMedia` call site reads this instead.
@Riverpod(keepAlive: true)
MediaUploadController mediaUploadController(Ref ref) =>
    MediaUploadController(ref);
