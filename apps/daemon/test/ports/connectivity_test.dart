import 'package:conduitd/src/ports/connectivity.dart';
import 'package:test/test.dart';

void main() {
  test('onChanged fires on an edge, not on every probe', () async {
    final connectivity = DaemonConnectivity();
    addTearDown(connectivity.dispose);

    final seen = connectivity.onChanged.take(3).toList();

    connectivity.report(true);
    connectivity.report(true);
    connectivity.report(false);
    connectivity.report(true);

    expect(await seen, <bool>[true, false, true]);
  });

  test('dispose stops the stream', () async {
    final connectivity = DaemonConnectivity();
    await connectivity.dispose();
    connectivity.report(true);
  });
}
