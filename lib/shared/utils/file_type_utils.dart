import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Utilities for file type detection, icon selection, and formatting.
///
/// Provides platform-aware icon selection (Cupertino on iOS, Material
/// elsewhere), file type detection by extension, and human-readable
/// file size formatting.
class FileTypeUtils {
  FileTypeUtils._();

  /// Audio file extensions (lowercase, with leading dot).
  static const Set<String> _audioExtensions = {
    '.mp3',
    '.wav',
    '.flac',
    '.m4a',
    '.aac',
  };

  /// Image file extensions (lowercase, with leading dot).
  static const Set<String> _imageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
    '.heic',
    '.heif',
    '.dng',
    '.raw',
    '.cr2',
    '.nef',
    '.arw',
    '.orf',
    '.rw2',
  };

  /// Video file extensions (lowercase, with leading dot).
  static const Set<String> _videoExtensions = {'.mp4', '.avi', '.mov', '.mkv'};

  /// Whether the extension represents an audio file.
  ///
  /// The [extension] should be lowercase with a leading dot (e.g. `.mp3`).
  static bool isAudio(String extension) => _audioExtensions.contains(extension);

  /// Whether the extension represents an image file.
  ///
  /// The [extension] should be lowercase with a leading dot (e.g. `.png`).
  static bool isImage(String extension) => _imageExtensions.contains(extension);

  /// Whether the extension represents a video file.
  ///
  /// The [extension] should be lowercase with a leading dot (e.g. `.mp4`).
  static bool isVideo(String extension) => _videoExtensions.contains(extension);

  /// Returns a platform-aware icon for the given file [extension].
  ///
  /// Uses Cupertino icons on iOS and Material icons on other platforms.
  /// The [extension] should be lowercase with a leading dot.
  static IconData iconForExtension(String extension) {
    if (isAudio(extension)) {
      return Platform.isIOS
          ? CupertinoIcons.waveform
          : Icons.audio_file_rounded;
    }
    if (isImage(extension)) {
      return Platform.isIOS ? CupertinoIcons.photo : Icons.image_rounded;
    }
    if (isVideo(extension)) {
      return Platform.isIOS
          ? CupertinoIcons.videocam_fill
          : Icons.video_file_rounded;
    }
    return Platform.isIOS
        ? CupertinoIcons.doc_fill
        : Icons.insert_drive_file_rounded;
  }

  /// Returns a color representing the file type category.
  ///
  /// Audio files are orange, image files are blue, and other files
  /// fall back to [fallback].
  static Color colorForExtension(String extension, {required Color fallback}) {
    if (isAudio(extension)) return Colors.orange;
    if (isImage(extension)) return Colors.blue;
    return fallback;
  }

  /// Formats a byte count into a human-readable string.
  ///
  /// Returns an empty string when [bytes] is null.
  /// Examples: `512 B`, `1.5 KB`, `3.2 MB`, `1.1 GB`.
  static String formatFileSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Extracts the file extension from a filename.
  ///
  /// Returns the lowercase extension with a leading dot, or an empty
  /// string if the filename has no extension.
  static String extensionFromName(String filename) {
    final dotIndex = filename.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex == filename.length - 1) return '';
    return filename.substring(dotIndex).toLowerCase();
  }

  /// Returns an emoji icon representing the file type.
  ///
  /// The [extension] should be lowercase with a leading dot.
  /// Uses [imageExtensions] to check image formats when provided,
  /// otherwise falls back to the built-in [_imageExtensions] set.
  static String emojiForExtension(
    String extension, {
    Set<String>? imageExtensions,
  }) {
    // Documents
    if (const {'.pdf', '.doc', '.docx'}.contains(extension)) {
      return '\u{1F4C4}';
    }
    if (const {'.xls', '.xlsx', '.ppt', '.pptx'}.contains(extension)) {
      return '\u{1F4CA}';
    }

    // Images
    final images = imageExtensions ?? _imageExtensions;
    if (images.contains(extension)) return '\u{1F5BC}\uFE0F';

    // Code
    if (const {
      '.js',
      '.ts',
      '.py',
      '.dart',
      '.java',
      '.cpp',
    }.contains(extension)) {
      return '\u{1F4BB}';
    }
    if (const {'.html', '.css', '.json', '.xml'}.contains(extension)) {
      return '\u{1F310}';
    }

    // Archives
    if (const {'.zip', '.rar', '.7z', '.tar', '.gz'}.contains(extension)) {
      return '\u{1F4E6}';
    }

    // Media
    if (isAudio(extension)) return '\u{1F3B5}';
    if (isVideo(extension)) return '\u{1F3AC}';

    return '\u{1F4CE}';
  }
}
