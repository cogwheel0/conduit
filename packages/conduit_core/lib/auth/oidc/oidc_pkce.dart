import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// [byteCount] random bytes, base64url-encoded without padding: 32 bytes give
/// the 43 characters RFC 7636 asks of a code verifier.
///
/// The MCP and Hermes sign-ins use it too, for their state and verifiers.
String oidcRandomToken({int byteCount = 32, Random? random}) {
  final source = random ?? Random.secure();
  return base64UrlEncode(
    List<int>.generate(byteCount, (_) => source.nextInt(256)),
  ).replaceAll('=', '');
}

/// The `S256` code challenge for [verifier] (RFC 7636, section 4.2).
String oidcS256Challenge(String verifier) =>
    base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

/// A PKCE code verifier and its `S256` challenge.
final class OidcPkce {
  const OidcPkce._(this.verifier, this.challenge);

  factory OidcPkce.generate({Random? random}) {
    final verifier = oidcRandomToken(random: random);
    return OidcPkce._(verifier, oidcS256Challenge(verifier));
  }

  /// The only method sent: `plain` would hand the verifier to anyone who
  /// sees the authorization URL.
  static const String method = 'S256';

  /// Sent to the token endpoint with the code, and nowhere else.
  final String verifier;

  /// Sent in the authorization URL.
  final String challenge;

  @override
  String toString() => 'OidcPkce(<redacted>)';
}
