@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'support/null_sink.dart';

const String _token = 'cJkVQ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';
final String _masterKey = base64.encode(List<int>.filled(32, 7));

/// One daemon for the file.
///
/// `Hive.init` and `PreferencesStore` are process-global, so a second
/// `CoreRuntime` in this isolate would not be a second daemon -- it would be
/// the same global storage under a new container, which is not a thing the
/// product ever does. Tests that need isolation use a distinct server id.
void main() {
  late Directory tempDir;
  late DaemonServer server;
  late int port;
  late json_rpc.Peer peer;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('conduitd_servers_rpc');
    final config = BootstrapConfig(
      sessionToken: _token,
      masterKey: _masterKey,
      userDataDir: tempDir.path,
    );
    final directories = DaemonDirectories.create(tempDir.path);
    final log = DaemonLog(level: 'error', sink: NullSink());

    server = DaemonServer(
      config: config,
      directories: directories,
      daemonVersion: '0.0.0-test',
      log: log,
    );
    port = await server.start();
    server.attachCore(
      await CoreRuntime.start(
        config: config,
        directories: directories,
        log: log,
      ),
    );

    final socket = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
      protocols: buildSubprotocols(_token),
      headers: <String, dynamic>{'Origin': kConduitAppOrigin},
    );
    await socket.ready;
    peer = json_rpc.Peer(socket.cast<String>());
    unawaited(peer.listen());
    await callTyped<HandshakeResponse>(
      peer,
      ConduitMethods.systemHandshake,
      params: const HandshakeRequest(
        protocolVersion: kConduitProtocolVersion,
        clientName: 'test',
        clientVersion: '0.0.0',
        windowKind: WindowKind.headless,
        locale: 'en',
      ).toJson(),
      decodeResult: HandshakeResponse.fromJson,
    );
  });

  tearDownAll(() async {
    await peer.close();
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<ServerList> list() => callTyped<ServerList>(
    peer,
    ConduitMethods.serversList,
    decodeResult: ServerList.fromJson,
  );

  Future<ServerSummary> add(ServerDraft draft) => callTyped<ServerSummary>(
    peer,
    ConduitMethods.serversAdd,
    params: draft.toJson(),
    decodeResult: ServerSummary.fromJson,
  );

  group('servers.*', () {
    test('a fresh daemon has no servers, which is onboarding', () async {
      final result = await list();
      expect(result.servers, isEmpty);
      expect(result.activeServerId, isNull);
    });

    test('add returns a summary and list reflects it', () async {
      final added = await add(
        const ServerDraft(name: 'Home', url: 'https://chat.example.com'),
      );
      expect(added.name, 'Home');
      expect(added.url, 'https://chat.example.com');
      expect(added.id, isNotEmpty);

      final result = await list();
      expect(result.servers.map((s) => s.id), contains(added.id));
    });

    test(
      'at most one server reports isActive, and it is the active id',
      () async {
        await add(
          const ServerDraft(name: 'One', url: 'https://one.example.com'),
        );
        await add(
          const ServerDraft(name: 'Two', url: 'https://two.example.com'),
        );

        final result = await list();
        final active = result.servers.where((s) => s.isActive).toList();
        expect(active.length, lessThanOrEqualTo(1));
        if (result.activeServerId == null) {
          expect(active, isEmpty);
        } else {
          expect(active.single.id, result.activeServerId);
        }
      },
    );

    test('adding does not make it active', () async {
      final added = await add(
        const ServerDraft(name: 'Second', url: 'https://second.example.com'),
      );
      final result = await list();
      expect(result.activeServerId, isNot(added.id));
    });

    test('a secret never comes back', () async {
      final added = await add(
        const ServerDraft(
          name: 'Secretive',
          url: 'https://secretive.example.com',
          mtlsCertificateChainPem: '-----BEGIN CERTIFICATE-----\nxyz\n',
          mtlsCertificateLabel: 'corp.pem',
          mtlsPrivateKeyPem: '-----BEGIN PRIVATE KEY-----\nabc\n',
          mtlsPrivateKeyLabel: 'corp-key.pem',
          mtlsPrivateKeyPassword: 'hunter2',
          customHeaders: <String, String>{'X-Proxy-Token': 'bearer-secret'},
        ),
      );

      // The typed view says a credential exists, and names the file the user
      // picked, and no more.
      expect(added.hasMutualTlsCredentials, isTrue);
      expect(added.mtlsPrivateKeyLabel, 'corp-key.pem');
      expect(added.customHeaderNames, <String>['X-Proxy-Token']);

      // And the encoded frame really does not contain the values -- asserted
      // on the JSON rather than on the Dart object, because the wire is what
      // the renderer actually sees.
      final encoded = jsonEncode(added.toJson());
      expect(encoded, isNot(contains('BEGIN PRIVATE KEY')));
      expect(encoded, isNot(contains('BEGIN CERTIFICATE')));
      expect(encoded, isNot(contains('hunter2')));
      expect(encoded, isNot(contains('bearer-secret')));
    });

    test('update leaves a secret alone when it is not resent', () async {
      final added = await add(
        const ServerDraft(
          name: 'Keeps',
          url: 'https://keeps.example.com',
          mtlsCertificateChainPem: '-----BEGIN CERTIFICATE-----\nkeep\n',
          mtlsPrivateKeyPem: '-----BEGIN PRIVATE KEY-----\nkeep\n',
          mtlsPrivateKeyLabel: 'keep-key.pem',
        ),
      );
      expect(added.hasMutualTlsCredentials, isTrue);

      final renamed = await callTyped<ServerSummary>(
        peer,
        ConduitMethods.serversUpdate,
        params: ServerDraft(
          id: added.id,
          name: 'Renamed',
          url: 'https://keeps.example.com',
        ).toJson(),
        decodeResult: ServerSummary.fromJson,
      );

      expect(renamed.name, 'Renamed');
      // The form was never given the private key, so it could not resend it
      // -- and that must not be read as "delete it".
      expect(renamed.hasMutualTlsCredentials, isTrue);
      expect(renamed.mtlsPrivateKeyLabel, 'keep-key.pem');
    });

    test('clearMutualTls is how a client certificate is removed', () async {
      final added = await add(
        const ServerDraft(
          name: 'Clears',
          url: 'https://clears.example.com',
          mtlsCertificateChainPem: '-----BEGIN CERTIFICATE-----\ngone\n',
          mtlsPrivateKeyPem: '-----BEGIN PRIVATE KEY-----\ngone\n',
          mtlsPrivateKeyLabel: 'gone-key.pem',
        ),
      );
      expect(added.hasMutualTlsCredentials, isTrue);

      final cleared = await callTyped<ServerSummary>(
        peer,
        ConduitMethods.serversUpdate,
        params: ServerDraft(
          id: added.id,
          name: 'Clears',
          url: 'https://clears.example.com',
          clearMutualTls: true,
        ).toJson(),
        decodeResult: ServerSummary.fromJson,
      );

      expect(cleared.hasMutualTlsCredentials, isFalse);
      expect(cleared.mtlsPrivateKeyLabel, isNull);
    });

    test('a trailing slash does not make a second server', () async {
      final added = await add(
        const ServerDraft(name: 'Slash', url: 'https://slash.example.com/'),
      );
      expect(added.url, 'https://slash.example.com');
    });

    group('rejects a url that is not http(s)', () {
      for (final url in <String>[
        'file:///etc/passwd',
        'data:text/plain,hello',
        'not a url at all',
        '/relative/path',
        'https://',
      ]) {
        test(url, () async {
          expect(
            () => add(ServerDraft(name: 'Bad', url: url)),
            throwsA(
              isA<RpcError>().having(
                (e) => e.code,
                'code',
                ConduitErrorCodes.invalidParams,
              ),
            ),
          );
        });
      }
    });

    test('rejects an empty name', () async {
      expect(
        () => add(const ServerDraft(name: '   ', url: 'https://x.example.com')),
        throwsA(isA<RpcError>()),
      );
    });

    test('updating an unknown id is resource.notFound', () async {
      expect(
        () => callTyped<ServerSummary>(
          peer,
          ConduitMethods.serversUpdate,
          params: const ServerDraft(
            id: 'no-such-server',
            name: 'X',
            url: 'https://x.example.com',
          ).toJson(),
          decodeResult: ServerSummary.fromJson,
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.notFound,
          ),
        ),
      );
    });

    test('connect makes that server active and supersedes the rest', () async {
      final first = await add(
        const ServerDraft(name: 'Alpha', url: 'https://alpha.example.com'),
      );
      await add(
        const ServerDraft(name: 'Beta', url: 'https://beta.example.com'),
      );

      final after = await callTyped<ServerList>(
        peer,
        ConduitMethods.serversConnect,
        params: ServerRef(id: first.id).toJson(),
        decodeResult: ServerList.fromJson,
      );

      expect(after.activeServerId, first.id);
      expect(after.servers.where((s) => s.isActive).single.id, first.id);

      // The core keeps a single `auth_token_v3`, so connecting replaces the
      // configured list rather than leaving a second server addressable with
      // a token that does not belong to it. Asserted because it is
      // surprising, and a caller that did not know would present this as
      // "switch account" and quietly delete the user's other servers.
      expect(after.servers.map((s) => s.id), <String>[first.id]);
    });

    test('connecting to an unknown id is resource.notFound', () async {
      expect(
        () => callTyped<ServerList>(
          peer,
          ConduitMethods.serversConnect,
          params: const ServerRef(id: 'no-such-server').toJson(),
          decodeResult: ServerList.fromJson,
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.notFound,
          ),
        ),
      );
    });

    test('removing the active server leaves none active', () async {
      final only = await add(
        const ServerDraft(name: 'Solo', url: 'https://solo.example.com'),
      );
      await callTyped<ServerList>(
        peer,
        ConduitMethods.serversConnect,
        params: ServerRef(id: only.id).toJson(),
        decodeResult: ServerList.fromJson,
      );

      final after = await callTyped<ServerList>(
        peer,
        ConduitMethods.serversRemove,
        params: ServerRef(id: only.id).toJson(),
        decodeResult: ServerList.fromJson,
      );

      // Never auto-promote whichever server happens to be next: that would
      // connect the user somewhere they did not ask to go.
      expect(after.activeServerId, isNull);
      expect(after.servers.where((s) => s.isActive), isEmpty);
    });

    test('remove drops it and returns the new list', () async {
      final added = await add(
        const ServerDraft(name: 'Doomed', url: 'https://doomed.example.com'),
      );

      final after = await callTyped<ServerList>(
        peer,
        ConduitMethods.serversRemove,
        params: ServerRef(id: added.id).toJson(),
        decodeResult: ServerList.fromJson,
      );

      expect(after.servers.map((s) => s.id), isNot(contains(added.id)));
    });

    test('removing an unknown id is resource.notFound', () async {
      expect(
        () => callTyped<ServerList>(
          peer,
          ConduitMethods.serversRemove,
          params: const ServerRef(id: 'no-such-server').toJson(),
          decodeResult: ServerList.fromJson,
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.notFound,
          ),
        ),
      );
    });
  });

  group('auth.*', () {
    test('a fresh daemon reports no session', () async {
      final snapshot = await callTyped<AuthSnapshot>(
        peer,
        ConduitMethods.authStatus,
        decodeResult: AuthSnapshot.fromJson,
      );
      expect(snapshot.isAuthenticated, isFalse);
      expect(snapshot.hasToken, isFalse);
      expect(snapshot.user, isNull);
    });

    test('the snapshot carries no token field at all', () async {
      final raw = await peer.sendRequest(ConduitMethods.authStatus);
      expect((raw as Map).keys, isNot(contains('token')));
      expect(jsonEncode(raw), isNot(contains('"token"')));
    });

    test('hasSavedCredentials answers without a server', () async {
      final raw = await peer.sendRequest(
        ConduitMethods.authHasSavedCredentials,
      ) as Map<String, dynamic>;
      expect(raw['hasSavedCredentials'], isA<bool>());
    });

    test('reviewer mode round-trips', () async {
      final on = await callTyped<AuthSnapshot>(
        peer,
        ConduitMethods.authSetReviewerMode,
        params: <String, dynamic>{'enabled': true},
        decodeResult: AuthSnapshot.fromJson,
      );
      expect(on.isReviewerMode, isTrue);

      final off = await callTyped<AuthSnapshot>(
        peer,
        ConduitMethods.authSetReviewerMode,
        params: <String, dynamic>{'enabled': false},
        decodeResult: AuthSnapshot.fromJson,
      );
      expect(off.isReviewerMode, isFalse);
    });

    test('setReviewerMode rejects a non-boolean', () async {
      expect(
        () => peer.sendRequest(ConduitMethods.authSetReviewerMode, {
          'enabled': 'yes',
        }),
        throwsA(
          isA<json_rpc.RpcException>().having(
            (e) => (e.data! as Map)['code'],
            'code',
            ConduitErrorCodes.invalidParams,
          ),
        ),
      );
    });

    test('completeExternal needs an active server', () async {
      expect(
        () => peer.sendRequest(
          ConduitMethods.authCompleteExternal,
          const ExternalAuthCompletion(origin: 'https://elsewhere.example.com')
              .toJson(),
        ),
        throwsA(
          isA<json_rpc.RpcException>().having(
            (e) => (e.data! as Map)['code'],
            'code',
            ConduitErrorCodes.invalidParams,
          ),
        ),
      );
    });
  });

  test(
    'an unimplemented reserved namespace is still capability.unsupported',
    () async {
      expect(
        () => peer.sendRequest('chats.list'),
        throwsA(
          isA<json_rpc.RpcException>().having(
            (e) => (e.data! as Map)['code'],
            'code',
            ConduitErrorCodes.unsupported,
          ),
        ),
      );
    },
  );
}
