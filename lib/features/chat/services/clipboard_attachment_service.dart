import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'file_attachment_service.dart';

/// Service for handling clipboard image paste operations.
///
/// This service converts pasted image data into [LocalAttachment] objects that
/// integrate with the existing file attachment flow.
///
/// Uses `super_clipboard` to read native clipboard formats across platforms.
/// On iOS, callers should invoke reads in direct response to a user paste
/// action so the system can present paste permission UI if needed.
class ClipboardAttachmentService {
  /// Supported MIME types for image paste operations.
  static const Set<String> supportedImageMimeTypes = {
    'image/png',
    'image/jpeg',
    'image/jpg',
    'image/gif',
    'image/webp',
    'image/bmp',
    'image/tiff',
    'image/heic',
    'image/heif',
  };

  static const List<(FileFormat, String)> _supportedImageFormats = [
    (Formats.png, 'image/png'),
    (Formats.jpeg, 'image/jpeg'),
    (Formats.gif, 'image/gif'),
    (Formats.webp, 'image/webp'),
    (Formats.bmp, 'image/bmp'),
    (Formats.tiff, 'image/tiff'),
    (Formats.heic, 'image/heic'),
    (Formats.heif, 'image/heif'),
  ];

  /// Reads an image from the system clipboard.
  ///
  /// Returns the image data as bytes if an image is present, null otherwise.
  Future<Uint8List?> getClipboardImage() async {
    try {
      final result = await _readClipboardImage();
      return result?.$1;
    } catch (e) {
      debugPrint('ClipboardAttachmentService: Failed to read clipboard: $e');
      return null;
    }
  }

  /// Creates a [LocalAttachment] from pasted image data.
  ///
  /// The image data is saved to a temporary file with an appropriate extension
  /// based on the MIME type. Returns null if the operation fails.
  Future<LocalAttachment?> createAttachmentFromImageData({
    required Uint8List imageData,
    required String mimeType,
    String? suggestedFileName,
  }) async {
    try {
      // Determine file extension from MIME type
      final extension = _extensionForMimeType(mimeType);
      if (extension == null) {
        debugPrint(
          'ClipboardAttachmentService: Unsupported MIME type: $mimeType',
        );
        return null;
      }

      // Generate filename, ensuring proper extension
      String fileName;
      if (suggestedFileName != null && suggestedFileName.isNotEmpty) {
        // If suggested filename doesn't have the correct extension, add it
        final suggestedLower = suggestedFileName.toLowerCase();
        final hasImageExt = supportedImageMimeTypes.any((mime) {
          final ext = _extensionForMimeType(mime);
          return ext != null && suggestedLower.endsWith(ext);
        });
        fileName = hasImageExt
            ? suggestedFileName
            : '$suggestedFileName$extension';
      } else {
        fileName = _generateFileName(extension);
      }

      // Get temporary directory and create file path
      final tempDir = await getTemporaryDirectory();
      final filePath = path.join(tempDir.path, fileName);

      // Write image data to file
      final file = File(filePath);
      await file.writeAsBytes(imageData);

      return LocalAttachment(file: file, displayName: fileName);
    } catch (e) {
      debugPrint('ClipboardAttachmentService: Failed to create attachment: $e');
      return null;
    }
  }

  /// Checks if a MIME type is a supported image type.
  bool isSupportedImageType(String mimeType) {
    return supportedImageMimeTypes.contains(mimeType.toLowerCase());
  }

  /// Returns the file extension for a given MIME type, or null if unsupported.
  String? _extensionForMimeType(String mimeType) {
    switch (mimeType.toLowerCase()) {
      case 'image/png':
        return '.png';
      case 'image/jpeg':
      case 'image/jpg':
        return '.jpg';
      case 'image/gif':
        return '.gif';
      case 'image/webp':
        return '.webp';
      case 'image/bmp':
        return '.bmp';
      case 'image/tiff':
        return '.tiff';
      case 'image/heic':
        return '.heic';
      case 'image/heif':
        return '.heif';
      default:
        return null;
    }
  }

  Future<(Uint8List, String)?> _readClipboardImage() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      return null;
    }

    final reader = await clipboard.read();
    for (final entry in _supportedImageFormats) {
      final format = entry.$1;
      if (!reader.canProvide(format)) {
        continue;
      }

      final completer = Completer<Uint8List?>();
      final progress = reader.getFile(format, (file) async {
        try {
          completer.complete(await file.readAll());
        } catch (error) {
          completer.completeError(error);
        }
      }, onError: completer.completeError);

      if (progress == null) {
        continue;
      }

      final bytes = await completer.future;
      if (bytes != null && bytes.isNotEmpty) {
        return (bytes, entry.$2);
      }
    }

    return null;
  }

  /// Generates a timestamped filename for pasted images.
  String _generateFileName(String extension) {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final timestamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return 'pasted_$timestamp$extension';
  }
}
