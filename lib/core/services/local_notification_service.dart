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
const _backgroundResponseKeyPrefix = 'local_notification_pending_response_v1.';
const _maxStoredBackgroundResponses = 20;

int _backgroundResponseSequence = 0;

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
  }

  @visibleForTesting
  void handleNotificationResponseForTesting(NotificationResponse response) {
    _handleNotificationResponse(response);
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
        return await _areIOSNotificationsEnabled();
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

  Future<bool> _areIOSNotificationsEnabled() async {
    final iosImpl = _notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (iosImpl == null) {
      return false;
    }
    final permissions =
        await (iosImpl as dynamic).checkPermissions()
            as NotificationsEnabledOptions?;
    return permissions?.isEnabled ?? false;
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
    _dropDeliveredPendingResponses();
  }

  void _dropDeliveredPendingResponses() {
    if (_responseHandlers.isEmpty) {
      return;
    }
    final droppedResponseKeys = <String>[];
    _pendingResponses.removeWhere((response) {
      final responseKey = _responseKey(response);
      final delivered = _responseHandlers.keys.every((id) {
        return _deliveredPendingResponseKeys[id]?.contains(responseKey) ??
            false;
      });
      if (delivered) {
        droppedResponseKeys.add(responseKey);
      }
      return delivered;
    });
    for (final responseKey in droppedResponseKeys) {
      for (final deliveredKeys in _deliveredPendingResponseKeys.values) {
        deliveredKeys.remove(responseKey);
      }
    }
    _deliveredPendingResponseKeys.removeWhere(
      (id, keys) => keys.isEmpty && !_responseHandlers.containsKey(id),
    );
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
      final responses = <NotificationResponse>[];
      final legacyRaw = prefs.getString(_backgroundResponseKey);
      if (legacyRaw != null && legacyRaw.isNotEmpty) {
        await prefs.remove(_backgroundResponseKey);
        responses.addAll(_notificationResponsesFromJson(legacyRaw));
      }
      final keys = _backgroundResponseKeys(prefs)..sort();
      for (final key in keys) {
        responses.addAll(_notificationResponsesFromJson(prefs.getString(key)));
      }
      await Future.wait(keys.map(prefs.remove));
      for (final response in responses) {
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
Future<void> localNotificationTapBackground(
  NotificationResponse response,
) async {
  DartPluginRegistrant.ensureInitialized();
  await _storeBackgroundNotificationResponse(response);
}

Future<void> _storeBackgroundNotificationResponse(
  NotificationResponse response,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _backgroundResponseStorageKey(response),
      jsonEncode(_notificationResponseToJson(response)),
    );
    final keys = _backgroundResponseKeys(prefs)..sort();
    if (keys.length > _maxStoredBackgroundResponses) {
      await Future.wait(
        keys
            .take(keys.length - _maxStoredBackgroundResponses)
            .map(prefs.remove),
      );
    }
  } catch (_) {}
}

List<String> _backgroundResponseKeys(SharedPreferences prefs) {
  return prefs
      .getKeys()
      .where((key) => key.startsWith(_backgroundResponseKeyPrefix))
      .toList(growable: false);
}

String _backgroundResponseStorageKey(NotificationResponse response) {
  final timestamp = DateTime.now()
      .toUtc()
      .microsecondsSinceEpoch
      .toString()
      .padLeft(20, '0');
  final sequence = (_backgroundResponseSequence++ & 0xffff)
      .toRadixString(16)
      .padLeft(4, '0');
  final fingerprint = _responseKey(
    response,
  ).hashCode.toUnsigned(32).toRadixString(16).padLeft(8, '0');
  return '$_backgroundResponseKeyPrefix$timestamp-$sequence-$fingerprint';
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

List<NotificationResponse> _notificationResponsesFromJson(String? raw) {
  if (raw == null || raw.isEmpty) {
    return <NotificationResponse>[];
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .map(_notificationResponseFromDecoded)
          .nonNulls
          .toList(growable: true);
    }
    final response = _notificationResponseFromDecoded(decoded);
    return response == null ? <NotificationResponse>[] : [response];
  } catch (_) {
    return <NotificationResponse>[];
  }
}

NotificationResponse? _notificationResponseFromDecoded(Object? decoded) {
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
