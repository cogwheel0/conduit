import 'package:checks/checks.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/services/notification_event_classifier.dart';
import 'package:test/test.dart';

void main() {
  const classifier = NotificationEventClassifier();
  const currentUserId = 'me-123';
  const scope = 'owui:acct-1';

  // Mirrors the personal `events` stream envelope:
  // { chat_id, message_id, session_id,
  //   data: { type, data: { done, content, title } } }
  Map<String, dynamic> chatEvent({
    String? chatId = 'chat-1',
    String? messageId = 'msg-1',
    String type = 'chat:completion',
    Object? inner = const {
      'done': true,
      'content': 'Hello there',
      'title': 'Greeting',
    },
  }) => {
    'chat_id': ?chatId,
    'message_id': ?messageId,
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
        scope: scope,
      );

      check(result).isNotNull();
      check(result!.kind).equals(NotificationKind.chatCompletion);
      check(result.title).equals('Greeting');
      check(result.body).equals('Hello there');
      check(result.sourceId).equals('chat-1');
      check(result.scope).equals(scope);
      check(result.group).equals('chat:chat-1');
      check(result.read).isFalse();
    });

    test('non-terminal completion (done != true) is ignored', () {
      final result = classifier.classifyChatEvent(
        chatEvent(inner: const {'done': false, 'content': 'partial'}),
        currentUserId: currentUserId,
        scope: scope,
      );
      check(result).isNull();
    });

    test('completion with no done flag is ignored', () {
      final result = classifier.classifyChatEvent(
        chatEvent(inner: const {'content': 'partial'}),
        currentUserId: currentUserId,
        scope: scope,
      );
      check(result).isNull();
    });

    test('empty title is preserved for the surface layer to fall back', () {
      final result = classifier.classifyChatEvent(
        chatEvent(inner: const {'done': true, 'content': 'hi', 'title': ''}),
        currentUserId: currentUserId,
        scope: scope,
      );
      check(result).isNotNull();
      check(result!.title).equals('');
    });

    test('missing chat_id is ignored', () {
      final result = classifier.classifyChatEvent(
        chatEvent(chatId: null),
        currentUserId: currentUserId,
        scope: scope,
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
        scope: scope,
        );
        check(because: 'type "$type" must not notify', result).isNull();
      }
    });

    test('malformed envelopes return null without throwing', () {
      check(
        classifier.classifyChatEvent(
          {},
          currentUserId: currentUserId,
          scope: scope,
        ),
      ).isNull();
      check(
        classifier.classifyChatEvent({
          'data': 'not-a-map',
        }, currentUserId: currentUserId, scope: scope),
      ).isNull();
      check(
        classifier.classifyChatEvent({
          'chat_id': 'c',
          'data': {'type': 'chat:completion', 'data': 'not-a-map'},
        }, currentUserId: currentUserId, scope: scope),
      ).isNull();
    });

    test('dedupKey is the scoped chat and message id a push carries', () {
      final result = classifier.classifyChatEvent(
        chatEvent(),
        currentUserId: currentUserId,
        scope: scope,
      );
      check(result!.dedupKey).equals('owui:acct-1|chat:chat-1:msg-1');
    });

    test('the same reply in another account is a different key', () {
      final a = classifier.classifyChatEvent(
        chatEvent(),
        currentUserId: currentUserId,
        scope: scope,
      );
      final b = classifier.classifyChatEvent(
        chatEvent(),
        currentUserId: currentUserId,
        scope: 'owui:acct-2',
      );
      check(a!.dedupKey).not((it) => it.equals(b!.dedupKey));
    });

    test('without a message id, dedupKey is a stable content digest', () {
      final result = classifier.classifyChatEvent(
        chatEvent(messageId: null),
        currentUserId: currentUserId,
        scope: scope,
      );
      // sha1('Hello there'), the same in every process.
      check(result!.dedupKey).equals(
        'owui:acct-1|chat:chat-1:726c76553e1a3fdea29134f36e6af2ea05ec5cce',
      );
    });

    test('the preview is plain text', () {
      final result = classifier.classifyChatEvent(
        chatEvent(
          inner: const {
            'done': true,
            'content':
                '<details type="reasoning">\nplan\n</details>\n**Done.**',
          },
        ),
        currentUserId: currentUserId,
        scope: scope,
      );
      check(result!.body).equals('Done.');
    });

    test('dedupKey is stable for identical terminal frames', () {
      final a = classifier.classifyChatEvent(
        chatEvent(),
        currentUserId: currentUserId,
        scope: scope,
      );
      final b = classifier.classifyChatEvent(
        chatEvent(),
        currentUserId: currentUserId,
        scope: scope,
      );
      check(a!.dedupKey).equals(b!.dedupKey);
    });

    test('dedupKey differs for distinct responses in the same chat', () {
      final a = classifier.classifyChatEvent(
        chatEvent(
          messageId: null,
          inner: const {'done': true, 'content': 'first'},
        ),
        currentUserId: currentUserId,
        scope: scope,
      );
      final b = classifier.classifyChatEvent(
        chatEvent(
          messageId: null,
          inner: const {'done': true, 'content': 'second'},
        ),
        currentUserId: currentUserId,
        scope: scope,
      );
      check(a!.dedupKey).not((it) => it.equals(b!.dedupKey));
    });
  });

  group('classifyChannelEvent', () {
    test('message from another user in a group channel notifies', () {
      final result = classifier.classifyChannelEvent(
        channelEvent(),
        currentUserId: currentUserId,
        scope: scope,
      );

      check(result).isNotNull();
      check(result!.kind).equals(NotificationKind.channelMessage);
      check(result.title).equals('Ada (#general)');
      check(result.body).equals('Anyone around?');
      check(result.sourceId).equals('chan-1');
      check(result.dedupKey).equals('owui:acct-1|channel:chan-1:msg-1');
      check(result.group).equals('channel:chan-1');
    });

    test('DM channel title omits the channel-name suffix', () {
      final result = classifier.classifyChannelEvent(
        channelEvent(channelType: 'dm'),
        currentUserId: currentUserId,
        scope: scope,
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
        scope: scope,
      );
      check(result).isNull();
    });

    test('message with missing/empty author is ignored as malformed', () {
      final result = classifier.classifyChannelEvent(
        channelEvent(inner: const {'id': 'msg-3', 'content': 'no author'}),
        currentUserId: currentUserId,
        scope: scope,
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
        scope: scope,
        );
        check(because: 'type "$type" must not notify', result).isNull();
      }
    });

    test('missing channel_id is ignored', () {
      final result = classifier.classifyChannelEvent(
        channelEvent(channelId: null),
        currentUserId: currentUserId,
        scope: scope,
      );
      check(result).isNull();
    });

    test('dedupKey falls back to a content digest without a message id', () {
      final result = classifier.classifyChannelEvent(
        channelEvent(
          inner: const {
            'content': 'no id here',
            'user': {'id': 'other-456', 'name': 'Ada'},
          },
        ),
        currentUserId: currentUserId,
        scope: scope,
      );
      check(result).isNotNull();
      // sha1('no id here').
      check(result!.dedupKey).equals(
        'owui:acct-1|channel:chan-1:ce88d5abcba6bf81b16a0da3633b7eb6f1c34ad1',
      );
    });

    test('malformed envelopes return null without throwing', () {
      check(
        classifier.classifyChannelEvent(
          {},
          currentUserId: currentUserId,
          scope: scope,
        ),
      ).isNull();
      check(
        classifier.classifyChannelEvent({
          'channel_id': 'c',
          'data': {'type': 'message', 'data': 'not-a-map'},
        }, currentUserId: currentUserId, scope: scope),
      ).isNull();
    });
  });
}
