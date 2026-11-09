import 'dart:convert';

/// The claims in the payload of [token], a three-part JWT: null when it is
/// not one, or its payload is not a JSON object.
///
/// The signature is not checked. This is for what a token says about
/// itself (when it expires, who it names), never for trusting it.
Map<String, dynamic>? jwtClaims(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  return jwtPayloadClaims(parts[1]);
}

/// The claims in [payload], the base64url-encoded middle part of a JWT,
/// padded or not: null when it does not decode to a JSON object.
Map<String, dynamic>? jwtPayloadClaims(String payload) {
  try {
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(payload))),
    );
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}
