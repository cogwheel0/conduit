/// How a personal connection's endpoint is shown in a list: never with a key
/// or token the user wrote into it.
library;

import 'package:conduit_core/features/integrations/personal_connection_settings.dart';

/// What a tool server's row says under its name in the composer's tool list:
/// its description, else its host. Never the full [url], which can carry a
/// token.
String? personalToolServerSubtitle(Map<String, dynamic> raw, String url) {
  final info = personalConnectionMap(raw['info']);
  for (final candidate in <Object?>[raw['description'], info?['description']]) {
    final text = candidate?.toString().trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  final host = Uri.tryParse(url)?.host.trim() ?? '';
  return host.isEmpty ? null : host;
}

/// [url] as a list shows it: scheme, host, port and path only, so a key or
/// token written into the query or user info is not put on screen.
///
/// A URL that does not parse with a host, such as `user:token@host/path`, is
/// cut by hand the same way: the user info before the host and everything
/// from the query or fragment on are left out.
String personalConnectionPublicEndpoint(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return _withoutCredentials(url.trim());
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}

/// [text] without what follows a `?` or `#`, and without anything up to the
/// last `@` before the path, after a `scheme://` when there is one.
String _withoutCredentials(String text) {
  var rest = text;
  final end = rest.indexOf(RegExp('[?#]'));
  if (end >= 0) rest = rest.substring(0, end);
  final schemeEnd = rest.indexOf('://');
  final prefix = schemeEnd >= 0 ? rest.substring(0, schemeEnd + 3) : '';
  rest = rest.substring(prefix.length);
  final slash = rest.indexOf('/');
  final authority = slash >= 0 ? rest.substring(0, slash) : rest;
  final at = authority.lastIndexOf('@');
  if (at >= 0) rest = rest.substring(at + 1);
  return '$prefix$rest';
}
