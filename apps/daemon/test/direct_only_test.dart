@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'support/fake_openai.dart';
import 'support/null_sink.dart';
import 'support/window.dart';

/// The app with no Open WebUI server at all: a direct connection is
/// the whole backend, chosen on the welcome screen.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeOpenAi provider;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('direct-only-test');
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
  });

  tearDownAll(() async {
    await provider.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('a direct connection is enough to chat', () async {
    final direct = DirectService(runtime.container);
    var list = await direct.list();
    expect(list.preferred, isFalse);
    expect(list.usable, isFalse);

    list = await direct.setPreferred(preferred: true);
    expect(list.preferred, isTrue);
    list = await direct.save(
      DirectConnectionEdit(
        name: 'Fake',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['fake-model'],
      ),
    );
    expect(list.usable, isTrue);

    // Its models are offered with no server to ask.
    final models = ModelsService(runtime.container);
    ModelSummary? offered;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (offered == null && DateTime.now().isBefore(deadline)) {
      offered = (await models.list()).models
          .where((m) => m.connection == 'Fake')
          .firstOrNull;
      if (offered == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    expect(offered, isNotNull);

    final events = EventBus();
    final turns = TurnsService(runtime.container, events);
    addTearDown(turns.dispose);
    final chats = ChatsService(runtime.container, events: events);
    addTearDown(chats.dispose);
    final done = <TurnCompleted>[];
    final failed = <TurnFailed>[];
    events.attach('window', (envelope) {
      if (envelope.event == ConduitEvents.turnCompleted) {
        done.add(TurnCompleted.fromJson(envelope.payload));
      } else if (envelope.event == ConduitEvents.turnFailed) {
        failed.add(TurnFailed.fromJson(envelope.payload));
      }
    });
    final accepted = await turns.send(
      SendTurn(model: offered!.id, text: 'Hello there'),
    );
    // A window learns the new chat's id from the reply, and is sent what it
    // missed when it subscribes: the answer so far, or the finished answer
    // when the provider was quicker than the reply.
    subscribeWindow(events, turns, 'window', <String>[accepted.chatId]);
    final until = DateTime.now().add(const Duration(seconds: 20));
    while (done.isEmpty && failed.isEmpty && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(failed, isEmpty, reason: failed.map((f) => f.args).join());
    expect(done.single.text, 'no tool');
    expect(done.single.messageId, accepted.assistantMessageId);
    // Kept on this computer, and listed like any other chat.
    expect(accepted.chatId, startsWith('direct-local:'));
    final listed = await chats.list();
    expect(listed.chats.map((c) => c.id), contains(accepted.chatId));
    final detail = await chats.get(accepted.chatId);
    expect(detail!.messages.map((m) => m.content), <String>[
      'Hello there',
      'no tool',
    ]);

    // Managed where it is kept, with no Open WebUI account to ask.
    ChatSummary summary(ChatList list) =>
        list.chats.singleWhere((c) => c.id == accepted.chatId);
    expect(
      summary(await chats.rename(accepted.chatId, 'Kept here')).title,
      'Kept here',
    );
    expect(
      summary(await chats.setPinned(accepted.chatId, value: true)).pinned,
      isTrue,
    );
    final tree = await chats.tree(accepted.chatId);
    expect(tree.nodes, hasLength(2));
    final archived = await chats.bulk(
      BulkChats(
        action: BulkChatAction.archive,
        chatIds: <String>[accepted.chatId],
      ),
    );
    expect(archived.failed, isEmpty);
    await chats.setArchived(accepted.chatId, value: false);
    final deleted = await chats.delete(accepted.chatId);
    expect(deleted.chats.map((c) => c.id), isNot(contains(accepted.chatId)));
  });

  // A temporary chat lives only in the daemon's memory; deleting it must
  // forget it there, or `chats.get` and the next send still have it.
  test('deleting a temporary chat forgets its transcript', () async {
    final temporary = TemporaryChats()..start('local:scratch');
    final chats = ChatsService(runtime.container, temporary: temporary);
    addTearDown(chats.dispose);
    expect(await chats.get('local:scratch'), isNotNull);
    await chats.delete('local:scratch');
    expect(temporary.contains('local:scratch'), isFalse);
    expect(await chats.get('local:scratch'), isNull);

    // An answer that was still running, or a scope still lingering, does
    // not write it back; and it cannot be sent to again.
    temporary.replace('local:scratch', const []);
    expect(temporary.contains('local:scratch'), isFalse);
    final turns = TurnsService(
      runtime.container,
      EventBus(),
      temporary: temporary,
    );
    addTearDown(turns.dispose);
    await expectLater(
      turns.send(const SendTurn(chatId: 'local:scratch', text: 'again')),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.notFound,
        ),
      ),
    );
  });

  // The id goes into the server's path, with the account's credential: an
  // id that is not one plain path segment must not reach anywhere else.
  test('a file id that is not one plain segment is refused', () async {
    final files = FilesService(runtime.container);
    for (final id in <String>[
      '..',
      '.',
      'a?b',
      'a#b',
      '../../auths',
      r'a\b',
      // Decoded once already; the server would decode it again.
      '%2E%2E',
      'a%2Fb',
    ]) {
      await expectLater(
        files.download('any-server', id),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.invalidParams,
          ),
        ),
        reason: id,
      );
    }
  });

  // The server check and the client must name the same server: an account
  // switch between them would otherwise show the new account's file under
  // the old account's id.
  test('a file is refused when the client belongs to another server', () async {
    final container = ProviderContainer(
      overrides: [
        activeServerProvider.overrideWith(
          (ref) async =>
              const ServerConfig(id: 'a', name: 'A', url: 'https://a.example'),
        ),
        apiServiceProvider.overrideWithValue(_OtherServerApi()),
      ],
    );
    addTearDown(container.dispose);
    await expectLater(
      FilesService(container).download('a', 'file-1'),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.notFound,
        ),
      ),
    );
  });
}

/// The client of another account's server, which must never be asked.
final class _OtherServerApi extends ApiService {
  _OtherServerApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'b',
          name: 'B',
          url: 'https://b.example',
        ),
        workerManager: WorkerManager(),
      );

  @override
  Future<String> getFileContent(
    String fileId, {
    int? maxBytes,
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async => fail('read $fileId from the other account\'s server');
}
