import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import 'package:conduit_core/services/api_service.dart';
import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/providers/terminal_providers.dart';
import 'package:conduit/features/terminal/services/terminal_service.dart';
import 'package:conduit/features/terminal/widgets/terminal_console_surface.dart';
import 'package:conduit/features/terminal/widgets/terminal_tab.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show systemTerminalLiveFeaturesProvider;
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  group('TerminalTab', () {
    testWidgets('PDF cache identity changes for each newly read file', (
      tester,
    ) async {
      final service = _FakeTerminalService(
        servers: [
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://terminal.example',
            baseUrl: Uri.parse('https://terminal.example'),
            name: 'Workspace',
          ),
        ],
        entries: const [],
        ports: const [],
      );
      final container = ProviderContainer(
        overrides: [
          terminalServiceProvider.overrideWithValue(service),
          terminalAutoConnectProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_buildHarnessWithContainer(container));
      await tester.pumpAndSettle();
      PdfDocumentRefKey? previous;
      for (final path in [
        '/first/report.pdf',
        '/second/report.pdf',
        '/second/report.pdf',
      ]) {
        // The cache contract is independent of PDF parsing: each network read
        // has its own bytes, including rewrites of the same file.
        service.readResult = TerminalFileReadResult(
          fileName: 'report.pdf',
          contentType: 'application/pdf',
          bytes: Uint8List.fromList([1, 2, 3]),
        );
        container.read(terminalDisplayFileProvider.notifier).handleEvent(
          'terminal:display_file',
          {'path': path},
        );
        await tester.pumpAndSettle();
        final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
        if (previous != null) expect(viewer.documentRef.key, isNot(previous));
        previous = viewer.documentRef.key;
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('preview survives removal of its terminal tab', (tester) async {
      final service = _FakeTerminalService(
        servers: [
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://terminal.example',
            baseUrl: Uri.parse('https://terminal.example'),
            name: 'Workspace',
          ),
        ],
        entries: const [],
        ports: const [],
      );
      final container = ProviderContainer(
        overrides: [
          terminalServiceProvider.overrideWithValue(service),
          terminalAutoConnectProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_buildHarnessWithContainer(container));
      await tester.pumpAndSettle();
      container.read(terminalDisplayFileProvider.notifier).handleEvent(
        'terminal:display_file',
        {'path': '/report.txt'},
      );
      await tester.pumpAndSettle();
      expect(find.text('print("hello from terminal")'), findsOneWidget);
      await tester.pumpWidget(
        _buildHarnessWithContainer(container, showTab: false),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _buildHarnessWithContainer(
          container,
          showTab: false,
          theme: ThemeData.dark(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('print("hello from terminal")'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('report.txt'), findsNothing);
    });

    testWidgets(
      'tool file display waits for discovery and writes refresh the browser',
      (tester) async {
        final discovery = Completer<void>();
        final service = _FakeTerminalService(
          discovery: discovery.future,
          servers: [
            TerminalServerInfo(
              kind: TerminalServerKind.direct,
              selectionId: 'https://terminal.example',
              baseUrl: Uri.parse('https://terminal.example'),
              name: 'Workspace',
            ),
          ],
          entries: const [],
          ports: const [],
        );
        final container = ProviderContainer(
          overrides: [
            terminalServiceProvider.overrideWithValue(service),
            terminalAutoConnectProvider.overrideWithValue(false),
          ],
        );
        addTearDown(container.dispose);
        final events = container.read(terminalDisplayFileProvider.notifier);
        events.handleEvent('terminal:display_file', {
          'path': '/reports/result.txt',
          'page': 3,
        });
        expect(container.read(terminalDisplayFileProvider)!.page, 3);
        await tester.pumpWidget(
          _buildHarnessWithContainer(container, isActive: false),
        );
        await tester.pump();
        expect(service.readPaths, isEmpty);
        await tester.pumpWidget(_buildHarnessWithContainer(container));
        await tester.pump();
        expect(service.readPaths, isEmpty);
        expect(container.read(terminalDisplayFileProvider), isNotNull);
        discovery.complete();
        await tester.pumpAndSettle();
        expect(container.read(terminalDisplayFileProvider), isNotNull);
        expect(service.readPaths, ['/reports/result.txt']);
        expect(find.text('print("hello from terminal")'), findsOneWidget);
        events.handleEvent('terminal:display_file', {
          'path': '/reports/new.txt',
        });
        await tester.pumpAndSettle();
        expect(find.text('result.txt', skipOffstage: false), findsNothing);
        expect(find.text('new.txt'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(container.read(terminalDisplayFileProvider), isNull);
        expect(
          find.text('print("hello from terminal")', skipOffstage: false),
          findsNothing,
        );
        service.readError = StateError('File unavailable');
        events.handleEvent('terminal:display_file', {
          'path': '/reports/missing.txt',
        });
        await tester.pumpAndSettle();
        expect(container.read(terminalDisplayFileProvider), isNull);
        final attemptedReads = service.readPaths.length;
        for (final type in [
          'terminal:write_file',
          'terminal:replace_file_content',
          'terminal:run_command',
        ]) {
          final count = service.listFilesRequestCount;
          events.handleEvent(type, {'path': '/reports/result.txt'});
          await tester.pumpAndSettle();
          expect(service.listFilesRequestCount, greaterThan(count));
          expect(service.readPaths.length, attemptedReads);
          expect(
            service.listedDirectories.last,
            type == 'terminal:run_command' ? '/' : '/reports/',
          );
        }
      },
    );

    testWidgets('shows an empty state when no terminal servers exist', (
      tester,
    ) async {
      final fakeService = _FakeTerminalService(
        servers: const <TerminalServerInfo>[],
        entries: const <TerminalFileEntry>[],
        ports: const <TerminalListeningPort>[],
      );

      await tester.pumpWidget(_buildHarness(fakeService));
      await tester.pumpAndSettle();

      expect(
        find.text('No terminal servers available.'),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets(
      'defers default panel update when terminal servers are cached',
      (tester) async {
        final fakeService = _FakeTerminalService(
          servers: <TerminalServerInfo>[
            TerminalServerInfo(
              kind: TerminalServerKind.direct,
              selectionId: 'https://terminal.example',
              baseUrl: Uri.parse('https://terminal.example'),
              name: 'Workspace',
            ),
          ],
          entries: const <TerminalFileEntry>[],
          ports: const <TerminalListeningPort>[],
        );
        final container = ProviderContainer(
          overrides: [
            terminalServiceProvider.overrideWithValue(fakeService),
            terminalAutoConnectProvider.overrideWithValue(false),
          ],
        );
        addTearDown(container.dispose);
        await container.read(terminalAvailableServersProvider.future);

        await tester.pumpWidget(_buildHarnessWithContainer(container));
        await tester.pump();

        expect(tester.takeException(), isNull);

        await tester.pumpAndSettle();

        expect(
          container.read(terminalSidebarPanelProvider),
          TerminalSidebarPanel.files,
        );
      },
    );

    testWidgets('waits to sync until the terminal tab becomes active', (
      tester,
    ) async {
      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://terminal.example',
            baseUrl: Uri.parse('https://terminal.example'),
            name: 'Workspace',
          ),
        ],
        entries: const <TerminalFileEntry>[],
        ports: const <TerminalListeningPort>[],
      );
      final isActive = ValueNotifier<bool>(false);
      addTearDown(isActive.dispose);

      await tester.pumpWidget(_buildHarnessWithActivity(fakeService, isActive));
      await tester.pumpAndSettle();

      expect(fakeService.cwdRequestCount, 0);
      expect(fakeService.listFilesRequestCount, 0);
      expect(fakeService.listeningPortsRequestCount, 0);

      isActive.value = true;
      await tester.pump();
      await tester.pumpAndSettle();

      expect(fakeService.cwdRequestCount, 1);
      expect(fakeService.listFilesRequestCount, 1);
      expect(fakeService.listeningPortsRequestCount, 1);
    });

    testWidgets('stale disconnects do not close a newer terminal session', (
      tester,
    ) async {
      final staleDisconnectCancel = Completer<void>();
      final resumedSyncGate = Completer<bool>();
      final firstChannel = _TestWebSocketConnection(
        cancelFuture: staleDisconnectCancel.future,
      );
      final secondChannel = _TestWebSocketConnection();
      addTearDown(() async {
        await firstChannel.dispose();
        await secondChannel.dispose();
      });

      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://terminal.example',
            baseUrl: Uri.parse('https://terminal.example'),
            name: 'Workspace',
          ),
        ],
        entries: const <TerminalFileEntry>[],
        ports: const <TerminalListeningPort>[],
      );
      final isActive = ValueNotifier<bool>(true);
      addTearDown(isActive.dispose);

      var channelConnectCount = 0;
      final channels = <_TestWebSocketConnection>[firstChannel, secondChannel];

      await tester.pumpWidget(
        _buildHarnessWithActivity(
          fakeService,
          isActive,
          channelConnector: (_, {required kind}) {
            expect(kind, TerminalServerKind.direct);
            return channels[channelConnectCount++].channel;
          },
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(TerminalTab)),
      );
      container
          .read(terminalSidebarPanelProvider.notifier)
          .setPanel(TerminalSidebarPanel.console);
      await tester.pump();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(TerminalTab)),
      )!;

      await tester.tap(find.bySemanticsLabel(l10n.terminalConnectAction));
      await tester.pump();
      await tester.pump();

      expect(channelConnectCount, 1);
      expect(
        container.read(terminalConnectionStateProvider).isConnected,
        isTrue,
      );

      fakeService.terminalEnabledCompletersByRequest[fakeService
                  .terminalEnabledRequestCount +
              1] =
          resumedSyncGate;

      isActive.value = false;
      await tester.pump();

      isActive.value = true;
      await tester.pump();

      container.read(terminalActiveSessionProvider.notifier).clear();
      container
          .read(terminalConnectionStateProvider.notifier)
          .set(const TerminalConnectionState.disconnected());
      await tester.pump();

      await tester.tap(find.bySemanticsLabel(l10n.terminalConnectAction));
      await tester.pump();
      await tester.pump();

      expect(channelConnectCount, 2);
      expect(
        container.read(terminalConnectionStateProvider).isConnected,
        isTrue,
      );

      staleDisconnectCancel.complete();
      await tester.pump();

      expect(firstChannel.closeCallCount, 1);
      expect(secondChannel.closeCallCount, 0);
      expect(
        container.read(terminalConnectionStateProvider).isConnected,
        isTrue,
      );

      resumedSyncGate.complete(true);
      await tester.pumpAndSettle();
    });

    testWidgets('loads files and filters them with the shared search field', (
      tester,
    ) async {
      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://terminal.example',
            baseUrl: Uri.parse('https://terminal.example'),
            name: 'Workspace',
          ),
        ],
        entries: const <TerminalFileEntry>[
          TerminalFileEntry(
            name: 'alpha.txt',
            path: '/workspace/alpha.txt',
            isDirectory: false,
            size: 12,
          ),
          TerminalFileEntry(
            name: 'beta.log',
            path: '/workspace/beta.log',
            isDirectory: false,
            size: 24,
          ),
        ],
        ports: const <TerminalListeningPort>[
          TerminalListeningPort(port: 3000, process: 'vite'),
        ],
      );

      await tester.pumpWidget(_buildHarness(fakeService));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(TerminalTab)),
      );
      container
          .read(terminalSidebarPanelProvider.notifier)
          .setPanel(TerminalSidebarPanel.files);
      await tester.pumpAndSettle();

      expect(find.text('alpha.txt'), findsOneWidget);
      expect(find.text('beta.log'), findsOneWidget);

      container.read(sidebarSearchFieldControllerProvider).text = 'beta';
      await tester.pumpAndSettle();

      expect(find.text('alpha.txt'), findsNothing);
      expect(find.text('beta.log'), findsOneWidget);

      container.read(sidebarSearchFieldControllerProvider).clear();
      await tester.pumpAndSettle();
    });

    testWidgets('files panel shows files and terminal panel shows ports', (
      tester,
    ) async {
      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://terminal.example',
            baseUrl: Uri.parse('https://terminal.example'),
            name: 'Workspace',
          ),
        ],
        entries: const <TerminalFileEntry>[
          TerminalFileEntry(
            name: 'alpha.txt',
            path: '/workspace/alpha.txt',
            isDirectory: false,
          ),
        ],
        ports: const <TerminalListeningPort>[
          TerminalListeningPort(port: 3000, process: 'vite'),
        ],
      );

      await tester.pumpWidget(_buildHarness(fakeService));
      await tester.pumpAndSettle();

      expect(find.text('alpha.txt'), findsOneWidget);
      expect(find.text('Listening Ports'), findsNothing);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(TerminalTab)),
      );
      container
          .read(terminalSidebarPanelProvider.notifier)
          .setPanel(TerminalSidebarPanel.console);
      await tester.pumpAndSettle();

      expect(find.text('Listening Ports'), findsOneWidget);
      expect(find.text('alpha.txt'), findsNothing);

      expect(find.text('localhost:3000'), findsNothing);
      await tester.tap(find.text('Listening Ports'));
      await tester.pumpAndSettle();
      expect(find.text('localhost:3000'), findsOneWidget);
    });

    testWidgets('live events refresh the files and ports as they change', (
      tester,
    ) async {
      final entries = <TerminalFileEntry>[
        const TerminalFileEntry(
          name: 'alpha.txt',
          path: '/workspace/alpha.txt',
          isDirectory: false,
        ),
      ];
      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://terminal.example',
            baseUrl: Uri.parse('https://terminal.example'),
            name: 'Workspace',
          ),
        ],
        entries: entries,
        ports: const <TerminalListeningPort>[],
        features: const TerminalServerFeatures(events: true),
      );
      // Files and ports each get a socket, as in the web client.
      final fileEvents = _TestWebSocketConnection();
      final portEvents = _TestWebSocketConnection();
      addTearDown(fileEvents.dispose);
      addTearDown(portEvents.dispose);
      final opened = <Uri>[];

      await tester.pumpWidget(
        _buildHarness(
          fakeService,
          channelConnector: (uri, {required kind}) {
            opened.add(uri);
            return (opened.length == 1 ? fileEvents : portEvents).channel;
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(opened, [
        Uri.parse('wss://terminal.example/events'),
        Uri.parse('wss://terminal.example/events'),
      ]);
      final fileFrames = verify(
        () => fileEvents.sink.add(captureAny()),
      ).captured;
      expect(fileFrames.map((frame) => jsonDecode(frame as String)), [
        {'type': 'auth', 'token': 'terminal-token'},
        {'type': 'subscribe', 'path': '/workspace/'},
      ]);
      final portFrames = verify(
        () => portEvents.sink.add(captureAny()),
      ).captured;
      expect(portFrames.map((frame) => jsonDecode(frame as String)), [
        {'type': 'auth', 'token': 'terminal-token'},
        {'type': 'subscribe', 'ports': true},
      ]);
      final listings = fakeService.listFilesRequestCount;

      // An agent writes a file; nobody pulls to refresh.
      entries.add(
        const TerminalFileEntry(
          name: 'agent-made.txt',
          path: '/workspace/agent-made.txt',
          isDirectory: false,
        ),
      );
      fileEvents._controller.add('{"type":"fs:change"}');
      await tester.pumpAndSettle();
      expect(find.text('agent-made.txt'), findsOneWidget);
      expect(fakeService.listFilesRequestCount, listings + 1);

      portEvents._controller.add(
        jsonEncode({
          'type': 'ports:change',
          'ports': [
            {'port': 5173, 'process': 'vite'},
          ],
        }),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TerminalTab)),
      );
      container
          .read(terminalSidebarPanelProvider.notifier)
          .setPanel(TerminalSidebarPanel.console);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Listening Ports'));
      await tester.pumpAndSettle();
      expect(find.text('localhost:5173'), findsOneWidget);
    });

    testWidgets('an Open WebUI terminal goes live once it relays events', (
      tester,
    ) async {
      final relays = ValueNotifier<bool>(false);
      addTearDown(relays.dispose);
      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.system,
            selectionId: 'system:t1',
            systemServerId: 't1',
            baseUrl: Uri.parse('https://owui.example/api/v1/terminals/t1'),
            name: 'Workspace',
          ),
        ],
        entries: const <TerminalFileEntry>[],
        ports: const <TerminalListeningPort>[],
        features: const TerminalServerFeatures(events: true),
      );
      final sockets = [_TestWebSocketConnection(), _TestWebSocketConnection()];
      for (final socket in sockets) {
        addTearDown(socket.dispose);
      }
      final opened = <Uri>[];

      await tester.pumpWidget(
        _buildHarness(
          fakeService,
          liveFeatures: relays,
          channelConnector: (uri, {required kind}) {
            opened.add(uri);
            return sockets[opened.length - 1].channel;
          },
        ),
      );
      await tester.pumpAndSettle();
      // Open WebUI's version was not known when the terminal loaded.
      expect(opened, isEmpty);
      final loads = fakeService.terminalEnabledRequestCount;

      relays.value = true;
      await tester.pumpAndSettle();

      expect(opened, [
        Uri.parse('wss://owui.example/api/v1/terminals/t1/events'),
        Uri.parse('wss://owui.example/api/v1/terminals/t1/events'),
      ]);
      // Only the watches start: the terminal is not loaded again, which
      // would also reconnect its console.
      expect(fakeService.terminalEnabledRequestCount, loads);
    });

    testWidgets('a new account token reopens the event sockets with it', (
      tester,
    ) async {
      // A token change replaces the account's client, and so the terminal
      // service: the terminal loads again and its watchers start afresh,
      // so none reconnects with the token it started with.
      TerminalServerInfo system() => TerminalServerInfo(
        kind: TerminalServerKind.system,
        selectionId: 'system:t1',
        systemServerId: 't1',
        baseUrl: Uri.parse('https://owui.example/api/v1/terminals/t1'),
        name: 'Workspace',
      );
      _FakeTerminalService serviceWith(String token) => _FakeTerminalService(
        servers: <TerminalServerInfo>[system()],
        entries: const <TerminalFileEntry>[],
        ports: const <TerminalListeningPort>[],
        features: const TerminalServerFeatures(events: true),
        token: token,
      );
      final current = ValueNotifier<TerminalService>(serviceWith('old-jwt'));
      addTearDown(current.dispose);
      final sockets = List.generate(4, (_) => _TestWebSocketConnection());
      for (final socket in sockets) {
        addTearDown(socket.dispose);
      }
      var opened = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            terminalServiceProvider.overrideWith((ref) {
              void changed() => ref.invalidateSelf();
              current.addListener(changed);
              ref.onDispose(() => current.removeListener(changed));
              return current.value;
            }),
            terminalAutoConnectProvider.overrideWithValue(false),
            terminalChannelConnectorProvider.overrideWithValue(
              (uri, {required kind}) => sockets[opened++].channel,
            ),
            systemTerminalLiveFeaturesProvider.overrideWithValue(true),
          ],
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: TerminalTab(isActive: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(opened, 2);

      // A silent sign-in.
      current.value = serviceWith('new-jwt');
      await tester.pumpAndSettle();

      expect(opened, 4);
      expect(sockets[0].closeCallCount, 1);
      expect(sockets[1].closeCallCount, 1);
      for (final socket in sockets.skip(2)) {
        final frames = verify(() => socket.sink.add(captureAny())).captured;
        expect(jsonDecode(frames.first as String), {
          'type': 'auth',
          'token': 'new-jwt',
        });
      }
    });

    testWidgets('returning to the files panel lists files made meanwhile', (
      tester,
    ) async {
      final entries = <TerminalFileEntry>[
        const TerminalFileEntry(
          name: 'alpha.txt',
          path: '/workspace/alpha.txt',
          isDirectory: false,
        ),
      ];
      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://terminal.example',
            baseUrl: Uri.parse('https://terminal.example'),
            name: 'Workspace',
          ),
        ],
        entries: entries,
        ports: const <TerminalListeningPort>[],
      );

      await tester.pumpWidget(_buildHarness(fakeService));
      await tester.pumpAndSettle();
      expect(find.text('alpha.txt'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(TerminalTab)),
      );
      final panel = container.read(terminalSidebarPanelProvider.notifier);
      panel.setPanel(TerminalSidebarPanel.console);
      await tester.pumpAndSettle();

      // The shell creates a file while the console is shown.
      entries.add(
        const TerminalFileEntry(
          name: 'pty-made.txt',
          path: '/workspace/pty-made.txt',
          isDirectory: false,
        ),
      );
      panel.setPanel(TerminalSidebarPanel.files);
      await tester.pumpAndSettle();

      expect(find.text('pty-made.txt'), findsOneWidget);
    });

    testWidgets('the inline console sits above the keyboard', (tester) async {
      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://terminal.example',
            baseUrl: Uri.parse('https://terminal.example'),
            name: 'Workspace',
          ),
        ],
        entries: const <TerminalFileEntry>[],
        ports: const <TerminalListeningPort>[],
      );

      // The sidebar does not resize for the keyboard (its tab bar stays put).
      await tester.pumpWidget(
        _buildHarness(fakeService, resizeToAvoidBottomInset: false),
      );
      await tester.pumpAndSettle();
      ProviderScope.containerOf(tester.element(find.byType(TerminalTab)))
          .read(terminalSidebarPanelProvider.notifier)
          .setPanel(TerminalSidebarPanel.console);
      await tester.pumpAndSettle();

      const keyboardHeight = 300.0;
      final dpr = tester.view.devicePixelRatio;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight * dpr);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      final screenHeight = tester.view.physicalSize.height / dpr;
      final console = tester.getRect(find.byType(TerminalConsoleSurface));
      expect(console.bottom, lessThanOrEqualTo(screenHeight - keyboardHeight));
    });

    testWidgets('a resizing sidebar lifts the inline console only once', (
      tester,
    ) async {
      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://terminal.example',
            baseUrl: Uri.parse('https://terminal.example'),
            name: 'Workspace',
          ),
        ],
        entries: const <TerminalFileEntry>[],
        ports: const <TerminalListeningPort>[],
      );

      // The scaffold shrinks its body for the keyboard and removes the inset
      // from the body's media query, so the console must not lift again.
      await tester.pumpWidget(_buildHarness(fakeService));
      await tester.pumpAndSettle();
      ProviderScope.containerOf(tester.element(find.byType(TerminalTab)))
          .read(terminalSidebarPanelProvider.notifier)
          .setPanel(TerminalSidebarPanel.console);
      await tester.pumpAndSettle();
      final restingBottom = tester
          .getRect(find.byType(TerminalConsoleSurface))
          .bottom;

      const keyboardHeight = 300.0;
      final dpr = tester.view.devicePixelRatio;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight * dpr);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      final console = tester.getRect(find.byType(TerminalConsoleSurface));
      expect(restingBottom - console.bottom, keyboardHeight);
    });

    testWidgets('ignores stale file loads after switching terminal servers', (
      tester,
    ) async {
      final staleListCompleter = Completer<List<TerminalFileEntry>>();
      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://one.example',
            baseUrl: Uri.parse('https://one.example'),
            name: 'One',
          ),
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://two.example',
            baseUrl: Uri.parse('https://two.example'),
            name: 'Two',
          ),
        ],
        entries: const <TerminalFileEntry>[],
        entriesByServer: const <String, List<TerminalFileEntry>>{
          'https://two.example': <TerminalFileEntry>[
            TerminalFileEntry(
              name: 'current.txt',
              path: '/workspace/current.txt',
              isDirectory: false,
            ),
          ],
        },
        listFileCompleters: <String, Completer<List<TerminalFileEntry>>>{
          'https://one.example': staleListCompleter,
        },
        ports: const <TerminalListeningPort>[],
      );

      await tester.pumpWidget(_buildHarness(fakeService));
      await tester.pump();
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(TerminalTab)),
      );
      await container
          .read(terminalSelectionControllerProvider)
          .select(fakeService.servers[1]);
      await tester.pumpAndSettle();

      expect(
        container.read(terminalEntriesProvider).single.displayName,
        'current.txt',
      );

      staleListCompleter.complete(const <TerminalFileEntry>[
        TerminalFileEntry(
          name: 'stale.txt',
          path: '/workspace/stale.txt',
          isDirectory: false,
        ),
      ]);
      await tester.pumpAndSettle();

      expect(
        container.read(terminalEntriesProvider).single.displayName,
        'current.txt',
      );
    });

    testWidgets('server picker updates the selected terminal id', (
      tester,
    ) async {
      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://one.example',
            baseUrl: Uri.parse('https://one.example'),
            name: 'One',
          ),
          TerminalServerInfo(
            kind: TerminalServerKind.system,
            selectionId: 'system-2',
            systemServerId: 'system-2',
            baseUrl: Uri.parse('https://example.com/api/v1/terminals/system-2'),
            name: 'Two',
          ),
        ],
        entries: const <TerminalFileEntry>[],
        ports: const <TerminalListeningPort>[],
      );

      await tester.pumpWidget(_buildHarness(fakeService));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(TerminalTab)),
      );
      expect(container.read(selectedTerminalIdProvider), 'https://one.example');

      await container
          .read(terminalSelectionControllerProvider)
          .select(fakeService.servers[1]);
      await tester.pumpAndSettle();

      expect(container.read(selectedTerminalIdProvider), 'system-2');
    });

    testWidgets('sanitizes malformed terminal metadata before rendering', (
      tester,
    ) async {
      final badServerName = 'broken${String.fromCharCode(0xD800)}server';
      final badFileName = 'bad${String.fromCharCode(0xDC00)}.txt';
      final fakeService = _FakeTerminalService(
        servers: <TerminalServerInfo>[
          TerminalServerInfo(
            kind: TerminalServerKind.direct,
            selectionId: 'https://terminal.example',
            baseUrl: Uri.parse('https://terminal.example'),
            name: badServerName,
          ),
        ],
        entries: <TerminalFileEntry>[
          TerminalFileEntry(
            name: badFileName,
            path: '/workspace/$badFileName',
            isDirectory: false,
          ),
        ],
        ports: const <TerminalListeningPort>[],
      );

      await tester.pumpWidget(_buildHarness(fakeService));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(TerminalTab)),
      );
      container
          .read(terminalSidebarPanelProvider.notifier)
          .setPanel(TerminalSidebarPanel.files);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('bad'), findsOneWidget);
    });
  });
}

Widget _buildHarness(
  _FakeTerminalService service, {
  bool isActive = true,
  bool autoConnect = false,
  TerminalChannelConnector? channelConnector,
  bool resizeToAvoidBottomInset = true,
  ValueNotifier<bool>? liveFeatures,
}) {
  return ProviderScope(
    overrides: [
      terminalServiceProvider.overrideWithValue(service),
      terminalAutoConnectProvider.overrideWithValue(autoConnect),
      if (channelConnector != null)
        terminalChannelConnectorProvider.overrideWithValue(channelConnector),
      if (liveFeatures != null)
        systemTerminalLiveFeaturesProvider.overrideWith((ref) {
          void changed() => ref.invalidateSelf();
          liveFeatures.addListener(changed);
          ref.onDispose(() => liveFeatures.removeListener(changed));
          return liveFeatures.value;
        }),
    ],
    child: MaterialApp(
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        body: TerminalTab(isActive: isActive),
      ),
    ),
  );
}

Widget _buildHarnessWithActivity(
  _FakeTerminalService service,
  ValueNotifier<bool> isActive, {
  bool autoConnect = false,
  TerminalChannelConnector? channelConnector,
}) {
  return ProviderScope(
    overrides: [
      terminalServiceProvider.overrideWithValue(service),
      terminalAutoConnectProvider.overrideWithValue(autoConnect),
      if (channelConnector != null)
        terminalChannelConnectorProvider.overrideWithValue(channelConnector),
    ],
    child: MaterialApp(
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ValueListenableBuilder<bool>(
        valueListenable: isActive,
        builder: (context, value, _) {
          return Scaffold(body: TerminalTab(isActive: value));
        },
      ),
    ),
  );
}

Widget _buildHarnessWithContainer(
  ProviderContainer container, {
  bool isActive = true,
  bool showTab = true,
  ThemeData? theme,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: theme,
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: showTab ? TerminalTab(isActive: isActive) : const SizedBox(),
      ),
    ),
  );
}

class _MockApiService extends Mock implements ApiService {}

class _FakeTerminalService extends TerminalService {
  _FakeTerminalService({
    this.discovery,
    required this.servers,
    required this.entries,
    required this.ports,
    this.entriesByServer = const <String, List<TerminalFileEntry>>{},
    this.listFileCompleters =
        const <String, Completer<List<TerminalFileEntry>>>{},
    Map<int, Completer<bool>> terminalEnabledCompletersByRequest =
        const <int, Completer<bool>>{},
    this.features = const TerminalServerFeatures(),
    this.token = 'terminal-token',
  }) : terminalEnabledCompletersByRequest = Map<int, Completer<bool>>.from(
         terminalEnabledCompletersByRequest,
       ),
       super(_MockApiService());

  final Future<void>? discovery;
  final List<TerminalServerInfo> servers;
  final List<TerminalFileEntry> entries;
  final List<TerminalListeningPort> ports;
  final Map<String, List<TerminalFileEntry>> entriesByServer;
  final Map<String, Completer<List<TerminalFileEntry>>> listFileCompleters;
  final Map<int, Completer<bool>> terminalEnabledCompletersByRequest;
  final TerminalServerFeatures features;
  final String token;
  final List<String> readPaths = <String>[];
  Object? readError;
  TerminalFileReadResult? readResult;
  final List<String> listedDirectories = [];
  int cwdRequestCount = 0;
  int listFilesRequestCount = 0;
  int listeningPortsRequestCount = 0;
  int terminalEnabledRequestCount = 0;
  int createSessionRequestCount = 0;

  @override
  Future<List<TerminalServerInfo>> getAvailableServers() async {
    await discovery;
    return servers;
  }

  @override
  Future<Map<String, dynamic>> updateDirectTerminalSelection(
    String? selectedSelectionId,
  ) async {
    return <String, dynamic>{};
  }

  @override
  Future<TerminalServerFeatures> getFeatures(
    TerminalServerInfo server, {
    String? sessionScopeId,
  }) async {
    terminalEnabledRequestCount++;
    final completer =
        terminalEnabledCompletersByRequest[terminalEnabledRequestCount];
    if (completer != null) {
      return TerminalServerFeatures(terminal: await completer.future);
    }
    return features;
  }

  @override
  Future<TerminalSessionInfo> createSession(
    TerminalServerInfo server, {
    required String sessionScopeId,
  }) async {
    createSessionRequestCount++;
    return TerminalSessionInfo(
      serverSelectionId: server.selectionId,
      sessionId: 'session-$createSessionRequestCount',
      sessionScopeId: sessionScopeId,
    );
  }

  @override
  String? authTokenForServer(TerminalServerInfo server) => token;

  @override
  Uri buildEventsWebSocketUri(TerminalServerInfo server) => server.isSystem
      ? Uri.parse(
          'wss://owui.example/api/v1/terminals/${server.systemServerId}/events',
        )
      : super.buildEventsWebSocketUri(server);

  @override
  Future<String?> getCwd(
    TerminalServerInfo server, {
    required String sessionScopeId,
  }) async {
    cwdRequestCount++;
    return '/workspace/';
  }

  @override
  Future<List<TerminalFileEntry>> listFiles(
    TerminalServerInfo server,
    String directory, {
    required String sessionScopeId,
  }) async {
    listFilesRequestCount++;
    listedDirectories.add(directory);
    final completer = listFileCompleters[server.selectionId];
    if (completer != null) {
      return completer.future;
    }
    // A copy, like a decoded response: later edits must not leak in.
    return List.of(entriesByServer[server.selectionId] ?? entries);
  }

  @override
  Future<List<TerminalListeningPort>> getListeningPorts(
    TerminalServerInfo server, {
    required String sessionScopeId,
  }) async {
    listeningPortsRequestCount++;
    return ports;
  }

  @override
  Future<void> setCwd(
    TerminalServerInfo server,
    String path, {
    required String sessionScopeId,
  }) async {}

  @override
  Future<TerminalFileReadResult> readFile(
    TerminalServerInfo server,
    String path, {
    required String sessionScopeId,
  }) async {
    readPaths.add(path);
    if (readError != null) throw readError!;
    return readResult ??
        const TerminalFileReadResult(
          fileName: 'alpha.txt',
          contentType: 'text/plain',
          text: 'print("hello from terminal")',
        );
  }
}

class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

class _MockWebSocketSink extends Mock implements WebSocketSink {}

class _TestWebSocketConnection {
  _TestWebSocketConnection({Future<void>? ready, Future<void>? cancelFuture})
    : _ready = ready ?? Future<void>.value(),
      _cancelFuture = cancelFuture ?? Future<void>.value() {
    _controller = StreamController<dynamic>(onCancel: () => _cancelFuture);
    when(() => channel.stream).thenAnswer((_) => _controller.stream);
    when(() => channel.sink).thenReturn(sink);
    when(() => channel.ready).thenAnswer((_) => _ready);
    when(() => sink.add(any())).thenAnswer((_) {});
    when(() => sink.close()).thenAnswer((_) async {
      closeCallCount++;
    });
    when(() => sink.done).thenAnswer((_) => Future<void>.value());
  }

  final _MockWebSocketChannel channel = _MockWebSocketChannel();
  final _MockWebSocketSink sink = _MockWebSocketSink();
  final Future<void> _ready;
  final Future<void> _cancelFuture;
  late final StreamController<dynamic> _controller;

  int closeCallCount = 0;

  Future<void> dispose() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}
