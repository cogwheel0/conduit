import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';

/// An in-process listener on the [EventBus] ([EventBus.tap]).
typedef EventTap = void Function(
  String event,
  String? scope,
  Map<String, dynamic> payload,
);

/// Fan-out of daemon events to every connected window, with per-client
/// filters.
///
/// Each session numbers the events it is sent, from 1, with no gaps. A
/// client can then tell a lost event from one its filter left out: the
/// filter never shows up as a gap, so a gap always means something went
/// missing and the client refetches instead of patching stale state. One
/// shared counter could not do that, since every event another window
/// wanted, or this one filtered out, looked like a gap here.
class EventBus {
  final Map<String, _Subscriber> _subscribers = <String, _Subscriber>{};

  /// Number of attached clients. Used by tests and by the idle-shutdown check.
  int get subscriberCount => _subscribers.length;

  /// The last sequence number [sessionId] was sent; 0 before its first
  /// event, and for a session that is not attached.
  int lastSeqFor(String sessionId) => _subscribers[sessionId]?.seq ?? 0;

  /// Starts delivering to [sessionId]. Its numbering starts at 1, so a
  /// reconnecting window, which is a new session, starts again too.
  void attach(String sessionId, void Function(EventEnvelope envelope) deliver) {
    _subscribers[sessionId] = _Subscriber(deliver);
    final waiting = List<Completer<bool>>.of(_attachWaiters);
    _attachWaiters.clear();
    for (final waiter in waiting) {
      waiter.complete(true);
    }
  }

  final List<Completer<bool>> _attachWaiters = <Completer<bool>>[];

  /// True when the next client attaches (a window reconnecting), false when
  /// [until] completes first. Either way nothing is left waiting here.
  Future<bool> attachBefore(Future<void> until) {
    final waiter = Completer<bool>();
    _attachWaiters.add(waiter);
    unawaited(
      until.then((_) {
        if (_attachWaiters.remove(waiter)) waiter.complete(false);
      }),
    );
    return waiter.future;
  }

  void detach(String sessionId) => _subscribers.remove(sessionId);

  final List<EventTap> _taps = <EventTap>[];

  /// Hears every event published from now on, in this process: what
  /// `intents.ask` waits for its answer with. A tap is not a window: it is
  /// never counted in [subscriberCount] (which decides whether anyone can
  /// be asked a question), never [watches] a chat and takes no sequence
  /// numbers. Returns the function that removes it.
  void Function() tap(EventTap listener) {
    _taps.add(listener);
    return () => _taps.remove(listener);
  }

  /// Whether a window is listening to [scope] (shows that chat, say).
  bool watches(String scope) =>
      _subscribers.values.any((subscriber) => subscriber.scopes.contains(scope));

  /// Replaces [sessionId]'s interest set.
  ///
  /// Replace rather than merge: a reconnecting window sends its whole set in
  /// one call, and merging would leave it subscribed to chats it has since
  /// navigated away from.
  ///
  /// Returns the scopes [sessionId] was subscribed to before, so what it is
  /// owed for a newly added scope can be told from what it already saw.
  Set<String> subscribe(String sessionId, EventSubscription subscription) {
    final subscriber = _subscribers[sessionId];
    if (subscriber == null) return const <String>{};
    final previous = subscriber.scopes;
    subscriber.events = subscription.events.toSet();
    subscriber.scopes = subscription.scopes.toSet();
    return previous;
  }

  /// Publishes to every client whose filter matches, each under its own
  /// next sequence number.
  ///
  /// Returns how many clients it reached; taps ([tap]) are not counted.
  int publish(
    String event, {
    String? scope,
    Map<String, dynamic> payload = const <String, dynamic>{},
  }) {
    for (final listener in _taps.toList()) {
      listener(event, scope, payload);
    }
    var reached = 0;
    // A copy: delivering can close a session, which detaches it.
    for (final subscriber in _subscribers.values.toList()) {
      if (!subscriber.wants(event, scope)) continue;
      subscriber.send(event, scope, payload);
      reached++;
    }
    return reached;
  }

  /// Sends one event to [sessionId] alone, past its filter, under its next
  /// sequence number.
  ///
  /// For what a window is owed when it subscribes -- a question already
  /// waiting, a turn already streaming -- which was published before it was
  /// listening.
  void sendTo(
    String sessionId,
    String event, {
    String? scope,
    Map<String, dynamic> payload = const <String, dynamic>{},
  }) {
    _subscribers[sessionId]?.send(event, scope, payload);
  }

  /// Publishes [spec]'s event with [payload], typed by the protocol's event
  /// table: what the services use, so a payload cannot drift from what
  /// windows decode. [publish] stays for tests that route synthetic events.
  ///
  /// [scope] must be given exactly when the spec is scoped.
  int emit<T>(ConduitEventSpec<T> spec, T payload, {String? scope}) => publish(
    spec.name,
    scope: _checkScope(spec, scope),
    payload: _encode(spec, payload),
  );

  /// [sendTo], typed as [emit] is.
  void emitTo<T>(
    String sessionId,
    ConduitEventSpec<T> spec,
    T payload, {
    String? scope,
  }) => sendTo(
    sessionId,
    spec.name,
    scope: _checkScope(spec, scope),
    payload: _encode(spec, payload),
  );

  /// The scope, after checking in debug builds and tests that it is given
  /// exactly when [spec] is scoped.
  static String? _checkScope(ConduitEventSpec<Object?> spec, String? scope) {
    assert(
      spec.scoped == (scope != null),
      '${spec.name} is ${spec.scoped ? '' : 'un'}scoped',
    );
    return scope;
  }

  static Map<String, dynamic> _encode<T>(ConduitEventSpec<T> spec, T payload) =>
      spec.payload == null || payload == null
      ? const <String, dynamic>{}
      : encodeDto(payload);
}

class _Subscriber {
  _Subscriber(this.deliver);

  final void Function(EventEnvelope envelope) deliver;

  /// The last sequence number this session was sent.
  int seq = 0;

  /// Empty means "every event", matching [EventSubscription.events].
  Set<String> events = <String>{};

  /// Empty means "session-wide events only".
  Set<String> scopes = <String>{};

  bool wants(String event, String? scope) {
    if (events.isNotEmpty && !events.contains(event)) return false;
    // Session-wide events always go through; a window cannot opt out of
    // `sync.status` by forgetting to list a scope.
    if (scope == null) return true;
    return scopes.contains(scope);
  }

  void send(String event, String? scope, Map<String, dynamic> payload) {
    deliver(
      EventEnvelope(event: event, seq: ++seq, scope: scope, payload: payload),
    );
  }
}
