import 'dart:collection';

import 'package:conduit_core/services/settings_service.dart';

import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'package:conduit_core/features/notifications/services/active_view_tracker.dart';

import 'local_notification_service.dart';
import 'notification_sound_service.dart';

/// The visible surface a notification was routed to (or why it was dropped).
enum NotificationSurface {
  /// In-app banner (app foreground).
  banner,

  /// OS system notification (app background).
  system,

  /// Passed gating but no visible surface (the relevant surface pref is off).
  silent,

  /// Suppressed by gating (pref off, duplicate, or currently viewing target).
  suppressed,
}

/// Claims [dedupKey] before a system notification for it is posted, and says
/// whether this app may post it. [localNotificationId] is the id the posted
/// notification will have, so a source that loses the race can remove it.
/// The router claims again with the same id right after posting: a push that
/// took the key over in between had nothing to remove yet, so the platform
/// removes this copy then.
///
/// Push wires this to the native ledger it shares with the notification
/// service extension, so a socket notification and a push for the same event
/// never both show.
typedef NotificationClaim =
    Future<bool> Function(String dedupKey, String? localNotificationId);

Future<bool> _alwaysClaim(String dedupKey, String? localNotificationId) =>
    Future<bool>.value(true);

/// Whether notifications for one scope (`owui:<accountId>`,
/// `hermes:<connectionId>`, `direct`) are switched on.
typedef ScopeNotificationsEnabled = bool Function(String scope);

/// Whether a push will report the same event as [notification]: push is on
/// for its scope (a test push decrypted here) and, for a Hermes reply, the
/// plugin pushes that session's turns.
typedef PushCovers = bool Function(AppNotification notification);

bool _noPush(AppNotification notification) => false;

/// The single decision point for whether and how to surface a classified
/// [AppNotification]. UI-free and dependency-injected so every gating branch is
/// unit-testable. The widget/provider layer supplies the collaborators.
class NotificationRouter {
  NotificationRouter({
    required AppSettings Function() readSettings,
    required ActiveView Function() readActiveView,
    required bool Function() isAppForeground,
    required LocalNotificationService localNotifications,
    required NotificationSoundService sound,
    required void Function(AppNotification) showInAppBanner,
    required void Function(AppNotification) onChannelUnread,
    NotificationClaim claim = _alwaysClaim,
    ScopeNotificationsEnabled? scopeNotificationsEnabled,
    PushCovers pushCovers = _noPush,
    DateTime Function() now = DateTime.now,
    int dedupCapacity = 200,
  }) : _readSettings = readSettings,
       _scopeNotificationsEnabled = scopeNotificationsEnabled,
       _pushCovers = pushCovers,
       _readActiveView = readActiveView,
       _isAppForeground = isAppForeground,
       _localNotifications = localNotifications,
       _sound = sound,
       _showInAppBanner = showInAppBanner,
       _onChannelUnread = onChannelUnread,
       _claim = claim,
       _now = now,
       _dedupCapacity = dedupCapacity;

  /// How long a Hermes reply suppresses another for the same session.
  ///
  /// The app can't know the server's turn id for a reply it watched finish, so
  /// its key never matches the push for the same turn; the session does
  /// (docs/push/PROTOCOL.md §2).
  static const Duration hermesGroupWindow = Duration(seconds: 120);

  final AppSettings Function() _readSettings;
  final ActiveView Function() _readActiveView;
  final bool Function() _isAppForeground;
  final LocalNotificationService _localNotifications;
  final NotificationSoundService _sound;
  final void Function(AppNotification) _showInAppBanner;
  final void Function(AppNotification) _onChannelUnread;
  final NotificationClaim _claim;

  /// The notification's own switch: its Open WebUI account's, or the
  /// device-level one for Hermes and Direct. Without it, the active
  /// settings' switch stands for every scope.
  final ScopeNotificationsEnabled? _scopeNotificationsEnabled;
  final PushCovers _pushCovers;
  final DateTime Function() _now;
  final int _dedupCapacity;

  /// Bounded LRU of recently surfaced dedup keys. Lives for the router's
  /// lifetime (a keepAlive provider), so it survives socket re-bind and the
  /// buffered-event replay that re-delivers a terminal frame on re-registration.
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();

  /// When a Hermes reply last surfaced, by `<scope>|<group>`.
  final Map<String, DateTime> _hermesGroups = <String, DateTime>{};

  /// Routes [notification] through the gating chain and dispatches it. Returns
  /// the surface taken, primarily for tests and diagnostics.
  ///
  /// [alreadyClaimed] is for a push the platform handed over in the
  /// foreground: the notification service extension claimed its key before
  /// the app saw it, so claiming again would always lose.
  Future<NotificationSurface> route(
    AppNotification notification, {
    bool alreadyClaimed = false,
  }) async {
    final settings = _readSettings();

    // 1. Master toggle: the switch of the account the notification belongs
    // to, not the active account's. Hermes and Direct follow the
    // device-level switch (see notificationsEnabledForScope).
    final enabled =
        _scopeNotificationsEnabled?.call(notification.scope) ??
        settings.notificationsEnabled;
    if (!enabled) return NotificationSurface.suppressed;

    // 2. Per-kind toggle.
    if (!_kindEnabled(notification.kind, settings)) {
      return NotificationSurface.suppressed;
    }

    final foreground = _isAppForeground();

    // 3. In the background a push that reports the same event is shown
    // without this router. A source whose key cannot match the push's (a
    // Hermes turn this app watched, a frame with no message id) would then
    // notify twice, so it leaves the system notification to the push -- only
    // when one is sure to come, though, or nothing would notify at all.
    // The push's own key differs from this source's, so recording this one
    // never holds the push back if it reaches the router in the foreground.
    // A push shown outside the app never reaches the loaded channel list, so
    // its unread count still goes up here, once per message even when the
    // frame is delivered again.
    if (!foreground &&
        !alreadyClaimed &&
        !notification.sharesPushDedupKey &&
        _pushCovers(notification)) {
      if (notification.kind == NotificationKind.channelMessage &&
          _markFresh(notification.dedupKey)) {
        _onChannelUnread(notification);
      }
      return NotificationSurface.suppressed;
    }

    // 4. De-duplication (also guards replayed terminal frames after re-bind),
    // and a Hermes reply already shown for the same session.
    if (!_markFresh(notification.dedupKey) ||
        _hermesGroupShownRecently(notification)) {
      return NotificationSurface.suppressed;
    }

    // 5. Don't alert for content the user is actively looking at — but only in
    // the foreground. Backgrounded, the user can't see any view, so a
    // completion in the chat they just left (the "active" chat) must still
    // notify. Mirrors Open WebUI's `(notViewingChat) || isInBackground` gate.
    // The same chat id in another account or connection is not on screen.
    if (foreground && _readActiveView().isViewing(notification)) {
      return NotificationSurface.suppressed;
    }

    // Only a Hermes reply that got this far holds back the next one for its
    // session: one hidden because its session was on screen was never seen
    // as an alert, so a later reply there must still notify.
    _recordHermesGroup(notification);

    // 6. Side effects for everything that passed gating.
    if (settings.notificationSound && settings.notificationSoundAlways) {
      await _sound.play();
    }
    if (notification.kind == NotificationKind.channelMessage) {
      _onChannelUnread(notification);
    }

    // 7. Exactly one primary surface, chosen by lifecycle. Unlike Open WebUI's
    // web client (which can show an in-app toast AND a browser Notification at
    // once), a foregrounded mobile app only needs the in-app banner; the OS
    // notification is the background affordance.
    if (foreground) {
      if (settings.notificationInAppBanner) {
        _showInAppBanner(notification);
        return NotificationSurface.banner;
      }
      return NotificationSurface.silent;
    } else {
      if (settings.notificationSystem) {
        // Another source (a push) may already have shown this event.
        final id = _localNotifications.nextNotificationId();
        if (!alreadyClaimed && !await _claim(notification.dedupKey, '$id')) {
          return NotificationSurface.suppressed;
        }
        await _localNotifications.show(
          notification,
          playSound: settings.notificationSound,
          id: id,
        );
        if (!alreadyClaimed) await _claim(notification.dedupKey, '$id');
        return NotificationSurface.system;
      }
      return NotificationSurface.silent;
    }
  }

  bool _kindEnabled(NotificationKind kind, AppSettings settings) {
    switch (kind) {
      case NotificationKind.chatCompletion:
      case NotificationKind.replyFailed:
        return settings.notificationChatEnabled;
      case NotificationKind.channelMessage:
        return settings.notificationChannelEnabled;
      case NotificationKind.scheduledTask:
        return settings.notificationScheduledEnabled;
      case NotificationKind.pushTest:
        // A test push only proves delivery; it is never shown here.
        return false;
    }
  }

  /// The key a Hermes reply's session window is kept under, `<scope>|<group>`;
  /// null for anything else.
  static String? _hermesGroupKey(AppNotification notification) {
    final group = notification.group;
    if (group == null ||
        NotificationScope.tryParse(notification.scope)
            is! HermesNotificationScope ||
        (notification.kind != NotificationKind.chatCompletion &&
            notification.kind != NotificationKind.replyFailed)) {
      return null;
    }
    return '${notification.scope}|$group';
  }

  /// Whether a Hermes reply for the same session surfaced within
  /// [hermesGroupWindow].
  bool _hermesGroupShownRecently(AppNotification notification) {
    final key = _hermesGroupKey(notification);
    if (key == null) return false;
    final now = _now();
    _hermesGroups.removeWhere(
      (_, shownAt) => now.difference(shownAt) >= hermesGroupWindow,
    );
    return _hermesGroups.containsKey(key);
  }

  /// Opens the session window of a Hermes reply that passed gating.
  void _recordHermesGroup(AppNotification notification) {
    final key = _hermesGroupKey(notification);
    if (key != null) _hermesGroups[key] = _now();
  }

  /// Returns true if [key] was not seen before (and records it). Evicts the
  /// oldest key once capacity is exceeded.
  bool _markFresh(String key) {
    if (_seen.contains(key)) return false;
    _seen.add(key);
    if (_seen.length > _dedupCapacity) {
      _seen.remove(_seen.first);
    }
    return true;
  }
}
