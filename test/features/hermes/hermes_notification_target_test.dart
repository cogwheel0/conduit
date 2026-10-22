import 'package:conduit_core/features/hermes/models/hermes_notification_target.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification tap preserves the conversation title and reads older payloads', () {
    const notification = AppNotification(
      kind: NotificationKind.chatCompletion,
      title: 'Website redesign',
      body: 'Ready',
      sourceId: 'session-1',
      dedupKey: 'reply-1',
    );
    expect(
      NotificationTap.tryDecode(NotificationTap.encode(notification))!.title,
      'Website redesign',
    );
    final older = NotificationTap.tryDecode(
      '{"kind":"chatCompletion","sourceId":"session-1"}',
    )!;
    expect(older.sourceId, 'session-1');
    expect(older.title, isNull);
  });
  test(
    'notification destination keeps the server principal and session together',
    () {
      const target = HermesNotificationTarget(
        sessionId: 'session-1',
        connectionIdentity: 'principal-a',
      );
      final decoded = HermesNotificationTarget.decode(target.encode())!;
      expect(decoded.sessionId, target.sessionId);
      expect(decoded.connectionIdentity, target.connectionIdentity);
      expect(decoded.connectionIdentity == 'principal-b', isFalse);
    },
  );

  test('invalid and oversized notification destinations are rejected', () {
    for (final value in [
      'ordinary-chat',
      '${HermesNotificationTarget.prefix}invalid',
      '${HermesNotificationTarget.prefix}${'a' * 4096}',
    ]) {
      expect(HermesNotificationTarget.decode(value), isNull);
    }
  });
}
