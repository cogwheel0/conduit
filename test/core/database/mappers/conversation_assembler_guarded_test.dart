/// Tests for [assembleConversationGuarded] — the contract-enforcing wrapper
/// that offloads large-conversation assembly off the UI isolate.
library;

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/mappers/conversation_assembler.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_blob_fixtures.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<(ChatRow, List<MessageRow>)> seedFixture() async {
    final fixture = loadChatBlobFixtures()
        .singleWhere((f) => f.name == '02_linear_multi_turn');
    await db.chatsDao.upsertServerChat(rows: rowsFromFixture(fixture));
    final chat = (await db.chatsDao.getChat(fixture.chatId))!;
    final messages = await db.messagesDao.getForChat(fixture.chatId);
    return (chat, messages);
  }

  group('assembleConversationGuarded', () {
    test(
      'messages.length <= threshold: offload NOT called; result matches sync parse',
      () async {
        final (chat, messages) = await seedFixture();

        // The fixture has far fewer than kLocalConversationWorkerThreshold messages.
        check(messages.length).isLessThan(kLocalConversationWorkerThreshold);

        var offloadCallCount = 0;
        // This branch must never be entered.
        Future<Conversation> offload(Object? envelope) async {
          offloadCallCount++;
          return assembleConversation(chat, messages);
        }

        final result = await assembleConversationGuarded(
          chat,
          messages,
          offload: offload,
        );

        check(offloadCallCount).equals(0);
        final expected = assembleConversation(chat, messages);
        check(result.id).equals(expected.id);
        check(result.title).equals(expected.title);
        check(result.messages.length).equals(expected.messages.length);
      },
    );

    test(
      'messages.length > threshold: offload IS called exactly once with non-null envelope',
      () async {
        final (chat, realMessages) = await seedFixture();

        // Pad the list past the threshold; the guarded helper only checks length.
        final padded = <MessageRow>[
          ...realMessages,
          for (var i = 0; i < kLocalConversationWorkerThreshold; i++)
            realMessages.first,
        ];
        check(padded.length).isGreaterThan(kLocalConversationWorkerThreshold);

        var offloadCallCount = 0;
        Object? capturedEnvelope;
        final syncResult = assembleConversation(chat, realMessages);
        Future<Conversation> offload(Object? envelope) async {
          offloadCallCount++;
          capturedEnvelope = envelope;
          return syncResult;
        }

        final result = await assembleConversationGuarded(
          chat,
          padded,
          offload: offload,
        );

        check(offloadCallCount).equals(1);
        check(capturedEnvelope).isNotNull();
        check(identical(result, syncResult)).isTrue();
      },
    );

    test(
      'messages.length > threshold, offload null: falls back to synchronous parse without throwing',
      () async {
        final (chat, realMessages) = await seedFixture();

        // Pad the list past the threshold.
        final padded = <MessageRow>[
          ...realMessages,
          for (var i = 0; i < kLocalConversationWorkerThreshold; i++)
            realMessages.first,
        ];
        check(padded.length).isGreaterThan(kLocalConversationWorkerThreshold);

        // Must not throw even with offload == null.
        final result = await assembleConversationGuarded(
          chat,
          padded,
          offload: null,
        );

        check(result).isA<Conversation>();
        check(result.id).equals(chat.id);
      },
    );
  });
}
