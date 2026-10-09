import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

ActiveNotification _posted(int? id, String? payload, {String? tag}) =>
    ActiveNotification(id: id, payload: payload, tag: tag);

String _payload(String scope, String sourceId) => NotificationTap.encode(
  AppNotification(
    kind: NotificationKind.chatCompletion,
    scope: scope,
    title: 't',
    body: 'b',
    sourceId: sourceId,
    dedupKey: '$scope|chat:$sourceId:m',
  ),
);

void main() {
  group('notificationsInScope', () {
    test('picks the scope\'s own and leaves other accounts\' alone', () {
      final active = [
        _posted(1, _payload('owui:acct-1', 'c1'), tag: 'owui:acct-1|a'),
        _posted(2, _payload('owui:acct-2', 'c2'), tag: 'owui:acct-2|b'),
        _posted(3, _payload('hermes:conn-1', 's1')),
        _posted(4, _payload('owui:acct-1', 'c3')),
      ];

      final picked = LocalNotificationService.notificationsInScope(
        active,
        'owui:acct-1',
      );

      check(picked.map((n) => n.id)).deepEquals([1, 4]);
      check(picked.first.tag).equals('owui:acct-1|a');
    });

    test('takes taps from before scopes, which no account can claim', () {
      final picked = LocalNotificationService.notificationsInScope([
        _posted(7, '{"kind":"chatCompletion","sourceId":"c1"}'),
      ], 'owui:acct-1');

      check(picked.map((n) => n.id)).deepEquals([7]);
    });

    test('leaves notifications that are not message notifications', () {
      final picked = LocalNotificationService.notificationsInScope([
        _posted(9, 'voice-call'),
        _posted(10, null),
        _posted(null, _payload('owui:acct-1', 'c1')),
      ], 'owui:acct-1');

      check(picked).isEmpty();
    });
  });
}
