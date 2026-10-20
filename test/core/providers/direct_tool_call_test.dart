import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/personal_tool_execution.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/socket_transport_availability.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _server = ServerConfig(
  id: 'server-1',
  name: 'Home server',
  url: 'https://owui.example',
);

typedef _Auth = ({bool authenticated, String? token, Object epoch});

final class _AuthNotifier extends Notifier<_Auth> {
  @override
  _Auth build() => (authenticated: true, token: 'token-a', epoch: Object());

  void set(_Auth next) => state = next;
}

final _authProvider = NotifierProvider<_AuthNotifier, _Auth>(_AuthNotifier.new);

/// The server's current verdict on whether this account may use personal tool
/// servers, which a callback must honour whatever the Advanced preference says.
final class _AccessNotifier extends Notifier<PersonalConnectionsAccess> {
  @override
  PersonalConnectionsAccess build() =>
      const PersonalConnectionsAccess.allowed();

  void deny() => state = const PersonalConnectionsAccess.blocked(
    PersonalConnectionsBlock.noPermission,
  );
}

final _accessProvider =
    NotifierProvider<_AccessNotifier, PersonalConnectionsAccess>(
      _AccessNotifier.new,
    );

/// A socket whose acknowledgements are recorded instead of written to a
/// network connection. The ack callbacks it hands out are the library's own, so
/// what is recorded is exactly what would go on the wire.
final class _RecordingSocket extends io.Socket {
  _RecordingSocket(super.io, super.nsp, super.opts);

  final List<Map<dynamic, dynamic>> written = <Map<dynamic, dynamic>>[];

  @override
  void packet(Map packet) => written.add(Map<dynamic, dynamic>.of(packet));

  List<Map<dynamic, dynamic>> ackedFor(int id) => [
    for (final packet in written)
      if (packet['id'] == id) packet,
  ];
}

class _Request {
  _Request(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;
}

/// A tool server on loopback that publishes an OpenAPI document and records
/// every request it receives.
final class _ToolHost {
  _ToolHost._(this._http);

  final HttpServer _http;
  final List<_Request> requests = <_Request>[];

  String get url => 'http://127.0.0.1:${_http.port}';

  List<_Request> get calls =>
      requests.where((r) => r.uri.path != '/openapi.json').toList();

  static Future<_ToolHost> start() async {
    final host = _ToolHost._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    host._http.listen(host._handle);
    return host;
  }

  Map<String, dynamic> get _spec => <String, dynamic>{
    'openapi': '3.0.0',
    'info': <String, dynamic>{'title': 'Notes', 'version': '1'},
    'paths': <String, dynamic>{
      '/items/{id}': <String, dynamic>{
        'get': <String, dynamic>{
          'operationId': 'getItem',
          'parameters': <dynamic>[
            <String, dynamic>{'name': 'id', 'in': 'path'},
            <String, dynamic>{'name': 'q', 'in': 'query'},
          ],
        },
      },
      '/notes/{noteId}': <String, dynamic>{
        'post': <String, dynamic>{
          'operationId': 'createNote',
          'parameters': <dynamic>[
            <String, dynamic>{'name': 'noteId', 'in': 'path'},
            <String, dynamic>{'name': 'dry', 'in': 'query'},
          ],
          'requestBody': <String, dynamic>{
            'content': <String, dynamic>{
              'application/json': <String, dynamic>{
                'schema': <String, dynamic>{
                  r'$ref': '#/components/schemas/Note',
                },
              },
            },
          },
        },
      },
      '/boom': <String, dynamic>{
        'get': <String, dynamic>{'operationId': 'boom'},
      },
    },
    'components': <String, dynamic>{
      'schemas': <String, dynamic>{
        'Note': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'text': <String, dynamic>{'type': 'string'},
            'tags': <String, dynamic>{'type': 'array'},
          },
        },
      },
    },
  };

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    requests.add(
      _Request(request.method, request.uri, <String, String>{
        for (final name in <String>['authorization', 'x-session-id'])
          name: ?request.headers.value(name),
      }, body),
    );
    final response = request.response..headers.contentType = ContentType.json;
    switch (request.uri.path) {
      case '/openapi.json':
        response.write(jsonEncode(_spec));
      case '/boom':
        response
          ..statusCode = 500
          ..headers.contentType = ContentType.text
          ..write('nope');
      case final path when path.startsWith('/items/'):
        response.write(jsonEncode(<String, dynamic>{'path': path}));
      default:
        response.write(jsonEncode(<String, dynamic>{'ok': true}));
    }
    await response.close();
  }

  Future<void> close() => _http.close(force: true);
}

Map<String, dynamic> _toolServerEntry(
  _ToolHost host, {
  String key = 'edited-key',
  String authType = 'bearer',
  bool enabled = true,
}) => <String, dynamic>{
  'type': 'openapi',
  'url': host.url,
  'spec_type': 'url',
  'path': '/openapi.json',
  'auth_type': authType,
  'key': key,
  'config': <String, dynamic>{'enable': enabled},
  'info': <String, dynamic>{'id': 'notes', 'name': 'Notes'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ToolHost host;
  late FakeUserSettingsServer settings;
  late ApiService api;
  late ProviderContainer container;
  late _RecordingSocket socket;
  late SocketService service;
  var nextAckId = 100;

  /// What the chat request for [messageId] in [chatId] sent: [entry] (the
  /// notes server by default) advertising [operations]. The real request
  /// builders produce this at the point the request leaves.
  void admit({
    String chatId = 'background-chat',
    String messageId = 'assistant-1',
    PersonalConnectionKind kind = PersonalConnectionKind.toolServer,
    Map<String, dynamic>? entry,
    Set<String> operations = const <String>{'getItem', 'createNote', 'boom'},
  }) {
    final sent = entry ?? _toolServerEntry(host);
    service.admitPersonalToolServers(
      chatId: chatId,
      messageId: messageId,
      sessionId: 'session-1',
      connections: <PersonalToolAdmission>[
        PersonalToolAdmission(
          kind: kind,
          identity: personalConnectionAdmissionIdentity(kind, sent),
          url: personalConnectionUrl(sent),
          operations: operations,
        ),
      ],
    );
  }

  setUp(() async {
    // The test binding refuses real HTTP; the tool server is on loopback.
    HttpOverrides.global = null;
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    host = await _ToolHost.start();
    settings = FakeUserSettingsServer(const <String, dynamic>{})
      ..addAccount('token-a', <String, dynamic>{
        'ui': <String, dynamic>{
          'toolServers': <dynamic>[_toolServerEntry(host)],
        },
        // A stale list from an older client, which the edited one outranks.
        'toolServers': <dynamic>[_toolServerEntry(host, key: 'stale-key')],
      })
      ..addAccount('token-b', <String, dynamic>{
        'ui': <String, dynamic>{'toolServers': <dynamic>[]},
      });
    api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
      authToken: 'token-a',
    );
    api.dio.httpClientAdapter = settings;

    container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        personalConnectionsAccessProvider.overrideWith(
          (ref) => ref.watch(_accessProvider),
        ),
        apiServiceProvider.overrideWithValue(api),
        isAuthenticatedProvider2.overrideWith(
          (ref) => ref.watch(_authProvider).authenticated,
        ),
        authTokenProvider3.overrideWith(
          (ref) => ref.watch(_authProvider).token,
        ),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(_authProvider).epoch,
        ),
        activeServerProvider.overrideWith((ref) async => _server),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        socketTransportOptionsProvider.overrideWithValue(
          const SocketTransportAvailability(
            allowPolling: true,
            allowWebsocketOnly: true,
          ),
        ),
        connectivityStatusProvider.overrideWithValue(ConnectivityStatus.online),
        socketServiceFactoryProvider.overrideWithValue(({
          required serverConfig,
          required authToken,
          required websocketOnly,
          required allowWebsocketUpgrade,
        }) {
          return SocketService(
            serverConfig: serverConfig,
            authToken: authToken,
            websocketOnly: websocketOnly,
            allowWebsocketUpgrade: allowWebsocketUpgrade,
            socketFactory: (_, _, _) {
              final base = io.io('http://localhost:19000', <String, dynamic>{
                'autoConnect': false,
                'forceNew': true,
                'reconnection': false,
              });
              socket = _RecordingSocket(base.io, '/', <String, dynamic>{})
                ..connected = true
                ..id = 'session-1';
              return socket;
            },
          );
        }),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await host.close();
    });

    // The real manager builds the service and binds the tool executor to it.
    final subscription = container.listen(
      socketServiceManagerProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    service = (await container.read(socketServiceManagerProvider.future))!;
    await service.connect();
    socket
      ..connected = true
      ..id = 'session-1';

    // The chat request for this message handed the notes server to Open WebUI,
    // and advertised these operations for it.
    admit();
  });

  /// Delivers an `execute:tool` event to the socket the way the server's
  /// session-targeted `sio.call` does, and returns the ack id it carried.
  int deliver(
    Map<String, dynamic> call, {
    String chatId = 'background-chat',
    String messageId = 'assistant-1',
    String sessionId = 'session-1',
  }) {
    final id = nextAckId++;
    socket.onevent(<String, dynamic>{
      'type': 2,
      'id': id,
      'data': <dynamic>[
        'events',
        <String, dynamic>{
          'chat_id': chatId,
          'message_id': messageId,
          'data': <String, dynamic>{
            'type': 'execute:tool',
            'data': <String, dynamic>{
              'id': 'call-$id',
              'session_id': sessionId,
              ...call,
            },
          },
        },
      ],
    });
    return id;
  }

  Future<List<Map<dynamic, dynamic>>> answered(int id) async {
    // The reply is produced by real HTTP and socket work.
    for (var attempt = 0; attempt < 100; attempt++) {
      final acks = socket.ackedFor(id);
      if (acks.isNotEmpty) return acks;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return socket.ackedFor(id);
  }

  Map<String, dynamic> call(String name, Map<String, dynamic> params) =>
      <String, dynamic>{
        'name': name,
        'params': params,
        'server': <String, dynamic>{'url': host.url},
      };

  test('an operation reaches the edited connection with its own key and the reply is one [data, headers] argument', () async {
    admit(chatId: 'chat-9');
    final id = deliver(
      call('getItem', <String, dynamic>{
        'id': 'a b/ü',
        'q': 'x y',
        // Not declared as a parameter, so it must not leak into the URL.
        'extra': 1,
      }),
      chatId: 'chat-9',
    );

    final acks = await answered(id);

    expect(acks, hasLength(1));
    final sent = host.calls.single;
    expect(sent.method, 'GET');
    expect(sent.uri.path, '/items/a%20b%2F%C3%BC');
    expect(sent.uri.query, 'q=x+y');
    // The edited list's key, not the stale root one, and the chat id the
    // reference client forwards.
    expect(sent.headers['authorization'], 'Bearer edited-key');
    expect(sent.headers['x-session-id'], 'chat-9');
    // The pair is a single wire argument, as the reference client sends it.
    final args = acks.single['data'] as List<dynamic>;
    expect(args, hasLength(1));
    final pair = args.single as List<dynamic>;
    expect(pair[0], <String, dynamic>{'path': '/items/a%20b%2F%C3%BC'});
    expect(
      (pair[1] as Map<String, dynamic>)['content-type'],
      contains('application/json'),
    );
  });

  test('a declared request body carries only what the schema keeps', () async {
    final id = deliver(
      call('createNote', <String, dynamic>{
        'noteId': 'n1',
        'dry': true,
        'text': 'hi',
        'tags': <String>['a'],
        'unlisted': 3,
      }),
    );

    await answered(id);

    final sent = host.calls.single;
    expect(sent.method, 'POST');
    expect(sent.uri.path, '/notes/n1');
    expect(sent.uri.query, 'dry=true');
    // Path and query parameters stay out of the body; undeclared ones stay in.
    expect(jsonDecode(sent.body), <String, dynamic>{
      'text': 'hi',
      'tags': <String>['a'],
      'unlisted': 3,
    });
  });

  test('a failing operation is answered once with the error pair', () async {
    final id = deliver(call('boom', const <String, dynamic>{}));

    final acks = await answered(id);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(socket.ackedFor(id), hasLength(1));
    final pair = (acks.single['data'] as List<dynamic>).single as List<dynamic>;
    expect(pair[0], <String, dynamic>{
      'error': 'HTTP error! Status: 500. Message: nope',
    });
    expect(pair[1], isNull);
  });

  test(
    'a server the account does not have is refused without any request',
    () async {
      final id = deliver(<String, dynamic>{
        'name': 'getItem',
        'params': <String, dynamic>{'id': '1'},
        // The event cannot bring its own server, URL or key.
        'server': <String, dynamic>{
          'url': 'http://127.0.0.1:9',
          'key': 'event-supplied-key',
        },
      });

      final acks = await answered(id);

      expect(acks.single['data'], <dynamic>[
        <String, dynamic>{'error': 'Tool Server Not Found'},
      ]);
      expect(host.requests, isEmpty);
    },
  );

  test(
    'a direct terminal is called with its own key, and only while enabled',
    () async {
      Map<String, dynamic> terminal({required bool enabled}) =>
          <String, dynamic>{
            'url': host.url,
            'key': 'terminal-key',
            'enabled': enabled,
          };
      final ui = settings.settingsOf('token-a')['ui'] as Map<String, dynamic>;
      ui['toolServers'] = <dynamic>[];
      ui['terminalServers'] = <dynamic>[terminal(enabled: false)];
      admit(
        kind: PersonalConnectionKind.terminal,
        entry: terminal(enabled: true),
        operations: const <String>{'getItem'},
      );

      final refused = await answered(
        deliver(call('getItem', <String, dynamic>{'id': '1'})),
      );
      expect(refused.single['data'], <dynamic>[
        <String, dynamic>{'error': 'Tool Server Not Found'},
      ]);
      expect(host.requests, isEmpty);

      ui['terminalServers'] = <dynamic>[terminal(enabled: true)];
      await answered(deliver(call('getItem', <String, dynamic>{'id': '1'})));

      // The terminal publishes its document at the default path.
      expect(host.calls.single.headers['authorization'], 'Bearer terminal-key');
    },
  );

  test('a switched-off connection is not called', () async {
    settings.settingsOf('token-a')['ui']['toolServers'] = <dynamic>[
      _toolServerEntry(host, enabled: false),
    ];

    final id = deliver(call('getItem', <String, dynamic>{'id': '1'}));
    final acks = await answered(id);

    expect(acks.single['data'], <dynamic>[
      <String, dynamic>{'error': 'Tool Server Not Found'},
    ]);
    expect(host.requests, isEmpty);
  });

  test(
    'an auth mode that cannot be sent is answered, not left waiting',
    () async {
      settings.settingsOf('token-a')['ui']['toolServers'] = <dynamic>[
        _toolServerEntry(host, authType: 'session'),
      ];

      final id = deliver(call('getItem', <String, dynamic>{'id': '1'}));
      final acks = await answered(id);

      final pair =
          (acks.single['data'] as List<dynamic>).single as List<dynamic>;
      expect(
        (pair[0] as Map<String, dynamic>)['error'],
        contains('authentication'),
      );
      // Neither the document nor the call was requested: the Open WebUI session
      // token is never offered to a host the user configured.
      expect(host.requests, isEmpty);
    },
  );

  test(
    'a server that cannot be reached is answered, not left waiting',
    () async {
      final closed = await _ToolHost.start();
      final closedUrl = closed.url;
      await closed.close();
      final unreachable = <String, dynamic>{
        ..._toolServerEntry(host),
        'url': closedUrl,
      };
      settings.settingsOf('token-a')['ui']['toolServers'] = <dynamic>[
        unreachable,
      ];
      admit(entry: unreachable);

      final id = deliver(<String, dynamic>{
        'name': 'getItem',
        'params': <String, dynamic>{'id': '1'},
        'server': <String, dynamic>{'url': closedUrl},
      });
      final acks = await answered(id);

      final pair =
          (acks.single['data'] as List<dynamic>).single as List<dynamic>;
      expect(
        (pair[0] as Map<String, dynamic>)['error'],
        contains('could not be reached'),
      );
    },
  );

  test('a call addressed to another session is not run or answered', () async {
    final id = deliver(
      call('getItem', <String, dynamic>{'id': '1'}),
      sessionId: 'someone-elses-session',
    );

    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(socket.ackedFor(id), isEmpty);
    expect(host.requests, isEmpty);
    expect(settings.log, isEmpty);
  });

  test('a call redelivered while it runs is performed once', () async {
    final first = deliver(call('getItem', <String, dynamic>{'id': '1'}));
    // The server resends the same call id before the first reply is ready.
    socket.onevent(<String, dynamic>{
      'type': 2,
      'id': 777,
      'data': <dynamic>[
        'events',
        <String, dynamic>{
          'chat_id': 'background-chat',
          'message_id': 'assistant-1',
          'data': <String, dynamic>{
            'type': 'execute:tool',
            'data': <String, dynamic>{
              'id': 'call-$first',
              'session_id': 'session-1',
              ...call('getItem', <String, dynamic>{'id': '1'}),
            },
          },
        },
      ],
    });

    await answered(first);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(host.calls, hasLength(1));
    expect(socket.ackedFor(777), isEmpty);
  });

  test(
    'an account that changes before the call is sent gets nothing sent for it',
    () async {
      settings.gateFirstGet();
      final getsBefore = settings.log.length;

      final id = deliver(call('getItem', <String, dynamic>{'id': '1'}));
      await settings.firstGetEntered.future;
      expect(settings.log.length, getsBefore + 1);
      // Account B signs in on the same server while the call is still loading
      // the connections it may use.
      api.updateAuthToken('token-b');
      container.read(_authProvider.notifier).set((
        authenticated: true,
        token: 'token-b',
        epoch: Object(),
      ));
      await Future<void>.delayed(Duration.zero);
      settings.releaseFirstGet.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Nothing reached the tool server, with A's key or any other, and the
      // reply for A's call is not put on a connection that is no longer A's.
      expect(host.requests, isEmpty);
      expect(socket.ackedFor(id), isEmpty);
    },
  );

  group('a callback needs the request that sent the connection', () {
    const notFound = <dynamic>[
      <String, dynamic>{'error': 'Tool Server Not Found'},
    ];

    test(
      'a configured connection is not authority for an unadmitted chat',
      () async {
        final id = deliver(
          call('createNote', <String, dynamic>{'noteId': 'n1', 'text': 'x'}),
          chatId: 'never-admitted',
        );

        final acks = await answered(id);

        expect(acks.single['data'], notFound);
        expect(host.requests, isEmpty);
        // Not even the account's settings were read for it.
        expect(settings.log, isEmpty);
      },
    );

    test(
      'a callback for another completion of an admitted chat is refused',
      () async {
        final id = deliver(
          call('createNote', <String, dynamic>{'noteId': 'n1', 'text': 'x'}),
          messageId: 'someone-elses-completion',
        );

        expect((await answered(id)).single['data'], notFound);
        expect(host.requests, isEmpty);
      },
    );

    test(
      'a configured server the request did not send is not called',
      () async {
        final other = await _ToolHost.start();
        addTearDown(other.close);
        settings.settingsOf('token-a')['ui']['toolServers'] = <dynamic>[
          _toolServerEntry(host),
          <String, dynamic>{
            ..._toolServerEntry(other),
            'info': <String, dynamic>{'id': 'other', 'name': 'Other'},
          },
        ];

        final id = deliver(<String, dynamic>{
          'name': 'getItem',
          'params': <String, dynamic>{'id': '1'},
          'server': <String, dynamic>{'url': other.url},
        });

        expect((await answered(id)).single['data'], notFound);
        expect(other.requests, isEmpty);
        expect(host.requests, isEmpty);
      },
    );

    test('an operation the request did not advertise is not run', () async {
      admit(operations: const <String>{'getItem'});

      final id = deliver(
        call('createNote', <String, dynamic>{'noteId': 'n1', 'text': 'x'}),
      );

      expect((await answered(id)).single['data'], notFound);
      expect(host.requests, isEmpty);
    });

    test(
      'another connection that now sits at the admitted URL is not called',
      () async {
        settings.settingsOf('token-a')['ui']['toolServers'] = <dynamic>[
          <String, dynamic>{
            ..._toolServerEntry(host),
            'info': <String, dynamic>{'id': 'impostor', 'name': 'Impostor'},
          },
        ];

        final id = deliver(call('getItem', <String, dynamic>{'id': '1'}));

        expect((await answered(id)).single['data'], notFound);
        expect(host.requests, isEmpty);
      },
    );

    test('a finished completion no longer admits callbacks', () async {
      socket.onevent(<String, dynamic>{
        'type': 2,
        'data': <dynamic>[
          'events',
          <String, dynamic>{
            'chat_id': 'background-chat',
            'message_id': 'assistant-1',
            'data': <String, dynamic>{
              'type': 'chat:completion',
              'data': <String, dynamic>{'done': true},
            },
          },
        ],
      });

      final id = deliver(call('getItem', <String, dynamic>{'id': '1'}));

      expect((await answered(id)).single['data'], notFound);
      expect(host.requests, isEmpty);
    });

    test('what one session sent does not admit another session', () async {
      // The connection is now a different session from the one that sent the
      // request.
      socket.id = 'session-2';

      final id = deliver(
        call('getItem', <String, dynamic>{'id': '1'}),
        sessionId: 'session-2',
      );

      expect((await answered(id)).single['data'], notFound);
      expect(host.requests, isEmpty);
    });
  });

  group(
    'a callback follows the account\'s current right to use connections',
    () {
      List<dynamic> refusal(List<Map<dynamic, dynamic>> acks) =>
          ((acks.single['data'] as List<dynamic>).single as List<dynamic>);

      test('keeps working with the Advanced preference off', () async {
        expect(
          container.read(appSettingsProvider).advancedFeaturesEnabled,
          isFalse,
        );

        final id = deliver(call('getItem', <String, dynamic>{'id': '1'}));
        await answered(id);

        expect(host.calls, hasLength(1));
      });

      test('a denied account sends nothing and is answered', () async {
        container.read(_accessProvider.notifier).deny();

        final id = deliver(
          call('createNote', <String, dynamic>{'noteId': 'n1', 'text': 'x'}),
        );
        final pair = refusal(await answered(id));

        expect((pair.first as Map)['error'], contains('cannot use'));
        expect(pair.last, isNull);
        expect(host.requests, isEmpty);
        // Refused before the account's settings were even read.
        expect(settings.log, isEmpty);
      });

      test('a right lost while the settings load stops the call', () async {
        settings.gateFirstGet();

        final id = deliver(
          call('createNote', <String, dynamic>{'noteId': 'n1', 'text': 'x'}),
        );
        await settings.firstGetEntered.future;
        container.read(_accessProvider.notifier).deny();
        settings.releaseFirstGet.complete();
        final pair = refusal(await answered(id));

        expect((pair.first as Map)['error'], contains('cannot use'));
        expect(host.requests, isEmpty);
      });
    },
  );

  group('a call is performed at most once', () {
    test(
      'a completed call redelivered with a new ack id runs no second time',
      () async {
        const stableId = 'one-side-effect';
        Map<String, dynamic> create() => <String, dynamic>{
          'id': stableId,
          ...call('createNote', <String, dynamic>{
            'noteId': 'n1',
            'text': 'once',
          }),
        };

        final first = deliver(create());
        final firstAck = await answered(first);
        expect(host.calls, hasLength(1));

        final second = deliver(create());
        final secondAck = await answered(second);

        // The server is answered again, with what the call answered, and the
        // tool server saw one request.
        expect(secondAck, hasLength(1));
        expect(secondAck.single['data'], firstAck.single['data']);
        expect(host.calls, hasLength(1));
      },
    );

    test(
      'a call that lost its connection does not start work when late',
      () async {
        settings.gateFirstGet();

        final id = deliver(
          call('createNote', <String, dynamic>{'noteId': 'n1', 'text': 'late'}),
        );
        await settings.firstGetEntered.future;
        // The connection drops and comes back while the settings are loading.
        socket.onclose('transport close');
        socket.id = 'session-2';
        settings.releaseFirstGet.complete();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(host.requests, isEmpty);
        expect(socket.ackedFor(id), isEmpty);
      },
    );
  });
}
