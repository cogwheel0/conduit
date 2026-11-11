/// Whether [host], a URI's host (an IPv6 address without its brackets), is
/// this device: `localhost`, an IPv4 address in `127.0.0.0/8`, `::1`, or an
/// IPv4-mapped IPv6 address in `127.0.0.0/8` (`::ffff:127.0.0.1`). Pure
/// Dart, so it needs no `dart:io`.
bool isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  if (normalized == 'localhost') return true;
  try {
    return Uri.parseIPv4Address(normalized).first == 127;
  } on FormatException {
    // Not an IPv4 address.
  }
  try {
    final bytes = Uri.parseIPv6Address(normalized);
    if (bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff) {
      return bytes[12] == 127;
    }
    return bytes.last == 1 && bytes.take(15).every((byte) => byte == 0);
  } on FormatException {
    return false;
  }
}
