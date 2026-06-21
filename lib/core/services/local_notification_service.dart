import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/debug_logger.dart';

typedef LocalNotificationResponseHandler =
    FutureOr<void> Function(NotificationResponse response);

const _backgroundResponseKey = 'local_notification_pending_response_v1';

final localNotificationServiceProvider = Provider<LocalNotificationService>(
  (ref) => LocalNotificationService.instance,
);

/// Shared owner for the flutter_local_notifications plugin.
///
/// The plugin only supports one response callback registration. Keeping that
/// callback here prevents feature services from overwriting each other.
class LocalNotificationService {
  LocalNotificationService._()
    : _isAndroid = (() => Platform.isAndroid),
      _isIOS = (() => Platform.isIOS);

  @visibleForTesting
  LocalNotificationService.testing({bool isAndroid = false, bool isIOS = false})
    : _isAndroid = (() => isAndroid),
      _isIOS = (() => isIOS);

  static final LocalNotificationService instance = LocalNotificationService._();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final Map<String, LocalNotificationResponseHandler> _responseHandlers = {};
  final List<NotificationResponse> _pendingResponses = [];
  final Map<String, Set<String>> _deliveredPendingResponseKeys = {};
  final bool Function() _isAndroid;
  final bool Function() _isIOS;

  Future<void>? _initializing;
  bool _initialized = false;

  FlutterLocalNotificationsPlugin get plugin => _notifications;

  Future<void> initialize() {
    if (_initialized) {
      return Future<void>.value();
    }
    final initializing =
        _initializing ??
        _initialize().catchError((Object error, StackTrace stackTrace) {
          _initializing = null;
          Error.throwWithStackTrace(error, stackTrace);
        });
    _initializing = initializing;
    return initializing;
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
    final startupResponseKeys = <String>{};
    await _drainStoredBackgroundResponse(startupResponseKeys);
    await _captureLaunchNotificationResponse(startupResponseKeys);
    _initialized = true;
  }

  void addResponseHandler(String id, LocalNotificationResponseHandler handler) {
    _responseHandlers[id] = handler;
    _dispatchPendingResponsesTo(id, handler);
  }

  void removeResponseHandler(String id) {
    _responseHandlers.remove(id);
    _deliveredPendingResponseKeys.remove(id);
  }

  Future<void> createAndroidChannel(AndroidNotificationChannel channel) async {
    if (!_isAndroid()) {
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
    try {
      if (_isAndroid()) {
        final androidImpl = _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        return await androidImpl?.areNotificationsEnabled() ?? false;
      }
      if (_isIOS()) {
        final iosImpl = _notifications
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        final permissions = await iosImpl?.checkPermissions();
        return permissions?.isEnabled ?? false;
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'notification-permission-check-failed',
        scope: 'notifications/local',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return false;
  }

  Future<bool> requestPermissions({bool sound = true}) async {
    await initialize();
    try {
      if (_isAndroid()) {
        final androidImpl = _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final granted = await androidImpl?.requestNotificationsPermission();
        return granted ?? true;
      }
      if (_isIOS()) {
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
    if (_responseHandlers.isEmpty) {
      _queuePendingResponse(response);
      return;
    }
    _dispatchResponse(response);
  }

  void _dispatchResponse(NotificationResponse response) {
    for (final entry
        in List<MapEntry<String, LocalNotificationResponseHandler>>.from(
          _responseHandlers.entries,
        )) {
      _dispatchResponseTo(entry.key, entry.value, response);
    }
  }

  void _dispatchPendingResponsesTo(
    String id,
    LocalNotificationResponseHandler handler,
  ) {
    for (final response in List<NotificationResponse>.from(_pendingResponses)) {
      final delivered = _deliveredPendingResponseKeys.putIfAbsent(
        id,
        () => <String>{},
      );
      if (!delivered.add(_responseKey(response))) {
        continue;
      }
      _dispatchResponseTo(id, handler, response);
    }
  }

  void _dispatchResponseTo(
    String id,
    LocalNotificationResponseHandler handler,
    NotificationResponse response,
  ) {
    try {
      final result = handler(response);
      if (result is Future<void>) {
        unawaited(
          result.catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'notification-response-handler-failed',
              scope: 'notifications/local',
              error: error,
              stackTrace: stackTrace,
              data: {'handler': id},
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
        data: {'handler': id},
      );
    }
  }

  void _queuePendingResponse(NotificationResponse response) {
    final key = _responseKey(response);
    for (final pending in _pendingResponses) {
      if (_responseKey(pending) == key) {
        return;
      }
    }
    _pendingResponses.add(response);
    if (_pendingResponses.length > 20) {
      _pendingResponses.removeRange(0, _pendingResponses.length - 20);
    }
  }

  Future<void> _drainStoredBackgroundResponse(
    Set<String> startupResponseKeys,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_backgroundResponseKey);
      if (raw == null || raw.isEmpty) {
        return;
      }
      await prefs.remove(_backgroundResponseKey);
      final response = _notificationResponseFromJson(raw);
      if (response != null) {
        _handleStartupNotificationResponse(response, startupResponseKeys);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'notification-background-response-drain-failed',
        scope: 'notifications/local',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _captureLaunchNotificationResponse(
    Set<String> startupResponseKeys,
  ) async {
    try {
      final launchDetails = await _notifications
          .getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp != true) {
        return;
      }
      final response = launchDetails?.notificationResponse;
      if (response != null) {
        _handleStartupNotificationResponse(response, startupResponseKeys);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'notification-launch-response-capture-failed',
        scope: 'notifications/local',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _handleStartupNotificationResponse(
    NotificationResponse response,
    Set<String> startupResponseKeys,
  ) {
    if (!startupResponseKeys.add(_responseKey(response))) {
      return;
    }
    _handleNotificationResponse(response);
  }
}

@pragma('vm:entry-point')
void localNotificationTapBackground(NotificationResponse response) {
  DartPluginRegistrant.ensureInitialized();
  unawaited(_storeBackgroundNotificationResponse(response));
}

Future<void> _storeBackgroundNotificationResponse(
  NotificationResponse response,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _backgroundResponseKey,
      jsonEncode(_notificationResponseToJson(response)),
    );
  } catch (_) {}
}

Map<String, dynamic> _notificationResponseToJson(
  NotificationResponse response,
) {
  return {
    'notificationResponseType': response.notificationResponseType.name,
    'id': response.id,
    'actionId': response.actionId,
    'input': response.input,
    'payload': response.payload,
    'data': response.data,
  };
}

NotificationResponse? _notificationResponseFromJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    final typeName = decoded['notificationResponseType']?.toString();
    final responseType = switch (typeName) {
      'selectedNotificationAction' =>
        NotificationResponseType.selectedNotificationAction,
      'selectedNotification' => NotificationResponseType.selectedNotification,
      _ => null,
    };
    if (responseType == null) {
      return null;
    }
    return NotificationResponse(
      notificationResponseType: responseType,
      id: decoded['id'] is int ? decoded['id'] as int : null,
      actionId: decoded['actionId']?.toString(),
      input: decoded['input']?.toString(),
      payload: decoded['payload']?.toString(),
      data: _stringKeyedMap(decoded['data']),
    );
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _stringKeyedMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const <String, dynamic>{};
}

String _responseKey(NotificationResponse response) {
  return [
    response.notificationResponseType.name,
    response.id,
    response.actionId,
    response.input,
    response.payload,
  ].join('\u001f');
}
