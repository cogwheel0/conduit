import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../../core/utils/debug_logger.dart';
import '../models/app_notification.dart';
import 'local_notification_service.dart';
import 'remote_push_build_config.dart';
import 'remote_push_models.dart';

@pragma('vm:entry-point')
Future<void> conduitFirebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  // Visible background notifications are displayed by the OS. Data-only
  // background handling is intentionally a later inbox/sync concern.
}

abstract class RemotePushTokenProvider {
  Future<bool> initialize();

  Future<bool> requestPermission();

  Future<RemotePushDeviceToken?> getDeviceToken();

  Stream<RemotePushDeviceToken> get tokenRefreshes;

  Stream<NotificationTap> get taps;

  Future<NotificationTap?> launchTap();

  void dispose();
}

class FirebaseRemotePushTokenProvider implements RemotePushTokenProvider {
  FirebaseRemotePushTokenProvider({required RemotePushBuildConfig config})
    : _config = config;

  final RemotePushBuildConfig _config;
  final StreamController<RemotePushDeviceToken> _tokenRefreshes =
      StreamController<RemotePushDeviceToken>.broadcast();
  final StreamController<NotificationTap> _taps =
      StreamController<NotificationTap>.broadcast();

  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _tapSub;
  bool _initialized = false;
  Future<bool>? _initializing;

  @override
  Stream<RemotePushDeviceToken> get tokenRefreshes => _tokenRefreshes.stream;

  @override
  Stream<NotificationTap> get taps => _taps.stream;

  @override
  Future<bool> initialize() {
    if (_initialized) return Future<bool>.value(true);
    if (!_config.isConfigured) return Future<bool>.value(false);
    return _initializing ??= _doInitialize();
  }

  Future<bool> _doInitialize() async {
    try {
      final options = _config.firebaseOptionsForCurrentPlatform;
      if (options == null) return false;
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: options);
      }
      FirebaseMessaging.onBackgroundMessage(
        conduitFirebaseMessagingBackgroundHandler,
      );

      final messaging = FirebaseMessaging.instance;
      _tokenRefreshSub ??= messaging.onTokenRefresh.listen((_) {
        unawaited(_publishCurrentToken());
      });
      _tapSub ??= FirebaseMessaging.onMessageOpenedApp.listen((message) {
        final tap = notificationTapFromRemoteMessageDataForTest(message.data);
        if (tap != null && !_taps.isClosed) {
          _taps.add(tap);
        }
      });

      _initialized = true;
      return true;
    } catch (e, st) {
      DebugLogger.error(
        'failed to initialize remote push',
        error: e,
        stackTrace: st,
        scope: 'notifications/push',
      );
      return false;
    } finally {
      _initializing = null;
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!await initialize()) return false;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e, st) {
      DebugLogger.error(
        'remote push permission request failed',
        error: e,
        stackTrace: st,
        scope: 'notifications/push',
      );
      return false;
    }
  }

  @override
  Future<RemotePushDeviceToken?> getDeviceToken() async {
    if (!await initialize()) return null;
    try {
      if (Platform.isAndroid) {
        final token = (await FirebaseMessaging.instance.getToken())?.trim();
        if (token == null || token.isEmpty) return null;
        return RemotePushDeviceToken(
          platform: RemotePushPlatform.android,
          tokenType: RemotePushTokenType.fcm,
          value: token,
        );
      }
      if (Platform.isIOS) {
        for (var attempt = 0; attempt < 6; attempt++) {
          final token = (await FirebaseMessaging.instance.getAPNSToken())
              ?.trim();
          if (token != null && token.isNotEmpty) {
            return RemotePushDeviceToken(
              platform: RemotePushPlatform.ios,
              tokenType: RemotePushTokenType.apns,
              value: token,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
      }
      return null;
    } catch (e, st) {
      DebugLogger.error(
        'failed to read remote push token',
        error: e,
        stackTrace: st,
        scope: 'notifications/push',
      );
      return null;
    }
  }

  @override
  Future<NotificationTap?> launchTap() async {
    if (!await initialize()) return null;
    try {
      final message = await FirebaseMessaging.instance.getInitialMessage();
      if (message == null) return null;
      return notificationTapFromRemoteMessageDataForTest(message.data);
    } catch (e, st) {
      DebugLogger.error(
        'failed to read remote push launch tap',
        error: e,
        stackTrace: st,
        scope: 'notifications/push',
      );
      return null;
    }
  }

  Future<void> _publishCurrentToken() async {
    final token = await getDeviceToken();
    if (token != null && !_tokenRefreshes.isClosed) {
      _tokenRefreshes.add(token);
    }
  }

  @override
  void dispose() {
    _tokenRefreshSub?.cancel();
    _tapSub?.cancel();
    _tokenRefreshes.close();
    _taps.close();
  }
}

@visibleForTesting
NotificationTap? notificationTapFromRemoteMessageDataForTest(
  Map<String, dynamic> data,
) {
  final kind = _parseNotificationKind(
    data['conduit_kind'] ??
        data['kind'] ??
        data['notification_kind'] ??
        data['type'],
  );
  if (kind == null) return null;
  final sourceId = _firstNonEmptyString([
    data['conduit_source_id'],
    data['source_id'],
    data['sourceId'],
    data['chat_id'],
    data['chatId'],
    data['channel_id'],
    data['channelId'],
  ]);
  if (sourceId == null) return null;
  return NotificationTap(kind: kind, sourceId: sourceId);
}

NotificationKind? _parseNotificationKind(Object? value) {
  final normalized = value?.toString().trim();
  return switch (normalized) {
    'chat_completion' ||
    'chatCompletion' ||
    'chat:completion' => NotificationKind.chatCompletion,
    'channel_message' ||
    'channelMessage' ||
    'channel:message' ||
    'channel_message_created' => NotificationKind.channelMessage,
    _ => null,
  };
}

String? _firstNonEmptyString(List<Object?> values) {
  for (final value in values) {
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
  }
  return null;
}
