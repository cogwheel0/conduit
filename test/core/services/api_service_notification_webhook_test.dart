import 'package:checks/checks.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mergeUserNotificationWebhookSettingsForTest', () {
    test('writes webhook URL under ui.notifications', () {
      final updated = mergeUserNotificationWebhookSettingsForTest({
        'notificationEnabled': true,
        'ui': {'memory': true},
      }, webhookUrl: ' https://push.example.test/hook ');

      check(updated['notificationEnabled']).equals(true);
      final ui = updated['ui'] as Map<String, dynamic>;
      check(ui['memory']).equals(true);
      final notifications = ui['notifications'] as Map<String, dynamic>;
      check(
        notifications['webhook_url'],
      ).equals('https://push.example.test/hook');
    });

    test('removes an expected existing webhook URL', () {
      final updated = mergeUserNotificationWebhookSettingsForTest(
        {
          'ui': {
            'notifications': {'webhook_url': 'https://push.example.test/old'},
          },
        },
        webhookUrl: null,
        expectedCurrentWebhookUrl: 'https://push.example.test/old',
      );

      final ui = updated['ui'] as Map<String, dynamic>;
      final notifications = ui['notifications'] as Map<String, dynamic>;
      check(notifications.containsKey('webhook_url')).isFalse();
    });

    test('refuses to overwrite a different existing webhook URL', () {
      check(
        () => mergeUserNotificationWebhookSettingsForTest({
          'ui': {
            'notifications': {'webhook_url': 'https://other.example.test/hook'},
          },
        }, webhookUrl: 'https://push.example.test/hook'),
      ).throws<UserNotificationWebhookConflictException>();
    });
  });
}
