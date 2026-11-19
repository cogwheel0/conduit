@TestOn('vm')
library;

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

/// A chat as the windows list and open it: another user's chat, reached
/// through a folder shared with this account, is read-only, as the core
/// decides it for a phone (issue #710).
void main() {
  Conversation chat({String? owner}) => Conversation(
    id: 'chat-1',
    title: 'Trip plans',
    createdAt: DateTime.utc(2026, 11, 1),
    updatedAt: DateTime.utc(2026, 11, 2),
    userId: owner,
  );

  test('another user\'s chat is read-only', () {
    expect(
      chatSummaryOf(chat(owner: 'user-b'), currentUserId: 'user-a').readOnly,
      isTrue,
    );
  });

  test('the account\'s own chat is not', () {
    expect(
      chatSummaryOf(chat(owner: 'user-a'), currentUserId: 'user-a').readOnly,
      isFalse,
    );
  });

  test('a chat with no owner on record is not (direct, Hermes, older '
      'rows)', () {
    expect(chatSummaryOf(chat(), currentUserId: 'user-a').readOnly, isFalse);
  });

  test('an owner with the signed-in user not yet known reads as read-only, '
      'failing closed', () {
    expect(
      chatSummaryOf(chat(owner: 'user-b'), currentUserId: null).readOnly,
      isTrue,
    );
  });

  group('a folder shared with the account', () {
    test('says whose it is and whether chats may be put in it', () {
      final shared = folderSummaryOf(
        const Folder(
          id: 'folder-1',
          name: 'Trip planning',
          shared: true,
          ownerName: 'Riley Example',
          permission: 'read',
        ),
      );
      expect(shared.shared, isTrue);
      expect(shared.ownerName, 'Riley Example');
      expect(shared.canWrite, isFalse);

      final writable = folderSummaryOf(
        const Folder(
          id: 'folder-2',
          name: 'Team notes',
          shared: true,
          permission: 'write',
        ),
      );
      expect(writable.canWrite, isTrue);

      final own = folderSummaryOf(
        const Folder(id: 'folder-3', name: 'Mine', isExpanded: true),
      );
      expect((own.shared, own.canWrite, own.expanded), (false, true, true));
    });

    test('lists its chats in it, another user\'s read-only', () {
      final chats = folderChatSummaries(
        <Conversation>[
          // The server's shared-chats route does not always name the folder.
          chat(owner: 'user-b'),
          Conversation(
            id: 'chat-2',
            title: 'Mine, in their folder',
            createdAt: DateTime.utc(2026, 11, 1),
            updatedAt: DateTime.utc(2026, 11, 3),
            folderId: 'folder-1',
            userId: 'user-a',
          ),
        ],
        folderId: 'folder-1',
        currentUserId: 'user-a',
      );
      expect(chats.map((c) => (c.id, c.folderId, c.readOnly)), [
        ('chat-1', 'folder-1', true),
        ('chat-2', 'folder-1', false),
      ]);
    });
  });

  group('unread', () {
    test('a chat never read shows as unread, but not while it answers', () {
      expect(chatSummaryOf(chat(), currentUserId: 'user-a').unread, isTrue);
      expect(
        chatSummaryOf(chat(), currentUserId: 'user-a', generating: true).unread,
        isFalse,
      );
    });

    test('a chat read since it last changed does not', () {
      final read = chat().copyWith(lastReadAt: DateTime.utc(2026, 11, 3));
      expect(chatSummaryOf(read, currentUserId: 'user-a').unread, isFalse);
    });
  });

  group('answerModelNameOf', () {
    ChatMessage answer(Map<String, dynamic>? metadata) => ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'Basil and thyme.',
      timestamp: DateTime.utc(2026, 11, 2),
      model: 'hermes:agent:desktop:7f3a9c',
      metadata: metadata,
    );

    test('the name the answer kept, for a window to fall back to', () {
      expect(
        answerModelNameOf(
          answer(<String, dynamic>{'modelName': ' Demo Model Large '}),
        ),
        'Demo Model Large',
      );
      expect(
        answerModelNameOf(
          answer(<String, dynamic>{'model_name': 'Demo Model Large'}),
        ),
        'Demo Model Large',
      );
    });

    test('none when it kept none', () {
      expect(answerModelNameOf(answer(null)), isNull);
      expect(
        answerModelNameOf(answer(<String, dynamic>{'modelName': '  '})),
        isNull,
      );
    });
  });

  group('siblingIdsOf', () {
    ChatMessage message(
      String id, {
      List<String> versions = const <String>[],
      Map<String, dynamic>? metadata,
    }) => ChatMessage(
      id: id,
      role: 'assistant',
      content: id,
      timestamp: DateTime.utc(2026, 11, 2),
      metadata: metadata,
      versions: <ChatMessageVersion>[
        for (final version in versions)
          ChatMessageVersion(
            id: version,
            content: version,
            timestamp: DateTime.utc(2026, 11, 2),
          ),
      ],
    );

    test('none without versions', () {
      expect(siblingIdsOf(message('a2'), null), isEmpty);
    });

    test("in the parent's order, wherever the shown one stands", () {
      final parent = ChatMessage(
        id: 'q1',
        role: 'user',
        content: 'Which liner?',
        timestamp: DateTime.utc(2026, 11, 2),
        metadata: <String, dynamic>{
          'childrenIds': <String>['a1', 'a2', 'a3'],
        },
      );
      expect(
        siblingIdsOf(message('a2', versions: <String>['a1', 'a3']), parent),
        <String>['a1', 'a2', 'a3'],
      );
    });

    test('versions then the shown one when the parent does not say', () {
      expect(
        siblingIdsOf(message('a2', versions: <String>['a1']), null),
        <String>['a1', 'a2'],
      );
    });
  });
}
