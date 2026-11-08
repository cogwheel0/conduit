import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_storage.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit_core/features/direct_connections/services/openai_compatible_adapter.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/direct_replay_output.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A direct-local answer has to come back from the database exactly as the
/// chat showed it when the stream finished: same reasoning section, same tool
/// sections, same answer. Every case here sends through the real direct turn
/// (finalizer, `directMessageRow`, `persistDirectMessages`) and reloads
/// through `ChatDatabaseRepository.loadConversation`, the path both the
/// mobile app and the desktop daemon open a stored chat with.
void main() {
  late bool previousDontWarn;

  setUpAll(() {
    previousDontWarn = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousDontWarn;
  });

  group('direct-local answer survives a reload', () {
    test('reasoning deltas', () async {
      final turn = await _sendAndReload(
        adapter: _ScriptedAdapter(const <DirectStreamEvent>[
          DirectReasoningDelta('Compare the two tide tables first.'),
          DirectContentDelta('High tide is at 14:05.'),
          DirectStreamDone(),
        ]),
      );

      expect(turn.live.content, contains('<details type="reasoning"'));
      expect(turn.reloaded.content, turn.live.content);
    });

    test('reasoning deltas with a provider tool call', () async {
      final turn = await _sendAndReload(
        adapter: _ScriptedAdapter(<DirectStreamEvent>[
          const DirectReasoningDelta('Look the harbour up before answering.'),
          DirectToolCallStarted(
            id: 'call_tide_7',
            name: 'tide_lookup',
            arguments: const <String, dynamic>{'harbour': 'Northcove'},
          ),
          DirectToolCallCompleted(
            id: 'call_tide_7',
            name: 'tide_lookup',
            arguments: const <String, dynamic>{'harbour': 'Northcove'},
            result: const <String, dynamic>{'high': '14:05'},
          ),
          const DirectContentDelta('High tide is at 14:05.'),
          const DirectStreamDone(),
        ]),
      );

      expect(turn.live.content, contains('<details type="reasoning"'));
      expect(turn.live.content, contains('<details type="tool_calls"'));
      expect(turn.reloaded.content, turn.live.content);
      expect(_detailsTypes(turn.reloaded.content), <String>[
        'reasoning',
        'tool_calls',
      ]);
      // The provider-facing raw answer and reasoning survive the reload too,
      // so the next request replays them instead of presentation text.
      expect(
        turn.reloaded.metadata?[kDirectRawAssistantContentMetadataKey],
        'High tide is at 14:05.',
      );
      expect(
        turn.reloaded.metadata?[kDirectRawAssistantReasoningMetadataKey],
        'Look the harbour up before answering.',
      );
    });

    test('a provider tool call without reasoning', () async {
      final turn = await _sendAndReload(
        adapter: _ScriptedAdapter(<DirectStreamEvent>[
          DirectToolCallStarted(
            id: 'call_tide_8',
            name: 'tide_lookup',
            arguments: const <String, dynamic>{'harbour': 'Eastmere'},
          ),
          DirectToolCallCompleted(
            id: 'call_tide_8',
            name: 'tide_lookup',
            arguments: const <String, dynamic>{'harbour': 'Eastmere'},
            result: 'No tide data for Eastmere.',
            isError: true,
          ),
          const DirectContentDelta('I could not find Eastmere.'),
          const DirectStreamDone(),
        ]),
      );

      expect(turn.live.content, contains('<details type="tool_calls"'));
      expect(turn.reloaded.content, turn.live.content);
    });

    test('reasoning and a provider tool call with no final answer', () async {
      final turn = await _sendAndReload(
        adapter: _ScriptedAdapter(<DirectStreamEvent>[
          const DirectReasoningDelta('The lookup should settle it.'),
          DirectToolCallStarted(
            id: 'call_tide_9',
            name: 'tide_lookup',
            arguments: const <String, dynamic>{'harbour': 'Westholm'},
          ),
          DirectToolCallCompleted(
            id: 'call_tide_9',
            name: 'tide_lookup',
            arguments: const <String, dynamic>{'harbour': 'Westholm'},
            result: const <String, dynamic>{'high': '09:40'},
          ),
          const DirectStreamDone(),
        ]),
      );

      expect(turn.reloaded.content, turn.live.content);
      expect(
        turn.reloaded.content,
        isNot(contains(kConduitDirectIncompleteAnswerReplayText)),
      );
    });

    test('raw <think> text in the answer', () async {
      // Direct adapters do not split inline think tags; the live chat shows
      // them as escaped answer text, and a reload must show the same.
      const raw = '<think>Check the almanac.</think>Low tide is at 08:12.';
      final turn = await _sendAndReload(
        adapter: _ScriptedAdapter(const <DirectStreamEvent>[
          DirectContentDelta(raw),
          DirectStreamDone(),
        ]),
      );

      expect(turn.reloaded.content, turn.live.content);
      expect(
        turn.reloaded.metadata?[kDirectRawAssistantContentMetadataKey],
        raw,
      );
    });

    test('an OpenAI-compatible stream with reasoning_content deltas', () async {
      final http = _SseAdapter(<String>[
        'data: {"choices":[{"delta":{"reasoning_content":"Spring tides "}}]}',
        'data: {"choices":[{"delta":{"reasoning_content":"run higher."}}]}',
        'data: {"choices":[{"delta":{"content":"Expect a 4.1 m high tide."}}]}',
        'data: [DONE]',
      ]);
      final turn = await _sendAndReload(
        adapter: OpenAiCompatibleAdapter(
          dioFactory: (_) => Dio()..httpClientAdapter = http,
          closeClients: false,
        ),
        adapterKey: kOpenAiCompatibleAdapterKey,
      );

      expect(http.requests, 1);
      expect(turn.live.content, contains('<details type="reasoning"'));
      expect(turn.live.content, contains('Spring tides run higher.'));
      expect(turn.reloaded.content, turn.live.content);
    });
  });

  group('direct-local rows stored without their rendered sections', () {
    // Before the fix, a direct answer whose output held a provider tool call
    // (any id other than Ollama's) was stored with only its answer text.
    // Those rows still hold the reasoning in their metadata and the tool calls
    // in their output; loading them must put both back.
    test('recovers reasoning and tool sections on load', () async {
      final reloaded = await _reloadStoredRow(
        events: <DirectStreamEvent>[
          const DirectReasoningDelta('Check both buoys.'),
          DirectToolCallStarted(
            id: 'call_buoy_1',
            name: 'buoy_reading',
            arguments: const <String, dynamic>{'buoy': 'north'},
          ),
          DirectToolCallCompleted(
            id: 'call_buoy_1',
            name: 'buoy_reading',
            arguments: const <String, dynamic>{'buoy': 'north'},
            result: const <String, dynamic>{'swell_m': 1.2},
          ),
          const DirectContentDelta('Swell is 1.2 m at the north buoy.'),
          const DirectStreamDone(),
        ],
      );

      expect(_detailsTypes(reloaded.content), <String>[
        'reasoning',
        'tool_calls',
      ]);
      expect(reloaded.content, contains('&gt; Check both buoys.'));
      expect(reloaded.content, contains('name="buoy_reading"'));
      expect(
        reloaded.content.trimRight(),
        endsWith('Swell is 1.2 m at the north buoy.'),
      );
    });

    test(
      'recovers a no-final-answer turn without the replay sentinel',
      () async {
        final reloaded = await _reloadStoredRow(
          events: <DirectStreamEvent>[
            const DirectReasoningDelta('One reading is enough.'),
            DirectToolCallStarted(
              id: 'call_buoy_2',
              name: 'buoy_reading',
              arguments: const <String, dynamic>{'buoy': 'south'},
            ),
            DirectToolCallCompleted(
              id: 'call_buoy_2',
              name: 'buoy_reading',
              arguments: const <String, dynamic>{'buoy': 'south'},
              result: const <String, dynamic>{'swell_m': 0.4},
            ),
            const DirectStreamDone(),
          ],
        );

        expect(_detailsTypes(reloaded.content), <String>[
          'reasoning',
          'tool_calls',
        ]);
        expect(
          reloaded.content,
          isNot(contains(kConduitDirectIncompleteAnswerReplayText)),
        );
      },
    );
  });
}

const _chatId = 'direct-local:tide-chat';

typedef _Turn = ({ChatMessage live, ChatMessage reloaded});

/// Sends one follow-up in a stored direct-local chat and reloads the chat.
Future<_Turn> _sendAndReload({
  required DirectProviderAdapter adapter,
  String adapterKey = _scriptedAdapterKey,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final profile = DirectConnectionProfile(
    id: 'tide-profile',
    name: 'Tide provider',
    adapterKey: adapterKey,
    baseUrl: 'https://tides.example/v1',
    apiKey: 'synthetic-key',
  );
  final registry = DirectModelRegistry();
  final model = registry.replaceProfileModels(profile, [
    DirectRemoteModel(id: 'tide-model'),
  ]).single;
  final now = DateTime.utc(2026, 3, 2);
  final firstUser = ChatMessage(
    id: 'user-1',
    role: 'user',
    content: 'When is high tide?',
    timestamp: now,
    metadata: const {
      'parentId': null,
      'childrenIds': <String>['assistant-1'],
    },
  );
  final firstAssistant = ChatMessage(
    id: 'assistant-1',
    role: 'assistant',
    content: 'Which harbour?',
    timestamp: now,
    model: model.id,
    metadata: const {
      'parentId': 'user-1',
      'childrenIds': <String>[],
      'transport': kDirectTransport,
    },
  );
  final rows = ChatBlobMapper.blobToRows(
    chatId: _chatId,
    blob: directNewChatBlob(
      title: 'Tides',
      modelId: model.id,
      messages: [firstUser, firstAssistant],
    ),
    title: 'Tides',
    createdAt: 1,
    updatedAt: 2,
  );
  await db.chatsDao.upsertLocalOnlyChat(rows: rows);

  final container = ProviderContainer(
    overrides: [
      activeConversationProvider.overrideWith(_ActiveConversation.new),
      selectedModelProvider.overrideWithValue(model),
      reviewerModeProvider.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(null),
      socketServiceProvider.overrideWithValue(null),
      appDatabaseProvider.overrideWithValue(null),
      directLocalDatabaseProvider.overrideWithValue(db),
      directModelRegistryProvider.overrideWithValue(registry),
      directConnectionProfilesProvider.overrideWith(() => _Profiles(profile)),
      directProviderAdapterRegistryProvider.overrideWithValue(
        DirectProviderAdapterRegistry([adapter]),
      ),
    ],
  );
  addTearDown(container.dispose);
  final active = withChatStorageProvenance(
    Conversation(
      id: _chatId,
      title: 'Tides',
      createdAt: now,
      updatedAt: now,
      model: model.id,
      messages: [firstUser, firstAssistant],
    ),
    ChatStorageKind.directLocal,
  );
  container.read(activeConversationProvider.notifier).set(active);
  container.read(chatMessagesProvider.notifier).setMessages(active.messages);

  await sendMessageWithContainer(container, 'Northcove, please.', null);

  final live = container.read(chatMessagesProvider).last;
  expect(live.role, 'assistant');
  expect(live.isStreaming, isFalse);
  expect(live.error, isNull);

  final located = await container
      .read(chatDatabaseRepositoryProvider)
      .loadConversation(_chatId, preferred: ChatStorageKind.directLocal);
  expect(located, isNotNull);
  final reloaded = located!.conversation.messages.singleWhere(
    (message) => message.id == live.id,
  );
  return (live: live, reloaded: reloaded);
}

/// Stores a finished direct answer the way builds before this fix did for
/// a turn with provider tool calls: the row's `content` held only the
/// output's message text, while `output` and `metadata` kept everything
/// else. Returns the message as the load path rebuilds it.
Future<ChatMessage> _reloadStoredRow({
  required List<DirectStreamEvent> events,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final repository = ChatDatabaseRepository(
    openWebUiDatabase: null,
    directLocalDatabase: db,
  );

  final accumulator = DirectStreamingAccumulator();
  for (final event in events) {
    accumulator.apply(event);
  }
  final output = <Map<String, dynamic>>[
    ...accumulator.toolOutput,
    ...?directProviderReplayOutput(
      assistantMessageId: 'assistant-2',
      rawContent: accumulator.text,
      useIncompleteAnswerSentinel:
          accumulator.text.trim().isEmpty &&
          (accumulator.reasoning.trim().isNotEmpty ||
              accumulator.toolOutput.isNotEmpty),
    ),
  ];
  final now = DateTime.utc(2026, 3, 3);
  final user = ChatMessage(
    id: 'user-2',
    role: 'user',
    content: 'How big is the swell?',
    timestamp: now,
  );
  final assistant = ChatMessage(
    id: 'assistant-2',
    role: 'assistant',
    content: accumulator.render(done: true),
    timestamp: now,
    model: 'tide-model',
    output: output,
    metadata: <String, dynamic>{
      kDirectRawAssistantContentMetadataKey: accumulator.text,
      if (accumulator.reasoning.trim().isNotEmpty)
        kDirectRawAssistantReasoningMetadataKey: accumulator.reasoning,
    },
  );
  final storedAnswer = outputMessageText(output);
  final row = directMessageRow(
    chatId: _chatId,
    message: assistant,
    parentId: user.id,
    childrenIds: const <String>[],
    orderIndex: 1,
  );
  final legacyRow = MessageRowData(
    id: row.id,
    chatId: row.chatId,
    parentId: row.parentId,
    role: row.role,
    content: storedAnswer,
    model: row.model,
    createdAt: row.createdAt,
    orderIndex: row.orderIndex,
    payload: <String, dynamic>{...row.payload, 'content': storedAnswer},
  );

  final location = repository.locationFor(ChatStorageKind.directLocal);
  await repository.persistNewDirectChat(
    location,
    ChatBlobMapper.blobToRows(
      chatId: _chatId,
      blob: directNewChatBlob(
        title: 'Swell',
        modelId: 'tide-model',
        messages: [user],
      ),
      title: 'Swell',
      createdAt: 1,
      updatedAt: 1,
    ),
  );
  await repository.persistDirectMessages(
    location,
    chatId: _chatId,
    messages: <MessageRowData>[legacyRow],
    currentMessageId: assistant.id,
    updatedAt: 2,
  );

  final located = await repository.loadConversation(
    _chatId,
    preferred: ChatStorageKind.directLocal,
  );
  return located!.conversation.messages.singleWhere(
    (message) => message.id == assistant.id,
  );
}

/// The joined text of the output's `message` items, as Open WebUI's
/// `getOutputText` reads it.
String outputMessageText(List<Map<String, dynamic>> output) => output
    .where((item) => item['type'] == 'message')
    .expand((item) => item['content'] as List)
    .map((part) => (part as Map)['text'] as String)
    .join('\n');

List<String> _detailsTypes(String content) => RegExp(
  r'^<details type="([a-z_]+)"',
  multiLine: true,
).allMatches(content).map((match) => match.group(1)!).toList();

const _scriptedAdapterKey = 'scripted-test-adapter';

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _Profiles extends DirectConnectionProfilesController {
  _Profiles(this.profile);

  final DirectConnectionProfile profile;

  @override
  Future<List<DirectConnectionProfile>> build() async => [profile];
}

/// Replays a fixed list of normalized provider events, the shape every direct
/// adapter emits after parsing its wire format.
final class _ScriptedAdapter implements DirectProviderAdapter {
  _ScriptedAdapter(this.events);

  final List<DirectStreamEvent> events;

  @override
  String get key => _scriptedAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => [DirectRemoteModel(id: 'tide-model')];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) => DirectCompletionRun(
    id: 'scripted-run',
    profileId: profile.id,
    remoteModelId: request.remoteModelId,
    events: Stream<DirectStreamEvent>.fromIterable(events),
    cancelToken: CancelToken(),
    done: Future<void>.value(),
  );
}

/// Answers every request with one server-sent-events stream.
final class _SseAdapter implements HttpClientAdapter {
  _SseAdapter(this.lines);

  final List<String> lines;
  var requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody(
      Stream<Uint8List>.fromIterable(<Uint8List>[
        for (final line in lines) Uint8List.fromList(utf8.encode('$line\n\n')),
      ]),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
