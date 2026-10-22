import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

/// Arrival belongs to an answer/version, not a virtualized row's State.
/// Only identities are retained; no message text or widgets are kept alive.
class StreamingArrivalMemory {
  StreamingArrivalMemory({this.maxEntries = 512});
  final int maxEntries;
  final _seen = <Object>{};

  bool markVisible(Object answer) {
    final seen = _seen.remove(answer);
    _seen.add(answer);
    while (_seen.length > maxEntries) {
      _seen.remove(_seen.first);
    }
    return !seen;
  }
}

final streamingArrivalMemoryProvider = Provider<StreamingArrivalMemory>((ref) {
  ref.watch(hermesConnectionGenerationProvider);
  return StreamingArrivalMemory();
});
