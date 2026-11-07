import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_message_actions.dart'
    show resendEditedUserMessage;
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/features/librechat/providers/librechat_composer_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_transport.dart';
import 'package:conduit_core/features/librechat/providers/librechat_model_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_sync_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _root = '00000000-0000-0000-0000-000000000000';

final class _Preferred extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.libreChat;
}

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _IdleSyncEngine extends SyncEngine {
  @override
  Future<PullResult?> requestPull({required String reason}) =>
      Future<PullResult?>.value(null);
}

/// LibreChat's generation routes, scripted: each start is recorded and
/// answered from [startAnswers] (else "started"), and each subscription gets
/// a stream the test writes frames into.
final class _ScriptedChat {
  _ScriptedChat(this.fake) {
    fake
      ..on('POST', '/api/agents/chat/([^/]+)', (request, match) {
        final body = Map<String, dynamic>.from(request.data as Map);
        starts.add(body);
        if (startAnswers.isNotEmpty) return startAnswers.removeAt(0)(body);
        final id = body['conversationId'] as String? ?? newConversationId;
        return FakeLibreChatResponse.json({
          'streamId': id,
          'conversationId': id,
          'generationCreatedAt': 42,
          'status': 'started',
        });
      })
      ..on('POST', '/api/agents/chat/abort', (request, match) {
        aborts.add(Map<String, dynamic>.from(request.data as Map));
        emit({
          'final': true,
          'aborted': true,
          'responseMessage': {
            'messageId': lastResponseId,
            'content': [
              {'type': 'text', 'text': 'Stopped here'},
            ],
          },
        });
        end();
        return FakeLibreChatResponse.json({'success': true});
      })
      ..on(
        'GET',
        '/api/agents/chat/status/(.+)',
        (request, match) => FakeLibreChatResponse.json({'active': false}),
      )
      ..on('GET', '/api/agents/chat/stream/(.+)', (request, match) {
        final controller = StreamController<Uint8List>();
        streams.add(controller);
        return FakeLibreChatResponse(
          200,
          contentType: 'text/event-stream',
          stream: controller.stream,
        );
      })
      ..on(
        'GET',
        '/api/endpoints',
        (request, match) => FakeLibreChatResponse.json({
          'Ollama': {
            'order': 1,
            'type': 'custom',
            'modelDisplayLabel': 'Ollama',
          },
        }),
      )
      ..on(
        'GET',
        '/api/models',
        (request, match) => FakeLibreChatResponse.json({
          'Ollama': ['llama3.2'],
        }),
      )
      ..on(
        'GET',
        '/api/agents',
        (request, match) =>
            FakeLibreChatResponse.json({'data': <Object>[], 'has_more': false}),
      );
  }

  final FakeLibreChatServer fake;
  final List<Map<String, dynamic>> starts = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> aborts = <Map<String, dynamic>>[];
  final List<StreamController<Uint8List>> streams =
      <StreamController<Uint8List>>[];
  final List<FakeLibreChatResponse Function(Map<String, dynamic>)>
  startAnswers = <FakeLibreChatResponse Function(Map<String, dynamic>)>[];
  String newConversationId = 'conv-new';
  String lastResponseId = 'a-srv';

  void emit(Map<String, dynamic> json) => streams.last.add(
    Uint8List.fromList(
      utf8.encode('event: message\ndata: ${jsonEncode(json)}\n\n'),
    ),
  );

  void end() {
    if (!streams.last.isClosed) unawaited(streams.last.close());
  }

  void created(String userId, String text, {String parent = _root}) => emit({
    'created': true,
    'message': {
      'messageId': userId,
      'parentMessageId': parent,
      'text': text,
      'isCreatedByUser': true,
    },
  });

  void text(String responseId, String chunk, {String step = 'step-text'}) {
    lastResponseId = responseId;
    emit({
      'event': 'on_run_step',
      'data': {
        'id': step,
        'runId': responseId,
        'index': 0,
        'stepDetails': {'type': 'message_creation'},
      },
    });
    emit({
      'event': 'on_message_delta',
      'data': {
        'id': step,
        'delta': {
          'content': [
            {'type': 'text', 'text': chunk},
          ],
        },
      },
    });
  }

  void finish(String responseId, String full) {
    emit({
      'final': true,
      'responseMessage': {
        'messageId': responseId,
        'content': [
          {'type': 'text', 'text': full},
        ],
      },
    });
    end();
  }
}

/// The app going to the background and coming back, as the test says.
final class _Lifecycle implements AppLifecyclePort {
  final StreamController<AppLifecyclePhase> _changes =
      StreamController<AppLifecyclePhase>.broadcast();
  AppLifecyclePhase _current = AppLifecyclePhase.resumed;

  @override
  AppLifecyclePhase? get current => _current;

  @override
  Stream<AppLifecyclePhase> get changes => _changes.stream;

  void emit(AppLifecyclePhase phase) {
    _current = phase;
    _changes.add(phase);
  }

  Future<void> close() => _changes.close();
}

/// What the chat shows, for a failure message.
String Function()? _describeChat;

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Condition never held. ${_describeChat?.call() ?? ''}');
}

Map<String, dynamic> _message(
  String id,
  String text, {
  required bool user,
  String parent = _root,
}) => {
  'messageId': id,
  'parentMessageId': parent,
  'isCreatedByUser': user,
  'text': text,
  if (!user)
    'content': [
      {'type': 'text', 'text': text},
    ],
  'createdAt': user ? '2026-10-18T10:00:00.000Z' : '2026-10-18T10:00:05.000Z',
};

void main() {
  const server = LibreChatServer(baseUrl: 'https://chat.example.com');
  late FakeLibreChatServer fake;
  late _ScriptedChat chat;
  late AppDatabase libreChatDb;
  late AppDatabase owuiDb;
  late AppDatabase directDb;
  late ProviderContainer container;
  late List<Duration> sleeps;
  var stopFallback = const Duration(seconds: 8);

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late _Lifecycle lifecycle;

  setUp(() async {
    stopFallback = const Duration(seconds: 8);
    lifecycle = _Lifecycle();
    addTearDown(lifecycle.close);
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    fake = FakeLibreChatServer()..addUser();
    chat = _ScriptedChat(fake);
    sleeps = <Duration>[];
    libreChatDb = AppDatabase(NativeDatabase.memory());
    owuiDb = AppDatabase(NativeDatabase.memory());
    directDb = AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: owuiDb),
        preferredBackendProvider.overrideWith(_Preferred.new),
        secureStorageProvider.overrideWithValue(InMemorySecureKeyValueStore()),
        libreChatHttpAdapterProvider.overrideWithValue(fake),
        libreChatDatabaseProvider.overrideWith((ref) {
          final session = ref.watch(libreChatSessionProvider).asData?.value;
          return session is LibreChatSignedInState ? libreChatDb : null;
        }),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        isOnlineProvider.overrideWithValue(true),
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        socketServiceProvider.overrideWithValue(null),
        apiServiceProvider.overrideWithValue(null),
        syncEngineProvider.overrideWith(_IdleSyncEngine.new),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
        libreChatTurnSleepProvider.overrideWithValue((delay) async {
          sleeps.add(delay);
        }),
        libreChatStopFallbackProvider.overrideWith((ref) => stopFallback),
        appLifecycleProvider.overrideWithValue(lifecycle),
      ],
    );
    container.listen(chatMessagesProvider, (_, _) {});
    _describeChat = () => [
      'chat ${container.read(activeConversationProvider)?.id}',
      for (final m in container.read(chatMessagesProvider))
        '${m.id} ${m.role} streaming=${m.isStreaming} "${m.content}" '
            'error=${m.error?.content} ${m.metadata}',
      'starts ${chat.starts.length}, streams ${chat.streams.length}',
    ].join('\n');

    final auth = LibreChatAuthService(server, adapter: fake);
    final signedIn = await auth.signIn(
      email: 'dev@example.com',
      password: 'devpassword',
    ) as LibreChatSignedIn;
    auth.close();
    await container
        .read(libreChatAccountsProvider)
        .saveSignedIn(server: server, session: signedIn.session);
    await container.read(libreChatSessionProvider.future);
    final catalog = await container.read(libreChatModelCatalogProvider.future);
    container.read(selectedModelProvider.notifier).set(catalog.single);
  });

  tearDown(() async {
    for (final stream in chat.streams) {
      if (!stream.isClosed) await stream.close();
    }
    container.dispose();
    await libreChatDb.close();
    await owuiDb.close();
    await directDb.close();
    PreferencesStore.debugReset();
  });

  List<ChatMessage> visible() => container.read(chatMessagesProvider);
  // A streaming reply shows through the live tail until it settles.
  String shown() =>
      container.read(streamingContentProvider) ?? visible().last.content;
  Conversation? active() => container.read(activeConversationProvider);

  /// Sends [text] as a new chat's first turn, answered with [answer] and
  /// saved on the server.
  Future<void> firstTurn(String text, String answer) async {
    final send = sendMessageWithContainer(container, text, null);
    await _until(() => chat.streams.isNotEmpty);
    chat
      ..created('u-srv', text)
      ..text('a-srv', answer);
    fake.addConversation(
      'conv-new',
      title: 'Greeting',
      messageList: [
        _message('u-srv', text, user: true),
        _message('a-srv', answer, user: false, parent: 'u-srv'),
      ],
    );
    chat.finish('a-srv', answer);
    await send;
    await _until(
      () =>
          visible().length == 2 &&
          visible().every((message) => !message.isStreaming) &&
          visible().last.id == 'a-srv',
    );
  }

  test('the catalog joins the picker while LibreChat is primary', () async {
    final models = await container.read(modelsProvider.future);
    final libreChat = models.where(isLibreChatModel).toList();
    check(libreChat.map((model) => model.id))
        .deepEquals(['librechat:model:Ollama/llama3.2']);
    check(libreChat.single.metadata?['libreChatSection']).equals('Ollama');
  });

  test('refreshing the models fetches LibreChat\'s catalog again', () async {
    await container.read(modelsProvider.future);
    fake.on(
      'GET',
      '/api/models',
      (request, match) => FakeLibreChatResponse.json({
        'Ollama': ['llama3.2', 'qwen3'],
      }),
    );
    await container.read(modelsProvider.notifier).refresh();
    final models = await container.read(modelsProvider.future);
    check(models.where(isLibreChatModel).map((model) => model.id))
        .unorderedEquals([
          'librechat:model:Ollama/llama3.2',
          'librechat:model:Ollama/qwen3',
        ]);
  });

  test('a new chat streams, takes the server\'s ids, and keeps only the '
      'server\'s rows', () async {
    final send = sendMessageWithContainer(container, 'Hi there', null);
    await _until(() => chat.streams.isNotEmpty);
    final start = chat.starts.single;
    check(start)
      ..has((it) => it['endpoint'], 'endpoint').equals('Ollama')
      ..has((it) => it['endpointType'], 'endpointType').equals('custom')
      ..has((it) => it['model'], 'model').equals('llama3.2')
      ..has((it) => it['conversationId'], 'conversationId').isNull()
      ..has((it) => it['parentMessageId'], 'parent').equals(_root)
      ..has((it) => it['text'], 'text').equals('Hi there');

    // The server named the chat on start.
    await _until(() => active()?.id == 'conv-new');
    check(isLibreChatConversation(active())).isTrue();

    chat
      ..created('u-srv', 'Hi there')
      ..text('a-srv', 'Hello');
    await _until(() => shown().contains('Hello'));
    check(visible().map((message) => message.id))
        .deepEquals(['u-srv', 'a-srv']);
    check(visible().last.isStreaming).isTrue();
    check(visible().last.metadata?['transport']).equals(kLibreChatTransport);
    check(container.read(libreChatActiveGenerationsProvider))
        .contains('conv-new');

    fake.addConversation(
      'conv-new',
      title: 'Greeting',
      messageList: [
        _message('u-srv', 'Hi there', user: true),
        _message('a-srv', 'Hello world', user: false, parent: 'u-srv'),
      ],
    );
    chat.finish('a-srv', 'Hello world');
    await send;

    await _until(() => !visible().last.isStreaming);
    check(visible().last.content).equals('Hello world');
    check(container.read(libreChatActiveGenerationsProvider)).isEmpty();

    // The pull stores the server's rows, which the chat adopts in place.
    var stored = <String>[];
    for (var i = 0; i < 200 && stored.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      stored = [
        for (final row in await libreChatDb.messagesDao.getForChat('conv-new'))
          row.id,
      ];
    }
    check(stored).unorderedEquals(['u-srv', 'a-srv']);
    await pumpEventQueue();
    check(visible().map((message) => message.id))
        .deepEquals(['u-srv', 'a-srv']);
    check(visible().last.content).equals('Hello world');
  });

  test('a follow-up answers the server\'s last message', () async {
    await firstTurn('Hi there', 'Hello world');
    final send = sendMessageWithContainer(container, 'And you?', null);
    await _until(() => chat.streams.length == 2);
    check(chat.starts.last)
      ..has((it) => it['conversationId'], 'conversationId').equals('conv-new')
      ..has((it) => it['parentMessageId'], 'parent').equals('a-srv');
    chat
      ..created('u2-srv', 'And you?', parent: 'a-srv')
      ..text('a2-srv', 'Fine');
    chat.finish('a2-srv', 'Fine');
    await send;
  });

  test('stop aborts on the server and the reply settles', () async {
    final send = sendMessageWithContainer(container, 'Write a lot', null);
    await _until(() => chat.streams.isNotEmpty);
    chat
      ..created('u-srv', 'Write a lot')
      ..text('a-srv', 'Once');
    await _until(() => shown().contains('Once'));

    container.read(stopGenerationProvider)();
    await _until(() => chat.aborts.isNotEmpty);
    check(chat.aborts.single)
      ..has((it) => it['conversationId'], 'conversationId').equals('conv-new')
      ..has((it) => it['generationCreatedAt'], 'createdAt').equals(42);
    await send;
    await _until(() => !visible().last.isStreaming);
    check(visible().last.content).contains('Stopped here');
  });

  test('stop ends the reply on time when the server cannot answer the '
      'abort', () async {
    stopFallback = const Duration(milliseconds: 20);
    fake.on(
      'POST',
      '/api/agents/chat/abort',
      (request, match) => Completer<FakeLibreChatResponse>().future,
    );
    final send = sendMessageWithContainer(container, 'Write a lot', null);
    await _until(() => chat.streams.isNotEmpty);
    chat
      ..created('u-srv', 'Write a lot')
      ..text('a-srv', 'Once');
    await _until(() => shown().contains('Once'));

    container.read(stopGenerationProvider)();
    await send;
    await _until(() => !visible().last.isStreaming);
    check(visible().last.isStreaming).isFalse();
    check(visible().last.content).equals('Once');
  });

  test('New Chat while the start waits keeps the old turn out of the new '
      'draft, and the named chat is listed', () async {
    final started = Completer<void>();
    fake.on('POST', '/api/agents/chat/(Ollama)', (request, match) async {
      chat.starts.add(Map<String, dynamic>.from(request.data as Map));
      await started.future;
      return FakeLibreChatResponse.json({
        'streamId': 'conv-new',
        'conversationId': 'conv-new',
        'generationCreatedAt': 42,
        'status': 'started',
      });
    });
    final send = sendMessageWithContainer(container, 'First draft', null);
    await _until(() => chat.starts.isNotEmpty);
    final localUserId = visible().first.id;

    // New Chat: the draft is closed and emptied.
    container.read(activeConversationProvider.notifier).clear();
    container.read(chatMessagesProvider.notifier).clearMessages();
    check(visible()).isEmpty();
    started.complete();
    await _until(() => chat.streams.isNotEmpty);
    await pumpEventQueue();
    check(active()).isNull();
    check(visible()).isEmpty();
    check(
      container.read(libreChatActiveGenerationsProvider),
    ).contains('conv-new');
    check(await libreChatDb.chatsDao.getChat('conv-new')).isNotNull();

    chat
      ..created('u-srv', 'First draft')
      ..text('a-srv', 'Hello');
    fake.addConversation(
      'conv-new',
      title: 'Greeting',
      messageList: [
        _message('u-srv', 'First draft', user: true),
        _message('a-srv', 'Hello', user: false, parent: 'u-srv'),
      ],
    );
    chat.finish('a-srv', 'Hello');
    await send;
    check(visible()).isEmpty();
    check(
      container.read(chatMessagesProvider.notifier).currentMessageId(
        localUserId,
      ),
    ).equals(localUserId);
  });

  test('ids the server gives are found from the ones minted here', () async {
    final send = sendMessageWithContainer(container, 'Hi there', null);
    await _until(() => chat.streams.isNotEmpty);
    final localUserId = visible().first.id;
    final localReplyId = visible().last.id;
    chat
      ..created('u-srv', 'Hi there')
      ..text('a-srv', 'Hello');
    await _until(() => visible().last.id == 'a-srv');
    final notifier = container.read(chatMessagesProvider.notifier);
    check(notifier.currentMessageId(localUserId)).equals('u-srv');
    check(notifier.currentMessageId(localReplyId)).equals('a-srv');
    fake.addConversation(
      'conv-new',
      title: 'Greeting',
      messageList: [
        _message('u-srv', 'Hi there', user: true),
        _message('a-srv', 'Hello', user: false, parent: 'u-srv'),
      ],
    );
    chat.finish('a-srv', 'Hello');
    await send;
  });

  test('regenerate asks the server to answer the same message again', () async {
    await firstTurn('Hi there', 'Hello world');
    final regenerate = regenerateMessage(container, 'Hi there', null);
    await _until(() => chat.streams.length == 2);
    check(chat.starts.last)
      ..has((it) => it['isRegenerate'], 'isRegenerate').equals(true)
      ..has((it) => it['overrideParentMessageId'], 'override').equals('u-srv')
      ..has((it) => it['parentMessageId'], 'parent').equals(_root)
      ..has((it) => it['conversationId'], 'conversationId').equals('conv-new');
    final placeholder = visible().last;
    check(placeholder.isStreaming).isTrue();
    check(placeholder.versions.map((version) => version.content))
        .contains('Hello world');
    chat
      ..text('a3-srv', 'Hi again')
      ..finish('a3-srv', 'Hi again');
    await regenerate;
  });

  test('the server\'s title names the chat', () async {
    final send = sendMessageWithContainer(container, 'Hi there', null);
    await _until(() => chat.streams.isNotEmpty);
    chat.emit({
      'event': 'title',
      'data': {'conversationId': 'conv-new', 'title': 'Greeting'},
    });
    await _until(() => active()?.title == 'Greeting');
    chat.finish('a-srv', 'Hello');
    await send;
  });

  test('a deferred start is tried again as the same request', () async {
    chat.startAnswers.add(
      (body) => FakeLibreChatResponse(
        503,
        body: jsonEncode({'code': 'SERVER_NOT_READY'}),
        headers: {'retry-after': '3'},
      ),
    );
    final send = sendMessageWithContainer(container, 'Hi there', null);
    await _until(() => chat.streams.isNotEmpty);
    check(chat.starts).length.equals(2);
    check(chat.starts.first['clientRequestId'])
        .equals(chat.starts.last['clientRequestId']);
    check(sleeps).deepEquals([const Duration(seconds: 3)]);
    chat.finish('a-srv', 'Hello');
    await send;
  });

  test('a run carries on while another chat is open, and shows again on '
      'return', () async {
    final send = sendMessageWithContainer(container, 'Hi there', null);
    await _until(() => chat.streams.isNotEmpty);
    chat
      ..created('u-srv', 'Hi there')
      ..text('a-srv', 'Hello');
    await _until(() => shown().contains('Hello'));
    final chatWithRun = active()!;

    container.read(activeConversationProvider.notifier).set(null);
    await _until(() => visible().isEmpty);
    chat.text('a-srv', ' world');
    await pumpEventQueue();

    container.read(activeConversationProvider.notifier).set(chatWithRun);
    await _until(() => visible().any((message) => message.id == 'a-srv'));
    final reply = visible().firstWhere((message) => message.id == 'a-srv');
    check(reply.isStreaming).isTrue();
    check(reply.content).contains('Hello world');

    chat.finish('a-srv', 'Hello world');
    await send;
  });

  test('opening a chat whose reply is still running follows it', () async {
    fake
      ..addConversation(
        'conv-live',
        title: 'Live',
        messageList: [_message('u-live', 'Still going?', user: true)],
      )
      ..on(
        'GET',
        '/api/agents/chat/status/conv-live',
        (request, match) =>
            FakeLibreChatResponse.json({'active': true, 'createdAt': 77}),
      );
    final conversation = await container.read(
      loadConversationProvider('conv-live').future,
    );
    container.read(activeConversationProvider.notifier).set(conversation);
    await _until(() => chat.streams.isNotEmpty);
    final subscribe = fake.requests.lastWhere(
      (request) => request.path.contains('/chat/stream/'),
    );
    check(subscribe.path).endsWith('/conv-live');
    check(subscribe.uri.queryParameters['resume']).equals('true');
    chat.text('a-live', 'Yes');
    await _until(() => shown().contains('Yes'));
    check(visible().last.id).equals('a-live');
    check(container.read(libreChatActiveGenerationsProvider))
        .contains('conv-live');
    chat.finish('a-live', 'Yes');
    await _until(() => !visible().last.isStreaming);
    check(container.read(libreChatActiveGenerationsProvider)).isEmpty();
  });

  test('a refused start shows the server\'s reason', () async {
    chat.startAnswers.add(
      (body) => FakeLibreChatResponse.json({
        'message': 'You have hit your message limit.',
      }, statusCode: 403),
    );
    await sendMessageWithContainer(container, 'Hi there', null);
    await _until(() => !visible().last.isStreaming);
    check(chat.starts).length.equals(1);
    check(sleeps).isEmpty();
    check(visible().last.error?.content)
        .equals('You have hit your message limit.');
  });

  test('a reply that fails shows the server\'s words', () async {
    final send = sendMessageWithContainer(container, 'Hi there', null);
    await _until(() => chat.streams.isNotEmpty);
    chat.streams.last.add(
      Uint8List.fromList(
        utf8.encode(
          'event: error\ndata: ${jsonEncode({'error': 'Model unavailable'})}\n\n',
        ),
      ),
    );
    chat.end();
    await send;
    await _until(() => !visible().last.isStreaming);
    check(visible().last.error?.content).equals('Model unavailable');
  });

  test('a LibreChat chat branches on its own server, not Open WebUI', () async {
    await firstTurn('Hi there', 'Hello world');
    // Open WebUI's sibling controls stay off; the branch action is
    // LibreChat's fork, offered while the account can sync.
    check(container.read(chatBranchControlsProvider)).isFalse();
    // Online and not streaming: the fork is offered as it is.
    check(
      container.read(chatForkAvailabilityProvider),
    ).equals(ChatForkAvailability.available);
  });

  test('Open WebUI-only toggles are off for LibreChat models', () {
    check(container.read(webSearchAvailableProvider)).isFalse();
    check(container.read(imageGenerationAvailableProvider)).isFalse();
    check(container.read(comparisonRuntimeAvailableProvider)).isFalse();
    final model = container.read(selectedModelProvider) as Model;
    check(usesLibreChatTransportForRegeneration(null, model)).isTrue();
  });

  group('composer features', () {
    void scriptTools() {
      fake
        ..on(
          'GET',
          '/api/config',
          (request, match) => FakeLibreChatResponse.json({
            ...fake.startupConfig,
            'interface': {'webSearch': true, 'runCode': true},
          }),
        )
        ..on(
          'GET',
          '/api/endpoints',
          (request, match) => FakeLibreChatResponse.json({
            'Ollama': {'order': 1, 'type': 'custom'},
            'agents': {
              'capabilities': ['web_search', 'execute_code', 'file_search'],
            },
          }),
        )
        ..on(
          'GET',
          '/api/roles/(.+)',
          (request, match) => FakeLibreChatResponse.json({'permissions': {}}),
        )
        ..on(
          'GET',
          '/api/search/enable',
          (request, match) => FakeLibreChatResponse.json(false),
        )
        ..on(
          'GET',
          '/api/mcp/tools',
          (request, match) => FakeLibreChatResponse.json({
            'servers': {
              'everything': {
                'name': 'everything',
                'authenticated': true,
                'tools': [
                  {'name': 'echo'},
                ],
              },
              'github': {'name': 'github', 'authenticated': false},
            },
          }),
        )
        ..on(
          'GET',
          '/api/mcp/connection/status',
          (request, match) => FakeLibreChatResponse.json({
            'connectionStatus': {
              'everything': {'connectionState': 'connected'},
            },
          }),
        );
    }

    test('an endpoint model offers the server\'s tools', () async {
      scriptTools();
      final options = await container.read(
        libreChatComposerOptionsProvider.future,
      );
      check(options.webSearch).isTrue();
      check(options.codeInterpreter).isTrue();
      check(options.fileSearch).isTrue();
      check(options.mcpServers.map((server) => server.name)).unorderedEquals([
        'everything',
        'github',
      ]);
      check(
        options.mcpServers.singleWhere((s) => s.name == 'github'),
      ).has((it) => it.needsConnection, 'needsConnection').isTrue();
    });

    test('coming back from signing in to a server in the browser reads its '
        'connection again', () async {
      scriptTools();
      var options = await container.read(
        libreChatComposerOptionsProvider.future,
      );
      check(
        options.mcpServers.singleWhere((s) => s.name == 'github'),
      ).has((it) => it.needsConnection, 'needsConnection').isTrue();
      container.listen(libreChatComposerOptionsProvider, (_, _) {});

      fake.on(
        'GET',
        '/api/mcp/tools',
        (request, match) => FakeLibreChatResponse.json({
          'servers': {
            'github': {'name': 'github', 'authenticated': true},
          },
        }),
      );
      lifecycle.emit(AppLifecyclePhase.paused);
      lifecycle.emit(AppLifecyclePhase.resumed);
      await pumpEventQueue();
      options = await container.read(libreChatComposerOptionsProvider.future);
      check(
        options.mcpServers.singleWhere((s) => s.name == 'github'),
      ).has((it) => it.needsConnection, 'needsConnection').isFalse();
    });

    test('a turn sends its files and the tools chosen', () async {
      container.read(libreChatUploadedFilesProvider.notifier).record({
        'file_id': 'f1',
        'filepath': '/images/user1/f1.png',
        'filename': 'photo.png',
        'type': 'image/png',
        'width': 4,
        'height': 3,
      });
      container.read(selectedToolIdsProvider.notifier).set([
        kLibreChatWebSearchToolId,
        '${kLibreChatMcpToolIdPrefix}everything',
        'owui-tool',
      ]);
      final send = sendMessageWithContainer(container, 'Look', ['f1']);
      await _until(() => chat.starts.isNotEmpty);
      final body = chat.starts.single;
      check(body['files'] as List).deepEquals([
        {
          'file_id': 'f1',
          'filepath': '/images/user1/f1.png',
          'filename': 'photo.png',
          'type': 'image/png',
          'width': 4,
          'height': 3,
        },
      ]);
      check(body['ephemeralAgent'] as Map).deepEquals({
        'web_search': true,
        'execute_code': false,
        'file_search': false,
        'mcp': ['everything'],
      });
      final user = visible().firstWhere((m) => m.role == 'user');
      check(user.files!.single['url']).equals('/images/user1/f1.png');
      // The upload is spent once its turn has gone out.
      check(container.read(libreChatUploadedFilesProvider)).isEmpty();
      await _until(() => chat.streams.isNotEmpty);
      chat
        ..created('u-srv', 'Look')
        ..finish('a-srv', 'Nice');
      await send;
    });

    test('an edited message goes out again with its files', () async {
      container.read(libreChatUploadedFilesProvider.notifier).record({
        'file_id': 'f1',
        'filepath': '/images/user1/f1.png',
        'filename': 'photo.png',
        'type': 'image/png',
      });
      final send = sendMessageWithContainer(container, 'Look', ['f1']);
      await _until(() => chat.streams.isNotEmpty);
      chat
        ..created('u-srv', 'Look')
        ..finish('a-srv', 'Nice');
      await send;
      await _until(() => !visible().last.isStreaming);
      check(container.read(libreChatUploadedFilesProvider)).isEmpty();

      final user = visible().firstWhere((m) => m.role == 'user');
      final edit = resendEditedUserMessage(
        container,
        messageId: user.id,
        newText: 'Look closer',
      );
      await _until(() => chat.starts.length == 2);
      final files = chat.starts.last['files'] as List;
      check(files).length.equals(1);
      check((files.single as Map)['file_id']).equals('f1');
      check((files.single as Map)['filepath']).equals('/images/user1/f1.png');
      await _until(() => chat.streams.length == 2);
      chat
        ..created('u2-srv', 'Look closer')
        ..finish('a2-srv', 'Closer');
      await edit;
    });

    test('a file this session no longer holds stops the send', () async {
      Object? failure;
      try {
        await sendMessageWithContainer(container, 'Look', ['gone']);
      } catch (error) {
        failure = error;
      }
      check(failure).isNotNull();
      check(chat.starts).isEmpty();
    });

    test('a paused tool is approved through the paused turn\'s settings',
        () async {
      final resumes = <Map<String, dynamic>>[];
      fake.on('POST', '/api/agents/chat/resume', (request, match) {
        resumes.add(Map<String, dynamic>.from(request.data as Map));
        return FakeLibreChatResponse.json({'status': 'resumed'});
      });
      final send = sendMessageWithContainer(container, 'Echo hi', null);
      await _until(() => chat.streams.isNotEmpty);
      chat
        ..created('u-srv', 'Echo hi')
        ..emit({
          'event': 'on_pending_action',
          'data': {
            'actionId': 'act_1',
            'conversationId': 'conv-new',
            'payload': {
              'type': 'tool_approval',
              'action_requests': [
                {
                  'name': 'echo_mcp_everything',
                  'arguments': {'message': 'hi'},
                  'tool_call_id': 'call_echo',
                },
              ],
              'review_configs': [
                {
                  'tool_call_id': 'call_echo',
                  'allowed_decisions': ['approve', 'reject'],
                },
              ],
            },
          },
        });
      await _until(
        () => visible().last.metadata?[kLibreChatPendingActionKey] is Map,
      );
      final replyId = visible().last.id;
      final action = libreChatPendingActionFor(container, replyId)!;
      check(action.toolRequests.single.name).equals('echo_mcp_everything');

      await resolveLibreChatPendingAction(
        container,
        replyId,
        decisions: {
          'call_echo': const LibreChatToolDecisionInput(
            LibreChatToolDecision.approve,
          ),
        },
      );
      final body = resumes.single;
      check(body['actionId']).equals('act_1');
      check(body['endpoint']).equals('Ollama');
      check(body['model']).equals('llama3.2');
      check(body['generationCreatedAt']).equals(42);
      check(body.containsKey('text')).isFalse();
      check(body['decisions'] as List).deepEquals([
        {'tool_call_id': 'call_echo', 'decision': 'approve'},
      ]);
      check(
        visible().last.metadata?.containsKey(kLibreChatPendingActionKey),
      ).equals(false);
      check(libreChatPendingActionFor(container, replyId)).isNull();
      chat.finish('a-srv', 'hi');
      await send;
    });

    test('a question is answered as answer', () async {
      final resumes = <Map<String, dynamic>>[];
      fake.on('POST', '/api/agents/chat/resume', (request, match) {
        resumes.add(Map<String, dynamic>.from(request.data as Map));
        return FakeLibreChatResponse.json({'status': 'resumed'});
      });
      final send = sendMessageWithContainer(container, 'Plan a trip', null);
      await _until(() => chat.streams.isNotEmpty);
      chat.emit({
        'event': 'on_pending_action',
        'data': {
          'actionId': 'act_q',
          'payload': {
            'type': 'ask_user_question',
            'question': {'question': 'Which city?'},
            'tool_call_id': 'call_q',
          },
        },
      });
      await _until(
        () => visible().last.metadata?[kLibreChatPendingActionKey] is Map,
      );
      await resolveLibreChatPendingAction(
        container,
        visible().last.id,
        answers: {'call_q': 'Paris'},
      );
      check(resumes.single['answer']).equals('Paris');
      chat.finish('a-srv', 'Paris it is');
      await send;
    });

    test('an image loads with the live session cookie, renewing once when '
        'refused', () async {
      var refusals = 0;
      fake.on('GET', '/images/(.+)', (request, match) {
        // LibreChat checks the refresh cookie against the live session.
        final refresh = request.cookies['refreshToken'];
        if (refusals == 0 || !fake.refreshTokens.containsKey(refresh)) {
          refusals++;
          return FakeLibreChatResponse.json({
            'message': 'Unauthorized',
          }, statusCode: 401);
        }
        return FakeLibreChatResponse(
          200,
          contentType: 'image/png',
          stream: Stream<Uint8List>.value(Uint8List.fromList([137, 80, 78])),
        );
      });

      final fetch = container.read(libreChatImageFetcherProvider)!;
      check(await fetch('/images/user1/f1.png')).deepEquals([137, 80, 78]);
      check(refusals).equals(1);
      final loads = fake.requests
          .where((request) => request.path == '/images/user1/f1.png')
          .toList();
      check(loads).length.equals(2);
      check(
        loads.last.cookies['refreshToken'],
      ).not((it) => it.equals(loads.first.cookies['refreshToken']));
    });

    test('prompt groups become slash commands', () async {
      fake.on(
        'GET',
        '/api/roles/(.+)',
        (request, match) => FakeLibreChatResponse.json({'permissions': {}}),
      );
      fake.on(
        'GET',
        '/api/prompts/all',
        (request, match) => FakeLibreChatResponse.json([
          {
            '_id': 'g1',
            'name': 'Email Reply',
            'command': 'reply',
            'productionPrompt': {'prompt': 'Reply to {{sender}}'},
          },
        ]),
      );
      final prompts = await container.read(libreChatPromptsProvider.future);
      check(prompts.single.command).equals('/reply');
    });

    test('tool ids map to an ephemeral agent', () {
      check(
        libreChatToolSelectionFor([
          kLibreChatCodeToolId,
          kLibreChatFileSearchToolId,
          '${kLibreChatMcpToolIdPrefix}b',
          '${kLibreChatMcpToolIdPrefix}a',
        ]).toEphemeralAgent(),
      ).isNotNull().deepEquals({
        'web_search': false,
        'execute_code': true,
        'file_search': true,
        'mcp': ['a', 'b'],
      });
      check(isLibreChatToolId('owui-tool')).isFalse();
    });
  });
}
