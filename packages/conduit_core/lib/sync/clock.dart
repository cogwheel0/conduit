import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'clock.g.dart';

/// Epoch-seconds clock seam (CDT-RFC-001 §7.2, A5).
///
/// IMPORTANT — device clock, used deliberately: server timestamps
/// (`updated_at`) are NEVER compared against device clocks (REQ §7.2
/// timestamps note). This clock is the ONE allowed exception: it feeds
/// outbox bookkeeping ONLY — `OutboxOps.nextAttemptAt` scheduling — where the
/// value is compared solely against itself (a previously-stored
/// `nextAttemptAt`), never against any server-minted timestamp. A backward
/// device-clock jump can only make an op runnable slightly early, which is
/// harmless.
abstract interface class SyncClock {
  /// Device wall clock in whole seconds since the Unix epoch.
  int nowEpochSeconds();
}

/// Production clock over `DateTime.now()`.
class SystemSyncClock implements SyncClock {
  const SystemSyncClock();

  @override
  int nowEpochSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}

@Riverpod(keepAlive: true)
SyncClock syncClock(Ref ref) => const SystemSyncClock();
