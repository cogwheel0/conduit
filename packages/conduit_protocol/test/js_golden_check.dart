// The golden checks as a plain `main()`, so CI can compile them with
// `dart compile js` and run them under Node.
//
// `package:test`'s own browser runner would need a browser; this is cheaper
// and proves the thing the renderer actually requires — that conduit_protocol
// and its goldens survive dart2js. A mismatch here is almost always a number
// or type-coercion difference between the VM and JS.
//
//   dart compile js -o build/js_golden_check.js test/js_golden_check.dart
//   node build/js_golden_check.js
//
// Exits non-zero by throwing: an uncaught error from compiled Dart surfaces as
// a Node exception, which is the signal CI checks.
import 'src/golden_checks.dart';

void main() {
  final failures = runProtocolGoldenChecks();
  if (failures.isNotEmpty) {
    throw StateError(
      'conduit_protocol goldens failed under dart2js:\n'
      '${failures.map((f) => '  - $f').join('\n')}',
    );
  }
  print('conduit_protocol: all golden checks passed under dart2js');
}
