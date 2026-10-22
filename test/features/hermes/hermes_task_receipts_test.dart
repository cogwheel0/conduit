import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/features/hermes/providers/hermes_mobile_work.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _Channel extends Mock implements WebSocketChannel {}

final class _Sink extends Mock implements WebSocketSink {}

class _StatusAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode({
      'version': '0.20.1',
      'auth_required': false,
      'gateway_running': true,
    }),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

class _DesktopFixture {
  _DesktopFixture() {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': {}},
          }),
        ),
      );
      return incoming.stream;
    });
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final request = jsonDecode(
        invocation.positionalArguments.single as String,
      ) as Map<String, dynamic>;
      if (request['id'] == null) return;
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': request['method'] == 'session.active_list'
                ? {'sessions': rows}
                : <String, dynamic>{},
          }),
        ),
      );
    });
  }
  final channel = _Channel();
  final sink = _Sink();
  final incoming = StreamController<dynamic>.broadcast();
  List<Map<String, dynamic>> rows = [];
  late final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://fixture.invalid',
      mode: HermesBackendMode.desktopGateway,
      desktopCredentials: HermesDesktopCredentials(
        legacyToken: 'fixture-token',
      ),
    ),
    dio: Dio()..httpClientAdapter = _StatusAdapter(),
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => channel,
    ),
  );
  Future<void> close() async {
    service.close();
    await incoming.close();
  }
}

Conversation _conversation(
  String session, {
  String title = 'Fixture task',
  Map<String, dynamic> metadata = const {},
}) => markNativeHermesConversation(
  Conversation(
    id: 'local:hermes_$session',
    title: title,
    createdAt: DateTime.utc(2026, 10, 17),
    updatedAt: DateTime.utc(2026, 10, 17),
    metadata: {'hermesSessionId': session, ...metadata},
  ),
);

ChatMessage _message({String? session}) => ChatMessage(
  id: 'fixture-assistant',
  role: 'assistant',
  content: 'Fixture response',
  timestamp: DateTime.utc(2026, 10, 17),
  metadata: session == null ? null : {'hermesSessionId': session},
);

void main() {
  test(
    'receipts retain the twelve latest sessions and update a repeated session',
    () {
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);
      final ledger = container.read(hermesTaskReceiptsProvider.notifier);
      for (var i = 0; i < 15; i++) {
        ledger.record(
          _conversation('session-$i'),
          _message(),
          HermesChatOutcome.completed,
        );
      }
      final bounded = container.read(hermesTaskReceiptsProvider);
      expect(bounded, hasLength(12));
      expect(bounded.map((row) => row.session.id), [
        for (var i = 14; i >= 3; i--) 'session-$i',
      ]);

      ledger.record(
        _conversation('session-7', title: 'Retried task'),
        _message(),
        HermesChatOutcome.failed,
      );
      final updated = container.read(hermesTaskReceiptsProvider);
      expect(updated, hasLength(12));
      expect(updated.first.session.id, 'session-7');
      expect(updated.first.session.title, 'Retried task');
      expect(updated.first.outcome, HermesChatOutcome.failed);
      expect(
        updated.where((row) => row.session.id == 'session-7'),
        hasLength(1),
      );
      expect(updated.last.session.id, 'session-3');
    },
  );

  test('receipts use the terminal message session and retain bot identity', () {
    final container = ProviderContainer(
      overrides: [hermesApiServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    final startedAt = DateTime.now();
    container
        .read(hermesTaskReceiptsProvider.notifier)
        .record(
          _conversation(
            'old-session',
            title: 'Plan release',
            metadata: {
              'hermesBotProfile': 'planner',
              'hermesBotTitle': 'Release planner',
              'hermesBotShape': 'hexagon',
              'hermesBotColor': '#387a65',
              'hermesBotImageKind': 'photo',
              'hermesBotAvatar': 'data:image/png;base64,Zml4dHVyZQ==',
            },
          ),
          _message(session: 'captured-session'),
          HermesChatOutcome.stopped,
        );
    final receipt = container.read(hermesTaskReceiptsProvider).single;
    expect(receipt.session.id, 'captured-session');
    expect(receipt.session.title, 'Plan release');
    expect(receipt.outcome, HermesChatOutcome.stopped);
    expect(receipt.bot?.name, 'planner');
    expect(receipt.bot?.title, 'Release planner');
    expect(receipt.bot?.avatarShape, 'hexagon');
    expect(receipt.bot?.avatarColor, '#387a65');
    expect(receipt.bot?.avatarImageKind, 'photo');
    expect(receipt.bot?.hasAvatar, isTrue);
    expect(receipt.botAvatar, 'data:image/png;base64,Zml4dHVyZQ==');
    expect(receipt.session.updatedAt!.isBefore(startedAt), isFalse);
    expect(receipt.session.updatedAt!.isAfter(DateTime.now()), isFalse);
  });

  test(
    'serialized Hermes metadata cannot add mixed OpenWebUI work to receipts',
    () {
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);
      final ledger = container.read(hermesTaskReceiptsProvider.notifier);
      final native = _conversation(
        'shared-session',
        title: 'Native Hermes task',
      );
      ledger.record(native, _message(), HermesChatOutcome.completed);
      final foreign = native.copyWith(
        id: 'server-chat',
        title: 'Foreign account task',
        metadata: {...native.metadata, 'backend': 'hermes'},
      );
      expect(isNativeHermesConversation(foreign), isFalse);
      ledger.record(foreign, _message(), HermesChatOutcome.failed);
      final receipt = container.read(hermesTaskReceiptsProvider).single;
      expect(receipt.session.title, 'Native Hermes task');
      expect(receipt.outcome, HermesChatOutcome.completed);
    },
  );

  test(
    'changing or disconnecting the backend clears prior connection receipts',
    () async {
      final first = _DesktopFixture(), second = _DesktopFixture();
      addTearDown(first.close);
      addTearDown(second.close);
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(first.service)],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        hermesTaskReceiptsProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      container
          .read(hermesTaskReceiptsProvider.notifier)
          .record(
            _conversation('shared-session'),
            _message(),
            HermesChatOutcome.completed,
          );
      expect(container.read(hermesTaskReceiptsProvider), hasLength(1));

      // The same endpoint can belong to another account or connection lifetime.
      container.updateOverrides([
        hermesApiServiceProvider.overrideWithValue(second.service),
      ]);
      await container.pump();
      expect(container.read(hermesTaskReceiptsProvider), isEmpty);
      container
          .read(hermesTaskReceiptsProvider.notifier)
          .record(
            _conversation('shared-session', title: 'Second connection task'),
            _message(),
            HermesChatOutcome.failed,
          );
      expect(
        container.read(hermesTaskReceiptsProvider).single.session.title,
        'Second connection task',
      );
      container.updateOverrides([
        hermesApiServiceProvider.overrideWithValue(null),
      ]);
      await container.pump();
      expect(container.read(hermesTaskReceiptsProvider), isEmpty);
    },
  );

  test(
    'a remote active row disappearing never creates a terminal receipt',
    () async {
      final fixture = _DesktopFixture()
        ..rows = [
          {'id': 'remote-run', 'status': 'working'},
        ];
      final container = ProviderContainer(
        overrides: [
          hermesApiServiceProvider.overrideWithValue(fixture.service),
        ],
      );
      addTearDown(fixture.close);
      addTearDown(container.dispose);
      final subscription = container.listen(
        hermesMobileActiveTasksProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      container
          .read(hermesTaskReceiptsProvider.notifier)
          .record(
            _conversation('finished-local-task'),
            _message(),
            HermesChatOutcome.completed,
          );
      expect(
        await container.read(hermesMobileActiveTasksProvider.future),
        hasLength(1),
      );

      fixture.rows = [];
      container.invalidate(hermesMobileActiveTasksProvider);
      expect(
        await container.read(hermesMobileActiveTasksProvider.future),
        isEmpty,
      );
      final receipts = container.read(hermesTaskReceiptsProvider);
      expect(receipts, hasLength(1));
      expect(receipts.single.session.id, 'finished-local-task');
    },
  );
}
