import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/utils/message_tree_utils.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _message(
  String id, {
  String role = 'user',
  String? parentId,
  List<String> childrenIds = const <String>[],
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: id,
    timestamp: DateTime(2024),
    metadata: {
      'parentId': ?parentId,
      if (childrenIds.isNotEmpty) 'childrenIds': childrenIds,
    },
  );
}

void main() {
  test('collects descendants from chat messages', () {
    final messages = [
      _message('root', childrenIds: const ['child']),
      _message('child', parentId: 'root', childrenIds: const ['leaf']),
      _message('leaf', parentId: 'child'),
      _message('sibling', parentId: 'root'),
    ];

    expect(chatMessageDescendantIds(messages, 'child'), {'child', 'leaf'});
  });

  test('guards chain traversal against cycles', () {
    final messages = {
      'a': {'id': 'a', 'parentId': 'b'},
      'b': {'id': 'b', 'parentId': 'a'},
    };

    final chain = chainToRoot<Map<String, dynamic>>(
      'a',
      messagesById: messages,
      parentIdOf: rawMessageParentId,
    );

    expect(chain.map((message) => message['id']), ['b', 'a']);
  });

  test('finds same-role siblings from raw history children', () {
    final messages = {
      'user': {
        'id': 'user',
        'role': 'user',
        'childrenIds': ['a1', 'a2', 'tool'],
      },
      'a1': {'id': 'a1', 'role': 'assistant', 'parentId': 'user'},
      'a2': {'id': 'a2', 'role': 'assistant', 'parentId': 'user'},
      'tool': {'id': 'tool', 'role': 'tool', 'parentId': 'user'},
    };

    final siblings = sameRoleSiblings<Map<String, dynamic>>(
      messageId: 'a1',
      message: messages['a1']!,
      messagesById: messages,
      parentIdOf: rawMessageParentId,
      childrenIdsOf: rawMessageChildrenIds,
      roleOf: rawMessageRole,
    );

    expect(siblings.map((message) => message['id']), ['a2']);
  });

  test('resolves assistant parent user with metadata fallback', () {
    final messages = [
      _message('u1'),
      _message('a1', role: 'assistant', parentId: 'u1'),
      _message('u2'),
      _message('a2', role: 'assistant'),
    ];

    expect(
      assistantParentUserMessageId(messages: messages, assistantIndex: 1),
      'u1',
    );
    expect(
      assistantParentUserMessageId(messages: messages, assistantIndex: 3),
      'u2',
    );
  });

  test('uses latest remaining id even when timestamps are missing', () {
    final messages = {
      'old': {'timestamp': 1},
      'missing': <String, dynamic>{},
      'new': {'timestamp': 2},
      'laterMissing': <String, dynamic>{},
    };

    expect(
      latestRemainingMessageId<Map<String, dynamic>>(
        messages,
        timestampOf: (message) {
          final timestamp = message['timestamp'];
          return timestamp is num ? timestamp : null;
        },
      ),
      'new',
    );
  });

  test('falls back to the last message when all timestamps are missing', () {
    final messages = {
      'first': <String, dynamic>{},
      'last': <String, dynamic>{},
    };

    expect(
      latestRemainingMessageId<Map<String, dynamic>>(
        messages,
        timestampOf: (message) {
          final timestamp = message['timestamp'];
          return timestamp is num ? timestamp : null;
        },
      ),
      'last',
    );
  });
}
