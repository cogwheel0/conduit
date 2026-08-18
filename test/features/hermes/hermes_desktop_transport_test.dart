import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_mcp.dart';
import 'package:flutter_test/flutter_test.dart';
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

  void ready() => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {'type': 'gateway.ready', 'payload': {}},
    }),
  );

  Map<String, dynamic> sentFrame(int index) =>
      Map<String, dynamic>.from(jsonDecode(sent[index]) as Map);

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

    check(offsets).deepEquals([0, 500]);
    check(messages).length.equals(750);
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

  test(
    'rejects unsupported host requests without invoking mobile features',
    () async {
      final socket = _SocketHarness();
      final client = HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => socket.channel,
      );
      addTearDown(() async {
        await client.close();
        await socket.dispose();
      });
      final connecting = client.connect(Uri.parse('ws://localhost/api/ws'));
      socket.ready();
      await connecting;

      socket.incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 'host-1',
          'method': 'terminal.open',
          'params': {},
        }),
      );
      await Future<void>.delayed(Duration.zero);

      final response = socket.sentFrame(0);
      check(response['id']).equals('host-1');
      check((response['error'] as Map)['code']).equals(-32601);
    },
  );

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
