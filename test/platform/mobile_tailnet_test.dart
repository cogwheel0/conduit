import 'dart:convert';
import 'dart:io';

import 'package:conduit/platform/mobile_tailnet.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'sign-in is explicit, survives suspension, and can be forgotten offline',
    () async {
      final storage = InMemorySecureKeyValueStore();
      final dir = await Directory.systemTemp.createTemp('synthetic-tailnet');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final operations = <String>[];
      final keys = <String>[];
      final node = MobileTailnet(
        storage: storage,
        directory: () async => dir,
        openLogin: (_) async => fail('unexpected browser'),
        call: (cmd) async {
          operations.add(cmd['op'] as String);
          if (cmd['op'] == 'start') keys.add(cmd['key'] as String);
          if (cmd['op'] == 'logout') throw const SocketException('offline');
          return {'state': 'Running'};
        },
      );
      await node.refresh();
      expect(node.state, TailnetState.signedOut);
      await expectLater(
        node.connect(Uri.parse('http://orchard.test'), null, null),
        throwsA(isA<SocketException>()),
      );
      expect(operations, isEmpty);
      await node.signIn();
      expect(node.state, TailnetState.connected);
      await node.lifecycle(true);
      expect(node.state, TailnetState.idle);
      await expectLater(
        node.connect(Uri.parse('http://orchard.test'), null, null),
        throwsA(isA<SocketException>()),
      );
      await node.lifecycle(false);
      await node.signIn();
      expect(keys, hasLength(2));
      expect(keys.first, keys.last);
      await node.signOut();
      expect(operations, ['start', 'stop', 'start', 'logout']);
      expect(await storage.readAll(), isEmpty);
      expect(await dir.exists(), isFalse);
      expect(node.state, TailnetState.signedOut);
    },
  );

  test(
    'TLS keeps the peer hostname and rejects an untrusted peer by default',
    () async {
      final dir = await Directory.systemTemp.createTemp('synthetic-tls-peer');
      addTearDown(() => dir.delete(recursive: true));
      final result = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '1',
        '-subj',
        '/CN=orchard.test',
        '-keyout',
        'key.pem',
        '-out',
        'cert.pem',
      ], workingDirectory: dir.path);
      expect(result.exitCode, 0);
      final identity = SecurityContext()
        ..useCertificateChain('${dir.path}/cert.pem')
        ..usePrivateKey('${dir.path}/key.pem');
      final peer = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        identity,
      );
      addTearDown(() => peer.close(force: true));
      peer.listen((request) async {
        request.response.write('paper kite');
        await request.response.close();
      });
      final handoff = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(handoff.close);
      const ticket = 'synthetic-ticket';
      handoff.listen((client) async {
        final remote = await Socket.connect(
          InternetAddress.loopbackIPv4,
          peer.port,
        );
        var consumed = 0;
        client.listen(
          (bytes) {
            final remaining = ticket.length - consumed;
            final skip = bytes.length < remaining ? bytes.length : remaining;
            expect(
              bytes.take(skip),
              ascii.encode(ticket).skip(consumed).take(skip),
            );
            consumed += skip;
            if (skip < bytes.length) remote.add(bytes.sublist(skip));
          },
          onDone: remote.close,
          onError: (_) => remote.destroy(),
        );
        remote.listen(
          client.add,
          onDone: client.close,
          onError: (_) => client.destroy(),
        );
      });
      final node = MobileTailnet(
        storage: InMemorySecureKeyValueStore(),
        directory: () async => dir,
        openLogin: (_) async => fail('unexpected browser'),
        call: (command) async => command['op'] == 'dial'
            ? {'port': handoff.port, 'ticket': ticket}
            : {'state': 'Running'},
      );
      await node.signIn();
      final uri = Uri.parse('https://orchard.test:${peer.port}');
      final untrusted = await node.connect(uri, null, null);
      await expectLater(untrusted.socket, throwsA(isA<HandshakeException>()));
      final trusted = await node.connect(uri, null, (certificate, host, port) {
        expect(host, 'orchard.test');
        expect(port, peer.port);
        return true;
      });
      final socket = await trusted.socket;
      socket.write('GET / HTTP/1.0\r\nHost: orchard.test\r\n\r\n');
      expect(await utf8.decoder.bind(socket).join(), contains('paper kite'));
      socket.destroy();
    },
  );

  testWidgets('an abandoned browser login stops the node in the background', (
    tester,
  ) async {
    var stops = 0;
    final node = MobileTailnet(
      storage: InMemorySecureKeyValueStore(),
      directory: () async => Directory.fromUri(
        Directory.systemTemp.uri.resolve('unused-synthetic-node'),
      ),
      openLogin: (_) async => true,
      call: (command) async {
        if (command['op'] == 'stop') stops++;
        return {
          'state': 'NeedsLogin',
          'loginURL': 'https://login.tailscale.com/example',
        };
      },
    );
    await node.signIn();
    await node.lifecycle(true);
    await tester.pump(const Duration(minutes: 2));
    expect(stops, 1);
    expect(node.state, TailnetState.authorizing);
  });

  test(
    'browser handoff and outstanding authorization can be cancelled',
    () async {
      final urls = <Uri>[];
      final dir = await Directory.systemTemp.createTemp('synthetic-enrollment');
      final node = MobileTailnet(
        storage: InMemorySecureKeyValueStore(),
        directory: () async => dir,
        openLogin: (url) async {
          urls.add(url);
          return true;
        },
        call: (_) async => {
          'state': 'NeedsLogin',
          'loginURL': 'https://login.tailscale.com/example',
        },
      );
      await node.signIn();
      expect(node.state, TailnetState.authorizing);
      expect(urls.single.host, 'login.tailscale.com');
      await node.lifecycle(true);
      await node.lifecycle(false);
      await node.signOut();
      expect(node.state, TailnetState.signedOut);
    },
  );
}
