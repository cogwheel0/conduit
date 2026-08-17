import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the server follow-ups envelope', () {
    final parsed = debugParseFollowUpsSocketEventForTesting({
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
    final parsed = debugParseFollowUpsSocketEventForTesting({
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
      debugParseFollowUpsSocketEventForTesting({
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
      debugParseFollowUpsSocketEventForTesting({
        'data': {
          'type': 'chat:message:follow_ups',
          'data': {
            'follow_ups': ['One?'],
          },
        },
      }),
    ).isNull();
    check(
      debugParseFollowUpsSocketEventForTesting({
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
