import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/notifications/services/local_reply_notifications.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../services/notification_router.dart';
import 'notification_socket_listener.dart';

part 'direct_notification_bridge.g.dart';

/// Notifies about Direct replies that finish, through the
/// [NotificationRouter].
///
/// Direct runs on this device, so no server pushes about it: when a reply
/// finishes while the app is in the background, this is what posts the
/// system notification. In the foreground the router shows a banner, unless
/// that chat is on screen. Alive from app start, with or without an Open
/// WebUI session; it follows the run registry across sign-outs.
@Riverpod(keepAlive: true)
class DirectNotificationBridge extends _$DirectNotificationBridge {
  @override
  void build() {
    final registry = ref.watch(directRunRegistryProvider);
    final subscription = registry.completions.listen(_onCompletion);
    ref.onDispose(subscription.cancel);
  }

  void _onCompletion(DirectRunCompletion completion) {
    final notification = appNotificationForDirectRun(completion);
    if (notification == null) return;
    unawaited(
      ref.read(notificationRouterProvider).route(notification).catchError((
        Object e,
        StackTrace st,
      ) {
        DebugLogger.error(
          'direct notification routing failed',
          error: e,
          stackTrace: st,
          scope: 'notifications/center',
        );
        return NotificationSurface.suppressed;
      }),
    );
  }
}
