import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show ChatMessagesNotifier, chatMessagesProvider;
import 'package:conduit_core/features/hermes/models/hermes_background_work.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_background_work_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/testing/fake_app_lifecycle.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

/// A refusal the stub gateway answers instead of a result.
final class _Refusal implements Exception {
  const _Refusal(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Map<String, Object?>? data;
}

/// A Desktop Gateway over `/api/ws`: the dashboard's legacy wire, or with
/// [authority] a gateway's Webapp listener. Records each request and
/// answers it from [work] and [handler].
final class _Gateway {
  _Gateway({required this.authority}) {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(_ready);
      // One stream per connection, as a socket's: a reconnect cancels the
      // dropped one, and that cancel must complete under fake time, which
      // a broadcast subscription's does not.
      late final StreamSubscription<dynamic> forward;
      final socket = StreamController<dynamic>(
        onCancel: () {
          unawaited(forward.cancel());
          return Future<void>.value();
        },
      );
      forward = incoming.stream.listen(
        socket.add,
        onError: socket.addError,
        onDone: socket.close,
      );
      return socket.stream;
    });
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final frame = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      sent.add(frame);
      final id = frame['id'];
      final method = frame['method'];
      if (id == null || method is! String) return;
      final params = Map<String, dynamic>.from(
        (frame['params'] as Map?) ?? const {},
      );
      Map<String, Object?> reply;
      try {
        reply = {'result': handler?.call(method, params) ?? _answer(method)};
      } on _Refusal catch (refusal) {
        reply = {
          'error': {
            'code': refusal.code,
            'message': refusal.message,
            'data': ?refusal.data,
          },
        };
      }
      void send() {
        if (!incoming.isClosed) {
          incoming.add(jsonEncode({'jsonrpc': '2.0', 'id': id, ...reply}));
        }
      }

      final hold = method == 'subagent.tail' ? holdTail : null;
      if (hold != null) {
        unawaited(hold.future.then((_) => send()));
      } else {
        scheduleMicrotask(send);
      }
    });
  }

  final bool authority;

  /// While set, a `subagent.tail` answer waits for it to complete.
  Completer<Object?>? holdTail;
  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <Map<String, dynamic>>[];

  /// The legacy wire mints a runtime id per attach; an authority keeps
  /// the stored one.
  String get runtimeId => authority ? 'local-1' : 'rt-1';

  List<Map<String, Object?>> subagents = const [];
  List<Map<String, Object?>> processes = const [];

  /// Answers a request in place of the defaults; null falls back to them.
  Object? Function(String method, Map<String, dynamic> params)? handler;

  Object? _answer(String method) => switch (method) {
    'session.resume' => {
      'session_id': runtimeId,
      'stored_session_id': 'local-1',
      'running': false,
      if (authority) ...{
        'messages': const <Object?>[],
        'authority_epoch': 1,
        'replay_epoch': 'epoch-1',
        'last_sequence': 0,
        'subscription_id': 'sub-1',
        'revision': 1,
        'execution_generation': 1,
        'pending': const <Object?>[],
        'prompts': const <Object?>[],
      },
      'info': {
        if (authority) 'desktop_protocol': kHermesCanonicalGatewayProtocol,
      },
    },
    'subagent.list' => {
      'subagents': subagents,
      'delegations': const <Object?>[],
    },
    'process.list' => {'processes': processes},
    _ => const <String, Object?>{},
  };

  void _ready() {
    if (incoming.isClosed) return;
    incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'gateway.ready',
          'payload': {if (authority) 'session_authority': true},
        },
      }),
    );
  }

  void event(String type, Map<String, Object?> payload, {String? session}) =>
      incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': type,
            'session_id': session ?? runtimeId,
            'payload': payload,
          },
        }),
      );

  List<Map<String, dynamic>> calls(String method) => [
    for (final frame in sent)
      if (frame['method'] == method)
        Map<String, dynamic>.from(frame['params'] as Map),
  ];

  Future<void> dispose() => incoming.close();
}

final class _Rest implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final (status, body) = options.uri.path == '/api/status'
        ? (200, {'auth_required': false, 'gateway_running': true})
        : (404, {'detail': 'Not Found'});
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

HermesDesktopApiService _service(_Gateway gateway) =>
    HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.legacyToken,
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'session-token',
        ),
        desktopProfile: 'default',
      ),
      dio: Dio()..httpClientAdapter = _Rest(),
      rpc: HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => gateway.channel,
      ),
      gatewayStartRetryDelays: const [Duration.zero],
    );

/// The open chat continues Hermes session `local-1`.
final class _OpenHermesChat extends ActiveConversationNotifier {
  @override
  Conversation? build() => Conversation(
    id: 'local:hermes_local-1',
    title: 'Tides',
    createdAt: DateTime.utc(2030),
    updatedAt: DateTime.utc(2030),
    metadata: const {'hermesSessionId': 'local-1'},
  );
}

/// An OpenWebUI chat whose latest reply Hermes wrote in session local-1.
final class _MixedChat extends ActiveConversationNotifier {
  @override
  Conversation? build() => Conversation(
    id: 'owui-chat-1',
    title: 'Tides',
    createdAt: DateTime.utc(2030),
    updatedAt: DateTime.utc(2030),
  );
}

final class _MixedMessages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [
    ChatMessage(
      id: 'reply-1',
      role: 'assistant',
      content: 'Working on it.',
      timestamp: DateTime.utc(2030),
      metadata: const {'hermesSessionId': 'local-1'},
    ),
  ];
}

Map<String, Object?> _child(
  String id, {
  String status = 'running',
  String goal = 'Survey the tide tables',
}) => {
  'subagent_id': id,
  'parent_id': null,
  'depth': 0,
  'goal': goal,
  'delegation_id': null,
  'model': 'synthetic-model',
  'started_at': 1900000000.5,
  'status': status,
  'tool_count': 2,
  'last_tool': 'web_search',
  'accepting_steer': true,
};

Map<String, Object?> _process(String id, {String status = 'running'}) => {
  'session_id': id,
  'command': 'python3 -m http.server 8000\n# second line',
  'status': status,
  'uptime_seconds': 75,
  'output_tail': 'Serving HTTP on 0.0.0.0 port 8000',
};

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  group('model', () {
    test('reads subagents and counts the ones still running', () {
      final work = HermesBackgroundWork.fromResults(
        subagents: {
          'subagents': [
            _child('sa-1'),
            _child('sa-2', status: 'queued'),
            _child('sa-3', status: 'completed'),
            {'goal': 'no id'},
            'not a row',
          ],
        },
      );

      check(work.subagents.map((s) => s.id)).deepEquals([
        'sa-1',
        'sa-2',
        'sa-3',
      ]);
      check(work.runningSubagents).equals(2);
      check(work.runningProcesses).equals(0);
      check(work.active).isTrue();
      final first = work.subagent('sa-1')!;
      check(first.goal).equals('Survey the tide tables');
      check(first.model).equals('synthetic-model');
      check(first.lastTool).equals('web_search');
      check(first.toolCount).equals(2);
      check(
        first.startedAt,
      ).equals(DateTime.fromMillisecondsSinceEpoch(1900000000500));
    });

    test('reads both wires\' process rows', () {
      final now = DateTime.utc(2030, 1, 1, 12);
      final work = HermesBackgroundWork.fromResults(
        processes: {
          'processes': [
            // The dashboard counts uptime.
            _process('proc_a'),
            // A session authority names the start and the exit.
            {
              'session_id': 'proc_b',
              'command': 'make watch',
              'status': 'exited',
              'exit_code': 2,
              'started_epoch': 1900000000,
              'output_tail': 'done',
            },
          ],
        },
        now: now,
      );

      final [legacy, canonical] = work.processes;
      check(legacy.command).equals('python3 -m http.server 8000');
      check(legacy.running).isTrue();
      check(legacy.startedAt).equals(now.subtract(const Duration(seconds: 75)));
      check(legacy.output).equals('Serving HTTP on 0.0.0.0 port 8000');
      check(canonical.running).isFalse();
      check(canonical.exitCode).equals(2);
      check(
        canonical.startedAt,
      ).equals(DateTime.fromMillisecondsSinceEpoch(1900000000000));
      check(work.runningProcesses).equals(1);
    });

    test('bounds what it keeps', () {
      final work = HermesBackgroundWork.fromResults(
        subagents: {
          'subagents': [
            for (var i = 0; i < 80; i++) _child('sa-$i', goal: 'g' * 900),
          ],
        },
        processes: {
          'processes': [
            {
              'session_id': 'proc_x',
              'command': 'c' * 400,
              'output_tail': 'o' * 9000,
            },
          ],
        },
      );

      check(work.subagents).length.equals(kMaxHermesBackgroundItems);
      check(work.subagents.first.goal.runes.length).equals(500);
      check(work.processes.single.command.runes.length).equals(200);
      check(
        work.processes.single.output!,
      ).length.equals(kMaxHermesProcessOutputCharacters);
    });

    test('reads a transcript tail without splitting a character', () {
      final text = '🌊${'x' * (kMaxHermesSubagentTailCharacters - 1)}';
      final tail = HermesSubagentTail.fromJson({
        'available': true,
        'text': text,
        'truncated': true,
      });

      check(tail.available).isTrue();
      check(tail.truncated).isTrue();
      check(tail.text).equals('x' * (kMaxHermesSubagentTailCharacters - 1));
      check(HermesSubagentTail.fromJson(null).available).isFalse();
    });

    test('reads what a kill did', () {
      check(
        HermesProcessKillResult.fromJson({
          'status': 'killed',
          'output': 'bye',
        }),
      ).has((r) => r.stopped, 'stopped').isTrue();
      check(
        HermesProcessKillResult.fromJson({'status': 'already_exited'}).status,
      ).equals(HermesProcessKillStatus.alreadyExited);
      final failed = HermesProcessKillResult.fromJson({
        'status': 'error',
        'error': 'Kill incomplete: 1 process(es) still alive',
      });
      check(failed.status).equals(HermesProcessKillStatus.failed);
      check(failed.stopped).isFalse();
      check(failed.error).equals('Kill incomplete: 1 process(es) still alive');
    });
  });

  for (final authority in [false, true]) {
    final wire = authority ? 'session authority' : 'dashboard';

    group('on the $wire', () {
      late _Gateway gateway;
      late HermesDesktopApiService service;

      setUp(() async {
        gateway = _Gateway(authority: authority);
        service = _service(gateway);
        addTearDown(() async {
          service.close();
          await gateway.dispose();
        });
      });

      Future<void> open() => service.pendingDecisionsForSession('local-1');

      test('lists nothing until the chat is attached, then both', () async {
        check(await service.backgroundWorkFor('local-1')).isNull();
        check(gateway.calls('session.resume')).isEmpty();

        gateway
          ..subagents = [_child('sa-1')]
          ..processes = [_process('proc_a')];
        await open();
        final work = (await service.backgroundWorkFor('local-1'))!;

        check(work.runningSubagents).equals(1);
        check(work.runningProcesses).equals(1);
        for (final method in ['subagent.list', 'process.list']) {
          check(gateway.calls(method).single).deepEquals({
            'session_id': gateway.runtimeId,
            'profile': 'default',
          });
        }
      });

      test('reads no output while the chat is not attached', () async {
        // An output poll must not resume the chat itself.
        check(await service.subagentTail('local-1', 'sa-1')).isNull();
        check(gateway.calls('session.resume')).isEmpty();
        check(gateway.calls('subagent.tail')).isEmpty();
      });

      test('a gateway without process.list still lists subagents', () async {
        gateway
          ..subagents = [_child('sa-1')]
          ..handler = (method, _) => method == 'process.list'
              ? throw const _Refusal(-32601, 'Method not found')
              : null;
        await open();

        final work = (await service.backgroundWorkFor('local-1'))!;

        check(work.subagents).length.equals(1);
        check(work.processes).isEmpty();
      });

      test('reads, steers and stops a subagent', () async {
        gateway.handler = (method, params) => switch (method) {
          'subagent.tail' => {
            'subagent_id': params['subagent_id'],
            'available': true,
            'text': 'Reading tide tables…',
            'truncated': false,
          },
          'subagent.steer' => {
            'status': params['text'] == 'late' ? 'rejected' : 'queued',
            'subagent_id': params['subagent_id'],
            'text': params['text'],
          },
          'subagent.interrupt' => {
            'found': true,
            'subagent_id': params['subagent_id'],
          },
          _ => null,
        };
        await open();

        final tail = await service.subagentTail('local-1', 'sa-1');
        check(tail?.text).equals('Reading tide tables…');
        check(
          await service.steerSubagent('local-1', 'sa-1', 'Only check May'),
        ).isTrue();
        check(await service.steerSubagent('local-1', 'sa-1', 'late')).isFalse();
        check(await service.stopSubagent('local-1', 'sa-1')).isTrue();

        final scope = {'session_id': gateway.runtimeId, 'profile': 'default'};
        check(
          gateway.calls('subagent.tail').single,
        ).deepEquals({...scope, 'subagent_id': 'sa-1'});
        check(gateway.calls('subagent.steer').first).deepEquals({
          ...scope,
          'subagent_id': 'sa-1',
          'text': 'Only check May',
        });
        check(
          gateway.calls('subagent.interrupt').single,
        ).deepEquals({...scope, 'subagent_id': 'sa-1'});
      });

      test('kills a process, and names one that is gone', () async {
        gateway.handler = (method, params) {
          if (method != 'process.kill') return null;
          if (params['process_id'] == 'proc_gone') {
            throw authority
                ? const _Refusal(4001, 'process_not_found', {
                    'reason': 'process_not_found',
                  })
                : const _Refusal(4044, 'no such process: proc_gone');
          }
          return {
            'status': 'killed',
            'session_id': params['process_id'],
            'output': 'Serving HTTP',
          };
        };
        await open();

        final killed = await service.killBackgroundProcess('local-1', 'proc_a');
        check(killed.status).equals(HermesProcessKillStatus.killed);
        check(killed.output).equals('Serving HTTP');
        check(gateway.calls('process.kill').first).deepEquals({
          'session_id': gateway.runtimeId,
          'profile': 'default',
          'process_id': 'proc_a',
        });
        check(
          (await service.killBackgroundProcess('local-1', 'proc_gone')).status,
        ).equals(HermesProcessKillStatus.notFound);
      });

      test('hints at changes from subagent and process events', () async {
        await open();
        final hints = <String>[];
        final sub = service.backgroundWorkHints.listen(hints.add);
        addTearDown(sub.cancel);

        gateway
          ..event('subagent.start', {'subagent_id': 'sa-1'})
          ..event('tool.complete', {'name': 'terminal'})
          ..event('tool.start', {'name': 'delegate_task'})
          ..event('status.update', {'kind': 'process', 'text': 'done'})
          // Not about background work.
          ..event('tool.complete', {'name': 'read_file'})
          ..event('status.update', {'kind': 'compressing'});
        await _settle();

        check(hints).deepEquals(List.filled(4, 'local-1'));
        check(service.isSameChat('local-1', gateway.runtimeId)).isTrue();
        check(service.isSameChat('local-1', 'local-other')).isFalse();
      });
    });
  }

  group('the open chat\'s background work', () {
    late _Gateway gateway;
    late HermesDesktopApiService service;
    late FakeAppLifecycle lifecycle;
    late ProviderContainer container;

    void start(FakeAsync async) {
      gateway = _Gateway(authority: false);
      service = _service(gateway);
      lifecycle = FakeAppLifecycle();
      unawaited(service.pendingDecisionsForSession('local-1'));
      async.elapse(Duration.zero);
      container = ProviderContainer(
        overrides: [
          hermesApiServiceProvider.overrideWithValue(service),
          activeConversationProvider.overrideWith(_OpenHermesChat.new),
          appLifecycleProvider.overrideWithValue(lifecycle),
        ],
      );
    }

    void stop(FakeAsync async) {
      container.dispose();
      service.close();
      unawaited(gateway.dispose());
      unawaited(lifecycle.dispose());
      async.flushMicrotasks();
    }

    int lists() => gateway.calls('process.list').length;

    test('polls only while work runs or an event suggests it', () {
      fakeAsync((async) {
        start(async);
        gateway.subagents = [_child('sa-1')];
        final seen = <HermesBackgroundWork?>[];
        container.listen(
          hermesBackgroundWorkProvider,
          (_, next) => seen.add(next),
          fireImmediately: true,
        );
        async.elapse(Duration.zero);
        check(lists()).equals(1);
        check(seen.last!.runningSubagents).equals(1);

        async.elapse(kHermesBackgroundWorkPollInterval);
        check(lists()).equals(2);

        // Done: the next list finds nothing and polling stops.
        gateway.subagents = const [];
        async.elapse(kHermesBackgroundWorkPollInterval);
        check(lists()).equals(3);
        check(seen.last!.active).isFalse();
        async.elapse(const Duration(minutes: 1));
        check(lists()).equals(3);

        // A subagent event lists again, and keeps listing for a while.
        gateway.event('subagent.spawn_requested', {'subagent_id': 'sa-2'});
        async.elapse(const Duration(seconds: 1));
        check(lists()).equals(4);
        async.elapse(kHermesBackgroundWorkHintWindow);
        final afterWindow = lists();
        check(afterWindow).isGreaterThan(4);
        async.elapse(const Duration(minutes: 1));
        check(lists()).equals(afterWindow);

        // Another chat's events change nothing here.
        gateway.event('subagent.start', {}, session: 'rt-other');
        async.elapse(const Duration(seconds: 5));
        check(lists()).equals(afterWindow);
        stop(async);
      });
    });

    test('events faster than the debounce do not hold the list back', () {
      fakeAsync((async) {
        start(async);
        gateway.subagents = [_child('sa-1')];
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        async.elapse(Duration.zero);
        final before = lists();

        // A busy subagent reports progress every 100 ms for two seconds.
        for (var tick = 0; tick < 20; tick++) {
          gateway.event('subagent.progress', {'subagent_id': 'sa-1'});
          async.elapse(const Duration(milliseconds: 100));
        }

        check(lists()).isGreaterThan(before + 2);
        stop(async);
      });
    });

    test('pauses in the background and lists again on return', () {
      fakeAsync((async) {
        start(async);
        gateway.processes = [_process('proc_a')];
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        async.elapse(Duration.zero);
        check(lists()).equals(1);

        lifecycle.emit(AppLifecyclePhase.paused);
        async.elapse(const Duration(minutes: 1));
        check(lists()).equals(1);

        lifecycle.emit(AppLifecyclePhase.resumed);
        async.elapse(Duration.zero);
        check(lists()).equals(2);
        stop(async);
      });
    });

    test('lists again once a chat it gave up on attaches', () {
      fakeAsync((async) {
        gateway = _Gateway(authority: false);
        service = _service(gateway);
        lifecycle = FakeAppLifecycle();
        // Not attached: reads find nothing until polling gives up.
        container = ProviderContainer(
          overrides: [
            hermesApiServiceProvider.overrideWithValue(service),
            activeConversationProvider.overrideWith(_OpenHermesChat.new),
            appLifecycleProvider.overrideWithValue(lifecycle),
          ],
        );
        gateway.processes = [_process('proc_a')];
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        async.elapse(const Duration(minutes: 2));
        check(lists()).equals(0);
        check(container.read(hermesBackgroundWorkProvider)).isNull();

        // Sending or reopening reattaches it; no event names the process.
        unawaited(service.pendingDecisionsForSession('local-1'));
        async.elapse(const Duration(seconds: 1));

        check(lists()).equals(1);
        check(
          container.read(hermesBackgroundWorkProvider)!.runningProcesses,
        ).equals(1);
        stop(async);
      });
    });

    // The chat names no session itself: its Hermes turn's session is on its
    // reply, and the chip never showed.
    test('an OpenWebUI chat lists the work of the session it bound', () {
      fakeAsync((async) {
        gateway = _Gateway(authority: false);
        service = _service(gateway);
        lifecycle = FakeAppLifecycle();
        unawaited(service.pendingDecisionsForSession('local-1'));
        async.elapse(Duration.zero);
        container = ProviderContainer(
          overrides: [
            hermesApiServiceProvider.overrideWithValue(service),
            activeConversationProvider.overrideWith(_MixedChat.new),
            chatMessagesProvider.overrideWith(_MixedMessages.new),
            appLifecycleProvider.overrideWithValue(lifecycle),
          ],
        );
        gateway.processes = [_process('proc_a')];
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        async.elapse(Duration.zero);
        // The reply's metadata alone, which the server could have written,
        // names nothing.
        check(lists()).equals(0);

        // This app ran the chat's turn in that session.
        container.read(hermesActiveSessionProvider.notifier).set('local-1');
        async.elapse(Duration.zero);
        check(lists()).equals(1);
        check(
          container.read(hermesBackgroundWorkProvider)!.processes,
        ).length.equals(1);
        stop(async);
      });
    });

    test('stops polling once the chat is closed', () {
      fakeAsync((async) {
        start(async);
        gateway.processes = [_process('proc_a')];
        final sub = container.listen(hermesBackgroundWorkProvider, (_, _) {});
        async.elapse(Duration.zero);
        sub.close();
        async.elapse(const Duration(minutes: 1));
        check(lists()).equals(1);
        stop(async);
      });
    });

    test('a kill lists the work again', () {
      fakeAsync((async) {
        start(async);
        gateway.processes = [_process('proc_a')];
        gateway.handler = (method, params) =>
            method == 'process.kill' ? {'status': 'killed'} : null;
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        async.elapse(Duration.zero);

        gateway.processes = const [];
        HermesProcessKillResult? result;
        container
            .read(hermesBackgroundWorkProvider.notifier)
            .kill('proc_a')
            .then((value) => result = value);
        async.elapse(const Duration(seconds: 1));

        check(result!.status).equals(HermesProcessKillStatus.killed);
        check(lists()).equals(2);
        check(container.read(hermesBackgroundWorkProvider)!.active).isFalse();
        stop(async);
      });
    });

    test('reads a shown subagent\'s output until it finishes', () {
      fakeAsync((async) {
        start(async);
        var reads = 0;
        gateway
          ..subagents = [_child('sa-1')]
          ..handler = (method, params) {
            if (method != 'subagent.tail') return null;
            reads++;
            // Its transcript is cleaned up when it ends.
            return gateway.subagents.isEmpty
                ? {'subagent_id': 'sa-1', 'available': false}
                : {
                    'subagent_id': 'sa-1',
                    'available': true,
                    'text': 'step $reads',
                  };
          };
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        final tail = hermesSubagentTailProvider((
          storedId: 'local-1',
          subagentId: 'sa-1',
        ));
        final sub = container.listen(tail, (_, _) {});
        async.elapse(Duration.zero);
        check(container.read(tail).tail!.text).equals('step 1');

        async.elapse(kHermesSubagentTailPollInterval);
        check(container.read(tail).tail!.text).equals('step 2');

        gateway.subagents = const [];
        async.elapse(kHermesBackgroundWorkPollInterval);
        final finalReads = reads;
        async.elapse(const Duration(minutes: 1));
        check(reads).equals(finalReads);
        // The last output read stays on screen.
        check(container.read(tail).tail!.available).isTrue();

        sub.close();
        stop(async);
      });
    });

    test('reads a finished subagent\'s output once', () {
      fakeAsync((async) {
        start(async);
        var reads = 0;
        gateway
          ..subagents = [_child('sa-1', status: 'completed')]
          ..handler = (method, params) {
            if (method != 'subagent.tail') return null;
            reads++;
            return {'subagent_id': 'sa-1', 'available': true, 'text': 'done'};
          };
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        async.elapse(Duration.zero);
        check(container.read(hermesBackgroundWorkProvider)!.active).isFalse();

        final tail = hermesSubagentTailProvider((
          storedId: 'local-1',
          subagentId: 'sa-1',
        ));
        final sub = container.listen(tail, (_, _) {});
        async.elapse(const Duration(minutes: 1));

        check(reads).equals(1);
        check(container.read(tail).tail!.text).equals('done');
        sub.close();
        stop(async);
      });
    });

    test('a finished subagent\'s output is read again after a failure', () {
      fakeAsync((async) {
        start(async);
        var reads = 0;
        gateway
          ..subagents = [_child('sa-1', status: 'completed')]
          ..handler = (method, params) {
            if (method != 'subagent.tail') return null;
            if (reads++ == 0) throw const _Refusal(5000, 'busy');
            return {'subagent_id': 'sa-1', 'available': true, 'text': 'done'};
          };
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        async.elapse(Duration.zero);

        final tail = hermesSubagentTailProvider((
          storedId: 'local-1',
          subagentId: 'sa-1',
        ));
        final sub = container.listen(tail, (_, _) {});
        async.elapse(const Duration(minutes: 1));

        check(reads).equals(2);
        check(container.read(tail).tail?.text).equals('done');
        sub.close();
        stop(async);
      });
    });

    // Three failed reads on a live socket stopped polling: once Hermes
    // recovered, with no event to say so, the list stayed stale.
    test('keeps listing after failed reads, less often, until one answers',
        () {
      fakeAsync((async) {
        start(async);
        gateway.processes = [_process('proc_a')];
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        async.elapse(Duration.zero);
        check(lists()).equals(1);

        var failing = true;
        gateway.handler = (method, params) =>
            failing && method == 'process.list'
            ? throw const _Refusal(5000, 'busy')
            : null;
        // Three tries at the usual interval, then 8, 16 and 32 seconds,
        // then every minute.
        async.elapse(kHermesBackgroundWorkPollInterval * 3);
        check(lists()).equals(4);
        for (final wait in const [8, 16, 32, 60, 60]) {
          final before = lists();
          async.elapse(Duration(seconds: wait - 1));
          check(lists()).equals(before);
          async.elapse(const Duration(seconds: 1));
          check(lists()).equals(before + 1);
        }
        // The last list stays meanwhile.
        check(
          container.read(hermesBackgroundWorkProvider)!.runningProcesses,
        ).equals(1);

        failing = false;
        gateway.processes = const [];
        async.elapse(kHermesBackgroundWorkMaxRetryInterval);
        check(container.read(hermesBackgroundWorkProvider)!.active).isFalse();
        // Nothing runs any more: polling stops.
        final settled = lists();
        async.elapse(const Duration(minutes: 5));
        check(lists()).equals(settled);
        stop(async);
      });
    });

    test('a turn lists a failing chat again without waiting out the retry',
        () {
      fakeAsync((async) {
        start(async);
        gateway
          ..processes = [_process('proc_a')]
          ..handler = (method, params) => method == 'process.list'
              ? throw const _Refusal(5000, 'busy')
              : null;
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        // Failed reads at 0, 4, 8 and 16 seconds; the next waits until 32.
        async.elapse(const Duration(seconds: 30));
        final before = lists();

        // A turn starts.
        gateway.event('session.info', {'running': true});
        async.elapse(const Duration(seconds: 1));
        check(lists()).equals(before + 1);
        stop(async);
      });
    });

    // Three failed reads stopped a running subagent's output for good:
    // what it showed stayed stale, with no error, once Hermes recovered.
    test('keeps reading a running subagent\'s output after failed reads', () {
      fakeAsync((async) {
        start(async);
        var failing = false;
        var reads = 0;
        gateway
          ..subagents = [_child('sa-1')]
          ..handler = (method, params) {
            if (method != 'subagent.tail') return null;
            reads++;
            if (failing) throw const _Refusal(5000, 'busy');
            return {
              'subagent_id': 'sa-1',
              'available': true,
              'text': 'step $reads',
            };
          };
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        final tail = hermesSubagentTailProvider((
          storedId: 'local-1',
          subagentId: 'sa-1',
        ));
        final sub = container.listen(tail, (_, _) {});
        async.elapse(Duration.zero);
        check(container.read(tail).tail!.text).equals('step 1');

        // Failing reads at 2, 4 and 6 seconds, then after 4, 8, 16, 32
        // and 60 more: by two minutes, seven of them.
        failing = true;
        async.elapse(const Duration(minutes: 2));
        check(reads).equals(8);
        check(container.read(tail).tail!.text).equals('step 1');
        check(container.read(tail).failed).isFalse();

        failing = false;
        async.elapse(kHermesBackgroundWorkMaxRetryInterval);
        check(reads).isGreaterThan(8);
        check(container.read(tail).tail!.text).equals('step $reads');
        sub.close();
        stop(async);
      });
    });

    test('a finished subagent\'s output is not read again after its tries',
        () {
      fakeAsync((async) {
        start(async);
        var reads = 0;
        gateway
          ..subagents = [_child('sa-1', status: 'completed')]
          ..handler = (method, params) {
            if (method != 'subagent.tail') return null;
            reads++;
            throw const _Refusal(5000, 'busy');
          };
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        async.elapse(Duration.zero);

        final tail = hermesSubagentTailProvider((
          storedId: 'local-1',
          subagentId: 'sa-1',
        ));
        final sub = container.listen(tail, (_, _) {});
        async.elapse(const Duration(minutes: 5));

        check(reads).equals(3);
        check(container.read(tail).failed).isTrue();
        sub.close();
        stop(async);
      });
    });

    // Reads that failed while it ran counted against its last read, which
    // then stopped after one try and showed the output as failed.
    test('a subagent that finishes gets its last read\'s full tries', () {
      fakeAsync((async) {
        start(async);
        var failing = 0;
        gateway
          ..subagents = [_child('sa-1')]
          ..handler = (method, params) {
            if (method != 'subagent.tail') return null;
            if (failing > 0) {
              failing--;
              throw const _Refusal(5000, 'busy');
            }
            return {'subagent_id': 'sa-1', 'available': true, 'text': 'done'};
          };
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        final tail = hermesSubagentTailProvider((
          storedId: 'local-1',
          subagentId: 'sa-1',
        ));
        // Reads at 0, 2, 4 and 8 seconds fail while it runs.
        failing = 4;
        final sub = container.listen(tail, (_, _) {});
        async.elapse(const Duration(seconds: 10));
        check(failing).equals(0);
        check(container.read(tail).failed).isTrue();

        // It finishes; its last read fails twice more, then answers.
        failing = 2;
        gateway.subagents = [_child('sa-1', status: 'completed')];
        async.elapse(const Duration(seconds: 30));

        check(failing).equals(0);
        check(container.read(tail).tail?.text).equals('done');
        check(container.read(tail).failed).isFalse();
        sub.close();
        stop(async);
      });
    });

    // Its last read found the chat detached (the socket dropped and came
    // back) and reads stopped: the output never loaded, even once the chat
    // attached again.
    test('a finished subagent\'s output is read once its chat attaches', () {
      fakeAsync((async) {
        start(async);
        var reads = 0;
        gateway
          ..subagents = [_child('sa-1', status: 'completed')]
          ..handler = (method, params) {
            if (method != 'subagent.tail') return null;
            reads++;
            return {'subagent_id': 'sa-1', 'available': true, 'text': 'done'};
          };
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        async.elapse(Duration.zero);
        check(container.read(hermesBackgroundWorkProvider)!.active).isFalse();

        gateway.incoming.addError(StateError('gone'));
        async.elapse(Duration.zero);
        final tail = hermesSubagentTailProvider((
          storedId: 'local-1',
          subagentId: 'sa-1',
        ));
        final sub = container.listen(tail, (_, _) {});
        async.elapse(const Duration(minutes: 1));
        check(reads).equals(0);
        check(container.read(tail).tail).isNull();

        // Sending or reopening reattaches it.
        unawaited(service.pendingDecisionsForSession('local-1'));
        async.elapse(const Duration(seconds: 1));
        check(reads).equals(1);
        check(container.read(tail).tail!.text).equals('done');

        // Read, it is not read again: a later turn says nothing new.
        gateway.event('session.info', {'running': true});
        async.elapse(const Duration(minutes: 1));
        check(reads).equals(1);
        sub.close();
        stop(async);
      });
    });

    test('keeps the newest output when an older read answers last', () {
      fakeAsync((async) {
        start(async);
        gateway
          ..subagents = [_child('sa-1')]
          ..handler = (method, params) => method == 'subagent.tail'
              ? {'subagent_id': 'sa-1', 'available': true, 'text': 'step 1'}
              : null;
        container.listen(hermesBackgroundWorkProvider, (_, _) {});
        final tail = hermesSubagentTailProvider((
          storedId: 'local-1',
          subagentId: 'sa-1',
        ));
        final sub = container.listen(tail, (_, _) {});
        async.elapse(Duration.zero);
        check(container.read(tail).tail!.text).equals('step 1');

        // Hold the next read's answer; a return to the app reads again
        // and that newer read answers first.
        final held = Completer<Object?>();
        var replies = 0;
        gateway.handler = (method, params) {
          if (method != 'subagent.tail') return null;
          replies++;
          return {
            'subagent_id': 'sa-1',
            'available': true,
            'text': replies == 1 ? 'old' : 'new',
          };
        };
        gateway.holdTail = held;
        async.elapse(kHermesSubagentTailPollInterval);
        gateway.holdTail = null;
        lifecycle
          ..emit(AppLifecyclePhase.paused)
          ..emit(AppLifecyclePhase.resumed);
        async.elapse(Duration.zero);
        check(container.read(tail).tail!.text).equals('new');

        held.complete();
        async.elapse(Duration.zero);
        check(container.read(tail).tail!.text).equals('new');
        sub.close();
        stop(async);
      });
    });
  });
}
