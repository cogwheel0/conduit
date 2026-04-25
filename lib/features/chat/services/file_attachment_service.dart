import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import '../../../core/providers/app_providers.dart';
import '../../../core/models/file_info.dart';
import '../../../shared/utils/file_type_utils.dart';
import '../../../core/services/worker_manager.dart';
import '../../../core/utils/debug_logger.dart';

/// Standard web image formats that LLMs can process directly.
const Set<String> _standardImageFormats = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
};

/// Formats that should always be converted to JPEG for compatibility.
const Set<String> _alwaysConvertFormats = {
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

/// Formats that should never be converted (animation, already optimal).
const Set<String> _preserveFormats = {'.gif', '.webp'};

/// All supported image formats (both standard and those requiring conversion).
const Set<String> allSupportedImageFormats = {
  ..._standardImageFormats,
  ..._alwaysConvertFormats,
};

/// Returns true if the extension always requires conversion to JPEG.
bool _alwaysNeedsConversion(String extension) {
  return _alwaysConvertFormats.contains(extension);
}

/// Returns true if the format should be preserved as-is.
bool _shouldPreserve(String extension) {
  return _preserveFormats.contains(extension);
}

String _mimeTypeForExtension(String extension) {
  return switch (extension) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.png' => 'image/png',
    '.gif' => 'image/gif',
    '.webp' => 'image/webp',
    _ => 'image/jpeg',
  };
}

String _extractMimeTypeFromDataUrl(String imageDataUrl) {
  final match = RegExp(r'^data:([^;]+);').firstMatch(imageDataUrl);
  return match?.group(1)?.toLowerCase() ?? 'image/png';
}

/// Top-level function for base64 encoding in an isolate.
String _encodeToDataUrlWorker(Map<String, dynamic> payload) {
  final bytes = payload['bytes'] as List<int>;
  final mimeType = payload['mimeType'] as String;
  return 'data:$mimeType;base64,${base64Encode(bytes)}';
}

/// Helper to encode bytes to data URL, using isolate when worker is provided.
Future<String> _encodeToDataUrl(
  List<int> bytes,
  String mimeType,
  WorkerManager? worker,
) async {
  if (worker != null && bytes.length > 50 * 1024) {
    // Use isolate for files > 50KB
    return worker.schedule(_encodeToDataUrlWorker, {
      'bytes': bytes,
      'mimeType': mimeType,
    }, debugLabel: 'base64-encode');
  }
  // Small files: encode on main thread
  return 'data:$mimeType;base64,${base64Encode(bytes)}';
}

/// Converts an image file to a base64 data URL with compatibility-first rules.
/// This is a standalone utility used by both FileAttachmentService and TaskWorker.
///
/// Conversion strategy:
/// - HEIC/HEIF/RAW/BMP → Always convert to JPEG
/// - JPEG/PNG → Preserve as-is
/// - GIF → Preserve (maintains animation)
/// - WebP → Preserve
///
/// If [worker] is provided, base64 encoding runs in a background isolate
/// to avoid blocking the UI thread for large images.
///
/// Returns null if conversion fails for formats requiring conversion.
Future<String?> convertImageFileToDataUrl(
  File imageFile, {
  WorkerManager? worker,
}) async {
  try {
    final ext = path.extension(imageFile.path).toLowerCase();
    final fileSize = await imageFile.length();

    // Formats that must always be converted (HEIC, RAW, BMP, etc.)
    if (_alwaysNeedsConversion(ext)) {
      DebugLogger.log(
        'Converting image from $ext to JPEG (required)',
        scope: 'attachments',
        data: {'path': imageFile.path, 'size': fileSize},
      );

      final convertedBytes = await _convertToJpeg(imageFile);
      if (convertedBytes != null) {
        return _encodeToDataUrl(convertedBytes, 'image/jpeg', worker);
      }

      DebugLogger.warning(
        'Conversion failed for $ext format, cannot process image',
      );
      return null;
    }

    // Formats that should be preserved as-is (GIF, WebP)
    if (_shouldPreserve(ext)) {
      final bytes = await imageFile.readAsBytes();
      final mimeType = ext == '.gif' ? 'image/gif' : 'image/webp';
      return _encodeToDataUrl(bytes, mimeType, worker);
    }

    // Pass through standard browser-readable formats as-is.
    final bytes = await imageFile.readAsBytes();
    final mimeType = _mimeTypeForExtension(ext);
    return _encodeToDataUrl(bytes, mimeType, worker);
  } catch (e) {
    DebugLogger.error('convert-image-failed', scope: 'attachments', error: e);
    return null;
  }
}

/// Converts an image file to JPEG bytes for broad compatibility.
Future<List<int>?> _convertToJpeg(File imageFile) async {
  try {
    final result = await FlutterImageCompress.compressWithFile(
      imageFile.absolute.path,
      format: CompressFormat.jpeg,
      quality: 90,
    );

    if (result != null && result.isNotEmpty) {
      DebugLogger.log(
        'Image converted to JPEG successfully',
        scope: 'attachments',
        data: {'originalPath': imageFile.path, 'resultSize': result.length},
      );
      return result;
    }

    return null;
  } catch (e) {
    DebugLogger.error('jpeg-conversion-failed', scope: 'attachments', error: e);
    return null;
  }
}

String _deriveDisplayName({
  required String? preferredName,
  required String filePath,
  String fallbackPrefix = 'attachment',
}) {
  final String candidate =
      (preferredName != null && preferredName.trim().isNotEmpty)
      ? preferredName.trim()
      : path.basename(filePath);

  final String pathExt = path.extension(filePath);
  final String candidateExt = path.extension(candidate);
  final String extension = (candidateExt.isNotEmpty ? candidateExt : pathExt)
      .toLowerCase();

  if (candidate.toLowerCase().startsWith('image_picker')) {
    return _timestampedName(prefix: fallbackPrefix, extension: extension);
  }

  if (candidate.isEmpty) {
    return _timestampedName(prefix: fallbackPrefix, extension: extension);
  }

  return candidate;
}

String _timestampedName({required String prefix, required String extension}) {
  final DateTime now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  final String ext = extension.isNotEmpty ? extension : '.jpg';
  final String timestamp =
      '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  return '${prefix}_$timestamp$ext';
}

/// Represents a locally selected attachment with a user-facing display name.
class LocalAttachment {
  LocalAttachment({required this.file, required this.displayName});

  final File file;
  final String displayName;

  int get sizeInBytes => file.lengthSync();

  String get extension {
    final fromName = path.extension(displayName);
    if (fromName.isNotEmpty) {
      return fromName.toLowerCase();
    }
    return path.extension(file.path).toLowerCase();
  }

  bool get isImage => allSupportedImageFormats.contains(extension);
}

class FileAttachmentService {
  final ImagePicker _imagePicker = ImagePicker();

  FileAttachmentService();

  // Pick files from device
  Future<List<LocalAttachment>> pickFiles({
    bool allowMultiple = true,
    List<String>? allowedExtensions,
  }) async {
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: allowMultiple,
        type: allowedExtensions != null ? FileType.custom : FileType.any,
        allowedExtensions: allowedExtensions,
      );

      if (result == null || result.files.isEmpty) {
        return [];
      }

      return result.files.where((file) => file.path != null).map((file) {
        final displayName = _deriveDisplayName(
          preferredName: file.name,
          filePath: file.path!,
          fallbackPrefix: 'attachment',
        );
        return LocalAttachment(
          file: File(file.path!),
          displayName: displayName,
        );
      }).toList();
    } catch (e) {
      throw Exception('Failed to pick files: $e');
    }
  }

  // Pick image from gallery
  Future<LocalAttachment?> pickImage() async {
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: false,
        type: FileType.image,
      );

      if (result != null && result.files.isNotEmpty) {
        final platformFile = result.files.first;
        if (platformFile.path != null) {
          final displayName = _deriveDisplayName(
            preferredName: platformFile.name,
            filePath: platformFile.path!,
            fallbackPrefix: 'photo',
          );
          return LocalAttachment(
            file: File(platformFile.path!),
            displayName: displayName,
          );
        }
      }
    } catch (e) {
      DebugLogger.log(
        'FilePicker image failed: $e',
        scope: 'attachments/image',
      );
    }

    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );

      if (image == null) return null;
      final file = File(image.path);
      final displayName = _deriveDisplayName(
        preferredName: image.name,
        filePath: image.path,
        fallbackPrefix: 'photo',
      );
      return LocalAttachment(file: file, displayName: displayName);
    } catch (e) {
      throw Exception('Failed to pick image: $e');
    }
  }

  // Take photo from camera
  Future<LocalAttachment?> takePhoto() async {
    try {
      final XFile? photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );

      if (photo == null) return null;
      final file = File(photo.path);
      final displayName = _deriveDisplayName(
        preferredName: photo.name,
        filePath: photo.path,
        fallbackPrefix: 'photo',
      );
      return LocalAttachment(file: file, displayName: displayName);
    } catch (e) {
      throw Exception('Failed to take photo: $e');
    }
  }

  /// Compresses and resizes an image data URL while preserving a
  /// compatibility-friendly format.
  Future<String> compressImage(
    String imageDataUrl,
    int? maxWidth,
    int? maxHeight,
  ) async {
    try {
      // Decode base64 data - with validation
      final parts = imageDataUrl.split(',');
      if (parts.length < 2) {
        DebugLogger.log(
          'Invalid data URL format - missing comma separator',
          scope: 'attachments/image',
          data: {
            'urlPrefix': imageDataUrl.length > 50
                ? imageDataUrl.substring(0, 50)
                : imageDataUrl,
          },
        );
        return imageDataUrl;
      }
      final data = parts[1];
      final bytes = base64Decode(data);

      // Decode image
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      int width = image.width;
      int height = image.height;

      // Calculate new dimensions maintaining aspect ratio
      if (maxWidth != null && maxHeight != null) {
        if (width <= maxWidth && height <= maxHeight) {
          return imageDataUrl;
        }

        if (width / height > maxWidth / maxHeight) {
          height = ((maxWidth * height) / width).round();
          width = maxWidth;
        } else {
          width = ((maxHeight * width) / height).round();
          height = maxHeight;
        }
      } else if (maxWidth != null) {
        if (width <= maxWidth) {
          return imageDataUrl;
        }
        height = ((maxWidth * height) / width).round();
        width = maxWidth;
      } else if (maxHeight != null) {
        if (height <= maxHeight) {
          return imageDataUrl;
        }
        width = ((maxHeight * width) / height).round();
        height = maxHeight;
      }

      // Create resized image (dart:ui only supports PNG output).
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint(),
      );

      final picture = recorder.endRecording();
      final resizedImage = await picture.toImage(width, height);
      final byteData = await resizedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      final pngBytes = byteData!.buffer.asUint8List();
      final originalMimeType = _extractMimeTypeFromDataUrl(imageDataUrl);

      if (originalMimeType == 'image/jpeg' || originalMimeType == 'image/jpg') {
        final jpegBytes = await FlutterImageCompress.compressWithList(
          pngBytes,
          format: CompressFormat.jpeg,
          quality: 90,
        );
        final compressedBase64 = base64Encode(jpegBytes);
        return 'data:image/jpeg;base64,$compressedBase64';
      }

      final compressedBase64 = base64Encode(pngBytes);
      return 'data:image/png;base64,$compressedBase64';
    } catch (e) {
      DebugLogger.error(
        'compress-failed',
        scope: 'attachments/image',
        error: e,
      );
      return imageDataUrl;
    }
  }

  // Convert image file to base64 data URL with optional compression
  Future<String?> convertImageToDataUrl(
    File imageFile, {
    bool enableCompression = false,
    int? maxWidth,
    int? maxHeight,
  }) async {
    // Use the shared utility for basic conversion
    String? dataUrl = await convertImageFileToDataUrl(imageFile);
    if (dataUrl == null) return null;

    // Apply compression if enabled
    if (enableCompression && (maxWidth != null || maxHeight != null)) {
      dataUrl = await compressImage(dataUrl, maxWidth, maxHeight);
    }

    return dataUrl;
  }

  /// Formats a byte count into a human-readable string.
  String formatFileSize(int bytes) => FileTypeUtils.formatFileSize(bytes);

  /// Returns an emoji icon for the given [fileName] based on its extension.
  String getFileIcon(String fileName) {
    final ext = path.extension(fileName).toLowerCase();
    return FileTypeUtils.emojiForExtension(
      ext,
      imageExtensions: allSupportedImageFormats,
    );
  }
}

// File upload state
class FileUploadState {
  final File file;
  final String fileName;
  final int fileSize;
  final double progress;
  final FileUploadStatus status;
  final String? fileId;
  final String? error;
  final bool? isImage;

  /// For images: stores the base64 data URL (e.g., "data:image/png;base64,...")
  /// This matches web client behavior where images are not uploaded to server.
  final String? base64DataUrl;

  FileUploadState({
    required this.file,
    required this.fileName,
    required this.fileSize,
    required this.progress,
    required this.status,
    this.fileId,
    this.error,
    this.isImage,
    this.base64DataUrl,
  });

  /// Human-readable file size string.
  String get formattedSize => FileTypeUtils.formatFileSize(fileSize);

  /// Whether this attachment references a previously uploaded server file.
  bool get isRemote => file.path.startsWith('remote://');

  /// Emoji icon representing the file type.
  String get fileIcon {
    final ext = path.extension(fileName).toLowerCase();
    return FileTypeUtils.emojiForExtension(
      ext,
      imageExtensions: allSupportedImageFormats,
    );
  }
}

enum FileUploadStatus { pending, uploading, completed, failed }

// Mock file attachment service for reviewer mode
class MockFileAttachmentService {
  final ImagePicker _imagePicker = ImagePicker();

  Future<List<LocalAttachment>> pickFiles({
    bool allowMultiple = true,
    List<String>? allowedExtensions,
  }) async {
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: allowMultiple,
        type: allowedExtensions != null ? FileType.custom : FileType.any,
        allowedExtensions: allowedExtensions,
      );

      if (result == null || result.files.isEmpty) {
        return [];
      }

      return result.files.where((file) => file.path != null).map((file) {
        final displayName = _deriveDisplayName(
          preferredName: file.name,
          filePath: file.path!,
          fallbackPrefix: 'attachment',
        );
        return LocalAttachment(
          file: File(file.path!),
          displayName: displayName,
        );
      }).toList();
    } catch (e) {
      throw Exception('Failed to pick files: $e');
    }
  }

  Future<LocalAttachment?> pickImage() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (image == null) return null;
      final file = File(image.path);
      final displayName = _deriveDisplayName(
        preferredName: image.name,
        filePath: image.path,
        fallbackPrefix: 'photo',
      );
      return LocalAttachment(file: file, displayName: displayName);
    } catch (e) {
      throw Exception('Failed to pick image: $e');
    }
  }

  Future<LocalAttachment?> takePhoto() async {
    try {
      final XFile? photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
      if (photo == null) return null;
      final file = File(photo.path);
      final displayName = _deriveDisplayName(
        preferredName: photo.name,
        filePath: photo.path,
        fallbackPrefix: 'photo',
      );
      return LocalAttachment(file: file, displayName: displayName);
    } catch (e) {
      throw Exception('Failed to take photo: $e');
    }
  }
}

// Providers
final fileAttachmentServiceProvider = Provider<dynamic>((ref) {
  final isReviewerMode = ref.watch(reviewerModeProvider);

  if (isReviewerMode) {
    return MockFileAttachmentService();
  }

  // Guard: only provide service when user is logged in
  final apiService = ref.watch(apiServiceProvider);
  if (apiService == null) return null;

  return FileAttachmentService();
});

// State notifier for managing attached files
class AttachedFilesNotifier extends Notifier<List<FileUploadState>> {
  @override
  List<FileUploadState> build() => [];

  void addFiles(List<LocalAttachment> attachments) {
    final newStates = attachments
        .map(
          (attachment) => FileUploadState(
            file: attachment.file,
            fileName: attachment.displayName,
            fileSize: attachment.sizeInBytes,
            progress: 0.0,
            status: FileUploadStatus.pending,
            isImage: attachment.isImage,
          ),
        )
        .toList();

    state = [...state, ...newStates];
  }

  void addRemoteFile(FileInfo file) {
    if (state.any((entry) => entry.fileId == file.id)) {
      return;
    }

    state = [
      ...state,
      FileUploadState(
        file: File('remote://${file.id}'),
        fileName: file.displayName,
        fileSize: file.size,
        progress: 1.0,
        status: FileUploadStatus.completed,
        fileId: file.id,
        isImage: false,
      ),
    ];
  }

  void updateFileState(String filePath, FileUploadState newState) {
    state = [
      for (final fileState in state)
        if (fileState.file.path == filePath) newState else fileState,
    ];
  }

  void removeFile(String filePath) {
    state = state
        .where((fileState) => fileState.file.path != filePath)
        .toList();
  }

  void clearAll() {
    state = [];
  }
}

final attachedFilesProvider =
    NotifierProvider<AttachedFilesNotifier, List<FileUploadState>>(
      AttachedFilesNotifier.new,
    );
