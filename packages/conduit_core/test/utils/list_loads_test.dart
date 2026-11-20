import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/utils/list_loads.dart';
import 'package:test/test.dart';

void main() {
  test(
    'settles once the newest read finishes, while an older one has not',
    () async {
      final loads = ListLoads();
      final older = loads.start();
      final settled = loads.settled();
      var done = false;
      unawaited(settled.then((_) => done = true));

      final newer = loads.start();
      await pumpEventQueue();
      check(done).isFalse();
      newer.finish();

      // The older read is still under way.
      await settled;
      older.finish();
    },
  );
}
