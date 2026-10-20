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
