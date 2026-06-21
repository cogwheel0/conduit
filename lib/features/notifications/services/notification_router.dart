import 'dart:collection';

import '../../../core/services/settings_service.dart';
import '../models/app_notification.dart';
import 'active_view_tracker.dart';
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
    int dedupCapacity = 200,
  }) : _readSettings = readSettings,
       _readActiveView = readActiveView,
       _isAppForeground = isAppForeground,
       _localNotifications = localNotifications,
       _sound = sound,
       _showInAppBanner = showInAppBanner,
       _onChannelUnread = onChannelUnread,
       _dedupCapacity = dedupCapacity;

  final AppSettings Function() _readSettings;
  final ActiveView Function() _readActiveView;
  final bool Function() _isAppForeground;
  final LocalNotificationService _localNotifications;
  final NotificationSoundService _sound;
  final void Function(AppNotification) _showInAppBanner;
  final void Function(AppNotification) _onChannelUnread;
  final int _dedupCapacity;

  /// Bounded LRU of recently surfaced dedup keys. Lives for the router's
  /// lifetime (a keepAlive provider), so it survives socket re-bind and the
  /// buffered-event replay that re-delivers a terminal frame on re-registration.
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();

  /// Routes [notification] through the gating chain and dispatches it. Returns
  /// the surface taken, primarily for tests and diagnostics.
  Future<NotificationSurface> route(AppNotification notification) async {
    final settings = _readSettings();

    // 1. Master toggle.
    if (!settings.notificationsEnabled) return NotificationSurface.suppressed;

    // 2. Per-kind toggle.
    if (!_kindEnabled(notification.kind, settings)) {
      return NotificationSurface.suppressed;
    }

    // 3. De-duplication (also guards replayed terminal frames after re-bind).
    if (!_markFresh(notification.dedupKey)) {
      return NotificationSurface.suppressed;
    }

    final foreground = _isAppForeground();

    // 4. Don't alert for content the user is actively looking at — but only in
    // the foreground. Backgrounded, the user can't see any view, so a
    // completion in the chat they just left (the "active" chat) must still
    // notify. Mirrors Open WebUI's `(notViewingChat) || isInBackground` gate.
    if (foreground && _isViewingTarget(notification)) {
      return NotificationSurface.suppressed;
    }

    // 5. Side effects for everything that passed gating.
    if (settings.notificationSound && settings.notificationSoundAlways) {
      await _sound.play();
    }
    if (notification.kind == NotificationKind.channelMessage) {
      _onChannelUnread(notification);
    }

    // 6. Exactly one primary surface, chosen by lifecycle. Unlike Open WebUI's
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
        await _localNotifications.show(
          notification,
          playSound: settings.notificationSound,
        );
        return NotificationSurface.system;
      }
      return NotificationSurface.silent;
    }
  }

  bool _kindEnabled(NotificationKind kind, AppSettings settings) {
    switch (kind) {
      case NotificationKind.chatCompletion:
        return settings.notificationChatEnabled;
      case NotificationKind.channelMessage:
        return settings.notificationChannelEnabled;
    }
  }

  bool _isViewingTarget(AppNotification notification) {
    final view = _readActiveView();
    switch (notification.kind) {
      case NotificationKind.chatCompletion:
        return view.isViewingChat(notification.sourceId);
      case NotificationKind.channelMessage:
        return view.isViewingChannel(notification.sourceId);
    }
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
