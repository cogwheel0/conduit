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

  /// Already-parsed segments: text, reasoning, tool call, code execution,
  /// citations, images, follow-ups, status. Parsing happens once, in the
  /// daemon (section 4); the UI only turns markdown into DOM.
  static const String turnBlocks = 'turn.blocks';
  static const String turnCompleted = 'turn.completed';
  static const String turnFailed = 'turn.failed';

  static const String chatsChanged = 'chats.changed';
  static const String notesChanged = 'notes.changed';
  static const String channelsMessage = 'channels.message';

  /// Who is typing in a channel changed (M5). Payload
  /// [ChannelTypingUsers], scoped to `channel:<id>`.
  static const String channelsTyping = 'channels.typing';

  /// The channel list changed: a channel added, removed, renamed, or a new
  /// unread count (M5). No payload.
  static const String channelsChanged = 'channels.changed';

  static const String syncStatus = 'sync.status';
  static const String socketHealth = 'socket.health';

  /// Ask the shell to raise an OS notification (WP-9.3).
  static const String notifyShow = 'notify.show';

  /// A chat ID was remapped after sync; the UI must rewrite its route
  /// without pushing a history entry (WP-1.7).
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
  /// models discovered, or the server's list was refreshed (M4). No
  /// payload; `models.list` says what they are.
  static const String modelsChanged = 'models.changed';

  /// The daemon needs a page opened in the system browser (M4): an MCP
  /// server's OAuth sign-in. Payload [OpenUrl]. The first window to hear it
  /// opens it.
  static const String openUrl = 'shell.openUrl';

  /// A workspace section's items changed (M6). Payload [WorkspaceChanged].
  static const String workspaceChanged = 'workspace.changed';

  /// Every event name, for subscription validation and tests.
  static const Set<String> all = {
    turnStarted,
    turnDelta,
    turnBlocks,
    turnCompleted,
    turnFailed,
    chatsChanged,
    notesChanged,
    channelsMessage,
    channelsTyping,
    channelsChanged,
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

    /// Monotonic per daemon process, starting at 1 and shared across all
    /// events and all clients. After a reconnect the UI compares the first
    /// [seq] it sees against the last it processed: a gap means it missed
    /// events while the socket was down and must refetch rather than patch.
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
