import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/models/app_notification.dart';
import 'package:conduit/features/notifications/services/remote_push_token_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('notificationTapFromRemoteMessageDataForTest', () {
    test('parses chat completion payloads', () {
      final tap = notificationTapFromRemoteMessageDataForTest({
        'kind': 'chat_completion',
        'chat_id': 'chat-1',
      });

      check(tap).isNotNull();
      check(tap!.kind).equals(NotificationKind.chatCompletion);
      check(tap.sourceId).equals('chat-1');
    });

    test('parses channel message payloads', () {
      final tap = notificationTapFromRemoteMessageDataForTest({
        'conduit_kind': 'channel_message',
        'conduit_source_id': 'channel-1',
      });

      check(tap).isNotNull();
      check(tap!.kind).equals(NotificationKind.channelMessage);
      check(tap.sourceId).equals('channel-1');
    });

    test('ignores payloads without a supported kind or target', () {
      check(
        notificationTapFromRemoteMessageDataForTest({
          'kind': 'unknown',
          'source_id': 'chat-1',
        }),
      ).isNull();
      check(
        notificationTapFromRemoteMessageDataForTest({
          'kind': 'chat_completion',
        }),
      ).isNull();
    });
  });
}
