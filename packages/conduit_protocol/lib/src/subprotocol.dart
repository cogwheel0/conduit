import 'dart:convert';

import 'protocol_version.dart';

/// Prefix marking the subprotocol entry that carries the session token.
const String _tokenPrefix = 'tk.';

/// Builds the `Sec-WebSocket-Protocol` list a Conduit client must offer.
///
/// The browser's WebSocket API cannot set request headers, so the session
/// token rides in the subprotocol list — the one field the client controls.
/// It is base64url-encoded without padding because `=` is not legal in a
/// subprotocol token (RFC 6455 restricts them to HTTP token characters).
List<String> buildSubprotocols(String sessionToken) => <String>[
  kConduitSubprotocol,
  '$_tokenPrefix${_base64UrlNoPad(sessionToken)}',
];

/// Recovers the session token from an offered subprotocol list.
///
/// Returns null when the list is absent, does not advertise
/// [kConduitSubprotocol], or carries no well-formed token entry. Callers must
/// treat null as "reject the upgrade", never as "no auth required".
String? extractSessionToken(Iterable<String>? protocols) {
  if (protocols == null) return null;
  final offered = protocols
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList(growable: false);
  if (!offered.contains(kConduitSubprotocol)) return null;

  for (final entry in offered) {
    if (!entry.startsWith(_tokenPrefix)) continue;
    final encoded = entry.substring(_tokenPrefix.length);
    if (encoded.isEmpty) continue;
    try {
      return utf8.decode(base64Url.decode(_restorePadding(encoded)));
    } on FormatException {
      // A malformed entry is a rejected handshake, not a fallback to the
      // next candidate: accepting a second token would let an attacker
      // append a guess after a truncated real one.
      return null;
    }
  }
  return null;
}

/// The value the server must echo back in its `Sec-WebSocket-Protocol`
/// response header.
///
/// Always the bare version tag — never the token entry. Response headers end
/// up in proxy logs and devtools, and the token is a bearer credential.
const String negotiatedSubprotocol = kConduitSubprotocol;

/// Whether [origin] is the one page allowed to open an RPC socket.
///
/// Electron serves the bundle from `app://conduit`; anything else is either a
/// real browser tab or another local app probing the port.
bool isAllowedOrigin(String? origin) => origin == kConduitAppOrigin;

/// Compares two secrets without leaking their common prefix length through
/// timing.
///
/// The loop always visits every character of [a]; the length check is folded
/// into the accumulator rather than short-circuiting.
bool constantTimeEquals(String a, String b) {
  // Whether the *expected* secret is empty is a property of the program, not
  // of the attacker's input, so returning early on it leaks nothing.
  if (b.isEmpty) return a.isEmpty;
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    // Wrapping the index keeps the iteration count tied to the candidate's
    // length alone; a length mismatch is already recorded in `diff`.
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i % b.length);
  }
  return diff == 0;
}

String _base64UrlNoPad(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

String _restorePadding(String value) {
  final remainder = value.length % 4;
  if (remainder == 0) return value;
  return value + '=' * (4 - remainder);
}
