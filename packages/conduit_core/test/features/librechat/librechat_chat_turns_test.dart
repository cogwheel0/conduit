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
import 'package:conduit_core/features/chat/services/historical_message_regeneration.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/features/librechat/providers/librechat_composer_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_transport.dart';
import 'package:conduit_core/features/librechat/providers/librechat_model_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_sync_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart'
    show accountChangeStopRepliesProvider;
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
import 'package:riverpod/misc.dart' show ProviderListenable;
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

/// A page's ref, which can no longer read once the page has closed.
final class _PageRef {
  _PageRef(this._container);

  final ProviderContainer _container;
  bool closed = false;

  T read<T>(ProviderListenable<T> provider) {
    if (closed) throw StateError('The page has closed.');
    return _container.read(provider);
  }
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

  test('a failed agents list fails the catalog; a refused one only drops '
      'agents', () async {
    fake.on(
      'GET',
      '/api/agents',
      (request, match) =>
          FakeLibreChatResponse.json({'message': 'Broken'}, statusCode: 500),
    );
    container
      ..invalidate(libreChatModelCatalogProvider)
      ..listen(libreChatModelCatalogProvider, (_, _) {});
    await _until(
      () => container.read(libreChatModelCatalogProvider).hasError,
    );

    fake.on(
      'GET',
      '/api/agents',
      (request, match) =>
          FakeLibreChatResponse.json({'message': 'Forbidden'}, statusCode: 403),
    );
    container.invalidate(libreChatModelCatalogProvider);
    await _until(() {
      final catalog = container.read(libreChatModelCatalogProvider);
      return catalog.hasValue && !catalog.isLoading && !catalog.hasError;
    });
    check(
      container.read(libreChatModelCatalogProvider).requireValue,
    ).isNotEmpty();
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

  test('a reply of the account just left never shows in another account\'s '
      'chat with the same id', () async {
    final send = sendMessageWithContainer(container, 'Write a lot', null);
    await _until(() => chat.streams.isNotEmpty);
    chat
      ..created('u-srv', 'Write a lot')
      ..text('a-srv', 'Once');
    await _until(() => shown().contains('Once'));
    final sameId = active()!;
    container.read(activeConversationProvider.notifier).set(null);
    await _until(() => visible().isEmpty);

    // Another user on the server signs in and takes over; a chat of theirs
    // has the same id (a copied server, say).
    final other = fake.addUser(email: 'other@example.com');
    final auth = LibreChatAuthService(server, adapter: fake);
    addTearDown(auth.close);
    final signedIn =
        await auth.signIn(email: other.email, password: other.password)
            as LibreChatSignedIn;
    await container
        .read(libreChatAccountsProvider)
        .saveSignedIn(server: server, session: signedIn.session);
    // Not the chat the other account named as it started its reply.
    await check(
      container.read(loadConversationProvider('conv-new').future),
    ).throws<Object>();
    container
        .read(activeConversationProvider.notifier)
        .set(sameId.copyWith(messages: const []));
    await pumpEventQueue();
    check(visible().map((message) => message.id)).not(
      (it) => it.contains('a-srv'),
    );

    chat.finish('a-srv', 'Once more');
    await send;
  });

  test('leaving the account stops replies in chats not open', () async {
    final send = sendMessageWithContainer(container, 'Write a lot', null);
    await _until(() => chat.streams.isNotEmpty);
    chat
      ..created('u-srv', 'Write a lot')
      ..text('a-srv', 'Once');
    await _until(() => shown().contains('Once'));
    // Another chat is opened; the reply runs on.
    container.read(activeConversationProvider.notifier).set(null);
    await _until(() => visible().isEmpty);

    container.read(accountChangeStopRepliesProvider)();
    await _until(() => chat.aborts.isNotEmpty);
    check(chat.aborts.single['conversationId']).equals('conv-new');
    await send;
  });

  test('another account\'s chat of the same id is followed while the old '
      'account\'s reply runs on', () async {
    final send = sendMessageWithContainer(container, 'Write a lot', null);
    await _until(() => chat.streams.isNotEmpty);
    chat
      ..created('u-srv', 'Write a lot')
      ..text('a-srv', 'Once');
    await _until(() => shown().contains('Once'));
    await send;

    // Another account, on a copy of the server, has a chat of the same id
    // whose reply is still being written.
    container.read(activeConversationProvider.notifier).set(null);
    const copy = LibreChatServer(baseUrl: 'https://copy.example.com');
    final auth = LibreChatAuthService(copy, adapter: fake);
    final signedIn = await auth.signIn(
      email: 'dev@example.com',
      password: 'devpassword',
    ) as LibreChatSignedIn;
    auth.close();
    await container
        .read(libreChatAccountsProvider)
        .saveSignedIn(server: copy, session: signedIn.session);
    await container.read(libreChatSessionProvider.future);
    fake
      ..addConversation(
        'conv-new',
        title: 'Copied',
        messageList: [_message('u-copy', 'Still going?', user: true)],
      )
      ..on(
        'GET',
        '/api/agents/chat/status/conv-new',
        (request, match) =>
            FakeLibreChatResponse.json({'active': true, 'createdAt': 77}),
      );
    final conversation = await container.read(
      loadConversationProvider('conv-new').future,
    );
    container.read(activeConversationProvider.notifier).set(conversation);

    // Its reply is followed, though the first account's has not ended.
    await _until(() => chat.streams.length == 2);
    chat.text('a-copy', 'Yes');
    await _until(() => shown().contains('Yes'));
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

  test('a tool cut short by a stop stops showing as running', () async {
    stopFallback = const Duration(milliseconds: 20);
    fake.on(
      'POST',
      '/api/agents/chat/abort',
      (request, match) => Completer<FakeLibreChatResponse>().future,
    );
    final send = sendMessageWithContainer(container, 'Weather?', null);
    await _until(() => chat.streams.isNotEmpty);
    chat
      ..created('u-srv', 'Weather?')
      ..text('a-srv', 'Checking')
      ..emit({
        'event': 'on_run_step',
        'data': {
          'id': 'step-tool',
          'runId': 'a-srv',
          'index': 1,
          'stepDetails': {
            'type': 'tool_calls',
            'tool_calls': [
              {'id': 'call_1', 'name': 'get_weather', 'args': ''},
            ],
          },
        },
      });
    await _until(() => shown().contains('get_weather'));
    check(shown()).contains('status="in_progress"');

    container.read(stopGenerationProvider)();
    await send;
    await _until(() => !visible().last.isStreaming);
    check(visible().last.content)
      ..contains('done="true"')
      ..not((it) => it.contains('status="in_progress"'));
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
    chat.text('a3-srv', 'Hi again');
    await _until(() => shown().contains('Hi again'));

    // Back in the chat while the new answer runs: the old one shows only
    // among its versions.
    final chatWithRun = active()!;
    container.read(activeConversationProvider.notifier).set(null);
    await _until(() => visible().isEmpty);
    container.read(activeConversationProvider.notifier).set(chatWithRun);
    await _until(() => visible().any((message) => message.id == 'a3-srv'));
    check(visible().map((message) => message.id)).deepEquals([
      'u-srv',
      'a3-srv',
    ]);
    check(visible().first.metadata?['childrenIds'])
        .isA<List<Object?>>()
        .deepEquals(['a3-srv']);

    chat.finish('a3-srv', 'Hi again');
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
    // The chat was named before the server named its messages: each shows
    // once, under the server's id.
    check(visible().map((message) => message.id)).deepEquals([
      'u-srv',
      'a-srv',
    ]);
    check(
      visible().first.metadata?['childrenIds'],
    ).isA<List<Object?>>().deepEquals(['a-srv']);

    chat.finish('a-srv', 'Hello world');
    await send;
  });

  test('a new chat reopens from history while its first reply runs',
      () async {
    final send = sendMessageWithContainer(container, 'Hi there', null);
    await _until(() => chat.streams.isNotEmpty);
    chat
      ..created('u-srv', 'Hi there')
      ..text('a-srv', 'Hello');
    await _until(() => shown().contains('Hello'));
    container.read(activeConversationProvider.notifier).set(null);
    await _until(() => visible().isEmpty);

    // Listed, but with no messages saved and none to pull while it runs.
    final reopened = await container.read(
      loadConversationProvider('conv-new').future,
    );
    container.read(activeConversationProvider.notifier).set(reopened);
    await _until(() => visible().any((message) => message.id == 'a-srv'));
    check(visible().map((message) => message.id)).deepEquals([
      'u-srv',
      'a-srv',
    ]);
    check(visible().last.isStreaming).isTrue();

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

  test('regenerating an earlier reply while a reopened chat\'s reply runs '
      'is refused before the transcript changes', () async {
    fake
      ..addConversation(
        'conv-live',
        title: 'Live',
        messageList: [
          _message('u-old', 'Hi', user: true),
          _message('a-old', 'Hello', user: false, parent: 'u-old'),
          _message('u-live', 'Still going?', user: true, parent: 'a-old'),
        ],
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
    // Followed, before its reply shows anything.
    await _until(() => chat.streams.isNotEmpty);
    final before = [for (final message in visible()) message.id];

    await check(
      regenerateHistoricalMessageById(container, 'a-old'),
    ).throws<LibreChatReplyRunningException>();
    check([for (final message in visible()) message.id]).deepEquals(before);
    // The latest reply, answered again, is refused as well.
    await check(
      regenerateMessage(container, 'Still going?', null),
    ).throws<LibreChatReplyRunningException>();
    check([for (final message in visible()) message.id]).deepEquals(before);
    check(chat.starts).isEmpty();

    chat.finish('a-live', 'Yes');
    await _until(() => visible().any((message) => message.id == 'a-live'));
  });

  test('stopping a followed reply names its generation', () async {
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
    chat.text('a-live', 'Yes');
    await _until(() => shown().contains('Yes'));

    // Another device may have started a newer reply since: only this one
    // is stopped.
    container.read(stopGenerationProvider)();
    await _until(() => chat.aborts.isNotEmpty);
    check(chat.aborts.single['generationCreatedAt']).equals(77);
    await _until(() => !visible().last.isStreaming);
  });

  test('a chat already open when the messages are first read follows its '
      'running reply', () async {
    var statusChecks = 0;
    fake
      ..addConversation(
        'conv-live',
        title: 'Live',
        messageList: [_message('u-live', 'Still going?', user: true)],
      )
      ..on('GET', '/api/agents/chat/status/conv-live', (request, match) {
        statusChecks += 1;
        // Idle when the rig's messages see the chat open; running by the
        // time messages built afterwards read it.
        return FakeLibreChatResponse.json(
          statusChecks == 1
              ? {'active': false}
              : {'active': true, 'createdAt': 77},
        );
      });
    final conversation = await container.read(
      loadConversationProvider('conv-live').future,
    );
    container.read(activeConversationProvider.notifier).set(conversation);
    await _until(() => statusChecks == 1);
    // Messages first built with the chat already open, as on a start that
    // restores it, see no change of chat to react to.
    final later = NotifierProvider<ChatMessagesNotifier, List<ChatMessage>>(
      ChatMessagesNotifier.new,
    );
    container.listen(later, (_, _) {});
    await _until(() => chat.streams.isNotEmpty);
    chat.text('a-live', 'Yes');
    await _until(() => shown().contains('Yes'));
    check(visible().last.id).equals('a-live');
    chat.finish('a-live', 'Yes');
    await _until(() => !visible().last.isStreaming);
  });

  test('a running reply already in the history streams in its own row',
      () async {
    fake
      ..addConversation(
        'conv-live',
        title: 'Live',
        messageList: [
          _message('u-live', 'Still going?', user: true),
          _message('a-live', 'Partial', user: false, parent: 'u-live'),
        ],
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
    // The resumed stream names the user message, which shows the reply
    // under a placeholder until the server names it too, then starts the
    // reply over.
    chat
      ..created('u-live', 'Still going?')
      ..text('a-live', 'Partial answer');
    await _until(() => shown().contains('Partial answer'));
    check(visible().map((message) => message.id)).deepEquals([
      'u-live',
      'a-live',
    ]);
    check(visible().last.isStreaming).isTrue();
    check(shown()).not((it) => it.contains('PartialPartial'));

    // A reconnect resumes again and names the same user message; leaving
    // and reopening the chat keeps the question above its running reply.
    chat.created('u-live', 'Still going?');
    await pumpEventQueue();
    container.read(activeConversationProvider.notifier).set(null);
    await _until(() => visible().isEmpty);
    container.read(activeConversationProvider.notifier).set(conversation);
    await _until(() => visible().any((message) => message.id == 'a-live'));
    check(visible().map((message) => message.id)).deepEquals([
      'u-live',
      'a-live',
    ]);
    check(visible().last.isStreaming).isTrue();
    chat.finish('a-live', 'Partial answer, done');
    await _until(() => !visible().last.isStreaming);
    check(visible().last.content).equals('Partial answer, done');
  });

  test('a refused start shows the server\'s reason', () async {
    chat.startAnswers.add(
      (body) => FakeLibreChatResponse.json({
        'message': 'You have hit your message limit.',
      }, statusCode: 403),
    );
    // The send fails, so the composer keeps the message to send again.
    await check(
      sendMessageWithContainer(container, 'Hi there', null),
    ).throws<LibreChatApiException>();
    await _until(() => !visible().last.isStreaming);
    check(chat.starts).length.equals(1);
    check(sleeps).isEmpty();
    check(visible().last.error?.content)
        .equals('You have hit your message limit.');
  });

  test('a send is done once the server takes the turn, while the reply '
      'runs on', () async {
    var sent = false;
    final send = sendMessageWithContainer(
      container,
      'Hi there',
      null,
    ).then((_) => sent = true);
    await _until(() => chat.streams.isNotEmpty);
    await _until(() => sent);
    check(visible().last.isStreaming).isTrue();
    check(container.read(libreChatActiveGenerationsProvider))
        .contains('conv-new');
    chat
      ..created('u-srv', 'Hi there')
      ..finish('a-srv', 'Hello');
    await send;
    await _until(() => !visible().last.isStreaming);
  });

  test('regenerating a message the server never took sends it again as a '
      'new chat', () async {
    chat.startAnswers.add(
      (body) => FakeLibreChatResponse.json({
        'message': 'You have hit your message limit.',
      }, statusCode: 403),
    );
    await check(
      sendMessageWithContainer(container, 'Hi there', null),
    ).throws<LibreChatApiException>();
    await _until(() => !visible().last.isStreaming);

    await regenerateMessage(container, 'Hi there', null);
    check(chat.starts).length.equals(2);
    check(chat.starts.last)
      ..has((it) => it['isRegenerate'], 'isRegenerate').isNull()
      ..has((it) => it['overrideParentMessageId'], 'override').isNull()
      ..has((it) => it['conversationId'], 'conversationId').isNull()
      ..has((it) => it['parentMessageId'], 'parent').equals(_root)
      ..has((it) => it['text'], 'text').equals('Hi there');
    check(chat.starts.last['clientRequestId'])
        .not((it) => it.equals(chat.starts.first['clientRequestId']));
    // The new turn takes the failed one's place.
    check(visible().map((message) => message.role))
        .deepEquals(['user', 'assistant']);
    check(visible().last.error).isNull();
    await _until(() => chat.streams.isNotEmpty);
    chat
      ..created('u-srv', 'Hi there')
      ..finish('a-srv', 'Hello');
    await _until(() => !visible().last.isStreaming);
    check(visible().map((message) => message.id))
        .deepEquals(['u-srv', 'a-srv']);
  });

  test('regenerating a follow-up the server never took sends it again after '
      'the last message it has', () async {
    await firstTurn('Hi there', 'Hello world');
    chat.startAnswers.add(
      (body) => FakeLibreChatResponse.json({
        'message': 'You have hit your message limit.',
      }, statusCode: 403),
    );
    await check(
      sendMessageWithContainer(container, 'And you?', null),
    ).throws<LibreChatApiException>();
    await _until(() => !visible().last.isStreaming);

    await regenerateMessage(container, 'And you?', null);
    check(chat.starts.last)
      ..has((it) => it['isRegenerate'], 'isRegenerate').isNull()
      ..has((it) => it['overrideParentMessageId'], 'override').isNull()
      ..has((it) => it['conversationId'], 'conversationId').equals('conv-new')
      ..has((it) => it['parentMessageId'], 'parent').equals('a-srv')
      ..has((it) => it['text'], 'text').equals('And you?');
    check(visible()).length.equals(4);
    check(
      visible()[1].metadata?['childrenIds'],
    ).isA<List<Object?>>().deepEquals([visible()[2].id]);
    await _until(() => chat.streams.length == 2);
    chat
      ..created('u2-srv', 'And you?', parent: 'a-srv')
      ..finish('a2-srv', 'Fine');
    await _until(() => !visible().last.isStreaming);
  });

  test('a second send while a reply runs is refused before anything is '
      'written', () async {
    await firstTurn('Hi there', 'Hello world');
    final running = sendMessageWithContainer(container, 'And you?', null);
    await _until(() => chat.streams.length == 2);
    final rows = visible().length;

    // A shortcut or the expanded editor sends again while it runs.
    await check(
      sendMessageWithContainer(container, 'Again?', null),
    ).throws<LibreChatReplyRunningException>();
    check(chat.starts).length.equals(2);
    check(visible()).length.equals(rows);

    chat
      ..created('u2-srv', 'And you?', parent: 'a-srv')
      ..finish('a2-srv', 'Fine');
    await running;
    await _until(() => !visible().last.isStreaming);
  });

  test('an edit while a reply runs is refused before the transcript changes',
      () async {
    await firstTurn('Hi there', 'Hello world');
    final running = sendMessageWithContainer(container, 'And you?', null);
    await _until(() => chat.streams.length == 2);
    final before = [for (final message in visible()) message.id];

    await check(
      resendEditedUserMessage(
        container,
        messageId: visible().first.id,
        newText: 'Hi again',
      ),
    ).throws<LibreChatReplyRunningException>();
    check([for (final message in visible()) message.id]).deepEquals(before);
    check(chat.starts).length.equals(2);

    chat
      ..created('u2-srv', 'And you?', parent: 'a-srv')
      ..finish('a2-srv', 'Fine');
    await running;
    await _until(() => !visible().last.isStreaming);
  });

  test('a second send while a new chat is still starting is refused',
      () async {
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
    final rows = visible().length;

    // The server has not named the chat yet: the draft sends again.
    await check(
      sendMessageWithContainer(container, 'Again?', null),
    ).throws<LibreChatReplyRunningException>();
    check(chat.starts).length.equals(1);
    check(visible()).length.equals(rows);

    started.complete();
    await _until(() => chat.streams.isNotEmpty);
    chat
      ..created('u-srv', 'First draft')
      ..finish('a-srv', 'Hello');
    await send;
  });

  test('a send while a chat is still opening does not start a new one',
      () async {
    container.read(isLoadingConversationProvider.notifier).set(true);
    await check(sendMessageWithContainer(container, 'Hi there', null))
        .throws<StateError>();
    check(chat.starts).isEmpty();
    check(visible()).isEmpty();
  });

  test('a new chat is not sent while temporary chat is on; a saved one '
      'carries on', () async {
    container.read(temporaryChatEnabledProvider.notifier).set(true);
    await check(
      sendMessageWithContainer(container, 'Hi there', null),
    ).throws<LibreChatTemporaryChatException>();
    check(chat.starts).isEmpty();
    check(visible()).isEmpty();

    container.read(temporaryChatEnabledProvider.notifier).set(false);
    await firstTurn('Hi there', 'Hello world');
    container.read(temporaryChatEnabledProvider.notifier).set(true);
    final send = sendMessageWithContainer(container, 'And you?', null);
    await _until(() => chat.streams.length == 2);
    check(chat.starts.last['conversationId']).equals('conv-new');
    chat
      ..created('u2-srv', 'And you?', parent: 'a-srv')
      ..finish('a2-srv', 'Fine');
    await send;
  });

  test('a LibreChat model does not regenerate in another backend\'s chat',
      () async {
    final now = DateTime(2026, 10, 18);
    container
        .read(activeConversationProvider.notifier)
        .set(
          Conversation(
            id: 'owui-chat',
            title: 'Elsewhere',
            createdAt: now,
            updatedAt: now,
          ),
        );
    container.read(chatMessagesProvider.notifier).setMessages([
      ChatMessage(id: 'u1', role: 'user', content: 'Hi', timestamp: now),
      ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'Hello',
        timestamp: now,
      ),
    ]);
    await check(regenerateMessage(container, 'Hi', null)).throws<StateError>(
      (it) => it
          .has((error) => error.message, 'message')
          .equals('A LibreChat model can only continue a LibreChat chat.'),
    );
    check(chat.starts).isEmpty();
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

    test('an MCP server is ready by its connection, as LibreChat reads it',
        () {
      const userVariables = {
        'authenticated': false,
        'authConfig': [
          {'authField': 'API_KEY'},
        ],
      };
      // Per-user variables saved and connected, though the listing says
      // otherwise.
      check(
        libreChatMcpServerNeedsConnection(userVariables, {
          'connectionState': 'connected',
        }),
      ).isFalse();
      check(
        libreChatMcpServerNeedsConnection(userVariables, {
          'connectionState': 'disconnected',
        }),
      ).isTrue();
      // Connected per request: ready once its variables are saved.
      check(
        libreChatMcpServerNeedsConnection(userVariables, {
          'connectionState': 'disconnected',
          'requestScoped': true,
          'configurationState': 'configured',
          'authorizationState': 'not_required',
        }),
      ).isFalse();
      check(
        libreChatMcpServerNeedsConnection(userVariables, {
          'connectionState': 'disconnected',
          'requestScoped': true,
          'configurationState': 'needs_configuration',
        }),
      ).isTrue();
      // OAuth not signed in to; signed in.
      check(
        libreChatMcpServerNeedsConnection(const {'authenticated': true}, {
          'connectionState': 'disconnected',
          'requiresOAuth': true,
        }),
      ).isTrue();
      check(
        libreChatMcpServerNeedsConnection(const {'authenticated': true}, {
          'connectionState': 'connected',
          'requiresOAuth': true,
        }),
      ).isFalse();
      // Asked to sign in again; nothing but the listing to go by.
      check(
        libreChatMcpServerNeedsConnection(const {
          'authenticated': false,
          'authorizationState': 'reauth_required',
        }, {'connectionState': 'connected'}),
      ).isTrue();
      check(
        libreChatMcpServerNeedsConnection(const {'authenticated': false}, null),
      ).isTrue();
      check(
        libreChatMcpServerNeedsConnection(const {'authenticated': true}, null),
      ).isFalse();
    });

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

    test('servers chat cannot pick are not offered', () async {
      scriptTools();
      fake.on(
        'GET',
        '/api/mcp/servers',
        (request, match) => FakeLibreChatResponse.json({
          'everything': {'title': 'Everything'},
          // Hidden from chat by the admin, and reached only through an
          // agent: LibreChat drops both from a turn's tools.
          'github': {'chatMenu': false},
          'calendar': {'consumeOnly': true},
        }),
      );
      fake.on(
        'GET',
        '/api/mcp/tools',
        (request, match) => FakeLibreChatResponse.json({
          'servers': {
            for (final name in ['everything', 'github', 'calendar'])
              name: {'name': name, 'authenticated': true},
          },
        }),
      );
      final options = await container.read(
        libreChatComposerOptionsProvider.future,
      );
      check(
        options.mcpServers.map((server) => server.name),
      ).deepEquals(['everything']);
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
      // The send's own tools, not those of the composer's unsent draft.
      container.read(selectedToolIdsProvider.notifier).set([
        kLibreChatCodeToolId,
      ]);
      final send = sendMessageWithContainer(container, 'Look', ['f1'], [
        kLibreChatWebSearchToolId,
        '${kLibreChatMcpToolIdPrefix}everything',
        'owui-tool',
      ]);
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
      await _until(() => chat.streams.isNotEmpty);
      // The upload is spent once the server has its turn.
      await send;
      check(container.read(libreChatUploadedFilesProvider)).isEmpty();
      chat
        ..created('u-srv', 'Look')
        ..finish('a-srv', 'Nice');
      await send;
    });

    test('a send without tools takes none from the composer', () async {
      container.read(selectedToolIdsProvider.notifier).set([
        kLibreChatWebSearchToolId,
        '${kLibreChatMcpToolIdPrefix}everything',
      ]);
      final send = sendMessageWithContainer(container, 'Thanks', null);
      await _until(() => chat.starts.isNotEmpty);
      check(chat.starts.single.containsKey('ephemeralAgent')).isFalse();
      await _until(() => chat.streams.isNotEmpty);
      chat
        ..created('u-srv', 'Thanks')
        ..finish('a-srv', 'Welcome');
      await send;
      await _until(() => !visible().last.isStreaming);
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

    test('a refused start keeps its files for the draft sent again', () async {
      container.read(libreChatUploadedFilesProvider.notifier).record({
        'file_id': 'f1',
        'filepath': '/images/user1/f1.png',
        'filename': 'photo.png',
        'type': 'image/png',
      });
      chat.startAnswers.add(
        (body) => FakeLibreChatResponse.json({
          'message': 'You have hit your message limit.',
        }, statusCode: 403),
      );
      await check(
        sendMessageWithContainer(container, 'Look', ['f1']),
      ).throws<LibreChatApiException>();
      check(container.read(libreChatUploadedFilesProvider).keys)
          .deepEquals(['f1']);

      // Answering it again sends it as a new turn, with its file.
      await regenerateMessage(container, 'Look', null);
      check(chat.starts).length.equals(2);
      check(chat.starts.last['isRegenerate']).isNull();
      check(
        ((chat.starts.last['files'] as List).single as Map)['file_id'],
      ).equals('f1');
      await _until(() => chat.streams.isNotEmpty);
      chat
        ..created('u-srv', 'Look')
        ..finish('a-srv', 'Nice');
      await _until(() => !visible().last.isStreaming);
    });

    test('regenerating answers again with the message\'s files and the tools '
        'chosen', () async {
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

      container.read(selectedToolIdsProvider.notifier).set([
        kLibreChatWebSearchToolId,
      ]);
      await regenerateMessage(container, 'Look', null);
      final body = chat.starts.last;
      check(body['isRegenerate']).equals(true);
      check(body['overrideParentMessageId']).equals('u-srv');
      final file = (body['files'] as List).single as Map;
      check(file['file_id']).equals('f1');
      check(file['filepath']).equals('/images/user1/f1.png');
      check((body['ephemeralAgent'] as Map)['web_search']).equals(true);
      await _until(() => chat.streams.length == 2);
      chat
        ..text('a2-srv', 'Nicer')
        ..finish('a2-srv', 'Nicer');
      await _until(() => !visible().last.isStreaming);
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

    test('a second answer to a pause while the first goes out joins it',
        () async {
      final resumes = <Map<String, dynamic>>[];
      final answered = Completer<void>();
      fake.on('POST', '/api/agents/chat/resume', (request, match) async {
        resumes.add(Map<String, dynamic>.from(request.data as Map));
        await answered.future;
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
      final replyId = visible().last.id;

      final first = resolveLibreChatPendingAction(
        container,
        replyId,
        answers: {'call_q': 'Paris'},
      );
      await _until(() => resumes.isNotEmpty);
      // The chat opened again shows the card again, answered again.
      final second = resolveLibreChatPendingAction(
        container,
        replyId,
        answers: {'call_q': 'Paris'},
      );
      answered.complete();
      await Future.wait([first, second]);
      check(resumes).length.equals(1);
      check(libreChatPendingActionFor(container, replyId)).isNull();
      chat.finish('a-srv', 'Paris it is');
      await send;
    });

    test('an answer clears its question though a reconnect reported it '
        'again meanwhile', () async {
      final answered = Completer<void>();
      fake.on('POST', '/api/agents/chat/resume', (request, match) async {
        await answered.future;
        return FakeLibreChatResponse.json({'status': 'resumed'});
      });
      final send = sendMessageWithContainer(container, 'Plan a trip', null);
      await _until(() => chat.streams.isNotEmpty);
      final pause = <String, dynamic>{
        'actionId': 'act_q',
        'payload': {
          'type': 'ask_user_question',
          'question': {'question': 'Which city?'},
          'tool_call_id': 'call_q',
        },
      };
      chat.emit({'event': 'on_pending_action', 'data': pause});
      await _until(
        () => visible().last.metadata?[kLibreChatPendingActionKey] is Map,
      );
      final replyId = visible().last.id;
      final answer = resolveLibreChatPendingAction(
        container,
        replyId,
        answers: {'call_q': 'Paris'},
      );

      // The stream drops while the answer goes out, and its snapshot still
      // has the pause, the server not having taken the answer yet.
      chat.end();
      await _until(() => chat.streams.length == 2);
      chat.emit({
        'sync': true,
        'resumeState': {'responseMessageId': 'a-srv', 'pendingAction': pause},
        'pendingEvents': <Object>[],
      });
      await pumpEventQueue();
      answered.complete();
      await answer;

      check(libreChatPendingActionFor(container, replyId)).isNull();
      check(
        visible().last.metadata?.containsKey(kLibreChatPendingActionKey),
      ).equals(false);
      chat.finish('a-srv', 'Paris it is');
      await send;
    });

    test('an answer clears the question even when its page closed while '
        'it went out', () async {
      final page = _PageRef(container);
      fake.on('POST', '/api/agents/chat/resume', (request, match) {
        page.closed = true;
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
        page,
        visible().last.id,
        answers: {'call_q': 'Paris'},
      );
      check(
        visible().last.metadata?.containsKey(kLibreChatPendingActionKey),
      ).equals(false);
      chat.finish('a-srv', 'Paris it is');
      await send;
    });

    test('a pause reported before the saved reply is adopted keeps its '
        'card', () async {
      final send = sendMessageWithContainer(container, 'Plan a trip', null);
      await _until(() => chat.streams.isNotEmpty);
      chat
        ..created('u-srv', 'Plan a trip')
        ..emit({
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
      // The history the chat opened with already shows the reply.
      container.read(chatMessagesProvider.notifier).setMessages([
        ...container.read(chatMessagesProvider),
        ChatMessage(
          id: 'a-srv',
          role: 'assistant',
          content: '',
          timestamp: DateTime.utc(2026, 10, 18),
        ),
      ]);
      chat.text('a-srv', 'Which city');
      await _until(() => visible().any((message) => message.id == 'a-srv'));
      await pumpEventQueue();

      final adopted = visible().singleWhere(
        (message) => message.id == 'a-srv',
      );
      check(adopted.metadata?[kLibreChatPendingActionKey]).isA<Map>();
      check(libreChatPendingActionFor(container, 'a-srv')).isNotNull();
      chat.finish('a-srv', 'Paris it is');
      await send;
    });

    test('a pause answered elsewhere while the stream was away loses its '
        'card', () async {
      final send = sendMessageWithContainer(container, 'Plan a trip', null);
      await _until(() => chat.streams.isNotEmpty);
      chat
        ..created('u-srv', 'Plan a trip')
        ..emit({
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

      // The stream drops, and the question is answered in LibreChat's web
      // app meanwhile: the snapshot it comes back with has no pause.
      chat.end();
      await _until(() => chat.streams.length == 2);
      chat.emit({
        'sync': true,
        'resumeState': {
          'responseMessageId': 'a-srv',
          'aggregatedContent': [
            {'type': 'text', 'text': 'Paris, then'},
          ],
        },
        'pendingEvents': <Object>[],
      });
      await _until(() => shown().contains('Paris, then'));
      check(
        visible().last.metadata?.containsKey(kLibreChatPendingActionKey),
      ).equals(false);
      check(libreChatPendingActionFor(container, visible().last.id)).isNull();
      chat.finish('a-srv', 'Paris it is');
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
