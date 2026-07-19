import 'package:flutter/foundation.dart';

/// A normalized HTTP(S) origin used to bind WebView credential reads.
typedef NormalizedWebOrigin = ({String scheme, String host, int port});

/// Returns the exact origin of an HTTP(S) URI, including its effective port.
///
/// Explicit default ports normalize to the same origin as implicit ports.
/// Unsupported schemes and hostless URIs do not have a trusted web origin.
@visibleForTesting
NormalizedWebOrigin? normalizeWebViewOrigin(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  if (host.isEmpty || (scheme != 'http' && scheme != 'https')) return null;

  final port = uri.hasPort
      ? uri.port
      : switch (scheme) {
          'http' => 80,
          'https' => 443,
          _ => -1,
        };
  if (port <= 0 || port > 65535) return null;

  return (scheme: scheme, host: host, port: port);
}

/// Whether [candidate] has the same scheme, host, and effective port as
/// [trustedServer]. Paths are intentionally ignored because Open WebUI can
/// return from OAuth through several routes on its configured origin.
bool hasExactWebViewOrigin(Uri candidate, Uri trustedServer) {
  final candidateOrigin = normalizeWebViewOrigin(candidate);
  final trustedOrigin = normalizeWebViewOrigin(trustedServer);
  return candidateOrigin != null && candidateOrigin == trustedOrigin;
}

/// String-safe form of [hasExactWebViewOrigin] for WebView callbacks.
bool webViewUrlHasExactServerOrigin(String pageUrl, String serverUrl) {
  final pageUri = Uri.tryParse(pageUrl);
  final serverUri = Uri.tryParse(serverUrl);
  return pageUri != null &&
      serverUri != null &&
      hasExactWebViewOrigin(pageUri, serverUri);
}

/// Query/fragment-free origin label for diagnostics. OAuth callback URLs can
/// contain authorization codes, state, and tokens, so raw WebView URLs must
/// never be interpolated into logs.
String webViewOriginForLog(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  final origin = uri == null ? null : normalizeWebViewOrigin(uri);
  if (origin == null) return '<invalid-web-origin>';
  final host = origin.host.contains(':') ? '[${origin.host}]' : origin.host;
  final defaultPort = origin.scheme == 'https' ? 443 : 80;
  final port = origin.port == defaultPort ? '' : ':${origin.port}';
  return '${origin.scheme}://$host$port';
}

/// A trusted descendant URL used for native cookie matching.
///
/// Configured server URLs are stored without a trailing slash. Querying the
/// slashless `/openwebui` path would omit cookies scoped to `/openwebui/`, even
/// though every API descendant needs them.
String webViewCookieLookupUrl(String serverUrl) {
  final uri = Uri.tryParse(serverUrl);
  if (uri == null || normalizeWebViewOrigin(uri) == null) {
    throw const FormatException('Invalid server URL for cookie lookup');
  }
  var lookupPath = uri.path;
  if (lookupPath.isEmpty) {
    lookupPath = '/';
  } else if (!lookupPath.endsWith('/')) {
    lookupPath = '$lookupPath/';
  }
  return Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: lookupPath,
  ).toString();
}
