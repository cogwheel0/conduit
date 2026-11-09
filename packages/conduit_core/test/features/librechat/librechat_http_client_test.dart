import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/testing.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// A store that records the order of writes against the requests the fake
/// server sees, to prove a renewed cookie is saved before any retry runs.
final class _OrderedStore implements LibreChatSessionStore {
  _OrderedStore(this.fake);

  final FakeLibreChatServer fake;
  final List<String> events = <String>[];
  LibreChatSession? session;

  @override
  Future<void> clear() async {
    events.add('clear');
    session = null;
  }

  @override
  Future<LibreChatSession?> read() async => session;

  @override
  Future<void> write(LibreChatSession session) async {
    events.add('save after ${fake.requests.length} requests');
    this.session = session;
  }
}

/// What [future] failed with, which must be a [T].
Future<T> _thrown<T extends Object>(Future<Object?> future) async {
  try {
    await future;
  } on T catch (error) {
    return error;
  }
  fail('Expected a $T.');
}

void main() {
  const server = LibreChatServer(
    baseUrl: 'https://chat.example.com',
    customHeaders: {
      'X-Proxy-Key': 'k',
      'User-Agent': 'curl/8',
      'Origin': 'https://evil.com',
      'Cookie': 'stolen=1',
    },
  );
  late FakeLibreChatServer fake;
  late LibreChatAuthService auth;
  late DateTime now;

  setUp(() {
    now = DateTime.now().toUtc();
    fake = FakeLibreChatServer(clock: () => now);
    auth = LibreChatAuthService(server, adapter: fake, clock: () => now);
    fake.addUser();
  });
  tearDown(() => auth.close());

  Future<LibreChatSession> signIn() async =>
      ((await auth.signIn(email: 'dev@example.com', password: 'devpassword'))
              as LibreChatSignedIn)
          .session;

  Future<(LibreChatHttpClient, LibreChatSessionHandle, _OrderedStore)>
  connect() async {
    final store = _OrderedStore(fake);
    final handle = LibreChatSessionHandle(
      session: await signIn(),
      store: store,
      renew: auth.renew,
      clock: () => now,
    );
    final client = LibreChatHttpClient(
      server: server,
      session: handle,
      adapter: fake,
      clock: () => now,
    );
    addTearDown(client.close);
    return (client, handle, store);
  }

  test('every request carries the browser User-Agent, the session and the '
      'proxy headers, and never an Origin', () async {
    final (client, handle, _) = await connect();
    await client.dio.get<dynamic>(
      '/api/user',
      options: Options(headers: {'origin': 'https://chat.example.com'}),
    );
    final request = fake.requests.last;
    check(
      FakeLibreChatServer.looksLikeBrowser(request.header('user-agent')),
    ).isTrue();
    check(request.header('origin')).isNull();
    check(request.header('x-proxy-key')).equals('k');
    check(request.bearer).equals(handle.current!.accessToken);
    check(
      request.cookies['refreshToken'],
    ).equals(handle.current!.cookies.value('refreshToken'));
    check(request.cookies.containsKey('stolen')).isFalse();
  });

  test('the fake server refuses an access token past its expiry', () async {
    final session = await signIn();
    final client = LibreChatHttpClient(
      server: server,
      adapter: fake,
      clock: () => now,
    );
    addTearDown(client.close);
    Future<int?> status() async {
      try {
        final response = await client.dio.get<dynamic>(
          '/api/user',
          options: Options(
            headers: {'Authorization': 'Bearer ${session.accessToken}'},
            extra: const {LibreChatRequestExtra.authenticate: false},
          ),
        );
        return response.statusCode;
      } on DioException catch (error) {
        return error.response?.statusCode;
      }
    }

    check(await status()).equals(200);
    now = now.add(fake.accessTokenTtl);
    check(await status()).equals(401);
  });

  test('never sends the session to another origin', () async {
    final (client, _, _) = await connect();
    final before = fake.requests.length;
    final refused = await _thrown<DioException>(
      client.dio.get<dynamic>('https://evil.com/api/user'),
    );
    check(refused.error).isA<LibreChatApiException>();
    check(fake.requests.length).equals(before);
  });

  test('a refused token renews once for concurrent requests, and the new '
      'cookie is saved before any retry', () async {
    final (client, handle, store) = await connect();
    final firstToken = handle.current!.accessToken;
    fake.expireAccessTokens();
    final hold = fake.holdRefresh = Completer<void>();

    final requests = [
      for (var i = 0; i < 3; i++) client.dio.get<dynamic>('/api/user'),
    ];
    // All three are refused before the renewal answers.
    await pumpEventQueue();
    hold.complete();
    final responses = await Future.wait(requests);

    check(responses.map((response) => response.statusCode)).every(
      (it) => it.equals(200),
    );
    check(fake.refreshCalls).equals(1);
    check(handle.current!.accessToken).not((it) => it.equals(firstToken));
    final refreshIndex = fake.requests.indexWhere(
      (request) => request.path == '/api/auth/refresh',
    );
    check(store.events).deepEquals(['save after ${refreshIndex + 1} requests']);
    // Every retry went out after the save, with the renewed token.
    final retries = fake.requests.skip(refreshIndex + 1).toList();
    check(retries).length.equals(3);
    for (final retry in retries) {
      check(retry.bearer).equals(handle.current!.accessToken);
    }
  });

  test('a token about to lapse renews before the request', () async {
    final (client, handle, store) = await connect();
    final firstToken = handle.current!.accessToken;
    now = now.add(const Duration(minutes: 14, seconds: 45));
    await client.dio.get<dynamic>('/api/user');
    check(fake.refreshCalls).equals(1);
    check(fake.requests.last.bearer).not((it) => it.equals(firstToken));
    check(store.events).length.equals(1);
    // No request was refused on the way.
    check(
      fake.requests.where((request) => request.path == '/api/user'),
    ).length.equals(1);
  });

  test('an ended session fails the request and clears the store', () async {
    final (client, handle, store) = await connect();
    fake.endSessions();
    final ended = expectLater(handle.changes, emits(isNull));
    final failure = await _thrown<DioException>(
      client.dio.get<dynamic>('/api/user'),
    );
    check(failure.error).isA<LibreChatSessionExpiredException>();
    await ended;
    check(handle.isEnded).isTrue();
    check(store.events).deepEquals(['clear']);
    await check(
      client.dio.get<dynamic>('/api/user'),
    ).throws<DioException>();
    check(fake.refreshCalls).equals(1);
  });

  test('a renewal that fails transiently keeps the session', () async {
    final (client, handle, _) = await connect();
    fake.expireAccessTokens();
    fake.on(
      'POST',
      '/api/auth/refresh',
      (request, match) =>
          FakeLibreChatResponse.json({'message': 'busy'}, statusCode: 503),
    );
    final failure = await _thrown<DioException>(
      client.dio.get<dynamic>('/api/user'),
    );
    check(failure.response?.statusCode).equals(401);
    check(handle.isEnded).isFalse();
  });

  test('cookies a response sets join the session', () async {
    final (client, handle, store) = await connect();
    fake.on(
      'GET',
      '/api/banner',
      (request, match) => FakeLibreChatResponse.json(
        null,
        setCookies: ['connect.sid=s%3Anew; Path=/; HttpOnly'],
      ),
    );
    await client.dio.get<dynamic>('/api/banner');
    check(handle.current!.cookies.value('connect.sid')).equals('s%3Anew');
    check(store.session!.cookies.value('connect.sid')).equals('s%3Anew');
  });

  test('uaParser\'s "Illegal request" surfaces as its own error', () async {
    final client = LibreChatHttpClient(
      server: server,
      adapter: fake,
      userAgent: 'Conduit/4.2.1',
    );
    addTearDown(client.close);
    final refused = await _thrown<DioException>(
      client.dio.get<dynamic>(
        '/api/agents',
        options: Options(
          extra: const {LibreChatRequestExtra.authenticate: false},
        ),
      ),
    );
    check(refused.error).isA<LibreChatIllegalRequestException>();
    check(fake.violations).equals(1);
  });

  test('only a short error frame reads as "Illegal request"', () {
    const frame = 'event: error\ndata: {"message":"Illegal request"}\n\n';
    check(LibreChatIllegalRequestException.matches(frame)).isTrue();
    check(LibreChatIllegalRequestException.matches(frame.codeUnits)).isTrue();
    // A message or file that happens to quote the frame is a real response.
    check(
      LibreChatIllegalRequestException.matches('Quoting: $frame'),
    ).isFalse();
    check(
      LibreChatIllegalRequestException.matches('$frame${'x' * 400}'),
    ).isFalse();
    check(LibreChatIllegalRequestException.matches({'x': frame})).isFalse();
  });

  test('signing out while a renewal runs keeps its cookie out', () async {
    final (client, handle, store) = await connect();
    fake.expireAccessTokens();
    final hold = fake.holdRefresh = Completer<void>();
    final request = client.dio.get<dynamic>('/api/user');
    await pumpEventQueue();
    await handle.end();
    hold.complete();
    await check(request).throws<DioException>();
    check(store.session).isNull();
    check(store.events).deepEquals(['clear']);
  });
}
