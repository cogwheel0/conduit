import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'package:conduit_core/features/notifications/services/cp1_notification_mapper.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/notification_router.dart';
import '../services/notification_tap_router.dart';
import 'notification_socket_listener.dart';

part 'push_notification_listener.g.dart';

/// Hands decrypted pushes the platform gives the app to the notification
/// router, and tapped ones to the tap router.
///
/// Alive from app start, whichever backends are in use: a push belongs to
/// any account or connection, and the active one changing must not drop it.
@Riverpod(keepAlive: true)
class PushNotificationListener extends _$PushNotificationListener {
  Future<PushTap?>? _launchTap;
  bool _launchTapOpened = false;

  @override
  void build() {
    final subscription = ref
        .read(pushPlatformPortProvider)
        .events
        .listen(
          _onEvent,
          onError: (Object error) => DebugLogger.warning(
            'push-event-failed',
            scope: 'notifications/push',
            data: {'errorType': error.runtimeType.toString()},
          ),
        );
    ref.onDispose(subscription.cancel);
  }

  void _onEvent(PushPlatformEvent event) {
    switch (event) {
      case PushForegroundEvent(:final message):
        _route(message);
      case PushTapEvent(:final tap):
        unawaited(_open(tap));
      case PushTokenEvent() ||
          PushTestReceivedEvent() ||
          PushUnregisteredEvent() ||
          PushUnifiedPushEndpointEvent():
        // The push coordinator handles these.
        break;
    }
  }

  /// A push that arrived while the app was in the foreground: the platform
  /// showed nothing, so the router decides between a banner and nothing.
  void _route(PushMessage message) {
    final notification = appNotificationFromCp1Json(
      message.payloadJson,
      scope: message.scope,
    );
    // A test push only proves delivery; the push coordinator counts it.
    if (notification == null ||
        notification.kind == NotificationKind.pushTest) {
      return;
    }
    unawaited(
      ref
          .read(notificationRouterProvider)
          // The platform claimed it before handing it over: the iOS
          // notification service extension, or the Android receiver.
          .route(notification, alreadyClaimed: true)
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'push-routing-failed',
              scope: 'notifications/push',
              error: error,
              stackTrace: stackTrace,
            );
            return NotificationSurface.suppressed;
          }),
    );
  }

  Future<void> _open(PushTap tap) async {
    try {
      final Object? payload;
      try {
        payload = jsonDecode(tap.payloadJson);
      } on FormatException {
        return;
      }
      await ref
          .read(notificationTapRouterProvider)
          .openCp1(payload, scope: tap.scope);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'push-tap-failed',
        scope: 'notifications/push',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Opens the push notification that cold-launched the app, once.
  ///
  /// Same rule as the local notification launch tap: one into an Open WebUI
  /// account waits for a call that says its session is up ([openWebUiReady]);
  /// one for Hermes opens on the first call.
  Future<void> handleLaunchTap({required bool openWebUiReady}) async {
    final tap = await (_launchTap ??= _takeLaunchTap());
    if (tap == null || _launchTapOpened || !ref.mounted) return;
    final needsOpenWebUi =
        NotificationScope.tryParse(tap.scope) is OpenWebUiNotificationScope;
    if (needsOpenWebUi && !openWebUiReady) return;
    _launchTapOpened = true;
    await _open(tap);
  }

  Future<PushTap?> _takeLaunchTap() async {
    try {
      return await ref.read(pushPlatformPortProvider).takeLaunchTap();
    } catch (error) {
      DebugLogger.warning(
        'push-launch-tap-failed',
        scope: 'notifications/push',
        data: {'errorType': error.runtimeType.toString()},
      );
      return null;
    }
  }
}
