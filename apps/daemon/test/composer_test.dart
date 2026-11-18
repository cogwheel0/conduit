@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart'
    show PrimaryAccountKind;
import 'package:conduit_core/providers/primary_account_providers.dart'
    show PrimaryAccountRef, primaryAccountProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'support/fake_openai.dart';
import 'support/null_sink.dart';

/// What the composer holds and draws on, past the protocol: its draft kept
/// per chat, a message's mentions in Open WebUI's wire format, an upload's
/// retry advice, and the queue's answers in a chat with nothing running.
void main() {
  test(
    'Send Link says what it could not read, and whether it is a video',
    () async {
      // No Open WebUI account to read it (Direct, Hermes, signed out).
      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);
      final composer = ComposerService(container);

      final notALink = await composer.sendLink('  ftp://example.com/tides ');
      expect(notALink.url, 'ftp://example.com/tides');
      expect(notALink.error, 'invalidUrl');
      expect(notALink.youtube, isFalse);
      expect(notALink.attachment, isNull);

      final video = await composer.sendLink('https://youtu.be/tide-clock');
      expect(video.youtube, isTrue);
      expect(video.error, 'failed');
      expect(video.attachment, isNull);
    },
  );

  test(
    'Send Link never answers once another account took charge while it read',
    () async {
      var primary = const PrimaryAccountRef(
        PrimaryAccountKind.openWebUi,
        'server-ada',
      );
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          primaryAccountProvider.overrideWith((ref) => primary),
        ],
      );
      addTearDown(container.dispose);
      final composer = ComposerService(container);

      final asked = composer.sendLink('https://example.org/tides');
      // Another account takes charge before the read comes back.
      primary = const PrimaryAccountRef(
        PrimaryAccountKind.openWebUi,
        'server-bo',
      );
      container.invalidate(primaryAccountProvider);
      container.read(primaryAccountProvider);

      await expectLater(
        asked,
        throwsA(
          isA<RpcError>()
              .having((e) => e.code, 'code', ConduitErrorCodes.sessionExpired)
              .having((e) => e.args['reason'], 'reason', 'account'),
        ),
      );
    },
  );

  test('mentions go out in Open WebUI\'s wire format', () {
    const text = 'Ask @Riley in #garden with \$Plain English';
    final wire = composerWireText(text, const <ComposerMentionDto>[
      ComposerMentionDto(
        start: 4,
        end: 10,
        id: 'u-1',
        label: 'Riley',
        idType: 'U',
      ),
      ComposerMentionDto(
        start: 27,
        end: 41,
        id: 'plain-english',
        label: 'Plain English',
        kind: MentionKind.skill,
      ),
    ]);
    expect(
      wire,
      'Ask <@U:u-1|Riley> in #garden with <\$plain-english|Plain English>',
    );
    // A range outside the text is left out rather than cutting it short.
    expect(
      composerWireText('hi', const <ComposerMentionDto>[
        ComposerMentionDto(start: 1, end: 9, id: 'x', label: 'x'),
      ]),
      'hi',
    );
  });

  test('a failed upload says whether and when to try again', () {
    DioException dio(DioExceptionType type) => DioException(
      requestOptions: RequestOptions(path: '/api/v1/files/'),
      type: type,
    );
    expect(
      uploadRetryArgs(dio(DioExceptionType.connectionError), 1)['retry'],
      'offline',
    );
    expect(
      uploadRetryArgs(dio(DioExceptionType.receiveTimeout), 1)['retry'],
      'indeterminate',
    );
    final refused = uploadRetryArgs(dio(DioExceptionType.badResponse), 2);
    expect(refused['retry'], 'retryable');
    expect(int.parse(refused['retryAfterMs']!), inInclusiveRange(10000, 11000));
    expect(
      uploadRetryArgs(dio(DioExceptionType.badResponse), 4)['retry'],
      'exhausted',
    );
  });

  test("a draft asked for under one account is not the next one's", () async {
    var account = Object();
    final chat = Completer<Conversation>();
    final container = ProviderContainer(
      overrides: [
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        loadConversationProvider.overrideWith((ref, id) => chat.future),
      ],
    );
    addTearDown(container.dispose);
    final drafts = DraftsService(container, temporary: TemporaryChats());
    final saving = drafts.save(const DraftSave(chatId: 'chat-1', text: ''));
    account = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    chat.completeError(StateError('that account has left'));
    await expectLater(
      saving,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
  });

  group('with a direct connection', () {
    late Directory temporary;
    late CoreRuntime runtime;
    late FakeOpenAi provider;
    late String modelId;

    setUpAll(() async {
      temporary = Directory.systemTemp.createTempSync('composer-test');
      runtime = await CoreRuntime.start(
        config: BootstrapConfig(
          sessionToken: 'a' * 43,
          masterKey: base64.encode(List<int>.generate(32, (i) => i)),
          userDataDir: temporary.path,
        ),
        directories: DaemonDirectories.create(temporary.path),
        log: DaemonLog(level: 'error', sink: NullSink()),
      );
      provider = await FakeOpenAi.start();
      final direct = DirectService(runtime.container);
      await direct.setPreferred(preferred: true);
      await direct.save(
        DirectConnectionEdit(
          name: 'Fake',
          kind: DirectKind.openai,
          baseUrl: provider.baseUrl,
          manualModelIds: const <String>['fake-model'],
        ),
      );
      // The connection's model, once the model list has it.
      final listed = Completer<core.Model>();
      final subscription = runtime.container
          .listen<AsyncValue<List<core.Model>>>(modelsProvider, (_, next) {
            final model = next.value
                ?.where((m) => m.metadata?['directProfileName'] == 'Fake')
                .firstOrNull;
            if (model != null && !listed.isCompleted) listed.complete(model);
          }, fireImmediately: true);
      modelId = (await listed.future).id;
      subscription.close();
      await ModelsService(runtime.container).select(modelId);
    });

    tearDownAll(() async {
      await provider.close();
      await runtime.dispose();
      temporary.deleteSync(recursive: true);
    });

    test("a coding agent's composer offers no Compare and no effort of its "
        'own', () async {
      runtime.container
          .read(selectedModelProvider.notifier)
          .set(
            const core.Model(id: 'agent:bench:codex:gpt-5.1', name: 'Codex'),
            allowHidden: true,
          );
      addTearDown(() => ModelsService(runtime.container).select(modelId));
      final agent = await ComposerService(runtime.container).options();
      expect(agent.agentChat, isTrue);
      expect(agent.ownEffortControl, isTrue);
      expect(agent.compareModels, isFalse);

      // A composer that shows another model (a temporary chat, where no
      // agent answers) is offered that model's options, as its turn goes
      // to it.
      final shown = await ComposerService(
        runtime.container,
      ).options(ComposerOptionsQuery(modelId: modelId));
      expect(shown.agentChat, isFalse);
      expect(shown.ownEffortControl, isFalse);

      await ModelsService(runtime.container).select(modelId);
      final plain = await ComposerService(runtime.container).options();
      expect(plain.agentChat, isFalse);
      expect(plain.ownEffortControl, isFalse);
    });

    test('a draft is kept per chat, and a new chat\'s per folder', () async {
      // A chat kept on this computer, to keep a draft under.
      final turns = TurnsService(runtime.container, EventBus());
      addTearDown(turns.dispose);
      final chatId = (await turns.send(
        SendTurn(model: modelId, text: 'Hello there'),
      )).chatId;
      final drafts = DraftsService(
        runtime.container,
        temporary: TemporaryChats(),
      );
      expect((await drafts.get(const DraftRef())).text, isEmpty);
      await drafts.save(const DraftSave(text: 'Half a thought'));
      await drafts.save(
        const DraftSave(folderId: 'garden', text: 'For the garden'),
      );
      await drafts.save(DraftSave(chatId: chatId, text: 'In that chat'));
      expect((await drafts.get(const DraftRef())).text, 'Half a thought');
      expect(
        (await drafts.get(const DraftRef(folderId: 'garden'))).text,
        'For the garden',
      );
      final chat = await drafts.get(DraftRef(chatId: chatId));
      expect(chat.text, 'In that chat');
      expect(chat.stored, isTrue);
      // Kept by the database, so a new service (a relaunch) reads it back.
      final again = DraftsService(
        runtime.container,
        temporary: TemporaryChats(),
      );
      expect((await again.get(const DraftRef())).text, 'Half a thought');
      // Cleared by saving nothing.
      await again.save(const DraftSave(text: ''));
      expect((await again.get(const DraftRef())).text, isEmpty);
      // Steering is Hermes's (a Desktop Gateway): another chat declines it,
      // and the text stays with the window.
      final steer = await turns.steer(
        SteerTurn(chatId: chatId, text: 'Faster'),
      );
      expect(steer.accepted, isFalse);
      expect(steer.uncertain, isFalse);
      // A chat that is gone keeps none.
      final gone = await drafts.save(
        const DraftSave(chatId: 'direct-local:gone', text: 'Nowhere'),
      );
      expect(gone.stored, isFalse);
      // A temporary chat keeps none.
      final temp = await drafts.save(
        const DraftSave(chatId: 'local:temp-1', text: 'Gone with the chat'),
      );
      expect(temp.stored, isFalse);
      expect(
        (await drafts.get(const DraftRef(chatId: 'local:temp-1'))).stored,
        isFalse,
      );
    });

    test(
      'a chat with nothing running has nothing queued, and takes nothing',
      () async {
        final turns = TurnsService(runtime.container, EventBus());
        addTearDown(turns.dispose);
        final state = turns.queueGet('direct-local:chat-1');
        expect(state.drafts, isEmpty);
        expect(state.offer, isFalse);
        expect(
          () => turns.queueAdd(
            const QueueAdd(chatId: 'direct-local:chat-1', text: 'Later'),
          ),
          throwsA(
            isA<RpcError>().having(
              (e) => e.code,
              'code',
              ConduitErrorCodes.notFound,
            ),
          ),
        );
      },
    );
  });
}
