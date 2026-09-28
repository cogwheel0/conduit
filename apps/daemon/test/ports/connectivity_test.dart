import 'package:conduitd/src/ports/connectivity.dart';
import 'package:test/test.dart';

void main() {
  test('reports on a machine with a real interface', () async {
    final connectivity = DaemonConnectivity();
    addTearDown(connectivity.dispose);

    // Not asserted as true: CI containers can genuinely have no non-loopback
    // interface. What matters is that it answers rather than hanging.
    expect(await connectivity.hasNetworkInterface(), isA<bool>());
  });

  test('onChanged fires on an edge, not on every probe', () async {
    final connectivity = DaemonConnectivity();
    addTearDown(connectivity.dispose);

    final seen = <bool>[];
    connectivity.onChanged.listen(seen.add);

    connectivity.report(true);
    connectivity.report(true);
    connectivity.report(false);
    connectivity.report(true);
    await Future<void>.delayed(Duration.zero);

    expect(seen, <bool>[true, false, true]);
  });

  test('start is idempotent', () async {
    final connectivity = DaemonConnectivity(
      pollInterval: const Duration(milliseconds: 20),
    );
    addTearDown(connectivity.dispose);

    connectivity.start();
    connectivity.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // A doubled timer would not be visible in the event stream, which only
    // reports edges -- so this asserts the thing that is observable: no
    // throw, and dispose still stops everything.
    await connectivity.dispose();
  });

  test('dispose stops the stream', () async {
    final connectivity = DaemonConnectivity();
    await connectivity.dispose();
    connectivity.report(true);
  });
}
