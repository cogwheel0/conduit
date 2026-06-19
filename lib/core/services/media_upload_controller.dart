import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/chat/services/file_attachment_service.dart';
import '../../features/chat/widgets/enhanced_image_attachment.dart';
import '../database/database_provider.dart';
import '../models/file_info.dart';
import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';
import 'attachment_upload_queue.dart';
import 'share_staging_cleanup.dart';

part 'media_upload_controller.g.dart';

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
    } catch (_) {
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

    // Upload all files (including images) to the server — mirrors OpenWebUI:
    // images go to /api/v1/files/ and the server resolves them when sending to
    // the LLM.
    final uploader = AttachmentUploadQueue();
    final api = _ref.read(apiServiceProvider);
    if (api == null) {
      throw Exception('API not available');
    }
    await uploader.initialize(
      onUpload: (path, name, {cancelToken}) =>
          api.uploadFile(path, name, cancelToken: cancelToken),
      database: () => _ref.read(appDatabaseProvider),
    );

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
    sub = uploader.queueStream.listen((items) {
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
    });

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
