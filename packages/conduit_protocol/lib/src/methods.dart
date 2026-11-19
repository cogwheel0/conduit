/// Canonical RPC method names.
///
/// Both peers reference these constants instead of string literals, so a
/// renamed method is a compile error on the side that forgot to follow.
///
/// Namespaces are declared here as prefixes too, so new methods extend a
/// known surface rather than inventing one.
abstract final class ConduitMethods {
  // ---------------------------------------------------------------------
  // system.*
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

  /// Sends what the outbox holds (for up to 3 s), replies with what is still
  /// waiting, then stops the daemon.
  ///
  /// Optional. The supported way to stop the daemon is to close its stdin:
  /// at EOF it closes every session, then the core and its database, and
  /// exits 0. This method ends in that same stop, after trying to send
  /// pending changes first; whatever it could not send stays on disk for
  /// the next launch. SIGINT and SIGTERM stop it the same way too, so a
  /// supervisor that gets no exit after closing stdin can escalate.
  static const String systemShutdown = 'system.shutdown';

  /// Zips the daemon's rotating logs (`userData/logs`) and a snapshot of its
  /// configuration into the staging directory, and returns the path.
  ///
  /// Nothing is uploaded. The snapshot names servers by id and origin only;
  /// tokens, keys, cookies, passwords and header values are left out, and
  /// the logs are scrubbed of them again on the way into the zip.
  static const String systemExportDiagnostics = 'system.exportDiagnostics';

  /// The window's view of the network: the browser's `online` and
  /// `offline` events, which arrive at once where the daemon can only poll.
  static const String systemNetwork = 'system.network';

  /// Replace this client's event interest set.
  static const String eventsSubscribe = 'events.subscribe';

  /// Answer a `ui.request` event. Carries the request id and the user's
  /// choice, or a cancellation.
  static const String uiRespond = 'ui.respond';

  // ---------------------------------------------------------------------
  // accounts.*, servers.* and auth.*
  // ---------------------------------------------------------------------

  /// Every saved Open WebUI account, which is active, and whether one is
  /// being added.
  static const String accountsList = 'accounts.list';

  /// Begins adding an account: a new account on the given server becomes
  /// active, signed out, and the `auth.login*` methods sign in to it. The
  /// account it was added from keeps its session, so `accounts.cancelAdd`
  /// returns to it. On a saved server's address the new account joins that
  /// server; signed in as a user already saved there, it is folded into that
  /// account.
  static const String accountsAdd = 'accounts.add';

  /// Leaves an addition whose sign-in has not finished: the new account is
  /// dropped and the one it was added from is active again.
  static const String accountsCancelAdd = 'accounts.cancelAdd';

  /// Makes another saved account active. The session being left is kept, so
  /// switching back does not ask for a sign-in.
  static const String accountsSwitch = 'accounts.switch';

  /// Signs out of an account and removes it, with its local data. When it is
  /// the active one, the most recently used remaining account takes over,
  /// preferring one still signed in; with none left the app carries on with
  /// Direct or Hermes, or goes back to choosing a backend.
  static const String accountsRemove = 'accounts.remove';

  /// `accounts.remove` for the active account: signing out hands over to the
  /// next account, as on mobile. Other accounts and their data stay.
  static const String accountsSignOut = 'accounts.signOut';

  /// Edits the server an account is on: name, address, TLS and headers.
  /// Secret fields left null keep their value. Every account on that server
  /// keeps its session. The id may also be a saved server's (its
  /// `AccountSummary.serverId`), which renames it. An address change goes
  /// through `servers.addresses.*`, which check it first.
  static const String serversUpdate = 'servers.update';

  /// A saved server's addresses, in the order they are tried, and which one
  /// is in use.
  static const String serversAddressesList = 'servers.addresses.list';

  /// Checks an address being added to a saved server, or edited, for an
  /// Open WebUI server that answers. Nothing is saved.
  static const String serversAddressesCheck = 'servers.addresses.check';

  /// Saves a checked address, once it is shown to know the server's
  /// accounts. Asks first (`ServerAddressConfirmation`) before an account's
  /// session goes to a new host, and before the address in use changes
  /// while a reply arrives through it.
  static const String serversAddressesSave = 'servers.addresses.save';

  /// Removes an address; one is always left.
  static const String serversAddressesRemove = 'servers.addresses.remove';

  /// Puts a server's addresses in a new order.
  static const String serversAddressesReorder = 'servers.addresses.reorder';

  /// Live state of the active server: capabilities, version, reachability.
  ///
  /// Distinct from `accounts.list`, which reports stored configuration. This
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

  /// Finishes an SSO, OAuth or proxy sign-in that ran in a desktop app window.
  static const String authCompleteExternal = 'auth.completeExternal';

  /// Whether stored credentials exist, so the UI can show "signing in"
  /// instead of a login form while `auth.silentLogin` runs.
  static const String authHasSavedCredentials = 'auth.hasSavedCredentials';

  /// Turns the reviewer/demo path on or off.
  static const String authSetReviewerMode = 'auth.setReviewerMode';

  /// What to add to an authenticator app for a two-step `enroll` step.
  static const String authTwoStepSetup = 'auth.twoStep.setup';

  /// Answers a two-step `verify` or `enroll` step with a code (or, for
  /// `verify`, a recovery code). Signs in, or moves to `recoveryCodes` when
  /// the server issued new ones.
  static const String authTwoStepVerify = 'auth.twoStep.verify';

  /// Redeems an administrator's recovery token for a `recover` step, which
  /// moves to `enroll`.
  static const String authTwoStepRedeem = 'auth.twoStep.redeem';

  /// Signs in once the new recovery codes were shown.
  static const String authTwoStepFinish = 'auth.twoStep.finish';

  /// Leaves the second step, back to the sign-in form.
  static const String authTwoStepCancel = 'auth.twoStep.cancel';

  /// Checks the kept session again after a connection issue: the server is
  /// asked again, or the saved sign-in tried when no session is kept.
  static const String authRetry = 'auth.retry';

  /// Renews the active account's expired reverse-proxy session in place
  /// with what a proxy sign-in window captured, keeping the account signed
  /// in.
  static const String authRenewProxy = 'auth.renewProxy';

  // ---------------------------------------------------------------------
  // chats.* -- the conversation list and transcripts.
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

  /// Moves a conversation into a folder, or out of one. Open WebUI
  /// unpins a conversation it moves; so does this.
  static const String chatsMove = 'chats.move';

  /// Every conversation in one folder, for its page.
  static const String chatsFolder = 'chats.folder';

  /// Every message on every branch, for the overview map.
  static const String chatsTree = 'chats.tree';

  /// Makes the branch through a message the one the transcript shows, on
  /// the server, as Open WebUI's client does when switching branches.
  static const String chatsSetCurrent = 'chats.setCurrent';

  /// Sets or clears a conversation's own system prompt.
  static const String chatsSetSystemPrompt = 'chats.setSystemPrompt';

  /// Archives, unarchives, deletes or moves many conversations at once,
  /// refreshing the list once at the end.
  static const String chatsBulk = 'chats.bulk';

  /// Every tag the account has, with its display name.
  static const String chatsTagsAll = 'chats.tags.all';

  /// Tags a chat; answers with the chat's tags afterwards.
  static const String chatsTagsAdd = 'chats.tags.add';

  /// Untags a chat; answers with the chat's tags afterwards.
  static const String chatsTagsRemove = 'chats.tags.remove';

  /// Renames a conversation.
  static const String chatsRename = 'chats.rename';

  // folders.* -- the account's own folders, as a phone's drawer edits
  // them. Each answers with the list afterwards and publishes
  // `chats.changed`, so every window's sidebar follows.

  /// Makes a folder, at the top level or in another.
  static const String foldersCreate = 'folders.create';

  /// Renames a folder the account owns.
  static const String foldersRename = 'folders.rename';

  /// Deletes a folder the account owns, with its subfolders. The chats in
  /// them are kept: they leave the folder for the chat list, as the sync
  /// engine's own folder delete leaves them.
  static const String foldersDelete = 'folders.delete';

  /// A folder's settings: name, icon, system prompt, default models and
  /// project knowledge, read from the server as its page shows them.
  static const String foldersGet = 'folders.get';

  /// Changes what [FolderUpdate] names; answers with the settings after.
  static const String foldersUpdate = 'folders.update';

  /// What a new chat in the folder starts on: its default models this
  /// server offers. Selects nothing.
  static const String foldersDraftModel = 'folders.draftModel';

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

  /// Creates or updates a public share link, or reads it (and sets who
  /// may open it); `chats.unshare` deletes it.
  static const String chatsShare = 'chats.share';
  static const String chatsUnshare = 'chats.unshare';

  /// A new chat from the start of one to a message in it (Open WebUI's
  /// fork); answers with the new chat's id.
  static const String chatsFork = 'chats.fork';

  /// A chat as a file to save: a JSON backup Open WebUI imports (every
  /// branch), or a Markdown transcript of the branch shown.
  static const String chatsExport = 'chats.export';

  /// Asks the server's model for a title and saves it, unless the chat was
  /// renamed meanwhile.
  static const String chatsGenerateTitle = 'chats.generateTitle';

  /// Marks a chat unread, or read again.
  static const String chatsMarkUnread = 'chats.markUnread';

  /// Makes a temporary chat a normal, stored one (Save Chat); answers with
  /// its new id, and windows showing it hear `route.remap`.
  static const String chatsSaveTemporary = 'chats.saveTemporary';

  // ---------------------------------------------------------------------
  // messages.* -- one message of a chat.
  // ---------------------------------------------------------------------

  /// Deletes messages (with the answers to them), or counts what would go.
  static const String messagesDelete = 'messages.delete';

  // ---------------------------------------------------------------------
  // models.* -- what the active server offers.
  // ---------------------------------------------------------------------

  /// Every model the server offers, and which one is selected.
  static const String modelsList = 'models.list';

  /// Chooses the model new turns use. Persisted with the account, so the
  /// choice survives a restart and agrees with the mobile app.
  static const String modelsSelect = 'models.select';

  /// Pins a model to the top of the picker, or unpins it, in the account's
  /// settings (as mobile's picker does).
  static const String modelsSetPinned = 'models.setPinned';

  /// The picker's extras for one model: reasoning effort (an Ollama
  /// model's thinking level) and Hermes' Fast tier.
  static const String modelsOptions = 'models.options';

  /// Picks a reasoning effort for a model. For an Open WebUI model it is
  /// also saved on the chat, as mobile's picker saves it.
  static const String modelsSetReasoningEffort = 'models.setReasoningEffort';

  /// Turns Hermes' Fast tier on or off.
  static const String modelsSetFastTier = 'models.setFastTier';

  /// One model's controls (Open WebUI's `model_controls`: a coding agent's
  /// reasoning effort or service tier), with the option that applies now.
  static const String modelsControls = 'models.controls';

  /// Picks an option of a model's control, or clears the pick, in the
  /// account's Open WebUI settings.
  static const String modelsSetControl = 'models.setControl';

  // ---------------------------------------------------------------------
  // chatSettings.* -- a chat's own system prompt and parameters (Open
  // WebUI's `chat.params`), as mobile's Chat Settings sheet edits them.
  // ---------------------------------------------------------------------

  /// The form for a chat, or for a new chat's draft.
  static const String chatSettingsGet = 'chatSettings.get';

  /// The form with an edit applied, its errors marked; writes nothing.
  static const String chatSettingsCheck = 'chatSettings.check';

  /// Saves an edit: only what changed is written.
  static const String chatSettingsSave = 'chatSettings.save';

  // ---------------------------------------------------------------------
  // valves.* -- the user's own settings ("personal valves") for the tools,
  // filters and pipe a chat uses.
  // ---------------------------------------------------------------------

  /// What a chat's model, tools and filters offer personal valves for.
  static const String valvesTargets = 'valves.targets';

  /// One tool's or function's personal valves.
  static const String valvesGet = 'valves.get';

  /// Saves them; answers with what the server stored.
  static const String valvesSave = 'valves.save';

  // ---------------------------------------------------------------------
  // access.* -- who may read or write a resource (users and groups). One
  // API for folders now, and notes and Workspace items later.
  // ---------------------------------------------------------------------

  static const String accessGet = 'access.get';

  /// Replaces the named grants; answers with the server's own result.
  static const String accessSet = 'access.set';

  /// Users and groups to grant access to.
  static const String accessPrincipals = 'access.principals';

  /// What the composer may offer: web search, image generation, the
  /// server's tools. Re-asked when the model or the session changes.
  static const String composerOptions = 'composer.options';

  /// Knowledge bases matching what follows a `#` in the composer.
  static const String composerKnowledge = 'composer.knowledge';

  // drafts.*, queue.*, mentions.*, skills.*, context.*, files.* -- what
  // the composer holds and draws on.

  /// The composer's draft for a chat (or a new chat), as the account's
  /// database keeps it.
  static const String draftsGet = 'drafts.get';

  /// Keeps what the composer holds now; an empty text clears it.
  static const String draftsSave = 'drafts.save';

  /// A chat's messages queued behind its running answer.
  static const String queueGet = 'queue.get';

  /// Queues a message behind the running answer.
  static const String queueAdd = 'queue.add';

  /// Replaces a queued message's text.
  static const String queueEdit = 'queue.edit';

  /// Removes a queued message.
  static const String queueRemove = 'queue.remove';

  /// Stops the running answer and sends one queued message at once.
  static const String queueSendNow = 'queue.sendNow';

  /// Lets a queue whose last batch was refused try again.
  static const String queueRetry = 'queue.retry';

  /// The server's users and channels matching what follows an `@`.
  static const String mentionsSearch = 'mentions.search';

  /// The Open WebUI skills matching what follows a `$`.
  static const String skillsSearch = 'skills.search';

  /// Notes, knowledge bases and knowledge files matching what follows a `#`.
  static const String contextSearch = 'context.search';

  /// A web page's readable text or a YouTube video's transcript, as a
  /// context attachment.
  static const String contextFetchUrl = 'context.fetchUrl';

  /// The account's files already on the Open WebUI server, for the
  /// server-file picker.
  static const String filesList = 'files.list';

  /// The account's saved prompts, for the composer's `/` menu.
  static const String promptsList = 'prompts.list';

  /// A prompt's text with its variables filled in. Answers with the fields
  /// still to ask for when the prompt has any and no values were sent.
  static const String promptsRender = 'prompts.render';

  // ---------------------------------------------------------------------
  // direct.* -- connections the app talks to itself, not through Open
  // WebUI.
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

  /// Reads the Open WebUI account's connections again; answers with the
  /// list.
  static const String directReload = 'direct.reload';

  /// What applies to every connection's models: images per request and the
  /// context limits of models that report none.
  static const String directOptions = 'direct.options';

  /// Sets how many of a chat's newest images one request carries.
  static const String directSetImagesPerRequest = 'direct.setImagesPerRequest';

  /// Sets the context limit chats with a model are compacted at.
  static const String directSetContextLimit = 'direct.setContextLimit';

  // ---------------------------------------------------------------------
  // mcp.* -- MCP servers the app talks to itself.
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
  // webSearch.* -- the web search the app runs itself for direct models.
  // ---------------------------------------------------------------------

  /// The engine, safe search and region on-device searches use.
  static const String webSearchGet = 'webSearch.get';

  /// Changes them; answers with all of them.
  static const String webSearchSet = 'webSearch.set';

  // ---------------------------------------------------------------------
  // turns.* -- sending and stopping generation.
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

  /// A message typed while Hermes works: steers the running turn, or goes
  /// as the next message (a Hermes Desktop Gateway).
  static const String turnsSteer = 'turns.steer';

  /// Rates an answer, up or down, as Open WebUI's own client does: an
  /// evaluation record plus the thumb on the message. Gated on
  /// `capabilities.messageRating`.
  static const String turnsRate = 'turns.rate';

  /// Merge Responses: the answers of a Compare Models turn merged into one,
  /// saved on the answer shown; or stops the merge running. The text
  /// arrives as `messages.merge`.
  static const String turnsMerge = 'turns.merge';

  // handoff.* -- a server's suggestion to carry on with another model.

  /// The user's answer to `handoff.requested`.
  static const String handoffAnswer = 'handoff.answer';

  /// Sends a queued answer again now ([QueuedTurnRef]): one waiting for
  /// the connection, or one that stopped retrying. Optionally without the
  /// reasoning effort the provider refused.
  static const String turnsRetryQueued = 'turns.retryQueued';

  /// Removes a queued answer before it goes out: its request, and the
  /// empty answer waiting for it.
  static const String turnsRemoveQueued = 'turns.removeQueued';

  // ---------------------------------------------------------------------
  // chatPrompts.* -- Open WebUI's questions and approvals in a chat.
  // ---------------------------------------------------------------------

  /// The prompt waiting in a chat, if any ([ChatPromptState]): asked over
  /// the live connection, or saved in the chat by the server.
  static const String chatPromptsGet = 'chatPrompts.get';

  /// Answers an `askUser` prompt's questions; the turn goes on.
  static const String chatPromptsAnswer = 'chatPrompts.answer';

  /// Approves or refuses a tool approval or confirmation, or declines an
  /// `askUser` prompt.
  static const String chatPromptsDecide = 'chatPrompts.decide';

  // ---------------------------------------------------------------------
  // mcpApps.* -- MCP Apps in Open WebUI chats, hosted by the daemon.
  // ---------------------------------------------------------------------

  /// Loads an app's page through the server's app RPC and starts its host.
  static const String mcpAppsOpen = 'mcpApps.open';

  /// One message the page posted to its host.
  static const String mcpAppsMessage = 'mcpApps.message';

  /// The app's place changed: the window's appearance, the page's width.
  static const String mcpAppsContext = 'mcpApps.context';

  /// The app's view is going: tells the app, then stops its host.
  static const String mcpAppsClose = 'mcpApps.close';

  // ---------------------------------------------------------------------
  // notifications.* -- what notifies, and how (the phone's Notifications
  // page). The master toggle and sounds mirror to the Open WebUI account.
  // ---------------------------------------------------------------------

  /// The settings ([NotificationSettingsDto]).
  static const String notificationsGet = 'notifications.get';

  /// Changes them ([NotificationSettingsPatch]); replies with all of them.
  static const String notificationsSet = 'notifications.set';

  /// What one notification does ([NotificationRouteParams] →
  /// [NotificationRoute]): the core's gating chain, given what the window
  /// knows (in front, looking at it).
  static const String notificationsRoute = 'notifications.route';

  // ---------------------------------------------------------------------
  // webhooks.* -- the account's webhook destinations on its Open WebUI
  // server (Advanced, `features.webhooks`). Each reply is the [WebhookList].
  // ---------------------------------------------------------------------

  static const String webhooksList = 'webhooks.list';
  static const String webhooksCreate = 'webhooks.create';
  static const String webhooksUpdate = 'webhooks.update';
  static const String webhooksMakeDefault = 'webhooks.makeDefault';

  /// Asks the server to deliver one real test notification.
  static const String webhooksTest = 'webhooks.test';
  static const String webhooksDelete = 'webhooks.delete';

  // ---------------------------------------------------------------------
  // integrations.* -- the account's personal connections: tool servers
  // (OpenAPI) and terminals, kept in its Open WebUI settings. A chat that
  // selects one has the daemon run its tool calls (`execute:tool`).
  // ---------------------------------------------------------------------

  /// The connections ([PersonalConnections]).
  static const String integrationsList = 'integrations.list';

  /// Adds, changes, switches or deletes one ([PersonalConnectionSave]).
  static const String integrationsSave = 'integrations.save';

  /// Reads the OpenAPI document, or checks the terminal, without saving
  /// ([PersonalConnectionTest]).
  static const String integrationsTest = 'integrations.test';

  /// The cleared-selection notice was read.
  static const String integrationsClearNotice = 'integrations.clearNotice';

  // ---------------------------------------------------------------------
  // settings.* -- the app's own preferences.
  // ---------------------------------------------------------------------

  /// Theme, palette and locale, as the daemon has them stored.
  static const String settingsGetApp = 'settings.getApp';

  /// Patches them. Fields left null keep their value.
  static const String settingsSetApp = 'settings.setApp';

  /// Core's `AppSettings` (the Chats, Personalization, Data & Connection,
  /// Audio and Voice Provider settings); `settings.changed` follows them.
  static const String settingsGet = 'settings.get';

  /// Patches them; null fields keep their value, `clear` resets nullable
  /// ones.
  static const String settingsSet = 'settings.set';

  /// The Open WebUI account's own settings kept on its server ("Your system
  /// prompt").
  static const String settingsGetAccount = 'settings.getAccount';
  static const String settingsSetAccount = 'settings.setAccount';

  /// A model's own system prompt on the server (Prompt Overrides).
  static const String settingsModelPrompt = 'settings.modelPrompt';
  static const String settingsSetModelPrompt = 'settings.setModelPrompt';

  /// The quick pills Settings › Chats offers.
  static const String settingsQuickPills = 'settings.quickPills';

  /// The Direct connections the Voice Provider can use.
  static const String settingsVoiceProviders = 'settings.voiceProviders';

  /// About's server rows and Conduit's links.
  static const String settingsAbout = 'settings.about';

  // ---------------------------------------------------------------------
  // profile.* -- the Open WebUI account's profile.
  // ---------------------------------------------------------------------

  static const String profileGet = 'profile.get';

  /// Name, bio, gender and birth date.
  static const String profileUpdate = 'profile.update';

  /// Uses an image file as the photo.
  static const String profileSetImage = 'profile.setImage';

  /// Removes the photo (the initials show).
  static const String profileRemoveImage = 'profile.removeImage';
  static const String profileChangePassword = 'profile.changePassword';

  /// Signs out of every account (Settings' "Sign Out of All Accounts").
  static const String profileSignOutAll = 'profile.signOutAll';

  // ---------------------------------------------------------------------
  // memories.* -- the account's memories on its Open WebUI server.
  // ---------------------------------------------------------------------

  static const String memoriesList = 'memories.list';
  static const String memoriesAdd = 'memories.add';
  static const String memoriesUpdate = 'memories.update';
  static const String memoriesDelete = 'memories.delete';

  /// Deletes every memory.
  static const String memoriesClear = 'memories.clear';

  /// The account's "Memory" setting.
  static const String memoriesSetEnabled = 'memories.setEnabled';

  // ---------------------------------------------------------------------
  // releaseNotes.* -- core's release-notes decision over the app's catalog.
  // ---------------------------------------------------------------------

  /// At launch: whether the after-update banner shows, and its notes. Marks
  /// the version seen.
  static const String releaseNotesCheck = 'releaseNotes.check';

  /// The notes About › Release Notes shows: the newest at or before this
  /// version.
  static const String releaseNotesLatest = 'releaseNotes.latest';

  /// Dismisses the banner for this update.
  static const String releaseNotesDismiss = 'releaseNotes.dismiss';

  // ---------------------------------------------------------------------
  // data.* -- Chat Data Controls and the connection's health.
  // ---------------------------------------------------------------------

  /// What the server-wide actions reach: local-only and unsent chats.
  static const String dataSummary = 'data.summary';

  /// Writes the whole library to a file (Open WebUI-compatible JSON).
  static const String dataExport = 'data.export';

  /// Reads a backup file and counts its chats and messages, sending nothing.
  static const String dataPreviewImport = 'data.previewImport';

  /// Sends a backup file's chats to the server.
  static const String dataImport = 'data.import';

  /// Sends what this computer has that the server lacks, then pulls.
  static const String dataSync = 'data.sync';
  static const String dataArchiveAll = 'data.archiveAll';
  static const String dataUnarchiveAll = 'data.unarchiveAll';
  static const String dataUnshareAll = 'data.unshareAll';
  static const String dataDeleteAll = 'data.deleteAll';

  /// The realtime socket's health; `socket.health` says when it changed.
  static const String dataConnection = 'data.connection';

  /// Reconnects the realtime socket now, rather than at its next scheduled
  /// try (the chat toolbar's Live Updates › Retry); answers its health
  /// after the attempt.
  static const String dataReconnect = 'data.reconnect';

  // ---------------------------------------------------------------------
  // Namespace prefixes.
  // ---------------------------------------------------------------------

  static const String accountsPrefix = 'accounts.';
  static const String serversPrefix = 'servers.';
  static const String authPrefix = 'auth.';
  static const String chatsPrefix = 'chats.';
  static const String foldersPrefix = 'folders.';
  static const String turnsPrefix = 'turns.';
  static const String composerPrefix = 'composer.';
  static const String modelsPrefix = 'models.';
  static const String capabilitiesPrefix = 'capabilities.';
  static const String filesPrefix = 'files.';
  static const String draftsPrefix = 'drafts.';
  static const String queuePrefix = 'queue.';
  static const String mentionsPrefix = 'mentions.';
  static const String skillsPrefix = 'skills.';
  static const String contextPrefix = 'context.';
  static const String knowledgePrefix = 'knowledge.';
  static const String notesPrefix = 'notes.';
  static const String chatPromptsPrefix = 'chatPrompts.';
  static const String mcpAppsPrefix = 'mcpApps.';
  static const String speechPrefix = 'speech.';

  // speech.* -- read aloud. The daemon runs the reading (the core's
  // manager); the window is its voice and its player.

  /// The reading now, with its sentences.
  static const String speechGet = 'speech.get';

  /// Reads an answer aloud, or stops the reading of it (resumes it when
  /// paused): the Read Aloud action.
  static const String speechToggle = 'speech.toggle';

  static const String speechPause = 'speech.pause';
  static const String speechResume = 'speech.resume';
  static const String speechStop = 'speech.stop';

  /// Reads the failed reading again.
  static const String speechRetry = 'speech.retry';

  /// Moves the reading to a sentence, by some sentences, or to a time.
  static const String speechSeek = 'speech.seek';

  /// Settings › Audio's sample, or stops it.
  static const String speechPreview = 'speech.preview';

  /// The window's speech engine answers a `speech.command`, or says what
  /// it did.
  static const String speechReport = 'speech.report';

  static const String callsPrefix = 'calls.';

  // calls.* -- voice calls. The call runs here (the core's voice-mode
  // controller, in its chat's scope); the window is its microphone and,
  // for a realtime voice, its speaker.

  /// The call now.
  static const String callsGet = 'calls.get';

  /// Starts a call in a chat, or in a new one.
  static const String callsStart = 'calls.start';

  /// Ends the call.
  static const String callsEnd = 'calls.end';

  /// Stops listening and speaking until resumed.
  static const String callsPause = 'calls.pause';
  static const String callsResume = 'calls.resume';

  /// Mutes the microphone, or unmutes it.
  static const String callsMute = 'calls.mute';

  /// Stops the answer being said and listens again.
  static const String callsSkip = 'calls.skip';

  /// The window answers a `calls.command`, or says what a listen did.
  static const String callsReport = 'calls.report';
  // calendar.* -- the account's Open WebUI calendars and the agenda over
  // them (core's CalendarAgenda), in the Mac's time zone.
  static const String calendarPrefix = 'calendar.';

  /// The calendars and the agenda for the range, moving or reloading it.
  static const String calendarAgenda = 'calendar.agenda';

  /// Shows or hides a calendar's events; the last shown one stays.
  static const String calendarSetVisible = 'calendar.setVisible';

  /// Makes one of the account's own calendars its default.
  static const String calendarMakeDefault = 'calendar.makeDefault';

  /// Creates a private calendar of the account's own.
  static const String calendarCreateCalendar = 'calendar.createCalendar';

  /// What the event sheet shows of an agenda item.
  static const String calendarEvent = 'calendar.event';

  /// Deletes an event (a recurring event's whole series).
  static const String calendarDeleteEvent = 'calendar.deleteEvent';

  /// The account's own answer to an invitation.
  static const String calendarRespond = 'calendar.respond';

  /// Opens the event editor's draft: a new event, or an item's stored event.
  static const String calendarEditor = 'calendar.editor';

  /// Settles an edited draft (an end moved along with the start) and says
  /// what stops it being saved.
  static const String calendarCheckDraft = 'calendar.checkDraft';

  /// Creates the draft's event, or sends what changed.
  static const String calendarSave = 'calendar.save';

  // automations.* -- the account's Open WebUI scheduled tasks (core's
  // Automations), behind Settings' Advanced as on the phone.
  static const String automationsPrefix = 'automations.';

  /// The tasks, newest first, for a search and a status.
  static const String automationsList = 'automations.list';

  /// The next page of the list.
  static const String automationsLoadMore = 'automations.loadMore';

  /// One task, read from the server.
  static const String automationsGet = 'automations.get';

  /// A page of a task's history.
  static const String automationsRuns = 'automations.runs';

  /// Makes a task active or paused.
  static const String automationsSetActive = 'automations.setActive';

  /// Asks the server to run a task now, then watches its history for the
  /// run (`automations.runProgress`).
  static const String automationsRun = 'automations.run';

  /// Where a task's Run Now stands.
  static const String automationsRunState = 'automations.runState';

  static const String automationsDelete = 'automations.delete';

  /// Opens the task editor's draft and what it can pick.
  static const String automationsEditor = 'automations.editor';

  /// Settles an edited draft's schedule and says what stops it being saved.
  static const String automationsCheckDraft = 'automations.checkDraft';

  /// Creates the draft's task, or replaces the task with it.
  static const String automationsSave = 'automations.save';

  /// The server terminals a task may run with, and the models the editor
  /// offers with the draft's terminal and working folder (its coding
  /// agents among them).
  static const String automationsTerminals = 'automations.terminals';

  static const String applePrefix = 'apple.';

  // apple.* -- Apple's Foundation Models as a Direct backend. The chat runs
  // here (the core's Direct engine and Apple adapter); the window runs the
  // model, which is a Swift API.

  /// Apple Intelligence on this Mac, as Settings shows it.
  static const String appleStatus = 'apple.status';

  /// Asks the Mac again (Settings' Refresh); a model that became able to
  /// answer is listed in the model picker.
  static const String appleRefresh = 'apple.refresh';

  /// The first-run chooser's Apple On-Device row: asks the Mac again, and
  /// when the model answers, Direct is preferred with it (history kept on
  /// this Mac unless a policy was chosen before). Answers with the model as
  /// it is now; anything but available chose nothing.
  static const String appleChoose = 'apple.choose';

  /// The window's engine answers an `apple.command`, or says what a run
  /// did.
  static const String appleReport = 'apple.report';

  static const String locationPrefix = 'location.';

  // location.* -- the Mac's location services, for `{{USER_LOCATION}}`. The
  // daemon decides when to ask (the core's location policy); the window
  // asks CoreLocation.

  /// The window answers a `location.command`.
  static const String locationReport = 'location.report';

  // notes.* -- listed with the prefixes because they are few.

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

  /// Attaches an uploaded file -- a recording, a document -- to a note.
  static const String notesAttach = 'notes.attach';

  /// Takes a file off a note; the file itself stays on the server.
  static const String notesDetach = 'notes.detach';

  /// A note's recordings that are not attached yet; starts uploading the
  /// ones waiting when the server can be reached.
  static const String notesRecordings = 'notes.recordings';

  /// Keeps a recording the window made, then uploads it and attaches it to
  /// the note, surviving a lost connection and a relaunch.
  static const String notesAddRecording = 'notes.addRecording';

  /// Tries a waiting recording's upload again.
  static const String notesRetryRecording = 'notes.retryRecording';

  /// Deletes a recording that is not attached yet.
  static const String notesRemoveRecording = 'notes.removeRecording';
  static const String channelsPrefix = 'channels.';

  // channels.*.

  /// Every channel the user can see, with unread counts.
  static const String channelsList = 'channels.list';

  /// Creates or changes a channel; answers with the list.
  static const String channelsSave = 'channels.save';

  static const String channelsDelete = 'channels.delete';

  /// Leaves a channel one is a member of; it stays for the others.
  static const String channelsLeave = 'channels.leave';

  /// A channel's messages or one thread's, newest first. Asking for a
  /// channel's also starts listening to it, so the window hears
  /// `channels.message` and `channels.typing` for it.
  static const String channelsMessages = 'channels.messages';

  static const String channelsPost = 'channels.post';
  static const String channelsEditMessage = 'channels.editMessage';
  static const String channelsDeleteMessage = 'channels.deleteMessage';
  static const String channelsReact = 'channels.react';
  static const String channelsPin = 'channels.pin';

  /// Says the user is typing, or has stopped.
  static const String channelsTyping = 'channels.typing';

  /// Clears a channel's unread count, here and on the server.
  static const String channelsMarkRead = 'channels.markRead';

  /// Who is in a channel, for `@` mentions.
  static const String channelsMembers = 'channels.members';

  /// Opens a channel's pane: the channel as it shows there, and what the
  /// user may do to its members. Marks it read and starts listening to it.
  static const String channelsOpen = 'channels.open';

  /// The channel in front of the user now, or none: its new messages are
  /// read as they come, and it neither counts as unread nor notifies.
  static const String channelsFocus = 'channels.focus';

  /// Notifies for every message, or (muted) for mentions only.
  static const String channelsSetMuted = 'channels.setMuted';

  /// The channel's members matching what follows an `@`.
  static const String channelsMentions = 'channels.mentions';

  /// The members sheet: a page of members, by name, for a search.
  static const String channelsMemberPage = 'channels.memberPage';
  static const String channelsAddMembers = 'channels.addMembers';
  static const String channelsRemoveMember = 'channels.removeMember';

  /// Presses a button on an app's message.
  static const String channelsAppAction = 'channels.appAction';
  static const String workspacePrefix = 'workspace.';

  // workspace.*: models, knowledge, prompts, tools and skills. Most
  // methods take a [WorkspaceKind]; the rest belong to one section.

  /// Which sections the user may manage, and what each allows.
  static const String workspaceCapabilities = 'workspace.capabilities';

  /// A section's items, a page at a time.
  static const String workspaceList = 'workspace.list';

  /// One item, everything its editor shows.
  static const String workspaceGet = 'workspace.get';

  /// Creates or replaces an item; answers with it as saved.
  static const String workspaceSave = 'workspace.save';
  static const String workspaceDelete = 'workspace.delete';

  /// Switches a model, prompt or skill on or off; answers with it.
  static const String workspaceToggle = 'workspace.toggle';

  /// Replaces who may read and write an item.
  static const String workspaceSetAccess = 'workspace.setAccess';

  /// Users and groups to grant access to.
  static const String workspacePrincipals = 'workspace.principals';
  static const String workspaceExport = 'workspace.export';
  static const String workspaceImport = 'workspace.import';

  /// What the model editor's pickers offer.
  static const String workspaceModelOptions = 'workspace.modelOptions';

  /// A prompt's saved versions, newest first.
  static const String workspacePromptHistory = 'workspace.promptHistory';

  /// How a version differs from another.
  static const String workspacePromptDiff = 'workspace.promptDiff';

  /// Puts a saved version of a prompt in production.
  static const String workspacePromptSetVersion = 'workspace.promptSetVersion';
  static const String workspacePromptDeleteVersion =
      'workspace.promptDeleteVersion';

  /// A tool's valves, or the user's own for it.
  static const String workspaceValves = 'workspace.valves';
  static const String workspaceSaveValves = 'workspace.saveValves';

  /// Reads a tool from a URL -- GitHub links become raw ones -- without
  /// saving it; the editor fills in from the answer.
  static const String workspaceToolFromUrl = 'workspace.toolFromUrl';

  /// One folder of a knowledge base.
  static const String workspaceFiles = 'workspace.files';

  /// Puts uploaded files into a knowledge base.
  static const String workspaceAttachFiles = 'workspace.attachFiles';

  /// Renames, moves, re-reads, removes or deletes a knowledge file.
  static const String workspaceFileAction = 'workspace.fileAction';

  /// Creates, renames or deletes a knowledge folder.
  static const String workspaceDirectoryAction = 'workspace.directoryAction';

  /// Empties a knowledge base.
  static const String workspaceKnowledgeReset = 'workspace.knowledgeReset';

  /// Takes the files that failed to be read in out of a knowledge base.
  static const String workspaceKnowledgeCleanup = 'workspace.knowledgeCleanup';

  /// Makes a copy of an item on the server and answers with it.
  static const String workspaceDuplicate = 'workspace.duplicate';

  /// Puts a text file made from typed text into a knowledge base.
  static const String workspaceAddText = 'workspace.addText';

  /// Reads a skill from a Markdown file (front-matter name, id and
  /// description, the file as instructions), not saved.
  static const String workspaceSkillFromMarkdown =
      'workspace.skillFromMarkdown';
  static const String directPrefix = 'direct.';
  static const String mcpPrefix = 'mcp.';
  static const String webSearchPrefix = 'webSearch.';
  static const String hermesPrefix = 'hermes.';

  // hermes.*: the Hermes Agent connection, its sessions -- chats with
  // `local:hermes_<id>` ids, sent to through turns.* -- jobs and catalog.

  static const String hermesSettings = 'hermes.settings';
  static const String hermesSaveSettings = 'hermes.saveSettings';

  /// Tries a connection without saving it.
  static const String hermesTest = 'hermes.test';

  /// Reachability, capabilities and the server's health.
  static const String hermesStatus = 'hermes.status';

  /// Signs in to a desktop gateway in the system browser (native PKCE).
  static const String hermesSignIn = 'hermes.signIn';
  static const String hermesSignOut = 'hermes.signOut';
  static const String hermesSessions = 'hermes.sessions';
  static const String hermesRenameSession = 'hermes.renameSession';
  static const String hermesDeleteSession = 'hermes.deleteSession';

  /// A copy of a session to go on from; answers with the new one.
  static const String hermesForkSession = 'hermes.forkSession';

  /// Pins, archives or hides a session, or undoes it; answers with the
  /// sessions.
  static const String hermesSessionsUpdate = 'hermes.sessions.update';

  /// Continues a read-only session's chat in a session this app owns:
  /// Hermes's fork (Continue Here) or a copy; answers with the session to
  /// open.
  static const String hermesSessionsContinue = 'hermes.sessions.continue';

  /// The sessions hidden from every list (Hidden Chats).
  static const String hermesHiddenList = 'hermes.hidden.list';

  /// Branch from Here: a new session with a Hermes chat up to a reply;
  /// answers with the session to open.
  static const String hermesHistoryBranch = 'hermes.history.branch';

  /// Undo Last Turn of a Desktop Gateway chat, there and in the chat.
  static const String hermesHistoryUndo = 'hermes.history.undo';
  static const String hermesJobs = 'hermes.jobs';

  /// Creates or edits a scheduled agent; answers with the jobs.
  static const String hermesSaveJob = 'hermes.saveJob';
  static const String hermesSetJobEnabled = 'hermes.setJobEnabled';

  /// Runs a job now, whatever its schedule.
  static const String hermesRunJob = 'hermes.runJob';
  static const String hermesDeleteJob = 'hermes.deleteJob';

  /// The agent's skills and toolsets, and a Hermes chat's `/` commands.
  static const String hermesCatalog = 'hermes.catalog';

  /// The sessions a scheduled agent's runs wrote, newest first (a Desktop
  /// Gateway's).
  static const String hermesJobsRuns = 'hermes.jobs.runs';

  /// Stops a scheduled agent's running run (its schedule stays); answers
  /// with the jobs, and how the Stop settles comes in their notices.
  static const String hermesJobsStop = 'hermes.jobs.stop';

  /// Where the connection's scheduled agents can deliver.
  static const String hermesJobsDelivery = 'hermes.jobs.delivery';

  // hermes.connections.*: Hermes's switch and its saved connections.

  static const String hermesConnectionsList = 'hermes.connections.list';

  /// Saves a connection, new or edited; the first one saved is put in use.
  static const String hermesConnectionsSave = 'hermes.connections.save';

  /// Tries a connection's form without saving it.
  static const String hermesConnectionsTest = 'hermes.connections.test';

  /// Puts a saved connection in use: Hermes's sessions, jobs and servers
  /// follow it.
  static const String hermesConnectionsActivate = 'hermes.connections.activate';

  /// Deletes a saved connection and its credentials; deleting the one in
  /// use puts the most recently used other one in use.
  static const String hermesConnectionsDelete = 'hermes.connections.delete';

  /// Turns Hermes on or off, its connections kept.
  static const String hermesConnectionsSetEnabled =
      'hermes.connections.setEnabled';

  /// The profiles a Desktop Gateway offers a connection's form (sent with
  /// the form's credentials, as the phone's Refresh Profiles).
  static const String hermesConnectionsProfiles = 'hermes.connections.profiles';

  // hermes.toolsets.*, hermes.skills.*: the agent's tools and skills.

  /// Turns a toolset on or off for new sessions (a Desktop Gateway).
  static const String hermesToolsetsSet = 'hermes.toolsets.set';

  /// Has a Desktop Gateway read its skills again; answers the catalog.
  static const String hermesSkillsReload = 'hermes.skills.reload';

  // hermes.dashboard.*: a Desktop Gateway's dashboard sign-in, run in the
  // window's browser window and kept by the daemon.

  /// Where a connection's dashboard sign-in opens.
  static const String hermesDashboardStart = 'hermes.dashboard.start';

  /// Hands over the cookies of a page the sign-in window loaded; kept when
  /// the dashboard accepts them as a signed-in session.
  static const String hermesDashboardComplete = 'hermes.dashboard.complete';

  /// The sign-in window closed: its sign-in keeps nothing it has not kept
  /// already.
  static const String hermesDashboardCancel = 'hermes.dashboard.cancel';

  // hermes.mcp.*: the MCP servers a Desktop Gateway connects its agent to.

  static const String hermesMcpList = 'hermes.mcp.list';

  /// The ready-made servers Hermes offers.
  static const String hermesMcpCatalog = 'hermes.mcp.catalog';

  /// Adds a server of the user's own (an HTTP address or a command).
  static const String hermesMcpAdd = 'hermes.mcp.add';

  /// Adds a server from Hermes's catalog, by its name there.
  static const String hermesMcpAddFromCatalog = 'hermes.mcp.addFromCatalog';
  static const String hermesMcpSetApiKey = 'hermes.mcp.setApiKey';
  static const String hermesMcpRemove = 'hermes.mcp.remove';

  /// Connects to a server once and lists what it offers.
  static const String hermesMcpTest = 'hermes.mcp.test';

  /// Offers a server's tools to the agent, or stops offering them.
  static const String hermesMcpSetEnabled = 'hermes.mcp.setEnabled';

  /// Signs in to a server with OAuth in the browser; answers once it is
  /// done (or after two minutes).
  static const String hermesMcpAuthenticate = 'hermes.mcp.authenticate';

  // hermes.work.*, hermes.context.*, hermes.decisions.*: what a Hermes
  // chat's agent is doing, its context window, and what it asks.

  /// Follows a chat's agent work (subagents, processes, plan) while the
  /// window shows it; changes come as `hermes.work.changed`.
  static const String hermesWorkWatch = 'hermes.work.watch';
  static const String hermesWorkUnwatch = 'hermes.work.unwatch';

  /// New instructions for a running subagent.
  static const String hermesWorkSteer = 'hermes.work.steer';

  /// Stops a subagent.
  static const String hermesWorkStop = 'hermes.work.stop';

  /// Kills a background process.
  static const String hermesWorkKill = 'hermes.work.kill';

  /// A Hermes chat's context window, token totals and plan usage.
  static const String hermesContextGet = 'hermes.context.get';

  /// Summarizes a Hermes chat's older messages on the server.
  static const String hermesContextCompact = 'hermes.context.compact';

  /// Answers a clarify form, a sudo password, a secret or a set-up card,
  /// and waits for Hermes to take it.
  static const String hermesDecisionsAnswer = 'hermes.decisions.answer';

  // hermes.bots.*: Bot Mode. A bot is a Hermes profile with a face and one
  // permanent Bot Chat.

  /// The gateway's bots, most recently active first.
  static const String hermesBotsList = 'hermes.bots.list';

  /// A bot's picture, as a `data:image/...` URL.
  static const String hermesBotsAvatar = 'hermes.bots.avatar';

  /// Opens a bot's Bot Chat (made when it has none); answers with its
  /// session, opened as a chat.
  static const String hermesBotsOpen = 'hermes.bots.open';

  // hermes.rooms.*: Group Chats, two to six bots talking together on a
  // Desktop Gateway.

  /// The gateway's Group Chats, and whether a new one can be made.
  static const String hermesRoomsList = 'hermes.rooms.list';
  static const String hermesRoomsCreate = 'hermes.rooms.create';

  /// Follows an open room, read every 2 s while a window watches it;
  /// changes come as `hermes.rooms.changed`.
  static const String hermesRoomsWatch = 'hermes.rooms.watch';
  static const String hermesRoomsUnwatch = 'hermes.rooms.unwatch';

  /// Posts a message in a room.
  static const String hermesRoomsSend = 'hermes.rooms.send';

  /// Stops the room's work.
  static const String hermesRoomsStop = 'hermes.rooms.stop';

  /// Continues a discussion that paused at its limit.
  static const String hermesRoomsContinue = 'hermes.rooms.continue';

  /// Answers an approval in a room, or retries uncertain work.
  static const String hermesRoomsAnswer = 'hermes.rooms.answer';
  static const String hermesRoomsRename = 'hermes.rooms.rename';

  /// Saves a room's purpose, notes and who answers.
  static const String hermesRoomsSaveContext = 'hermes.rooms.saveContext';

  /// Ends a room for good.
  static const String hermesRoomsDisband = 'hermes.rooms.disband';
  static const String terminalPrefix = 'terminal.';

  // terminal.*. The shell itself is `WS /terminal/{handle}`.

  /// The terminal servers usable in a scope, and the selected one.
  static const String terminalServers = 'terminal.servers';

  /// Selects the terminal chats use and the page opens.
  static const String terminalSelect = 'terminal.select';

  /// A handle for one server in one scope: the shell, files and ports.
  static const String terminalAttach = 'terminal.attach';

  /// One directory; also where the shell's `cd` starts next.
  static const String terminalList = 'terminal.list';

  /// A file as text or bytes, for a preview.
  static const String terminalRead = 'terminal.read';

  /// A file's bytes, to save.
  static const String terminalDownload = 'terminal.download';

  /// Makes a folder, deletes, or moves (renames).
  static const String terminalFileAction = 'terminal.fileAction';
  static const String terminalPorts = 'terminal.ports';

  /// An address the system browser can open to see a port.
  static const String terminalPreviewPort = 'terminal.previewPort';

  /// Keeps a directory's listing and the ports live (`terminal.changed`).
  static const String terminalWatch = 'terminal.watch';

  /// Lets a handle go: its watch, its port previews.
  static const String terminalDetach = 'terminal.detach';
  static const String computerPrefix = 'computer.';

  // computer.*. The viewer page streams from a relay on this computer
  // (`ComputerView.streamUrl`); the daemon holds the credentials.

  /// Whether a chat's header offers Computer, and which surfaces.
  static const String computerStatus = 'computer.status';

  /// A view of a chat terminal's desktop or browser.
  static const String computerOpen = 'computer.open';

  /// The terminal browser's tabs.
  static const String computerTabs = 'computer.tabs';
  static const String computerCloseTab = 'computer.closeTab';

  /// A key combination for the surface a view shows.
  static const String computerShortcut = 'computer.shortcut';

  /// Ends a view: its relay closes.
  static const String computerClose = 'computer.close';
  static const String voicePrefix = 'voice.';

  // voice.*. Audio stays in the window; recordings reach the server
  // through `POST /transcribe`, and speech comes back from `GET /tts/{jobId}`.

  static const String voiceSettings = 'voice.settings';
  static const String voiceSaveSettings = 'voice.saveSettings';

  /// The server's voices.
  static const String voiceVoices = 'voice.voices';

  /// Starts a server speech job for an `<audio>` element to play.
  static const String voiceSpeak = 'voice.speak';

  /// The whisper models for transcribing on this computer.
  static const String voiceModels = 'voice.models';

  /// Starts downloading a model; `voice.changed` reports its progress.
  static const String voiceDownloadModel = 'voice.downloadModel';

  /// Deletes a downloaded model, or stops its download.
  static const String voiceDeleteModel = 'voice.deleteModel';
  static const String dictationPrefix = 'dictation.';

  // dictation.*. The window listens and records; what it heard reaches the
  // backend through `POST /transcribe`.

  /// Which engine dictates now, and what the target's backend can do.
  static const String dictationStatus = 'dictation.status';
  static const String recordingsPrefix = 'recordings.';

  // recordings.*. A dictation's audio, kept with the unsent draft in the
  // account's database so a crash or a relaunch loses none of it.

  /// A draft's saved recordings.
  static const String recordingsList = 'recordings.list';

  /// Starts a recording for a draft.
  static const String recordingsBegin = 'recordings.begin';

  /// Stores the next audio of an open recording.
  static const String recordingsAppend = 'recordings.append';

  /// Ends an open recording; one with no audio is not kept.
  static const String recordingsClose = 'recordings.close';

  /// Deletes a saved recording.
  static const String recordingsDiscard = 'recordings.discard';

  /// A saved recording, as text: by the model's backend or by whisper.
  static const String recordingsTranscribe = 'recordings.transcribe';
  static const String librechatPrefix = 'librechat.';

  // librechat.* -- LibreChat accounts (signing in; the list and switching
  // are `accounts.*`), and what only LibreChat has: its composer tools,
  // memories and Duplicate.

  /// Checks an address for a LibreChat server and how to sign in there.
  static const String librechatProbe = 'librechat.probe';

  /// Signs in with an email (or LDAP username) and password.
  static const String librechatSignIn = 'librechat.signIn';

  /// The second step: an authenticator code or a backup code.
  static const String librechatVerify = 'librechat.verify';

  /// Where single sign-on starts, for the window's sign-in browser.
  static const String librechatSsoStart = 'librechat.ssoStart';

  /// Finishes single sign-on with the cookies the window captured.
  static const String librechatCompleteSso = 'librechat.completeSso';

  /// The tools the composer may offer a LibreChat turn.
  static const String librechatComposer = 'librechat.composer';

  /// The user's memories and whether the assistant uses them.
  static const String librechatMemoriesList = 'librechat.memories.list';

  /// Adds a memory, or changes one (and its key).
  static const String librechatMemoriesSave = 'librechat.memories.save';
  static const String librechatMemoriesDelete = 'librechat.memories.delete';

  /// Turns the assistant's use of memories on or off.
  static const String librechatMemoriesSetEnabled =
      'librechat.memories.setEnabled';

  /// Copies a LibreChat chat whole into a new chat on its server.
  static const String librechatDuplicate = 'librechat.duplicate';
  static const String intentsPrefix = 'intents.';

  // intents.*. Shortcuts and App Intents on the Mac: the app's intents ask
  // through these, and the daemon does the work.

  /// A question whose answer comes back in the reply (Ask Conduit): sends
  /// it as a new chat and waits for the answer, up to a timeout.
  static const String intentsAsk = 'intents.ask';

  /// The chats Shortcuts offers (Open Chat): by id, by search, or recent.
  static const String intentsChats = 'intents.chats';

  /// What the server reads from a link (Send Link to Conduit): a web
  /// page's text or a YouTube video's transcript, for a new chat.
  static const String intentsSendLink = 'intents.sendLink';
  static const String settingsPrefix = 'settings.';
  static const String syncPrefix = 'sync.';
  static const String socketPrefix = 'socket.';
  static const String profilePrefix = 'profile.';
  static const String memoriesPrefix = 'memories.';
  static const String releaseNotesPrefix = 'releaseNotes.';
  static const String dataPrefix = 'data.';
  static const String chatSettingsPrefix = 'chatSettings.';
  static const String valvesPrefix = 'valves.';
  static const String accessPrefix = 'access.';
  static const String messagesPrefix = 'messages.';
  static const String handoffPrefix = 'handoff.';
  static const String notificationsPrefix = 'notifications.';
  static const String webhooksPrefix = 'webhooks.';
  static const String integrationsPrefix = 'integrations.';

  /// Every namespace the protocol reserves. A method outside these prefixes
  /// is a typo, and the daemon's fallback handler says so.
  static const Set<String> reservedPrefixes = {
    'system.',
    'events.',
    'ui.',
    accountsPrefix,
    serversPrefix,
    authPrefix,
    chatsPrefix,
    foldersPrefix,
    turnsPrefix,
    composerPrefix,
    modelsPrefix,
    capabilitiesPrefix,
    filesPrefix,
    draftsPrefix,
    queuePrefix,
    mentionsPrefix,
    skillsPrefix,
    contextPrefix,
    knowledgePrefix,
    notesPrefix,
    channelsPrefix,
    workspacePrefix,
    directPrefix,
    mcpPrefix,
    hermesPrefix,
    terminalPrefix,
    computerPrefix,
    voicePrefix,
    dictationPrefix,
    recordingsPrefix,
    librechatPrefix,
    intentsPrefix,
    settingsPrefix,
    syncPrefix,
    socketPrefix,
    profilePrefix,
    memoriesPrefix,
    releaseNotesPrefix,
    dataPrefix,
    chatSettingsPrefix,
    valvesPrefix,
    accessPrefix,
    messagesPrefix,
    handoffPrefix,
    notificationsPrefix,
    webhooksPrefix,
    integrationsPrefix,
    chatPromptsPrefix,
    mcpAppsPrefix,
    speechPrefix,
    calendarPrefix,
    automationsPrefix,
    applePrefix,
    locationPrefix,
  };

  /// Whether [method] sits in a namespace this protocol version defines.
  static bool isReserved(String method) =>
      reservedPrefixes.any(method.startsWith);
}

/// HTTP paths served next to the RPC socket, for payloads that do not belong
/// in JSON-RPC frames.
abstract final class ConduitHttpRoutes {
  /// `POST` multipart; streamed straight to the attachment queue so a 2 GB
  /// file never lands in a JSON string.
  static const String upload = '/upload';

  /// `GET /files/{serverId}/{fileId}` — proxied with the server's auth, TLS
  /// policy, and cookie jar applied, so `<img src>` works without the
  /// renderer ever holding a credential.
  static String file(String serverId, String fileId) =>
      '/files/$serverId/$fileId';

  /// `GET /files/{serverId}/models/{modelId}` -- a model's profile image
  /// ([WorkspaceImageSource.server]), asked of the server with the
  /// account's credential: the image the model keeps, or a picture at an
  /// address on the server itself. 404 when it has none (the window draws
  /// the model's initial); never an address on another site.
  static String modelImage(String serverId, String modelId) =>
      '/files/$serverId/models/${Uri.encodeComponent(modelId)}';

  /// `GET /tts/{jobId}` — audio for an `<audio>` element.
  static String tts(String jobId) => '/tts/$jobId';

  /// `POST` a recording as the body, its type as `content-type`: its
  /// transcription as a `VoiceTranscript`, by the active server or, with
  /// the local engine, by whisper on this computer -- which takes 16 kHz
  /// mono WAV only. The saved language applies.
  ///
  /// Query: `engine` (`server` or `local`; the saved one when absent) and
  /// `model` (a model id: its backend transcribes on the server -- an Open
  /// WebUI server, the Voice Provider, a Hermes gateway or a LibreChat
  /// server; the account's server when absent).
  static const String transcribe = '/transcribe';

  /// `GET /recordings/{id}?chatId=&folderId=` -- a saved recording
  /// (`recordings.*`) as 16 kHz mono WAV, for Export and for transcribing
  /// it on this computer.
  ///
  /// `GET /recordings/{id}?noteId=` -- one of a note's recordings still
  /// waiting to go to the server (`notes.recordings`), as it was recorded
  /// (its type as `content-type`), for playing it.
  static String recording(String id) => '/recordings/$id';

  /// `WS /terminal/{handle}` — raw byte tunnel to the Open WebUI terminal
  /// socket with auth added.
  static String terminal(String handle) => '/terminal/$handle';

  /// `POST` with the headers `x-conduit-terminal` (a handle) and
  /// `x-conduit-directory`: an upload into a terminal's files rather than
  /// to Open WebUI. Same body as [upload].
  static const String terminalUpload = '/terminal-upload';

  /// `GET /media/image?url=` and `GET /media/pdf?url=` -- a picture or a
  /// PDF an answer links to on another site, fetched for the window: no
  /// cookies or credentials, no `Referer`, never retried, and refused past
  /// a size or a time limit, or when the bytes are not what was asked for.
  static const String media = '/media';

  /// The JSON-RPC WebSocket itself.
  static const String rpc = '/rpc';
}
