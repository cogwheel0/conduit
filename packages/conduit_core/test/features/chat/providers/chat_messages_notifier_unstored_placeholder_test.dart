import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A new Open WebUI chat is pulled into the database before its answer's
/// transport attaches. That first emission has the question and not the
/// answer placeholder, and adopting it used to drop the placeholder, so the
/// stream that attached a moment later had no answer to write into.
void main() {
  late AppDatabase db;
  late bool previousWarn;

  setUpAll(() {
    previousWarn = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(
    () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarn,
  );
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  final now = DateTime.utc(2026, 11, 8);
  ChatMessage question(String id) =>
      ChatMessage(id: id, role: 'user', content: 'hello', timestamp: now);
  ChatMessage placeholder(String id, {String content = ''}) => ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    timestamp: now,
    isStreaming: true,
  );

  Future<void> storeQuestionOnly(String chatId) => db.chatsDao.upsertServerChat(
    rows: ChatBlobMapper.blobToRows(
      chatId: chatId,
      blob: {
        'title': 'New Chat',
        'history': {
          'currentId': 'q1',
          'messages': {
            'q1': {
              'id': 'q1',
              'parentId': null,
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'hello',
              'timestamp': 1,
            },
          },
        },
      },
      title: 'New Chat',
      createdAt: 1,
      updatedAt: 1,
    ),
  );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test(
    'the first emission of a new chat keeps the answer placeholder',
    () async {
      final c = container();
      final chat = withChatStorageProvenance(
        Conversation(
          id: 'server-chat',
          title: 'New Chat',
          createdAt: now,
          updatedAt: now,
          messages: [question('q1'), placeholder('a1')],
        ),
        ChatStorageKind.openWebUi,
      );
      c.read(activeConversationProvider.notifier).set(chat);
      expect(c.read(chatMessagesProvider).map((m) => m.id), ['q1', 'a1']);

      await storeQuestionOnly('server-chat');
      await settle();

      expect(c.read(chatMessagesProvider).map((m) => m.id), ['q1', 'a1']);
      expect(c.read(chatMessagesProvider).last.isStreaming, isTrue);
    },
  );

  test('only an empty, streaming placeholder the rows lack is held', () {
    final c = container();
    final notifier = c.read(chatMessagesProvider.notifier);
    final stored = [question('q1')];

    notifier.setMessages([question('q1'), placeholder('a1')]);
    expect(notifier.debugAwaitsUnstoredPlaceholder(stored), isTrue);
    // Stored already: the database has it, so its copy is adopted.
    expect(
      notifier.debugAwaitsUnstoredPlaceholder([...stored, placeholder('a1')]),
      isFalse,
    );

    // Text has arrived: the stream owns it from here.
    notifier.setMessages([question('q1'), placeholder('a1', content: 'Hi')]);
    expect(notifier.debugAwaitsUnstoredPlaceholder(stored), isFalse);

    // A regeneration preparing: the answer it replaces is archived only
    // here, and so is the placeholder that follows it.
    final archived = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'Hello',
      timestamp: now,
      metadata: const {'archivedVariant': true},
    );
    final storedAnswer = archived.copyWith(metadata: const {});
    notifier.setMessages([question('q1'), archived]);
    expect(
      notifier.debugAwaitsUnstoredPlaceholder([...stored, storedAnswer]),
      isTrue,
    );
    notifier.setMessages([question('q1'), archived, placeholder('a2')]);
    expect(
      notifier.debugAwaitsUnstoredPlaceholder([...stored, storedAnswer]),
      isTrue,
    );
    expect(
      notifier.debugAwaitsUnstoredPlaceholder([
        ...stored,
        storedAnswer,
        placeholder('a2'),
      ]),
      isFalse,
    );

    // Finished, or not an answer at all.
    notifier.setMessages([
      question('q1'),
      placeholder('a1').copyWith(isStreaming: false),
    ]);
    expect(notifier.debugAwaitsUnstoredPlaceholder(stored), isFalse);
    notifier.setMessages([question('q1')]);
    expect(notifier.debugAwaitsUnstoredPlaceholder(stored), isFalse);
  });
}
