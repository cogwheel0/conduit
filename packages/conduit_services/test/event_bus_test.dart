import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:test/test.dart';

/// Sequence numbers are per session, so a client can tell a lost event from
/// one its own filter left out.
void main() {
  late EventBus bus;
  late Map<String, List<EventEnvelope>> seen;

  void open(String session, {EventSubscription? subscription}) {
    seen[session] = <EventEnvelope>[];
    bus.attach(session, seen[session]!.add);
    if (subscription != null) bus.subscribe(session, subscription);
  }

  List<int> seqs(String session) =>
      seen[session]!.map((e) => e.seq).toList(growable: false);

  setUp(() {
    bus = EventBus();
    seen = <String, List<EventEnvelope>>{};
  });

  test('a session counts only the events it is sent', () {
    open(
      'a',
      subscription: const EventSubscription(
        events: <String>[ConduitEvents.turnDelta],
        scopes: <String>['chat_1'],
      ),
    );
    open(
      'b',
      subscription: const EventSubscription(scopes: <String>['chat_2']),
    );

    bus
      ..publish(ConduitEvents.turnDelta, scope: 'chat_2')
      ..publish(ConduitEvents.notesChanged)
      ..publish(ConduitEvents.turnDelta, scope: 'chat_1')
      ..publish(ConduitEvents.turnDelta, scope: 'chat_2')
      ..publish(ConduitEvents.turnDelta, scope: 'chat_1');

    expect(seqs('a'), <int>[1, 2]);
    expect(seqs('b'), <int>[1, 2, 3]);
    expect(bus.lastSeqFor('a'), 2);
    expect(bus.lastSeqFor('b'), 3);
  });

  test("an event a session's gate refuses is not numbered; the gate is told "
      'of a direct send before it goes, and of a change of filter', () {
    seen['a'] = <EventEnvelope>[];
    final gate = _Gate(seen['a']!);
    bus.attach('a', seen['a']!.add, gate: gate);
    bus.subscribe('a', const EventSubscription(scopes: <String>['chat_1']));
    open(
      'b',
      subscription: const EventSubscription(scopes: <String>['chat_1']),
    );
    expect(gate.filterChanges, 1);

    bus
      ..publish(
        ConduitEvents.turnDelta,
        scope: 'chat_1',
        payload: <String, dynamic>{'keep': false},
      )
      ..publish(
        ConduitEvents.turnDelta,
        scope: 'chat_1',
        payload: <String, dynamic>{'keep': true},
      )
      ..sendTo('a', ConduitEvents.turnCompleted, scope: 'chat_1');

    expect(seqs('a'), <int>[1, 2]);
    expect(seen['a']!.first.payload, <String, dynamic>{'keep': true});
    // Told before it was numbered.
    expect(gate.directs, <String>['${ConduitEvents.turnCompleted} 1']);
    // Another session is not asked: it gets both.
    expect(seqs('b'), <int>[1, 2]);
  });

  test('publish says how many sessions it reached', () {
    open('a');
    open('b', subscription: const EventSubscription(events: <String>['x']));
    expect(bus.publish(ConduitEvents.syncStatus), 1);
  });

  test('a direct send takes the next number, past the filter', () {
    open(
      'a',
      subscription: const EventSubscription(
        events: <String>[ConduitEvents.turnDelta],
      ),
    );
    open('b');
    bus.publish(ConduitEvents.turnDelta);
    bus.sendTo('a', ConduitEvents.uiRequest);
    bus.publish(ConduitEvents.turnDelta);

    expect(seqs('a'), <int>[1, 2, 3]);
    expect(seen['a']![1].event, ConduitEvents.uiRequest);
    // Only a's counter moved.
    expect(seqs('b'), <int>[1, 2]);
  });

  test('a new session starts again at 1', () {
    open('a');
    bus
      ..publish(ConduitEvents.syncStatus)
      ..publish(ConduitEvents.syncStatus)
      ..detach('a');
    expect(bus.lastSeqFor('a'), 0);

    open('a2');
    bus.publish(ConduitEvents.syncStatus);
    expect(seqs('a2'), <int>[1]);
  });

  test('a session closed while delivering does not break the fan-out', () {
    open('b');
    seen['a'] = <EventEnvelope>[];
    bus.attach('a', (envelope) {
      seen['a']!.add(envelope);
      bus.detach('a');
    });
    bus.publish(ConduitEvents.syncStatus);
    bus.publish(ConduitEvents.syncStatus);
    expect(seqs('a'), <int>[1]);
    expect(seqs('b'), <int>[1, 2]);
  });
}

/// Takes a published event when its payload says to keep it, and notes
/// what it is told, with how many events [delivered] then held.
final class _Gate implements EventGate {
  _Gate(this.delivered);

  final List<EventEnvelope> delivered;
  int filterChanges = 0;
  final List<String> directs = <String>[];

  @override
  bool admit(String event, String? scope, Map<String, dynamic> payload) =>
      payload['keep'] == true;

  @override
  void direct(String event, String? scope, Map<String, dynamic> payload) =>
      directs.add('$event ${delivered.length}');

  @override
  void filterChanged() => filterChanges++;
}
