import 'package:checks/checks.dart';
import 'package:conduit/core/services/conversation_parsing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseConversationSummary', () {
    group('extracts id and title', () {
      test('from top-level fields', () {
        final result = parseConversationSummary({
          'id': 'conv-123',
          'title': 'My Chat',
        });

        check(result['id']).equals('conv-123');
        check(result['title']).equals('My Chat');
      });

      test('defaults title to Chat when missing', () {
        final result = parseConversationSummary({'id': 'x'});

        check(result['title']).equals('Chat');
      });

      test('defaults id to empty string when missing', () {
        final result = parseConversationSummary({});

        check(result['id']).equals('');
      });
    });

    group('parses timestamps', () {
      test('integer seconds', () {
        final result = parseConversationSummary({
          'id': '1',
          'created_at': 1700000000,
          'updated_at': 1700000100,
        });

        final created = DateTime.parse(result['createdAt'] as String);
        final updated = DateTime.parse(result['updatedAt'] as String);
        check(created.millisecondsSinceEpoch).equals(1700000000000);
        check(updated.millisecondsSinceEpoch).equals(1700000100000);
      });

      test('string ISO 8601', () {
        final result = parseConversationSummary({
          'id': '1',
          'created_at': '2024-01-15T10:30:00.000Z',
        });

        final created = DateTime.parse(result['createdAt'] as String);
        check(created.year).equals(2024);
        check(created.month).equals(1);
        check(created.day).equals(15);
      });

      test('accepts camelCase timestamp keys', () {
        final result = parseConversationSummary({
          'id': '1',
          'createdAt': 1700000000,
          'updatedAt': 1700000100,
        });

        final created = DateTime.parse(result['createdAt'] as String);
        check(created.millisecondsSinceEpoch).equals(1700000000000);
      });

      test('null timestamp defaults to now-ish', () {
        final before = DateTime.now();
        final result = parseConversationSummary({'id': '1'});
        final after = DateTime.now();

        final created = DateTime.parse(result['createdAt'] as String);
        check(
          created.millisecondsSinceEpoch,
        ).isGreaterOrEqual(before.millisecondsSinceEpoch);
        check(
          created.millisecondsSinceEpoch,
        ).isLessOrEqual(after.millisecondsSinceEpoch);
      });
    });

    group('extracts model', () {
      test('from top-level model field', () {
        final result = parseConversationSummary({'id': '1', 'model': 'gpt-4'});

        check(result['model']).equals('gpt-4');
      });
    });

    group('extracts tags', () {
      test('from list of strings', () {
        final result = parseConversationSummary({
          'id': '1',
          'tags': ['tag1', 'tag2'],
        });

        check((result['tags'] as List<String>)).deepEquals(['tag1', 'tag2']);
      });

      test('empty when not present', () {
        final result = parseConversationSummary({'id': '1'});

        check((result['tags'] as List<String>)).isEmpty();
      });
    });

    group('extracts boolean and optional fields', () {
      test('pinned and archived', () {
        final result = parseConversationSummary({
          'id': '1',
          'pinned': true,
          'archived': true,
        });

        check(result['pinned'] as bool).isTrue();
        check(result['archived'] as bool).isTrue();
      });

      test('defaults pinned and archived to false', () {
        final result = parseConversationSummary({'id': '1'});

        check(result['pinned'] as bool).isFalse();
        check(result['archived'] as bool).isFalse();
      });

      test('shareId and folderId', () {
        final result = parseConversationSummary({
          'id': '1',
          'share_id': 'share-abc',
          'folder_id': 'folder-xyz',
        });

        check(result['shareId']).equals('share-abc');
        check(result['folderId']).equals('folder-xyz');
      });
    });

    group('messages is always empty list', () {
      test('summary never includes messages', () {
        final result = parseConversationSummary({
          'id': '1',
          'chat': {
            'messages': [
              {'role': 'user', 'content': 'hello'},
            ],
          },
        });

        check((result['messages'] as List<Map<String, dynamic>>)).isEmpty();
      });
    });
  });

  group('parseFullConversation', () {
    group('returns messages array', () {
      test('from chat.messages list', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'title': 'Test',
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'role': 'user',
                'content': 'Hello',
                'timestamp': 1700000000,
              },
            ],
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        check(messages).length.equals(1);
        check(messages.first['role']).equals('user');
        check(messages.first['content']).equals('Hello');
      });

      test('from top-level messages list', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'messages': [
            {
              'id': 'msg-1',
              'role': 'assistant',
              'content': 'Hi there',
              'timestamp': 1700000000,
            },
          ],
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        check(messages).length.equals(1);
        check(messages.first['content']).equals('Hi there');
      });
    });

    group('extracts messages from history', () {
      test('follows parent chain from currentId', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'title': 'Test',
          'chat': {
            'history': {
              'currentId': 'msg-2',
              'messages': {
                'msg-1': {
                  'role': 'user',
                  'content': 'Hello',
                  'timestamp': 1700000000,
                  'models': ['llama-3'],
                  'childrenIds': ['msg-2'],
                },
                'msg-2': {
                  'role': 'assistant',
                  'content': 'Hi!',
                  'parentId': 'msg-1',
                  'timestamp': 1700000001,
                },
              },
            },
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        check(messages).length.equals(2);
        check(messages[0]['role']).equals('user');
        check(messages[0]['content']).equals('Hello');
        check(messages[1]['role']).equals('assistant');
        check(messages[1]['content']).equals('Hi!');
        check(messages[0]['metadata']).isA<Map<String, dynamic>>().deepEquals({
          'childrenIds': ['msg-2'],
          'models': ['llama-3'],
        });
        check(
          messages[1]['metadata'],
        ).isA<Map<String, dynamic>>().deepEquals({'parentId': 'msg-1'});
      });
    });

    group('handles content formats', () {
      test('content as string', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'role': 'user',
                'content': 'plain text content',
                'timestamp': 1700000000,
              },
            ],
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        check(messages.first['content']).equals('plain text content');
      });

      test('content as list of text parts', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'role': 'user',
                'content': [
                  {'type': 'text', 'text': 'Hello '},
                  {'type': 'text', 'text': 'world'},
                ],
                'timestamp': 1700000000,
              },
            ],
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        check(messages.first['content']).equals('Hello world');
      });

      test('normalizes assistant embeds from message payloads', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'role': 'assistant',
                'content': '',
                'timestamp': 1700000000,
                'embeds': [
                  '<div>embed</div>',
                  {'html': '<section>card</section>'},
                ],
              },
            ],
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        check(messages.first['embeds'] as List<Object?>).deepEquals([
          {'src': '<div>embed</div>'},
          {'html': '<section>card</section>', 'src': '<section>card</section>'},
        ]);
      });
    });

    group('extracts role, model, timestamp', () {
      test('role from message data', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'role': 'system',
                'content': 'You are helpful',
                'timestamp': 1700000000,
              },
            ],
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        check(messages.first['role']).equals('system');
      });

      test('model from message data', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'role': 'assistant',
                'content': 'response',
                'model': 'gpt-4',
                'timestamp': 1700000000,
              },
            ],
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        check(messages.first['model']).equals('gpt-4');
      });

      test('timestamp is parsed to ISO string', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'role': 'user',
                'content': 'hi',
                'timestamp': 1700000000,
              },
            ],
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        final ts = DateTime.parse(messages.first['timestamp'] as String);
        check(ts.millisecondsSinceEpoch).equals(1700000000000);
      });
    });

    group('extracts model from chat object', () {
      test('from chat.models list', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'chat': {
            'models': ['llama-3'],
            'messages': [
              {
                'id': 'msg-1',
                'role': 'user',
                'content': 'hi',
                'timestamp': 1700000000,
              },
            ],
          },
        });

        check(result['model']).equals('llama-3');
      });
    });

    group('handles error field', () {
      test('error as map with content', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'role': 'assistant',
                'content': '',
                'timestamp': 1700000000,
                'error': {'content': 'Something went wrong'},
              },
            ],
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        final error = messages.first['error'] as Map<String, dynamic>;
        check(error['content']).equals('Something went wrong');
      });

      test('error as bool true', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'role': 'assistant',
                'content': 'error msg',
                'timestamp': 1700000000,
                'error': true,
              },
            ],
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        final error = messages.first['error'] as Map<String, dynamic>;
        check(error['content']).isNull();
      });

      test('no error field means null error', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'role': 'assistant',
                'content': 'fine',
                'timestamp': 1700000000,
              },
            ],
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        check(messages.first['error']).isNull();
      });

      test('error as string', () {
        final result = parseFullConversation({
          'id': 'conv-1',
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'role': 'assistant',
                'content': '',
                'timestamp': 1700000000,
                'error': 'Network error',
              },
            ],
          },
        });

        final messages = result['messages'] as List<Map<String, dynamic>>;
        final error = messages.first['error'] as Map<String, dynamic>;
        check(error['content']).equals('Network error');
      });
    });

    group('empty or missing data', () {
      test('empty chatData returns minimal structure', () {
        final result = parseFullConversation({});

        check(result['id']).equals('');
        check(result['title']).equals('Chat');
        check((result['messages'] as List<Map<String, dynamic>>)).isEmpty();
      });
    });
  });
}
