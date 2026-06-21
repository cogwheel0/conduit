import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../../core/database/local_conversation_loader.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../chat/providers/chat_providers.dart' as chat;
import '../models/open_webui_notification.dart';

class OpenWebUINotificationRouter {
  const OpenWebUINotificationRouter(this.ref);

  final Ref ref;

  Future<void> handleNotificationResponse(NotificationResponse response) async {
    final payload = decodeOpenWebUINotificationPayload(response.payload);
    if (payload == null) {
      return;
    }

    switch (payload.kind) {
      case OpenWebUINotificationKind.chat:
        await openChat(payload.id);
        break;
      case OpenWebUINotificationKind.channel:
        NavigationService.navigateToChannel(payload.id);
        break;
    }
  }

  Future<void> openChat(String chatId) async {
    if (chatId.isEmpty) {
      return;
    }

    try {
      final selectedReadAt = DateTime.now();
      final previousId = ref.read(activeConversationProvider)?.id;
      if (previousId != chatId) {
        markConversationRead(ref, previousId);
      }
      markConversationRead(ref, chatId, readAt: selectedReadAt);

      ref.read(chat.isLoadingConversationProvider.notifier).set(true);
      ref.read(activeConversationProvider.notifier).clear();
      ref.read(chat.chatMessagesProvider.notifier).clearMessages();
      ref.read(pendingFolderIdProvider.notifier).clear();

      NavigationService.router.go(Routes.chat);

      final local = await loadLocalConversation(ref, chatId);
      if (local != null) {
        ref
            .read(activeConversationProvider.notifier)
            .set(_withOptimisticReadAt(local, selectedReadAt));
        schedulePullChatNow(ref, chatId);
        return;
      }

      final api = ref.read(apiServiceProvider);
      if (api != null) {
        final remote = await api.getConversation(chatId);
        ref
            .read(activeConversationProvider.notifier)
            .set(_withOptimisticReadAt(remote, selectedReadAt));
        schedulePullChatNow(ref, chatId);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'notification-open-chat-failed',
        scope: 'notifications/openwebui',
        error: error,
        stackTrace: stackTrace,
        data: {'chatId': chatId},
      );
    } finally {
      try {
        ref.read(chat.isLoadingConversationProvider.notifier).set(false);
      } catch (_) {}
    }
  }

  Conversation _withOptimisticReadAt(
    Conversation conversation,
    DateTime selectedReadAt,
  ) {
    final readAt = conversation.lastReadAt;
    return readAt == null || selectedReadAt.isAfter(readAt)
        ? conversation.copyWith(lastReadAt: selectedReadAt)
        : conversation;
  }
}
