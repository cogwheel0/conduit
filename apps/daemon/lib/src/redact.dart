/// Scrubbing of credentials from text the daemon writes down: log lines,
/// and everything a diagnostics export carries.
///
/// The rules are deliberately blunt. A redacted word in a log costs a little
/// readability; a token in a zip the user mails to someone costs their
/// account.
library;

const String _hidden = '[redacted]';

final List<(RegExp, String Function(Match))>
_rules = <(RegExp, String Function(Match))>[
  // A quoted value under a quoted header or secret name, as JSON writes
  // them: the whole value, escapes and spaces included, before the rules
  // below see only its first word. The value's two alternatives never match
  // the same character (an escape starts with a backslash, the other takes
  // anything but one), so a long run of backslashes is read one way, in
  // linear time.
  (
    RegExp(
      r'''(["'])(authorization|proxy-authorization|cookie|set-cookie|'''
      r'''x-api-key|api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|'''
      r'''id[_-]?token|session[_-]?token|session[_-]?key|client[_-]?secret|'''
      r'''token|password|passphrase|secret|code_verifier|master[_-]?key)\1'''
      r'''(\s*:\s*)(["'])(?:\\[\s\S]|(?!\4)[^\\])*\4''',
      caseSensitive: false,
    ),
    (m) => '${m[1]}${m[2]}${m[1]}${m[3]}${m[4]}$_hidden${m[4]}',
  ),
  // Header lines, whatever follows on the line.
  (
    RegExp(
      r'\b(authorization|proxy-authorization|cookie|set-cookie|'
      r'x-api-key|api-key)(\s*[:=]\s*)[^\r\n]*',
      caseSensitive: false,
    ),
    (m) => '${m[1]}${m[2]}$_hidden',
  ),
  // A bearer or basic credential wherever it appears.
  (
    RegExp(r'\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{12,}', caseSensitive: false),
    (m) => '${m[1]} $_hidden',
  ),
  // JSON Web Tokens: three base64url segments, the first a JSON header.
  (
    RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*'),
    (_) => _hidden,
  ),
  // Provider keys in their usual shapes.
  (RegExp(r'\b(sk|pk|rk)-[A-Za-z0-9_-]{8,}'), (m) => '${m[1]}-$_hidden'),
  // `key=value`, `"key": "value"` and query parameters naming a secret.
  (
    RegExp(
      r'''\b(api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|'''
      r'''session[_-]?token|session[_-]?key|client[_-]?secret|token|'''
      r'''password|passphrase|secret|code_verifier|master[_-]?key)'''
      r'''(["']?\s*[:=]\s*["']?)([^\s"'&,;}]+)''',
      caseSensitive: false,
    ),
    (m) => '${m[1]}${m[2]}$_hidden',
  ),
  // `user:password@` in a URL.
  (
    RegExp(r'([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@', caseSensitive: false),
    (m) => '${m[1]}$_hidden@',
  ),
];

/// [text] with every credential the rules recognise replaced, and every
/// one of [exact] -- secrets the daemon knows by value -- as well.
String redactSecrets(String text, {Iterable<String> exact = const []}) {
  var out = text;
  for (final secret in exact) {
    if (secret.isEmpty) continue;
    out = out.replaceAll(secret, _hidden);
  }
  for (final (pattern, replace) in _rules) {
    out = out.replaceAllMapped(pattern, replace);
  }
  return out;
}

/// Just the scheme, host and port of [url]: no user, path or query, which is
/// where a URL carries a credential or a person's name. Null for nothing,
/// and a placeholder for something that is not a URL.
String? originOnly(String? url) {
  if (url == null || url.trim().isEmpty) return null;
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '[not a url]';
  return uri.hasPort
      ? '${uri.scheme}://${uri.host}:${uri.port}'
      : '${uri.scheme}://${uri.host}';
}
