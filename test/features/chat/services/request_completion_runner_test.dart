import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/database_provider.dart';
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
  }) {
    final runnerProvider = Provider<RequestCompletionRunner>(
      ChatRequestCompletionRunner.new,
    );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        isChatStreamingProvider.overrideWithValue(isStreaming),
        activeConversationProvider.overrideWith(() => _SeededActive(active)),
        // No api/socket stack here: the headless/live drive both short-circuit
        // on the null-api guard, letting these tests assert the PATH choice
        // (headless vs live vs defer) without a real transport.
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
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
}

class _SeededActive extends ActiveConversationNotifier {
  _SeededActive(this._initial);

  final Conversation? _initial;

  @override
  Conversation? build() => _initial;
}
