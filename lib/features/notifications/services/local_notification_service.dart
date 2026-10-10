import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/utils/current_localizations.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/models/notification_scope.dart';

part 'local_notification_service.g.dart';

/// A tap on a system notification, decoded back into the target it points at.
///
/// The payload is JSON. Version 2, which this app writes:
/// `{"v": 2, "kind": "chat_completion", "sourceId": "…", "scope": "owui:…",
/// "group": "chat:…"}`, with `kind` a [NotificationKindWireName.wireName] and
/// `group` optional. Version 1, written before notifications knew their
/// account, is `{"kind": "chatCompletion", "sourceId": "…"}`; it has no
/// [scope] and points into the active account.
class NotificationTap {
  const NotificationTap({
    required this.kind,
    required this.sourceId,
    this.scope,
    this.group,
  });

  NotificationTap.fromNotification(AppNotification notification)
    : this(
        kind: notification.kind,
        sourceId: notification.sourceId,
        scope: notification.scope,
        group: notification.group,
      );

  static const int version = 2;

  final NotificationKind kind;
  final String sourceId;

  /// The account or connection it belongs to; null for a version 1 tap, which
  /// means the active account.
  final String? scope;

  final String? group;

  static NotificationTap? tryDecode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final map = jsonDecode(payload);
      if (map is! Map) return null;
      final kindName = map['kind'];
      final sourceId = map['sourceId'];
      if (kindName is! String || sourceId is! String || sourceId.isEmpty) {
        return null;
      }
      final kind = NotificationKindWireName.parse(kindName);
      if (kind == null) return null;
      final scope = map['scope'];
      final group = map['group'];
      // A version 2 tap names its account; without one it can't be opened
      // in the right place.
      if (map['v'] is int && (map['v'] as int) >= 2) {
        if (scope is! String || NotificationScope.tryParse(scope) == null) {
          return null;
        }
      }
      return NotificationTap(
        kind: kind,
        sourceId: sourceId,
        scope: scope is String ? scope : null,
        group: group is String && group.isNotEmpty ? group : null,
      );
    } catch (_) {
      return null;
    }
  }

  static String encode(AppNotification notification) => jsonEncode({
    'v': version,
    'kind': notification.kind.wireName,
    'sourceId': notification.sourceId,
    'scope': notification.scope,
    'group': ?notification.group,
  });
}

/// Wraps a single [FlutterLocalNotificationsPlugin] instance for OS-level
/// message notifications. Deliberately separate from
/// `VoiceCallNotificationService` for now (that refactor is a follow-up); this
/// owns its own `conduit_messages` channel and never requests permission at
/// init — permission is requested only when the user opts in.
class LocalNotificationService {
  LocalNotificationService();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'conduit_messages';

  bool _initialized = false;

  /// Monotonic OS-notification id. Using a counter (rather than a hash of the
  /// dedup key) avoids 31-bit hash collisions silently replacing a notification
  /// in the drawer. De-duplication is handled upstream by the router.
  int _idCounter = 0;

  /// The id the next notification posts with, handed out ahead of [show] so
  /// it can be claimed under (see `NotificationClaim`).
  int nextNotificationId() => _idCounter = (_idCounter + 1) & 0x7fffffff;

  final StreamController<NotificationTap> _taps =
      StreamController<NotificationTap>.broadcast();

  /// Emits when the user taps a message notification while the app is running.
  Stream<NotificationTap> get taps => _taps.stream;

  Future<void>? _initializing;

  /// Initializes the plugin exactly once. Concurrent callers (e.g. several
  /// `show()`s racing before setup completes) share the same in-flight future
  /// instead of each running `_plugin.initialize()` in parallel.
  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    if (!Platform.isAndroid && !Platform.isIOS) return Future<void>.value();
    return _initializing ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    try {
      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      // No permission requests at init — see class doc.
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const settings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _onResponse,
      );

      if (Platform.isAndroid) {
        await _createAndroidChannel();
      }

      _initialized = true;
    } catch (e, st) {
      // Contain init failures here so they can't bubble into notification
      // routing. _initialized stays false so a later call can retry.
      DebugLogger.error(
        'failed to initialize local notifications',
        error: e,
        stackTrace: st,
        scope: 'notifications/system',
      );
    } finally {
      _initializing = null;
    }
  }

  Future<void> _createAndroidChannel() async {
    final l10n = currentAppLocalizations();
    final channel = AndroidNotificationChannel(
      _channelId,
      l10n.notificationChannelMessagesName,
      description: l10n.notificationChannelMessagesDescription,
      importance: Importance.high,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  void _onResponse(NotificationResponse response) {
    // The plugin singleton keeps this callback registered after dispose(), so a
    // late tap could otherwise add to a closed controller and throw.
    if (_taps.isClosed) return;
    final tap = NotificationTap.tryDecode(response.payload);
    if (tap != null) {
      _taps.add(tap);
    }
  }

  /// The notification that cold-launched the app, if any (e.g. tapped from a
  /// killed state). Returns null when the launch was not from a notification.
  Future<NotificationTap?> launchTap() async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return NotificationTap.tryDecode(details?.notificationResponse?.payload);
  }

  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await android?.requestNotificationsPermission() ?? false;
    }
    if (Platform.isIOS) {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      return await ios?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    return false;
  }

  /// Opens the OS notification settings for this app. Returns false when the
  /// platform has no such screen or it could not be launched.
  Future<bool> openSystemSettings() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    try {
      return await _plugin.openAppNotificationSettings() ?? false;
    } catch (error) {
      DebugLogger.warning(
        'open-system-settings-failed',
        scope: 'notifications/local',
        data: {'error': error.toString()},
      );
      return false;
    }
  }

  /// Posts an OS notification for [notification]. No-ops on unsupported
  /// platforms. Safe to call before [initialize] (it self-initializes).
  ///
  /// [playSound] honors the user's notification-sound preference. Note Android
  /// 8+ governs sound at the channel level, so the per-notification flag is
  /// best-effort there; it is authoritative on iOS.
  ///
  /// [id] is one [nextNotificationId] handed out; a fresh one by default. On
  /// Android the notification is tagged with its dedup key, which push posts
  /// under too.
  Future<void> show(
    AppNotification notification, {
    required bool playSound,
    int? id,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (!_initialized) await initialize();

    final l10n = currentAppLocalizations();
    final title = notification.title.isNotEmpty
        ? notification.title
        : l10n.notificationDefaultTitle;
    final body =
        notification.body.isEmpty &&
            notification.kind == NotificationKind.replyFailed
        ? l10n.notificationReplyFailedBody
        : notification.body;

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      l10n.notificationChannelMessagesName,
      channelDescription: l10n.notificationChannelMessagesDescription,
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      playSound: playSound,
      tag: notification.dedupKey,
    );
    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: playSound,
      threadIdentifier: notificationThreadIdentifier(notification),
    );

    try {
      await _plugin.show(
        id: id ?? nextNotificationId(),
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: androidDetails,
          iOS: iosDetails,
        ),
        payload: NotificationTap.encode(notification),
      );
    } catch (e, st) {
      DebugLogger.error(
        'failed to show system notification',
        error: e,
        stackTrace: st,
        scope: 'notifications/system',
      );
    }
  }

  /// Clears all posted message notifications — used when signing out of
  /// everything, so nothing deep-links into data that is gone.
  Future<void> cancelAll() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await _plugin.cancelAll();
  }

  /// Clears the posted notifications of one account or connection ([scope],
  /// see [NotificationScope]), leaving every other one in place. Notifications
  /// posted before they carried a scope go too: which account they belong to
  /// is no longer known.
  Future<void> cancelScope(String scope) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (!_initialized) await initialize();
    try {
      final active = await _plugin.getActiveNotifications();
      for (final notification in notificationsInScope(active, scope)) {
        await _plugin.cancel(id: notification.id!, tag: notification.tag);
      }
    } catch (e, st) {
      DebugLogger.error(
        'failed to clear scoped notifications',
        error: e,
        stackTrace: st,
        scope: 'notifications/system',
      );
    }
  }

  /// Which of the posted [active] notifications [cancelScope] clears for
  /// [scope]: this app's message notifications of that scope, and those
  /// without one. Others (a voice call's, say) are left alone.
  @visibleForTesting
  static List<ActiveNotification> notificationsInScope(
    List<ActiveNotification> active,
    String scope,
  ) => [
    for (final notification in active)
      if (notification.id != null)
        if (NotificationTap.tryDecode(notification.payload) case final tap?)
          if (tap.scope == null || tap.scope == scope) notification,
  ];

  void dispose() {
    _taps.close();
  }
}

@Riverpod(keepAlive: true)
LocalNotificationService localNotificationService(Ref ref) {
  final service = LocalNotificationService();
  ref.onDispose(service.dispose);
  return service;
}

/// The iOS thread a notification is listed under: its group, scoped to the
/// account that posted it, the same way the push extension builds it, so a
/// local notification and a push for the same chat share one thread and two
/// accounts never share one.
@visibleForTesting
String notificationThreadIdentifier(AppNotification notification) {
  final group = notification.group;
  return group == null || group.isEmpty
      ? notification.scope
      : '${notification.scope}|$group';
}
