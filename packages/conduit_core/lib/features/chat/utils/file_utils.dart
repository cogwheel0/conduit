// Utility functions for handling file data in chat messages.
// Used by both user and assistant message widgets.

const Set<String> _imageFileExtensions = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'svg',
  'avif',
  'heic',
  'tiff',
  'tif',
};

const Set<String> _videoFileExtensions = {
  'mp4',
  'mov',
  'avi',
  'mkv',
  'webm',
  'm4v',
  '3gp',
  'flv',
  'wmv',
};

/// Infers a media kind from a URL or path via its extension.
/// Returns 'image', 'video', or 'file'. Extensionless file IDs (e.g.
/// `/api/v1/files/<uuid>/content`) resolve to 'file'.
String inferFileTypeFromUrl(String url) {
  final normalized = url.split('#').first.split('?').first.toLowerCase();
  final dotIndex = normalized.lastIndexOf('.');
  if (dotIndex < 0) {
    return 'file';
  }
  final extension = normalized.substring(dotIndex + 1);
  if (_imageFileExtensions.contains(extension)) {
    return 'image';
  }
  if (_videoFileExtensions.contains(extension)) {
    return 'video';
  }
  return 'file';
}

/// Returns true when a file entry is explicitly or implicitly a video.
/// Prefers server-declared `content_type`/`type`; falls back to extension
/// inference only when neither declares an image kind.
bool isVideoFile(dynamic file) {
  if (file is! Map) return false;

  final contentType = file['content_type']?.toString().toLowerCase() ?? '';
  if (contentType.startsWith('video/')) return true;
  if (contentType.startsWith('image/')) return false;

  final type = file['type']?.toString().toLowerCase() ?? '';
  if (type == 'video') return true;
  if (type == 'image') return false;

  final url = file['url'];
  if (url is String && url.isNotEmpty && !url.startsWith('data:')) {
    if (inferFileTypeFromUrl(url) == 'video') return true;
  }
  final name = file['filename'] ?? file['name'];
  if (name is String && name.isNotEmpty) {
    return inferFileTypeFromUrl(name) == 'video';
  }
  return false;
}

bool isImageFile(dynamic file) {
  if (file is! Map) return false;
  if (isVideoFile(file)) return false;
  if (file['type'] == 'image') return true;
  final contentType = file['content_type']?.toString() ?? '';
  return contentType.startsWith('image/');
}

String? getFileUrl(dynamic file) {
  if (file is! Map) return null;
  final url = file['url'];
  if (url == null) return null;
  return url.toString();
}
