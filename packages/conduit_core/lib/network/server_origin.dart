/// Whether [imageUrl] is on the server at [serverBaseUrl]: a path on it
/// (`/static/x.png`), or an http(s) address with the server's scheme, host
/// and port. Requests to it may carry the account's credential; a picture
/// anywhere else is another site's.
bool imageUrlIsServerOrigin(String? serverBaseUrl, String imageUrl) {
  if (serverBaseUrl == null || serverBaseUrl.isEmpty) return false;
  final serverUri = Uri.tryParse(serverBaseUrl.trim());
  if (serverUri == null || !_isHttpScheme(serverUri.scheme)) return false;
  if (serverUri.host.isEmpty) return false;

  final imageUri = Uri.tryParse(imageUrl.trim());
  if (imageUri == null) return false;
  if (!imageUri.hasScheme && imageUri.host.isEmpty) return true;

  final imageScheme = imageUri.scheme.isEmpty
      ? serverUri.scheme.toLowerCase()
      : imageUri.scheme.toLowerCase();
  if (!_isHttpScheme(imageScheme)) return false;

  return imageScheme == serverUri.scheme.toLowerCase() &&
      imageUri.host.toLowerCase() == serverUri.host.toLowerCase() &&
      _effectivePort(imageUri, imageScheme) ==
          _effectivePort(serverUri, serverUri.scheme.toLowerCase());
}

bool _isHttpScheme(String scheme) {
  final lower = scheme.toLowerCase();
  return lower == 'http' || lower == 'https';
}

int? _effectivePort(Uri uri, String scheme) {
  if (uri.hasPort) return uri.port;
  return switch (scheme) {
    'http' => 80,
    'https' => 443,
    _ => null,
  };
}
