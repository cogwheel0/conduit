@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageIdentity;
import 'package:conduit_core/database/database_provider.dart'
    show directLocalDatabaseProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:test/test.dart';

import 'support/core.dart';
import 'support/scripted_openai.dart';

/// A Direct reply the daemon stops under, and one a daemon that died left
/// stored as still being written: each opens as a finished answer.
void main() {
  late Directory temporary;
  late ScriptedOpenAi provider;

  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('account-change-restart');
    provider = await ScriptedOpenAi.start();
  });

  tearDown(() async {
    await provider.close();
    temporary.deleteSync(recursive: true);
  });

  /// Starts a daemon on [temporary] and sends a Direct reply the provider
  /// holds after its words, returning the chat once they have come.
  Future<(CoreRuntime, TurnsService, String)> holdReply(String key) async {
    final runtime = await startTestCore(temporary);
    final turns = TurnsService(runtime.container, EventBus());
    final saved = await DirectService(runtime.container).save(
      DirectConnectionEdit(
        name: 'Scripted',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['scripted-model'],
      ),
    );
    final model = DirectModelId.encode(
      saved.connections.single.id,
      'scripted-model',
    );
    final asked = provider.asked('hold:$key');
    final accepted = await turns.send(
      SendTurn(model: model, text: 'hold:$key Words before the pause'),
    );
    await asked;
    while (!provider.steps.contains('$key holding')) {
      await pumpEventQueue();
    }
    await pumpEventQueue(times: 100);
    return (runtime, turns, accepted.chatId);
  }

  /// The answer as the stored copy has it.
  Future<Map<String, dynamic>> storedPayload(
    CoreRuntime runtime,
    String chatId,
  ) async {
    final rows = await runtime.container
        .read(directLocalDatabaseProvider)
        .messagesDao
        .getForChat(ChatStorageIdentity.parse(chatId).rawId);
    final answer = rows.lastWhere((row) => row.role == 'assistant');
    return <String, dynamic>{
      ...jsonDecode(answer.payload) as Map<String, dynamic>,
      'content': answer.content,
    };
  }

  test('quitting while a Direct reply streams stores the words that came as '
      'a finished answer, without waiting on the provider', () async {
    final (runtime, turns, chatId) = await holdReply('quit');
    await turns.dispose();
    await runtime.dispose().timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail('the quit waited on the provider'),
    );
    expect(provider.steps, isNot(contains('quit released')));

    final again = await startTestCore(temporary);
    final chats = ChatsService(again.container, events: EventBus());
    addTearDown(() async {
      chats.dispose();
      await again.dispose();
    });
    final answer = (await chats.get(chatId))!.messages.last;
    expect(answer.content.trim(), 'Words before the pause');
    expect(answer.streaming, isFalse);
  });

  test('an answer a dead daemon left stored as still being written opens as '
      'a finished one, and is stored that way', () async {
    // No turn is stopped: the process died with the reply in flight. What
    // its abandoned services raise after that is no process's to see.
    final crashed = Completer<String>();
    runZonedGuarded(() async {
      try {
        final (runtime, _, chatId) = await holdReply('crash');
        await runtime.dispose();
        crashed.complete(chatId);
      } on Object catch (error, stackTrace) {
        crashed.completeError(error, stackTrace);
      }
    }, (_, _) {});
    final chatId = await crashed.future;

    final again = await startTestCore(temporary);
    final chats = ChatsService(again.container, events: EventBus());
    addTearDown(() async {
      chats.dispose();
      await again.dispose();
    });
    expect((await storedPayload(again, chatId))['isStreaming'], isTrue);
    final answer = (await chats.get(chatId))!.messages.last;
    expect(answer.role, 'assistant');
    expect(answer.streaming, isFalse);
    final stored = await storedPayload(again, chatId);
    expect(stored['isStreaming'], isFalse);
    expect(stored['done'], isTrue);
  });
}
