import 'package:freezed_annotation/freezed_annotation.dart';

// Freezed applies JsonKey to constructor parameters which triggers
// invalid_annotation_target; suppress it for this data model file.
// ignore_for_file: invalid_annotation_target

part 'app_notification.freezed.dart';
part 'app_notification.g.dart';

/// The kind of a user-facing notification.
///
/// The Open WebUI socket raises the first two, mirroring the upstream web
/// client: its `+layout.svelte` only surfaces a toast / browser Notification
/// for `chat:completion` (terminal frame), `calendar:alert` and channel
/// `message`. Conduit has no calendar feature, so `calendar:alert` is not
/// represented here. Every other socket event (`chat:title`, `chat:tags`,
/// `chat:message:error`, channel reply / reaction / created, etc.) is a silent
/// state refresh upstream and is likewise not a [NotificationKind].
///
/// Push notifications (`cp/1`, docs/push/PROTOCOL.md) add the rest. Hermes and
/// Direct replies are [chatCompletion]s too.
enum NotificationKind {
  /// An assistant response finished in a chat the user is not currently
  /// viewing — upstream `chat:completion` with `done == true`, a Hermes turn,
  /// or a Direct reply.
  @JsonValue('chat_completion')
  chatCompletion,

  /// A new message arrived in a channel or DM authored by someone else —
  /// upstream channel event with `type == 'message'`.
  @JsonValue('channel_message')
  channelMessage,

  /// An assistant response failed instead of finishing.
  @JsonValue('reply_failed')
  replyFailed,

  /// A Hermes scheduled task (cron job) delivered its result.
  @JsonValue('scheduled_task')
  scheduledTask,

  /// A test push that proves a subscription works. Never shown by the router.
  @JsonValue('push_test')
  pushTest,
}

/// The names a [NotificationKind] travels under outside Dart: its JSON value,
/// which native code and stored tap payloads use too.
extension NotificationKindWireName on NotificationKind {
  String get wireName => switch (this) {
    NotificationKind.chatCompletion => 'chat_completion',
    NotificationKind.channelMessage => 'channel_message',
    NotificationKind.replyFailed => 'reply_failed',
    NotificationKind.scheduledTask => 'scheduled_task',
    NotificationKind.pushTest => 'push_test',
  };

  /// The kind named [name], by wire name or Dart name; null for neither.
  static NotificationKind? parse(String? name) {
    if (name == null) return null;
    for (final kind in NotificationKind.values) {
      if (kind.wireName == name || kind.name == name) return kind;
    }
    return null;
  }
}

/// An immutable, transport-agnostic description of a notification to surface.
///
/// Produced by [NotificationEventClassifier] from a raw socket envelope, by
/// [appNotificationFromCp1] from a push, or by the app for Hermes and Direct
/// replies, and consumed by the notification router. It deliberately carries
/// no routing or presentation concerns: navigation is derived later from
/// [scope] + [kind] + [sourceId], and received-time / read tracking belong to
/// the (deferred) inbox layer.
@freezed
sealed class AppNotification with _$AppNotification {
  const factory AppNotification({
    /// What happened — selects the surface copy and the deep-link target.
    required NotificationKind kind,

    /// The account or connection this notification belongs to:
    /// `owui:<accountId>`, `hermes:<connectionId>` or `direct`. See
    /// [NotificationScope].
    required String scope,

    /// Headline text, already formatted from the payload (may be empty when
    /// the source provides no title; the surface layer supplies a fallback).
    required String title,

    /// Body text — the message / completion content.
    required String body,

    /// What this notification points at, within [scope]: the chat id for an
    /// Open WebUI or Direct reply, the channel id for a channel message, the
    /// session id for a Hermes reply, the job id for a scheduled task. Used
    /// both for active-view suppression and to build the tap deep link.
    required String sourceId,

    /// App-wide de-duplication key, `<scope>|<protocol dedup key>` (for
    /// example `owui:acct-1|chat:c1:m1`). Survives socket re-bind /
    /// buffered-event replay so a replayed terminal frame never
    /// double-notifies, and matches the key a push for the same event builds,
    /// so the two never duplicate each other.
    required String dedupKey,

    /// The conversation this belongs to, for grouping (`chat:<chatId>`,
    /// `channel:<channelId>`, `hermes:<sessionId>`, `cron:<jobId>`), when
    /// known.
    String? group,

    /// Whether the user has seen this notification (set by the inbox layer).
    @Default(false) bool read,
  }) = _AppNotification;

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      _$AppNotificationFromJson(json);
}
