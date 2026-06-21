import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/notifications/models/open_webui_notification.dart';

void main() {
  group('parseChatCompletionNotification', () {
    test('builds a notification for done chat completions', () {
      final notification = parseChatCompletionNotification({
        'chat_id': 'chat-1',
        'data': {
          'type': 'chat:completion',
          'data': {
            'done': true,
            'title': 'Planning',
            'content': 'The answer is ready.',
          },
        },
      });

      check(notification).isNotNull();
      check(notification!.kind).equals(OpenWebUINotificationKind.chat);
      check(notification.id).equals('chat-1');
      check(notification.title).equals('Planning - Open WebUI');
      check(notification.body).equals('The answer is ready.');

      final payload = decodeOpenWebUINotificationPayload(notification.payload);
      check(payload).isNotNull();
      check(payload!.kind).equals(OpenWebUINotificationKind.chat);
      check(payload.id).equals('chat-1');
    });

    test('reads nested chat ids from socket data', () {
      final notification = parseChatCompletionNotification({
        'data': {
          'type': 'chat:completion',
          'chat_id': 'chat-nested',
          'data': {'done': true, 'content': 'Nested answer.'},
        },
      });

      check(notification).isNotNull();
      check(notification!.id).equals('chat-nested');
    });

    test('ignores non-final completion chunks', () {
      final notification = parseChatCompletionNotification({
        'chat_id': 'chat-1',
        'data': {
          'type': 'chat:completion',
          'data': {'done': false, 'content': 'partial'},
        },
      });

      check(notification).isNull();
    });

    test('keeps done completions without final content', () {
      final notification = parseChatCompletionNotification({
        'chat_id': 'chat-1',
        'data': {
          'type': 'chat:completion',
          'data': {'done': true, 'title': 'Planning'},
        },
      });

      check(notification).isNotNull();
      check(notification!.title).equals('Planning - Open WebUI');
      check(notification.body).equals('Assistant response ready');
    });

    test('ignores temporary chats unless explicitly allowed', () {
      final event = {
        'chat_id': 'local:socket-1',
        'data': {
          'type': 'chat:completion',
          'data': {'done': true, 'content': 'private'},
        },
      };

      check(parseChatCompletionNotification(event)).isNull();
      check(
        parseChatCompletionNotification(event, allowTemporary: true),
      ).isNotNull();
    });
  });

  group('parseChannelMessageNotification', () {
    test('builds a notification for channel messages', () {
      final notification = parseChannelMessageNotification({
        'channel_id': 'channel-1',
        'user': {'id': 'user-2', 'name': 'Avery'},
        'channel': {'type': 'group', 'name': 'ops'},
        'data': {
          'type': 'message',
          'data': {
            'content': 'Can you check this?',
            'user': {'id': 'user-2', 'name': 'Avery'},
          },
        },
      }, currentUserId: 'user-1');

      check(notification).isNotNull();
      check(notification!.kind).equals(OpenWebUINotificationKind.channel);
      check(notification.id).equals('channel-1');
      check(notification.title).equals('Avery (#ops) - Open WebUI');
      check(notification.body).equals('Can you check this?');
    });

    test('reads nested channel ids from socket data', () {
      final notification = parseChannelMessageNotification({
        'user': {'id': 'user-2', 'name': 'Avery'},
        'channel': {'type': 'group', 'name': 'ops'},
        'data': {
          'type': 'message',
          'channel_id': 'channel-nested',
          'data': {'content': 'Nested message.'},
        },
      }, currentUserId: 'user-1');

      check(notification).isNotNull();
      check(notification!.id).equals('channel-nested');
    });

    test('omits channel suffix for direct messages', () {
      final notification = parseChannelMessageNotification({
        'channel_id': 'dm-1',
        'user': {'id': 'user-2', 'name': 'Avery'},
        'channel': {'type': 'dm', 'name': 'Avery'},
        'data': {
          'type': 'message',
          'data': {'content': 'Hello'},
        },
      });

      check(notification).isNotNull();
      check(notification!.title).equals('Avery - Open WebUI');
    });

    test('ignores messages from the current user', () {
      final notification = parseChannelMessageNotification({
        'channel_id': 'channel-1',
        'user': {'id': 'user-1', 'name': 'Me'},
        'data': {
          'type': 'message',
          'data': {'content': 'Mine'},
        },
      }, currentUserId: 'user-1');

      check(notification).isNull();
    });
  });

  group('sanitizeNotificationText', () {
    test('strips markdown, html, and control characters', () {
      final text = sanitizeNotificationText(
        '# Hello <b>there</b>\n[link](https://example.com)\u0000',
      );

      check(text).equals('Hello there link');
    });

    test('truncates long content', () {
      final text = sanitizeNotificationText('abcdef', maxLength: 5);

      check(text).equals('ab...');
    });
  });
}
