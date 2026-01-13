// Utility functions for handling file data in chat messages.
// Used by both user and assistant message widgets.

/// Checks if a file map represents an image.
/// Matches OpenWebUI behavior: type === 'image' OR content_type starts with 'image/'
bool isImageFile(dynamic file) {
  if (file is! Map) return false;
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
