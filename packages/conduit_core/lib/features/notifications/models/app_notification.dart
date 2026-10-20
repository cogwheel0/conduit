import 'package:freezed_annotation/freezed_annotation.dart';

// Freezed applies JsonKey to constructor parameters which triggers
// invalid_annotation_target; suppress it for this data model file.
// ignore_for_file: invalid_annotation_target

part 'app_notification.freezed.dart';
part 'app_notification.g.dart';

/// The kind of a user-facing notification, mirroring the Open WebUI socket
/// events that raise an alert in the upstream web client.
///
/// Open WebUI's `+layout.svelte` only surfaces a toast / browser Notification
/// for three event types: `chat:completion` (terminal frame), `calendar:alert`,
/// and channel `message`. Conduit has no calendar feature, so `calendar:alert`
/// is intentionally not represented here. Every other socket event
/// (`chat:title`, `chat:tags`, `chat:message:error`, channel reply / reaction /
/// created, etc.) is a silent state refresh upstream and is likewise not a
/// [NotificationKind].
enum NotificationKind {
  /// An assistant response finished in a chat the user is not currently
  /// viewing — upstream `chat:completion` with `done == true`.
  @JsonValue('chat_completion')
  chatCompletion,

  /// A new message arrived in a channel or DM authored by someone else —
  /// upstream channel event with `type == 'message'`.
  @JsonValue('channel_message')
  channelMessage,
}

/// An immutable, transport-agnostic description of a notification to surface.
///
/// Produced by [NotificationEventClassifier] from a raw socket envelope and
/// consumed by the notification router. It deliberately carries no routing or
/// presentation concerns: navigation is derived later from [kind] + [sourceId],
/// and received-time / read tracking belong to the (deferred) inbox layer.
@freezed
sealed class AppNotification with _$AppNotification {
  const factory AppNotification({
    /// What happened — selects the surface copy and the deep-link target.
    required NotificationKind kind,

    /// Headline text, already formatted from the payload (may be empty when
    /// the source provides no title; the surface layer supplies a fallback).
    required String title,

    /// Body text — the message / completion content.
    required String body,

    /// The chat id or channel id this notification points at. Used both for
    /// active-view suppression and to build the tap deep link.
    required String sourceId,

    /// Stable de-duplication key. Survives socket re-bind / buffered-event
    /// replay so a replayed terminal frame never double-notifies. Shared with
    /// any future push source so the two never duplicate each other.
    required String dedupKey,

    /// Whether the user has seen this notification (set by the inbox layer).
    @Default(false) bool read,
  }) = _AppNotification;

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      _$AppNotificationFromJson(json);
}
