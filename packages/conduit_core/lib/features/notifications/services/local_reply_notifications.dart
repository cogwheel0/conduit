import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind;
import 'package:conduit_core/features/direct_connections/services/direct_run_registry.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show HermesTurnCompletion;

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

/// The notification for a Hermes turn this app ran that ended, or null when
/// it can't be attributed.
///
/// The app can't know the server's turn id, so its dedup key
/// (`hermes:<connectionId>|hermes:<sessionId>:<local turn key>`) never
/// matches the push for the same turn ([AppNotification.sharesPushDedupKey]
/// is false). In the foreground the shared group `hermes:<sessionId>` lets
/// the router drop whichever comes second (docs/push/PROTOCOL.md §2); in the
/// background, where the push is shown without the router, the router
/// leaves it to the push when push is verified for the connection.
AppNotification? appNotificationForHermesTurn(
  HermesTurnCompletion completion,
) {
  final connectionId = completion.connectionId;
  final sessionId = completion.sessionId;
  if (connectionId.isEmpty || sessionId.isEmpty) return null;
  final scope = NotificationScope.hermes(connectionId);
  final failed = completion.failed;
  return AppNotification(
    kind: failed
        ? NotificationKind.replyFailed
        : NotificationKind.chatCompletion,
    scope: scope.value,
    title: clipNotificationText(completion.title, notificationTitleLimit),
    body: failed ? '' : notificationPreviewText(completion.message.content),
    sourceId: sessionId,
    dedupKey: scope.dedupKey('hermes:$sessionId:${completion.turnKey}'),
    group: 'hermes:$sessionId',
    sharesPushDedupKey: false,
  );
}
