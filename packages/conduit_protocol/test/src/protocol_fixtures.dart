import 'package:conduit_protocol/conduit_protocol.dart';

/// The canonical sample of every DTO that crosses the wire.
///
/// One map, consumed by three things: the golden encode/decode test, the
/// compiled-to-JS variant of that same test, and (later) the daemon and UI
/// integration fakes. Adding a DTO without adding it here is what "schema
/// drift" looks like in practice, so [protocolFixtures] is asserted to be
/// exhaustive in the golden test.
final Map<String, Object> protocolFixtures = <String, Object>{
  'handshakeRequest': const HandshakeRequest(
    protocolVersion: kConduitProtocolVersion,
    clientName: 'conduit-desktop-ui',
    clientVersion: '0.1.0',
    windowKind: WindowKind.main,
    locale: 'zh-Hant',
  ),
  'handshakeResponse': const HandshakeResponse(
    protocolVersion: kConduitProtocolVersion,
    daemonVersion: '0.1.0',
    sessionId: '0f9d1c2e-4b6a-4d8f-9a1b-2c3d4e5f6071',
    capabilities: Capabilities(
      workspace: true,
      notes: true,
      channels: true,
      serverStt: true,
      serverTts: true,
      deviceTts: true,
      branchNavigation: true,
      tags: true,
    ),
    paths: DaemonPaths(
      userData: '/home/u/.config/Conduit',
      database: '/home/u/.config/Conduit/db',
      cache: '/home/u/.config/Conduit/cache',
      logs: '/home/u/.config/Conduit/logs',
      staging: '/home/u/.config/Conduit/staging',
    ),
    platform: 'linux',
    needsOnboarding: true,
  ),
  'capabilitiesNone': Capabilities.none,
  'rpcErrorMinimal': const RpcError(code: ConduitErrorCodes.offline),
  'rpcErrorFull': const RpcError(
    code: ConduitErrorCodes.serverError,
    args: <String, String>{'status': '503', 'host': 'chat.example.com'},
    debugMessage: 'upstream returned 503',
    retryable: true,
  ),
  'eventEnvelope': const EventEnvelope(
    event: ConduitEvents.turnDelta,
    // Deliberately large: well past 2^32 but inside 2^53, so this fixture
    // fails loudly if anyone makes `seq` a type JS cannot represent exactly.
    seq: 9007199254740991,
    scope: 'chat_01HV8Z',
    payload: <String, dynamic>{'text': 'Hello', 'index': 3},
  ),
  'eventSubscription': const EventSubscription(
    events: <String>[ConduitEvents.turnDelta, ConduitEvents.chatsChanged],
    scopes: <String>['chat_01HV8Z'],
  ),
  'uiRequest': const UiRequest(
    requestId: 'req_7',
    kind: UiRequestKind.toolApproval,
    messageCode: 'tool.approvalPrompt',
    messageArgs: <String, String>{'tool': 'web_search'},
    detail: <String, dynamic>{
      'tool': 'web_search',
      'arguments': <String, dynamic>{'query': 'jaspr 0.23'},
    },
    timeoutMs: 120000,
  ),
  'uiResponse': const UiResponse(
    requestId: 'req_7',
    choice: 'allow',
    remember: true,
  ),
  'pongResult': const PongResult(
    uptimeMs: 421337,
    serverTimeMs: 1789000000000,
  ),
  'shutdownResult': const ShutdownResult(flushed: false, pendingOutboxEntries: 2),
  'diagnosticsExport': const DiagnosticsExport(
    path: '/home/u/.config/Conduit/staging/diagnostics-2026-09-21.zip',
    sizeBytes: 148213,
  ),
};

/// `fromJson` for each fixture, keyed the same way.
///
/// Kept beside [protocolFixtures] so a new DTO cannot be added to one without
/// the other; the golden test asserts the two key sets match.
final Map<String, Object Function(Map<String, dynamic>)> protocolDecoders =
    <String, Object Function(Map<String, dynamic>)>{
      'handshakeRequest': HandshakeRequest.fromJson,
      'handshakeResponse': HandshakeResponse.fromJson,
      'capabilitiesNone': Capabilities.fromJson,
      'rpcErrorMinimal': RpcError.fromJson,
      'rpcErrorFull': RpcError.fromJson,
      'eventEnvelope': EventEnvelope.fromJson,
      'eventSubscription': EventSubscription.fromJson,
      'uiRequest': UiRequest.fromJson,
      'uiResponse': UiResponse.fromJson,
      'pongResult': PongResult.fromJson,
      'shutdownResult': ShutdownResult.fromJson,
      'diagnosticsExport': DiagnosticsExport.fromJson,
    };

/// Every fixture's `toJson`, so the checker can encode without `dynamic`.
Map<String, dynamic> encodeFixture(Object fixture) =>
    (fixture as dynamic).toJson() as Map<String, dynamic>;
