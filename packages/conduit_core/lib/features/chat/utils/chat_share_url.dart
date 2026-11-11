/// Builds the public Open WebUI share URL for a chat snapshot.
///
/// Open WebUI exposes shared chats from the server origin at `/s/{shareId}`.
Uri buildChatShareUri({required String serverUrl, required String shareId}) {
  final trimmedShareId = shareId.trim();
  if (trimmedShareId.isEmpty) {
    throw const FormatException('Share ID cannot be empty.');
  }

  final serverUri = Uri.parse(serverUrl.trim());
  if (!serverUri.hasScheme || serverUri.host.isEmpty) {
    throw FormatException('Invalid server URL: $serverUrl');
  }

  return Uri(
    scheme: serverUri.scheme,
    host: serverUri.host,
    port: serverUri.hasPort ? serverUri.port : null,
    path: '/s/${Uri.encodeComponent(trimmedShareId)}',
  );
}

/// Builds the public Open WebUI share URL string for a chat snapshot.
String buildChatShareUrl({required String serverUrl, required String shareId}) {
  return buildChatShareUri(serverUrl: serverUrl, shareId: shareId).toString();
}

/// Builds the public LibreChat share URL for a chat snapshot.
///
/// LibreChat serves shared chats at `/share/{shareId}` under the base its web
/// app is served from, which may be a sub-path (`https://host/librechat`).
String buildLibreChatShareUrl({
  required String baseUrl,
  required String shareId,
}) {
  final trimmedShareId = shareId.trim();
  if (trimmedShareId.isEmpty) {
    throw const FormatException('Share ID cannot be empty.');
  }
  final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  final baseUri = Uri.parse(base);
  if (!baseUri.hasScheme || baseUri.host.isEmpty) {
    throw FormatException('Invalid server URL: $baseUrl');
  }
  return '$base/share/${Uri.encodeComponent(trimmedShareId)}';
}
