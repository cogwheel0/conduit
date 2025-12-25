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
import '../../../core/services/worker_manager.dart';
import '../../../core/utils/debug_logger.dart';

/// Size threshold for optimizing images to WebP (200KB).
/// Images larger than this will be converted to WebP for better compression.
const int _webpOptimizationThreshold = 200 * 1024;

/// Standard web image formats that LLMs can process directly.
const Set<String> _standardImageFormats = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
};

/// Formats that should always be converted to WebP (not widely supported).
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

/// Formats that benefit from WebP conversion when large.
const Set<String> _optimizableFormats = {'.jpg', '.jpeg', '.png'};

/// Formats that should never be converted (animation, already optimal).
const Set<String> _preserveFormats = {'.gif', '.webp'};

/// All supported image formats (both standard and those requiring conversion).
const Set<String> allSupportedImageFormats = {
  ..._standardImageFormats,
  ..._alwaysConvertFormats,
};

/// Returns true if the extension always requires conversion to WebP.
bool _alwaysNeedsConversion(String extension) {
  return _alwaysConvertFormats.contains(extension);
}

/// Returns true if the format can benefit from WebP optimization.
bool _canOptimize(String extension) {
  return _optimizableFormats.contains(extension);
}

/// Returns true if the format should be preserved as-is.
bool _shouldPreserve(String extension) {
  return _preserveFormats.contains(extension);
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

/// Converts an image file to a base64 data URL with smart optimization.
/// This is a standalone utility used by both FileAttachmentService and TaskWorker.
///
/// Optimization strategy:
/// - HEIC/HEIF/RAW/BMP → Always convert to WebP
/// - Large JPEG/PNG (>200KB) → Convert to WebP for better compression
/// - Small JPEG/PNG (<200KB) → Pass through as-is
/// - GIF → Preserve (maintains animation)
/// - WebP → Preserve (already optimal)
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
        'Converting image from $ext to WebP (required)',
        scope: 'attachments',
        data: {'path': imageFile.path, 'size': fileSize},
      );

      final convertedBytes = await _convertToWebP(imageFile);
      if (convertedBytes != null) {
        return _encodeToDataUrl(convertedBytes, 'image/webp', worker);
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

    // Optimizable formats (JPEG, PNG) - convert if large
    if (_canOptimize(ext) && fileSize > _webpOptimizationThreshold) {
      DebugLogger.log(
        'Optimizing large image from $ext to WebP',
        scope: 'attachments',
        data: {'path': imageFile.path, 'size': fileSize},
      );

      final convertedBytes = await _convertToWebP(imageFile);
      if (convertedBytes != null) {
        final savings = fileSize - convertedBytes.length;
        final savingsPercent = (savings / fileSize * 100).toStringAsFixed(1);
        DebugLogger.log(
          'WebP optimization saved $savingsPercent%',
          scope: 'attachments',
          data: {
            'originalSize': fileSize,
            'newSize': convertedBytes.length,
            'saved': savings,
          },
        );
        return _encodeToDataUrl(convertedBytes, 'image/webp', worker);
      }
      // Fall through to pass-through if conversion fails
    }

    // Pass through as-is (small images or unknown formats)
    final bytes = await imageFile.readAsBytes();
    String mimeType = 'image/png';
    if (ext == '.jpg' || ext == '.jpeg') {
      mimeType = 'image/jpeg';
    }

    return _encodeToDataUrl(bytes, mimeType, worker);
  } catch (e) {
    DebugLogger.error('convert-image-failed', scope: 'attachments', error: e);
    return null;
  }
}

/// Converts an image file to WebP bytes using flutter_image_compress.
/// WebP provides better compression than JPEG while maintaining quality.
Future<List<int>?> _convertToWebP(File imageFile) async {
  try {
    final result = await FlutterImageCompress.compressWithFile(
      imageFile.absolute.path,
      format: CompressFormat.webp,
      quality: 85,
    );

    if (result != null && result.isNotEmpty) {
      DebugLogger.log(
        'Image converted to WebP successfully',
        scope: 'attachments',
        data: {'originalPath': imageFile.path, 'resultSize': result.length},
      );
      return result;
    }

    return null;
  } catch (e) {
    DebugLogger.error('webp-conversion-failed', scope: 'attachments', error: e);
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
  final String ext = extension.isNotEmpty ? extension : '.webp';
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
      final result = await FilePicker.platform.pickFiles(
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
      final result = await FilePicker.platform.pickFiles(
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

  /// Compresses and resizes an image data URL.
  /// Uses PNG format for the resize operation (dart:ui limitation),
  /// then converts to WebP for optimal file size.
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

      // Create resized image (dart:ui only supports PNG output)
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

      // Convert PNG to WebP for better compression
      final webpBytes = await FlutterImageCompress.compressWithList(
        pngBytes,
        format: CompressFormat.webp,
        quality: 85,
      );

      final compressedBase64 = base64Encode(webpBytes);
      return 'data:image/webp;base64,$compressedBase64';
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

  // Format file size for display
  String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  // Get file icon based on extension
  String getFileIcon(String fileName) {
    final ext = path.extension(fileName).toLowerCase();

    // Documents
    if (['.pdf', '.doc', '.docx'].contains(ext)) return '📄';
    if (['.xls', '.xlsx'].contains(ext)) return '📊';
    if (['.ppt', '.pptx'].contains(ext)) return '📊';

    // Images (including iOS and RAW formats)
    if (allSupportedImageFormats.contains(ext)) return '🖼️';

    // Code
    if (['.js', '.ts', '.py', '.dart', '.java', '.cpp'].contains(ext)) {
      return '💻';
    }
    if (['.html', '.css', '.json', '.xml'].contains(ext)) return '🌐';

    // Archives
    if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) return '📦';

    // Media
    if (['.mp3', '.wav', '.flac', '.m4a'].contains(ext)) return '🎵';
    if (['.mp4', '.avi', '.mov', '.mkv'].contains(ext)) return '🎬';

    return '📎';
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

  String get formattedSize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String get fileIcon {
    final ext = path.extension(fileName).toLowerCase();

    // Documents
    if (['.pdf', '.doc', '.docx'].contains(ext)) return '📄';
    if (['.xls', '.xlsx'].contains(ext)) return '📊';
    if (['.ppt', '.pptx'].contains(ext)) return '📊';

    // Images (including iOS and RAW formats)
    if (allSupportedImageFormats.contains(ext)) return '🖼️';

    // Code
    if (['.js', '.ts', '.py', '.dart', '.java', '.cpp'].contains(ext)) {
      return '💻';
    }
    if (['.html', '.css', '.json', '.xml'].contains(ext)) return '🌐';

    // Archives
    if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) return '📦';

    // Media
    if (['.mp3', '.wav', '.flac', '.m4a'].contains(ext)) return '🎵';
    if (['.mp4', '.avi', '.mov', '.mkv'].contains(ext)) return '🎬';

    return '📎';
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
      final result = await FilePicker.platform.pickFiles(
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
