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

/// Whether [address] is routable on the public internet.
///
/// IPv4 rejects every IANA special-purpose block (private, loopback,
/// link-local, CGNAT, documentation, benchmarking, protocol assignments,
/// multicast, reserved). IPv6 accepts only global unicast (`2000::/3`), so
/// unique-local, site-local, link-local and multicast fall out, then rejects
/// documentation and Teredo space and checks the IPv4 address inside
/// IPv4-mapped/compatible, NAT64 (`64:ff9b::/96`) and 6to4 (`2002::/16`)
/// addresses, which a network may route to an internal host.
bool isPublicInternetAddress(InternetAddress address) {
  if (address.type == InternetAddressType.unix) return false;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return !_isPrivateOrSpecialIpv4(bytes);
  }

  bool zeros(int from, int to) =>
      bytes.sublist(from, to).every((byte) => byte == 0);
  // Addresses that carry an IPv4 destination are only as public as it is.
  final isIpv4Mapped = zeros(0, 10) && bytes[10] == 0xff && bytes[11] == 0xff;
  final isIpv4Compatible = zeros(0, 12);
  final isNat64 =
      bytes[0] == 0x00 &&
      bytes[1] == 0x64 &&
      bytes[2] == 0xff &&
      bytes[3] == 0x9b &&
      zeros(4, 12);
  if (isIpv4Mapped || isIpv4Compatible || isNat64) {
    return !_isPrivateOrSpecialIpv4(bytes.sublist(12));
  }
  if (bytes[0] == 0x20 && bytes[1] == 0x02) {
    return !_isPrivateOrSpecialIpv4(bytes.sublist(2, 6));
  }

  final isGlobalUnicast = (bytes[0] & 0xe0) == 0x20;
  final isDocumentation =
      bytes[0] == 0x20 &&
      bytes[1] == 0x01 &&
      bytes[2] == 0x0d &&
      bytes[3] == 0xb8;
  final isTeredo =
      bytes[0] == 0x20 &&
      bytes[1] == 0x01 &&
      bytes[2] == 0x00 &&
      bytes[3] == 0x00;
  return isGlobalUnicast && !isDocumentation && !isTeredo;
}

bool _isPrivateOrSpecialIpv4(List<int> bytes) {
  final first = bytes[0];
  final second = bytes[1];
  final third = bytes[2];
  return first == 0 ||
      first == 10 ||
      first == 127 ||
      (first == 100 && second >= 64 && second <= 127) ||
      (first == 169 && second == 254) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 0 && (third == 0 || third == 2)) ||
      (first == 192 && second == 88 && third == 99) ||
      (first == 192 && second == 168) ||
      (first == 198 && (second == 18 || second == 19)) ||
      (first == 198 && second == 51 && third == 100) ||
      (first == 203 && second == 0 && third == 113) ||
      first >= 224;
}
