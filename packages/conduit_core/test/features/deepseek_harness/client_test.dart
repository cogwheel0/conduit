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
      final acceptedPrompts = <String>{};
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
            if (acceptedPrompts.add(request['requestId'] as String) &&
                acceptedPrompts.length == 1) {
              // Accepted by the agent, but the response does not arrive.
              req.response.statusCode = HttpStatus.badGateway;
              await req.response.close();
              return;
            }
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
      await expectLater(
        client.send(id, 'Label the pots.', requestId: 'one'),
        throwsA(isA<DeepSeekHarnessException>()),
      );
      await client.send(id, 'Label the pots.', requestId: 'one');
      await client.send(id, 'Label the pots.', requestId: 'two');
      expect(acceptedPrompts, {'one', 'two'});
      await client.interrupt(id);
      expect(methods, [
        'session/list',
        'session/modelCatalog',
        'session/create',
        'session/selectModel',
        'session/prompt',
        'session/prompt',
        'session/prompt',
        'session/cancel',
      ]);
    },
  );

  test('older and malformed workspace rows keep other chats visible', () async {
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      final open = jsonDecode(await ws.first as String) as Map;
      ws.add(
        jsonEncode({
          'type': 'item',
          'streamId': open['streamId'],
          'value': {
            'type': 'baseline',
            'value': {
              'items': [
                {
                  'workspaceId': 'older',
                  'title': 'Seed trays',
                  'sessionIds': ['visible', false],
                },
                null,
                {'title': 'Broken'},
                {
                  'workspaceId': 'empty',
                  'title': 'Cuttings',
                  'path': '/garden/cuttings',
                  'sessionIds': [],
                },
              ],
            },
          },
        }),
      );
      await ws.close();
    });
    final workspaces = await client.listWorkspaces();
    expect(workspaces.map((w) => w.id), ['older', 'empty']);
    expect(workspaces.first.path, isEmpty);
    expect(workspaces.first.sessionIds, ['visible']);
    expect(workspaces.last.path, '/garden/cuttings');
  });

  test(
    'browses server paths, creates a folder, and adopts it idempotently',
    () async {
      const parent = r'Q:\Garden';
      const child = r'Q:\Garden\Fern house';
      final methods = <String>[];
      server.listen((req) async {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        final method = body['method'] as String;
        final args = body['payload']['args'];
        expect(req.uri.path, '/garden/api/$method');
        final Object value;
        switch (method) {
          case 'directoryPicker/list':
            expect(args, methods.isEmpty ? {} : {'path': parent});
            value = {
              'path': parent,
              'home': parent,
              'truncated': true,
              'crumbs': [
                {'name': 'Garden', 'path': parent, 'hidden': false},
              ],
              'entries': [
                {
                  'name': '.archive',
                  'path': r'Q:\Garden\.archive',
                  'hidden': true,
                },
              ],
            };
          case 'directoryPicker/createDirectory':
            expect(args, {'path': parent, 'name': 'Fern house'});
            value = child;
          case 'workspace/create':
            expect(args, {
              'request': {'path': child},
            });
            value = {
              'created': !methods.contains(method),
              'workspace': {
                'workspaceId': 'fern',
                'title': 'Fern house',
                'path': child,
                'sessionIds': ['sprout'],
              },
            };
          default:
            throw StateError('Unexpected method');
        }
        methods.add(method);
        req.response.write(
          jsonEncode({
            'type': 'server-response',
            'rpcId': body['rpcId'],
            'result': {'ok': true, 'value': value},
          }),
        );
        await req.response.close();
      });
      final home = await client.listDirectories();
      expect(home.crumbs.single.path, parent);
      expect(
        (await client.listDirectories(home.path)).entries.single.hidden,
        true,
      );
      expect(home.entries.single.name, '.archive');
      expect(home.truncated, true);
      final directory = await client.createDirectory(home.path, 'Fern house');
      final workspace = await client.createWorkspace(directory);
      expect(workspace.path, child);
      expect(workspace.sessionIds, ['sprout']);
      expect((await client.createWorkspace(directory)).id, workspace.id);
    },
  );

  test('rejects incomplete workspace creation receipts', () async {
    final workspace = {
      'workspaceId': 'fern',
      'title': 'Fern',
      'path': '/garden/fern',
      'sessionIds': <Object>[],
    };
    final replies = [
      {'workspace': workspace},
      {
        'created': true,
        'workspace': {...workspace, 'path': null},
      },
      {
        'created': false,
        'workspace': {
          ...workspace,
          'sessionIds': [null],
        },
      },
    ];
    final next = replies.iterator;
    server.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
      expect(next.moveNext(), true);
      req.response.write(
        jsonEncode({
          'type': 'server-response',
          'rpcId': body['rpcId'],
          'result': {'ok': true, 'value': next.current},
        }),
      );
      await req.response.close();
    });
    for (var i = 0; i < replies.length; i++) {
      await expectLater(
        client.createWorkspace('/garden/fern'),
        throwsA(
          isA<DeepSeekHarnessException>().having(
            (e) => e.reason,
            'reason',
            DeepSeekHarnessFailure.invalidResponse,
          ),
        ),
      );
    }
  });

  test('exposes only safe, actionable workspace errors', () async {
    final codes = [
      'workspace/invalid-path',
      'directory-picker/exists',
      'directory-picker/unavailable',
    ].iterator;
    server.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
      expect(codes.moveNext(), true);
      req.response.write(
        jsonEncode({
          'type': 'server-response',
          'rpcId': body['rpcId'],
          'result': {
            'ok': false,
            'error': {
              'code': codes.current,
              'message': 'example host-specific detail',
              'details': {},
            },
          },
        }),
      );
      await req.response.close();
    });
    Matcher issue(HarnessWorkspaceIssue value) => throwsA(
      isA<HarnessWorkspaceException>()
          .having((error) => error.issue, 'issue', value)
          .having(
            (error) => error.toString(),
            'description',
            isNot(contains('host-specific')),
          ),
    );
    await expectLater(
      client.createWorkspace('/garden/missing'),
      issue(HarnessWorkspaceIssue.invalidPath),
    );
    await expectLater(
      client.createDirectory('/garden', 'notes'),
      issue(HarnessWorkspaceIssue.directoryExists),
    );
    await expectLater(
      client.listDirectories(),
      issue(HarnessWorkspaceIssue.browseUnavailable),
    );
    for (final bad in ['', ' ', '.', '..', 'two/segments', r'two\segments']) {
      await expectLater(
        client.createDirectory('/garden', bad),
        issue(HarnessWorkspaceIssue.createFailed),
      );
    }
  });

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
              item(id, {'cursor': 4, 'running': true, 'pendingInput': []});
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
              item('state', {
                'cursor': 6,
                'running': false,
                'pendingInput': [],
              });
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
        req.response.statusCode = HttpStatus.seeOther;
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
      expect(pages.first.needsWorkspace, false);
      expect(pages.first.hasPendingRequest, false);
      expect(pages.first.messages, isEmpty);
      expect(pages.last.lastTurnFailed, false);
      expect(pages.last.needsWorkspace, false);
      expect(pages.last.running, true);
    },
  );

  test(
    'malformed session catalog entries return an invalid response',
    () async {
      final inputs = <Object?>[
        null,
        {},
        {'sessionId': 'bad', 'running': false, 'projections': 'malformed'},
      ].iterator;
      server.listen((req) async {
        expect(inputs.moveNext(), true);
        final body = jsonDecode(
          await req.cast<List<int>>().transform(utf8.decoder).join(),
        ) as Map;
        req.response.write(
          jsonEncode({
            'type': 'server-response',
            'rpcId': body['rpcId'],
            'result': {
              'ok': true,
              'value': {
                'items': [inputs.current],
              },
            },
          }),
        );
        await req.response.close();
      });
      for (var i = 0; i < 3; i++) {
        await expectLater(
          client.listSessions(),
          throwsA(
            isA<DeepSeekHarnessException>().having(
              (e) => e.reason,
              'reason',
              DeepSeekHarnessFailure.invalidResponse,
            ),
          ),
        );
      }
    },
  );

  test(
    'state samples and journal turns respect their inclusive cursor',
    () async {
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        await for (final raw in ws) {
          final frame = jsonDecode(raw as String) as Map;
          if (frame['streamId'] != 'events') continue;
          void item(String stream, Map value) => ws.add(
            jsonEncode({'type': 'item', 'streamId': stream, 'value': value}),
          );
          void state(int cursor, bool running) => item('state', {
            'running': running,
            'cursor': cursor,
            'pendingInput': [],
          });
          void event(int seq, String type) => item('journal', {
            'type': 'event',
            'event': {'seq': seq, 'type': type, 'data': {}},
          });
          state(8, true);
          item('journal', {
            'type': 'snapshot',
            'header': {'id': 'session'},
            'records': [],
            'assistantStream': {'revision': 0},
          });
          event(7, 'turn/end');
          event(8, 'turn/start');
          event(9, 'turn/end');
          state(8, true);
          event(10, 'turn/start');
          state(10, false);
          item('journal', {
            'type': 'event',
            'event': {
              'seq': 11,
              'type': 'session/title',
              'data': {'title': 'Finished'},
            },
          });
        }
      });
      final frames = <HarnessTranscript>[];
      await for (final frame in client.follow('session')) {
        frames.add(frame);
        if (frame.title == 'Finished') break;
      }
      final running = <bool>[];
      for (final f in frames) {
        if (running.isEmpty || running.last != f.running) {
          running.add(f.running);
        }
      }
      expect(running, [true, false, true, false]);
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
