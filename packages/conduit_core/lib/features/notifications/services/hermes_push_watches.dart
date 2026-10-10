import 'package:riverpod/riverpod.dart';

/// The Hermes API server sessions the push plugin was told to watch, and
/// until when.
///
/// The plugin pushes a reply in an API server session only while a watch
/// for it lasts, so a turn that started before push was on, whose watch
/// failed, or that outlasted it, gets no push. Push records each watch the
/// plugin accepted here; the notification router then leaves the
/// background alert of such a session's reply to the push, and posts its
/// own for any other.
class HermesPushWatches {
  HermesPushWatches({DateTime Function() now = DateTime.now}) : _now = now;

  final DateTime Function() _now;

  /// When each watch ends, by `<connectionId>|<sessionId>`.
  final Map<String, DateTime> _until = <String, DateTime>{};

  /// Notes that the plugin of [connectionId] accepted a watch of [sessionId]
  /// lasting [ttl].
  void record(String connectionId, String sessionId, {required Duration ttl}) {
    final now = _now();
    _until.removeWhere((_, until) => !now.isBefore(until));
    _until[_key(connectionId, sessionId)] = now.add(ttl);
  }

  /// Whether a watch of [sessionId] on [connectionId] lasts now.
  bool isWatched(String connectionId, String sessionId) {
    final until = _until[_key(connectionId, sessionId)];
    return until != null && _now().isBefore(until);
  }

  static String _key(String connectionId, String sessionId) =>
      '$connectionId|$sessionId';
}

/// The app's [HermesPushWatches]; it lives as long as the app does.
final hermesPushWatchesProvider = Provider<HermesPushWatches>(
  (ref) => HermesPushWatches(),
);
