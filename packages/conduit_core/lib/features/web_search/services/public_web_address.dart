import 'dart:io';

/// Canonicalizes [value] as a public `http`/`https` URL, or throws
/// [FormatException].
///
/// This is the syntactic half of the public-web boundary: it rejects
/// non-web schemes, embedded credentials, local hostnames and private IP
/// literals. A hostname that *resolves* to a private address is caught at
/// connect time by [isPublicInternetAddress].
String normalizePublicWebUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) {
    throw const FormatException('Web fetch URL is invalid.');
  }
  if (!uri.hasScheme) {
    throw const FormatException('Web fetch URL must be absolute.');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const FormatException('Web fetch URL must use HTTP or HTTPS.');
  }
  if (uri.host.isEmpty) {
    throw const FormatException('Web fetch URL must include a host.');
  }
  if (uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'Web fetch URL must not include user information.',
    );
  }
  // DNS treats a terminal dot as the same absolute hostname. Canonicalize it
  // before applying the public-host boundary so `localhost.` and IP literals
  // with a terminal dot cannot bypass the checks below.
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');
  if (host == 'localhost' ||
      host.isEmpty ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal')) {
    throw const FormatException('Web fetch requires a public URL.');
  }
  final literal = InternetAddress.tryParse(host);
  if (literal != null && !isPublicInternetAddress(literal)) {
    throw const FormatException('Web fetch requires a public URL.');
  }
  return uri.removeFragment().toString();
}

/// Whether [address] is routable on the public internet: not loopback,
/// private, link-local, carrier-grade NAT, benchmarking, multicast or
/// reserved, including IPv4 addresses embedded in IPv6.
bool isPublicInternetAddress(InternetAddress address) {
  if (address.type == InternetAddressType.unix) return false;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return !_isPrivateOrSpecialIpv4(bytes);
  }
  final isUnspecified = bytes.every((byte) => byte == 0);
  final isLoopback =
      bytes.take(15).every((byte) => byte == 0) && bytes.last == 1;
  final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc;
  final isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
  final isMulticast = bytes[0] == 0xff;
  final isIpv4Mapped =
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  final isIpv4Compatible = bytes.take(12).every((byte) => byte == 0);
  return !(isUnspecified ||
      isLoopback ||
      isUniqueLocal ||
      isLinkLocal ||
      isMulticast ||
      ((isIpv4Mapped || isIpv4Compatible) &&
          _isPrivateOrSpecialIpv4(bytes.sublist(12))));
}

bool _isPrivateOrSpecialIpv4(List<int> bytes) {
  final first = bytes[0];
  final second = bytes[1];
  return first == 0 ||
      first == 10 ||
      first == 127 ||
      (first == 100 && second >= 64 && second <= 127) ||
      (first == 169 && second == 254) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168) ||
      (first == 198 && (second == 18 || second == 19)) ||
      first >= 224;
}
