@TestOn('vm')
library;

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
}
