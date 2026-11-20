@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/navigation/models/account_features.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/features/navigation/providers/account_features_provider.dart';
import 'package:conduit_core/features/tether/tether_devices.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'support/fake_hermes_server.dart';
import 'support/null_sink.dart';

/// `system.capabilities` follows the account, and `capabilities.changed`
/// says when it moved.
void main() {
  group('the flags for an account', () {
    const openWebUi = SidebarTabAvailability(
      hermesOnly: false,
      hasOpenWebUi: true,
      hermesEnabled: false,
      notesEnabled: true,
      terminalEnabled: false,
      channelsEnabled: true,
    );

    test('sections follow the phone, the rest the server', () {
      final capabilities = CapabilitiesService.capabilitiesOf(
        const AccountFeatures(
          sidebar: openWebUi,
          folders: true,
          calendar: true,
          memories: true,
          workspaceSections: <WorkspaceSection>[WorkspaceSection.prompts],
        ),
        config: const BackendConfig(
          enableWebsocket: false,
          enableMessageRating: false,
        ),
      );
      expect(capabilities.notes, isTrue);
      // Channels are the phone's flag, not the socket's guess.
      expect(capabilities.channels, isTrue);
      expect(capabilities.terminal, isFalse);
      expect(capabilities.hermes, isFalse);
      expect(capabilities.calendar, isTrue);
      expect(capabilities.automations, isFalse);
      expect(capabilities.workspace, isTrue);
      expect(capabilities.workspacePrompts, isTrue);
      expect(capabilities.workspaceModels, isFalse);
      expect(capabilities.folders, isTrue);
      expect(capabilities.memories, isTrue);
      // The server answers these.
      expect(capabilities.messageRating, isFalse);
      expect(capabilities.bulkSelection, isTrue);
    });

    test('scheduled tasks are offered only with Advanced on', () {
      Capabilities of({required bool advanced}) =>
          CapabilitiesService.capabilitiesOf(
            AccountFeatures(
              sidebar: openWebUi,
              automations: true,
              scheduledTasks: advanced,
            ),
          );
      expect(of(advanced: false).automations, isTrue);
      expect(of(advanced: false).scheduledTasks, isFalse);
      expect(of(advanced: true).scheduledTasks, isTrue);
    });

    test('with no server, the server-only flags stay off', () {
      final capabilities = CapabilitiesService.capabilitiesOf(
        const AccountFeatures(),
      );
      expect(capabilities, Capabilities.none);
    });
  });

  // The backend config is cached once for every server: a config another
  // server answered (an account switch, a refresh still in flight) must
  // never show its flags for the active one.
  test("a config another server answered is not the active one's", () async {
    ProviderContainer over(String? configServer) => ProviderContainer(
      overrides: [
        accountFeaturesProvider.overrideWithValue(const AccountFeatures()),
        openWebUiAccountAvailableProvider.overrideWithValue(true),
        activeServerProvider.overrideWith(
          (ref) async =>
              const ServerConfig(id: 'b', name: 'B', url: 'https://b.example'),
        ),
        backendConfigProvider.overrideWith(
          () => _Config(
            BackendConfig(
              serverId: configServer,
              enableDirectConnections: true,
              enableMessageRating: true,
            ),
          ),
        ),
      ],
    );
    for (final (server, shown) in [('a', false), (null, false), ('b', true)]) {
      final container = over(server);
      addTearDown(container.dispose);
      await container.read(activeServerProvider.future);
      await container.read(backendConfigProvider.future);
      final service = CapabilitiesService(container);
      addTearDown(service.dispose);
      expect(service.current.directConnections, shown, reason: '$server');
      expect(service.current.messageRating, shown, reason: '$server');
    }
  });

  test('a Tether device changing what it offers is announced', () {
    final container = ProviderContainer(
      overrides: [
        accountFeaturesProvider.overrideWithValue(const AccountFeatures()),
        openWebUiAccountAvailableProvider.overrideWithValue(false),
        tetherDevicesProvider.overrideWith(_Devices.new),
      ],
    );
    addTearDown(container.dispose);
    final events = EventBus();
    final announced = <String>[];
    events.tap((event, _, _) => announced.add(event));
    final service = CapabilitiesService(container, events: events);
    addTearDown(service.dispose);
    announced.clear();

    (container.read(tetherDevicesProvider.notifier) as _Devices).bump();

    // The window reads the terminals again on this.
    expect(announced, <String>[ConduitEventSpecs.capabilitiesChanged.name]);
  });

  group('over a running core', () {
    late Directory temporary;
    late CoreRuntime runtime;
    late FakeHermesServer hermesServer;

    setUpAll(() async {
      temporary = Directory.systemTemp.createTempSync('capabilities-test');
      runtime = await CoreRuntime.start(
        config: BootstrapConfig(
          sessionToken: 'a' * 43,
          masterKey: base64.encode(List<int>.generate(32, (i) => i)),
          userDataDir: temporary.path,
        ),
        directories: DaemonDirectories.create(temporary.path),
        log: DaemonLog(level: 'error', sink: NullSink()),
      );
      hermesServer = await FakeHermesServer.start();
    });

    tearDownAll(() async {
      await hermesServer.close();
      await runtime.dispose();
      temporary.deleteSync(recursive: true);
    });

    test('Hermes switched on and off is announced', () async {
      final events = EventBus();
      final seen = <EventEnvelope>[];
      events.attach('window', seen.add);
      final reported = <Capabilities>[];
      final waiting = <(bool Function(Capabilities), Completer<void>)>[];
      final service = CapabilitiesService(
        runtime.container,
        events: events,
        onChange: (next) {
          reported.add(next);
          for (final (done, change) in waiting.toList()) {
            if (done(next) && !change.isCompleted) change.complete();
          }
        },
      );
      // The change [done] describes, as the service announces it.
      Future<void> announced(bool Function(Capabilities) done) {
        if (done(service.current)) return Future<void>.value();
        final change = Completer<void>();
        waiting.add((done, change));
        return change.future;
      }

      addTearDown(service.dispose);
      final hermes = HermesService(runtime.container, events: events);

      // No backend yet: nothing to show.
      expect(service.current.hermes, isFalse);

      await hermes.saveSettings(
        HermesSettingsEdit(
          baseUrl: hermesServer.baseUrl,
          apiKey: hermesServer.key,
          onboarding: true,
        ),
      );
      await announced((c) => c.hermes);
      expect(service.current.hermesOnly, isTrue);
      // Hermes alone: Open WebUI's sections stay hidden.
      expect(service.current.notes, isFalse);
      expect(service.current.workspace, isFalse);
      expect(reported.last, service.current);
      final told = seen
          .where((e) => e.event == ConduitEvents.capabilitiesChanged)
          .length;
      expect(told, greaterThan(0));

      await hermes.saveSettings(
        HermesSettingsEdit(baseUrl: hermesServer.baseUrl, enabled: false),
      );
      await announced((c) => !c.hermes);
      expect(
        seen.where((e) => e.event == ConduitEvents.capabilitiesChanged).length,
        greaterThan(told),
      );
    });
  });
}

/// A backend config that answers [config].
final class _Config extends BackendConfigNotifier {
  _Config(this.config);

  final BackendConfig config;

  @override
  Future<BackendConfig?> build() async => config;
}

/// Tether devices that change on cue.
final class _Devices extends TetherDevices {
  void bump() => state++;
}
