import 'package:conduit_core/features/chat/utils/conversation_unread.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:test/test.dart';

void main() {
  final updated = DateTime.utc(2026, 3, 4, 12);
  Conversation chat({DateTime? lastReadAt, String id = 'chat-1'}) =>
      Conversation(
        id: id,
        title: 'Seed packets',
        createdAt: DateTime.utc(2026, 3, 1),
        updatedAt: updated,
        lastReadAt: lastReadAt,
      );

  test('a chat never read is unread', () {
    expect(isConversationUnread(chat()), isTrue);
  });

  test('unread when something arrived after it was read', () {
    expect(
      isConversationUnread(
        chat(lastReadAt: updated.subtract(const Duration(minutes: 1))),
      ),
      isTrue,
    );
    expect(isConversationUnread(chat(lastReadAt: updated)), isFalse);
  });

  test('never while open, answering, or without an id', () {
    expect(isConversationUnread(chat(), selected: true), isFalse);
    expect(isConversationUnread(chat(), generating: true), isFalse);
    expect(isConversationUnread(chat(id: '')), isFalse);
  });
}
