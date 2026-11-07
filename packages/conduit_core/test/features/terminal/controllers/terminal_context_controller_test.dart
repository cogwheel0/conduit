import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_browser_controller.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_context_controller.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_controller_gateways.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_session_controller.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/services/terminal_port_preview.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'fake_events_channel.dart';
import 'fake_terminal_screen.dart';

void main() {
  final server = TerminalServerInfo(
    kind: TerminalServerKind.system,
    selectionId: 'system:primary',
    baseUrl: Uri.parse('https://example.test'),
  );
  final replacementServer = TerminalServerInfo(
    kind: TerminalServerKind.direct,
    selectionId: 'manual:replacement',
    baseUrl: Uri.parse('https://replacement.test'),
  );

  test('context controller owns initial fallback selection', () async {
    final service = _MockTerminalService();
    final gateway = _FakeTerminalGateway(service: service)
      ..selectedServer = server;
    final harness = _TerminalControllerHarness(gateway);
    addTearDown(harness.dispose);

    await harness.context.sync(force: true);

    check(gateway.selectedServers).deepEquals([server]);
    verifyNever(
      () => service.getFeatures(
        server,
        sessionScopeId: any(named: 'sessionScopeId'),
      ),
    );
  });

  test(
    'context controller sequences feature, path, files, and ports',
    () async {
      final service = _MockTerminalService();
      final gateway = _FakeTerminalGateway(service: service)
        ..selectedTerminalId = server.selectionId
        ..selectedServer = server;
      when(
        () => service.getFeatures(server, sessionScopeId: 'scope'),
      ).thenAnswer((_) async => const TerminalServerFeatures());
      when(() => service.getCwd(server, sessionScopeId: 'scope'))
          .thenAnswer((_) async => '/workspace');
      when(
        () => service.listFiles(server, '/workspace/', sessionScopeId: 'scope'),
      ).thenAnswer(
        (_) async => const [
          TerminalFileEntry(
            name: 'README.md',
            path: '/workspace/README.md',
            isDirectory: false,
          ),
        ],
      );
      when(() => service.getListeningPorts(server, sessionScopeId: 'scope'))
          .thenAnswer((_) async => const [TerminalListeningPort(port: 8080)]);
      final harness = _TerminalControllerHarness(gateway);
      addTearDown(harness.dispose);

      await harness.context.sync(force: true);

      check(gateway.currentPath).equals('/workspace/');
      check(gateway.entries.single.name).equals('README.md');
      check(gateway.ports.single.port).equals(8080);
      check(harness.failures).isEmpty();
    },
  );

  test('rename rejects a file captured from a replaced context', () async {
    final service = _MockTerminalService();
    final gateway = _FakeTerminalGateway(service: service)
      ..selectedTerminalId = server.selectionId
      ..selectedServer = server
      ..currentPath = '/workspace/'
      ..sessionScopeId = 'scope-a';
    final harness = _TerminalControllerHarness(gateway);
    addTearDown(harness.dispose);
    final operationContext = harness.browser.captureOperationContext();
    check(operationContext).isNotNull();
    final capturedContext = operationContext!;

    gateway
      ..selectedTerminalId = replacementServer.selectionId
      ..selectedServer = replacementServer
      ..currentPath = '/replacement/'
      ..sessionScopeId = 'scope-b';
    when(
      () => service.moveEntry(
        replacementServer,
        '/workspace/README.md',
        '/replacement/renamed.md',
        sessionScopeId: 'scope-b',
      ),
    ).thenAnswer((_) async {});

    await harness.browser.renameEntry(
      capturedContext,
      const TerminalFileEntry(
        name: 'README.md',
        path: '/workspace/README.md',
        isDirectory: false,
      ),
      'renamed.md',
    );

    verifyNever(
      () => service.moveEntry(
        replacementServer,
        '/workspace/README.md',
        '/replacement/renamed.md',
        sessionScopeId: 'scope-b',
      ),
    );
    verifyNever(
      () => service.moveEntry(
        server,
        '/workspace/README.md',
        '/workspace/renamed.md',
        sessionScopeId: 'scope-a',
      ),
    );
  });

  test('delete rejects a file captured from a replaced context', () async {
    final service = _MockTerminalService();
    final gateway = _FakeTerminalGateway(service: service)
      ..selectedTerminalId = server.selectionId
      ..selectedServer = server
      ..currentPath = '/workspace/'
      ..sessionScopeId = 'scope-a';
    final harness = _TerminalControllerHarness(gateway);
    addTearDown(harness.dispose);
    final operationContext = harness.browser.captureOperationContext();
    check(operationContext).isNotNull();

    gateway
      ..selectedTerminalId = replacementServer.selectionId
      ..selectedServer = replacementServer
      ..currentPath = '/replacement/'
      ..sessionScopeId = 'scope-b';

    await harness.browser.deleteEntry(
      operationContext!,
      const TerminalFileEntry(
        name: 'README.md',
        path: '/workspace/README.md',
        isDirectory: false,
      ),
    );

    verifyNever(
      () => service.deleteEntry(
        replacementServer,
        '/workspace/README.md',
        sessionScopeId: 'scope-b',
      ),
    );
    verifyNever(
      () => service.deleteEntry(
        server,
        '/workspace/README.md',
        sessionScopeId: 'scope-a',
      ),
    );
  });

  test('destructive operations use the captured owner while current', () async {
    final service = _MockTerminalService();
    final gateway = _FakeTerminalGateway(service: service)
      ..selectedTerminalId = server.selectionId
      ..selectedServer = server
      ..currentPath = '/workspace/'
      ..sessionScopeId = 'scope-a';
    final harness = _TerminalControllerHarness(gateway);
    addTearDown(harness.dispose);
    final operationContext = harness.browser.captureOperationContext();
    check(operationContext).isNotNull();
    final capturedContext = operationContext!;
    const entry = TerminalFileEntry(
      name: 'README.md',
      path: '/workspace/README.md',
      isDirectory: false,
    );
    when(
      () => service.moveEntry(
        server,
        '/workspace/README.md',
        '/workspace/renamed.md',
        sessionScopeId: 'scope-a',
      ),
    ).thenAnswer((_) async {});
    when(
      () => service.deleteEntry(
        server,
        '/workspace/README.md',
        sessionScopeId: 'scope-a',
      ),
    ).thenAnswer((_) async {});
    when(
      () => service.listFiles(server, '/workspace/', sessionScopeId: 'scope-a'),
    ).thenAnswer((_) async => const []);
    when(() => service.getListeningPorts(server, sessionScopeId: 'scope-a'))
        .thenAnswer((_) async => const []);

    await harness.browser.renameEntry(capturedContext, entry, 'renamed.md');
    await harness.browser.deleteEntry(capturedContext, entry);

    verify(
      () => service.moveEntry(
        server,
        '/workspace/README.md',
        '/workspace/renamed.md',
        sessionScopeId: 'scope-a',
      ),
    ).called(1);
    verify(
      () => service.deleteEntry(
        server,
        '/workspace/README.md',
        sessionScopeId: 'scope-a',
      ),
    ).called(1);
  });

  test('an older directory listing cannot replace a newer one', () async {
    final service = _MockTerminalService();
    final gateway = _FakeTerminalGateway(service: service)
      ..selectedTerminalId = server.selectionId
      ..selectedServer = server
      ..currentPath = '/old/'
      ..sessionScopeId = 'scope';
    final harness = _TerminalControllerHarness(gateway);
    addTearDown(harness.dispose);
    final oldListing = Completer<List<TerminalFileEntry>>();
    when(() => service.listFiles(server, '/old/', sessionScopeId: 'scope'))
        .thenAnswer((_) => oldListing.future);
    when(
      () => service.listFiles(server, '/workspace/', sessionScopeId: 'scope'),
    ).thenAnswer(
      (_) async => const [
        TerminalFileEntry(
          name: 'new.txt',
          path: '/workspace/new.txt',
          isDirectory: false,
        ),
      ],
    );
    when(() => service.getListeningPorts(server, sessionScopeId: 'scope'))
        .thenAnswer((_) async => const []);

    // A reload of the old path is still waiting when the context picks its
    // own path and lists that.
    final reload = harness.browser.reload();
    await harness.browser.loadDirectory(
      service,
      server,
      path: '/workspace/',
      updateServerCwd: false,
    );
    oldListing.complete(const [
      TerminalFileEntry(
        name: 'old.txt',
        path: '/old/old.txt',
        isDirectory: false,
      ),
    ]);
    await reload;

    check(gateway.currentPath).equals('/workspace/');
    check(gateway.entries.single.name).equals('new.txt');
    check(harness.browser.loadingFiles).isFalse();
  });

  for (final reloadAnswersFirst in [true, false]) {
    test(
      'a reload does not discard a folder being opened '
      '(${reloadAnswersFirst ? 'reload answers first' : 'folder answers first'})',
      () async {
        final service = _MockTerminalService();
        final gateway = _FakeTerminalGateway(service: service)
          ..selectedTerminalId = server.selectionId
          ..selectedServer = server
          ..currentPath = '/old/'
          ..sessionScopeId = 'scope';
        final harness = _TerminalControllerHarness(gateway);
        addTearDown(harness.dispose);
        final folderListing = Completer<List<TerminalFileEntry>>();
        final reloadListing = Completer<List<TerminalFileEntry>>();
        when(
          () => service.listFiles(server, '/folder/', sessionScopeId: 'scope'),
        ).thenAnswer((_) => folderListing.future);
        when(() => service.listFiles(server, '/old/', sessionScopeId: 'scope'))
            .thenAnswer((_) => reloadListing.future);
        when(() => service.getListeningPorts(server, sessionScopeId: 'scope'))
            .thenAnswer((_) async => const []);
        const folderEntries = [
          TerminalFileEntry(
            name: 'inside.txt',
            path: '/folder/inside.txt',
            isDirectory: false,
          ),
        ];
        const oldEntries = [
          TerminalFileEntry(
            name: 'outside.txt',
            path: '/old/outside.txt',
            isDirectory: false,
          ),
        ];

        // The user opens a folder, switches to Console and back before it has
        // answered, and the Files panel reloads the path that is still current.
        final navigation = harness.browser.loadDirectory(
          service,
          server,
          path: '/folder/',
          updateServerCwd: false,
        );
        final reload = harness.browser.reload();
        if (reloadAnswersFirst) {
          reloadListing.complete(oldEntries);
          await reload;
          folderListing.complete(folderEntries);
          await navigation;
        } else {
          folderListing.complete(folderEntries);
          await navigation;
          reloadListing.complete(oldEntries);
          await reload;
        }

        check(gateway.currentPath).equals('/folder/');
        check(gateway.entries.single.name).equals('inside.txt');
        check(harness.browser.loadingFiles).isFalse();
      },
    );
  }

  test(
    'a listing for a replaced server does not cancel the current one',
    () async {
      final service = _MockTerminalService();
      final gateway = _FakeTerminalGateway(service: service)
        ..selectedTerminalId = server.selectionId
        ..selectedServer = server
        ..currentPath = '/workspace/'
        ..sessionScopeId = 'scope';
      final harness = _TerminalControllerHarness(gateway);
      addTearDown(harness.dispose);
      final currentListing = Completer<List<TerminalFileEntry>>();
      when(
        () => service.listFiles(server, '/workspace/', sessionScopeId: 'scope'),
      ).thenAnswer((_) => currentListing.future);

      final current = harness.browser.loadDirectory(
        service,
        server,
        path: '/workspace/',
        updateServerCwd: false,
      );
      await harness.browser.loadDirectory(
        service,
        replacementServer,
        path: '/replacement/',
        updateServerCwd: false,
      );
      currentListing.complete(const [
        TerminalFileEntry(
          name: 'README.md',
          path: '/workspace/README.md',
          isDirectory: false,
        ),
      ]);
      await current;

      check(gateway.entries.single.name).equals('README.md');
      check(harness.browser.loadingFiles).isFalse();
    },
  );

  test(
    'overlapping reloads publish in the order they were requested',
    () async {
      final service = _MockTerminalService();
      final gateway = _FakeTerminalGateway(service: service)
        ..selectedTerminalId = server.selectionId
        ..selectedServer = server
        ..currentPath = '/workspace/'
        ..sessionScopeId = 'scope';
      final harness = _TerminalControllerHarness(gateway);
      addTearDown(harness.dispose);
      final listings = [
        Completer<List<TerminalFileEntry>>(),
        Completer<List<TerminalFileEntry>>(),
      ];
      var requested = 0;
      when(
        () => service.listFiles(server, '/workspace/', sessionScopeId: 'scope'),
      ).thenAnswer((_) => listings[requested++].future);
      when(() => service.getListeningPorts(server, sessionScopeId: 'scope'))
          .thenAnswer((_) async => const []);

      // Creating a folder refreshes the listing and then reloads it again.
      final first = harness.browser.reload();
      final second = harness.browser.reload();
      listings[1].complete(const [
        TerminalFileEntry(
          name: 'new-folder',
          path: '/workspace/new-folder',
          isDirectory: true,
        ),
      ]);
      await second;
      listings[0].complete(const <TerminalFileEntry>[]);
      await first;

      check(gateway.entries.single.name).equals('new-folder');
      check(harness.browser.loadingFiles).isFalse();
    },
  );

  group('live updates', () {
    final direct = TerminalServerInfo(
      kind: TerminalServerKind.direct,
      selectionId: 'https://direct.test',
      baseUrl: Uri.parse('https://direct.test'),
      apiKey: 'key',
    );

    _TerminalControllerHarness syncedHarness(
      _MockTerminalService service,
      TerminalServerInfo target, {
      TerminalServerFeatures features = const TerminalServerFeatures(
        events: true,
      ),
      bool relayed = false,
      List<List<TerminalFileEntry>>? listings,
    }) {
      final gateway = _FakeTerminalGateway(service: service)
        ..selectedTerminalId = target.selectionId
        ..selectedServer = target
        ..systemTerminalLiveFeatures = relayed;
      final queue = [...?listings];
      when(() => service.getFeatures(target, sessionScopeId: 'scope'))
          .thenAnswer((_) async => features);
      when(() => service.getCwd(target, sessionScopeId: 'scope'))
          .thenAnswer((_) async => '/workspace');
      when(
        () => service.listFiles(
          target,
          any(),
          sessionScopeId: 'scope',
        ),
      ).thenAnswer(
        (_) async =>
            queue.length > 1 ? queue.removeAt(0) : [...?queue.firstOrNull],
      );
      when(() => service.getListeningPorts(target, sessionScopeId: 'scope'))
          .thenAnswer((_) async => const [TerminalListeningPort(port: 8080)]);
      when(() => service.authTokenForServer(target)).thenReturn('token');
      when(
        () => service.buildEventsWebSocketUri(target),
      ).thenReturn(Uri.parse('wss://events.test/${target.kind.name}'));
      final harness = _TerminalControllerHarness(gateway);
      addTearDown(harness.dispose);
      return harness;
    }

    test('a terminal that reports events is watched after it loads', () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(service, direct);

      await harness.context.sync(force: true);
      await pumpEventQueue();

      // Files and ports each get a socket, as in the web client.
      final gateway = harness.gateway;
      check(gateway.openedChannels).length.equals(2);
      for (final opened in gateway.openedChannels) {
        check(opened.uri).equals(Uri.parse('wss://events.test/direct'));
        check(opened.kind).equals(TerminalServerKind.direct);
      }
      check(gateway.channels.first.decodedSent).deepEquals([
        {'type': 'auth', 'token': 'token'},
        {'type': 'subscribe', 'path': '/workspace/'},
      ]);
      check(gateway.channels.last.decodedSent).deepEquals([
        {'type': 'auth', 'token': 'token'},
        {'type': 'subscribe', 'ports': true},
      ]);
      check(harness.browser.liveUpdates).isTrue();
    });

    test('a terminal without events is refreshed on demand only', () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(
        service,
        direct,
        features: const TerminalServerFeatures(),
      );

      await harness.context.sync(force: true);
      await pumpEventQueue();

      check(harness.gateway.openedChannels).isEmpty();
      check(harness.browser.liveUpdates).isFalse();
    });

    test('Open WebUI terminals are watched where it relays events', () async {
      for (final relayed in [false, true]) {
        final service = _MockTerminalService();
        final harness = syncedHarness(service, server, relayed: relayed);

        await harness.context.sync(force: true);
        await pumpEventQueue();

        check(
          harness.gateway.openedChannels,
          because: 'relayed: $relayed',
        ).length.equals(relayed ? 2 : 0);
        harness.dispose();
      }
    });

    test('Open WebUI terminals are watched once it says it relays them',
        () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(service, server);
      await harness.context.sync(force: true);
      await pumpEventQueue();
      // The terminal loaded before Open WebUI's version was known.
      check(harness.gateway.openedChannels).isEmpty();

      harness.gateway.systemTerminalLiveFeatures = true;
      harness.browser.liveFeaturesChanged();
      await pumpEventQueue();

      check(harness.gateway.openedChannels).length.equals(2);
      check(harness.browser.liveUpdates).isTrue();
      // Only the watches start; the terminal is not loaded again.
      verify(
        () => service.getFeatures(server, sessionScopeId: 'scope'),
      ).called(1);

      harness.gateway.systemTerminalLiveFeatures = false;
      harness.browser.liveFeaturesChanged();
      await pumpEventQueue();
      check(harness.gateway.channels.first.sinkClosed).isTrue();
      check(harness.browser.liveUpdates).isFalse();
    });

    test('a terminal still loading starts its own watches', () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(service, server);
      harness.gateway.systemTerminalLiveFeatures = true;

      harness.browser.liveFeaturesChanged();
      await pumpEventQueue();

      check(harness.gateway.openedChannels).isEmpty();
    });

    test('a change lists the directory again without a spinner', () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(
        service,
        direct,
        listings: [
          const [],
          const [
            TerminalFileEntry(
              name: 'made-by-agent.txt',
              path: '/workspace/made-by-agent.txt',
              isDirectory: false,
            ),
          ],
        ],
      );
      await harness.context.sync(force: true);
      await pumpEventQueue();
      check(harness.gateway.entries).isEmpty();
      var spinnerShown = false;
      harness.browser.addListener(() {
        spinnerShown = spinnerShown || harness.browser.loadingFiles;
      });

      harness.gateway.channels.first.receive({'type': 'fs:change'});
      await pumpEventQueue();

      check(harness.gateway.entries.single.name).equals('made-by-agent.txt');
      check(spinnerShown).isFalse();
      verify(
        () => service.listFiles(direct, '/workspace/', sessionScopeId: 'scope'),
      ).called(2);
    });

    test('changes during a listing list once more after it', () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(service, direct);
      await harness.context.sync(force: true);
      await pumpEventQueue();
      final listing = Completer<List<TerminalFileEntry>>();
      when(
        () => service.listFiles(direct, '/workspace/', sessionScopeId: 'scope'),
      ).thenAnswer((_) => listing.future);

      final channel = harness.gateway.channels.first;
      channel
        ..receive({'type': 'fs:change'})
        ..receive({'type': 'fs:change'})
        ..receive({'type': 'fs:change'});
      await pumpEventQueue();
      // One listing is under way; the changes after it are owed one more.
      verify(
        () => service.listFiles(direct, '/workspace/', sessionScopeId: 'scope'),
      ).called(2);

      when(
        () => service.listFiles(direct, '/workspace/', sessionScopeId: 'scope'),
      ).thenAnswer((_) async => const []);
      listing.complete(const []);
      await pumpEventQueue();
      verify(
        () => service.listFiles(direct, '/workspace/', sessionScopeId: 'scope'),
      ).called(1);
    });

    test('a listing left waiting does not hold up the next terminal', () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(service, direct);
      await harness.context.sync(force: true);
      await pumpEventQueue();
      final stalled = Completer<List<TerminalFileEntry>>();
      when(
        () => service.listFiles(direct, '/workspace/', sessionScopeId: 'scope'),
      ).thenAnswer((_) => stalled.future);
      harness.gateway.channels.first.receive({'type': 'fs:change'});
      await pumpEventQueue();

      // The user moves to another terminal while that listing waits.
      final other = TerminalServerInfo(
        kind: TerminalServerKind.direct,
        selectionId: 'https://other.test',
        baseUrl: Uri.parse('https://other.test'),
      );
      var otherListings = 0;
      when(() => service.getFeatures(other, sessionScopeId: 'scope'))
          .thenAnswer((_) async => const TerminalServerFeatures(events: true));
      when(() => service.getCwd(other, sessionScopeId: 'scope'))
          .thenAnswer((_) async => '/home');
      when(() => service.listFiles(other, '/home/', sessionScopeId: 'scope'))
          .thenAnswer((_) async {
            otherListings++;
            return const [];
          });
      when(() => service.getListeningPorts(other, sessionScopeId: 'scope'))
          .thenAnswer((_) async => const []);
      when(() => service.authTokenForServer(other)).thenReturn(null);
      when(
        () => service.buildEventsWebSocketUri(other),
      ).thenReturn(Uri.parse('wss://other.test/events'));
      harness.gateway
        ..selectedTerminalId = other.selectionId
        ..selectedServer = other;
      await harness.context.sync(force: true);
      await pumpEventQueue();
      check(otherListings).equals(1);

      harness.gateway.channels[2].receive({'type': 'fs:change'});
      await pumpEventQueue();

      check(otherListings).equals(2);
      stalled.complete(const []);
      await pumpEventQueue();
      check(otherListings).equals(2);
    });

    test('reported ports replace the list', () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(service, direct);
      await harness.context.sync(force: true);
      await pumpEventQueue();
      check(harness.gateway.ports.single.port).equals(8080);

      harness.gateway.channels.last.receive({
        'type': 'ports:change',
        'ports': [
          {'port': 5173, 'process': 'vite'},
        ],
      });
      await pumpEventQueue();

      check(harness.gateway.ports.single.port).equals(5173);
      check(harness.gateway.ports.single.process).equals('vite');
    });

    test('a refresh that started before pushed ports does not undo them', () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(service, direct);
      await harness.context.sync(force: true);
      await pumpEventQueue();
      final fetch = Completer<List<TerminalListeningPort>>();
      when(
        () => service.getListeningPorts(direct, sessionScopeId: 'scope'),
      ).thenAnswer((_) => fetch.future);

      final refresh = harness.browser.loadPorts(service, direct);
      harness.gateway.channels.last.receive({
        'type': 'ports:change',
        'ports': [
          {'port': 5173, 'process': 'vite'},
        ],
      });
      await pumpEventQueue();
      fetch.complete(const []);
      await refresh;

      check(harness.gateway.ports.single.port).equals(5173);
    });

    test('a directory that cannot be watched leaves the ports live', () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(service, direct);
      await harness.context.sync(force: true);
      await pumpEventQueue();

      // Too many files for the terminal's watch limit: it gives up at once.
      harness.gateway.channels.first.closeFromServer(1011);
      await pumpEventQueue();
      harness.gateway.channels.last.receive({
        'type': 'ports:change',
        'ports': [
          {'port': 5173, 'process': 'vite'},
        ],
      });
      await pumpEventQueue();

      check(harness.gateway.ports.single.port).equals(5173);
      check(harness.browser.liveUpdates).isTrue();
    });

    test('opening a folder moves the watch there', () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(service, direct);
      when(
        () => service.setCwd(direct, any(), sessionScopeId: 'scope'),
      ).thenAnswer((_) async {});
      await harness.context.sync(force: true);
      await pumpEventQueue();

      await harness.browser.navigateTo('/workspace/src');
      await pumpEventQueue();

      check(harness.gateway.channels.first.decodedSent.last).isA<Map>()
          .deepEquals({'type': 'subscribe', 'path': '/workspace/src/'});
      // The ports socket watches no directory.
      check(harness.gateway.channels.last.decodedSent).length.equals(2);
    });

    test('leaving the tab closes the socket', () async {
      final service = _MockTerminalService();
      final harness = syncedHarness(service, direct);
      await harness.context.sync(force: true);
      await pumpEventQueue();

      await harness.context.deactivate();

      check(harness.gateway.channels.first.sinkClosed).isTrue();
      check(harness.gateway.channels.last.sinkClosed).isTrue();
      check(harness.browser.liveUpdates).isFalse();
    });
  });

  group('port previews', () {
    final direct = TerminalServerInfo(
      kind: TerminalServerKind.direct,
      selectionId: 'https://direct.test',
      baseUrl: Uri.parse('https://direct.test'),
      apiKey: 'key',
    );
    const session = TerminalBrowserSession(id: 'sid', token: 'tok');

    Future<TerminalPortPreview> openPreview(
      TerminalServerInfo target, {
      required TerminalServerFeatures features,
      bool relayed = false,
    }) async {
      final service = _MockTerminalService();
      final gateway = _FakeTerminalGateway(service: service)
        ..selectedTerminalId = target.selectionId
        ..selectedServer = target
        ..systemTerminalLiveFeatures = relayed;
      when(
        () => service.authTokenForServer(target),
      ).thenReturn(target.isSystem ? 'jwt' : target.apiKey);
      when(
        () => service.createBrowserSession(
          target,
          url: any(named: 'url'),
          sessionScopeId: any(named: 'sessionScopeId'),
        ),
      ).thenAnswer((_) async => session);
      when(
        () => service.closeBrowserSession(
          target,
          any(),
          sessionScopeId: any(named: 'sessionScopeId'),
        ),
      ).thenAnswer((_) async {});
      final harness = _TerminalControllerHarness(gateway);
      addTearDown(harness.dispose);
      harness.browser.setFeatures(target, 'scope', features);

      await harness.browser.openPort(const TerminalListeningPort(port: 5173));

      final preview = harness.platform.previews.single;
      if (preview.openSession != null) {
        check(await preview.openSession!()).identicalTo(session);
        verify(
          () => service.createBrowserSession(
            target,
            url: 'http://localhost:5173/',
            sessionScopeId: 'scope',
          ),
        ).called(1);
        await preview.closeSession!(session);
        verify(
          () => service.closeBrowserSession(
            target,
            'sid',
            sessionScopeId: 'scope',
          ),
        ).called(1);
      }
      return preview;
    }

    test('a terminal with browser sessions previews through one', () async {
      final preview = await openPreview(
        direct,
        features: const TerminalServerFeatures(browser: true),
      );

      check(preview.port).equals(5173);
      check(preview.terminalBaseUri).equals(direct.baseUrl);
      check(preview.openSession).isNotNull();
      // A direct terminal's key never goes with a session's pages.
      check(preview.sessionNavigator(session).headers).isEmpty();
    });

    test('a terminal without them previews through the proxy', () async {
      final preview = await openPreview(
        direct,
        features: const TerminalServerFeatures(events: true),
      );

      check(preview.openSession).isNull();
      check(preview.closeSession).isNull();
      // Open Terminal's proxy needs the key, which goes with the page loads
      // the app makes, as Open WebUI's token does for its own terminals.
      check(preview.bearerToken).equals('key');
      check(
        preview.proxyNavigator().headers,
      ).deepEquals({'Authorization': 'Bearer key'});
    });

    test('a session closes through the account\'s current client', () async {
      _MockTerminalService serviceFor(String serverConfigId) {
        final api = _MockApiService();
        when(() => api.serverConfig).thenReturn(
          ServerConfig(
            id: serverConfigId,
            name: serverConfigId,
            url: 'https://$serverConfigId.test',
          ),
        );
        final service = _MockTerminalService();
        when(() => service.api).thenReturn(api);
        when(() => service.authTokenForServer(server)).thenReturn('jwt');
        when(
          () => service.closeBrowserSession(
            server,
            any(),
            sessionScopeId: any(named: 'sessionScopeId'),
          ),
        ).thenAnswer((_) async {});
        return service;
      }

      final opener = serviceFor('owui');
      final gateway = _FakeTerminalGateway(service: opener)
        ..selectedTerminalId = server.selectionId
        ..selectedServer = server
        ..systemTerminalLiveFeatures = true;
      final harness = _TerminalControllerHarness(gateway);
      addTearDown(harness.dispose);
      harness.browser.setFeatures(
        server,
        'scope',
        const TerminalServerFeatures(browser: true),
      );
      await harness.browser.openPort(const TerminalListeningPort(port: 5173));
      final preview = harness.platform.previews.single;

      // A silent sign-in replaced, and closed, the client that opened it.
      final signedInAgain = serviceFor('owui');
      gateway.service = signedInAgain;
      await preview.closeSession!(session);
      verify(
        () => signedInAgain.closeBrowserSession(
          server,
          'sid',
          sessionScopeId: 'scope',
        ),
      ).called(1);
      verifyNever(
        () => opener.closeBrowserSession(
          server,
          any(),
          sessionScopeId: any(named: 'sessionScopeId'),
        ),
      );

      // Another server's client never hears of it.
      final elsewhere = serviceFor('elsewhere');
      gateway.service = elsewhere;
      await preview.closeSession!(session);
      verify(
        () => opener.closeBrowserSession(server, 'sid', sessionScopeId: 'scope'),
      ).called(1);
      verifyNever(
        () => elsewhere.closeBrowserSession(
          server,
          any(),
          sessionScopeId: any(named: 'sessionScopeId'),
        ),
      );
    });

    test('Open WebUI terminals use sessions only where it relays them',
        () async {
      final older = await openPreview(
        server,
        features: const TerminalServerFeatures(browser: true),
      );
      check(older.openSession).isNull();
      check(older.bearerToken).equals('jwt');

      final current = await openPreview(
        server,
        features: const TerminalServerFeatures(browser: true),
        relayed: true,
      );
      check(current.openSession).isNotNull();
      check(current.bearerToken).equals('jwt');
    });
  });
}

final class _TerminalControllerHarness {
  _TerminalControllerHarness(this.gateway) {
    bool isCurrentContext(TerminalServerInfo server, String scope) =>
        gateway.isActive &&
        gateway.selectedServer?.selectionId == server.selectionId &&
        gateway.sessionScopeId == scope;
    session = TerminalSessionController(
      gateway: gateway,
      isCurrentContext: isCurrentContext,
      screen: screen,
    );
    browser = TerminalBrowserController(
      gateway: gateway,
      platformGateway: platform,
      isCurrentContext: isCurrentContext,
      onFailure: (_) {},
    );
    context = TerminalContextController(
      gateway: gateway,
      sessionController: session,
      browserController: browser,
      isCurrentContext: isCurrentContext,
      disconnectedLabel: () => 'Disconnected',
      onFailure: failures.add,
    );
  }

  final _FakeTerminalGateway gateway;
  final _FakeTerminalPlatformGateway platform = _FakeTerminalPlatformGateway();
  final FakeTerminalScreen screen = FakeTerminalScreen();
  final List<TerminalContextFailure> failures = [];
  late final TerminalSessionController session;
  late final TerminalBrowserController browser;
  late final TerminalContextController context;

  void dispose() {
    context.dispose();
    browser.dispose();
    session.dispose();
  }
}

final class _MockTerminalService extends Mock implements TerminalService {}

final class _MockApiService extends Mock implements ApiService {}

final class _FakeTerminalGateway
    implements
        TerminalBrowserGateway,
        TerminalSessionGateway,
        TerminalContextGateway {
  _FakeTerminalGateway({required this.service});

  @override
  bool isActive = true;
  @override
  TerminalService? service;
  @override
  List<TerminalServerInfo> availableServers = const [];
  @override
  String? selectedTerminalId;
  @override
  TerminalServerInfo? selectedServer;
  @override
  String sessionScopeId = 'scope';
  @override
  String currentPath = '/';
  @override
  bool autoConnect = false;
  @override
  bool systemTerminalLiveFeatures = false;
  @override
  TerminalConnectionState connectionState =
      const TerminalConnectionState.disconnected();

  List<TerminalFileEntry> entries = const [];
  List<TerminalListeningPort> ports = const [];
  TerminalSessionInfo? activeSession;
  final List<TerminalServerInfo> selectedServers = [];

  @override
  Future<void> selectServer(TerminalServerInfo server) async {
    selectedServers.add(server);
    selectedTerminalId = server.selectionId;
  }

  @override
  void setCurrentPath(String path) => currentPath = path;

  @override
  void setEntries(List<TerminalFileEntry> value) => entries = value;

  @override
  void setListeningPorts(List<TerminalListeningPort> value) => ports = value;

  @override
  void requestRefresh() {}

  final List<({Uri uri, TerminalServerKind kind})> openedChannels = [];
  final List<FakeEventsChannel> channels = [];

  @override
  WebSocketChannel openChannel(Uri uri, {required TerminalServerKind kind}) {
    openedChannels.add((uri: uri, kind: kind));
    final channel = FakeEventsChannel();
    channels.add(channel);
    return channel;
  }

  @override
  void setActiveSession(TerminalSessionInfo? session) {
    activeSession = session;
  }

  @override
  void setConnectionState(TerminalConnectionState state) {
    connectionState = state;
  }
}

final class _FakeTerminalPlatformGateway
    implements TerminalBrowserPlatformGateway {
  final List<TerminalPortPreview> previews = [];

  @override
  Future<TerminalUploadFile?> pickUploadFile() async => null;

  @override
  Future<void> saveDownload(TerminalDownloadedFile downloaded) async {}

  @override
  Future<bool> openPort(TerminalPortPreview preview) async {
    previews.add(preview);
    return true;
  }
}
