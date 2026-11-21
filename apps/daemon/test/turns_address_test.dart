@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show appDatabaseProvider, openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart'
    show kDirectTransport;
import 'package:conduit_core/features/librechat/models/librechat_transport.dart';
import 'package:conduit_core/features/librechat/providers/librechat_model_providers.dart'
    show libreChatModelCatalogProvider;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/settled.dart' show readSettled;
import 'package:test/test.dart';

import 'support/fake_librechat_chat.dart';
import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';
import 'support/step_clock.dart';

/// The answers an address change waits for or stops: the Open WebUI ones,
/// which arrive through the active account's address.
void main() {
  final openWebUi = ChatCompletionTransport.taskSocket.name;
  final answers =
      <
        ({
          String name,
          bool running,
          bool sending,
          Object? transport,
          bool counts,
        })
      >[
        (
          name: 'a running Open WebUI answer',
          running: true,
          sending: false,
          transport: openWebUi,
          counts: true,
        ),
        (
          name: 'an Open WebUI send admitted, its answer not yet there',
          running: false,
          sending: true,
          transport: null,
          counts: true,
        ),
        (
          name: 'a running LibreChat answer',
          running: true,
          sending: false,
          transport: kLibreChatTransport,
          counts: false,
        ),
        (
          name: 'a running direct answer',
          running: true,
          sending: false,
          transport: kDirectTransport,
          counts: false,
        ),
      ];
  for (final answer in answers) {
    test('${answer.name} ${answer.counts ? 'counts' : 'does not count'}', () {
      expect(
        answersThroughAddress(
          running: answer.running,
          sending: answer.sending,
          transport: answer.transport,
        ),
        answer.counts,
      );
    });
  }

  test('a LibreChat regenerate not yet started does not count: its send '
      'names no answer, and the one streaming at the end is LibreChat\'s', () {
    final asked = ChatMessage(
      id: 'question',
      role: 'user',
      content: 'Name a kitchen tool.',
      timestamp: DateTime.utc(2026, 11, 20),
    );
    final before = ChatMessage(
      id: 'answer',
      role: 'assistant',
      content: 'A whisk.',
      timestamp: DateTime.utc(2026, 11, 20),
      metadata: const {'transport': kLibreChatTransport},
    );
    // The regenerate streams into the answer it replaces.
    final again = before.copyWith(content: '', isStreaming: true);
    final answer = sentAnswerAtTail(
      [asked, again],
      before: {before.id: before},
      settled: false,
    );
    expect(answer?.id, 'answer');
    expect(
      answersThroughAddress(
        running: false,
        sending: true,
        transport: answer?.metadata?['transport'],
      ),
      isFalse,
    );
  });

  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late EventBus events;
  late AccountsService accounts;
  late String openWebUiAccount;
  late TurnsService turns;
  late StepClock clock;

  /// A fake Open WebUI reporting [version], signed in to with its user
  /// bound, and the turns service on a clock of the test's own.
  Future<void> signIn({String version = '0.13.1'}) async {
    final temporary = Directory.systemTemp.createTempSync('turns-address');
    addTearDown(() => temporary.deleteSync(recursive: true));
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    addTearDown(runtime.dispose);
    owui =
        await FakeOwuiAuthServer.start(
            users: const {
              'ada@example.com': (
                id: 'user-ada',
                name: 'Ada',
                password: 'pw-ada',
              ),
            },
          )
          ..models = const ['kettle-model']
          ..version = version;
    addTearDown(owui.close);
    events = EventBus();
    accounts = AccountsService(runtime.container, events: events);
    addTearDown(accounts.dispose);
    final auth = AuthService(runtime.container);
    addTearDown(auth.dispose);
    final added = await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Lab', url: owui.url),
        force: true,
      ),
    );
    final accountId = openWebUiAccount = added.accounts.activeAccountId!;
    await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    await runtime.container.read(activeServerProvider.future);
    // Chats already on the server are opened as the account's once its user
    // is bound. Certification starts that bind right after it is announced,
    // queued on storage's lock: a registry read made after the
    // announcement's own work (a microtask) is queued behind it.
    final storage = runtime.container.read(optimizedStorageServiceProvider);
    final bound = Completer<void>();
    final watch = runtime.container.listen<Object?>(
      openWebUiCertifiedDatabaseServerProvider,
      (_, _) => Future<void>.microtask(() async {
        final registry = await storage.getOpenWebUiRegistryStrict();
        if (registry.account(accountId)?.userId != null && !bound.isCompleted) {
          bound.complete();
        }
      }),
      fireImmediately: true,
    );
    addTearDown(watch.close);
    await bound.future;
    clock = StepClock();
    turns = TurnsService(
      runtime.container,
      events,
      now: clock.now,
      pause: clock.pause,
    );
    addTearDown(turns.dispose);
  }

  /// A send into a chat already on the server, held at its [nth] read of
  /// the account's settings: admission reads them twice (0 and 1), then the
  /// outbox reads them as it prepares the request (2), after the chat's
  /// update has gone out.
  Future<Future<SendTurnAccepted>> heldPreparing(
    int nth, {
    String chatId = 'chat-kitchen',
  }) async {
    owui.chats.seed(chatId, userId: 'user-ada');
    owui
      ..settingsAsked = Completer<void>()
      ..settingsToPass = nth
      ..holdSettings = Completer<void>();
    final held = turns.send(
      SendTurn(chatId: chatId, model: 'kettle-model', text: 'Milk?'),
    )..ignore();
    await clock.during(owui.settingsAsked.future);
    expect(turns.addressAnswering, isTrue);
    return held;
  }

  group('against a fake Open WebUI', () {
    setUp(signIn);

    /// Two chats already on the server: one answering, held after its
    /// first word, and the other's send taken by the server with its reply
    /// held (as Open WebUI holds it until the whole reply is written, with
    /// no socket to send it on). Returns the answering chat's id and the
    /// held send.
    Future<({String answering, Future<SendTurnAccepted> held})>
    answeringAndHeld() async {
      final chats = owui.chats
        ..seed('chat-garden', userId: 'user-ada')
        ..seed('chat-kitchen', userId: 'user-ada')
        ..holdStream = Completer<void>();
      final answering = await clock.during(
        turns.send(
          const SendTurn(
            chatId: 'chat-garden',
            model: 'kettle-model',
            text: 'Water the beans',
          ),
        ),
      );
      expect(turns.isRunning(answering.chatId), isTrue);
      chats
        ..admissionAsked = Completer<void>()
        ..holdAdmission = Completer<void>();
      final held = turns.send(
        const SendTurn(
          chatId: 'chat-kitchen',
          model: 'kettle-model',
          text: 'Milk?',
        ),
      )..ignore();
      await clock.during(chats.admissionAsked.future);
      expect(turns.addressAnswering, isTrue);
      return (answering: answering.chatId, held: held);
    }

    test('an address change stops the answers through it while a send\'s '
        'reply is still held: the send is dropped, not waited out', () async {
      final (:answering, :held) = await answeringAndHeld();

      await clock.during(turns.stopAddressAnswers());

      expect(owui.chats.holdAdmission!.isCompleted, isFalse);
      expect(owui.chats.stopped, hasLength(1));
      expect(turns.isRunning(answering), isFalse);
      expect(turns.addressAnswering, isFalse);
      await clock.during(held.then((_) {}, onError: (_) {}));
      expect(turns.addressAnswering, isFalse);
    });

    for (final (nth, where) in const [
      (0, 'while its admission reads settings'),
      (2, 'while the outbox prepares its request'),
    ]) {
      test('an address change that reaches a send $where keeps its request '
          'from going out, and does not wait for an answer', () async {
        owui.chats.refuseSockets();
        final held = await heldPreparing(nth);
        owui.chats.holdStream = Completer<void>();

        final changing = turns.stopAddressAnswers();
        owui.holdSettings!.complete();
        await clock.during(changing);
        await clock.during(held.then((_) {}, onError: (_) {}));

        expect(owui.chats.completions, isEmpty);
        expect(turns.addressAnswering, isFalse);
      });
    }

    test('an address change leaves alone a reply another window starts in '
        'another chat while it waits', () async {
      final held = await heldPreparing(0);
      final changing = turns.stopAddressAnswers();

      // The other chat's admission and outbox read settings too.
      owui.settingsToPass = 3;
      owui.chats
        ..seed('chat-garden', userId: 'user-ada')
        ..holdStream = Completer<void>();
      final other = await clock.during(
        turns.send(
          const SendTurn(
            chatId: 'chat-garden',
            model: 'kettle-model',
            text: 'Water the beans',
          ),
        ),
      );
      owui.holdSettings!.complete();
      await clock.during(changing);
      await clock.during(held.then((_) {}, onError: (_) {}));

      expect(turns.isRunning(other.chatId), isTrue);
      expect(owui.chats.stopped, isEmpty);
    });

    test('Stop on a send whose reply is held drops it then', () async {
      final (answering: _, :held) = await answeringAndHeld();
      const chatId = 'chat-kitchen';

      await clock.during(turns.stop(chatId));

      expect(owui.chats.holdAdmission!.isCompleted, isFalse);
      expect(turns.isRunning(chatId), isFalse);
      await clock.during(held.then((_) {}, onError: (_) {}));
    });
  });

  group('against a fake Open WebUI, then a fake LibreChat', () {
    setUp(signIn);

    test('an address change stops an Open WebUI answer, and leaves a running '
        'LibreChat answer alone', () async {
      final chats = owui.chats
        ..seed('chat-garden', userId: 'user-ada')
        ..holdStream = Completer<void>();
      final garden = await clock.during(
        turns.send(
          const SendTurn(
            chatId: 'chat-garden',
            model: 'kettle-model',
            text: 'Water the beans',
          ),
        ),
      );
      expect(turns.addressAnswering, isTrue);
      // The send returns once the turn starts here; the server has a task
      // to stop only once it has taken the completion.
      await clock.during(chats.taskStarted.future);
      await clock.during(turns.stopAddressAnswers());
      expect(chats.stopped, hasLength(1));
      expect(turns.isRunning(garden.chatId), isFalse);

      // LibreChat takes charge of the chats; Open WebUI's account stays
      // active, parked, and its address can still change.
      final libreChat = await FakeLibreChatChat.start();
      addTearDown(libreChat.close);
      libreChat.fake.addUser(email: 'avery@example.com', password: 'pw-avery');
      final signedIn = await clock.during(
        LibreChatService(
          runtime.container,
          events: events,
          accounts: accounts,
        ).signIn(
          LibreChatSignIn(
            url: libreChat.url,
            email: 'avery@example.com',
            password: 'pw-avery',
          ),
        ),
      );
      expect(signedIn.outcome, LibreChatSignInOutcome.signedIn);
      // Preferences are the process's, and the next test signs in to Open
      // WebUI as the account in charge.
      addTearDown(
        () => clock.during(
          accounts.switchTo(
            AccountRef(
              accountId: openWebUiAccount,
              force: true,
              askedOver: signedIn.accountId,
            ),
          ),
        ),
      );
      final catalog = await clock.during(
        readSettled(runtime.container, libreChatModelCatalogProvider.future),
      );
      expect(catalog.map((m) => m.id), contains(FakeLibreChatChat.model));

      final sending = turns.send(
        const SendTurn(
          model: FakeLibreChatChat.model,
          text: 'Plan a ridge walk',
        ),
      );
      await clock.during(Future.any([libreChat.streamOpened, sending]));
      libreChat
        ..created('question-ridge', 'Plan a ridge walk')
        ..text('answer-ridge', 'Start at the');
      final ridge = await clock.during(sending);
      expect(turns.isRunning(ridge.chatId), isTrue);
      expect(turns.addressAnswering, isFalse);

      await clock.during(turns.stopAddressAnswers());
      expect(turns.isRunning(ridge.chatId), isTrue);
      expect(libreChat.aborts, isEmpty);
    });
  });

  // 0.13.4 passes both on to the provider instead of reading them. The core
  // tests cover each version; this one shows conduitd's client reads it.
  group('against a fake Open WebUI 0.13.4', () {
    setUp(() => signIn(version: '0.13.4'));

    test('a send leaves out model_item and tool_servers', () async {
      owui.chats.seed('chat-kitchen', userId: 'user-ada');

      await clock.during(
        turns.send(
          const SendTurn(
            chatId: 'chat-kitchen',
            model: 'kettle-model',
            text: 'Milk?',
          ),
        ),
      );
      await clock.during(owui.chats.admissionAsked.future);

      final asked = owui.chats.completions.single;
      expect(asked.containsKey('model_item'), isFalse);
      expect(asked.containsKey('tool_servers'), isFalse);
    });
  });

  group('against a fake Open WebUI before 0.9', () {
    setUp(() => signIn(version: '0.8.5'));

    for (final (step, reads) in const [('read', true), ('saved', false)]) {
      test('a Stop while its pending turn is $step, which then loses its '
          'connection, keeps the request from going out on any later '
          'attempt, and its answer ends stopped', () async {
        const chatId = 'chat-kitchen';
        final chats = owui.chats;
        final held = await heldPreparing(2);
        chats.dropHeldChats = true;
        if (reads) {
          chats
            ..chatReadAsked = Completer<void>()
            ..holdChatReads = Completer<void>();
        } else {
          chats
            ..chatSaveAsked = Completer<void>()
            ..holdChatSaves = Completer<void>();
        }
        owui.holdSettings!.complete();
        await clock.during(
          (reads ? chats.chatReadAsked : chats.chatSaveAsked).future,
        );

        final stopping = turns.stop(chatId);
        await pumpEventQueue();
        (reads ? chats.holdChatReads : chats.holdChatSaves)!.complete();
        await clock.during(stopping);
        await clock.during(held.then((_) {}, onError: (_) {}));

        expect(chats.completions, isEmpty);
        final db = runtime.container.read(appDatabaseProvider)!;
        final ops = await db.select(db.outboxOps).get();
        expect([
          for (final op in ops)
            if (op.chatId == chatId) op.kind,
        ], isNot(contains('requestCompletion')));
        final answers = [
          for (final row in await db.messagesDao.getForChat(chatId))
            if (row.role == 'assistant')
              jsonDecode(row.payload) as Map<String, dynamic>,
        ];
        expect(answers, isNotEmpty);
        expect(answers.last['isStreaming'], isFalse);
      });
    }
  });
}
