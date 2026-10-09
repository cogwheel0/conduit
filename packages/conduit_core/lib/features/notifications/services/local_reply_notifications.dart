import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind;
import 'package:conduit_core/features/direct_connections/services/direct_run_registry.dart';

import '../models/app_notification.dart';
import '../models/notification_scope.dart';
import 'notification_preview_text.dart';

/// The notification for a Direct reply that finished, or null when it can't
/// be attributed.
///
/// Direct runs on this device, so no server ever pushes about it. An
/// on-device chat is scoped `direct`; one stored in an Open WebUI account's
/// database belongs to that account, which a tap switches to first. The
/// dedup key is `<scope>|direct:<conversationId>:<assistantMessageId>`.
AppNotification? appNotificationForDirectRun(DirectRunCompletion completion) {
  final NotificationScope scope;
  if (completion.storage == ChatStorageKind.openWebUi) {
    final accountId = completion.openWebUiAccountId;
    if (accountId == null || accountId.isEmpty) return null;
    scope = NotificationScope.openWebUi(accountId);
  } else {
    scope = const NotificationScope.direct();
  }
  final conversationId = completion.conversationId;
  final failed = completion.failed;
  return AppNotification(
    kind: failed
        ? NotificationKind.replyFailed
        : NotificationKind.chatCompletion,
    scope: scope.value,
    title: clipNotificationText(completion.title, notificationTitleLimit),
    // A failure's own text can be technical; the surface says it failed.
    body: failed ? '' : notificationPreviewText(completion.message.content),
    sourceId: conversationId,
    dedupKey: scope.dedupKey(
      'direct:$conversationId:${completion.assistantMessageId}',
    ),
    group: 'chat:$conversationId',
  );
}
