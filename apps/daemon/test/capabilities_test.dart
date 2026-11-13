@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/navigation/models/account_features.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
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

    test('with no server, the server-only flags stay off', () {
      final capabilities = CapabilitiesService.capabilitiesOf(
        const AccountFeatures(),
      );
      expect(capabilities, Capabilities.none);
    });
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
      final service = CapabilitiesService(
        runtime.container,
        events: events,
        onChange: reported.add,
      );
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
      await _until(() => service.current.hermes);
      expect(service.current.hermesOnly, isTrue);
      // Hermes alone: Open WebUI's sections stay hidden.
      expect(service.current.notes, isFalse);
      expect(service.current.workspace, isFalse);
      expect(reported.last, service.current);
      final announced = seen
          .where((e) => e.event == ConduitEvents.capabilitiesChanged)
          .length;
      expect(announced, greaterThan(0));

      await hermes.saveSettings(
        HermesSettingsEdit(baseUrl: hermesServer.baseUrl, enabled: false),
      );
      await _until(() => !service.current.hermes);
      expect(
        seen.where((e) => e.event == ConduitEvents.capabilitiesChanged).length,
        greaterThan(announced),
      );
    });
  });
}

/// Waits (up to 5 s) for [done].
Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the capabilities to change');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
