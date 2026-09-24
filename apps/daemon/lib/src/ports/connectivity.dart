import 'dart:async';
import 'dart:io';

import 'package:conduit_core/ports/connectivity_port.dart';

/// The desktop [ConnectivityPort], from `dart:io` alone.
///
/// There is no desktop equivalent of the mobile connectivity plugin's push
/// notification inside a headless Dart process, so this polls
/// [NetworkInterface.list] instead. That is cheap -- it reads the OS routing
/// tables, no network traffic -- and the port's contract is deliberately
/// weak: "an interface exists" is a hint that a probe is worth attempting,
/// never a claim about reachability.
///
/// Electron *does* get `net.isOnline` events; forwarding them over RPC into
/// [report] makes the edge arrive immediately instead of up to one poll
/// interval late. Polling stays as the floor under that.
final class DaemonConnectivity implements ConnectivityPort {
  DaemonConnectivity({this.pollInterval = const Duration(seconds: 10)});

  final Duration pollInterval;

  final StreamController<bool> _changes = StreamController<bool>.broadcast();
  Timer? _timer;
  bool? _last;

  @override
  Future<bool> hasNetworkInterface() async {
    final online = await _probe();
    _publish(online);
    return online;
  }

  /// Starts the poll. Idempotent, so a second caller cannot double the rate.
  void start() {
    _timer ??= Timer.periodic(
      pollInterval,
      (_) async => _publish(await _probe()),
    );
    unawaited(hasNetworkInterface());
  }

  /// Accepts an out-of-band signal, for Electron's `net.isOnline`.
  void report(bool online) => _publish(online);

  @override
  Stream<bool> get onChanged => _changes.stream;

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _changes.close();
  }

  /// Loopback is always up, so counting it would make every machine look
  /// online forever -- which is exactly the bug that makes a connectivity
  /// check worthless.
  Future<bool> _probe() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
      );
      return interfaces.any((interface) => interface.addresses.isNotEmpty);
    } on OSError {
      // Refusing to answer is not the same as being offline; an OS that will
      // not enumerate interfaces should not stop the core from trying.
      return true;
    } on SocketException {
      return true;
    }
  }

  void _publish(bool online) {
    if (_last == online) return;
    _last = online;
    if (!_changes.isClosed) _changes.add(online);
  }
}
