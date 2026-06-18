import 'package:checks/checks.dart';
import 'package:conduit/core/models/socket_transport_availability.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('value equality: logically equal instances are == and hash-equal', () {
    const a = SocketTransportAvailability(
      allowPolling: true,
      allowWebsocketOnly: false,
    );
    const b = SocketTransportAvailability(
      allowPolling: true,
      allowWebsocketOnly: false,
    );

    // Distinct instances (the options provider rebuilds a fresh one each time)
    // must compare equal so watchers (e.g. SocketServiceManager) don't rebuild
    // and churn the socket when the resolved transport is unchanged.
    check(a == b).isTrue();
    check(a.hashCode).equals(b.hashCode);
  });

  test('value equality: differing fields are not equal', () {
    const base = SocketTransportAvailability(
      allowPolling: true,
      allowWebsocketOnly: true,
    );
    check(
      base ==
          const SocketTransportAvailability(
            allowPolling: false,
            allowWebsocketOnly: true,
          ),
    ).isFalse();
    check(
      base ==
          const SocketTransportAvailability(
            allowPolling: true,
            allowWebsocketOnly: false,
          ),
    ).isFalse();
  });
}
