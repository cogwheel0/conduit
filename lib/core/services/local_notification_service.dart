import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/debug_logger.dart';

typedef LocalNotificationResponseHandler =
    FutureOr<void> Function(NotificationResponse response);

final localNotificationServiceProvider = Provider<LocalNotificationService>(
  (ref) => LocalNotificationService.instance,
);

/// Shared owner for the flutter_local_notifications plugin.
///
/// The plugin only supports one response callback registration. Keeping that
/// callback here prevents feature services from overwriting each other.
class LocalNotificationService {
  LocalNotificationService._();

  static final LocalNotificationService instance = LocalNotificationService._();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final Map<String, LocalNotificationResponseHandler> _responseHandlers = {};

  Future<void>? _initializing;
  bool _initialized = false;

  FlutterLocalNotificationsPlugin get plugin => _notifications;

  Future<void> initialize() {
    if (_initialized) {
      return Future<void>.value();
    }
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          localNotificationTapBackground,
    );
    _initialized = true;
  }

  void addResponseHandler(String id, LocalNotificationResponseHandler handler) {
    _responseHandlers[id] = handler;
  }

  void removeResponseHandler(String id) {
    _responseHandlers.remove(id);
  }

  Future<void> createAndroidChannel(AndroidNotificationChannel channel) async {
    if (!Platform.isAndroid) {
      return;
    }
    await initialize();
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  Future<void> show({
    required int id,
    required String title,
    required String body,
    required NotificationDetails notificationDetails,
    String? payload,
  }) async {
    await initialize();
    await _notifications.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: notificationDetails,
      payload: payload,
    );
  }

  Future<void> cancel(int id) async {
    await initialize();
    await _notifications.cancel(id: id);
  }

  Future<bool> areNotificationsEnabled() async {
    await initialize();
    if (Platform.isAndroid) {
      final androidImpl = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await androidImpl?.areNotificationsEnabled() ?? false;
    }
    if (Platform.isIOS) {
      return _initialized;
    }
    return false;
  }

  Future<bool> requestPermissions({bool sound = true}) async {
    await initialize();
    try {
      if (Platform.isAndroid) {
        final androidImpl = _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final granted = await androidImpl?.requestNotificationsPermission();
        return granted ?? true;
      }
      if (Platform.isIOS) {
        final iosImpl = _notifications
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        final granted = await iosImpl?.requestPermissions(
          alert: true,
          badge: false,
          sound: sound,
        );
        return granted ?? false;
      }
      return false;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'notification-permission-request-failed',
        scope: 'notifications/local',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    for (final entry
        in List<MapEntry<String, LocalNotificationResponseHandler>>.from(
          _responseHandlers.entries,
        )) {
      try {
        final result = entry.value(response);
        if (result is Future<void>) {
          unawaited(
            result.catchError((Object error, StackTrace stackTrace) {
              DebugLogger.error(
                'notification-response-handler-failed',
                scope: 'notifications/local',
                error: error,
                stackTrace: stackTrace,
                data: {'handler': entry.key},
              );
            }),
          );
        }
      } catch (error, stackTrace) {
        DebugLogger.error(
          'notification-response-handler-threw',
          scope: 'notifications/local',
          error: error,
          stackTrace: stackTrace,
          data: {'handler': entry.key},
        );
      }
    }
  }
}

@pragma('vm:entry-point')
void localNotificationTapBackground(NotificationResponse response) {
  // Background isolates cannot reach the app's Riverpod graph. Foreground tap
  // handling is dispatched by LocalNotificationService when the app is active.
}
