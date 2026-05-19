import 'dart:async';

import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/providers/terminal_providers.dart';
import 'package:conduit/features/terminal/services/terminal_service.dart';
import 'package:conduit/features/terminal/widgets/terminal_tab.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  group('TerminalTab', () {
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
          channelConnector: (_) => channels[channelConnectCount++].channel,
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
      expect(find.text('Listening ports'), findsNothing);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(TerminalTab)),
      );
      container
          .read(terminalSidebarPanelProvider.notifier)
          .setPanel(TerminalSidebarPanel.console);
      await tester.pumpAndSettle();

      expect(find.text('Listening ports'), findsOneWidget);
      expect(find.text('localhost:3000'), findsOneWidget);
      expect(find.text('alpha.txt'), findsNothing);
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
}) {
  return ProviderScope(
    overrides: [
      terminalServiceProvider.overrideWithValue(service),
      terminalAutoConnectProvider.overrideWithValue(autoConnect),
      if (channelConnector != null)
        terminalChannelConnectorProvider.overrideWithValue(channelConnector),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: TerminalTab(isActive: isActive)),
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
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

Widget _buildHarnessWithContainer(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: TerminalTab()),
    ),
  );
}

class _MockApiService extends Mock implements ApiService {}

class _FakeTerminalService extends TerminalService {
  _FakeTerminalService({
    required this.servers,
    required this.entries,
    required this.ports,
    this.entriesByServer = const <String, List<TerminalFileEntry>>{},
    this.listFileCompleters =
        const <String, Completer<List<TerminalFileEntry>>>{},
    Map<int, Completer<bool>> terminalEnabledCompletersByRequest =
        const <int, Completer<bool>>{},
  }) : terminalEnabledCompletersByRequest = Map<int, Completer<bool>>.from(
         terminalEnabledCompletersByRequest,
       ),
       super(_MockApiService());

  final List<TerminalServerInfo> servers;
  final List<TerminalFileEntry> entries;
  final List<TerminalListeningPort> ports;
  final Map<String, List<TerminalFileEntry>> entriesByServer;
  final Map<String, Completer<List<TerminalFileEntry>>> listFileCompleters;
  final Map<int, Completer<bool>> terminalEnabledCompletersByRequest;
  final List<String> readPaths = <String>[];
  int cwdRequestCount = 0;
  int listFilesRequestCount = 0;
  int listeningPortsRequestCount = 0;
  int terminalEnabledRequestCount = 0;
  int createSessionRequestCount = 0;

  @override
  Future<List<TerminalServerInfo>> getAvailableServers() async => servers;

  @override
  Future<Map<String, dynamic>> updateDirectTerminalSelection(
    String? selectedSelectionId,
  ) async {
    return <String, dynamic>{};
  }

  @override
  Future<bool> isTerminalFeatureEnabled(
    TerminalServerInfo server, {
    String? sessionScopeId,
  }) async {
    terminalEnabledRequestCount++;
    final completer =
        terminalEnabledCompletersByRequest[terminalEnabledRequestCount];
    if (completer != null) {
      return completer.future;
    }
    return true;
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
  String? authTokenForServer(TerminalServerInfo server) => 'terminal-token';

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
    final completer = listFileCompleters[server.selectionId];
    if (completer != null) {
      return completer.future;
    }
    return entriesByServer[server.selectionId] ?? entries;
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
  Future<TerminalFileReadResult> readFile(
    TerminalServerInfo server,
    String path, {
    required String sessionScopeId,
  }) async {
    readPaths.add(path);
    return const TerminalFileReadResult(
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
