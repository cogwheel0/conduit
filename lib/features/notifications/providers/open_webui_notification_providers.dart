import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/local_notification_service.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/services/socket_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../models/open_webui_notification.dart';
import '../services/open_webui_notification_router.dart';

final openWebUINotificationSyncProvider = Provider<void>((ref) {
  final localNotifications = ref.read(localNotificationServiceProvider);
  final router = OpenWebUINotificationRouter(ref);
  SocketEventSubscription? chatSubscription;
  SocketEventSubscription? channelSubscription;
  SocketService? boundSocket;
  Future<void>? channelSetup;

  Future<void> ensureChannels() {
    return channelSetup ??= _ensureNotificationChannels(localNotifications);
  }

  void showNotification(
    OpenWebUINotification notification,
    SocketService socket,
  ) {
    final settings = ref.read(appSettingsProvider);
    final playSound =
        settings.notificationSoundEnabled &&
        (!socket.isAppForeground || settings.notificationSoundAlways);

    unawaited(
      (() async {
        await ensureChannels();
        await localNotifications.show(
          id: _notificationId(notification),
          title: notification.title,
          body: notification.body,
          notificationDetails: _notificationDetails(playSound: playSound),
          payload: notification.payload,
        );
      })().catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'show-notification-failed',
          scope: 'notifications/openwebui',
          error: error,
          stackTrace: stackTrace,
          data: {'kind': notification.kind.name, 'id': notification.id},
        );
      }),
    );
  }

  void handleChatEvent(SocketService socket, Map<String, dynamic> event) {
    final settings = ref.read(appSettingsProvider);
    if (!settings.responseNotificationsEnabled) {
      return;
    }

    final chatId = _chatIdFromEvent(event);
    if (chatId == null || chatId.isEmpty) {
      return;
    }
    final activeChatId = ref.read(activeConversationProvider)?.id;
    if (isTemporaryChat(chatId) && activeChatId != chatId) {
      return;
    }
    if (socket.isAppForeground && _isCurrentChat(activeChatId, chatId)) {
      return;
    }

    final notification = parseChatCompletionNotification(
      event,
      allowTemporary: activeChatId == chatId,
    );
    if (notification == null) {
      return;
    }
    showNotification(notification, socket);
  }

  void handleChannelEvent(SocketService socket, Map<String, dynamic> event) {
    final settings = ref.read(appSettingsProvider);
    if (!settings.responseNotificationsEnabled) {
      return;
    }

    final channelId = _channelIdFromEvent(event);
    if (channelId == null || channelId.isEmpty) {
      return;
    }
    if (socket.isAppForeground && _isCurrentChannel(channelId)) {
      return;
    }

    final notification = parseChannelMessageNotification(
      event,
      currentUserId: ref.read(currentUserProvider2)?.id,
    );
    if (notification == null) {
      return;
    }
    showNotification(notification, socket);
  }

  void bindSocket(SocketService? socket) {
    if (identical(boundSocket, socket)) {
      return;
    }
    chatSubscription?.dispose();
    channelSubscription?.dispose();
    chatSubscription = null;
    channelSubscription = null;
    boundSocket = socket;
    if (socket == null) {
      return;
    }
    chatSubscription = socket.addChatEventHandler(
      requireFocus: false,
      handler: (event, _) => handleChatEvent(socket, event),
    );
    channelSubscription = socket.addChannelEventHandler(
      requireFocus: false,
      handler: (event, _) => handleChannelEvent(socket, event),
    );
  }

  localNotifications.addResponseHandler(
    'openwebui-notifications',
    router.handleNotificationResponse,
  );
  unawaited(ensureChannels());
  bindSocket(ref.read(socketServiceProvider));
  ref.listen<SocketService?>(socketServiceProvider, (_, next) {
    bindSocket(next);
  });

  ref.onDispose(() {
    chatSubscription?.dispose();
    channelSubscription?.dispose();
    localNotifications.removeResponseHandler('openwebui-notifications');
  });
});

Future<void> _ensureNotificationChannels(
  LocalNotificationService notifications,
) async {
  if (!Platform.isAndroid) {
    await notifications.initialize();
    return;
  }

  const loudChannel = AndroidNotificationChannel(
    'open_webui_notifications',
    'Chat notifications',
    description: 'Assistant response and channel message notifications',
    importance: Importance.high,
    playSound: true,
    enableVibration: true,
    showBadge: true,
  );
  const silentChannel = AndroidNotificationChannel(
    'open_webui_notifications_silent',
    'Silent chat notifications',
    description: 'Assistant response and channel message notifications',
    importance: Importance.high,
    playSound: false,
    enableVibration: true,
    showBadge: true,
  );

  await notifications.createAndroidChannel(loudChannel);
  await notifications.createAndroidChannel(silentChannel);
}

NotificationDetails _notificationDetails({required bool playSound}) {
  final androidDetails = AndroidNotificationDetails(
    playSound ? 'open_webui_notifications' : 'open_webui_notifications_silent',
    playSound ? 'Chat notifications' : 'Silent chat notifications',
    channelDescription: 'Assistant response and channel message notifications',
    importance: Importance.high,
    priority: Priority.high,
    playSound: playSound,
    enableVibration: true,
    category: AndroidNotificationCategory.message,
    visibility: NotificationVisibility.private,
    icon: '@mipmap/ic_launcher',
  );
  final iosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: false,
    presentSound: playSound,
  );
  return NotificationDetails(android: androidDetails, iOS: iosDetails);
}

int _notificationId(OpenWebUINotification notification) {
  var hash = 0x811c9dc5;
  final input = '${notification.kind.name}:${notification.id}';
  for (final codeUnit in input.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return 3000 + (hash % 0x3fffffff);
}

String? _chatIdFromEvent(Map<String, dynamic> event) {
  return extractOpenWebUIChatId(event);
}

String? _channelIdFromEvent(Map<String, dynamic> event) {
  return extractOpenWebUIChannelId(event);
}

bool _isCurrentChat(String? activeChatId, String chatId) {
  if (activeChatId != chatId) {
    return false;
  }
  final uri = Uri.tryParse(NavigationService.currentRoute ?? '');
  return uri?.path == Routes.chat;
}

bool _isCurrentChannel(String channelId) {
  final uri = Uri.tryParse(NavigationService.currentRoute ?? '');
  final segments = uri?.pathSegments ?? const <String>[];
  return segments.length == 2 &&
      segments.first == 'channel' &&
      segments[1] == channelId;
}
