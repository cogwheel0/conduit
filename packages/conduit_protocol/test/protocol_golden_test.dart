@TestOn('vm')
library;

import 'package:test/test.dart';

import 'src/golden_checks.dart';

void main() {
  test('protocol goldens and invariants hold on the VM', () {
    final failures = runProtocolGoldenChecks();
    expect(
      failures,
      isEmpty,
      reason:
          'The daemon and the UI decode the same bytes only as long as these '
          'hold. If a change is intended, run `dart run tool/dump_goldens.dart` '
          'and bump kConduitProtocolVersion.\n${failures.join('\n')}',
    );
  });
}
