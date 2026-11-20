import 'package:checks/checks.dart';
import 'package:conduit_core/utils/list_loads.dart';
import 'package:test/test.dart';

void main() {
  test(
    'settles once the newest read finishes, while an older one has not',
    () async {
      final loads = ListLoads();
      final older = loads.start();
      var settled = false;
      loads.settled().then((_) => settled = true);

      final newer = loads.start();
      await pumpEventQueue();
      check(settled).isFalse();
      newer.finish();
      await pumpEventQueue();

      check(settled).isTrue();
      older.finish();
    },
  );
}
