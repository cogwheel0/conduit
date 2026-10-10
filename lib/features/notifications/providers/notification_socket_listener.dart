import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/providers/app_providers.dart';

import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/socket_service.dart';

import '../../../core/utils/current_localizations.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'package:conduit_core/features/notifications/services/active_view_tracker.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';

import '../services/local_notification_service.dart';
import '../services/notification_tap_router.dart';

import 'package:conduit_core/features/notifications/services/notification_event_classifier.dart';

import '../services/notification_router.dart';
import '../services/notification_sound_service.dart';

part 'notification_socket_listener.g.dart';

const _classifier = NotificationEventClassifier();

/// Builds the [NotificationRouter], wiring it to live app state. keepAlive so
/// its dedup memory persists across socket re-binds.
@Riverpod(keepAlive: true)
NotificationRouter notificationRouter(Ref ref) {
  return NotificationRouter(
    readSettings: () => ref.read(appSettingsProvider),
    readActiveView: () => ref.read(activeViewProvider),
    isAppForeground: _isAppForeground,
    localNotifications: ref.read(localNotificationServiceProvider),
    sound: ref.read(notificationSoundServiceProvider),
    showInAppBanner: (n) => _showInAppBanner(ref, n),
    onChannelUnread: (n) => _bumpChannelUnread(ref, n),
    // The ledger the push extension shares: a socket notification and a push
    // for the same event never both show.
    claim: (dedupKey, localNotificationId) =>
        _claimForPush(ref, dedupKey, localNotificationId),
    scopeNotificationsEnabled: (scope) => notificationsEnabledForScope(
      scope,
      activeValue: ref.read(appSettingsProvider).notificationsEnabled,
    ),
    pushVerified: (scope) => _pushVerified(ref, scope),
  );
}

/// Whether push is on for [scope]: turned on, not opted out, and a test push
/// decrypted on this device.
bool _pushVerified(Ref ref, String scope) {
  final push = ref.read(pushStateIfUsedProvider);
  if (push == null || !push.enabled) return false;
  final target = push.targets[scope];
  return target != null &&
      !target.optedOut &&
      (target.status == PushStatus.on ||
          target.status == PushStatus.updateAvailable);
}

Future<bool> _claimForPush(
  Ref ref,
  String dedupKey,
  String? localNotificationId,
) async {
  try {
    return await ref
        .read(pushPlatformPortProvider)
        .claimNotification(
          dedupKey,
          localNotificationId: localNotificationId,
        );
  } catch (error) {
    // Without the ledger nothing else can have shown it.
    DebugLogger.warning(
      'push-claim-failed',
      scope: 'notifications/center',
      data: {'errorType': error.runtimeType.toString()},
    );
    return true;
  }
}

bool _isAppForeground() {
  final state = WidgetsBinding.instance.lifecycleState;
  // Null very early in startup — treat as foreground so banners work.
  return state == null || state == AppLifecycleState.resumed;
}

void _showInAppBanner(Ref ref, AppNotification notification) {
  final context = NavigationService.navigatorKey.currentContext;
  if (context == null) return;
  final l10n = currentAppLocalizations();
  // A failed reply without a body says that it failed, as the system
  // notification does.
  final body = notificationDisplayBody(notification, l10n);
  final message = notification.title.isNotEmpty
      ? '${notification.title}: $body'
      : body;
  AdaptiveSnackBar.show(
    context,
    message: message,
    type: AdaptiveSnackBarType.info,
    action: l10n.notificationViewAction,
    onActionPressed: () => unawaited(
      ref.read(notificationTapRouterProvider).openNotification(notification),
    ),
  );
}

void _bumpChannelUnread(Ref ref, AppNotification notification) {
  final list = ref.read(channelsListProvider).value;
  if (list == null) return;
  for (final channel in list) {
    if (channel.id == notification.sourceId) {
      ref
          .read(channelsListProvider.notifier)
          .updateChannel(
            channel.copyWith(unreadCount: channel.unreadCount + 1),
          );
      return;
    }
  }
}

/// Single global subscriber that turns socket events into notifications.
///
/// Mirrors `ActiveChatsSync._bindSocket`: one chat handler + one channel
/// handler, both `requireFocus:false`, re-bound on socket change and on
/// reconnect. The [NotificationRouter] (not this class) owns all gating, so the
/// listener can run unconditionally — when notifications are disabled the router
/// simply drops everything.
@Riverpod(keepAlive: true)
class NotificationSocketListener extends _$NotificationSocketListener {
  SocketEventSubscription? _chatSub;
  SocketEventSubscription? _channelSub;
  StreamSubscription<void>? _reconnectSub;
  SocketService? _boundSocket;

  @override
  void build() {
    ref.onDispose(() {
      _chatSub?.dispose();
      _channelSub?.dispose();
      _reconnectSub?.cancel();
    });

    _bindSocket(ref.read(socketServiceProvider));
    ref.listen<SocketService?>(socketServiceProvider, (_, next) {
      _bindSocket(next);
    });
  }

  void _bindSocket(SocketService? socket) {
    if (identical(socket, _boundSocket)) return;
    _boundSocket = socket;
    _chatSub?.dispose();
    _chatSub = null;
    _channelSub?.dispose();
    _channelSub = null;
    _reconnectSub?.cancel();
    _reconnectSub = null;
    if (socket == null) return;

    // Wildcard handlers (all selectors null) so we see every chat/channel event.
    _chatSub = socket.addChatEventHandler(
      requireFocus: false,
      handler: (event, _) => _onChatEvent(event),
    );
    _channelSub = socket.addChannelEventHandler(
      requireFocus: false,
      handler: (event, _) => _onChannelEvent(event),
    );

    // Unread counts can drift while disconnected; reconcile from the server.
    _reconnectSub = socket.onReconnect.listen((_) {
      unawaited(ref.read(channelsListProvider.notifier).refresh());
      // Socket.IO does not replay channel history. Drop every keepAlive family
      // instance so an open thread and a channel reopened later both fetch an
      // authoritative page instead of retaining the pre-disconnect snapshot.
      ref.invalidate(channelMessagesProvider);
      ref.invalidate(threadMessagesProvider);
    });
  }

  String get _currentUserId => ref.read(currentUserProvider).value?.id ?? '';

  /// The scope of the account whose socket this is: the active one. Null
  /// before an account settles, when nothing can be attributed to one.
  String? get _scope {
    final accountId = ref.read(settledActiveAccountIdProvider);
    if (accountId == null || accountId.isEmpty) return null;
    return NotificationScope.openWebUi(accountId).value;
  }

  void _onChatEvent(Map<String, dynamic> event) {
    final scope = _scope;
    if (scope == null) return;
    final notification = _classifier.classifyChatEvent(
      event,
      currentUserId: _currentUserId,
      scope: scope,
    );
    if (notification != null) _route(notification);
  }

  void _onChannelEvent(Map<String, dynamic> event) {
    final userId = _currentUserId;
    // Until the current user resolves we can't run the self-author filter, so
    // skip rather than risk notifying the user for their own messages.
    if (userId.isEmpty) return;
    final scope = _scope;
    if (scope == null) return;
    final notification = _classifier.classifyChannelEvent(
      event,
      currentUserId: userId,
      scope: scope,
    );
    if (notification != null) _route(notification);
  }

  void _route(AppNotification notification) {
    unawaited(
      ref.read(notificationRouterProvider).route(notification).catchError((
        Object e,
        StackTrace st,
      ) {
        DebugLogger.error(
          'notification routing failed',
          error: e,
          stackTrace: st,
          scope: 'notifications/center',
        );
        return NotificationSurface.suppressed;
      }),
    );
  }
}
