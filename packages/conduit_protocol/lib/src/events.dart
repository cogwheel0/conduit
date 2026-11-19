import 'package:freezed_annotation/freezed_annotation.dart';

part 'events.freezed.dart';
part 'events.g.dart';

/// Names of the notifications the daemon pushes to the UI.
///
/// Notifications are one-way JSON-RPC messages carrying an [EventEnvelope] as
/// their single positional-free parameter map.
abstract final class ConduitEvents {
  // Turn lifecycle. `delta` is coalesced to at most 60 Hz by the daemon so a
  // fast server cannot outrun the renderer's frame budget.
  static const String turnStarted = 'turn.started';
  static const String turnDelta = 'turn.delta';

  /// The answer so far, parsed into blocks ([TurnBlocks]): files, status,
  /// text, reasoning, tool calls, code, error, sources, follow-ups. Parsing
  /// happens once, in the daemon; the UI only renders plain markdown.
  static const String turnBlocks = 'turn.blocks';
  static const String turnCompleted = 'turn.completed';
  static const String turnFailed = 'turn.failed';

  /// An answer ended, in any chat ([TurnFinished]); unscoped, for
  /// notifications about chats no window shows.
  static const String turnFinished = 'turn.finished';

  static const String chatsChanged = 'chats.changed';

  /// The saved accounts, or which one is active, changed: an account was
  /// added, switched to, signed in to or removed, from any window. Payload
  /// [AccountsChanged].
  static const String accountsChanged = 'accounts.changed';

  /// A saved server's name or addresses changed, or which address is in
  /// use. Payload [ServersChanged].
  static const String serversChanged = 'servers.changed';
  static const String notesChanged = 'notes.changed';
  static const String channelsMessage = 'channels.message';

  /// Who is typing in a channel changed. Payload
  /// [ChannelTypingUsers], scoped to `channel:<id>`.
  static const String channelsTyping = 'channels.typing';

  /// The channel list changed: a channel added, removed, renamed, or a new
  /// unread count. No payload.
  static const String channelsChanged = 'channels.changed';

  /// An app answered the user alone, under one of a channel's messages.
  /// Payload [ChannelAppReplyEvent], scoped to `channel:<id>`.
  static const String channelsAppReply = 'channels.appReply';

  /// Someone else posted in a channel that is not in front of the user.
  /// Payload [ChannelPosted], unscoped (for notifications).
  static const String channelsPosted = 'channels.posted';

  static const String syncStatus = 'sync.status';

  /// The realtime socket's health changed (connected, transport, latency,
  /// reconnects). No payload; `data.connection` says what it is now.
  static const String socketHealth = 'socket.health';

  /// Core's `AppSettings` changed, from any window or the daemon itself.
  /// No payload; `settings.get` says what they are now.
  static const String settingsChanged = 'settings.changed';

  /// The notification settings changed (`notifications.get` says how), from
  /// any window, the server's mirror or the daemon itself. No payload.
  static const String notificationsChanged = 'notifications.changed';

  /// An Open WebUI answer this Mac did not run finished (another device, a
  /// scheduled task): the window notifies as for its own (`AnswerNotice`).
  static const String notificationsAnswered = 'notifications.answered';

  /// Ask the shell to raise an OS notification.
  static const String notifyShow = 'notify.show';

  /// A chat ID was remapped after sync; the UI must rewrite its route
  /// without pushing a history entry.
  static const String routeRemap = 'route.remap';

  /// The core needs an answer from the user: tool approval, an Open WebUI
  /// input prompt, an MCP approval, a Hermes decision. Answered with
  /// `ui.respond`.
  static const String uiRequest = 'ui.request';

  /// A `ui.request` has been answered or has run out of time. Payload is
  /// `{requestId}`. Windows that did not answer close their card, so no
  /// window offers a choice that no longer counts.
  static const String uiSettled = 'ui.settled';

  /// Emitted when [Capabilities] change — a server switch, a sign-in, the
  /// Apple helper becoming available.
  static const String capabilitiesChanged = 'capabilities.changed';

  /// The models on offer changed: a direct connection was added and its
  /// models discovered, or the server's list was refreshed. Also when the
  /// model the next turn runs with changed (a new Default Model, say). No
  /// payload; `models.list` says what they are.
  static const String modelsChanged = 'models.changed';

  /// The daemon needs a page opened in the system browser: an MCP
  /// server's OAuth sign-in. Payload [OpenUrl]. The first window to hear it
  /// opens it.
  static const String openUrl = 'shell.openUrl';

  /// A workspace section's items changed. Payload [WorkspaceChanged].
  static const String workspaceChanged = 'workspace.changed';

  /// Hermes's settings, sessions or jobs changed. No payload.
  static const String hermesChanged = 'hermes.changed';

  /// The active account's session changed in a way the account list does
  /// not show: a second step began or moved on, or a kept session became a
  /// connection issue (a sign-in proxy turning it away). No payload; ask
  /// `auth.status` again.
  static const String authChanged = 'auth.changed';

  /// The whisper models changed: a download moved, finished or failed, or
  /// one was deleted. Payload [VoiceModels].
  static const String voiceChanged = 'voice.changed';

  /// A model's tool asked to show a file from the chat's terminal. Payload
  /// [TerminalDisplayFile], scoped to the chat.
  static const String terminalDisplayFile = 'terminal.displayFile';

  /// A watched terminal's directory or ports changed (`terminal.watch`).
  /// Payload [TerminalChanged]; unscoped, named by its handle.
  static const String terminalChanged = 'terminal.changed';

  /// A chat's queued messages changed. Payload [QueueState], scoped to the
  /// chat.
  static const String queueChanged = 'queue.changed';

  /// A merged response so far (Merge Responses). Payload [MergeProgress],
  /// scoped to the chat.
  static const String messagesMerge = 'messages.merge';

  /// The server suggests carrying on in a new chat with another model.
  /// Payload [HandoffRequest]; answered with `handoff.answer`.
  static const String handoffRequested = 'handoff.requested';

  /// A `handoff.requested` was answered or ran out of time. Payload
  /// [HandoffSettled].
  static const String handoffSettled = 'handoff.settled';

  /// The Open WebUI prompt waiting in a chat came or went. Payload
  /// [ChatPromptState], scoped to the chat.
  static const String chatPromptsChanged = 'chatPrompts.changed';

  /// An MCP App's host has something for its view: a message for the
  /// page, a new height, a start or an end. Payload [McpAppEvent], scoped
  /// to the app's chat.
  static const String mcpAppsEvent = 'mcpApps.event';

  /// The reading moved on: a word, a sentence, a pause, an end. Payload
  /// [SpeechProgress]; a new `reading` means new sentences (`speech.get`).
  static const String speechChanged = 'speech.changed';

  /// The daemon asks the window's speech engine to speak or play. Payload
  /// [SpeechCommand]; answered with `speech.report`.
  static const String speechCommand = 'speech.command';

  /// A watched Hermes chat's agent work changed: its subagents, processes,
  /// plan or the output a window reads. Payload [HermesWork], scoped to the
  /// chat.
  static const String hermesWorkChanged = 'hermes.work.changed';

  /// A watched Group Chat changed: its log, its bots' state, what it waits
  /// on. Payload [HermesRoomView], scoped to `hermes-room:<roomId>`.
  static const String hermesRoomsChanged = 'hermes.rooms.changed';

  /// The Group Chats listed changed: one was made, renamed or disbanded,
  /// or one had news. Payload [HermesRooms].
  static const String hermesRoomsListChanged = 'hermes.rooms.listChanged';
  /// The voice call changed: its phase, words, meter or error. Payload
  /// [CallState].
  static const String callsChanged = 'calls.changed';

  /// The daemon asks the window to listen, or to open the realtime audio,
  /// for the call. Payload [CallCommand]; answered with `calls.report`.
  static const String callsCommand = 'calls.command';
  /// The calendars or the agenda changed: `calendar.agenda` again. No
  /// payload.
  static const String calendarChanged = 'calendar.changed';

  /// The scheduled tasks changed: `automations.list` again (and the open
  /// task). No payload.
  static const String automationsChanged = 'automations.changed';

  /// A Run Now moved on. Payload [AutomationRunProgress].
  static const String automationsRunProgress = 'automations.runProgress';

  /// The daemon asks the window's Foundation Models engine for a model's
  /// status, to start or stop a run, or answers a tool call. Payload
  /// [AppleCommand]; answered with `apple.report`.
  static const String appleCommand = 'apple.command';

  /// The daemon asks the window's location services whether they are on, for
  /// permission, or for a position fix (`{{USER_LOCATION}}`). Payload
  /// [LocationCommand]; answered with `location.report`.
  static const String locationCommand = 'location.command';

  /// The core gives a chat's composer words to insert at the caret.
  /// Payload [ComposerInsertText], scoped to the chat.
  static const String composerInsertText = 'composer.insertText';

  /// Every event name, for subscription validation and tests.
  static const Set<String> all = {
    turnStarted,
    turnDelta,
    turnBlocks,
    turnCompleted,
    turnFailed,
    turnFinished,
    chatsChanged,
    accountsChanged,
    serversChanged,
    notesChanged,
    channelsMessage,
    channelsTyping,
    channelsChanged,
    channelsAppReply,
    channelsPosted,
    syncStatus,
    socketHealth,
    notifyShow,
    routeRemap,
    uiRequest,
    uiSettled,
    capabilitiesChanged,
    modelsChanged,
    openUrl,
    workspaceChanged,
    hermesChanged,
    authChanged,
    voiceChanged,
    terminalDisplayFile,
    terminalChanged,
    settingsChanged,
    notificationsChanged,
    notificationsAnswered,
    queueChanged,
    messagesMerge,
    handoffRequested,
    handoffSettled,
    chatPromptsChanged,
    mcpAppsEvent,
    speechChanged,
    speechCommand,
    hermesWorkChanged,
    callsChanged,
    callsCommand,
    calendarChanged,
    automationsChanged,
    automationsRunProgress,
    hermesRoomsChanged,
    hermesRoomsListChanged,
    appleCommand,
    locationCommand,
    composerInsertText,
  };
}

/// Wrapper around every notification payload.
///
/// One envelope shape for all events means the client can dispatch, order, and
/// gap-detect without knowing any individual event's schema.
@freezed
abstract class EventEnvelope with _$EventEnvelope {
  const factory EventEnvelope({
    /// One of [ConduitEvents].
    required String event,

    /// Numbers the events one session is sent, starting at 1 and counting
    /// only what this session receives: events its subscription leaves out
    /// take no number. So within a session the numbers have no gaps, and a
    /// gap means an event was lost and the client must refetch rather than
    /// patch. A reconnect is a new session, which starts at 1 again; the
    /// client refetches after one anyway.
    required int seq,

    /// Optional routing key — usually a chat, channel, or note ID.
    ///
    /// Clients declare interest with `events.subscribe`; the daemon skips
    /// sending an event whose scope no window is watching. Null means
    /// "session-wide", which is always delivered.
    String? scope,

    /// Event-specific body. Deliberately untyped at this layer: each family
    /// decodes its own payload with its own DTO, so adding an event never
    /// touches this file.
    @Default(<String, dynamic>{}) Map<String, dynamic> payload,
  }) = _EventEnvelope;

  factory EventEnvelope.fromJson(Map<String, dynamic> json) =>
      _$EventEnvelopeFromJson(json);
}

/// Parameters for `events.subscribe`.
///
/// Subscriptions are declarative and idempotent: a client sends its *entire*
/// current interest set, and the daemon replaces what it had. That way a
/// reconnecting window replays one call instead of diffing.
@freezed
abstract class EventSubscription with _$EventSubscription {
  const factory EventSubscription({
    /// Event names this client wants. Empty means all of [ConduitEvents.all].
    @Default(<String>[]) List<String> events,

    /// Scopes this client wants. Empty means "session-wide events only";
    /// scoped events are dropped unless their scope is listed here.
    @Default(<String>[]) List<String> scopes,
  }) = _EventSubscription;

  factory EventSubscription.fromJson(Map<String, dynamic> json) =>
      _$EventSubscriptionFromJson(json);
}
