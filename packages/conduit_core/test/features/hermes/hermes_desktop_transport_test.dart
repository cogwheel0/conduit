import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_json_guard.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_mcp.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

final class _SocketHarness {
  _SocketHarness() {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) => incoming.stream);
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.add(any())).thenAnswer((invocation) {
      sent.add(invocation.positionalArguments.single as String);
    });
    when(() => sink.close()).thenAnswer((_) async {});
  }

  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>();
  final sent = <String>[];

  void ready([Map<String, Object?> payload = const {}]) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {'type': 'gateway.ready', 'payload': payload},
    }),
  );

  List<Map<String, dynamic>> get frames => [
    for (final raw in sent) Map<String, dynamic>.from(jsonDecode(raw) as Map),
  ];

  /// The [index]th frame after the connection's capability handshake.
  Map<String, dynamic> sentFrame(int index) => frames
      .where((frame) => frame['method'] != 'client.capabilities')
      .elementAt(index);

  /// Answers the capability handshake the way Hermes 0.22+ does.
  Future<void> answerCapabilities({bool declinesNotShown = true}) async {
    await Future<void>.delayed(Duration.zero);
    final handshake = frames.singleWhere(
      (frame) => frame['method'] == 'client.capabilities',
    );
    incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': handshake['id'],
        'result': {
          'server_requests': ['approval', 'clarify', 'secret', 'sudo', 'tour'],
          'declines_not_shown': declinesNotShown,
        },
      }),
    );
    await Future<void>.delayed(Duration.zero);
  }

  void serverRequest(String id, String method, Map<String, Object?> params) =>
      incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }),
      );

  void event(String type, Map<String, Object?> payload, {String? session}) =>
      incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': type, 'session_id': ?session, 'payload': payload},
        }),
      );

  Future<void> dispose() => incoming.close();
}

void main() {
  test('preserves MCP state and discovered inventory', () {
    final server = HermesMcpServer.fromJson({
      'name': 'docs',
      'url': 'https://user:secret@example.com/mcp?token=secret',
      'enabled': false,
      'auth': 'oauth',
      'tools': [
        {'name': 'search'},
      ],
    });
    final probe = HermesMcpTestResult.fromJson({
      'ok': true,
      'tools': [
        {'name': 'search'},
      ],
      'resources': 3,
      'prompts': 2,
    });

    check(server.enabled).isFalse();
    check(server.auth).equals('oauth');
    check(server.tools).deepEquals(['search']);
    check(server.description).equals('https://example.com/mcp');
    check(probe.toolNames).deepEquals(['search']);
    check(probe.tools).equals(1);
    check(probe.resources).equals(3);
    check(probe.prompts).equals(2);
  });

  group('MCP server tool filter', () {
    Map<String, dynamic> row(Object? tools) => {
      'name': 'docs',
      'url': 'https://example.com/mcp',
      'tools': tools,
    };

    test('reads include, exclude and the utility switches', () {
      final filter = HermesMcpServer.fromJson(
        row({
          'include': ['search', 'get_*'],
          'exclude': 'delete_*',
          'resources': false,
          'prompts': 'off',
        }),
      ).toolFilter;

      check(filter).isNotNull();
      check(filter!.include).isNotNull().deepEquals(['search', 'get_*']);
      check(filter.exclude).isNotNull().deepEquals(['delete_*']);
      check(filter.resources).equals(false);
      check(filter.prompts).equals(false);
      check(filter.isEmpty).isFalse();
      check(filter.summary).equals(
        'only search, get_* · except delete_* · no resources · no prompts',
      );
    });

    test('an empty include is an explicit register-nothing whitelist', () {
      final filter = HermesMcpServer.fromJson(row({'include': []})).toolFilter;

      check(filter!.include).isNotNull().isEmpty();
      check(filter.summary).equals('none');
    });

    test('no filter object means everything registers', () {
      check(HermesMcpServer.fromJson(row(null)).toolFilter).isNull();
      check(HermesMcpServer.fromJson(row(const [])).toolFilter).isNull();
      check(HermesMcpServer.fromJson(row({})).toolFilter!.summary).isNull();
    });

    test('a filter object is not misread as tool names', () {
      final server = HermesMcpServer.fromJson(
        row({
          'include': ['search'],
        }),
      );

      check(server.tools).isEmpty();
      check(server.toolFilter!.include).isNotNull().deepEquals(['search']);
    });

    test('round-trips unchanged, including keys the client does not know', () {
      final wire = {
        'include': ['search'],
        'exclude': ['x_*'],
        'resources': 'no',
        'future_key': {
          'nested': [1, 2],
        },
      };
      final filter = HermesMcpServer.fromJson(row(wire)).toolFilter!;

      check(filter.toJson()).deepEquals(wire);
      // Mutating the source or the copy must not leak either way.
      (wire['include'] as List).add('late');
      check((filter.toJson()['include'] as List).length).equals(1);
      check(
        hermesMcpServerConfig(
          url: 'https://example.com/mcp',
          toolFilter: filter,
        ),
      ).deepEquals({
        'url': 'https://example.com/mcp',
        'tools': {
          'include': ['search'],
          'exclude': ['x_*'],
          'resources': 'no',
          'future_key': {
            'nested': [1, 2],
          },
        },
      });
    });

    test('the add config omits tools when there is no filter', () {
      check(hermesMcpServerConfig(command: 'npx', arguments: ['-y', 'x']))
          .deepEquals({
            'command': 'npx',
            'args': ['-y', 'x'],
          });
    });
  });

  test('ambiguous prompt recovery requires a newer transcript row', () {
    check(hermesTranscriptHasNewPrompt({'old'}, {'old'})).isFalse();
    check(hermesTranscriptHasNewPrompt({'old'}, {'old', 'new'})).isTrue();
  });

  test('MCP OAuth accepts only web URLs', () {
    check(parseHermesOAuthUrl('https://id.example/authorize')).isNotNull();
    check(parseHermesOAuthUrl('intent://open-app')).isNull();
    check(parseHermesOAuthUrl('file:///tmp/token')).isNull();
  });

  test('synthetic Desktop model inherits the configured Hermes default', () {
    check(hermesDesktopSessionModelSelection('default', null))
        .equals((model: null, provider: null));
    check(hermesDesktopSessionModelSelection('gpt-5.6-sol', 'azure-foundry'))
        .equals((model: 'gpt-5.6-sol', provider: 'azure-foundry'));
  });

  test('surfaces models from configured Hermes providers', () {
    final models = parseHermesDesktopConfiguredModels({
      'model': 'gpt-5.6-sol',
      'provider': 'azure-foundry',
      'providers': [
        {
          'slug': 'copilot',
          'authenticated': true,
          'models': ['gpt-5.4'],
        },
        {
          'slug': 'azure-foundry',
          'is_current': true,
          'models': ['gpt-5.6-sol'],
          'capabilities': {
            'gpt-5.6-sol': {'fast': true, 'reasoning': true},
          },
        },
      ],
    });

    check(models).deepEquals([
      {'id': 'gpt-5.4', 'name': 'gpt-5.4', 'provider': 'copilot'},
      {
        'id': 'gpt-5.6-sol',
        'name': 'gpt-5.6-sol',
        'provider': 'azure-foundry',
        'capabilities': {'fast': true, 'reasoning': true},
      },
    ]);
  });

  test('loads the complete compacted Desktop transcript in pages', () async {
    final offsets = <int>[];
    final messages = await loadHermesDesktopTranscriptPages((
      offset,
      limit,
    ) async {
      offsets.add(offset);
      final remaining = 750 - offset;
      return List.generate(
        remaining.clamp(0, limit),
        (index) => {'id': '${offset + index}'},
      );
    });

    check(offsets).deepEquals([0, 200, 400, 600]);
    check(messages).length.equals(750);
  });

  test('a short final transcript page stops paging', () async {
    final requests = <(int, int)>[];
    final messages = await loadHermesDesktopTranscriptPages((
      offset,
      limit,
    ) async {
      requests.add((offset, limit));
      final remaining = 230 - offset;
      return List.generate(
        remaining.clamp(0, limit),
        (index) => {'id': '${offset + index}'},
      );
    });

    check(requests).deepEquals([(0, 200), (200, 200)]);
    check(messages).length.equals(230);
  });

  test('an oversized transcript page is retried at half the limit', () async {
    final requests = <(int, int)>[];
    final messages = await loadHermesDesktopTranscriptPages((
      offset,
      limit,
    ) async {
      requests.add((offset, limit));
      if (limit > 100) throw const HermesResponseTooLargeException();
      final remaining = 250 - offset;
      return List.generate(
        remaining.clamp(0, limit),
        (index) => {'id': '${offset + index}'},
      );
    });

    check(requests).deepEquals([(0, 200), (0, 100), (100, 100), (200, 100)]);
    check(messages).length.equals(250);
    check(messages.first['id']).equals('0');
    check(messages.last['id']).equals('249');
  });

  test('a transcript page that is too large at the floor surfaces', () async {
    final limits = <int>[];
    await check(
      loadHermesDesktopTranscriptPages((offset, limit) async {
        limits.add(limit);
        throw const HermesResponseTooLargeException();
      }),
    ).throws<HermesResponseTooLargeException>();

    check(limits).deepEquals([200, 100, 50, 25]);
  });

  test('the transcript pager honours the total maximum', () async {
    final requests = <(int, int)>[];
    final messages = await loadHermesDesktopTranscriptPages((
      offset,
      limit,
    ) async {
      requests.add((offset, limit));
      return List.generate(limit, (index) => {'id': '${offset + index}'});
    }, maximum: 450);

    check(requests).deepEquals([(0, 200), (200, 200), (400, 50)]);
    check(messages).length.equals(450);
  });

  test('keeps the last usable transcript across empty or partial reads', () {
    final previous = [
      {'id': 'one'},
      {'id': 'two'},
    ];

    check(preferLastUsableHermesTranscript(previous, const []))
        .identicalTo(previous);
    check(
      preferLastUsableHermesTranscript(previous, const [
        {'id': 'one'},
      ]),
    ).identicalTo(previous);
  });

  test('does not retry with the expired access token after refresh 503', () {
    final expired = HermesDesktopTokenSet(
      accessToken: 'expired',
      refreshToken: 'still-valid',
      expiresAt: DateTime.utc(2020),
    );

    check(hermesNativeRefreshAllowsRetry(expired, expired)).isFalse();
  });

  test('skill routing error falls back to command.dispatch', () {
    check(
      hermesSlashNeedsCommandDispatch(
        const HermesDesktopRpcException('use command.dispatch', code: 4018),
      ),
    ).isTrue();
    check(
      hermesSlashNeedsCommandDispatch(
        const HermesDesktopRpcException('worker failed', code: 5000),
      ),
    ).isFalse();
  });

  test('slash alias preserves the original arguments', () {
    check(hermesExpandedAliasCommand('/shell git', '/git status'))
        .equals('/shell git status');
  });

  test('connect forwards its TLS client to the channel factory', () async {
    final socket = _SocketHarness();
    final trustClient = HttpClient();
    addTearDown(() => trustClient.close(force: true));
    HttpClient? received;
    final client = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) {
        received = httpClient;
        return socket.channel;
      },
    );
    addTearDown(() async {
      await client.close();
      await socket.dispose();
    });

    final connecting = client.connect(
      Uri.parse('wss://hermes.example/api/ws'),
      httpClient: trustClient,
    );
    await Future<void>.delayed(Duration.zero);
    socket.ready();
    await connecting;

    check(received).identicalTo(trustClient);
  });

  test('socket loss marks an in-flight mutation as ambiguous', () async {
    final socket = _SocketHarness();
    final client = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => socket.channel,
    );
    addTearDown(() async {
      await client.close();
      await socket.dispose();
    });
    final connecting = client.connect(Uri.parse('wss://hermes.example/api/ws'));
    await Future<void>.delayed(Duration.zero);
    socket.ready();
    await connecting;

    final request = client.request<Object?>('prompt.submit');
    await socket.incoming.close();

    try {
      await request;
      fail('Expected the disconnected request to fail.');
    } on HermesDesktopRpcException catch (error) {
      check(error.deliveryAmbiguous).isTrue();
    }
  });

  test('waits for gateway.ready and correlates concurrent RPCs', () async {
    final socket = _SocketHarness();
    final client = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => socket.channel,
    );
    addTearDown(() async {
      await client.close();
      await socket.dispose();
    });

    var connected = false;
    final connecting = client
        .connect(Uri.parse('wss://hermes.example/api/ws'))
        .then((_) => connected = true);
    await Future<void>.delayed(Duration.zero);
    check(connected).isFalse();
    socket.ready();
    await connecting;

    client.setDefaultParams({'profile': 'work'});
    // A caller-supplied profile wins over the connection default: Bot Mode
    // scopes single calls to another profile without a new connection.
    final first = client.request<String>(
      'first',
      params: {'session_id': 'session-1', 'profile': 'researcher'},
    );
    final second = client.request<String>('second');
    await Future<void>.delayed(Duration.zero);
    check(socket.sentFrame(0)['params'] as Map<String, dynamic>)
        .deepEquals({'session_id': 'session-1', 'profile': 'researcher'});
    check(socket.sentFrame(1)['params'] as Map<String, dynamic>)
        .deepEquals({'profile': 'work'});
    final firstId = socket.sentFrame(0)['id'];
    final secondId = socket.sentFrame(1)['id'];
    socket.incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': secondId, 'result': 'two'}),
    );
    socket.incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': firstId, 'result': 'one'}),
    );

    check(await first).equals('one');
    check(await second).equals('two');
  });

  test('buffers session events until a live consumer activates', () {
    final buffer = HermesDesktopEventBuffer(maximumPerSession: 2);
    check(
      buffer.add(
        const HermesDesktopEvent(
          type: 'message.delta',
          payload: {'delta': 'one'},
          sessionId: 'runtime-1',
        ),
      ),
    ).isTrue();
    check(
      buffer.add(
        const HermesDesktopEvent(
          type: 'message.delta',
          payload: {'delta': 'two'},
          sessionId: 'runtime-1',
        ),
      ),
    ).isFalse();
    buffer.add(
      const HermesDesktopEvent(
        type: 'message.delta',
        payload: {'delta': 'three'},
        sessionId: 'runtime-1',
      ),
    );

    check(buffer.activate('runtime-1').map((event) => event.payload['delta']))
        .deepEquals(['two', 'three']);
    buffer.add(
      const HermesDesktopEvent(
        type: 'message.delta',
        payload: {'delta': 'live'},
        sessionId: 'runtime-1',
      ),
    );
    check(buffer.hasPending('runtime-1')).isFalse();
  });

  test('bounds buffered events across unknown sessions', () {
    final buffer = HermesDesktopEventBuffer(
      maximumPerSession: 4,
      maximumSessions: 2,
      maximumTotalEvents: 2,
    );
    for (final session in const ['one', 'two', 'three']) {
      buffer.add(
        HermesDesktopEvent(
          type: 'message.delta',
          payload: {'delta': session},
          sessionId: session,
        ),
      );
    }

    check(buffer.hasPending('one')).isFalse();
    check(buffer.take('two')).length.equals(1);
    check(buffer.take('three')).length.equals(1);
  });

  group('server requests', () {
    late _SocketHarness socket;
    late HermesDesktopRpcClient client;
    late List<HermesDesktopEvent> events;

    setUp(() async {
      socket = _SocketHarness();
      client = HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => socket.channel,
      )..setDefaultParams({'profile': 'work'});
      events = [];
      client.events.listen(events.add);
      final connecting = client.connect(Uri.parse('ws://localhost/api/ws'));
      socket.ready();
      await connecting;
    });

    tearDown(() async {
      await client.close();
      await socket.dispose();
    });

    test('advertises answering them, without the default profile', () async {
      await Future<void>.delayed(Duration.zero);
      final handshake = socket.frames.single;
      check(handshake['method']).equals('client.capabilities');
      check(
        handshake['params'] as Map<String, dynamic>,
      ).deepEquals({'server_requests': true});
    });

    test('shows an approval as a decision and writes nothing back', () async {
      await socket.answerCapabilities();
      socket.serverRequest('srq-a1', 'approval', {
        'session_id': 'runtime-1',
        'request_id': 'queue-7',
        'command': 'rm -rf build',
        'description': 'delete in root path',
        'choices': ['once', 'session', 'always', 'deny'],
      });
      await Future<void>.delayed(Duration.zero);

      final approval = events.singleWhere(
        (event) => event.type == 'approval.request',
      );
      check(approval.sessionId).equals('runtime-1');
      check(approval.payload['request_id']).equals('srq-a1');
      check(approval.payload['approval_request_id']).equals('queue-7');
      check(approval.payload['command']).equals('rm -rf build');
      check(socket.frames.length).equals(1);
    });

    test('shows a clarify form one question at a time', () async {
      await socket.answerCapabilities();
      socket.serverRequest('srq-c1', 'clarify', {
        'session_id': 'runtime-1',
        'questions': [
          {
            'qid': 'q0',
            'question': 'Which colour?',
            'choices': ['Teal', 'Amber'],
            'multi_select': false,
          },
          {'qid': 'q1', 'question': 'Anything else?', 'choices': null},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      final first = events.singleWhere(
        (event) => event.type == 'clarify.request',
      );
      check(first.payload['request_id']).equals('srq-c1/q0');
      check(first.payload['question']).equals('1/2 · Which colour?');
      check(first.payload['choices'] as List).deepEquals(['Teal', 'Amber']);

      check(client.showNextClarifyQuestion('srq-c1/q0')).isTrue();
      await Future<void>.delayed(Duration.zero);
      final second = events.where((e) => e.type == 'clarify.request').last;
      check(second.payload['request_id']).equals('srq-c1/q1');
      check(second.payload['question']).equals('2/2 · Anything else?');

      check(client.showNextClarifyQuestion('srq-c1/q1')).isFalse();
    });

    test('a withdrawal closes the question shown now', () async {
      await socket.answerCapabilities();
      socket.serverRequest('srq-c2', 'clarify', {
        'session_id': 'runtime-1',
        'questions': [
          {'qid': 'q0', 'question': 'First?'},
          {'qid': 'q1', 'question': 'Second?'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      client.showNextClarifyQuestion('srq-c2/q0');
      socket.event('request.cancel', {
        'id': 'srq-c2',
        'method': 'clarify',
        'reason': 'timeout',
      }, session: 'runtime-1');
      await Future<void>.delayed(Duration.zero);

      final expired = events.singleWhere(
        (event) => event.type == 'clarify.expire',
      );
      check(expired.sessionId).equals('runtime-1');
      check(expired.payload['request_id']).equals('srq-c2/q1');
    });

    test('replays open requests, skipping answered questions', () async {
      client.replayOpenRequests([
        {
          'id': 'srq-r1',
          'method': 'clarify',
          'params': {
            'session_id': 'runtime-2',
            'questions': [
              {'qid': 'q0', 'question': 'First?'},
              {'qid': 'q1', 'question': 'Second?'},
            ],
            'answers': {'q0': 'yes'},
          },
        },
        {
          'id': 'srq-r2',
          'method': 'sudo',
          'params': {'session_id': 'runtime-2', 'command': 'apt update'},
        },
      ]);
      await Future<void>.delayed(Duration.zero);

      check(
        events
            .where((event) => event.type != 'gateway.ready')
            .map((event) => '${event.type} ${event.payload['request_id']}'),
      ).deepEquals(['clarify.request srq-r1/q1', 'sudo.request srq-r2']);
      check(events.last.payload['prompt']).equals('apt update');
    });

    test('shows a connection operation one waiting target at a time', () async {
      Map<String, Object?> target(String name, String state) => {
        'name': name,
        'kind': 'mcp',
        'action': 'install',
        'state': state,
        'launch': {'kind': 'stdio', 'target': 'npx demo-$name'},
      };
      socket.event('connection.request', {
        'op_id': 'op-1',
        'seq': 1,
        'deadline_at': 0,
        'timeout_seconds': 300,
        'targets': [target('docs', 'pending'), target('notes', 'pending')],
      }, session: 'runtime-1');
      await Future<void>.delayed(Duration.zero);
      final first = events.singleWhere(
        (event) => event.type == 'mcp.setup.request',
      );
      check(first.sessionId).equals('runtime-1');
      check(first.payload['request_id']).equals('op-1/docs');
      check(first.payload['action']).equals('install');
      check(first.payload['reason']).equals('npx demo-docs');

      socket.event('connection.update', {
        'op_id': 'op-1',
        'seq': 2,
        'settled': false,
        'owner': {'type': 'session', 'session_id': 'runtime-1'},
        'targets': [target('docs', 'connected'), target('notes', 'pending')],
      }, session: 'runtime-1');
      await Future<void>.delayed(Duration.zero);
      check(
        events
            .where((event) => event.type.startsWith('mcp.setup.'))
            .map((event) => '${event.type} ${event.payload['request_id']}'),
      ).deepEquals([
        'mcp.setup.request op-1/docs',
        'mcp.setup.expire op-1/docs',
        'mcp.setup.request op-1/notes',
      ]);

      socket.event('connection.update', {
        'op_id': 'op-1',
        'seq': 3,
        'settled': true,
        'owner': {'type': 'session', 'session_id': 'runtime-1'},
        'targets': [target('docs', 'connected'), target('notes', 'skipped')],
      }, session: 'runtime-1');
      await Future<void>.delayed(Duration.zero);
      check(events.last.type).equals('mcp.setup.expire');
      check(events.last.payload['request_id']).equals('op-1/notes');
    });

    test('a replay with newer answers moves the next question on', () async {
      final questions = [
        for (final qid in ['q0', 'q1', 'q2'])
          {'qid': qid, 'question': 'Pick $qid?'},
      ];
      socket.serverRequest('srq-c3', 'clarify', {
        'session_id': 'runtime-1',
        'questions': questions,
      });
      await Future<void>.delayed(Duration.zero);
      // Another surface answered q0 before this socket's resume.
      client.replayOpenRequests([
        {
          'id': 'srq-c3',
          'method': 'clarify',
          'params': {
            'session_id': 'runtime-1',
            'questions': questions,
            'answers': {'q0': 'Teal'},
          },
        },
      ]);
      await Future<void>.delayed(Duration.zero);
      check(
        events.where((e) => e.type == 'clarify.request').last,
      ).has((e) => e.payload['request_id'], 'request_id').equals('srq-c3/q1');

      check(client.showNextClarifyQuestion('srq-c3/q1')).isTrue();
      await Future<void>.delayed(Duration.zero);
      check(
        events.where((e) => e.type == 'clarify.request').last,
      ).has((e) => e.payload['request_id'], 'request_id').equals('srq-c3/q2');
    });

    test('the lock result names the questions still open', () async {
      socket.serverRequest('srq-c4', 'clarify', {
        'session_id': 'runtime-1',
        'questions': [
          for (final qid in ['q0', 'q1', 'q2'])
            {'qid': qid, 'question': 'Pick $qid?'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      // q1 was answered on another surface while q0 was shown here.
      check(
        client.showNextClarifyQuestion('srq-c4/q0', remaining: ['q2']),
      ).isTrue();
      await Future<void>.delayed(Duration.zero);
      check(
        events.where((e) => e.type == 'clarify.request').last,
      ).has((e) => e.payload['request_id'], 'request_id').equals('srq-c4/q2');
    });

    test('card ids keep a slash in either part', () {
      final id = hermesConnectionCardId('op-1', 'owner/skill~beta');
      check(id).equals('op-1/owner~1skill~0beta');
      final card = parseHermesConnectionCardId(id);
      check(card?.operationId).equals('op-1');
      check(card?.target).equals('owner/skill~beta');
      check(parseHermesClarifyCardId('srq-1/q0/extra')).isNull();
      check(parseHermesClarifyCardId('srq-1/')).isNull();
    });

    test('shows a target whose sign-in already started', () async {
      const link = 'https://auth.example/authorize?state=abc';
      Map<String, Object?> target(String state) => {
        'name': 'docs',
        'kind': 'mcp',
        'action': 'authorize',
        'state': state,
        if (state == 'initiated') 'connect_url': link,
      };
      socket.event('connection.request', {
        'op_id': 'op-2',
        'targets': [target('initiated')],
      }, session: 'runtime-1');
      await Future<void>.delayed(Duration.zero);

      final card = events.singleWhere((e) => e.type == 'mcp.setup.request');
      check(card.payload['request_id']).equals('op-2/docs');
      check(card.payload['action']).equals('authorize');
      check(client.connectionLink('op-2/docs')).equals(Uri.parse(link));

      socket.event('connection.update', {
        'op_id': 'op-2',
        'settled': true,
        'targets': [target('connected')],
      }, session: 'runtime-1');
      await Future<void>.delayed(Duration.zero);
      check(events.last.type).equals('mcp.setup.expire');
      check(client.connectionLink('op-2/docs')).isNull();
    });

    test('a target answered once is not asked about again', () async {
      Map<String, Object?> target(String name, String state, {String? url}) =>
          {
            'name': name,
            'kind': 'mcp',
            'action': 'install',
            'state': state,
            'connect_url': ?url,
          };
      void update(List<Map<String, Object?>> targets) => socket.event(
        'connection.update',
        {'op_id': 'op-3', 'targets': targets},
        session: 'runtime-1',
      );
      update([target('docs', 'pending'), target('notes', 'pending')]);
      // Approved: the install starts, then its sign-in link arrives.
      update([target('docs', 'initiated'), target('notes', 'pending')]);
      update([
        target('docs', 'initiated', url: 'https://auth.example/docs'),
        target('notes', 'pending'),
      ]);
      await Future<void>.delayed(Duration.zero);

      check(
        events
            .where((event) => event.type.startsWith('mcp.setup.'))
            .map((event) => '${event.type} ${event.payload['request_id']}'),
      ).deepEquals([
        'mcp.setup.request op-3/docs',
        'mcp.setup.expire op-3/docs',
        'mcp.setup.request op-3/notes',
      ]);
    });

    test('declines Desktop-only requests with 4404 once allowed', () async {
      socket.serverRequest('srq-t0', 'tour', {'session_id': 'runtime-1'});
      await Future<void>.delayed(Duration.zero);
      check(socket.frames.length).equals(1);

      await socket.answerCapabilities();
      socket.serverRequest('srq-t1', 'tour', {'session_id': 'runtime-1'});
      await Future<void>.delayed(Duration.zero);
      final decline = socket.frames.last;
      check(decline['id']).equals('srq-t1');
      check((decline['error'] as Map)['code']).equals(4404);
      check(events.where((event) => event.type != 'gateway.ready')).isEmpty();
    });
  });

  group('reply segments', () {
    test('drop a re-sent segment and keep only new text', () {
      final segments = HermesDeltaSegments();
      String? seen(int offset, String text, {int segment = 0}) =>
          segments.unseen(
            turnId: 'turn-1',
            segment: segment,
            offset: offset,
            text: text,
          );

      check(seen(0, 'Hello ')).equals('Hello ');
      check(seen(6, 'there')).equals('there');
      // A replay re-sends the segment from its start.
      check(seen(0, 'Hello ')).isNull();
      check(seen(0, 'Hello there, friend')).equals(', friend');
      // Another segment of the same turn counts from zero.
      check(seen(0, 'Next', segment: 1)).equals('Next');
    });

    test('pass through deltas without positions', () {
      final segments = HermesDeltaSegments();
      check(
        segments.unseen(turnId: null, segment: null, offset: null, text: 'a'),
      ).equals('a');
      check(
        segments.unseen(turnId: null, segment: null, offset: null, text: 'a'),
      ).equals('a');
    });

    test('count offsets in UTF-16 code units', () {
      final segments = HermesDeltaSegments();
      String? seen(int offset, String text) => segments.unseen(
        turnId: 't',
        segment: 0,
        offset: offset,
        text: text,
      );
      check(seen(0, '🙂 ok')).equals('🙂 ok');
      check(seen(0, '🙂 ok!')).equals('!');
    });
  });

  test('error data reaches the caller', () async {
    final socket = _SocketHarness();
    final client = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => socket.channel,
    );
    addTearDown(() async {
      await client.close();
      await socket.dispose();
    });
    final connecting = client.connect(Uri.parse('ws://localhost/api/ws'));
    socket.ready({'heartbeat': false, 'session_authority': true});
    await connecting;
    check(client.sessionAuthority).isTrue();

    final submit = client.request<Object?>(
      'prompt.submit',
      includeDefaultParams: false,
    );
    await Future<void>.delayed(Duration.zero);
    socket.incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': socket.sentFrame(0)['id'],
        'error': {
          'code': 4090,
          'message': 'busy',
          'data': {'reason': 'SESSION_OWNER_BUSY'},
        },
      }),
    );
    await check(submit).throws<HermesDesktopRpcException>(
      (error) => error
        ..has((error) => error.code, 'code').equals(4090)
        ..has((error) => error.reason, 'reason').equals('SESSION_OWNER_BUSY'),
    );
  });

  test('times out requests and rejects pending work on disconnect', () async {
    final socket = _SocketHarness();
    final client = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => socket.channel,
      requestTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(() async {
      await client.close();
      await socket.dispose();
    });
    final connecting = client.connect(Uri.parse('ws://localhost/api/ws'));
    socket.ready();
    await connecting;

    await expectLater(
      client.request<Object?>('slow'),
      throwsA(
        isA<HermesDesktopRpcException>().having(
          (error) => error.timedOut,
          'timedOut',
          isTrue,
        ),
      ),
    );
    final pending = client.request<Object?>('pending');
    final pendingExpectation = expectLater(
      pending,
      throwsA(isA<HermesDesktopRpcException>()),
    );
    await client.disconnect();
    await pendingExpectation;
  });

  test('reports an unexpected post-ready socket close', () async {
    final socket = _SocketHarness();
    final client = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => socket.channel,
    );
    addTearDown(client.close);
    final connecting = client.connect(Uri.parse('ws://localhost/api/ws'));
    socket.ready();
    await connecting;

    final disconnected = client.disconnects.first;
    await socket.incoming.close();
    await disconnected;
    check(client.isReady).isFalse();
  });

  test('does not forward access headers across a handshake redirect', () async {
    String? leakedHeader;
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((request) async {
      leakedHeader = request.headers.value('X-Access-Key');
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
    });
    final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    redirect.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'ws://127.0.0.1:${target.port}/api/ws',
      );
      await request.response.close();
    });
    addTearDown(() async {
      await redirect.close(force: true);
      await target.close(force: true);
    });

    final client = HermesDesktopRpcClient();
    addTearDown(client.close);
    await expectLater(
      client.connect(
        Uri.parse('ws://127.0.0.1:${redirect.port}/api/ws'),
        headers: const {'X-Access-Key': 'secret'},
      ),
      throwsA(anything),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    check(leakedHeader).isNull();
  });

  test('manual no-redirect handshake reaches gateway.ready', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': {}},
        }),
      );
    });
    addTearDown(() => server.close(force: true));
    final client = HermesDesktopRpcClient();
    addTearDown(client.close);

    await client.connect(Uri.parse('ws://127.0.0.1:${server.port}/api/ws'));
    check(client.isReady).isTrue();
  });
}
