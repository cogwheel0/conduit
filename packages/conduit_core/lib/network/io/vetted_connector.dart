import 'dart:async';
import 'dart:io';

/// Resolves a host name to its addresses.
typedef HostLookup = Future<List<InternetAddress>> Function(String host);

/// A host that resolved to an address [VettedConnector.allowed] refuses.
final class RefusedAddressException implements Exception {
  const RefusedAddressException(this.host);

  final String host;

  @override
  String toString() => 'RefusedAddressException($host)';
}

/// Opens an [HttpClient]'s connections (as its `connectionFactory`) only to
/// addresses it has checked itself.
///
/// The host is resolved here, every address it resolves to must pass
/// [allowed], and the socket is opened to one of those same addresses, so a
/// name that resolves to an allowed address for a check and to another one
/// for the connect (DNS rebinding) never reaches the other. An HTTP client
/// opens a connection for every redirect hop, so each hop is vetted too.
/// One refused answer refuses the whole lookup: a site has no reason to
/// resolve to an address the rule refuses.
final class VettedConnector {
  VettedConnector({
    required this.allowed,
    HostLookup? lookup,
    this.connectTimeout = const Duration(seconds: 6),
    this.maxAddresses = 4,
  }) : _lookup = lookup ?? InternetAddress.lookup;

  /// Whether a connection may go to the address.
  final bool Function(InternetAddress address) allowed;
  final HostLookup _lookup;
  final Duration connectTimeout;

  /// How many of the vetted addresses are tried, in order.
  final int maxAddresses;

  /// The connection for [url] (an `HttpClient.connectionFactory`); [stopped]
  /// says the request was given up, so a connect that lands late is closed.
  /// Throws [RefusedAddressException] for a refused address.
  Future<ConnectionTask<Socket>> connect(
    Uri url, {
    bool Function()? stopped,
  }) async {
    final halted = stopped ?? () => false;
    final host = url.host;
    final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
    final addresses = await vettedAddresses(host);
    if (halted()) throw const SocketException('Connection stopped');
    final socket = _connectAny(addresses, port, halted).then<Socket>(
      (socket) => url.scheme == 'https'
          ? SecureSocket.secure(socket, host: host)
          : socket,
    );
    return ConnectionTask.fromSocket(socket, () {});
  }

  /// [host]'s addresses, all of them allowed; an address literal is not
  /// looked up. Throws [RefusedAddressException] when one is refused and
  /// [SocketException] when there are none.
  Future<List<InternetAddress>> vettedAddresses(String host) async {
    final literal = InternetAddress.tryParse(host);
    final addresses = literal == null ? await _lookup(host) : [literal];
    if (addresses.isEmpty) {
      throw SocketException('No address for $host');
    }
    if (!addresses.every(allowed)) {
      throw RefusedAddressException(host);
    }
    return addresses;
  }

  Future<Socket> _connectAny(
    List<InternetAddress> addresses,
    int port,
    bool Function() stopped,
  ) async {
    Object? lastError;
    for (final address in addresses.take(maxAddresses)) {
      if (stopped()) throw const SocketException('Connection stopped');
      try {
        final socket = await Socket.connect(
          address,
          port,
          timeout: connectTimeout,
        );
        // A socket that lands after the request stopped is nobody's.
        if (stopped()) {
          socket.destroy();
          throw const SocketException('Connection stopped');
        }
        return socket;
      } on SocketException catch (error) {
        if (stopped()) rethrow;
        lastError = error;
      }
    }
    throw lastError ?? const SocketException('No address to connect to');
  }
}

/// Whether [address] is a host a fetch may reach when the user's own
/// network is allowed (sites they host themselves): any address except
/// this machine's own (loopback, and the unspecified `0.0.0.0/8` and `::`,
/// which reach it too), link-local ones (`169.254/16`, `fe80::/10`, where
/// routers and cloud metadata services answer) and multicast (`224/4`,
/// `ff00::/8`). Private ranges (`10/8`, `172.16/12`, `192.168/16`,
/// `fc00::/7`) pass. An IPv4 address carried in IPv6 (mapped, compatible,
/// NAT64 `64:ff9b::/96`, 6to4 `2002::/16`) is treated as that IPv4 address.
bool isLanOrPublicHostAddress(InternetAddress address) {
  if (address.type == InternetAddressType.unix) return false;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return _isLanOrPublicIpv4(bytes);
  }
  bool zeros(int from, int to) =>
      bytes.sublist(from, to).every((byte) => byte == 0);
  final isIpv4Mapped = zeros(0, 10) && bytes[10] == 0xff && bytes[11] == 0xff;
  final isIpv4Compatible = zeros(0, 12);
  final isNat64 =
      bytes[0] == 0x00 &&
      bytes[1] == 0x64 &&
      bytes[2] == 0xff &&
      bytes[3] == 0x9b &&
      zeros(4, 12);
  if (isIpv4Mapped || isIpv4Compatible || isNat64) {
    // `::` and `::1` are compatible-form too: 0.0.0.0 and 0.0.0.1, refused.
    return _isLanOrPublicIpv4(bytes.sublist(12));
  }
  if (bytes[0] == 0x20 && bytes[1] == 0x02) {
    return _isLanOrPublicIpv4(bytes.sublist(2, 6));
  }
  final isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
  final isMulticast = bytes[0] == 0xff;
  return !isLinkLocal && !isMulticast;
}

bool _isLanOrPublicIpv4(List<int> bytes) {
  final first = bytes[0];
  final second = bytes[1];
  return first != 0 &&
      first != 127 &&
      !(first == 169 && second == 254) &&
      !(first >= 224 && first <= 239);
}
