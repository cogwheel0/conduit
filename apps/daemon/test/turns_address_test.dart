@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart'
    show kDirectTransport;
import 'package:conduit_core/features/librechat/models/librechat_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';

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

  group('against a fake Open WebUI', () {
    late FakeOwuiAuthServer owui;
    late EventBus events;
    late TurnsService turns;

    setUp(() async {
      final temporary = Directory.systemTemp.createTempSync('turns-address');
      addTearDown(() => temporary.deleteSync(recursive: true));
      final runtime = await CoreRuntime.start(
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
            ..models = const ['kettle-model'];
      addTearDown(owui.close);
      events = EventBus();
      final accounts = AccountsService(runtime.container, events: events);
      addTearDown(accounts.dispose);
      final auth = AuthService(runtime.container);
      addTearDown(auth.dispose);
      final added = await accounts.add(
        AddAccount(
          server: ServerDraft(name: 'Lab', url: owui.url),
          force: true,
        ),
      );
      final accountId = added.accounts.activeAccountId!;
      await auth.loginWithPassword(
        const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
      );
      await runtime.container.read(activeServerProvider.future);
      // Chats already on the server are opened as the account's once its
      // user is bound. Certification starts that bind right after it is
      // announced, queued on storage's lock: a registry read made after the
      // announcement's own work (a microtask) is queued behind it.
      final storage = runtime.container.read(optimizedStorageServiceProvider);
      final bound = Completer<void>();
      final watch = runtime.container.listen<Object?>(
        openWebUiCertifiedDatabaseServerProvider,
        (_, _) => Future<void>.microtask(() async {
          final registry = await storage.getOpenWebUiRegistryStrict();
          if (registry.account(accountId)?.userId != null &&
              !bound.isCompleted) {
            bound.complete();
          }
        }),
        fireImmediately: true,
      );
      addTearDown(watch.close);
      await bound.future;
      turns = TurnsService(runtime.container, events);
      addTearDown(turns.dispose);
    });

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
      final answering = await turns.send(
        const SendTurn(
          chatId: 'chat-garden',
          model: 'kettle-model',
          text: 'Water the beans',
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
      await chats.admissionAsked.future;
      expect(turns.addressAnswering, isTrue);
      return (answering: answering.chatId, held: held);
    }

    test('an address change stops the answers through it while a send\'s '
        'reply is still held: the send is dropped, not waited out', () async {
      final (:answering, :held) = await answeringAndHeld();

      await turns.stopAddressAnswers();

      expect(owui.chats.holdAdmission!.isCompleted, isFalse);
      expect(owui.chats.stopped, hasLength(1));
      expect(turns.isRunning(answering), isFalse);
      expect(turns.addressAnswering, isFalse);
      // It settles, its answer stopped or never started.
      await held.then((_) {}, onError: (_) {});
      expect(turns.addressAnswering, isFalse);
    });

    test('a send refused while an address change waits for it ends the '
        'wait, and the answers through the address are stopped', () async {
      final (:answering, :held) = await answeringAndHeld();
      owui.chats.refusal = const {'detail': 'The model is busy.'};

      final changing = turns.stopAddressAnswers();
      owui.chats.holdAdmission!.complete();
      await changing;

      expect(owui.chats.stopped, hasLength(1));
      expect(turns.isRunning(answering), isFalse);
      expect(turns.addressAnswering, isFalse);
      // It settles, its answer stopped or never started.
      await held.then((_) {}, onError: (_) {});
      expect(turns.addressAnswering, isFalse);
    });

    /// A send into a chat already on the server, with no socket to send it
    /// on, held at its [nth] read of the account's settings: 0 is its
    /// admission's, 1 the outbox's as it prepares the request.
    Future<Future<SendTurnAccepted>> heldPreparing(int nth) async {
      owui.chats
        ..seed('chat-kitchen', userId: 'user-ada')
        ..refuseSockets();
      owui
        ..settingsAsked = Completer<void>()
        ..settingsToPass = nth
        ..holdSettings = Completer<void>();
      final held = turns.send(
        const SendTurn(
          chatId: 'chat-kitchen',
          model: 'kettle-model',
          text: 'Milk?',
        ),
      )..ignore();
      await owui.settingsAsked.future;
      expect(turns.addressAnswering, isTrue);
      return held;
    }

    for (final (nth, where) in const [
      (0, 'while its admission reads settings'),
      (1, 'while the outbox prepares its request'),
    ]) {
      test('an address change that reaches a send $where keeps its request '
          'from going out, and does not wait for an answer', () async {
        final held = await heldPreparing(nth);
        // An answer, were one asked for, would run on.
        owui.chats.holdStream = Completer<void>();

        final changing = turns.stopAddressAnswers();
        owui.holdSettings!.complete();
        await changing;
        await held.then((_) {}, onError: (_) {});

        expect(owui.chats.completions, isEmpty);
        expect(turns.addressAnswering, isFalse);
      });
    }

    test('Stop on a send whose reply is held drops it then', () async {
      final (answering: _, :held) = await answeringAndHeld();
      const chatId = 'chat-kitchen';

      await turns.stop(chatId);

      expect(owui.chats.holdAdmission!.isCompleted, isFalse);
      expect(turns.isRunning(chatId), isFalse);
      // It settles, its answer stopped or never started.
      await held.then((_) {}, onError: (_) {});
    });
  });
}
