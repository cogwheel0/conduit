import 'package:meta/meta.dart';

import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/services/settings_service.dart';

/// The visible surface a notification was routed to (or why it was dropped).
enum NotificationSurface {
  /// In-app banner (app in front).
  banner,

  /// OS system notification (app in the background).
  system,

  /// Passed gating but no visible surface (the relevant surface pref is off).
  silent,

  /// Suppressed by gating (pref off, duplicate, or currently viewing target).
  suppressed,
}

/// What a host does with one classified notification, as
/// [decideNotification] decides it.
@immutable
class NotificationDecision {
  const NotificationDecision({
    required this.surface,
    this.cue = false,
    this.systemSound = false,
    this.countsUnread = false,
  });

  /// Nothing to do: the notification is off, or its target is in front.
  static const suppressed = NotificationDecision(
    surface: NotificationSurface.suppressed,
  );

  final NotificationSurface surface;

  /// Play the notification cue ("Sound" with "Sound Always").
  final bool cue;

  /// A system notification makes its sound ("Sound").
  final bool systemSound;

  /// A channel message counts as unread, even when it does not alert.
  final bool countsUnread;

  @override
  bool operator ==(Object other) =>
      other is NotificationDecision &&
      other.surface == surface &&
      other.cue == cue &&
      other.systemSound == systemSound &&
      other.countsUnread == countsUnread;

  @override
  int get hashCode => Object.hash(surface, cue, systemSound, countsUnread);

  @override
  String toString() =>
      'NotificationDecision(${surface.name}, cue: $cue, '
      'systemSound: $systemSound, countsUnread: $countsUnread)';
}

/// Whether notifications of [kind] are on in [settings]. A failed reply
/// follows the chat toggle; a test push only proves delivery and is never
/// shown.
bool notificationKindEnabled(NotificationKind kind, AppSettings settings) =>
    switch (kind) {
      NotificationKind.chatCompletion ||
      NotificationKind.replyFailed => settings.notificationChatEnabled,
      NotificationKind.channelMessage => settings.notificationChannelEnabled,
      NotificationKind.scheduledTask => settings.notificationScheduledEnabled,
      NotificationKind.pushTest => false,
    };

/// The single gating chain for a classified notification, shared by every
/// host. Pure: the host supplies what only it knows, whether the app is in
/// front ([foreground]) and whether the user is looking at the notification's
/// chat or channel ([viewing]), and performs what comes back.
///
/// In order:
/// 1. the master toggle, then the toggle for [kind];
/// 2. content the user is looking at, but only in the foreground (in the
///    background no view is seen, so the chat just left still notifies, as
///    Open WebUI's `(notViewingChat) || isInBackground`);
/// 3. a channel message counts as unread from here on;
/// 4. [alert] false (a channel set to mentions only, not mentioning the user)
///    shows nothing, as in Open WebUI; nor does a channel message that is
///    neither a mention nor [direct] while
///    [AppSettings.notificationChannelMentionsOnly] is on;
/// 5. the cue plays for every alert when "Sound" and "Sound Always" are on;
/// 6. exactly one surface by lifecycle: the in-app banner in front, the
///    system notification in the background, or silent when that surface is
///    off.
NotificationDecision decideNotification({
  required AppSettings settings,
  required NotificationKind kind,
  required bool foreground,
  required bool viewing,
  bool alert = true,
  bool mention = false,
  bool direct = false,
}) {
  if (!settings.notificationsEnabled) return NotificationDecision.suppressed;
  if (!notificationKindEnabled(kind, settings)) {
    return NotificationDecision.suppressed;
  }
  if (foreground && viewing) return NotificationDecision.suppressed;

  final countsUnread = kind == NotificationKind.channelMessage;
  final mentionsOnly =
      kind == NotificationKind.channelMessage &&
      settings.notificationChannelMentionsOnly &&
      !mention &&
      !direct;
  if (!alert || mentionsOnly) {
    return NotificationDecision(
      surface: NotificationSurface.suppressed,
      countsUnread: countsUnread,
    );
  }

  final cue = settings.notificationSound && settings.notificationSoundAlways;
  final NotificationSurface surface;
  if (foreground) {
    surface = settings.notificationInAppBanner
        ? NotificationSurface.banner
        : NotificationSurface.silent;
  } else {
    surface = settings.notificationSystem
        ? NotificationSurface.system
        : NotificationSurface.silent;
  }
  return NotificationDecision(
    surface: surface,
    cue: cue,
    systemSound:
        surface == NotificationSurface.system && settings.notificationSound,
    countsUnread: countsUnread,
  );
}
