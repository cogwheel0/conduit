import 'package:conduit_core/conduit_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// The mobile [WakelockPort], backed by `wakelock_plus`.
class WakelockPlusPort implements WakelockPort {
  const WakelockPlusPort();

  @override
  Future<void> toggle({required bool enable}) {
    return WakelockPlus.toggle(enable: enable);
  }
}
