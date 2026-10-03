import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/temporary_chat_save.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/ports/database_opener.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

ChatMessage _message(String role, String content) => ChatMessage(
  id: '$role-${content.length}',
  role: role,
  content: content,
  timestamp: DateTime(2026),
);

void main() {
  group('temporaryChatTitle', () {
    test('uses the first user message', () {
      check(
        temporaryChatTitle([
          _message('assistant', 'Hello there'),
          _message('user', 'Plan my week'),
        ]),
      ).equals('Plan my week');
    });

    test('cuts long messages at 50 characters', () {
      final long = 'x' * 60;
      check(temporaryChatTitle([_message('user', long)]))
          .equals('${'x' * 50}...');
    });

    test('falls back to the first message, then New Chat', () {
      check(temporaryChatTitle([_message('assistant', 'Only reply')]))
          .equals('Only reply');
      check(temporaryChatTitle([_message('user', '')])).equals('New Chat');
      check(temporaryChatTitle(const [])).equals('New Chat');
    });
  });

  group('saveTemporaryChat', () {
    final transcript = [
      _message('user', 'Plan my week'),
      _message('assistant', 'Sure'),
    ];

    Conversation temporary(
      String id, {
      String? folderId,
      List<ChatMessage>? messages,
    }) => Conversation(
      id: id,
      title: 'Temporary',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      messages: messages ?? transcript,
      folderId: folderId,
    );

    late _CreatingApi api;

    ProviderContainer container({
      String id = 'local:temp-1',
      String? folderId,
      bool empty = false,
      _CreatingApi? withApi,
    }) {
      api = withApi ?? _CreatingApi();
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          databaseOpenerProvider.overrideWithValue(_MemoryDatabaseOpener()),
          apiServiceProvider.overrideWithValue(api),
          chatMessagesProvider.overrideWith(_SeededMessages.new),
          activeConversationProvider.overrideWith(
            () => _SeededActive(
              temporary(
                id,
                folderId: folderId,
                messages: empty ? const <ChatMessage>[] : null,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(chatMessagesProvider.notifier)
          .setMessages(empty ? const <ChatMessage>[] : transcript);
      // Auto-dispose: without a listener the toggle would reset between reads.
      container.listen(temporaryChatEnabledProvider, (_, _) {});
      container.read(temporaryChatEnabledProvider.notifier).set(true);
      return container;
    }

    test('a successful save makes the chat a server conversation', () async {
      final ref = container(folderId: 'folder-1');

      final outcome = await saveTemporaryChat(ref);

      check(outcome).equals(TemporaryChatSaveOutcome.saved);
      check(api.created.single.title).equals('Plan my week');
      check(api.created.single.folderId).equals('folder-1');
      check(api.created.single.messages).length.equals(2);
      final active = ref.read(activeConversationProvider)!;
      check(active.id).equals('server-chat');
      check(active.messages).length.equals(2);
      check(ref.read(temporaryChatEnabledProvider)).isFalse();
    });

    test('an empty transcript is skipped without a server call', () async {
      final ref = container(empty: true);

      final outcome = await saveTemporaryChat(ref);

      check(outcome).equals(TemporaryChatSaveOutcome.skipped);
      check(api.created).isEmpty();
      check(ref.read(temporaryChatEnabledProvider)).isTrue();
    });

    test('a chat switched during the request is not overwritten', () async {
      final gate = Completer<void>();
      final ref = container(withApi: _CreatingApi(gate: gate.future));

      final saving = saveTemporaryChat(ref);
      await Future<void>.delayed(Duration.zero);
      ref
          .read(activeConversationProvider.notifier)
          .set(temporary('local:temp-2'));
      gate.complete();
      final outcome = await saving;

      check(outcome).equals(TemporaryChatSaveOutcome.skipped);
      check(ref.read(activeConversationProvider)!.id).equals('local:temp-2');
      check(ref.read(temporaryChatEnabledProvider)).isTrue();
    });

    test('the page can drop the save while it is in flight', () async {
      final gate = Completer<void>();
      final ref = container(withApi: _CreatingApi(gate: gate.future));
      var pageStillOwnsChat = true;

      final saving = saveTemporaryChat(
        ref,
        isCurrentOwner: () => pageStillOwnsChat,
      );
      await Future<void>.delayed(Duration.zero);
      pageStillOwnsChat = false;
      gate.complete();

      check(await saving).equals(TemporaryChatSaveOutcome.skipped);
      check(ref.read(activeConversationProvider)!.id).equals('local:temp-1');
    });

    test(
      'a refused save reports failure and leaves the chat temporary',
      () async {
        final ref = container(withApi: _CreatingApi(fails: true));

        final outcome = await saveTemporaryChat(ref);

        check(outcome).equals(TemporaryChatSaveOutcome.failed);
        check(ref.read(activeConversationProvider)!.id).equals('local:temp-1');
        check(ref.read(temporaryChatEnabledProvider)).isTrue();
      },
    );
  });
}

class _SeededMessages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];

  @override
  void setMessages(List<ChatMessage> messages) {
    state = List<ChatMessage>.from(messages);
  }
}

class _SeededActive extends ActiveConversationNotifier {
  _SeededActive(this._conversation);

  final Conversation _conversation;

  @override
  Conversation? build() => _conversation;
}

class _CreatingApi extends ApiService {
  _CreatingApi({this.gate, this.fails = false})
    : super(
        serverConfig: const ServerConfig(
          id: 'save-test',
          name: 'Save test',
          url: 'http://localhost:0',
        ),
        workerManager: WorkerManager(),
      );

  final Future<void>? gate;
  final bool fails;
  final created =
      <({String title, List<ChatMessage> messages, String? folderId})>[];

  @override
  Future<Conversation> createConversation({
    required String title,
    required List<ChatMessage> messages,
    String? model,
    String? systemPrompt,
    String? folderId,
  }) async {
    created.add((title: title, messages: messages, folderId: folderId));
    await gate;
    if (fails) throw StateError('server refused');
    return Conversation(
      id: 'server-chat',
      title: title,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      folderId: folderId,
    );
  }
}

class _MemoryDatabaseOpener implements DatabaseOpenerPort {
  @override
  QueryExecutor open(String serverId) => NativeDatabase.memory();

  @override
  Future<Directory> databaseDirectory() async => Directory.systemTemp;
}
