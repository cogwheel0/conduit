import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/sync/outbox_drainer.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/services/request_completion_runner.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Targeted guards for [ChatRequestCompletionRunner] (Wiring D / R3 / R5).
///
/// These cover the no-stream control paths the runner takes BEFORE re-entering
/// the streaming pipeline (which needs a full api/socket stack out of scope
/// here): the live-stream busy-skip (R5), the already-completed idempotent
/// re-entry (R3), and the chat-absent early-return. The "drives the stream"
/// acceptance is covered by `test/core/sync/write_path_acceptance_test.dart`.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  /// Builds the real [ChatRequestCompletionRunner] with a genuine [Ref] via a
  /// throwaway provider, under the given overrides.
  ({ProviderContainer container, RequestCompletionRunner runner}) makeRunner({
    required bool isStreaming,
    Conversation? active,
    bool attachDatabase = true,
    int recoveryAttempts = 6,
    Duration recoveryDelay = const Duration(seconds: 2),
    Object Function()? authSessionEpoch,
  }) {
    final runnerProvider = Provider<RequestCompletionRunner>((ref) {
      return ChatRequestCompletionRunner(
        ref,
        recoveryAttempts: recoveryAttempts,
        recoveryDelay: recoveryDelay,
      );
    });
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => attachDatabase ? db : null),
        isChatStreamingProvider.overrideWithValue(isStreaming),
        chatMessagesProvider.overrideWith(() => _TestMessagesNotifier()),
        activeConversationProvider.overrideWith(() => _SeededActive(active)),
        // No api/socket stack here: the headless/live drive both short-circuit
        // on the null-api guard, letting these tests assert the PATH choice
        // (headless vs live vs defer) without a real transport.
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        if (authSessionEpoch != null)
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => authSessionEpoch(),
          ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, runner: container.read(runnerProvider));
  }

  Future<void> seedChat(String chatId) async {
    await db
        .into(db.chats)
        .insert(
          ChatsCompanion.insert(
            id: chatId,
            title: 'T',
            createdAt: 1,
            updatedAt: 1,
            bodySynced: const Value(true),
          ),
        );
  }

  Future<void> seedMessage(
    String chatId,
    String id,
    String content, {
    Map<String, dynamic>? payload,
  }) async {
    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            id: id,
            chatId: chatId,
            role: 'assistant',
            content: content,
            createdAt: 1,
            orderIndex: 0,
            payload: jsonEncode(payload ?? const <String, dynamic>{}),
          ),
        );
  }

  Conversation conv(String id) => Conversation(
    id: id,
    title: 'C',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    messages: const [],
  );

  Map<String, dynamic> payload(String assistantId) => RequestCompletionPayload(
    assistantMessageId: assistantId,
    model: 'model-1',
  ).toJson();

  test('defers (throws CompletionBusyException) when a live stream owns the '
      'chat', () async {
    const chatId = 'chat-busy';
    await seedChat(chatId);
    await seedMessage(chatId, 'asst-1', '');

    final (:container, :runner) = makeRunner(
      isStreaming: true,
      active: conv(chatId),
    );
    container; // silence unused.

    await check(
      runner.run(chatId: chatId, payload: payload('asst-1')),
    ).throws<CompletionBusyException>();
  });

  test(
    'recovers a submitted marker while another live stream owns the chat',
    () async {
      const chatId = 'chat-submitted-recovery';
      await seedChat(chatId);
      await seedMessage(
        chatId,
        'asst-submitted',
        'partial submitted response',
        payload: const <String, dynamic>{
          'id': 'asst-submitted',
          'role': 'assistant',
          'content': 'partial submitted response',
          'metadata': <String, dynamic>{'completionSubmitted': true},
        },
      );

      final (:container, :runner) = makeRunner(
        isStreaming: true,
        active: conv(chatId),
        recoveryAttempts: 1,
        recoveryDelay: Duration.zero,
      );
      container.read(chatMessagesProvider.notifier).setMessages([
        ChatMessage(
          id: 'other-live-assistant',
          role: 'assistant',
          content: 'another turn is streaming',
          timestamp: DateTime.utc(2026, 7, 14),
          isStreaming: true,
        ),
      ]);

      // The durable submitted marker makes this pull-only recovery. It must
      // not wait for the unrelated live stream or issue another completion.
      await runner.run(chatId: chatId, payload: payload('asst-submitted'));

      final row = await db.messagesDao.getMessage(chatId, 'asst-submitted');
      check(row?.content).equals('partial submitted response');
    },
  );

  test('does not defer its own optimistic streaming placeholder', () async {
    const chatId = 'chat-own-placeholder';
    await seedChat(chatId);
    await seedMessage(chatId, 'asst-own', '');

    final (:container, :runner) = makeRunner(
      isStreaming: true,
      active: conv(chatId),
    );
    container.read(chatMessagesProvider.notifier).setMessages([
      ChatMessage(
        id: 'user-own',
        role: 'user',
        content: 'hello',
        timestamp: DateTime.now(),
      ),
      ChatMessage(
        id: 'asst-own',
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: true,
      ),
    ]);

    await check(
      runner.run(chatId: chatId, payload: payload('asst-own')),
    ).throws<StateError>();
  });

  test('defers when no active database is attached', () async {
    final (:container, :runner) = makeRunner(
      isStreaming: false,
      active: null,
      attachDatabase: false,
    );
    container;

    await check(
      runner.run(chatId: 'chat-no-db', payload: payload('asst-no-db')),
    ).throws<CompletionDatabaseUnavailableException>();
  });

  test('returns early (idempotent) when the turn already completed', () async {
    const chatId = 'chat-done';
    await seedChat(chatId);
    await seedMessage(
      chatId,
      'asst-2',
      'already answered',
      payload: const <String, dynamic>{
        'id': 'asst-2',
        'role': 'assistant',
        'content': 'already answered',
        'timestamp': 1,
        'isStreaming': false,
      },
    );

    final (:container, :runner) = makeRunner(
      isStreaming: false,
      active: conv(chatId),
    );
    container;

    // Completes without throwing and without touching the api (none provided).
    await runner.run(chatId: chatId, payload: payload('asst-2'));

    // The completed row is left untouched (still exactly one assistant row).
    final rows = await db.messagesDao.getForChat(chatId);
    check(rows.where((r) => r.id == 'asst-2')).length.equals(1);
    check(rows.single.content).equals('already answered');
  });

  test(
    'returns early for a headless submitted marker with empty content',
    () async {
      const chatId = 'chat-headless-marker';
      await seedChat(chatId);
      await seedMessage(
        chatId,
        'asst-headless',
        '',
        payload: const <String, dynamic>{
          'id': 'asst-headless',
          'role': 'assistant',
          'content': '',
          'metadata': {'responseDone': true},
        },
      );

      final (:container, :runner) = makeRunner(
        isStreaming: false,
        active: conv('a-different-chat'),
      );

      await runner.run(chatId: chatId, payload: payload('asst-headless'));

      check(
        container.read(activeConversationProvider)?.id,
      ).equals('a-different-chat');
    },
  );

  test('does not treat pause-checkpoint content as completed', () async {
    const chatId = 'chat-partial';
    await seedChat(chatId);
    await seedMessage(
      chatId,
      'asst-partial',
      'partial answer',
      payload: const <String, dynamic>{
        'id': 'asst-partial',
        'role': 'assistant',
        'content': 'partial answer',
        'timestamp': 1,
        'isStreaming': true,
      },
    );

    final (:container, :runner) = makeRunner(
      isStreaming: false,
      active: conv(chatId),
    );
    container;

    await check(
      runner.run(chatId: chatId, payload: payload('asst-partial')),
    ).throws<StateError>();
  });

  test('returns early when the chat row vanished (delete won the race)', () async {
    const chatId = 'chat-absent';
    // No active conversation, so the runner takes the activate branch, finds no
    // row, and returns. (A DIFFERENT active chat would now defer first — see the
    // Option B test below.)
    final (:container, :runner) = makeRunner(isStreaming: false, active: null);
    container;

    // No chat seeded: must return without throwing.
    await runner.run(chatId: chatId, payload: payload('asst-3'));

    final rows = await db.messagesDao.getForChat(chatId);
    check(rows).isEmpty();
  });

  test('returns early when the assistant placeholder row vanished', () async {
    const chatId = 'chat-missing-placeholder';
    await seedChat(chatId);
    final (:container, :runner) = makeRunner(
      isStreaming: false,
      active: conv('a-different-chat'),
    );
    container;

    await runner.run(chatId: chatId, payload: payload('missing-asst'));

    final rows = await db.messagesDao.getForChat(chatId);
    check(rows).isEmpty();
  });

  test(
    'same-database auth-session switch defers after an awaited read',
    () async {
      const chatId = 'chat-session-switch';
      const assistantId = 'asst-session-switch';
      await seedChat(chatId);
      await seedMessage(chatId, assistantId, '');
      var authSessionEpoch = Object();
      final (:container, :runner) = makeRunner(
        isStreaming: false,
        active: conv(chatId),
        authSessionEpoch: () => authSessionEpoch,
      );

      final transactionEntered = Completer<void>();
      final releaseTransaction = Completer<void>();
      final transaction = db.transaction(() async {
        transactionEntered.complete();
        await releaseTransaction.future;
      });
      await transactionEntered.future;

      final completion = runner.run(
        chatId: chatId,
        payload: payload(assistantId),
      );
      await Future<void>.delayed(Duration.zero);
      authSessionEpoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      releaseTransaction.complete();
      await transaction;

      await check(completion).throws<CompletionDatabaseUnavailableException>();
    },
  );

  test('Option B: runs HEADLESS (never switches the active chat) when a '
      'DIFFERENT chat is foregrounded', () async {
    const chatId = 'chat-bg';
    await seedChat(chatId);
    await seedMessage(chatId, 'asst-4', '');

    // The user is viewing a different chat: the completion must NOT switch the
    // active conversation to chat-bg — it runs headless. With no api stack the
    // headless drive fails downstream, but it is NOT a deferral and NOT a
    // switch (proving the headless, non-disruptive path).
    final (:container, :runner) = makeRunner(
      isStreaming: false,
      active: conv('a-different-chat'),
    );

    await check(
      runner.run(chatId: chatId, payload: payload('asst-4')),
    ).throws<StateError>(); // "runHeadlessCompletion requires an API service"

    // The user's active conversation is untouched (Option B: no yank).
    check(
      container.read(activeConversationProvider)?.id,
    ).equals('a-different-chat');
  });

  test(
    'runs HEADLESS (does not activate) when no chat is being viewed',
    () async {
      const chatId = 'chat-idle';
      await seedChat(chatId);
      await seedMessage(chatId, 'asst-5', '');
      final (:container, :runner) = makeRunner(
        isStreaming: false,
        active: null,
      );

      await check(
        runner.run(chatId: chatId, payload: payload('asst-5')),
      ).throws<StateError>();
      // Headless never sets an active conversation.
      check(container.read(activeConversationProvider)).isNull();
    },
  );

  test(
    'DB await followed by a colliding direct-local active chat chooses headless',
    () async {
      const chatId = 'storage-collision';
      const assistantId = 'shared-assistant';
      await seedChat(chatId);
      await seedMessage(chatId, assistantId, '');

      final (:container, :runner) = makeRunner(
        isStreaming: true,
        active: conv(chatId),
      );
      final aMessages = <ChatMessage>[
        ChatMessage(
          id: 'user-a',
          role: 'user',
          content: 'A',
          timestamp: DateTime.utc(2026, 7, 13),
        ),
        ChatMessage(
          id: assistantId,
          role: 'assistant',
          content: '',
          timestamp: DateTime.utc(2026, 7, 13, 0, 0, 1),
          isStreaming: true,
        ),
      ];
      container.read(chatMessagesProvider.notifier).setMessages(aMessages);

      final transactionEntered = Completer<void>();
      final releaseTransaction = Completer<void>();
      final transaction = db.transaction(() async {
        transactionEntered.complete();
        await releaseTransaction.future;
      });
      await transactionEntered.future;

      final completion = runner.run(
        chatId: chatId,
        payload: payload(assistantId),
      );
      final expectation = expectLater(
        completion,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('runHeadlessCompletion'),
          ),
        ),
      );

      final bMessages = <ChatMessage>[
        ChatMessage(
          id: 'user-b',
          role: 'user',
          content: 'B must stay intact',
          timestamp: DateTime.utc(2026, 7, 13),
        ),
        ChatMessage(
          id: assistantId,
          role: 'assistant',
          content: 'B streaming bytes',
          timestamp: DateTime.utc(2026, 7, 13, 0, 0, 1),
          isStreaming: true,
        ),
      ];
      final directB = withChatStorageProvenance(
        conv(chatId).copyWith(messages: bMessages),
        ChatStorageKind.directLocal,
      );
      container.read(activeConversationProvider.notifier).set(directB);
      container.read(chatMessagesProvider.notifier).setMessages(bMessages);
      final bSnapshot = jsonEncode(
        bMessages.map((message) => message.toJson()).toList(),
      );

      releaseTransaction.complete();
      await transaction;
      await expectation;

      check(
        jsonEncode(
          container
              .read(chatMessagesProvider)
              .map((message) => message.toJson())
              .toList(),
        ),
      ).equals(bSnapshot);
      check(
        chatStorageKindOf(container.read(activeConversationProvider)),
      ).equals(ChatStorageKind.directLocal);
    },
  );
}

class _SeededActive extends ActiveConversationNotifier {
  _SeededActive(this._initial);

  final Conversation? _initial;

  @override
  Conversation? build() => _initial;
}

class _TestMessagesNotifier extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];

  @override
  void setMessages(List<ChatMessage> messages) {
    state = List<ChatMessage>.from(messages);
  }
}
