import 'dart:io';

bool isAllowedCredentialTransport(Uri uri) =>
    uri.scheme.toLowerCase() == 'https' ||
    (uri.scheme.toLowerCase() == 'http' &&
        isSafePlaintextCredentialHost(uri.host));

bool isSafePlaintextCredentialHost(String host) {
  final normalized = host.trim().toLowerCase();
  if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
    return true;
  }

  final address = InternetAddress.tryParse(normalized);
  if (address == null) return false;
  final bytes = address.rawAddress;
  if (bytes.length == 4) return _isPrivateOrLoopbackIpv4(bytes);
  if (bytes.length != 16) return false;

  final isIpv4Mapped =
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  if (isIpv4Mapped) {
    return _isPrivateOrLoopbackIpv4(bytes.sublist(12));
  }

  final isLoopback =
      bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
  final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc;
  final isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
  return isLoopback || isUniqueLocal || isLinkLocal;
}

bool _isPrivateOrLoopbackIpv4(List<int> bytes) {
  final first = bytes[0];
  final second = bytes[1];
  return first == 10 ||
      first == 127 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168) ||
      (first == 169 && second == 254);
}
