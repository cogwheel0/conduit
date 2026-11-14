import 'dart:math';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/oidc/oidc.dart';
import 'package:test/test.dart';

void main() {
  test('the S256 challenge matches the RFC 7636 example', () {
    // RFC 7636, appendix B.
    check(oidcS256Challenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'))
        .equals('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });

  test('a verifier is 43 unreserved characters, and new each time', () {
    final first = OidcPkce.generate();
    final second = OidcPkce.generate();
    check(first.verifier).matchesPattern(RegExp(r'^[A-Za-z0-9_\-]{43}$'));
    check(first.verifier).not((it) => it.equals(second.verifier));
    check(first.challenge).equals(oidcS256Challenge(first.verifier));
    check(OidcPkce.method).equals('S256');
  });

  test('a random token has no padding', () {
    final token = oidcRandomToken(byteCount: 16, random: Random(1));
    check(token).matchesPattern(RegExp(r'^[A-Za-z0-9_\-]{22}$'));
  });

  test('the verifier never shows in logs', () {
    final pkce = OidcPkce.generate();
    check(pkce.toString())
      ..not((it) => it.contains(pkce.verifier))
      ..not((it) => it.contains(pkce.challenge));
  });
}
