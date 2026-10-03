import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_controller_gateways.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_session_controller.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'fake_terminal_screen.dart';

void main() {
  final server = TerminalServerInfo(
    kind: TerminalServerKind.direct,
    selectionId: 'http://127.0.0.1:8000',
    baseUrl: Uri.parse('http://127.0.0.1:8000'),
    apiKey: 'key-1',
  );

  late _MockTerminalService service;
  late _FakeGateway gateway;
  late FakeTerminalScreen screen;
  late TerminalSessionController session;

  setUp(() {
    service = _MockTerminalService();
    gateway = _FakeGateway();
    screen = FakeTerminalScreen();
    session = TerminalSessionController(
      gateway: gateway,
      isCurrentContext: (_, _) => true,
      screen: screen,
    );
    when(() => service.authTokenForServer(server)).thenReturn('key-1');
    when(() => service.createSession(server, sessionScopeId: 'scope'))
        .thenAnswer(
          (_) async => const TerminalSessionInfo(
            serverSelectionId: 'http://127.0.0.1:8000',
            sessionId: 'abc',
            sessionScopeId: 'scope',
          ),
        );
    when(() => service.buildWebSocketUri(server, 'abc'))
        .thenReturn(Uri.parse('ws://127.0.0.1:8000/api/terminals/abc'));
  });

  tearDown(() => session.dispose());

  Future<void> connect() => session.connect(
    service,
    server,
    sessionScopeId: 'scope',
    disconnectedLabel: 'Disconnected',
    onFailure: () => fail('connect failed'),
  );

  test('connects, authenticates, then reports the grid size', () async {
    await connect();

    check(gateway.connectionState.isConnected).isTrue();
    check(gateway.openedUri)
        .equals(Uri.parse('ws://127.0.0.1:8000/api/terminals/abc'));
    final frames = gateway.channel.sent
        .map((frame) => jsonDecode(frame as String))
        .toList();
    check(frames).deepEquals([
      {'type': 'auth', 'token': 'key-1'},
      {'type': 'resize', 'cols': 80, 'rows': 24},
    ]);
  });

  test('keystrokes from the screen go out as UTF-8 bytes', () async {
    await connect();
    gateway.channel.sent.clear();

    screen.output!('ls é\r');

    check(gateway.channel.sent).deepEquals([utf8.encode('ls é\r')]);
  });

  test('a grid resize sends the new size, not the old one', () async {
    await connect();
    gateway.channel.sent.clear();

    // xterm reports a resize before it updates viewWidth/viewHeight: the
    // screen still answers the old size while the callback runs.
    screen.resized!(42, 17);

    check(
      jsonDecode(gateway.channel.sent.single as String) as Map<String, Object?>,
    ).deepEquals({'type': 'resize', 'cols': 42, 'rows': 17});
  });

  test('text and binary output reach the screen', () async {
    await connect();

    gateway.channel.incoming
      ..add('\x1b[31mred\x1b[0m ')
      ..add(utf8.encode('bytes'));
    await pumpEventQueue();

    check(screen.written.toString()).equals('\x1b[31mred\x1b[0m bytes');
  });

  test('a closed socket disconnects and writes the banner', () async {
    await connect();

    await gateway.channel.incoming.close();
    await pumpEventQueue();

    check(gateway.connectionState.status)
        .equals(TerminalConnectionStatus.disconnected);
    check(screen.written.toString()).equals('\r\n[Disconnected]\r\n');
    check(gateway.activeSession).isNull();
  });

  test('without a token the connection fails before any request', () async {
    when(() => service.authTokenForServer(server)).thenReturn(null);
    var failed = false;

    await session.connect(
      service,
      server,
      sessionScopeId: 'scope',
      disconnectedLabel: 'Disconnected',
      onFailure: () => failed = true,
    );

    check(failed).isTrue();
    check(gateway.connectionState.status)
        .equals(TerminalConnectionStatus.error);
    verifyNever(
      () => service.createSession(
        server,
        sessionScopeId: any(named: 'sessionScopeId'),
      ),
    );
  });

  test('dispose detaches the screen callbacks', () async {
    await connect();

    session.dispose();

    check(screen.output).isNull();
    check(screen.resized).isNull();
  });
}

final class _MockTerminalService extends Mock implements TerminalService {}

final class _FakeGateway implements TerminalSessionGateway {
  @override
  TerminalConnectionState connectionState =
      const TerminalConnectionState.disconnected();

  TerminalSessionInfo? activeSession;
  Uri? openedUri;
  final _FakeChannel channel = _FakeChannel();

  @override
  WebSocketChannel openChannel(Uri uri, {required TerminalServerKind kind}) {
    openedUri = uri;
    return channel;
  }

  @override
  void setActiveSession(TerminalSessionInfo? session) =>
      activeSession = session;

  @override
  void setConnectionState(TerminalConnectionState state) =>
      connectionState = state;
}

final class _FakeChannel implements WebSocketChannel {
  final StreamController<dynamic> incoming = StreamController<dynamic>();
  final List<Object?> sent = <Object?>[];
  late final _FakeSink _sink = _FakeSink(sent);

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeSink implements WebSocketSink {
  _FakeSink(this.sent);

  final List<Object?> sent;

  @override
  void add(Object? data) => sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
