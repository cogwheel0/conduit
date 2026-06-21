import 'dart:async';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/database/local_conversation_loader.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/services/socket_service.dart';
import '../../../core/utils/current_localizations.dart';
import '../../../core/utils/debug_logger.dart';
import '../../channels/providers/channel_providers.dart';
import '../models/app_notification.dart';
import '../services/active_view_tracker.dart';
import '../services/local_notification_service.dart';
import '../services/notification_event_classifier.dart';
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
  );
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
  final message = notification.title.isNotEmpty
      ? '${notification.title}: ${notification.body}'
      : notification.body;
  AdaptiveSnackBar.show(
    context,
    message: message,
    type: AdaptiveSnackBarType.info,
    action: l10n.notificationViewAction,
    onActionPressed: () => _handleTap(
      ref,
      NotificationTap(kind: notification.kind, sourceId: notification.sourceId),
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

Future<void> _handleTap(Ref ref, NotificationTap tap) async {
  // Fire-and-forget from tap streams / cold launch — never let a navigation
  // failure surface as an uncaught async error.
  try {
    switch (tap.kind) {
      case NotificationKind.channelMessage:
        NavigationService.navigateToChannel(tap.sourceId);
      case NotificationKind.chatCompletion:
        // DB-first open, mirroring the conversation-list selection flow.
        await NavigationService.navigateToChat();
        final local = await loadLocalConversation(ref, tap.sourceId);
        if (local != null) {
          ref.read(activeConversationProvider.notifier).set(local);
        }
        schedulePullChatNow(ref, tap.sourceId);
    }
  } catch (e, st) {
    DebugLogger.error(
      'notification deep-link failed',
      error: e,
      stackTrace: st,
      scope: 'notifications/center',
    );
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
  StreamSubscription<NotificationTap>? _tapSub;
  SocketService? _boundSocket;

  @override
  void build() {
    ref.onDispose(() {
      _chatSub?.dispose();
      _channelSub?.dispose();
      _reconnectSub?.cancel();
      _tapSub?.cancel();
    });

    final local = ref.read(localNotificationServiceProvider);
    // Initialize the plugin (channel + tap handler) without requesting
    // permission — permission is requested on master-toggle opt-in.
    unawaited(local.initialize());

    // System-notification taps (foreground) route to the target.
    _tapSub = local.taps.listen((tap) {
      unawaited(_handleTap(ref, tap));
    });

    _bindSocket(ref.read(socketServiceProvider));
    ref.listen<SocketService?>(socketServiceProvider, (_, next) {
      _bindSocket(next);
    });
  }

  /// Handles a notification that cold-launched the app from a killed state.
  /// Called once after the router is ready.
  Future<void> handleLaunchTap() async {
    final local = ref.read(localNotificationServiceProvider);
    // Ensure the plugin finished native init before querying the launch intent:
    // on Android getNotificationAppLaunchDetails() returns null until then, so
    // racing it would silently drop the deep link. initialize() is idempotent
    // and shares the in-flight future started in build().
    await local.initialize();
    final tap = await local.launchTap();
    if (tap != null) {
      await _handleTap(ref, tap);
    }
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
    });
  }

  String get _currentUserId =>
      ref.read(currentUserProvider).value?.id ?? '';

  void _onChatEvent(Map<String, dynamic> event) {
    final notification = _classifier.classifyChatEvent(
      event,
      currentUserId: _currentUserId,
    );
    if (notification != null) _route(notification);
  }

  void _onChannelEvent(Map<String, dynamic> event) {
    final notification = _classifier.classifyChannelEvent(
      event,
      currentUserId: _currentUserId,
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
