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

  test('applies OpenWebUI delete semantics by reparenting grandchildren', () {
    final messages = [
      _message('root', childrenIds: const ['child', 'sibling']),
      _message('child', parentId: 'root', childrenIds: const ['leaf']),
      _message('leaf', parentId: 'child'),
      _message('sibling', parentId: 'root'),
    ];

    expect(openWebUiDeletedMessageIds(messages, 'child'), {'child', 'leaf'});

    final updated = deleteOpenWebUiMessageFromChatMessages(messages, 'child');

    expect(updated.map((message) => message.id), ['root', 'sibling']);
    expect(chatMessageChildrenIds(updated.first), ['sibling']);
  });

  test('OpenWebUI delete reparents grandchildren to the deleted parent', () {
    final messages = [
      _message('root', childrenIds: const ['child']),
      _message('child', parentId: 'root', childrenIds: const ['leaf']),
      _message('leaf', parentId: 'child', childrenIds: const ['grandchild']),
      _message('grandchild', parentId: 'leaf'),
    ];

    final updated = deleteOpenWebUiMessageFromChatMessages(messages, 'child');
    final root = updated.singleWhere((message) => message.id == 'root');
    final grandchild = updated.singleWhere(
      (message) => message.id == 'grandchild',
    );

    expect(updated.map((message) => message.id), ['root', 'grandchild']);
    expect(chatMessageChildrenIds(root), ['grandchild']);
    expect(chatMessageParentId(grandchild), 'root');
  });

  test('OpenWebUI raw delete uses the same direct-child reparent plan', () {
    final messages = <String, Map<String, dynamic>>{
      'root': {
        'id': 'root',
        'childrenIds': ['child', 'sibling'],
      },
      'child': {
        'id': 'child',
        'parentId': 'root',
        'childrenIds': ['leaf'],
      },
      'sibling': {'id': 'sibling', 'parentId': 'root'},
      'leaf': {
        'id': 'leaf',
        'parentId': 'child',
        'childrenIds': ['grandchild'],
      },
      'grandchild': {'id': 'grandchild', 'parentId': 'leaf'},
    };

    final result = deleteOpenWebUiMessageFromRawHistory(messages, 'child');

    expect(result?.deletedIds, {'child', 'leaf'});
    expect(result?.currentId, 'grandchild');
    expect(messages.keys, ['root', 'sibling', 'grandchild']);
    expect(messages['root']!['childrenIds'], ['sibling', 'grandchild']);
    expect(messages['grandchild']!['parentId'], 'root');
  });

  test('OpenWebUI current id traversal stops on children cycles', () {
    final messages = <String, Map<String, dynamic>>{
      'root': {
        'id': 'root',
        'childrenIds': ['a'],
      },
      'a': {
        'id': 'a',
        'parentId': 'root',
        'childrenIds': ['b'],
      },
      'b': {
        'id': 'b',
        'parentId': 'a',
        'childrenIds': ['a'],
      },
    };
    const plan = OpenWebUiDeletePlan(
      rootId: 'deleted',
      deletedIds: <String>{},
      deletedParentId: 'root',
      grandchildIds: <String>[],
    );

    final currentId = currentIdAfterOpenWebUiDelete<Map<String, dynamic>>(
      messages,
      plan,
      parentIdOf: rawMessageParentId,
      childrenIdsOf: rawMessageChildrenIds,
    );

    expect(currentId, 'b');
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
