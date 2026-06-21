import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/utils/current_localizations.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/app_notification.dart';

part 'local_notification_service.g.dart';

/// A tap on a system notification, decoded back into the target it points at.
class NotificationTap {
  const NotificationTap({required this.kind, required this.sourceId});

  final NotificationKind kind;
  final String sourceId;

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
      final kind = NotificationKind.values
          .where((k) => k.name == kindName)
          .firstOrNull;
      if (kind == null) return null;
      return NotificationTap(kind: kind, sourceId: sourceId);
    } catch (_) {
      return null;
    }
  }

  static String encode(AppNotification notification) => jsonEncode({
    'kind': notification.kind.name,
    'sourceId': notification.sourceId,
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

  int _nextNotificationId() => _idCounter = (_idCounter + 1) & 0x7fffffff;

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

  /// Posts an OS notification for [notification]. No-ops on unsupported
  /// platforms. Safe to call before [initialize] (it self-initializes).
  ///
  /// [playSound] honors the user's notification-sound preference. Note Android
  /// 8+ governs sound at the channel level, so the per-notification flag is
  /// best-effort there; it is authoritative on iOS.
  Future<void> show(
    AppNotification notification, {
    required bool playSound,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (!_initialized) await initialize();

    final l10n = currentAppLocalizations();
    final title = notification.title.isNotEmpty
        ? notification.title
        : l10n.notificationDefaultTitle;

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      l10n.notificationChannelMessagesName,
      channelDescription: l10n.notificationChannelMessagesDescription,
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      playSound: playSound,
    );
    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: playSound,
    );

    try {
      await _plugin.show(
        id: _nextNotificationId(),
        title: title,
        body: notification.body,
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

  /// Clears all posted message notifications — used on logout / server switch
  /// to avoid cross-server deep links.
  Future<void> cancelAll() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await _plugin.cancelAll();
  }

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
