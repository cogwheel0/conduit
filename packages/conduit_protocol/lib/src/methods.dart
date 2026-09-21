/// Canonical RPC method names.
///
/// Both peers reference these constants instead of string literals, so a
/// renamed method is a compile error on the side that forgot to follow.
///
/// Only the `system.*` family is implemented in M0. The remaining namespaces
/// are declared here as prefixes so later milestones extend a known surface
/// (section 4) rather than inventing one.
abstract final class ConduitMethods {
  // ---------------------------------------------------------------------
  // system.* — implemented in WP-0.4.
  // ---------------------------------------------------------------------

  /// Exchange versions and capabilities. Must be the first call on a socket;
  /// every other method fails with `rpc.protocolViolation` until it succeeds.
  static const String systemHandshake = 'system.handshake';

  /// Round-trip liveness probe, sent by the UI every 5 s. The daemon replies
  /// with its uptime so a wedged event loop shows up as a timeout rather than
  /// as a silently stalled UI.
  static const String systemPing = 'system.ping';

  /// Re-read capabilities without reconnecting.
  static const String systemCapabilities = 'system.capabilities';

  /// Begin graceful shutdown: flush the outbox, checkpoint the database,
  /// close sockets. Electron main calls this before SIGTERM.
  static const String systemShutdown = 'system.shutdown';

  /// Zip the rotating logs plus a redacted config snapshot and return a path.
  static const String systemExportDiagnostics = 'system.exportDiagnostics';

  /// Replace this client's event interest set.
  static const String eventsSubscribe = 'events.subscribe';

  /// Answer a `ui.request` event. Carries the request id and the user's
  /// choice, or a cancellation.
  static const String uiRespond = 'ui.respond';

  // ---------------------------------------------------------------------
  // Namespace prefixes for later milestones (section 4).
  // ---------------------------------------------------------------------

  static const String serversPrefix = 'servers.';
  static const String authPrefix = 'auth.';
  static const String chatsPrefix = 'chats.';
  static const String foldersPrefix = 'folders.';
  static const String turnsPrefix = 'turns.';
  static const String composerPrefix = 'composer.';
  static const String modelsPrefix = 'models.';
  static const String capabilitiesPrefix = 'capabilities.';
  static const String filesPrefix = 'files.';
  static const String knowledgePrefix = 'knowledge.';
  static const String notesPrefix = 'notes.';
  static const String channelsPrefix = 'channels.';
  static const String workspacePrefix = 'workspace.';
  static const String directPrefix = 'direct.';
  static const String mcpPrefix = 'mcp.';
  static const String hermesPrefix = 'hermes.';
  static const String terminalPrefix = 'terminal.';
  static const String voicePrefix = 'voice.';
  static const String settingsPrefix = 'settings.';
  static const String syncPrefix = 'sync.';
  static const String socketPrefix = 'socket.';

  /// Every namespace the protocol reserves. A method outside these prefixes
  /// is a typo, and the daemon's fallback handler says so.
  static const Set<String> reservedPrefixes = {
    'system.',
    'events.',
    'ui.',
    serversPrefix,
    authPrefix,
    chatsPrefix,
    foldersPrefix,
    turnsPrefix,
    composerPrefix,
    modelsPrefix,
    capabilitiesPrefix,
    filesPrefix,
    knowledgePrefix,
    notesPrefix,
    channelsPrefix,
    workspacePrefix,
    directPrefix,
    mcpPrefix,
    hermesPrefix,
    terminalPrefix,
    voicePrefix,
    settingsPrefix,
    syncPrefix,
    socketPrefix,
  };

  /// Whether [method] sits in a namespace this protocol version defines.
  static bool isReserved(String method) =>
      reservedPrefixes.any(method.startsWith);
}

/// HTTP paths served next to the RPC socket, for payloads that do not belong
/// in JSON-RPC frames (section 3.2).
abstract final class ConduitHttpRoutes {
  /// `POST` multipart; streamed straight to the attachment queue so a 2 GB
  /// file never lands in a JSON string.
  static const String upload = '/upload';

  /// `GET /files/{serverId}/{fileId}` — proxied with the server's auth, TLS
  /// policy, and cookie jar applied, so `<img src>` works without the
  /// renderer ever holding a credential.
  static String file(String serverId, String fileId) =>
      '/files/$serverId/$fileId';

  /// `GET /tts/{jobId}` — audio for an `<audio>` element.
  static String tts(String jobId) => '/tts/$jobId';

  /// `WS /terminal/{sessionId}` — raw byte tunnel to the Open WebUI terminal
  /// socket with auth added (WP-7.2).
  static String terminal(String sessionId) => '/terminal/$sessionId';

  /// The JSON-RPC WebSocket itself.
  static const String rpc = '/rpc';
}
