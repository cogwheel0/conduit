import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/models/app_notification.dart';
import 'package:conduit/features/notifications/services/notification_event_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const classifier = NotificationEventClassifier();
  const currentUserId = 'me-123';

  // Mirrors the personal `events` stream envelope:
  // { chat_id, session_id, data: { type, data: { done, content, title } } }
  Map<String, dynamic> chatEvent({
    String? chatId = 'chat-1',
    String type = 'chat:completion',
    Object? inner = const {
      'done': true,
      'content': 'Hello there',
      'title': 'Greeting',
    },
  }) => {
    'chat_id': ?chatId,
    'session_id': 'sess-1',
    'data': {'type': type, 'data': inner},
  };

  // Mirrors the `events:channel` stream envelope:
  // { channel_id, channel: {type,name}, data: { type, data: {...message} } }
  Map<String, dynamic> channelEvent({
    String? channelId = 'chan-1',
    String type = 'message',
    String channelType = 'group',
    String channelName = 'general',
    Object? inner = const {
      'id': 'msg-1',
      'content': 'Anyone around?',
      'user': {'id': 'other-456', 'name': 'Ada'},
    },
  }) => {
    'channel_id': ?channelId,
    'channel': {'type': channelType, 'name': channelName},
    'data': {'type': type, 'data': inner},
  };

  group('classifyChatEvent', () {
    test('terminal completion in another chat yields a notification', () {
      final result = classifier.classifyChatEvent(
        chatEvent(),
        currentUserId: currentUserId,
      );

      check(result).isNotNull();
      check(result!.kind).equals(NotificationKind.chatCompletion);
      check(result.title).equals('Greeting');
      check(result.body).equals('Hello there');
      check(result.sourceId).equals('chat-1');
      check(result.read).isFalse();
    });

    test('non-terminal completion (done != true) is ignored', () {
      final result = classifier.classifyChatEvent(
        chatEvent(inner: const {'done': false, 'content': 'partial'}),
        currentUserId: currentUserId,
      );
      check(result).isNull();
    });

    test('completion with no done flag is ignored', () {
      final result = classifier.classifyChatEvent(
        chatEvent(inner: const {'content': 'partial'}),
        currentUserId: currentUserId,
      );
      check(result).isNull();
    });

    test('empty title is preserved for the surface layer to fall back', () {
      final result = classifier.classifyChatEvent(
        chatEvent(inner: const {'done': true, 'content': 'hi', 'title': ''}),
        currentUserId: currentUserId,
      );
      check(result).isNotNull();
      check(result!.title).equals('');
    });

    test('missing chat_id is ignored', () {
      final result = classifier.classifyChatEvent(
        chatEvent(chatId: null),
        currentUserId: currentUserId,
      );
      check(result).isNull();
    });

    test('non-notifiable chat types are ignored', () {
      for (final type in const [
        'chat:title',
        'chat:tags',
        'chat:message:error',
        'chat:message:delta',
        'request:chat:completion',
      ]) {
        final result = classifier.classifyChatEvent(
          chatEvent(type: type),
          currentUserId: currentUserId,
        );
        check(because: 'type "$type" must not notify', result).isNull();
      }
    });

    test('malformed envelopes return null without throwing', () {
      check(
        classifier.classifyChatEvent({}, currentUserId: currentUserId),
      ).isNull();
      check(
        classifier.classifyChatEvent({
          'data': 'not-a-map',
        }, currentUserId: currentUserId),
      ).isNull();
      check(
        classifier.classifyChatEvent({
          'chat_id': 'c',
          'data': {'type': 'chat:completion', 'data': 'not-a-map'},
        }, currentUserId: currentUserId),
      ).isNull();
    });

    test('dedupKey is stable for identical terminal frames', () {
      final a = classifier.classifyChatEvent(
        chatEvent(),
        currentUserId: currentUserId,
      );
      final b = classifier.classifyChatEvent(
        chatEvent(),
        currentUserId: currentUserId,
      );
      check(a!.dedupKey).equals(b!.dedupKey);
    });

    test('dedupKey differs for distinct responses in the same chat', () {
      final a = classifier.classifyChatEvent(
        chatEvent(inner: const {'done': true, 'content': 'first'}),
        currentUserId: currentUserId,
      );
      final b = classifier.classifyChatEvent(
        chatEvent(inner: const {'done': true, 'content': 'second'}),
        currentUserId: currentUserId,
      );
      check(a!.dedupKey).not((it) => it.equals(b!.dedupKey));
    });
  });

  group('classifyChannelEvent', () {
    test('message from another user in a group channel notifies', () {
      final result = classifier.classifyChannelEvent(
        channelEvent(),
        currentUserId: currentUserId,
      );

      check(result).isNotNull();
      check(result!.kind).equals(NotificationKind.channelMessage);
      check(result.title).equals('Ada (#general)');
      check(result.body).equals('Anyone around?');
      check(result.sourceId).equals('chan-1');
      check(result.dedupKey).equals('channel:chan-1:msg-1');
    });

    test('DM channel title omits the channel-name suffix', () {
      final result = classifier.classifyChannelEvent(
        channelEvent(channelType: 'dm'),
        currentUserId: currentUserId,
      );
      check(result).isNotNull();
      check(result!.title).equals('Ada');
    });

    test('self-authored message is ignored', () {
      final result = classifier.classifyChannelEvent(
        channelEvent(
          inner: const {
            'id': 'msg-2',
            'content': 'my own message',
            'user': {'id': currentUserId, 'name': 'Me'},
          },
        ),
        currentUserId: currentUserId,
      );
      check(result).isNull();
    });

    test('non-message channel types are ignored', () {
      for (final type in const [
        'message:reply',
        'message:reaction:add',
        'message:reaction:remove',
        'message:update',
        'message:delete',
        'channel:created',
        'channel:delete',
        'typing',
      ]) {
        final result = classifier.classifyChannelEvent(
          channelEvent(type: type),
          currentUserId: currentUserId,
        );
        check(because: 'type "$type" must not notify', result).isNull();
      }
    });

    test('missing channel_id is ignored', () {
      final result = classifier.classifyChannelEvent(
        channelEvent(channelId: null),
        currentUserId: currentUserId,
      );
      check(result).isNull();
    });

    test('dedupKey falls back to content hash when message id is absent', () {
      final result = classifier.classifyChannelEvent(
        channelEvent(
          inner: const {
            'content': 'no id here',
            'user': {'id': 'other-456', 'name': 'Ada'},
          },
        ),
        currentUserId: currentUserId,
      );
      check(result).isNotNull();
      check(result!.dedupKey).equals('channel:chan-1:${'no id here'.hashCode}');
    });

    test('malformed envelopes return null without throwing', () {
      check(
        classifier.classifyChannelEvent({}, currentUserId: currentUserId),
      ).isNull();
      check(
        classifier.classifyChannelEvent({
          'channel_id': 'c',
          'data': {'type': 'message', 'data': 'not-a-map'},
        }, currentUserId: currentUserId),
      ).isNull();
    });
  });
}
