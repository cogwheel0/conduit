import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';

/// Subscribes [sessionId] to [scopes] the way `events.subscribe` does over
/// RPC: replaces its interest set, then sends what it is owed for a turn
/// already running there, or one that finished before it could listen.
void subscribeWindow(
  EventBus events,
  TurnsService turns,
  String sessionId,
  List<String> scopes,
) {
  final subscription = EventSubscription(scopes: scopes);
  final previous = events.subscribe(sessionId, subscription);
  turns.catchUp(sessionId, subscription, alreadySubscribed: previous);
}
