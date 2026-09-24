@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_openai.dart';
import 'support/null_sink.dart';

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
    events.subscribe(
      'window',
      EventSubscription(scopes: <String>[accepted.chatId]),
    );
    final until = DateTime.now().add(const Duration(seconds: 20));
    while (done.isEmpty && failed.isEmpty && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(failed, isEmpty, reason: failed.map((f) => f.args).join());
    expect(done.single.text, 'no tool');
    // Kept on this computer, and listed like any other chat.
    expect(accepted.chatId, startsWith('direct-local:'));
    final listed = await chats.list();
    expect(listed.chats.map((c) => c.id), contains(accepted.chatId));
    final detail = await chats.get(accepted.chatId);
    expect(detail!.messages.map((m) => m.content), <String>[
      'Hello there',
      'no tool',
    ]);
  });
}
