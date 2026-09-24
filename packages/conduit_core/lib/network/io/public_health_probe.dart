/// The raw-socket health prober.
///
/// A health check may be redirected, and following a redirect blindly is an
/// SSRF: a malicious or compromised server could point the probe at the
/// user's private network or at a cloud metadata endpoint. So the redirect
/// target is resolved first, every answer is classified, and the connection
/// is then pinned to an address that was already checked -- which is why this
/// dials sockets itself instead of letting an HTTP client re-resolve the name
/// behind its back.
///
/// Moved out of `lib/core/services/api_service.dart`. What made it movable is
/// that the logic reaches nothing but `dart:io` and `dart:async` — the dio
/// plumbing it used to sit between stays behind with the HTTP client.
///
/// The move is otherwise line-for-line, with three deliberate exceptions:
/// eight names the caller still needs became public, `listEquals` became
/// `ListEquality` because the core cannot reach Flutter, and
/// [requestUsesServerConnectivityOrigin] lost a `@visibleForTesting` that was
/// only ever accurate because its production caller shared this library.
///
/// Deliberately not exported from `conduit_core.dart`. Like the models, it is
/// imported by path, so eight `PublicHealth*` names do not land in the
/// namespace of every importer of the barrel.
library;

import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

const int maximumPublicHealthRedirects = 5;
const Set<int> publicHealthRedirectStatusCodes = {
  HttpStatus.movedPermanently,
  HttpStatus.found,
  HttpStatus.seeOther,
  HttpStatus.temporaryRedirect,
  HttpStatus.permanentRedirect,
};

final class PublicHealthDeadline {
  PublicHealthDeadline(this.budget) : _clock = Stopwatch()..start();

  final Duration budget;
  final Stopwatch _clock;

  Duration remaining({Duration? cappedAt}) {
    final value = budget - _clock.elapsed;
    if (value <= Duration.zero) {
      throw TimeoutException('Public health-check deadline expired');
    }
    if (cappedAt != null && value > cappedAt) return cappedAt;
    return value;
  }
}

typedef PublicHealthAddressResolver = Future<List<InternetAddress>> Function(
  String host,
);
typedef PublicHealthSocketConnector = Future<ConnectionTask<Socket>> Function(
  InternetAddress address,
  int port,
);
typedef PublicHealthSocketUpgrader = Future<Socket> Function(
  Socket socket,
  String host,
);

final class PublicHealthNat64Prefix {
  const PublicHealthNat64Prefix(this.bytes, this.length);

  final List<int> bytes;
  final int length;

  bool matches(List<int> address) {
    final prefixBytes = length ~/ 8;
    if (address.length != 16 || bytes.length != prefixBytes) return false;
    for (var index = 0; index < prefixBytes; index++) {
      if (address[index] != bytes[index]) return false;
    }
    return true;
  }
}

final class _PinnedPublicHealthSocketAttempt {
  bool acceptsResult = true;
  ConnectionTask<Socket>? connectionTask;
  Socket? rawSocket;
  Socket? upgradedSocket;

  void cancel() {
    acceptsResult = false;
    try {
      connectionTask?.cancel();
    } catch (_) {}
    try {
      rawSocket?.destroy();
    } catch (_) {}
    try {
      upgradedSocket?.destroy();
    } catch (_) {}
  }

  void transferSocketOwnership() {
    acceptsResult = false;
    connectionTask = null;
    rawSocket = null;
    upgradedSocket = null;
  }
}

/// Owns every socket produced while trying a prevalidated DNS result.
///
/// `SecureSocket.secure` detaches the raw [Socket] before its future completes.
/// Keeping an acceptance flag around the upgrade future is therefore essential:
/// a timeout can no longer close the detached wrapper, but it can still destroy
/// the upgraded socket as soon as that future completes.
final class PinnedPublicHealthConnection {
  PinnedPublicHealthConnection({
    required this.target,
    required this.addresses,
    required this.connectTimeout,
    required this.connector,
    required this.upgrader,
  });

  final Uri target;
  final List<InternetAddress> addresses;
  final Duration connectTimeout;
  final PublicHealthSocketConnector connector;
  final PublicHealthSocketUpgrader upgrader;
  final Completer<Socket> _result = Completer<Socket>();

  _PinnedPublicHealthSocketAttempt? _activeAttempt;
  bool _cancelled = false;

  ConnectionTask<Socket> start() {
    unawaited(_run());
    return ConnectionTask.fromSocket<Socket>(_result.future, cancel);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _activeAttempt?.cancel();
    if (!_result.isCompleted) {
      _result.completeError(
        const SocketException('Pinned health connection was cancelled'),
        StackTrace.current,
      );
    }
  }

  Future<void> _run() async {
    final deadline = DateTime.now().add(connectTimeout);
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var index = 0; index < addresses.length; index++) {
      if (_cancelled || _result.isCompleted) return;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;

      // Reserve a fair share of the one connection deadline for every
      // prevalidated address. This retains IPv6/IPv4 fallback without allowing
      // each failed address to restart the full timeout.
      final addressesLeft = addresses.length - index;
      final sliceMicros =
          (remaining.inMicroseconds + addressesLeft - 1) ~/ addressesLeft;
      final attemptDeadline = DateTime.now().add(
        Duration(microseconds: sliceMicros),
      );
      final attempt = _PinnedPublicHealthSocketAttempt();
      _activeAttempt = attempt;

      try {
        final connectionTask = await connector(addresses[index], target.port)
            .then((task) {
              if (!attempt.acceptsResult || _cancelled) {
                task.cancel();
                throw const SocketException(
                  'Pinned health connection was cancelled',
                );
              }
              attempt.connectionTask = task;
              return task;
            })
            .timeout(_remainingUntil(attemptDeadline));

        final rawSocket = await connectionTask.socket
            .then((socket) {
              if (!attempt.acceptsResult || _cancelled) {
                socket.destroy();
                throw const SocketException(
                  'Pinned health connection was cancelled',
                );
              }
              attempt.rawSocket = socket;
              return socket;
            })
            .timeout(_remainingUntil(attemptDeadline));
        attempt.connectionTask = null;

        if (target.scheme.toLowerCase() == 'http') {
          attempt.transferSocketOwnership();
          _activeAttempt = null;
          _result.complete(rawSocket);
          return;
        }

        final upgradedSocket = await upgrader(rawSocket, target.host)
            .then((socket) {
              if (!attempt.acceptsResult || _cancelled) {
                socket.destroy();
                throw const SocketException(
                  'Pinned health connection was cancelled',
                );
              }
              attempt.upgradedSocket = socket;
              return socket;
            })
            .timeout(_remainingUntil(attemptDeadline));

        attempt.transferSocketOwnership();
        _activeAttempt = null;
        _result.complete(upgradedSocket);
        return;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        attempt.cancel();
        if (identical(_activeAttempt, attempt)) _activeAttempt = null;
      }
    }

    if (_cancelled || _result.isCompleted) return;
    _result.completeError(
      lastError ??
          const SocketException('No validated health address was reachable'),
      lastStackTrace ?? StackTrace.current,
    );
  }

  Duration _remainingUntil(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    return remaining > Duration.zero
        ? remaining
        : const Duration(microseconds: 1);
  }
}

// Not @visibleForTesting, despite carrying that annotation before the
// extraction. `ApiService` calls this from production code in four
// places; the annotation only stayed quiet because the caller used to
// share this library.
bool requestUsesServerConnectivityOrigin(Uri request, Uri? server) {
  if (server == null ||
      !request.hasScheme ||
      !server.hasScheme ||
      request.host.isEmpty ||
      server.host.isEmpty) {
    return false;
  }
  return request.scheme.toLowerCase() == server.scheme.toLowerCase() &&
      request.host.toLowerCase() == server.host.toLowerCase() &&
      request.port == server.port;
}

/// Whether an address is safe for a public, off-origin health redirect.
///
/// Same-origin health redirects deliberately bypass this classification so a
/// self-hosted Open WebUI instance can keep using loopback, LAN, VPN, or ULA
/// addressing. Off-origin redirects must be globally routable to avoid
/// turning the public `/health` probe into an internal-network request.
@visibleForTesting
bool isPublicHealthRedirectAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return _isPublicIpv4(bytes);
  }
  if (address.type != InternetAddressType.IPv6 || bytes.length != 16) {
    return false;
  }

  // IPv4-mapped IPv6 addresses retain the IPv4 address's classification.
  if (bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff) {
    return _isPublicIpv4(bytes.sublist(12));
  }

  // The well-known NAT64 prefix embeds an IPv4 destination in the final four
  // bytes. Do not allow it to disguise a private or otherwise reserved target.
  const nat64Prefix = <int>[0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0];
  if (_startsWithBytes(bytes, nat64Prefix)) {
    return _isPublicIpv4(bytes.sublist(12));
  }

  // Network-specific RFC 6052 Pref64 values cannot be inferred from an IPv6
  // address alone. In particular, treating every global /96 address as a
  // synthesized IPv4 destination would reject ordinary hosts such as
  // 2606:4700:4700::1. Only the standardized well-known prefix above is
  // unambiguous without a platform Pref64-discovery API; every other address
  // continues through native IPv6 classification.

  // Globally routable unicast currently lives in 2000::/3. This rejects
  // unspecified, loopback, ULA, link/site-local, multicast, and other
  // reserved address classes in one fail-closed boundary.
  if ((bytes[0] & 0xe0) != 0x20) return false;

  // Reject special-purpose ranges nested inside global-unicast space.
  if (bytes[0] == 0x20 && bytes[1] == 0x01) {
    // 2001:0000::/23 (IETF protocol assignments, not ordinary public hosts).
    if (bytes[2] <= 0x01) return false;
    // 2001:db8::/32 documentation.
    if (bytes[2] == 0x0d && bytes[3] == 0xb8) return false;
  }
  // 2002::/16 (deprecated 6to4 transition space).
  if (bytes[0] == 0x20 && bytes[1] == 0x02) return false;
  // 3fff::/20 documentation.
  if (bytes[0] == 0x3f && bytes[1] == 0xff && (bytes[2] & 0xf0) == 0) {
    return false;
  }
  return true;
}

bool requiresNat64PrefixDiscovery(InternetAddress address) {
  if (address.type != InternetAddressType.IPv6 ||
      address.rawAddress.length != 16) {
    return false;
  }
  final bytes = address.rawAddress;
  final isMapped =
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  if (isMapped) return false;
  const wellKnownPrefix = <int>[0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0];
  return !_startsWithBytes(bytes, wellKnownPrefix);
}

bool isPublicHealthRedirectAddressWithNat64Prefixes(
  InternetAddress address,
  List<PublicHealthNat64Prefix> prefixes,
) {
  if (!isPublicHealthRedirectAddress(address)) return false;
  if (address.type != InternetAddressType.IPv6) return true;

  final bytes = address.rawAddress;
  for (final prefix in prefixes) {
    if (!prefix.matches(bytes)) continue;
    final embedded = _rfc6052EmbeddedIpv4(bytes, prefix.length);
    // An address inside a discovered translation prefix must use the RFC 6052
    // layout. Invalid reserved/u bits fail closed instead of being treated as
    // an unrelated native IPv6 host.
    if (embedded == null || !_isPublicIpv4(embedded)) return false;
  }
  return true;
}

List<PublicHealthNat64Prefix>? nat64PrefixesFromIpv4OnlyArpa(
  List<InternetAddress> addresses,
) {
  if (addresses.isEmpty) return null;
  const discoveryTargets = <List<int>>[
    <int>[192, 0, 0, 170],
    <int>[192, 0, 0, 171],
  ];
  final prefixes = <String, PublicHealthNat64Prefix>{};

  for (final address in addresses) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      if (!discoveryTargets.any(
        (target) => const ListEquality<int>().equals(target, bytes),
      )) {
        return null;
      }
      continue;
    }
    if (address.type != InternetAddressType.IPv6 || bytes.length != 16) {
      return null;
    }

    var discovered = false;
    for (final prefixLength in const <int>[32, 40, 48, 56, 64, 96]) {
      final embedded = _rfc6052EmbeddedIpv4(bytes, prefixLength);
      if (embedded == null ||
          !discoveryTargets.any(
            (target) => const ListEquality<int>().equals(target, embedded),
          )) {
        continue;
      }
      final prefixBytes = List<int>.unmodifiable(
        bytes.sublist(0, prefixLength ~/ 8),
      );
      final key = '$prefixLength:${prefixBytes.join(',')}';
      prefixes[key] = PublicHealthNat64Prefix(prefixBytes, prefixLength);
      discovered = true;
    }
    // ipv4only.arpa has no native AAAA records. An IPv6 answer that does not
    // encode either standardized marker means discovery was tampered with or
    // is unsupported, so generic IPv6 targets cannot be classified safely.
    if (!discovered) return null;
  }

  return List<PublicHealthNat64Prefix>.unmodifiable(prefixes.values);
}

@visibleForTesting
bool isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
  InternetAddress address,
  List<InternetAddress> ipv4OnlyArpaAnswers,
) {
  final prefixes = nat64PrefixesFromIpv4OnlyArpa(ipv4OnlyArpaAnswers);
  return prefixes != null &&
      isPublicHealthRedirectAddressWithNat64Prefixes(address, prefixes);
}

List<int>? _rfc6052EmbeddedIpv4(List<int> bytes, int prefixLength) {
  if (bytes.length != 16) return null;
  if (prefixLength == 96) return bytes.sublist(12, 16);

  // RFC 6052's u octet separates an embedding that crosses bit 64. The
  // remaining suffix bits are reserved and zero in synthesized addresses.
  if (bytes[8] != 0) return null;
  final (candidate, suffixStart) = switch (prefixLength) {
    32 => (<int>[...bytes.sublist(4, 8)], 9),
    40 => (<int>[...bytes.sublist(5, 8), bytes[9]], 10),
    48 => (<int>[...bytes.sublist(6, 8), ...bytes.sublist(9, 11)], 11),
    56 => (<int>[bytes[7], ...bytes.sublist(9, 12)], 12),
    64 => (<int>[...bytes.sublist(9, 13)], 13),
    _ => (<int>[], 16),
  };
  if (candidate.length != 4 ||
      !bytes.sublist(suffixStart).every((byte) => byte == 0)) {
    return null;
  }
  return candidate;
}

bool _startsWithBytes(List<int> value, List<int> prefix) {
  if (value.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (value[index] != prefix[index]) return false;
  }
  return true;
}

bool _isPublicIpv4(List<int> bytes) {
  if (bytes.length != 4) return false;
  final first = bytes[0];
  final second = bytes[1];

  if (first == 0 || first == 10 || first == 127 || first >= 224) return false;
  if (first == 100 && second >= 64 && second <= 127) return false; // CGNAT
  if (first == 169 && second == 254) return false; // link-local
  if (first == 172 && second >= 16 && second <= 31) return false;
  if (first == 192) {
    if (second == 0 && bytes[2] == 0) return false; // protocol assignments
    if (second == 0 && bytes[2] == 2) return false; // documentation
    if (second == 88 && bytes[2] == 99) return false; // deprecated relay
    if (second == 168) return false;
  }
  if (first == 198) {
    if (second == 18 || second == 19) return false; // benchmarking
    if (second == 51 && bytes[2] == 100) return false; // documentation
  }
  if (first == 203 && second == 0 && bytes[2] == 113) return false;
  return true;
}
