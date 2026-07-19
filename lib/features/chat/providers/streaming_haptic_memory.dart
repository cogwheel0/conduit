import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Streaming haptic events that must fire at most once per assistant message.
enum StreamingHapticEvent { contentArrival, turnCompleted }

/// Remount-proof memory of per-message streaming haptics.
///
/// The assistant row's State can be recreated mid-stream (live-tail slot
/// restructuring, transient provider gaps, list churn). Widget-local guard
/// fields die with the State and replay the haptics on every remount, so the
/// fired flags live here, keyed by message id and bounded to the most recent
/// [maxEntries] messages.
class StreamingHapticMemory {
  StreamingHapticMemory({this.maxEntries = 128});

  /// Upper bound on remembered message ids; the least recently touched entry
  /// is evicted first.
  final int maxEntries;

  final LinkedHashMap<String, Set<StreamingHapticEvent>> _fired =
      LinkedHashMap<String, Set<StreamingHapticEvent>>();

  /// Marks [event] as fired for [messageId].
  ///
  /// Returns true when the event had not fired for this message yet, i.e. the
  /// caller should produce the haptic now.
  bool markFired(String messageId, StreamingHapticEvent event) {
    final events = _fired.remove(messageId) ?? <StreamingHapticEvent>{};
    // Re-insert to refresh recency before evicting the oldest entries.
    _fired[messageId] = events;
    final added = events.add(event);
    while (_fired.length > maxEntries) {
      _fired.remove(_fired.keys.first);
    }
    return added;
  }

  /// Re-arms the content-arrival haptic for [messageId] so an in-place
  /// re-stream of the same row (regeneration reusing the id) can announce
  /// content again.
  void rearmContentArrival(String messageId) {
    _fired[messageId]?.remove(StreamingHapticEvent.contentArrival);
  }
}

/// App-wide [StreamingHapticMemory], shared by every assistant row so the
/// guards survive row remounts.
final streamingHapticMemoryProvider = Provider<StreamingHapticMemory>(
  (ref) => StreamingHapticMemory(),
);
