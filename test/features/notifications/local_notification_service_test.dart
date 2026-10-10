import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:flutter/widgets.dart' show Locale;
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
  group('notificationThreadIdentifier', () {
    AppNotification notification(String scope, String? group) =>
        AppNotification(
          kind: NotificationKind.chatCompletion,
          scope: scope,
          title: 't',
          body: 'b',
          sourceId: 'c1',
          dedupKey: '$scope|chat:c1:m',
          group: group,
        );

    test('scopes the group to its account, as the push extension does', () {
      check(
        notificationThreadIdentifier(notification('owui:acct-1', 'chat:c1')),
      ).equals('owui:acct-1|chat:c1');
      check(
        notificationThreadIdentifier(notification('owui:acct-2', 'chat:c1')),
      ).equals('owui:acct-2|chat:c1');
    });

    test('falls back to the account alone without a group', () {
      check(
        notificationThreadIdentifier(notification('direct', null)),
      ).equals('direct');
    });
  });

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

    test('finds them by tag where Android lists them without payload', () {
      final picked = LocalNotificationService.notificationsInScope([
        _posted(11, null, tag: 'owui:acct-1|chat:c1:m1'),
        _posted(12, null, tag: 'owui:acct-10|chat:c2:m2'),
        _posted(13, null, tag: 'hermes:conn-1|hermes:s1:t1'),
        _posted(14, null, tag: 'owui:acct-1'),
        // A payload says which scope it is, whatever the tag.
        _posted(15, _payload('owui:acct-2', 'c3'), tag: 'owui:acct-1|x'),
      ], 'owui:acct-1');

      check(picked.map((n) => n.id)).deepEquals([11]);
    });
  });

  group('notificationDisplayBody', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    AppNotification notification(NotificationKind kind, String body) =>
        AppNotification(
          kind: kind,
          scope: 'direct',
          title: 'Trip ideas',
          body: body,
          sourceId: 'c1',
          dedupKey: 'direct|direct:c1:m:r',
        );

    test('a failed reply without a body says that it failed', () {
      check(
        notificationDisplayBody(
          notification(NotificationKind.replyFailed, ''),
          l10n,
        ),
      ).equals(l10n.notificationReplyFailedBody);
    });

    test('anything else shows its own body', () {
      check(
        notificationDisplayBody(
          notification(NotificationKind.replyFailed, 'Rate limited'),
          l10n,
        ),
      ).equals('Rate limited');
      check(
        notificationDisplayBody(
          notification(NotificationKind.chatCompletion, ''),
          l10n,
        ),
      ).equals('');
    });
  });
}
