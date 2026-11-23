import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// An authenticator app's six-digit code (RFC 6238: HMAC-SHA1, 30-second
/// steps) for a base32 [secret], [stepsAhead] steps after now.
///
/// Open WebUI accepts the step before, now and after, but never a step at
/// or before the last one it took: a test that signs in right after the
/// seed added the authenticator asks for the next step.
String totpCode(String secret, {int stepsAhead = 0, DateTime? at}) {
  final seconds = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final step = seconds ~/ 30 + stepsAhead;
  final counter = ByteData(8)..setInt64(0, step);
  final digest = Hmac(
    sha1,
    _base32(secret),
  ).convert(counter.buffer.asUint8List()).bytes;
  final offset = digest.last & 0x0f;
  final value =
      ((digest[offset] & 0x7f) << 24) |
      (digest[offset + 1] << 16) |
      (digest[offset + 2] << 8) |
      digest[offset + 3];
  return (value % 1000000).toString().padLeft(6, '0');
}

List<int> _base32(String text) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final clean = text.toUpperCase().replaceAll(RegExp('[^A-Z2-7]'), '');
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final char in clean.split('')) {
    buffer = (buffer << 5) | alphabet.indexOf(char);
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
  }
  return out;
}
