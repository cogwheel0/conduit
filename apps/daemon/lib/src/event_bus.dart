import 'package:conduit_protocol/conduit_protocol.dart';

/// Fan-out of daemon events to every connected window, with per-client
/// filters.
///
/// The sequence number is allocated here rather than per client so all
/// windows see one consistent ordering; a client that reconnects and finds a
/// gap knows it missed something and refetches instead of patching stale
/// state.
class EventBus {
  int _seq = 0;

  final Map<String, _Subscriber> _subscribers = <String, _Subscriber>{};

  /// Number of attached clients. Used by tests and by the idle-shutdown check.
  int get subscriberCount => _subscribers.length;

  /// The last sequence number handed out.
  int get lastSeq => _seq;

  void attach(String sessionId, void Function(EventEnvelope envelope) deliver) {
    _subscribers[sessionId] = _Subscriber(deliver);
  }

  void detach(String sessionId) => _subscribers.remove(sessionId);

  /// Replaces [sessionId]'s interest set.
  ///
  /// Replace rather than merge: a reconnecting window sends its whole set in
  /// one call, and merging would leave it subscribed to chats it has since
  /// navigated away from.
  void subscribe(String sessionId, EventSubscription subscription) {
    final subscriber = _subscribers[sessionId];
    if (subscriber == null) return;
    subscriber.events = subscription.events.toSet();
    subscriber.scopes = subscription.scopes.toSet();
  }

  /// Publishes to every client whose filter matches.
  ///
  /// Returns the envelope actually sent, so callers can log or assert on the
  /// sequence number.
  EventEnvelope publish(
    String event, {
    String? scope,
    Map<String, dynamic> payload = const <String, dynamic>{},
  }) {
    final envelope = EventEnvelope(
      event: event,
      seq: ++_seq,
      scope: scope,
      payload: payload,
    );
    for (final subscriber in _subscribers.values) {
      if (subscriber.wants(envelope)) subscriber.deliver(envelope);
    }
    return envelope;
  }
}

class _Subscriber {
  _Subscriber(this.deliver);

  final void Function(EventEnvelope envelope) deliver;

  /// Empty means "every event", matching [EventSubscription.events].
  Set<String> events = <String>{};

  /// Empty means "session-wide events only".
  Set<String> scopes = <String>{};

  bool wants(EventEnvelope envelope) {
    if (events.isNotEmpty && !events.contains(envelope.event)) return false;
    final scope = envelope.scope;
    // Session-wide events always go through; a window cannot opt out of
    // `sync.status` by forgetting to list a scope.
    if (scope == null) return true;
    return scopes.contains(scope);
  }
}
