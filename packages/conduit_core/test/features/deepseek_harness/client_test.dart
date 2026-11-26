import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/deepseek_harness/deepseek_harness.dart';
import 'package:conduit_core/features/deepseek_harness/deepseek_harness_client.dart';
import 'package:test/test.dart';

class _Grant implements DeepSeekHarnessConnection {
  _Grant(this.root);
  @override
  final Uri root;
  @override
  bool isExpired = false;
  @override
  String get cookieName => 'dsh-auth-synthetic';
  @override
  String get cookieValue => 'fixture';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late HttpServer server;
  late _Grant grant;
  late DeepSeekHarnessClient client;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    grant = _Grant(Uri.parse('http://127.0.0.1:${server.port}/garden/'));
    client = DeepSeekHarnessClient(grant);
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
  });

  test(
    'uses correlated, authenticated unary calls for each native action',
    () async {
      final methods = <String>[];
      server.listen((req) async {
        expect(
          req.headers.value(HttpHeaders.cookieHeader),
          '${grant.cookieName}=${grant.cookieValue}',
        );
        expect(req.headers.value('Origin'), grant.root.origin);
        final body = jsonDecode(
          await req.cast<List<int>>().transform(utf8.decoder).join(),
        ) as Map;
        final method = body['method'] as String;
        expect(req.uri.path, '/garden/api/$method');
        expect(body['type'], 'client-request');
        methods.add(method);
        final args = body['payload']['args'] as Map;
        final request = args['request'];
        final Map value;
        switch (method) {
          case 'session/list':
            expect(args, {'_request': {}});
            value = {
              'items': [
                {
                  'sessionId': 'session',
                  'running': false,
                  'projections': {
                    'values': {'title': 'Garden'},
                  },
                },
              ],
            };
          case 'session/modelCatalog':
            value = {
              'groups': [
                {
                  'id': 'greenhouse',
                  'models': [
                    {'id': 'field', 'name': 'Field'},
                  ],
                },
              ],
            };
          case 'session/create':
            expect(request, {'workspaceId': 'workspace'});
            value = {'sessionId': 'new'};
          case 'session/selectModel':
            expect(request, {
              'sessionId': 'new',
              'provider': 'greenhouse',
              'model': 'field',
            });
            value = {
              'selected': {'provider': 'greenhouse', 'model': 'field'},
            };
          case 'session/prompt':
            expect(request['requestId'], isNotEmpty);
            expect(request['mode'], 'queue');
            expect(request['content'], [
              {'type': 'text', 'text': 'Label the pots.'},
            ]);
            value = {'accepted': true};
          case 'session/cancel':
            expect(request, {'sessionId': 'new'});
            value = {'accepted': true};
          default:
            throw StateError('Unexpected call');
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'type': 'server-response',
            'rpcId': body['rpcId'],
            'result': {'ok': true, 'value': value},
          }),
        );
        await req.response.close();
      });
      expect((await client.listSessions()).single.title, 'Garden');
      final model = (await client.listModels()).single;
      final id = await client.createSession(workspaceId: 'workspace');
      await client.selectModel(id, model);
      await client.send(id, 'Label the pots.');
      await client.interrupt(id);
      expect(methods, [
        'session/list',
        'session/modelCatalog',
        'session/create',
        'session/selectModel',
        'session/prompt',
        'session/cancel',
      ]);
    },
  );

  test(
    'restores history, streams text, and leaves approvals for the user',
    () async {
      final closed = Completer<void>();
      final methods = <String>[];
      server.listen((req) async {
        expect(req.uri.path, '/garden/api/remote.mux');
        expect(req.headers.value('Origin'), grant.root.origin);
        expect(
          req.headers.value(HttpHeaders.cookieHeader),
          '${grant.cookieName}=${grant.cookieValue}',
        );
        final ws = await WebSocketTransformer.upgrade(req);
        void item(String streamId, Map value) => ws.add(
          jsonEncode({'type': 'item', 'streamId': streamId, 'value': value}),
        );
        await for (final raw in ws) {
          final frame = jsonDecode(raw as String) as Map;
          expect(frame['type'], 'open');
          final endpoint = frame['endpoint'] as String;
          methods.add(endpoint);
          final id = frame['streamId'] as String;
          switch (endpoint) {
            case 'session/follow':
              expect(frame['payload']['args']['request']['maxMessages'], 6);
              item(id, {
                'type': 'snapshot',
                'header': {'id': 'session'},
                'hasMore': true,
                'records': [
                  {
                    'type': 'event',
                    'event': {
                      'seq': 1,
                      'type': 'user/message',
                      'surfaceOp': 'append',
                      'data': {
                        'source': {'kind': 'user'},
                        'content': [
                          {'type': 'text', 'text': 'Seeds'},
                        ],
                      },
                    },
                  },
                  {
                    'type': 'event',
                    'event': {
                      'seq': 2,
                      'type': 'user/message',
                      'surfaceOp': {
                        'op': 'replace',
                        'startSeq': 1,
                        'endSeq': 1,
                      },
                      'data': {
                        'source': {'kind': 'compact-checkpoint'},
                        'content': [
                          {'type': 'text', 'text': 'Short model summary'},
                        ],
                      },
                    },
                  },
                  {
                    'type': 'event',
                    'event': {
                      'seq': 3,
                      'type': 'user/message',
                      'surfaceOp': 'append',
                      'data': {
                        'source': {'kind': 'model-selection'},
                        'content': [
                          {'type': 'text', 'text': 'Model context notice'},
                        ],
                      },
                    },
                  },
                ],
                'projections': {
                  'values': {
                    'title': 'Seed trays',
                    'modelSelection': {
                      'next': {'provider': 'seed', 'model': 'small'},
                    },
                  },
                },
                'assistantStream': {
                  'revision': 4,
                  'activeAttempt': {
                    'attemptId': 'a',
                    'nextIndex': 1,
                    'stream': [
                      {
                        'type': 'text-chunks',
                        'texts': ['Green'],
                      },
                    ],
                  },
                },
              });
              item(id, {
                'type': 'assistant-stream',
                'frame': {
                  'type': 'chunk',
                  'attemptId': 'a',
                  'revision': 5,
                  'index': 1,
                  'chunk': {'type': 'text-delta', 'text': ' leaves'},
                },
              });
            case 'session/observeState':
              item(id, {'running': true, 'pendingInput': []});
            case r'$events':
              item(id, {'type': 'ready', 'clientId': 'reader', 'host': {}});
              item(id, {
                'type': 'waterfall',
                'agentId': 'other-session',
                'eventId': 'unrelated',
              });
              item(id, {
                'type': 'waterfall',
                'agentId': 'session',
                'eventId': 'decision',
                'event': 'approval/request',
              });
              item(id, {'type': 'cancel', 'eventId': 'decision'});
              item('journal', {
                'type': 'event',
                'event': {
                  'seq': 4,
                  'type': 'assistant/message',
                  'surfaceOp': 'append',
                  'data': {
                    'message': {
                      'content': [
                        {'type': 'text', 'text': 'Green leaves'},
                      ],
                    },
                  },
                },
              });
              item('journal', {
                'type': 'assistant-stream',
                'frame': {
                  'type': 'end',
                  'attemptId': 'a',
                  'revision': 6,
                  'index': 2,
                },
              });
              item('journal', {
                'type': 'event',
                'event': {
                  'seq': 5,
                  'type': 'session/title',
                  'data': {'title': 'Seedling leaves'},
                },
              });
              item('journal', {
                'type': 'event',
                'event': {
                  'seq': 6,
                  'type': 'model/selection',
                  'data': {'provider': 'seed', 'model': 'large'},
                },
              });
              item('state', {'running': false, 'pendingInput': []});
          }
        }
        closed.complete();
      });
      final frames = <HarnessTranscript>[];
      await for (final page in client.follow('session', maxMessages: 6)) {
        frames.add(page);
        if (frames.any((p) => p.running) &&
            !page.running &&
            page.messages.last.text == 'Green leaves') {
          break;
        }
      }
      await closed.future;
      expect(methods, ['session/follow', 'session/observeState', r'$events']);
      expect(frames.first.messages.map((m) => m.text), ['Seeds', 'Green']);
      expect(frames.first.hasMore, true);
      expect(frames.first.title, 'Seed trays');
      expect(frames.first.modelId, 'small');
      expect(frames.last.title, 'Seedling leaves');
      expect(frames.last.modelId, 'large');
      expect(
        frames.any(
          (p) =>
              p.messages.last.streaming &&
              p.messages.last.text == 'Green leaves',
        ),
        true,
      );
      expect(frames.where((p) => p.hasPendingRequest), hasLength(1));
      expect(frames.last.needsWorkspace, false);
      expect(frames.last.messages.map((m) => m.text), [
        'Seeds',
        'Green leaves',
      ]);
    },
  );

  test('keeps the cookie on its origin and reports a revoked grant', () async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => other.close(force: true));
    var forwarded = 0, calls = 0;
    other.listen((r) async {
      forwarded++;
      await r.response.close();
    });
    server.listen((req) async {
      calls++;
      if (calls == 1) {
        req.response.statusCode = HttpStatus.temporaryRedirect;
        req.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${other.port}/',
        );
      } else {
        req.response.statusCode = HttpStatus.unauthorized;
      }
      await req.response.close();
    });
    await expectLater(
      client.listModels(),
      throwsA(isA<DeepSeekHarnessException>()),
    );
    await expectLater(
      client.listSessions(),
      throwsA(
        isA<DeepSeekHarnessException>().having(
          (e) => e.reason,
          'reason',
          DeepSeekHarnessFailure.unauthorized,
        ),
      ),
    );
    expect(forwarded, 0);
    grant.isExpired = true;
    await expectLater(
      client.listSessions(),
      throwsA(isA<DeepSeekHarnessException>()),
    );
    expect(calls, 2);
  });
  for (final (status, reason) in [
    (HttpStatus.unauthorized, DeepSeekHarnessFailure.unauthorized),
    (HttpStatus.forbidden, DeepSeekHarnessFailure.untrustedHost),
  ]) {
    test('reports HTTP $status on a refused stream handshake', () async {
      server.listen((req) async {
        req.response.statusCode = status;
        await req.response.close();
      });
      await expectLater(
        client.follow('session').first,
        throwsA(
          isA<DeepSeekHarnessException>().having(
            (e) => e.reason,
            'reason',
            reason,
          ),
        ),
      );
    });
  }
  test(
    'a provider failure survives reopening and a later turn clears it',
    () async {
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        await for (final raw in ws) {
          final frame = jsonDecode(raw as String) as Map;
          if (frame['streamId'] != 'journal') continue;
          for (final value in [
            {
              'type': 'snapshot',
              'header': {'id': 'session'},
              'records': [
                {
                  'type': 'event',
                  'event': {
                    'seq': 1,
                    'type': 'turn/end',
                    'data': {
                      'reason': {
                        'kind': 'error',
                        'error': {'message': 'Synthetic provider unavailable'},
                      },
                    },
                  },
                },
              ],
              'assistantStream': {'revision': 0},
            },
            {
              'type': 'event',
              'event': {
                'seq': 2,
                'type': 'turn/start',
                'data': {'turn': 2},
              },
            },
          ]) {
            ws.add(
              jsonEncode({
                'type': 'item',
                'streamId': 'journal',
                'value': value,
              }),
            );
          }
        }
      });
      final pages = await client.follow('session').take(2).toList();
      expect(pages.first.lastTurnFailed, true);
      expect(pages.first.needsWorkspace, true);
      expect(pages.first.hasPendingRequest, false);
      expect(pages.first.messages, isEmpty);
      expect(pages.last.lastTurnFailed, false);
      expect(pages.last.running, true);
    },
  );

  test('a missing stream revision closes all logical subscriptions', () async {
    final closed = Completer<void>();
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      await for (final raw in ws) {
        final frame = jsonDecode(raw as String) as Map;
        if (frame['streamId'] != 'journal') continue;
        for (final value in [
          {
            'type': 'snapshot',
            'header': {'id': 'session'},
            'records': [],
            'assistantStream': {'revision': 1},
          },
          {
            'type': 'assistant-stream',
            'frame': {'type': 'start', 'revision': 3, 'attemptId': 'a'},
          },
        ]) {
          ws.add(
            jsonEncode({'type': 'item', 'streamId': 'journal', 'value': value}),
          );
        }
      }
      closed.complete();
    });
    await expectLater(
      client.follow('session'),
      emitsInOrder([
        isA<HarnessTranscript>(),
        emitsError(
          isA<DeepSeekHarnessException>().having(
            (e) => e.reason,
            'reason',
            DeepSeekHarnessFailure.invalidResponse,
          ),
        ),
        emitsDone,
      ]),
    );
    await closed.future;
  });
}
