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
  'pongResult': const PongResult(uptimeMs: 421337, serverTimeMs: 1789000000000),
  'shutdownResult': const ShutdownResult(
    flushed: false,
    pendingOutboxEntries: 2,
  ),
  'diagnosticsExport': const DiagnosticsExport(
    path: '/home/u/.config/Conduit/staging/diagnostics-2026-09-21.zip',
    sizeBytes: 148213,
  ),

  // Nested inside handshakeResponse, so it is encoded there -- but its own
  // `fromJson` had never been exercised until the missing-fixture check in
  // protocol_golden_test.dart went looking.
  'daemonPaths': const DaemonPaths(
    userData: '/home/u/.config/Conduit',
    database: '/home/u/.config/Conduit/db',
    cache: '/home/u/.config/Conduit/cache',
    logs: '/home/u/.config/Conduit/logs',
    staging: '/home/u/.config/Conduit/staging',
  ),

  // servers.* and auth.* (WP-2.1). Two variants of ServerSummary on purpose:
  // the redacted-secrets shape is the one that carries the security claim, so
  // it is golden-checked rather than trusted.
  'serverSummaryMinimal': const ServerSummary(
    id: '7c1f0b2a-5e3d-4a9c-8b7e-1d2f3a4b5c6d',
    name: 'Home',
    url: 'https://chat.example.com',
  ),
  'serverSummaryFull': const ServerSummary(
    id: '7c1f0b2a-5e3d-4a9c-8b7e-1d2f3a4b5c6d',
    name: 'Work',
    url: 'https://openwebui.corp.example.com',
    isActive: true,
    lastConnectedMs: 1758412800000,
    allowSelfSignedCertificates: true,
    hasMutualTlsCredentials: true,
    mtlsCertificateLabel: 'corp-client.pem',
    mtlsPrivateKeyLabel: 'corp-client-key.pem',
    customHeaderNames: <String>['X-Conduit-Tenant', 'CF-Access-Client-Id'],
    hasStoredSession: true,
  ),
  'serverDraft': const ServerDraft(
    id: '7c1f0b2a-5e3d-4a9c-8b7e-1d2f3a4b5c6d',
    name: 'Work',
    url: 'https://openwebui.corp.example.com',
    allowSelfSignedCertificates: true,
    customHeaders: <String, String>{'X-Conduit-Tenant': 'acme'},
  ),
  'serverRef': const ServerRef(id: '7c1f0b2a-5e3d-4a9c-8b7e-1d2f3a4b5c6d'),
  'serverList': const ServerList(
    servers: <ServerSummary>[
      ServerSummary(
        id: '7c1f0b2a-5e3d-4a9c-8b7e-1d2f3a4b5c6d',
        name: 'Home',
        url: 'https://chat.example.com',
        isActive: true,
      ),
    ],
    activeServerId: '7c1f0b2a-5e3d-4a9c-8b7e-1d2f3a4b5c6d',
  ),
  'authSnapshotSignedOut': const AuthSnapshot(phase: AuthPhase.unauthenticated),
  'authSnapshotSignedIn': const AuthSnapshot(
    phase: AuthPhase.authenticated,
    isAuthenticated: true,
    hasToken: true,
    user: AuthUser(
      id: 'c3a1b2d4-5e6f-4708-9a1b-2c3d4e5f6071',
      name: 'Ada Lovelace',
      email: 'ada@example.com',
      role: 'admin',
      avatarUrl: '/api/v1/users/c3a1b2d4/avatar',
    ),
  ),
  'authSnapshotError': const AuthSnapshot(
    phase: AuthPhase.credentialError,
    errorCode: ConduitErrorCodes.invalidCredentials,
    errorArgs: <String, String>{'attempt': '3'},
  ),
  'authUser': const AuthUser(
    id: 'c3a1b2d4-5e6f-4708-9a1b-2c3d4e5f6071',
    name: 'Ada Lovelace',
  ),
  'passwordLogin': const PasswordLogin(
    username: 'ada@example.com',
    password: 'correct horse battery staple',
  ),
  'apiKeyLogin': const ApiKeyLogin(apiKey: 'sk-not-a-real-key'),
  'externalAuthCompletion': const ExternalAuthCompletion(
    origin: 'https://chat.example.com',
    cookies: <String, String>{'oauth2_proxy': 'opaque-session-value'},
    token: 'eyJhbGciOiJIUzI1NiJ9.not-a-real-token',
  ),
  'signOutRequest': const SignOutRequest(keepServerDetails: false),
  'modelSummary': const ModelSummary(
    id: 'gpt-4o',
    name: 'GPT-4o',
    description: 'Fast, multimodal.',
    pinned: true,
    capabilities: <String>['tools', 'vision'],
  ),
  'modelList': const ModelList(
    models: <ModelSummary>[ModelSummary(id: 'gpt-4o', name: 'GPT-4o')],
    selectedId: 'gpt-4o',
  ),
  'selectModel': const SelectModel(id: 'gpt-4o'),
  'sendTurn': const SendTurn(
    chatId: 'chat-7c1f0b2a',
    model: 'gpt-4o',
    text: 'How does the outbox order writes?',
    toolIds: <String>['web_search'],
    webSearch: true,
  ),
  'sendTurnAccepted': const SendTurnAccepted(
    chatId: 'chat-7c1f0b2a',
    userMessageId: 'msg-user-1',
    assistantMessageId: 'msg-assistant-1',
  ),
  'turnStarted': const TurnStarted(
    chatId: 'chat-7c1f0b2a',
    messageId: 'msg-assistant-1',
    model: 'gpt-4o',
  ),
  'turnDelta': const TurnDelta(
    chatId: 'chat-7c1f0b2a',
    messageId: 'msg-assistant-1',
    text: 'The outbox drains',
    reasoning: 'Checking the DAO.',
  ),
  'turnCompleted': const TurnCompleted(
    chatId: 'chat-7c1f0b2a',
    messageId: 'msg-assistant-1',
    text: 'The outbox drains oldest-first.',
    usage: <String, int>{'prompt_tokens': 812, 'completion_tokens': 46},
  ),
  'turnFailed': const TurnFailed(
    chatId: 'chat-7c1f0b2a',
    messageId: 'msg-assistant-1',
    code: ConduitErrorCodes.serverError,
    args: <String, String>{'status': '502'},
    partialText: 'The outbox dra',
  ),
  'stopTurn': const StopTurn(chatId: 'chat-7c1f0b2a'),
  'syncState': const SyncState(running: true, progress: 0.4),
  'chatsChanged': const ChatsChanged(chatId: 'chat-7c1f0b2a'),
  'editTurn': const EditTurn(
    chatId: 'chat-7c1f0b2a',
    messageId: 'msg-user-01',
    text: 'What I meant to ask',
  ),
  'chatMessageVersionDto': const ChatMessageVersionDto(
    id: 'msg-earlier',
    content: 'The first answer.',
    timestampMs: 1758412800000,
    model: 'llama3.2:1b',
  ),
  'folderSummary': const FolderSummary(
    id: 'folder-1d7c',
    name: 'Research',
    expanded: true,
  ),
  'archivedVisibility': const ArchivedVisibility(visible: true),
  'uploadedFile': const UploadedFile(
    id: 'file-3b91d0c4',
    name: 'notes.pdf',
    size: 182_344,
    contentType: 'application/pdf',
  ),
  'regenerateTurn': const RegenerateTurn(
    chatId: 'chat-7c1f0b2a',
    messageId: 'msg-2f9d4c17',
    model: 'llama3.2:1b',
  ),
  'chatSummary': const ChatSummary(
    id: 'chat-7c1f0b2a',
    title: 'Rewriting the sync engine',
    updatedAtMs: 1758412800000,
    pinned: true,
    model: 'gpt-4o',
    tags: <String>['work', 'architecture'],
    shared: true,
  ),
  'chatList': const ChatList(
    chats: <ChatSummary>[
      ChatSummary(
        id: 'chat-7c1f0b2a',
        title: 'Rewriting the sync engine',
        updatedAtMs: 1758412800000,
      ),
    ],
    hasMore: true,
    archivedCount: 12,
  ),
  'chatMessage': const ChatMessageDto(
    id: 'msg-1',
    role: 'assistant',
    content: 'The outbox drains oldest-first.',
    timestampMs: 1758412800000,
    model: 'gpt-4o',
    streaming: true,
  ),
  'chatDetail': const ChatDetail(
    summary: ChatSummary(
      id: 'chat-7c1f0b2a',
      title: 'Rewriting the sync engine',
      updatedAtMs: 1758412800000,
    ),
    messages: <ChatMessageDto>[
      ChatMessageDto(
        id: 'msg-1',
        role: 'user',
        content: 'How does the outbox order writes?',
        timestampMs: 1758412700000,
      ),
    ],
  ),
  'chatRef': const ChatRef(id: 'chat-7c1f0b2a'),
  'renameChat': const RenameChat(
    id: 'chat-7c1f0b2a',
    title: 'Rewriting the sync engine',
  ),
  'setChatFlag': const SetChatFlag(id: 'chat-7c1f0b2a', value: true),
  'chatShare': const ChatShare(
    chatId: 'chat-7c1f0b2a',
    shareId: '3f0b2a7c-1d4e-4a9c-8b7e-2d3f4a5b6c7d',
  ),
  'chatShareRemoved': const ChatShare(chatId: 'chat-7c1f0b2a'),
  'chatSearchQuery': const ChatSearchQuery(query: 'outbox', limit: 20),
  'chatSearchHit': const ChatSearchHit(
    chatId: 'chat-7c1f0b2a',
    title: 'Rewriting the sync engine',
    snippet: 'the <b>outbox</b> drains oldest-first',
    updatedAtMs: 1758412800000,
  ),
  'chatSearchResults': const ChatSearchResults(
    hits: <ChatSearchHit>[
      ChatSearchHit(
        chatId: 'chat-7c1f0b2a',
        title: 'Rewriting the sync engine',
        updatedAtMs: 1758412800000,
      ),
    ],
    complete: false,
  ),
  'serverStatusNoServer': const ServerStatus(maxSupportedVersion: '0.11.3'),
  'serverStatusReachable': const ServerStatus(
    activeServerId: '7c1f0b2a-5e3d-4a9c-8b7e-1d2f3a4b5c6d',
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
    reachability: ServerReachability.reachable,
    version: '0.11.3',
    maxSupportedVersion: '0.11.3',
  ),
  'serverStatusUnreachable': const ServerStatus(
    activeServerId: '7c1f0b2a-5e3d-4a9c-8b7e-1d2f3a4b5c6d',
    reachability: ServerReachability.unreachable,
    errorCode: ConduitErrorCodes.connectionFailed,
    maxSupportedVersion: '0.11.3',
  ),
  'serverStatusTooNew': const ServerStatus(
    activeServerId: '7c1f0b2a-5e3d-4a9c-8b7e-1d2f3a4b5c6d',
    reachability: ServerReachability.reachable,
    version: '0.99.0',
    isVersionSupported: false,
    maxSupportedVersion: '0.11.3',
  ),
  'appPreferencesDefault': const AppPreferences(),
  'appPreferencesFull': const AppPreferences(
    themeMode: AppThemeMode.dark,
    themePaletteId: 't3_chat',
    localeCode: 'zh-Hant',
  ),
  'appPreferencesPatch': const AppPreferencesPatch(
    themePaletteId: 'claude',
    clearLocaleCode: true,
  ),
  'signOutResult': const SignOutResult(
    outcome: SignOutOutcome.localDataClearedSessionCleanupIncomplete,
    remaining: <String>['cookies'],
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
      'daemonPaths': DaemonPaths.fromJson,
      'serverSummaryMinimal': ServerSummary.fromJson,
      'serverSummaryFull': ServerSummary.fromJson,
      'serverDraft': ServerDraft.fromJson,
      'serverRef': ServerRef.fromJson,
      'serverList': ServerList.fromJson,
      'authSnapshotSignedOut': AuthSnapshot.fromJson,
      'authSnapshotSignedIn': AuthSnapshot.fromJson,
      'authSnapshotError': AuthSnapshot.fromJson,
      'authUser': AuthUser.fromJson,
      'passwordLogin': PasswordLogin.fromJson,
      'apiKeyLogin': ApiKeyLogin.fromJson,
      'externalAuthCompletion': ExternalAuthCompletion.fromJson,
      'signOutRequest': SignOutRequest.fromJson,
      'modelSummary': ModelSummary.fromJson,
      'modelList': ModelList.fromJson,
      'selectModel': SelectModel.fromJson,
      'sendTurn': SendTurn.fromJson,
      'sendTurnAccepted': SendTurnAccepted.fromJson,
      'turnStarted': TurnStarted.fromJson,
      'turnDelta': TurnDelta.fromJson,
      'turnCompleted': TurnCompleted.fromJson,
      'turnFailed': TurnFailed.fromJson,
      'stopTurn': StopTurn.fromJson,
      'syncState': SyncState.fromJson,
      'chatsChanged': ChatsChanged.fromJson,
      'editTurn': EditTurn.fromJson,
      'chatMessageVersionDto': ChatMessageVersionDto.fromJson,
      'folderSummary': FolderSummary.fromJson,
      'archivedVisibility': ArchivedVisibility.fromJson,
      'uploadedFile': UploadedFile.fromJson,
      'regenerateTurn': RegenerateTurn.fromJson,
      'chatSummary': ChatSummary.fromJson,
      'chatList': ChatList.fromJson,
      'chatMessage': ChatMessageDto.fromJson,
      'chatDetail': ChatDetail.fromJson,
      'chatRef': ChatRef.fromJson,
      'renameChat': RenameChat.fromJson,
      'setChatFlag': SetChatFlag.fromJson,
      'chatShare': ChatShare.fromJson,
      'chatShareRemoved': ChatShare.fromJson,
      'chatSearchQuery': ChatSearchQuery.fromJson,
      'chatSearchHit': ChatSearchHit.fromJson,
      'chatSearchResults': ChatSearchResults.fromJson,
      'serverStatusNoServer': ServerStatus.fromJson,
      'serverStatusReachable': ServerStatus.fromJson,
      'serverStatusUnreachable': ServerStatus.fromJson,
      'serverStatusTooNew': ServerStatus.fromJson,
      'appPreferencesDefault': AppPreferences.fromJson,
      'appPreferencesFull': AppPreferences.fromJson,
      'appPreferencesPatch': AppPreferencesPatch.fromJson,
      'signOutResult': SignOutResult.fromJson,
    };

/// Every fixture's `toJson`, so the checker can encode without `dynamic`.
Map<String, dynamic> encodeFixture(Object fixture) =>
    (fixture as dynamic).toJson() as Map<String, dynamic>;
