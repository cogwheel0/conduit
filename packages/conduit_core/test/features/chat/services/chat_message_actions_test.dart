import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_message_actions.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

class _NullConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _TestMessagesNotifier extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];

  @override
  void setMessages(List<ChatMessage> messages) {
    state = List<ChatMessage>.from(messages);
  }

  @override
  void cancelActiveMessageStream() {}
}

ChatMessage _message(
  String id,
  String role, {
  String? parentId,
  List<String> childrenIds = const [],
  List<String>? attachmentIds,
  List<Map<String, dynamic>>? files,
}) => ChatMessage(
  id: id,
  role: role,
  content: '$role $id',
  timestamp: DateTime.utc(2026, 9, 25),
  attachmentIds: attachmentIds,
  files: files,
  metadata: <String, dynamic>{
    'parentId': ?parentId,
    'childrenIds': childrenIds,
  },
);

/// u1 -> a1 -> u2 -> a2, a linear Open WebUI tree.
List<ChatMessage> _linearChat() => [
  _message('u1', 'user', childrenIds: ['a1']),
  _message('a1', 'assistant', parentId: 'u1', childrenIds: ['u2']),
  _message('u2', 'user', parentId: 'a1', childrenIds: ['a2']),
  _message('a2', 'assistant', parentId: 'u2'),
];

void main() {
  group('chatMessageIdsRemovedByDelete', () {
    test('counts the message and its direct children, as Open WebUI does', () {
      check(chatMessageIdsRemovedByDelete(_linearChat(), ['u2']))
          .deepEquals({'u2', 'a2'});
    });

    test('unions a grouped response and ignores unknown ids', () {
      check(chatMessageIdsRemovedByDelete(_linearChat(), ['a2', 'missing']))
          .deepEquals({'a2'});
    });
  });

  group('editedMessageAttachmentIds', () {
    test('prefers trimmed attachment ids', () {
      check(
        editedMessageAttachmentIds(
          _message('u', 'user', attachmentIds: [' f1 ', '', 'f2']),
        ),
      ).isNotNull().deepEquals(['f1', 'f2']);
    });

    test('reads file ids, skipping notes and Hermes local references', () {
      final ids = editedMessageAttachmentIds(
        _message(
          'u',
          'user',
          files: [
            {'type': 'note', 'id': 'note-1'},
            {'source': 'hermes_local', 'id': 'local-1'},
            {'type': 'file', 'id': 'file-1'},
            {'type': 'image', 'url': '/api/v1/files/file-2/content'},
            {'type': 'file', 'id': 'file-1'},
          ],
        ),
      );
      check(ids).isNotNull().deepEquals(['file-1', 'file-2']);
    });

    test('is null for a text-only message', () {
      check(editedMessageAttachmentIds(_message('u', 'user'))).isNull();
    });
  });

  group('deleteChatMessageGroup', () {
    ProviderContainer container() {
      final container = ProviderContainer(
        overrides: [
          chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
          activeConversationProvider.overrideWith(
            _NullConversationNotifier.new,
          ),
          apiServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      container.read(chatMessagesProvider.notifier).setMessages(_linearChat());
      return container;
    }

    test('removes the group from the transcript', () async {
      final ref = container();
      final outcome = await deleteChatMessageGroup(ref, ['u2']);
      check(outcome).equals(ChatMessageDeleteOutcome.deleted);
      check(ref.read(chatMessagesProvider).map((m) => m.id).toList())
          .deepEquals(['u1', 'a1']);
    });

    test('changes nothing when no id matches', () async {
      final ref = container();
      final outcome = await deleteChatMessageGroup(ref, ['missing']);
      check(outcome).equals(ChatMessageDeleteOutcome.nothingToDelete);
      check(ref.read(chatMessagesProvider)).length.equals(4);
    });
  });
}
