import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_message_actions.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

class _NullConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _SeededConversationNotifier extends ActiveConversationNotifier {
  _SeededConversationNotifier(this._conversation);

  final Conversation _conversation;

  @override
  Conversation? build() => _conversation;
}

class _RecordingApi extends ApiService {
  _RecordingApi({this.failAfter})
    : super(
        serverConfig: const ServerConfig(
          id: 'actions-test',
          name: 'Actions test',
          url: 'http://localhost:0',
        ),
        workerManager: WorkerManager(),
      );

  /// How many deletes succeed before the next one throws; null never throws.
  final int? failAfter;
  final deleted = <String>[];

  @override
  Future<void> deleteConversationMessage(
    String conversationId,
    String messageId,
  ) async {
    if (failAfter != null && deleted.length >= failAfter!) {
      throw StateError('server rejected the delete');
    }
    deleted.add(messageId);
  }
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

  group('deleteChatMessageGroup on a server-backed chat', () {
    Conversation conversation() => Conversation(
      id: 'chat-1',
      title: 'Chat',
      createdAt: DateTime.utc(2026, 9, 25),
      updatedAt: DateTime.utc(2026, 9, 25),
      messages: _linearChat(),
    );

    ProviderContainer container(_RecordingApi api) {
      final container = ProviderContainer(
        overrides: [
          chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
          activeConversationProvider.overrideWith(
            () => _SeededConversationNotifier(conversation()),
          ),
          apiServiceProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      container.read(chatMessagesProvider.notifier).setMessages(_linearChat());
      return container;
    }

    test('deletes each id on the server, bottom-up', () async {
      final api = _RecordingApi();
      final ref = container(api);

      final outcome = await deleteChatMessageGroup(ref, ['a1', 'u2']);

      check(outcome).equals(ChatMessageDeleteOutcome.deleted);
      check(api.deleted).deepEquals(['u2', 'a1']);
    });

    test('a rejected delete restores the whole transcript', () async {
      final api = _RecordingApi(failAfter: 0);
      final ref = container(api);

      final outcome = await deleteChatMessageGroup(ref, ['a2']);

      check(outcome).equals(ChatMessageDeleteOutcome.persistFailed);
      check(ref.read(chatMessagesProvider).map((m) => m.id).toList())
          .deepEquals(['u1', 'a1', 'u2', 'a2']);
      check(ref.read(activeConversationProvider)!.messages).length.equals(4);
    });

    test(
      'a partial failure keeps what the server already deleted gone',
      () async {
        // Bottom-up, so u2 is deleted on the server before a1 is rejected.
        final api = _RecordingApi(failAfter: 1);
        final ref = container(api);

        final outcome = await deleteChatMessageGroup(ref, ['a1', 'u2']);

        check(outcome).equals(ChatMessageDeleteOutcome.persistFailed);
        check(api.deleted).deepEquals(['u2']);
        final ids = ref.read(chatMessagesProvider).map((m) => m.id).toList();
        check(ids).not((it) => it.contains('u2'));
        check(ids).contains('a1');
        check(ref.read(activeConversationProvider)!.messages.map((m) => m.id))
            .not((it) => it.contains('u2'));
      },
    );
  });

  group('resendEditedUserMessage', () {
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

    test('does nothing for blank, unchanged or unknown messages', () async {
      final ref = container();

      check(await resendEditedUserMessage(ref, messageId: 'u2', newText: ' '))
          .isFalse();
      check(
        await resendEditedUserMessage(ref, messageId: 'u2', newText: 'user u2'),
      ).isFalse();
      check(await resendEditedUserMessage(ref, messageId: 'nope', newText: 'x'))
          .isFalse();
      check(ref.read(chatMessagesProvider)).length.equals(4);
    });

    test('drops the edited message and what follows before sending, and a '
        'failed send rethrows', () async {
      final ref = container();

      await check(
        resendEditedUserMessage(ref, messageId: 'u2', newText: 'new text'),
      ).throws<Object>();

      check(ref.read(chatMessagesProvider).map((m) => m.id).toList())
          .deepEquals(['u1', 'a1']);
    });
  });
}
