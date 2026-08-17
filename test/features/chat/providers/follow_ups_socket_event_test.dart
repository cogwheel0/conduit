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

    expect(parsed, isNotNull);
    expect(parsed!.messageId, 'msg-1');
    expect(parsed.followUps, ['One?', 'Two?']);
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

    expect(parsed, isNotNull);
    expect(parsed!.messageId, 'msg-2');
    expect(parsed.followUps, ['A?']);
  });

  test('rejects other event types, missing ids, and empty lists', () {
    expect(
      debugParseFollowUpsSocketEventForTesting({
        'message_id': 'msg-1',
        'data': {
          'type': 'chat:title',
          'data': {
            'follow_ups': ['One?'],
          },
        },
      }),
      isNull,
    );
    expect(
      debugParseFollowUpsSocketEventForTesting({
        'data': {
          'type': 'chat:message:follow_ups',
          'data': {
            'follow_ups': ['One?'],
          },
        },
      }),
      isNull,
    );
    expect(
      debugParseFollowUpsSocketEventForTesting({
        'message_id': 'msg-1',
        'data': {
          'type': 'chat:message:follow_ups',
          'data': {
            'follow_ups': ['', '   '],
          },
        },
      }),
      isNull,
    );
  });
}
