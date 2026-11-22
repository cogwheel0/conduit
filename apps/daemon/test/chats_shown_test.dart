@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show appDatabaseProvider;
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:riverpod/riverpod.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

final class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

/// A window says which chat each of its views shows (`chats.setShown`), and
/// the core keeps those chats read while they show: until the view shows
/// another, or none, or the window goes.
void main() {
  late Directory tempDir;
  late ProviderContainer container;
  late RpcSession session;
  late json_rpc.Peer client;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('conduitd_chats_shown');
    container = ProviderContainer(
      overrides: [
        conversationsProvider.overrideWith(_Conversations.new),
        appDatabaseProvider.overrideWithValue(null),
      ],
    );
    final chats = ChatsService(container);
    final log = DaemonLog(level: 'error', sink: NullSink());
    final pipe = StreamChannelController<String>(sync: true);
    session = RpcSession(
      sessionId: 'w1',
      channel: pipe.local,
      system: SystemService(
        directories: DaemonDirectories.create(tempDir.path),
        daemonVersion: '0.0.0-test',
        log: log,
        requestStop: (_) => fail('nothing here should stop the daemon'),
      ),
      events: EventBus(),
      log: log,
      services: () => CoreServices(chats: chats),
    );
    unawaited(session.listen());
    client = json_rpc.Peer(pipe.foreign);
    unawaited(client.listen());
    await client.sendRequest(
      ConduitMethods.systemHandshake,
      const HandshakeRequest(
        protocolVersion: kConduitProtocolVersion,
        clientName: 'test',
        clientVersion: '0.0.0',
        windowKind: WindowKind.headless,
        locale: 'en',
      ).toJson(),
    );
  });

  tearDown(() async {
    await client.close();
    await session.close();
    container.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<void> show(ChatView view, String? chatId) => client.sendRequest(
    ConduitMethods.chatsSetShown,
    ShownChat(view: view, chatId: chatId).toJson(),
  );

  test('each view of a window shows its own chat, until it shows none or '
      'the window goes', () async {
    await show(ChatView.main, 'chat-a');
    await show(ChatView.quickAsk, 'chat-q');
    expect(container.read(shownChatsProvider), <String, String>{
      'w1/main': 'chat-a',
      'w1/quickAsk': 'chat-q',
    });

    await show(ChatView.quickAsk, null);
    expect(container.read(shownChatsProvider), <String, String>{
      'w1/main': 'chat-a',
    });

    await session.close();
    expect(container.read(shownChatsProvider), isEmpty);
  });
}
