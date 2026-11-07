import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
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

/// A gateway's session authority (its Webapp listener): `gateway.ready`
/// says `session_authority: true`, sessions answer with canonical snapshots,
/// and every request is recorded with its params.
final class _Authority {
  _Authority() {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(ready);
      return incoming.stream;
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
      Object? result;
      try {
        result = (handler ?? _answer)(method, params);
      } on _Refusal catch (refusal) {
        scheduleMicrotask(
          () => incoming.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'error': {
                'code': refusal.code,
                'message': refusal.message,
                'data': ?refusal.data,
              },
            }),
          ),
        );
        return;
      }
      if (identical(result, silent)) return;
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
        ),
      );
    });
  }

  static const Object silent = Object();

  final Map<String, Object?> readyPayload = const {'session_authority': true};
  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <Map<String, dynamic>>[];

  /// Answers a request in place of the defaults; null falls back to them.
  Object? Function(String method, Map<String, dynamic> params)? handler;

  int revision = 3;
  int generation = 2;
  List<Map<String, Object?>> prompts = const [];

  Map<String, Object?> snapshot(String id) => {
    'session_id': id,
    'stored_session_id': id,
    'messages': const <Object?>[],
    'message_count': 0,
    'running': false,
    'authority_epoch': 1,
    'replay_epoch': 'epoch-1',
    'last_sequence': 0,
    'subscription_id': 'sub-$id',
    'revision': revision,
    'execution_generation': generation,
    'pending': const <Object?>[],
    'prompts': prompts,
    'info': {'desktop_protocol': kHermesCanonicalGatewayProtocol},
  };

  Object? defaults(String method, Map<String, dynamic> params) =>
      _answer(method, params);

  Object? _answer(String method, Map<String, dynamic> params) {
    final session = params['session_id']?.toString() ?? 'local-1';
    switch (method) {
      case 'client.capabilities':
        return {
          'server_requests': ['approval', 'clarify', 'sudo', 'secret'],
          'declines_not_shown': true,
          'canonical_clarify_batch': true,
        };
      case 'session.create':
        return snapshot('local-1');
      case 'session.resume':
        return snapshot(params['title'] != null ? 'local-bot' : session);
      case 'prompt.submit':
        return {
          'admission_id': 'adm-1',
          'ref': {'session_id': session},
          'status': 'queued',
        };
      case 'config.get':
        return {'value': 'medium'};
      case 'session.mutate':
        revision++;
        return {
          'session_id': session,
          'operation': params['operation'],
          'revision': revision,
          'execution_generation': generation,
          if (params['operation'] == 'branch')
            'branched_session_id': 'local-branch',
        };
    }
    return const <String, Object?>{};
  }

  void ready() {
    if (incoming.isClosed) return;
    incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': readyPayload},
      }),
    );
  }

  void event(
    String type,
    Map<String, Object?> payload, {
    String session = 'local-1',
    int? seq,
    int? generation,
    String? admission,
  }) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': type,
        'session_id': session,
        'payload': payload,
        'replay_epoch': 'epoch-1',
        'seq': ?seq,
        'execution_generation': ?generation,
        'admission_id': ?admission,
      },
    }),
  );

  void serverRequest(String id, String method, Map<String, Object?> params) =>
      incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }),
      );

  List<Map<String, dynamic>> calls(String method) => [
    for (final frame in sent)
      if (frame['method'] == method)
        Map<String, dynamic>.from(frame['params'] as Map),
  ];

  Future<void> dispose() => incoming.close();
}

/// Serves `/api/status` (auth off) and the routes given, recording each
/// request with its Authorization header.
final class _Rest implements HttpClientAdapter {
  _Rest([this.routes = const {}]);

  final Map<String, (int, Object?) Function(RequestOptions)> routes;
  final requests = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${options.method} ${options.uri.path}';
    requests.add(key);
    final route = routes[key];
    final (status, body) =
        route?.call(options) ??
        (options.uri.path == '/api/status'
            ? (200, {'auth_required': false, 'gateway_running': true})
            : (404, {'detail': 'Not Found'}));
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

HermesDesktopApiService _service(
  _Authority gateway, {
  _Rest? rest,
  HermesDesktopAuthKind authKind = HermesDesktopAuthKind.legacyToken,
  List<Duration> retryDelays = const [Duration.zero],
}) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopAuthKind: authKind,
      desktopCredentials: HermesDesktopCredentials(
        legacyToken: 'session-token',
      ),
    ),
    dio: Dio()..httpClientAdapter = rest ?? _Rest(),
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => gateway.channel,
    ),
    gatewayStartRetryDelays: retryDelays,
  );
  addTearDown(() async {
    service.close();
    await gateway.dispose();
  });
  return service;
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  test(
    'creates a GUI session with only the keys the authority takes',
    () async {
      final gateway = _Authority();
      final service = _service(gateway);

      final stored = await service.createDesktopSession(
        title: 'First message',
        options: const HermesDesktopSessionOptions(
          model: 'synthetic-model',
          provider: 'synthetic-provider',
          reasoningEffort: 'low',
          fast: true,
        ),
      );

      check(stored).equals('local-1');
      final create = gateway.calls('session.create').single;
      check(create.keys.toSet()).deepEquals({
        'request_id',
        'source',
        'model',
        'provider',
        'reasoning',
        'service_tier',
        'profile',
      });
      check(create['source']).equals('gui');
      check(create['reasoning']).equals('low');
      check(create['service_tier']).equals('priority');
      check(service.rpc.sessionAuthority).isTrue();
      check(service.desktopContract).equals(2);
      check(service.turnStateFor('local-1'))
          .equals(HermesDesktopTurnState.idle);
    },
  );

  test(
    'a create whose answer was lost is retried as the same request',
    () async {
      final gateway = _Authority();
      var attempts = 0;
      gateway.handler = (method, params) {
        if (method == 'session.create' && attempts++ == 0) {
          // The answer never arrives; the socket drops.
          scheduleMicrotask(
            () => gateway.incoming.addError(StateError('gone')),
          );
          return _Authority.silent;
        }
        return gateway.defaults(method, params);
      };
      final service = _service(gateway);

      await check(service.createDesktopSession()).throws<Object>();
      await service.createDesktopSession();

      final creates = gateway.calls('session.create');
      check(creates).length.equals(2);
      check(creates.last['request_id']).equals(creates.first['request_id']);
    },
  );

  group('a turn', () {
    late _Authority gateway;
    late HermesDesktopApiService service;

    setUp(() async {
      gateway = _Authority();
      service = _service(gateway);
      await service.createDesktopSession();
    });

    Future<List<HermesRunEvent>> stream(
      void Function() frames, {
      HermesChatInput? input,
      CancelToken? cancelToken,
    }) async {
      final response = await service.streamDesktopResponse(
        input ?? HermesChatInput.text('hello'),
        sessionId: 'local-1',
        options: const HermesDesktopSessionOptions(),
        cancelToken: cancelToken,
      );
      final events = response.events.toList();
      await _settle();
      frames();
      return events.timeout(const Duration(seconds: 5));
    }

    test('is submitted with a submission id and ends when idle', () async {
      final events = await stream(() {
        gateway.event('message.start', {}, admission: 'adm-1', generation: 3);
        // Another prompt's turn on the same session is not this reply.
        gateway.event(
          'message.delta',
          {'text': 'Other turn.'},
          admission: 'adm-other',
          seq: 4,
        );
        gateway.event(
          'message.delta',
          {'text': 'Hello there.'},
          admission: 'adm-1',
          seq: 5,
          generation: 3,
        );
        // A replayed frame of the same stream position is shown once.
        gateway.event(
          'message.delta',
          {'text': 'Hello there.'},
          admission: 'adm-1',
          seq: 5,
          generation: 3,
        );
        gateway.event('session.info', {
          'running': false,
        }, admission: 'adm-other');
        gateway.event('message.complete', {
          'text': 'Hello there.',
        }, admission: 'adm-1');
        gateway.event('session.info', {
          'running': false,
          'revision': 4,
          'execution_generation': 3,
        }, admission: 'adm-1');
      });

      final submit = gateway.calls('prompt.submit').single;
      check(submit['submission_id'] as String?).isNotNull().isNotEmpty();
      check(events.whereType<HermesTokenDelta>().map((e) => e.content).join())
          .equals('Hello there.');
      check(events.whereType<HermesRunError>()).isEmpty();
      check(events.last).isA<HermesRunDone>();
    });

    test('a lost submit is sent again under its submission id', () async {
      var submits = 0;
      gateway.handler = (method, params) {
        if (method == 'prompt.submit' && submits++ == 0) {
          scheduleMicrotask(
            () => gateway.incoming.addError(StateError('dropped')),
          );
          return _Authority.silent;
        }
        return gateway.defaults(method, params);
      };
      final events = await stream(() {
        gateway.event('message.start', {}, admission: 'adm-1');
        gateway.event('message.complete', {
          'text': 'Recovered.',
        }, admission: 'adm-1');
        gateway.event('session.info', {'running': false}, admission: 'adm-1');
      });

      final sent = gateway.calls('prompt.submit');
      check(sent).length.equals(2);
      check(sent.last['submission_id']).equals(sent.first['submission_id']);
      check(events.whereType<HermesRunError>()).isEmpty();
      check(events.whereType<HermesFinalOutput>().single.text)
          .equals('Recovered.');
    });

    test('stopping it retires its admission', () async {
      final cancel = CancelToken();
      await stream(() {
        gateway.event('message.start', {}, admission: 'adm-1');
        cancel.cancel();
      }, cancelToken: cancel);

      check(gateway.calls('prompt.cancel').single).deepEquals({
        'profile': 'default',
        'session_id': 'local-1',
        'admission_id': 'adm-1',
      });
      check(gateway.calls('session.interrupt')).isEmpty();
    });

    test('a Stop before the submit is answered cancels only it', () async {
      final cancel = CancelToken();
      gateway.handler = (method, params) {
        // Stop lands while `prompt.submit` is on its way: no admission yet,
        // and another device's turn may be the one running.
        if (method == 'prompt.submit') cancel.cancel();
        return gateway.defaults(method, params);
      };
      await stream(() {}, cancelToken: cancel);
      await _settle();

      check(gateway.calls('session.interrupt')).isEmpty();
      check(gateway.calls('prompt.cancel').single['admission_id'])
          .equals('adm-1');
    });

    test('a queued prompt cancelled elsewhere ends its reply', () async {
      final events = await stream(() {
        // Hermes settles a queued admission with only this completion: no
        // idle follows while the turn ahead of it runs.
        gateway.event('message.complete', {
          'outcome': 'cancelled',
        }, admission: 'adm-1');
      });

      check(events.whereType<HermesRunError>().single.message)
          .contains('cancelled');
      check(events.last).isA<HermesRunDone>();
    });

    test('a reply finished while the socket was down ends on reconnect, '
        'though a later prompt runs', () async {
      var dropped = false;
      gateway.handler = (method, params) {
        if (method == 'session.resume' && dropped) {
          // The prompt queued behind this one runs now.
          return {...gateway.snapshot('local-1'), 'running': true};
        }
        if (method == 'prompt.receipt') {
          return {'admission_id': params['admission_id'], 'status': 'terminal'};
        }
        return gateway.defaults(method, params);
      };
      final events = await stream(() {
        gateway.event('message.start', {}, admission: 'adm-1');
        dropped = true;
        gateway.incoming.addError(StateError('gone'));
      });

      check(gateway.calls('prompt.receipt').single).deepEquals({
        'profile': 'default',
        'session_id': 'local-1',
        'admission_id': 'adm-1',
      });
      check(events.whereType<HermesRunError>()).isEmpty();
      check(events.last).isA<HermesRunDone>();
    });

    test('images are named on the submit and PDFs staged as files', () async {
      gateway.handler = (method, params) => switch (method) {
        'image.attach_bytes' => {
          'attached': true,
          'path': '/staged/upload.png',
          'mime': 'image/png',
        },
        'file.attach' => {
          'attached': true,
          'ref_text': '@file:/staged/${params['name']}',
        },
        _ => gateway.defaults(method, params),
      };
      await stream(
        () {
          gateway.event('message.start', {}, admission: 'adm-1');
          gateway.event('session.info', {'running': false}, admission: 'adm-1');
        },
        input: HermesChatInput.multimodal([
          HermesInputTextPart('look'),
          HermesInputImagePart('data:image/png;base64,AAAA'),
          HermesInputFilePart(
            filename: 'notes.pdf',
            mediaType: 'application/pdf',
            base64Data: 'JVBERi0=',
          ),
        ]),
      );

      check(gateway.calls('pdf.attach')).isEmpty();
      check(gateway.calls('file.attach').single['name']).equals('notes.pdf');
      final submit = gateway.calls('prompt.submit').single;
      check(submit['attachments'] as List).deepEquals([
        {'path': '/staged/upload.png', 'mime': 'image/png'},
      ]);
      check(submit['text'] as String).contains('@file:/staged/notes.pdf');
      check(gateway.calls('image.detach')).isEmpty();
    });

    test('a slash /model is a session edit', () async {
      final events = await stream(
        () {},
        input: HermesChatInput.text('/model synthetic-model'),
      );

      final edit = gateway.calls('session.mutate').single;
      check(edit['operation']).equals('model');
      check(edit['payload'] as Map).deepEquals({'model': 'synthetic-model'});
      check(edit['expected_revision']).equals(3);
      check(edit['expected_generation']).equals(2);
      check(gateway.calls('slash.exec')).isEmpty();
      check(events.whereType<HermesFinalOutput>().single.text)
          .startsWith('model: ');
    });

    test('a lost slash edit is not sent as a prompt', () async {
      gateway.handler = (method, params) {
        if (method == 'session.mutate') {
          scheduleMicrotask(
            () => gateway.incoming.addError(StateError('gone')),
          );
          return _Authority.silent;
        }
        return gateway.defaults(method, params);
      };
      final events = await stream(
        () {},
        input: HermesChatInput.text('/model synthetic-model'),
      );

      check(events.whereType<HermesRunError>()).isNotEmpty();
      check(gateway.calls('prompt.submit')).isEmpty();
    });
  });

  test('a recovered turn is stopped at its generation, read again once '
      'when Hermes moved on', () async {
    final gateway = _Authority();
    var interrupts = 0;
    gateway.handler = (method, params) {
      if (method == 'session.interrupt' && interrupts++ == 0) {
        gateway.generation = 5;
        throw const _Refusal(4001, 'stale_generation', {
          'reason': 'stale_generation',
        });
      }
      return gateway.defaults(method, params);
    };
    final service = _service(gateway);
    await service.createDesktopSession();
    gateway.event('message.start', {}, generation: 4, admission: 'adm-9');
    await _settle();

    await service.interrupt('local-1');

    final sent = gateway.calls('session.interrupt');
    check(sent.map((params) => params['execution_generation']))
        .deepEquals([4, 5]);
  });

  test(
    'steers at the turn\'s generation; an undelivered steer is queued',
    () async {
      final gateway = _Authority();
      gateway.handler = (method, params) => switch (method) {
        'session.steer' => throw const _Refusal(4001, 'execution_not_ready', {
          'reason': 'execution_not_ready',
        }),
        _ => gateway.defaults(method, params),
      };
      final service = _service(
        gateway,
        rest: _Rest({
          'GET /api/sessions/local-1/messages': (_) => (200, {'messages': []}),
        }),
      );
      await service.createDesktopSession();

      check(await service.steer('local-1', 'be brief')).isFalse();

      check(gateway.calls('session.steer').single['execution_generation'])
          .equals(2);
      final queued = gateway.calls('prompt.submit').single;
      check(queued['queued']).equals(true);
      check(queued['text']).equals('be brief');
      check(queued['submission_id'] as String?).isNotNull().isNotEmpty();
    },
  );

  test('renames, branches and switches models as fenced edits', () async {
    final gateway = _Authority();
    var conflicted = false;
    gateway.handler = (method, params) {
      if (method == 'session.mutate' &&
          params['operation'] == 'rename' &&
          !conflicted) {
        conflicted = true;
        // A turn moved the revision on; the refusal names the new one.
        throw const _Refusal(4001, 'revision_conflict', {
          'reason': 'revision_conflict',
          'revision': 7,
          'execution_generation': 2,
        });
      }
      return gateway.defaults(method, params);
    };
    final service = _service(gateway);
    await service.createDesktopSession();

    await service.renameSession('local-1', 'Renamed');
    final renames = gateway.calls('session.mutate');
    check(renames.map((p) => p['expected_revision'])).deepEquals([3, 7]);
    check(renames.last['payload'] as Map).deepEquals({'title': 'Renamed'});
    check(renames.last.containsKey('expected_generation')).isFalse();
    check(renames.last['request_id'])
        .not((it) => it.equals(renames.first['request_id']));

    final branch = await service.forkSession('local-1');
    check(branch).equals('local-branch');
    final branchEdit = gateway.calls('session.mutate').last;
    check(branchEdit['operation']).equals('branch');
    check(branchEdit['expected_generation']).equals(2);

    final response = await service.streamDesktopResponse(
      HermesChatInput.text('switch'),
      sessionId: 'local-1',
      options: const HermesDesktopSessionOptions(
        model: 'other-model',
        provider: 'synthetic-provider',
      ),
    );
    final events = response.events.toList();
    await _settle();
    gateway.event('message.start', {}, admission: 'adm-1');
    gateway.event('session.info', {'running': false}, admission: 'adm-1');
    await events.timeout(const Duration(seconds: 5));
    final model = gateway.calls('session.mutate').last;
    check(model['operation']).equals('model');
    check(model['payload'] as Map)
        .deepEquals({'model': 'other-model', 'provider': 'synthetic-provider'});
    check(
      gateway.calls('config.set').where((params) => params['key'] == 'model'),
    ).isEmpty();
    check(gateway.calls('session.title')).isEmpty();
  });

  test('a model switch held for a confirmation sends nothing', () async {
    final gateway = _Authority();
    gateway.handler = (method, params) {
      if (method == 'session.mutate' && params['operation'] == 'model') {
        // The owner wrote nothing: the chat is still on its old model.
        return {
          'session_id': params['session_id'],
          'operation': 'model',
          'status': 'confirmation_required',
          'confirm': 'confirm-token-1',
          'confirm_message': 'This model costs more per message.',
          'revision': gateway.revision,
          'execution_generation': gateway.generation,
        };
      }
      return gateway.defaults(method, params);
    };
    final service = _service(gateway);
    await service.createDesktopSession();
    Future<HermesResponseStream> send() => service.streamDesktopResponse(
      HermesChatInput.text('hello'),
      sessionId: 'local-1',
      options: const HermesDesktopSessionOptions(model: 'pricier-model'),
    );

    await check(send()).throws<HermesModelSwitchHeld>(
      (it) => it.has((error) => error.message, 'message')
        ..contains('pricier-model')
        ..contains('This model costs more per message.'),
    );
    // Not taken as applied: the next send asks again.
    await check(send()).throws<HermesModelSwitchHeld>();

    check(gateway.calls('prompt.submit')).isEmpty();
    check(
      gateway.calls('session.mutate').where(
        (params) => params['operation'] == 'model',
      ),
    ).length.equals(2);
  });

  test('deleting a chat detaches from it instead of closing it', () async {
    final gateway = _Authority();
    final rest = _Rest({
      'GET /api/sessions/local-1/mutation-snapshot': (_) => (
        200,
        {
          'session_id': 'local-1',
          'exists': true,
          'runtime_revision': 3,
          'runtime_generation': 2,
        },
      ),
      'DELETE /api/sessions/local-1': (_) => (200, {'ok': true}),
    });
    final service = _service(gateway, rest: rest);
    await service.createDesktopSession();

    await service.deleteSession('local-1');

    check(gateway.calls('session.close')).isEmpty();
    check(gateway.calls('session.detach').single).deepEquals({
      'profile': 'default',
      'session_id': 'local-1',
      'subscription_id': 'sub-local-1',
    });
    check(rest.requests).contains('DELETE /api/sessions/local-1');
  });

  test('a lost edit is retried only until another edit is made', () async {
    final gateway = _Authority();
    var lose = true;
    gateway.handler = (method, params) {
      if (method == 'session.mutate' && lose) {
        lose = false;
        scheduleMicrotask(() => gateway.incoming.addError(StateError('gone')));
        return _Authority.silent;
      }
      return gateway.defaults(method, params);
    };
    final service = _service(gateway);
    await service.createDesktopSession();

    await check(service.renameSession('local-1', 'Alpha')).throws<Object>();
    await service.renameSession('local-1', 'Beta');
    await service.renameSession('local-1', 'Alpha');
    lose = true;
    await check(service.renameSession('local-1', 'Gamma')).throws<Object>();
    await service.renameSession('local-1', 'Gamma');

    final ids = [
      for (final edit in gateway.calls('session.mutate')) edit['request_id'],
    ];
    check(ids).length.equals(5);
    // After Beta, Alpha again is new work, not the lost request ...
    check(ids[2]).not((it) => it.equals(ids[0]));
    // ... while a retry right after a loss is the same request.
    check(ids[4]).equals(ids[3]);
  });

  test('a chat left before a failed delete is attached again', () async {
    final gateway = _Authority();
    final rest = _Rest({
      'GET /api/sessions/local-1/mutation-snapshot': (_) => (
        200,
        {
          'session_id': 'local-1',
          'exists': true,
          'runtime_revision': 3,
          'runtime_generation': 2,
        },
      ),
      'DELETE /api/sessions/local-1': (_) => (500, {'detail': 'busy'}),
    });
    final service = _service(gateway, rest: rest);
    await service.createDesktopSession();

    await check(service.deleteSession('local-1')).throws<Object>();
    check(gateway.calls('session.detach')).length.equals(1);
    final resumes = gateway.calls('session.resume').length;
    await service.renameSession('local-1', 'Kept');

    check(gateway.calls('session.resume')).length.equals(resumes + 1);
  });

  test('a chat whose detach failed is attached again after a failed delete',
      () async {
    final gateway = _Authority();
    gateway.handler = (method, params) {
      // Hermes may have dropped the subscription before this answer.
      if (method == 'session.detach') {
        throw const _Refusal(5000, 'timeout');
      }
      return gateway.defaults(method, params);
    };
    final rest = _Rest({
      'GET /api/sessions/local-1/mutation-snapshot': (_) => (
        200,
        {
          'session_id': 'local-1',
          'exists': true,
          'runtime_revision': 3,
          'runtime_generation': 2,
        },
      ),
      'DELETE /api/sessions/local-1': (_) => (500, {'detail': 'busy'}),
    });
    final service = _service(gateway, rest: rest);
    await service.createDesktopSession();

    await check(service.deleteSession('local-1')).throws<Object>();
    final resumes = gateway.calls('session.resume').length;
    await service.renameSession('local-1', 'Kept');

    check(gateway.calls('session.resume')).length.equals(resumes + 1);
  });

  group('decisions', () {
    test('answers an approval by its prompt and generation', () async {
      final gateway = _Authority();
      final service = _service(gateway);
      await service.createDesktopSession();
      gateway.event('approval.request', {
        'kind': 'approval',
        'prompt_id': 'prompt-a',
        'execution_generation': 2,
        'command': 'rm -rf build',
        'choices': ['once', 'deny', 'session', 'always'],
      }, seq: 9);
      await _settle();

      await service.resolveApprovalChoiceForSession(
        'local-1',
        approvalId: 'prompt-a',
        choice: 'once',
      );

      check(gateway.calls('approval.respond').single).deepEquals({
        'profile': 'default',
        'session_id': 'local-1',
        'execution_generation': 2,
        'prompt_id': 'prompt-a',
        'choice': 'once',
      });
      check(gateway.calls('request.answer')).isEmpty();
    });

    test('a question listed only by a snapshot is answered too', () async {
      final gateway = _Authority()
        ..prompts = [
          {
            'kind': 'clarify',
            'prompt_id': 'prompt-q',
            'execution_generation': 2,
            'question': 'Which colour?',
            'choices': ['Teal', 'Amber'],
            'multi_select': false,
          },
        ];
      final service = _service(gateway);
      final shown = <HermesDesktopEvent>[];
      service.rpc.events.listen(shown.add);

      await service.pendingDecisionsForSession('local-1');
      await _settle();
      final card = shown.singleWhere((e) => e.type == 'clarify.request');
      check(card.payload['request_id']).equals('prompt-q');
      check(card.payload['question']).equals('Which colour?');
      await service.respondToDecision(
        runtimeId: 'local-1',
        storedSessionId: 'local-1',
        requestId: 'prompt-q',
        kind: HermesDecisionKind.clarification,
        value: 'Amber',
      );

      check(gateway.calls('clarify.respond').single).deepEquals({
        'profile': 'default',
        'session_id': 'local-1',
        'execution_generation': 2,
        'prompt_id': 'prompt-q',
        'answer': 'Amber',
      });
      check(gateway.calls('clarify.lock')).isEmpty();
    });

    test('answers a password request with its response frame', () async {
      final gateway = _Authority();
      final service = _service(gateway);
      await service.createDesktopSession();
      gateway.serverRequest('srq-s1', 'sudo', {
        'session_id': 'local-1',
        'command': 'apt update',
      });
      await _settle();

      await service.respondToDecision(
        runtimeId: 'local-1',
        storedSessionId: 'local-1',
        requestId: 'srq-s1',
        kind: HermesDecisionKind.sudo,
        value: 'synthetic-password',
      );

      check(gateway.sent.last).deepEquals({
        'jsonrpc': '2.0',
        'id': 'srq-s1',
        'result': {'value': 'synthetic-password'},
      });
      check(gateway.calls('request.answer')).isEmpty();
    });

    test('a password the socket could not send is not reported', () async {
      final gateway = _Authority();
      final service = _service(gateway);
      await service.createDesktopSession();
      gateway.serverRequest('srq-s2', 'sudo', {
        'session_id': 'local-1',
        'command': 'apt update',
      });
      await _settle();
      // The socket drops and comes back; it drops again right after the
      // resume that re-attaches the chat answers.
      gateway.incoming.addError(StateError('gone'));
      await _settle();
      gateway.handler = (method, params) {
        if (method == 'session.resume') {
          // One hop later than the reply, so the resume itself succeeds.
          scheduleMicrotask(
            () => scheduleMicrotask(
              () => gateway.incoming.addError(StateError('gone again')),
            ),
          );
        }
        return gateway.defaults(method, params);
      };

      await check(
        service.respondToDecision(
          runtimeId: 'local-1',
          storedSessionId: 'local-1',
          requestId: 'srq-s2',
          kind: HermesDecisionKind.sudo,
          value: 'synthetic-password',
        ),
      ).throws<StateError>();
      check(gateway.sent.where((frame) => frame['id'] == 'srq-s2')).isEmpty();
    });

    test('one settled while the socket was down closes on resume', () async {
      final gateway = _Authority();
      final service = _service(gateway);
      final shown = <HermesDesktopEvent>[];
      service.rpc.events.listen(shown.add);
      await service.createDesktopSession();
      gateway.event('approval.request', {
        'kind': 'approval',
        'prompt_id': 'prompt-b',
        'execution_generation': 2,
        'command': 'rm -rf build',
        'choices': ['once', 'deny'],
      }, seq: 4);
      await _settle();
      check(
        (await service.pendingDecisionsForSession('local-1')).map(
          (decision) => decision.requestId,
        ),
      ).deepEquals(['prompt-b']);

      // Answered on another device while this socket was down.
      gateway.incoming.addError(StateError('gone'));
      await _settle();
      final pending = await service.pendingDecisionsForSession('local-1');
      await _settle();

      check(pending).isEmpty();
      check(
        shown.where((e) => e.type == 'approval.expire').map(
          (e) => e.payload['request_id'],
        ),
      ).deepEquals(['prompt-b']);
    });

    test('one settled while the app was closed is not shown again', () async {
      final first = _Authority();
      final before = _service(first);
      await before.createDesktopSession();
      first.event('approval.request', {
        'kind': 'approval',
        'prompt_id': 'prompt-c',
        'execution_generation': 2,
        'command': 'rm -rf build',
        'choices': ['once', 'deny'],
      }, seq: 4);
      await _settle();
      check(await before.pendingDecisionsForSession('local-1')).length
          .equals(1);
      before.close();

      // A new start: the snapshot no longer lists the approval.
      final after = _service(_Authority());

      check(await after.pendingDecisionsForSession('local-1')).isEmpty();
    });

    test('one settled while its snapshot was read is not shown', () async {
      final gateway = _Authority()
        ..prompts = [
          {
            'kind': 'clarify',
            'prompt_id': 'prompt-s',
            'execution_generation': 2,
            'question': 'Which colour?',
            'choices': ['Teal', 'Amber'],
            'multi_select': false,
          },
        ];
      gateway.handler = (method, params) {
        if (method == 'session.resume') {
          // Answered on another device while the snapshot was read: the
          // snapshot still lists it.
          gateway.event('clarify.settled', {'prompt_id': 'prompt-s'});
        }
        return gateway.defaults(method, params);
      };
      final service = _service(gateway);
      final shown = <HermesDesktopEvent>[];
      service.rpc.events.listen(shown.add);

      final pending = await service.pendingDecisionsForSession('local-1');
      await _settle();

      check(pending).isEmpty();
      check(shown.where((e) => e.type == 'clarify.request')).isEmpty();
    });

    test('a snapshot past the replay bound keeps every listed one', () async {
      final gateway = _Authority();
      final service = _service(gateway);
      final shown = <HermesDesktopEvent>[];
      service.rpc.events.listen(shown.add);
      await service.createDesktopSession();
      Map<String, Object?> approval(int n) => {
        'kind': 'approval',
        'prompt_id': 'prompt-$n',
        'execution_generation': 2,
        'command': 'make step-$n',
        'choices': ['once', 'deny'],
      };
      gateway.event('approval.request', approval(33), seq: 4);
      await _settle();
      // Thirty-three open: the one asked live is listed last.
      gateway.prompts = [for (var n = 1; n <= 33; n++) approval(n)];

      gateway.incoming.addError(StateError('gone'));
      await _settle();
      final pending = await service.pendingDecisionsForSession('local-1');
      await _settle();

      check(
        shown.where((e) => e.type == 'approval.expire').map(
          (e) => e.payload['request_id'],
        ),
      ).isEmpty();
      check(pending.map((decision) => decision.requestId)).contains(
        'prompt-33',
      );
    });
  });

  test('a bot chat is looked up by its title', () async {
    final gateway = _Authority();
    final service = _service(gateway);

    final stored = await service.openBotChat(
      const HermesBot(name: 'default', title: 'Synthetic bot'),
    );

    check(stored).equals('local-bot');
    final resume = gateway.calls('session.resume').single;
    check(resume['title']).equals('Bot Chat');
    check(resume.containsKey('session_id')).isFalse();
  });

  group('a gateway that is starting', () {
    test('is tried again until it is ready', () async {
      var probes = 0;
      final gateway = _Authority();
      final service = _service(
        gateway,
        rest: _Rest({
          'GET /api/status': (_) => probes++ == 0
              ? (503, {'error': 'gateway_not_ready', 'state': 'starting'})
              : (200, {'auth_required': false}),
        }),
      );

      check(await service.createDesktopSession()).equals('local-1');
      check(probes).isGreaterOrEqual(2);
    });

    test('is reported as starting, not as a sign-in failure', () async {
      final gateway = _Authority();
      final service = _service(
        gateway,
        retryDelays: const [Duration.zero, Duration.zero],
        rest: _Rest({
          'GET /api/status': (_) =>
              (503, {'error': 'gateway_not_ready', 'state': 'draining'}),
        }),
      );

      await check(service.createDesktopSession())
          .throws<HermesDesktopGatewayStartingException>();
    });
  });

  test('the status screen reads the signed-in status', () async {
    final gateway = _Authority();
    final service = _service(
      gateway,
      rest: _Rest({
        'GET /api/status': (options) =>
            options.headers['Authorization'] == 'Bearer session-token'
            ? (
                200,
                {
                  'auth_required': true,
                  'version': '0.23.0',
                  'active_sessions': 2,
                },
              )
            : (
                200,
                {
                  'auth_required': true,
                  'version': '0.23.0',
                  'auth_providers': ['session-token'],
                },
              ),
      }),
    );

    final status = await service.healthDetailed();

    check(status['active_sessions']).equals(2);
  });

  test('skills are rescanned for an open chat', () async {
    final gateway = _Authority();
    final service = _service(gateway);

    await service.reloadSkills();
    check(gateway.calls('skills.reload')).isEmpty();

    await service.createDesktopSession();
    await service.reloadSkills();
    check(gateway.calls('skills.reload').single)
        .deepEquals({'profile': 'default', 'session_id': 'local-1'});
  });

  test('installed skills are listed from their categories', () async {
    final gateway = _Authority();
    gateway.handler = (method, params) => switch (method) {
      'skills.manage' => {
        'skills': {
          'notes': ['apple-notes', 'obsidian'],
          'media': ['youtube-content'],
        },
      },
      'commands.catalog' => {
        'pairs': [
          ['/obsidian', 'Work with an Obsidian vault'],
        ],
      },
      _ => gateway.defaults(method, params),
    };
    final service = _service(gateway);

    final skills = await service.listSkills();

    check(skills.map((skill) => skill['name']))
        .deepEquals(['apple-notes', 'obsidian', 'youtube-content']);
    check(skills[1]['description']).equals('Work with an Obsidian vault');
  });
}
