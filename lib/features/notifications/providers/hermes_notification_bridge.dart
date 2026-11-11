import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/notifications/services/local_reply_notifications.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../services/notification_router.dart';
import 'notification_socket_listener.dart';

part 'hermes_notification_bridge.g.dart';

/// Notifies about Hermes turns this app ran that end, through the
/// [NotificationRouter].
///
/// A push for the same turn may follow from the Hermes plugin; the router
/// keeps only the first of the two for that session. Alive from app start,
/// with or without an Open WebUI session.
@Riverpod(keepAlive: true)
class HermesNotificationBridge extends _$HermesNotificationBridge {
  @override
  void build() {
    final registry = ref.watch(hermesRunRegistryProvider);
    final subscription = registry.completions.listen(_onCompletion);
    ref.onDispose(subscription.cancel);
  }

  void _onCompletion(HermesTurnCompletion completion) {
    final notification = appNotificationForHermesTurn(completion);
    if (notification == null) return;
    unawaited(
      ref.read(notificationRouterProvider).route(notification).catchError((
        Object e,
        StackTrace st,
      ) {
        DebugLogger.error(
          'hermes notification routing failed',
          error: e,
          stackTrace: st,
          scope: 'notifications/center',
        );
        return NotificationSurface.suppressed;
      }),
    );
  }
}
