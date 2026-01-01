import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:typed_data';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/attachment_upload_queue.dart';
import '../../../core/services/worker_manager.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../features/chat/providers/chat_providers.dart' as chat;
import '../../../features/chat/providers/context_attachments_provider.dart';
import '../../../features/chat/services/file_attachment_service.dart';
import '../../../features/chat/widgets/enhanced_image_attachment.dart';
import 'outbound_task.dart';

class TaskWorker {
  final Ref _ref;
  TaskWorker(this._ref);

  Future<void> perform(OutboundTask task) async {
    await task.map<Future<void>>(
      sendTextMessage: _performSendText,
      uploadMedia: _performUploadMedia,
      executeToolCall: _performExecuteToolCall,
      generateImage: _performGenerateImage,
      imageToDataUrl: _performImageToDataUrl,
    );
  }

  Future<void> _performSendText(SendTextMessageTask task) async {
    // Ensure uploads referenced in attachments are completed if they are local queued ids
    // For now, assume attachments are already uploaded (fileIds or data URLs) as UI uploads eagerly.
    // If needed, we could resolve queued uploads here by integrating with AttachmentUploadQueue.
    final isReviewer = _ref.read(reviewerModeProvider);
    if (!isReviewer) {
      final api = _ref.read(apiServiceProvider);
      if (api == null) {
        throw Exception('API not available');
      }
    }

    // Set active conversation if provided; otherwise keep current
    try {
      // If a specific conversation id is provided and differs from current, load it
      final active = _ref.read(activeConversationProvider);
      if (task.conversationId != null &&
          task.conversationId!.isNotEmpty &&
          (active == null || active.id != task.conversationId)) {
        try {
          final api = _ref.read(apiServiceProvider);
          if (api != null) {
            final conv = await api.getConversation(task.conversationId!);
            _ref.read(activeConversationProvider.notifier).set(conv);
          }
        } catch (_) {
          // If loading fails, proceed; send flow can create a new conversation
        }
      }
    } catch (_) {}

    // Delegate to existing unified send implementation.
    // Always clear context attachments after send, even on failure,
    // to prevent stale attachments from leaking into subsequent messages.
    try {
      await chat.sendMessageFromService(
        _ref,
        task.text,
        task.attachments.isEmpty ? null : task.attachments,
        task.toolIds.isEmpty ? null : task.toolIds,
      );
    } finally {
      try {
        _ref.read(contextAttachmentsProvider.notifier).clear();
      } catch (_) {}
    }
  }

  Future<void> _performUploadMedia(UploadMediaTask task) async {
    final lowerName = task.fileName.toLowerCase();
    final bool isImage = allSupportedImageFormats.any(lowerName.endsWith);

    // Upload all files (including images) to server
    // This mirrors OpenWebUI's approach: images are uploaded to /api/v1/files/
    // and the server resolves them when sending to LLM
    final uploader = AttachmentUploadQueue();
    try {
      final api = _ref.read(apiServiceProvider);
      if (api != null) {
        await uploader.initialize(onUpload: (p, n) => api.uploadFile(p, n));
      }
    } catch (_) {}

    // For images: convert unsupported formats and optimize large JPEG/PNG
    String uploadPath = task.filePath;
    String uploadFileName = task.fileName;
    String? uploadMimeType = task.mimeType;
    if (isImage) {
      final shouldConvert = await _shouldConvertImage(lowerName, task.fileSize);
      if (shouldConvert) {
        final convertedPath = await _convertImageForUpload(task);
        if (convertedPath != null) {
          uploadPath = convertedPath;
          // Update filename to .webp extension since we converted the format
          final baseName = task.fileName.contains('.')
              ? task.fileName.substring(0, task.fileName.lastIndexOf('.'))
              : task.fileName;
          uploadFileName = '$baseName.webp';
          uploadMimeType = 'image/webp';
        }
      }
    }

    // Read image bytes before upload for instant display cache
    Uint8List? imageBytes;
    if (isImage) {
      try {
        imageBytes = await File(uploadPath).readAsBytes();
      } catch (_) {}
    }

    final id = await uploader.enqueue(
      filePath: uploadPath,
      fileName: uploadFileName,
      fileSize: task.fileSize ?? 0,
      mimeType: uploadMimeType,
      checksum: task.checksum,
    );

    final completer = Completer<void>();
    // Capture values for use in closure
    final displayFileName = uploadFileName;
    final cachedBytes = imageBytes;
    final tempFilePath = uploadPath != task.filePath ? uploadPath : null;
    late final StreamSubscription<List<QueuedAttachment>> sub;
    sub = uploader.queueStream.listen((items) {
      QueuedAttachment? entry;
      try {
        entry = items.firstWhere((e) => e.id == id);
      } catch (_) {
        entry = null;
      }
      if (entry == null) return;

      try {
        final current = _ref.read(attachedFilesProvider);
        final idx = current.indexWhere((f) => f.file.path == task.filePath);
        if (idx != -1) {
          final existing = current[idx];
          final status = switch (entry.status) {
            QueuedAttachmentStatus.pending => FileUploadStatus.uploading,
            QueuedAttachmentStatus.uploading => FileUploadStatus.uploading,
            QueuedAttachmentStatus.completed => FileUploadStatus.completed,
            QueuedAttachmentStatus.failed => FileUploadStatus.failed,
            QueuedAttachmentStatus.cancelled => FileUploadStatus.failed,
          };

          // Pre-cache image bytes for instant display when upload completes
          if (status == FileUploadStatus.completed &&
              entry.fileId != null &&
              cachedBytes != null) {
            preCacheImageBytes(entry.fileId!, cachedBytes);
          }

          final newState = FileUploadState(
            file: File(task.filePath),
            fileName: displayFileName,
            fileSize: task.fileSize ?? existing.fileSize,
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
              .updateFileState(task.filePath, newState);
        }
      } catch (_) {}
      switch (entry.status) {
        case QueuedAttachmentStatus.completed:
        case QueuedAttachmentStatus.failed:
        case QueuedAttachmentStatus.cancelled:
          sub.cancel();
          // Clean up temp file from image conversion
          if (tempFilePath != null) {
            try {
              File(tempFilePath).parent.deleteSync(recursive: true);
            } catch (_) {}
          }
          completer.complete();
          break;
        default:
          break;
      }
    });

    unawaited(uploader.processQueue());
    await completer.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        try {
          sub.cancel();
        } catch (_) {}

        // Clean up temp file on timeout
        if (tempFilePath != null) {
          try {
            File(tempFilePath).parent.deleteSync(recursive: true);
          } catch (_) {}
        }

        // Update state to failed on timeout
        try {
          final current = _ref.read(attachedFilesProvider);
          final idx = current.indexWhere((f) => f.file.path == task.filePath);
          if (idx != -1) {
            final existing = current[idx];
            final newState = FileUploadState(
              file: File(task.filePath),
              fileName: displayFileName,
              fileSize: task.fileSize ?? existing.fileSize,
              progress: 0.0,
              status: FileUploadStatus.failed,
              error: 'Upload timed out',
              isImage: isImage,
            );
            _ref
                .read(attachedFilesProvider.notifier)
                .updateFileState(task.filePath, newState);
          }
        } catch (_) {}

        DebugLogger.warning('UploadMediaTask timed out: ${task.fileName}');
        return;
      },
    );
  }

  /// Check if image should be converted to WebP before upload
  /// - Always convert: HEIC, RAW formats, BMP (unsupported or inefficient)
  /// - Optimize if large: JPEG, PNG > 500KB
  /// - Never convert: WebP (already optimal), GIF (may be animated)
  Future<bool> _shouldConvertImage(String lowerName, int? fileSize) async {
    // Always convert these formats (unsupported by some backends or inefficient)
    const alwaysConvert = {
      '.heic', '.heif', '.dng', '.raw', '.cr2', '.nef', '.arw', '.orf', '.rw2', '.bmp',
    };
    if (alwaysConvert.any(lowerName.endsWith)) {
      return true;
    }

    // Never convert these (already optimal or special format)
    const neverConvert = {'.webp', '.gif'};
    if (neverConvert.any(lowerName.endsWith)) {
      return false;
    }

    // Optimize large JPEG/PNG (> 500KB)
    const optimizeThreshold = 500 * 1024; // 500KB
    const optimizableFormats = {'.jpg', '.jpeg', '.png'};
    if (optimizableFormats.any(lowerName.endsWith)) {
      final size = fileSize ?? 0;
      return size > optimizeThreshold;
    }

    return false;
  }

  /// Convert image to WebP for upload if needed
  Future<String?> _convertImageForUpload(UploadMediaTask task) async {
    try {
      final file = File(task.filePath);
      final result = await FlutterImageCompress.compressWithFile(
        file.absolute.path,
        format: CompressFormat.webp,
        quality: 85,
      );
      
      if (result != null && result.isNotEmpty) {
        // Write to temp file for upload
        final tempDir = await Directory.systemTemp.createTemp('conduit_img_');
        final tempFile = File('${tempDir.path}/converted.webp');
        await tempFile.writeAsBytes(result);
        
        DebugLogger.log(
          'Converted image for upload',
          scope: 'tasks/upload',
          data: {
            'original': task.filePath,
            'converted': tempFile.path,
            'originalSize': await file.length(),
            'convertedSize': result.length,
          },
        );
        
        return tempFile.path;
      }
    } catch (e) {
      DebugLogger.error('image-conversion-failed', scope: 'tasks/upload', error: e);
    }
    return null;
  }

  Future<void> _performExecuteToolCall(ExecuteToolCallTask task) async {
    // Resolve API + selected model
    final api = _ref.read(apiServiceProvider);
    final selectedModel = _ref.read(selectedModelProvider);
    if (api == null || selectedModel == null) {
      throw Exception('API or model not available');
    }

    // Optionally bring the target conversation to foreground
    try {
      final active = _ref.read(activeConversationProvider);
      if (task.conversationId != null &&
          task.conversationId!.isNotEmpty &&
          (active == null || active.id != task.conversationId)) {
        try {
          final conv = await api.getConversation(task.conversationId!);
          _ref.read(activeConversationProvider.notifier).set(conv);
        } catch (_) {}
      }
    } catch (_) {}

    // Lookup tool by name (or id fallback)
    String? resolvedToolId;
    try {
      final tools = await api.getAvailableTools();
      for (final t in tools) {
        final id = (t['id'] ?? '').toString();
        final name = (t['name'] ?? '').toString();
        if (name.toLowerCase() == task.toolName.toLowerCase() ||
            id.toLowerCase() == task.toolName.toLowerCase()) {
          resolvedToolId = id;
          break;
        }
      }
    } catch (_) {}

    // Build an explicit user instruction to run the tool with arguments.
    // Passing the specific tool id hints the server/provider to execute it via native function calling.
    final args = task.arguments;
    String argsSnippet;
    try {
      argsSnippet = const JsonEncoder.withIndent('  ').convert(args);
    } catch (_) {
      argsSnippet = args.toString();
    }
    final instruction =
        'Run the tool "${task.toolName}" with the following JSON arguments and return the result succinctly.\n'
        'If the tool is not available, respond with a brief error.\n\n'
        'Arguments:\n'
        '```json\n$argsSnippet\n```';

    // Send as a normal message but constrain tools to the resolved tool (if found)
    final toolIds = (resolvedToolId != null && resolvedToolId.isNotEmpty)
        ? <String>[resolvedToolId]
        : null;

    await chat.sendMessageFromService(_ref, instruction, null, toolIds);
  }

  Future<void> _performGenerateImage(GenerateImageTask task) async {
    final api = _ref.read(apiServiceProvider);
    final selectedModel = _ref.read(selectedModelProvider);
    if (api == null || selectedModel == null) {
      throw Exception('API or model not available');
    }

    // Ensure the target conversation is active if provided
    try {
      final active = _ref.read(activeConversationProvider);
      if (task.conversationId != null &&
          task.conversationId!.isNotEmpty &&
          (active == null || active.id != task.conversationId)) {
        try {
          final conv = await api.getConversation(task.conversationId!);
          _ref.read(activeConversationProvider.notifier).set(conv);
        } catch (_) {}
      }
    } catch (_) {}

    // Temporarily enable image-generation background flow for this send
    final prev = _ref.read(chat.imageGenerationEnabledProvider);
    try {
      _ref.read(chat.imageGenerationEnabledProvider.notifier).set(true);
      await chat.sendMessageFromService(_ref, task.prompt, null, null);
    } finally {
      _ref.read(chat.imageGenerationEnabledProvider.notifier).set(prev);
    }
  }

  Future<void> _performImageToDataUrl(ImageToDataUrlTask task) async {
    // Convert image to base64 data URL locally (matching web client behavior)
    try {
      final file = File(task.filePath);
      final worker = _ref.read(workerManagerProvider);
      final base64DataUrl = await convertImageFileToDataUrl(
        file,
        worker: worker,
      );

      if (base64DataUrl == null) {
        throw Exception('Failed to convert image to base64');
      }

      // Update attachment state with base64 data URL
      final current = _ref.read(attachedFilesProvider);
      final idx = current.indexWhere((f) => f.file.path == task.filePath);
      if (idx != -1) {
        final existing = current[idx];
        final newState = FileUploadState(
          file: file,
          fileName: task.fileName,
          fileSize: existing.fileSize,
          progress: 1.0,
          status: FileUploadStatus.completed,
          fileId: base64DataUrl,
          isImage: true,
          base64DataUrl: base64DataUrl,
        );
        _ref
            .read(attachedFilesProvider.notifier)
            .updateFileState(task.filePath, newState);
      }

      DebugLogger.log(
        'image-to-dataurl-complete',
        scope: 'tasks/image',
        data: {
          'fileName': task.fileName,
          'dataUrlLength': base64DataUrl.length,
        },
      );
    } catch (e) {
      DebugLogger.error(
        'image-to-dataurl-failed',
        scope: 'tasks/image',
        error: e,
      );
      // Update state to failed
      try {
        final current = _ref.read(attachedFilesProvider);
        final idx = current.indexWhere((f) => f.file.path == task.filePath);
        if (idx != -1) {
          final existing = current[idx];
          final newState = FileUploadState(
            file: File(task.filePath),
            fileName: task.fileName,
            fileSize: existing.fileSize,
            progress: 0.0,
            status: FileUploadStatus.failed,
            error: e.toString(),
            isImage: true,
          );
          _ref
              .read(attachedFilesProvider.notifier)
              .updateFileState(task.filePath, newState);
        }
      } catch (_) {}
    }
  }
}
