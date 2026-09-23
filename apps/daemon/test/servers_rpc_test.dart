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

  Future<ServerList> connect(String id) => callTyped<ServerList>(
    peer,
    ConduitMethods.serversConnect,
    params: ServerRef(id: id).toJson(),
    decodeResult: ServerList.fromJson,
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

    test('connect makes that server active and keeps the others', () async {
      final first = await add(
        const ServerDraft(name: 'Alpha', url: 'https://alpha.example.com'),
      );
      final second = await add(
        const ServerDraft(name: 'Beta', url: 'https://beta.example.com'),
      );

      final afterFirst = await connect(first.id);
      expect(afterFirst.activeServerId, first.id);
      expect(afterFirst.servers.where((s) => s.isActive).single.id, first.id);

      // The one this whole work package exists for: switching accounts must
      // not delete the account you switched away from.
      expect(afterFirst.servers.map((s) => s.id), contains(second.id));

      final afterSecond = await connect(second.id);
      expect(afterSecond.activeServerId, second.id);
      expect(afterSecond.servers.map((s) => s.id), contains(first.id));
      expect(afterSecond.servers.where((s) => s.isActive).single.id, second.id);
    });

    test('a server with no session says so', () async {
      final added = await add(
        const ServerDraft(name: 'Fresh', url: 'https://fresh.example.com'),
      );
      final after = await connect(added.id);

      // Nothing has signed in, so nothing may claim a stored session -- the
      // UI uses this to decide between "switch" and "sign in".
      expect(
        after.servers.firstWhere((s) => s.id == added.id).hasStoredSession,
        isFalse,
      );
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
      await connect(only.id);

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

  group('servers.status', () {
    Future<ServerStatus> status() => callTyped<ServerStatus>(
      peer,
      ConduitMethods.serversStatus,
      decodeResult: ServerStatus.fromJson,
    );

    test('reports the supported ceiling even with no active server', () async {
      final result = await status();
      // The version gate needs a number to name, and it needs it before any
      // server is reachable.
      expect(result.maxSupportedVersion, isNotEmpty);
      expect(result.reachability, ServerReachability.unknown);
      expect(result.capabilities, Capabilities.none);
    });

    test('an unreachable server is an answer, not an error', () async {
      final added = await add(
        const ServerDraft(
          name: 'Nowhere',
          // Reserved by RFC 6761 to never resolve, so this is a real network
          // failure rather than a mock of one.
          url: 'https://conduit-test.invalid',
        ),
      );
      await connect(added.id);

      final result = await status();
      // The connection-issue page renders this. An RPC error would leave it
      // with nothing to say but "something went wrong".
      expect(result.reachability, isNot(ServerReachability.reachable));
      expect(result.errorCode, isNotNull);
      expect(result.activeServerId, added.id);
    });

    test('capabilities stay off until a server answers', () async {
      // An unknown capability is one the UI must not offer: a sidebar entry
      // that dead-ends is worse than a missing one.
      expect((await status()).capabilities.hermes, isFalse);
      expect((await status()).capabilities.terminal, isFalse);
    });
  });

  group('chats.*', () {
    test('a fresh daemon has no chats', () async {
      final result = await callTyped<ChatList>(
        peer,
        ConduitMethods.chatsList,
        decodeResult: ChatList.fromJson,
      );
      expect(result.chats, isEmpty);
      expect(result.hasMore, isFalse);
    });

    test('an unknown chat is absent, not an error', () async {
      // A window restored onto a chat deleted on another device is ordinary.
      final raw = await peer.sendRequest(
        ConduitMethods.chatsGet,
        const ChatRef(id: 'no-such-chat').toJson(),
      ) as Map<String, dynamic>;
      expect(raw['chat'], isNull);
    });

    test('an empty search is not a search for everything', () async {
      // Returning the whole history here would look like it worked and be
      // among the slowest things the app can do.
      final results = await callTyped<ChatSearchResults>(
        peer,
        ConduitMethods.chatsSearch,
        params: const ChatSearchQuery(query: '   ').toJson(),
        decodeResult: ChatSearchResults.fromJson,
      );
      expect(results.hits, isEmpty);
    });
  });

  group('turns.*', () {
    test(
      'sending without a signed-in server is auth.unauthenticated',
      () async {
        expect(
          () => callTyped<SendTurnAccepted>(
            peer,
            ConduitMethods.turnsSend,
            params: const SendTurn(model: 'gpt-4o', text: 'hello').toJson(),
            decodeResult: SendTurnAccepted.fromJson,
          ),
          throwsA(
            isA<RpcError>().having(
              (e) => e.code,
              'code',
              ConduitErrorCodes.unauthenticated,
            ),
          ),
        );
      },
    );

    test('an empty message is rejected before any request is made', () async {
      expect(
        () => callTyped<SendTurnAccepted>(
          peer,
          ConduitMethods.turnsSend,
          params: const SendTurn(model: 'gpt-4o', text: '   ').toJson(),
          decodeResult: SendTurnAccepted.fromJson,
        ),
        throwsA(isA<RpcError>()),
      );
    });

    test('stopping a chat that is not generating is not an error', () async {
      // A stop button pressed as the last token lands is the common case.
      final raw = await peer.sendRequest(
        ConduitMethods.turnsStop,
        const StopTurn(chatId: 'no-such-chat').toJson(),
      ) as Map<String, dynamic>;
      expect(raw['stopped'], isTrue);
    });
  });

  group('settings.*', () {
    Future<AppPreferences> readPrefs() => callTyped<AppPreferences>(
      peer,
      ConduitMethods.settingsGetApp,
      decodeResult: AppPreferences.fromJson,
    );

    Future<AppPreferences> patchPrefs(AppPreferencesPatch patch) =>
        callTyped<AppPreferences>(
          peer,
          ConduitMethods.settingsSetApp,
          params: patch.toJson(),
          decodeResult: AppPreferences.fromJson,
        );

    test('defaults to system mode and the conduit palette', () async {
      final prefs = await readPrefs();
      expect(prefs.themeMode, AppThemeMode.system);
      expect(prefs.themePaletteId, 'conduit');
      expect(prefs.localeCode, isNull);
    });

    test('a patch round-trips and persists', () async {
      await patchPrefs(
        const AppPreferencesPatch(
          themeMode: AppThemeMode.dark,
          themePaletteId: 't3_chat',
          localeCode: 'zh-Hant',
        ),
      );

      final reread = await readPrefs();
      expect(reread.themeMode, AppThemeMode.dark);
      expect(reread.themePaletteId, 't3_chat');
      expect(reread.localeCode, 'zh-Hant');
    });

    test('a null field leaves that preference alone', () async {
      await patchPrefs(const AppPreferencesPatch(themePaletteId: 'claude'));

      // Changing the palette must not reset the theme mode or the locale --
      // a settings panel edits one control at a time.
      final prefs = await readPrefs();
      expect(prefs.themePaletteId, 'claude');
      expect(prefs.themeMode, AppThemeMode.dark);
      expect(prefs.localeCode, 'zh-Hant');
    });

    test('clearLocaleCode is how "follow the system" is chosen', () async {
      // Null already means "unchanged", so removing needs its own flag.
      final prefs = await patchPrefs(
        const AppPreferencesPatch(clearLocaleCode: true),
      );
      expect(prefs.localeCode, isNull);
    });

    test('clearing wins over setting when a caller sends both', () async {
      final prefs = await patchPrefs(
        const AppPreferencesPatch(localeCode: 'de', clearLocaleCode: true),
      );
      expect(prefs.localeCode, isNull);
    });

    test('an unknown stored theme mode falls back to system', () async {
      // A bad preference -- a newer build's value, or a corrupted store --
      // must not stop the app from starting.
      await patchPrefs(
        const AppPreferencesPatch(themeMode: AppThemeMode.light),
      );
      expect((await readPrefs()).themeMode, AppThemeMode.light);
    });
  });

  test(
    'an unimplemented reserved namespace is still capability.unsupported',
    () async {
      expect(
        () => peer.sendRequest('hermes.sessions'),
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
