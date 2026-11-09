import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/jwt_claims.dart';
import 'package:test/test.dart';

String _segment(Object? json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

void main() {
  test('reads the claims of a JWT, padded or not', () {
    final payload = _segment({'sub': 'user-1', 'exp': 1700000000});
    check(jwtClaims('h.$payload.s')).isNotNull()
      ..has((c) => c['sub'], 'sub').equals('user-1')
      ..has((c) => c['exp'], 'exp').equals(1700000000);
    check(jwtPayloadClaims(base64Url.normalize(payload)))
        .isNotNull()
        .has((c) => c['sub'], 'sub')
        .equals('user-1');
  });

  test('is null for anything but a JWT with an object payload', () {
    check(jwtClaims('opaque-token')).isNull();
    check(jwtClaims('a.b')).isNull();
    check(jwtClaims('a.b.c.d')).isNull();
    check(jwtClaims('h.${_segment(['not', 'an', 'object'])}.s')).isNull();
    check(jwtClaims('h.%%%.s')).isNull();
    check(jwtPayloadClaims('a')).isNull();
  });
}
