/// Canonical RPC method names.
///
/// Both peers reference these constants instead of string literals, so a
/// renamed method is a compile error on the side that forgot to follow.
///
/// `system.*`, `servers.*` and `auth.*` are implemented. The remaining
/// namespaces are declared here as prefixes so later milestones extend a
/// known surface (section 4) rather than inventing one.
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

  /// The window's view of the network: the browser's `online` and
  /// `offline` events, which arrive at once where the daemon can only poll
  /// (WP-3.3).
  static const String systemNetwork = 'system.network';

  /// Replace this client's event interest set.
  static const String eventsSubscribe = 'events.subscribe';

  /// Answer a `ui.request` event. Carries the request id and the user's
  /// choice, or a cancellation.
  static const String uiRespond = 'ui.respond';

  // ---------------------------------------------------------------------
  // servers.* and auth.* -- implemented in WP-2.1.
  // ---------------------------------------------------------------------

  /// Every configured server plus which one is active.
  static const String serversList = 'servers.list';

  /// Adds a server and returns it. Does not make it active; `servers.select`
  /// is a separate step, because adding a second server from Settings must
  /// not sign the user out of the first.
  static const String serversAdd = 'servers.add';

  /// Edits a server in place. Secret fields left null keep their value.
  static const String serversUpdate = 'servers.update';

  /// Forgets a server and everything stored against it.
  static const String serversRemove = 'servers.remove';

  /// Makes one server active, keeping the others.
  ///
  /// The session being left is moved into the per-server token vault and the
  /// target's is taken up if it has one, so switching between servers you
  /// are signed into does not ask for credentials again. The adopted token is
  /// validated against the server before the session is published.
  ///
  /// Not destructive: the other configured servers and their sessions
  /// survive. `auth.signOut` is what ends sessions, and it empties the vault
  /// rather than only the active slot.
  static const String serversConnect = 'servers.connect';

  /// Live state of the active server: capabilities, version, reachability.
  ///
  /// Distinct from `servers.list`, which reports stored configuration. This
  /// one is about what the server is doing right now, and is what the version
  /// gate and the connection-issue page both read.
  static const String serversStatus = 'servers.status';

  /// The current session, without a token.
  static const String authStatus = 'auth.status';

  /// Username and password against Open WebUI's own login.
  static const String authLoginWithPassword = 'auth.loginWithPassword';

  /// Same credentials against the server's configured LDAP directory.
  static const String authLoginWithLdap = 'auth.loginWithLdap';

  /// An Open WebUI API key, used as a bearer token.
  static const String authLoginWithApiKey = 'auth.loginWithApiKey';

  /// Attempts to restore a session from stored credentials, validating them
  /// against the server first. Called once per launch.
  static const String authSilentLogin = 'auth.silentLogin';

  /// Finishes an SSO, OAuth or proxy sign-in that ran in an Electron window.
  static const String authCompleteExternal = 'auth.completeExternal';

  /// Whether stored credentials exist, so the UI can show "signing in"
  /// instead of a login form while `auth.silentLogin` runs.
  static const String authHasSavedCredentials = 'auth.hasSavedCredentials';

  /// Signs out, with the keep-server-details choice.
  static const String authSignOut = 'auth.signOut';

  /// Turns the reviewer/demo path on or off.
  static const String authSetReviewerMode = 'auth.setReviewerMode';

  // ---------------------------------------------------------------------
  // chats.* -- the conversation list and transcripts (M3).
  // ---------------------------------------------------------------------

  /// The first page of conversations, plus the archived count.
  static const String chatsList = 'chats.list';

  /// Extends the loaded page. Returns the whole list again rather than a
  /// delta: the sidebar renders from one array, and reconciling a delta in
  /// the renderer is how two clients end up disagreeing about the order.
  static const String chatsLoadMore = 'chats.loadMore';

  /// One conversation with its transcript.
  static const String chatsGet = 'chats.get';

  /// Full-text search over titles and message bodies.
  static const String chatsSearch = 'chats.search';

  /// Moves a conversation into a folder, or out of one (WP-3.1). Open WebUI
  /// unpins a conversation it moves; so does this.
  static const String chatsMove = 'chats.move';

  /// Every conversation in one folder, for its page (WP-3.1).
  static const String chatsFolder = 'chats.folder';

  /// Every message on every branch, for the overview map (WP-3.4).
  static const String chatsTree = 'chats.tree';

  /// Makes the branch through a message the one the transcript shows, on
  /// the server, as Open WebUI's client does when switching branches.
  static const String chatsSetCurrent = 'chats.setCurrent';

  /// Sets or clears a conversation's own system prompt (WP-3.4).
  static const String chatsSetSystemPrompt = 'chats.setSystemPrompt';

  /// Archives, unarchives, deletes or moves many conversations at once,
  /// refreshing the list once at the end (WP-3.8).
  static const String chatsBulk = 'chats.bulk';

  /// Every tag the account has, with its display name (WP-3.8).
  static const String chatsTagsAll = 'chats.tags.all';

  /// Tags a chat; answers with the chat's tags afterwards.
  static const String chatsTagsAdd = 'chats.tags.add';

  /// Untags a chat; answers with the chat's tags afterwards.
  static const String chatsTagsRemove = 'chats.tags.remove';

  /// Renames a conversation.
  static const String chatsRename = 'chats.rename';

  /// Pins or unpins it.
  static const String chatsSetPinned = 'chats.setPinned';

  /// Archives or unarchives it.
  static const String chatsSetArchived = 'chats.setArchived';

  /// Deletes it, on the server and locally.
  static const String chatsDelete = 'chats.delete';

  /// The sync engine's current state, for a window that has just opened.
  /// Changes after that arrive as `sync.status` events.
  static const String syncGet = 'sync.get';

  /// Includes archived chats in `chats.list`, or stops including them.
  static const String chatsSetArchivedVisible = 'chats.setArchivedVisible';

  /// Creates or removes a public share link.
  static const String chatsShare = 'chats.share';
  static const String chatsUnshare = 'chats.unshare';

  // ---------------------------------------------------------------------
  // models.* -- what the active server offers (M3).
  // ---------------------------------------------------------------------

  /// Every model the server offers, and which one is selected.
  static const String modelsList = 'models.list';

  /// Chooses the model new turns use. Persisted with the account, so the
  /// choice survives a restart and agrees with the mobile app.
  static const String modelsSelect = 'models.select';

  /// What the composer may offer: web search, image generation, the
  /// server's tools. Re-asked when the model or the session changes.
  static const String composerOptions = 'composer.options';

  /// Knowledge bases matching what follows a `#` in the composer (WP-3.3).
  static const String composerKnowledge = 'composer.knowledge';

  /// The account's saved prompts, for the composer's `/` menu (WP-3.3).
  static const String promptsList = 'prompts.list';

  /// A prompt's text with its variables filled in. Answers with the fields
  /// still to ask for when the prompt has any and no values were sent.
  static const String promptsRender = 'prompts.render';

  // ---------------------------------------------------------------------
  // direct.* -- connections the app talks to itself, not through Open
  // WebUI (M4).
  // ---------------------------------------------------------------------

  /// Every direct connection, secrets reported only as present.
  static const String directList = 'direct.list';

  /// Adds or changes a connection; answers with the list.
  static const String directSave = 'direct.save';

  /// Removes a connection; answers with the list.
  static const String directRemove = 'direct.remove';

  /// Turns a connection on or off without losing it.
  static const String directSetEnabled = 'direct.setEnabled';

  /// Tries a connection as edited, without saving it.
  static const String directTest = 'direct.test';

  /// Where direct chats are kept: this computer only, or mirrored.
  static const String directSetHistory = 'direct.setHistory';

  /// Makes direct connections the way the app is used, or stops: the
  /// welcome screen's choice. With one usable, no server is needed.
  static const String directSetPreferred = 'direct.setPreferred';

  /// An Ollama connection's models, with whether each is loaded and its
  /// keep-alive or thinking setting.
  static const String directOllamaModels = 'direct.ollamaModels';

  /// Loads an Ollama model into memory ahead of a chat.
  static const String directOllamaLoad = 'direct.ollamaLoad';

  /// Frees an Ollama model's memory.
  static const String directOllamaUnload = 'direct.ollamaUnload';

  /// Sets how long an Ollama model stays loaded after a chat.
  static const String directOllamaKeepAlive = 'direct.ollamaKeepAlive';

  /// Sets an Ollama Cloud model's thinking level.
  static const String directOllamaThinking = 'direct.ollamaThinking';

  // ---------------------------------------------------------------------
  // mcp.* -- MCP servers the app talks to itself (M4).
  // ---------------------------------------------------------------------

  /// Every MCP server, secrets reported only as present.
  static const String mcpList = 'mcp.list';

  /// Adds or changes a server; answers with the list.
  static const String mcpSave = 'mcp.save';

  /// Removes a server; answers with the list.
  static const String mcpRemove = 'mcp.remove';

  /// Turns a server on or off without losing it.
  static const String mcpSetEnabled = 'mcp.setEnabled';

  /// Connects to a server as edited and counts its tools, without saving.
  static const String mcpTest = 'mcp.test';

  /// Signs in with OAuth: the daemon listens on a loopback port and a
  /// window opens the provider's page (`shell.openUrl`). Answers once the
  /// sign-in finishes, fails or is cancelled.
  static const String mcpConnect = 'mcp.connect';

  /// Abandons a sign-in in progress.
  static const String mcpCancelConnect = 'mcp.cancelConnect';

  /// Forgets an OAuth sign-in.
  static const String mcpDisconnect = 'mcp.disconnect';

  /// Forgets remembered tool approvals.
  static const String mcpForgetApproval = 'mcp.forgetApproval';

  /// The prompts and resources one server offers, for the content sheet.
  static const String mcpContent = 'mcp.content';

  /// Renders one of a server's prompts with its arguments, to preview and
  /// insert.
  static const String mcpGetPrompt = 'mcp.getPrompt';

  /// Reads one of a server's resources, to preview and insert.
  static const String mcpReadResource = 'mcp.readResource';

  // ---------------------------------------------------------------------
  // turns.* -- sending and stopping generation (M3).
  // ---------------------------------------------------------------------

  /// Sends a message and starts generation.
  ///
  /// Returns once the server has accepted the request. The answer arrives as
  /// `turn.delta` events, so a long reply is not a long RPC.
  static const String turnsSend = 'turns.send';

  /// Stops generation for a chat, keeping whatever has arrived.
  static const String turnsStop = 'turns.stop';

  /// Runs the turn again, replacing one assistant answer.
  ///
  /// A branch server-side rather than an overwrite: Open WebUI records the
  /// new answer as another child of the same user message, so the previous
  /// one stays reachable. The renderer gets the same `turn.*` events a send
  /// produces, because from its side nothing else is different.
  static const String turnsRegenerate = 'turns.regenerate';

  /// Replaces one of the user's messages with new text and answers it, as
  /// a new branch.
  static const String turnsEdit = 'turns.edit';

  /// Rates an answer, up or down, as Open WebUI's own client does: an
  /// evaluation record plus the thumb on the message. Gated on
  /// `capabilities.messageRating`.
  static const String turnsRate = 'turns.rate';

  // ---------------------------------------------------------------------
  // settings.* -- app preferences implemented in WP-2.4. The server-side
  // user settings in this namespace arrive with M9.
  // ---------------------------------------------------------------------

  /// Theme, palette and locale, as the daemon has them stored.
  static const String settingsGetApp = 'settings.getApp';

  /// Patches them. Fields left null keep their value.
  static const String settingsSetApp = 'settings.setApp';

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

  // notes.* (M5) -- listed with the prefixes because they are few.

  /// Every note, or those matching a query; pinned first.
  static const String notesList = 'notes.list';

  /// One note, its body as Quill ops.
  static const String notesGet = 'notes.get';

  /// Creates or updates a note; answers with it as saved.
  static const String notesSave = 'notes.save';

  static const String notesDelete = 'notes.delete';

  /// Pins or unpins a note; answers with it. A state rather than a toggle,
  /// so a second window acting on a stale list cannot undo the first.
  static const String notesSetPinned = 'notes.setPinned';

  /// Asks a model for a short title for the note's text.
  static const String notesGenerateTitle = 'notes.generateTitle';

  /// Asks a model to rewrite the note as fuller, better-organised
  /// markdown; answers with the new body without saving it.
  static const String notesEnhance = 'notes.enhance';
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
