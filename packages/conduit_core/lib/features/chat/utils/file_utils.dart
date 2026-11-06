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
/// A server-declared `content_type` (top-level or `meta.content_type`) wins;
/// otherwise `type: 'video'` or a video extension in the URL or filename
/// marks a video. The extension overrides `type: 'image'` because tool
/// output saved before videos had their own type was always labelled image.
bool isVideoFile(dynamic file) {
  if (file is! Map) return false;

  final meta = file['meta'];
  for (final declared in [
    file['content_type'],
    if (meta is Map) meta['content_type'],
  ]) {
    final contentType = declared?.toString().toLowerCase() ?? '';
    if (contentType.startsWith('video/')) return true;
    if (contentType.startsWith('image/')) return false;
  }

  final type = file['type']?.toString().toLowerCase() ?? '';
  if (type == 'video') return true;

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

/// Checks if a file map represents an image.
/// Matches OpenWebUI behavior: type === 'image' OR content_type starts with
/// 'image/', unless the entry is a video.
bool isImageFile(dynamic file) {
  if (file is! Map) return false;
  if (isVideoFile(file)) return false;
  if (file['type'] == 'image') return true;
  final contentType = file['content_type']?.toString() ?? '';
  return contentType.startsWith('image/');
}

/// Extracts the file URL or ID from a file map.
/// OpenWebUI stores either a full URL, data URL, or just the file ID.
///
/// Returns the URL/ID string, or null if the file has no valid URL.
String? getFileUrl(dynamic file) {
  if (file is! Map) return null;
  final url = file['url'];
  if (url == null) return null;
  return url.toString();
}

final RegExp _openWebUiFileUrl = RegExp(r'/api/v1/files/([^/]+)(?:/content)?$');

/// The id a chat file shows under: taken from its URL, a bare file id or an
/// Open WebUI file path, whose query (a token, say) is no part of it. Null
/// for a file with no URL, which shows nothing.
String? chatFileShownId(dynamic file) {
  final url = getFileUrl(file);
  if (url == null) return null;
  if (!url.contains('/api/v1/files/')) return url;
  final path = Uri.tryParse(url)?.path ?? url;
  return _openWebUiFileUrl.firstMatch(path)?.group(1) ?? url;
}

/// A reply's [stored] files, then each of [shown] (files the model showed
/// with Open WebUI's display_file tool) that is not shown already: by a
/// stored file that has a URL to show, or, while the reply stores no files,
/// by one of its [attachmentIds]. A stored file with no URL shows nothing,
/// so the file it names still shows.
List<dynamic> chatFilesWithShown(
  List<dynamic>? stored,
  List<Map<String, dynamic>> shown, {
  List<String>? attachmentIds,
}) {
  final shownIds = <String>{
    for (final file in stored ?? const <dynamic>[])
      if (file is Map && chatFileShownId(file) != null) ...[
        chatFileShownId(file)!,
        for (final key in const ['id', 'file_id'])
          if (file[key] is String) file[key] as String,
      ],
    if (stored == null || stored.isEmpty) ...?attachmentIds,
  };
  return <dynamic>[
    ...?stored,
    for (final file in shown)
      if (!shownIds.contains(file['id'])) file,
  ];
}
