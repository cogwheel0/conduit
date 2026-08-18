import 'package:checks/checks.dart';
import 'package:conduit/features/terminal/controllers/terminal_browser_controller.dart';
import 'package:conduit/features/terminal/controllers/terminal_context_controller.dart';
import 'package:conduit/features/terminal/controllers/terminal_controller_gateways.dart';
import 'package:conduit/features/terminal/controllers/terminal_session_controller.dart';
import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/services/terminal_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
      () => service.isTerminalFeatureEnabled(
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
        () => service.isTerminalFeatureEnabled(server, sessionScopeId: 'scope'),
      ).thenAnswer((_) async => true);
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
    );
    browser = TerminalBrowserController(
      gateway: gateway,
      platformGateway: const _FakeTerminalPlatformGateway(),
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

  @override
  WebSocketChannel openChannel(Uri uri, {required TerminalServerKind kind}) =>
      throw UnimplementedError();

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
  const _FakeTerminalPlatformGateway();

  @override
  Future<TerminalUploadFile?> pickUploadFile() async => null;

  @override
  Future<void> saveDownload(TerminalDownloadedFile downloaded) async {}

  @override
  Future<bool> openPort(Uri uri, {String? bearerToken}) async => true;
}
