import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/ports/location_port.dart';
import 'package:conduit_core/services/location_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:fake_async/fake_async.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// `{{USER_LOCATION}}` on the Mac: the core's location port answered by the
/// window (`location.command` / `location.report`), asked only for a prompt
/// that names the variable while the account's setting is on. A fake window
/// answers as the desktop app's location services do.
void main() {
  late EventBus bus;
  late WindowLocationBridge bridge;

  setUp(() {
    bus = EventBus();
    bridge = WindowLocationBridge(
      timeout: const Duration(milliseconds: 300),
      permissionTimeout: const Duration(milliseconds: 300),
    );
    bridge.bind(bus);
  });

  group('the port', () {
    test('reads as off with no window to ask', () async {
      expect(await bridge.isLocationServiceEnabled(), isFalse);
      expect(await bridge.checkPermission(), LocationPermissionStatus.denied);
      expect(bridge.currentPosition, throwsStateError);
    });

    test('takes the window\'s answers', () async {
      final window = _Window(bus, bridge);
      expect(await bridge.isLocationServiceEnabled(), isTrue);
      expect(
        await bridge.checkPermission(),
        LocationPermissionStatus.whileInUse,
      );
      final fix = await bridge.currentPosition();
      expect(fix.latitude, 51.50142);
      expect(fix.longitude, -0.14189);
      expect(window.asked, <LocationCommandKind>[
        LocationCommandKind.status,
        LocationCommandKind.status,
        LocationCommandKind.currentPosition,
      ]);
    });

    test('a refusal or silence is no position', () {
      fakeAsync((time) {
        final window = _Window(bus, bridge)..fails = true;
        Object? refused;
        bridge.currentPosition().catchError((Object error) {
          refused = error;
          throw error;
        }).ignore();
        time.flushMicrotasks();
        expect(refused, isA<StateError>());

        // Silence: each command waits out its deadline on the fake clock.
        window
          ..fails = false
          ..silent = true;
        bool? enabled;
        LocationPermissionStatus? permission;
        bridge.isLocationServiceEnabled().then((on) => enabled = on);
        bridge.requestPermission().then((p) => permission = p);
        time.flushMicrotasks();
        expect(enabled, isNull, reason: 'it waits for the window');
        expect(permission, isNull, reason: 'it waits for the window');
        time.elapse(const Duration(milliseconds: 300));
        expect(enabled, isFalse);
        expect(permission, LocationPermissionStatus.denied);
      });
    });
  });

  group('a prompt template', () {
    late ProviderContainer container;
    setUp(() {
      container = ProviderContainer(overrides: windowLocationOverrides(bridge));
    });
    tearDown(() => container.dispose());

    const nearby = Prompt(
      command: '/nearby',
      title: 'Nearby',
      content: 'Suggest a walk near {{USER_LOCATION}}.',
    );
    const plain = Prompt(command: '/walk', title: 'Walk', content: 'A walk.');

    PromptsService service(Map<String, dynamic>? settings) => PromptsService(
      container,
      fetch: () async => <Prompt>[nearby, plain],
      userSettings: () async => settings,
    );

    test(
      'is filled with the window\'s position while the setting is on',
      () async {
        final window = _Window(bus, bridge);
        final rendered = await service(const <String, dynamic>{
          'ui': <String, dynamic>{'userLocation': true},
        }).render(const RenderPrompt(command: '/nearby'));
        expect(
          rendered.content,
          'Suggest a walk near 51.501, -0.142 (lat, long).',
        );
        expect(window.asked, contains(LocationCommandKind.currentPosition));
      },
    );

    test('never asks the window while the setting is off', () async {
      final window = _Window(bus, bridge);
      final off = await service(const <String, dynamic>{
        'ui': <String, dynamic>{'userLocation': false},
      }).render(const RenderPrompt(command: '/nearby'));
      expect(off.content, 'Suggest a walk near $userLocationUnknown.');

      final typed = await service(const <String, dynamic>{
        'ui': <String, dynamic>{'userLocation': 'Port Wren'},
      }).render(const RenderPrompt(command: '/nearby'));
      expect(typed.content, 'Suggest a walk near Port Wren.');
      expect(window.asked, isEmpty);
    });

    test('that does not name the variable asks nothing', () async {
      final window = _Window(bus, bridge);
      final rendered = await service(const <String, dynamic>{
        'ui': <String, dynamic>{'userLocation': true},
      }).render(const RenderPrompt(command: '/walk'));
      expect(rendered.content, 'A walk.');
      expect(window.asked, isEmpty);
      expect(bridge.sent, isEmpty);
    });
  });

  test('the daemon\'s location service asks only when named', () async {
    final container = ProviderContainer(
      overrides: windowLocationOverrides(bridge),
    );
    addTearDown(container.dispose);
    final window = _Window(bus, bridge);
    final service = container.read(locationServiceProvider);
    expect(service.policy, LocationLookupPolicy.whenNamedAndAllowed);
    const on = <String, dynamic>{'userLocation': true};

    expect(
      await service.resolveLocationForRequest(
        on,
        prompts: const <String?>['Be brief.'],
      ),
      isNull,
    );
    expect(window.asked, isEmpty);

    expect(
      await service.resolveLocationForRequest(
        on,
        prompts: const <String?>['Near {{USER_LOCATION}}.'],
      ),
      '51.501, -0.142 (lat, long)',
    );
    expect(window.asked, contains(LocationCommandKind.currentPosition));
  });
}

/// The desktop app's location services, as the daemon sees them.
final class _Window {
  _Window(this.bus, this.bridge) {
    bus.attach('window', _deliver);
  }

  final EventBus bus;
  final WindowLocationBridge bridge;
  final asked = <LocationCommandKind>[];
  bool fails = false;
  bool silent = false;

  void _deliver(EventEnvelope envelope) {
    if (envelope.event != ConduitEvents.locationCommand) return;
    final command = LocationCommand.fromJson(envelope.payload);
    asked.add(command.kind);
    if (silent) return;
    if (fails) {
      bridge.report(LocationReport(id: command.id, ok: false, error: 'no'));
      return;
    }
    bridge.report(switch (command.kind) {
      LocationCommandKind.status => LocationReport(
        id: command.id,
        servicesEnabled: true,
        permission: LocationPermission.whileInUse,
      ),
      LocationCommandKind.requestPermission => LocationReport(
        id: command.id,
        permission: LocationPermission.whileInUse,
      ),
      LocationCommandKind.currentPosition => LocationReport(
        id: command.id,
        latitude: 51.50142,
        longitude: -0.14189,
      ),
    });
  }
}
