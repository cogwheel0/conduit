import 'package:checks/checks.dart';
import 'package:conduit/core/utils/semantic_details.dart';
import 'package:conduit/features/chat/utils/follow_ups_socket_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('comparable assistant body strips semantic details with divergent '
      'attributes', () {
    const localRender =
        '<details type="reasoning" done="true" duration="0">'
        '<summary>Thought for 0 seconds</summary>\nthinking\n</details>\n'
        'The answer body.';
    const serverRender =
        '<details type="reasoning" done="true" duration="7">'
        '<summary>Thought for 7 seconds</summary>\nthinking\n</details>\n'
        'The answer body.';

    check(comparableAssistantBody(localRender))
        .equals(comparableAssistantBody(serverRender));
    check(comparableAssistantBody(localRender)).equals('The answer body.');
    // Ordinary user-authored details blocks are content and must survive.
    const plainDetails = '<details><summary>FAQ</summary>body</details>';
    check(comparableAssistantBody(plainDetails)).equals(plainDetails);
  });

  test('parses the server follow-ups envelope', () {
    final parsed = parseFollowUpsSocketEvent({
      'chat_id': 'chat-1',
      'message_id': 'msg-1',
      'data': {
        'type': 'chat:message:follow_ups',
        'data': {
          'follow_ups': ['One?', '  Two?  ', ''],
        },
      },
    });

    check(parsed).isNotNull();
    check(parsed!.messageId).equals('msg-1');
    check(parsed.followUps).deepEquals(['One?', 'Two?']);
  });

  test('accepts camelCase payload key and nested message_id', () {
    final parsed = parseFollowUpsSocketEvent({
      'data': {
        'type': 'chat:message:follow_ups',
        'message_id': 'msg-2',
        'data': {
          'followUps': ['A?'],
        },
      },
    });

    check(parsed).isNotNull();
    check(parsed!.messageId).equals('msg-2');
    check(parsed.followUps).deepEquals(['A?']);
  });

  test('rejects other event types, missing ids, and empty lists', () {
    check(
      parseFollowUpsSocketEvent({
        'message_id': 'msg-1',
        'data': {
          'type': 'chat:title',
          'data': {
            'follow_ups': ['One?'],
          },
        },
      }),
    ).isNull();
    check(
      parseFollowUpsSocketEvent({
        'data': {
          'type': 'chat:message:follow_ups',
          'data': {
            'follow_ups': ['One?'],
          },
        },
      }),
    ).isNull();
    check(
      parseFollowUpsSocketEvent({
        'message_id': 'msg-1',
        'data': {
          'type': 'chat:message:follow_ups',
          'data': {
            'follow_ups': ['', '   '],
          },
        },
      }),
    ).isNull();
  });
}
