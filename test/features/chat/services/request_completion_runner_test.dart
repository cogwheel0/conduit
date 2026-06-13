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
        activeConversationProvider.overrideWith(
          () => _SeededActive(active),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, runner: container.read(runnerProvider));
  }

  Future<void> seedChat(String chatId) async {
    await db.into(db.chats).insert(
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
    String content,
  ) async {
    await db.into(db.messages).insert(
      MessagesCompanion.insert(
        id: id,
        chatId: chatId,
        role: 'assistant',
        content: content,
        createdAt: 1,
        orderIndex: 0,
        payload: '{}',
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

  Map<String, dynamic> payload(String assistantId) =>
      RequestCompletionPayload(
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
    // Non-empty content => the turn already completed; runner is a no-op.
    await seedMessage(chatId, 'asst-2', 'already answered');

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

  test('returns early when the chat row vanished (delete won the race)',
      () async {
    const chatId = 'chat-absent';
    // Active is a DIFFERENT chat so the runner takes the activate branch,
    // finds no row, and returns.
    final (:container, :runner) = makeRunner(
      isStreaming: false,
      active: conv('other-chat'),
    );
    container;

    // No chat seeded: must return without throwing.
    await runner.run(chatId: chatId, payload: payload('asst-3'));

    final rows = await db.messagesDao.getForChat(chatId);
    check(rows).isEmpty();
  });
}

class _SeededActive extends ActiveConversationNotifier {
  _SeededActive(this._initial);

  final Conversation? _initial;

  @override
  Conversation? build() => _initial;
}
