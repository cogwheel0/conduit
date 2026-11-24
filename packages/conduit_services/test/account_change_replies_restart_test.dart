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
import 'support/window.dart';

/// A Direct reply the daemon stops under, and one a daemon that died left
/// stored as still being written: each opens as a finished answer.
void main() {
  late Directory temporary;
  late ScriptedOpenAi provider;

  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('account-change-restart');
    addTearDown(() => temporary.deleteSync(recursive: true));
    provider = await ScriptedOpenAi.start();
    addTearDown(provider.close);
  });

  /// A daemon on [temporary] whose Direct reply the provider holds after
  /// its words; returned once the window has been told them.
  ///
  /// [abandoned]: the daemon dies rather than stops, so its turns are never
  /// disposed.
  Future<(CoreRuntime, TurnsService, String)> holdReply(
    String key, {
    bool abandoned = false,
  }) async {
    final runtime = await startTestCore(temporary);
    addTearDown(runtime.dispose);
    final events = EventBus();
    final turns = TurnsService(runtime.container, events);
    if (!abandoned) addTearDown(turns.dispose);
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
    final told = Completer<void>();
    String? chatId;
    events.attach('window', (envelope) {
      if (envelope.event == ConduitEvents.turnDelta &&
          envelope.payload['chatId'] == chatId &&
          '${envelope.payload['text']}'.trim() == 'Words before the pause' &&
          !told.isCompleted) {
        told.complete();
      }
    });
    final accepted = await turns.send(
      SendTurn(model: model, text: 'hold:$key Words before the pause'),
    );
    chatId = accepted.chatId;
    subscribeWindow(events, turns, 'window', <String>[accepted.chatId]);
    await told.future;
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

  /// A daemon on [temporary] again, after the last one stopped.
  Future<(CoreRuntime, ChatsService)> restart() async {
    final runtime = await startTestCore(temporary);
    addTearDown(runtime.dispose);
    final chats = ChatsService(runtime.container, events: EventBus());
    addTearDown(chats.dispose);
    return (runtime, chats);
  }

  test('quitting while a Direct reply streams stores the words that came as '
      'a finished answer, without waiting on the provider', () async {
    final (runtime, turns, chatId) = await holdReply('quit');
    await turns.dispose();
    await runtime.dispose();
    expect(provider.steps, isNot(contains('quit released')));

    final (again, chats) = await restart();
    final stored = await storedPayload(again, chatId);
    expect('${stored['content']}'.trim(), 'Words before the pause');
    expect(stored['isStreaming'], isFalse);
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
        final (runtime, _, chatId) = await holdReply('crash', abandoned: true);
        await runtime.dispose();
        crashed.complete(chatId);
      } on Object catch (error, stackTrace) {
        crashed.completeError(error, stackTrace);
      }
    }, (_, _) {});
    final chatId = await crashed.future;

    final (again, chats) = await restart();
    expect((await storedPayload(again, chatId))['isStreaming'], isTrue);
    final answer = (await chats.get(chatId))!.messages.last;
    expect(answer.role, 'assistant');
    expect(answer.streaming, isFalse);
    final stored = await storedPayload(again, chatId);
    expect(stored['isStreaming'], isFalse);
    expect(stored['done'], isTrue);
  });
}
