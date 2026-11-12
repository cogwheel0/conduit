import 'package:meta/meta.dart';

import 'package:conduit_core/models/server_config.dart';

/// Where a LibreChat server lives and how to reach it.
///
/// [baseUrl] is the address the LibreChat web app is served from, without a
/// trailing slash. LibreChat can be deployed under a sub-path
/// (`https://example.com/librechat`), and every API route sits below it, so
/// requests are built as `$baseUrl/api/...` rather than against the origin.
@immutable
final class LibreChatServer {
  const LibreChatServer({
    required this.baseUrl,
    this.customHeaders = const <String, String>{},
    this.allowSelfSignedCertificates = false,
    this.mtlsCertificateChainPem,
    this.mtlsPrivateKeyPem,
    this.mtlsPrivateKeyPassword,
  });

  final String baseUrl;

  /// Extra headers the user asked for, for a proxy in front of the server.
  /// They never replace the User-Agent, Authorization or Cookie headers.
  final Map<String, String> customHeaders;

  /// Whether to trust a self-signed certificate on [baseUrl]'s host.
  final bool allowSelfSignedCertificates;

  final String? mtlsCertificateChainPem;
  final String? mtlsPrivateKeyPem;
  final String? mtlsPrivateKeyPassword;

  /// The address the user typed, reduced to the base the API hangs off, or
  /// null when it is not a usable http(s) address.
  ///
  /// A missing scheme means https. A link copied from the web app (a chat at
  /// `/c/<id>`, the sign-in page) is cut back to the base it belongs to.
  static String? normalizeBaseUrl(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final parsed = Uri.tryParse(text);
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty) {
      return null;
    }
    var path = parsed.path;
    path = path.replaceFirst(_webAppRoute, '');
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: parsed.scheme,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      path: path,
    ).toString();
  }

  /// Routes of the web app and its API, at the end of a pasted address.
  static final RegExp _webAppRoute = RegExp(
    r'/(c/.*|login|register|forgot-password|search|agents|api(/.*)?)/?$',
  );

  /// [path] (which starts with `/`) under [baseUrl].
  Uri resolve(String path) => Uri.parse('$baseUrl$path');

  /// The scheme, host and port requests may carry credentials to.
  Uri get origin {
    final base = Uri.parse(baseUrl);
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
    );
  }

  /// Whether [uri] is on this server's origin and under its base path, the
  /// only place the session's token and cookies may go.
  bool owns(Uri uri) {
    final base = Uri.parse(baseUrl);
    if (uri.scheme != base.scheme ||
        uri.host.toLowerCase() != base.host.toLowerCase() ||
        _port(uri) != _port(base)) {
      return false;
    }
    return base.path.isEmpty ||
        uri.path == base.path ||
        uri.path.startsWith('${base.path}/');
  }

  static int _port(Uri uri) =>
      uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

  /// The same TLS settings in the shape the shared TLS client factory reads.
  ServerConfig toTlsServerConfig() => ServerConfig(
    id: 'librechat',
    name: 'LibreChat',
    url: baseUrl,
    allowSelfSignedCertificates: allowSelfSignedCertificates,
    mtlsCertificateChainPem: mtlsCertificateChainPem,
    mtlsPrivateKeyPem: mtlsPrivateKeyPem,
    mtlsPrivateKeyPassword: mtlsPrivateKeyPassword,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'baseUrl': baseUrl,
    if (customHeaders.isNotEmpty) 'customHeaders': customHeaders,
    if (allowSelfSignedCertificates) 'allowSelfSignedCertificates': true,
    'mtlsCertificateChainPem': ?mtlsCertificateChainPem,
    'mtlsPrivateKeyPem': ?mtlsPrivateKeyPem,
    'mtlsPrivateKeyPassword': ?mtlsPrivateKeyPassword,
  };

  static LibreChatServer? fromJson(Object? json) {
    if (json is! Map) return null;
    final baseUrl = json['baseUrl'];
    if (baseUrl is! String || normalizeBaseUrl(baseUrl) != baseUrl) {
      return null;
    }
    final headers = json['customHeaders'];
    String? text(String key) {
      final value = json[key];
      return value is String ? value : null;
    }

    return LibreChatServer(
      baseUrl: baseUrl,
      customHeaders: headers is Map
          ? <String, String>{
              for (final entry in headers.entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            }
          : const <String, String>{},
      allowSelfSignedCertificates: json['allowSelfSignedCertificates'] == true,
      mtlsCertificateChainPem: text('mtlsCertificateChainPem'),
      mtlsPrivateKeyPem: text('mtlsPrivateKeyPem'),
      mtlsPrivateKeyPassword: text('mtlsPrivateKeyPassword'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LibreChatServer &&
      other.baseUrl == baseUrl &&
      other.allowSelfSignedCertificates == allowSelfSignedCertificates &&
      other.mtlsCertificateChainPem == mtlsCertificateChainPem &&
      other.mtlsPrivateKeyPem == mtlsPrivateKeyPem &&
      other.mtlsPrivateKeyPassword == mtlsPrivateKeyPassword &&
      _sameHeaders(other.customHeaders, customHeaders);

  static bool _sameHeaders(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length &&
      a.entries.every((entry) => b[entry.key] == entry.value);

  @override
  int get hashCode => Object.hash(
    baseUrl,
    allowSelfSignedCertificates,
    mtlsCertificateChainPem,
    mtlsPrivateKeyPem,
    mtlsPrivateKeyPassword,
    Object.hashAllUnordered(
      customHeaders.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );
}
