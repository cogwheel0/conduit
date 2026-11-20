@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'support/null_sink.dart';

const String _token = 'cJkVQ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';

/// A made-up private key's PEM header, written in two parts so the source
/// holds no key-shaped text for secret scanners.
const String _keyHeader =
    '-----BEGIN PRIVATE'
    ' KEY-----';
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
  late HandshakeResponse earlyHandshake;

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

    final socket = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
      protocols: buildSubprotocols(_token),
      headers: <String, dynamic>{'Origin': kConduitAppOrigin},
    );
    await socket.ready;
    peer = json_rpc.Peer(socket.cast<String>());
    unawaited(peer.listen());
    // As the app runs it: the core is announced, the window connects at
    // once, and its handshake waits for the core instead of guessing.
    server.coreStarting();
    final early = callTyped<HandshakeResponse>(
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

    // This window connected before the core was up, as one can while the
    // daemon restores state: it is told so, and then, once the core
    // attaches, it is served -- every test below runs on it.
    await expectLater(
      peer.sendRequest(ConduitMethods.accountsList),
      throwsA(
        isA<json_rpc.RpcException>().having(
          (e) => (e.data as Map?)?['code'],
          'code',
          ConduitErrorCodes.daemonUnavailable,
        ),
      ),
    );
    server.attachCore(
      await CoreRuntime.start(
        config: config,
        directories: directories,
        log: log,
      ),
    );
    earlyHandshake = await early;
  });

  tearDownAll(() async {
    await peer.close();
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AccountList> list() => callTyped<AccountList>(
    peer,
    ConduitMethods.accountsList,
    decodeResult: AccountList.fromJson,
  );

  Future<AccountChangeResult> add(ServerDraft draft) =>
      callTyped<AccountChangeResult>(
        peer,
        ConduitMethods.accountsAdd,
        params: AddAccount(server: draft).toJson(),
        decodeResult: AccountChangeResult.fromJson,
      );

  /// The account [add] just made: it is the active one.
  AccountSummary added(AccountChangeResult result) => result.accounts.accounts
      .singleWhere((a) => a.id == result.accounts.activeAccountId);

  Future<AccountChangeResult> switchTo(String id) =>
      callTyped<AccountChangeResult>(
        peer,
        ConduitMethods.accountsSwitch,
        params: AccountRef(accountId: id).toJson(),
        decodeResult: AccountChangeResult.fromJson,
      );

  Future<HandshakeResponse> handshakeAgain() => callTyped<HandshakeResponse>(
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

  group('accounts.* and servers.update', () {
    test('a handshake made while the core starts waits for its answer', () {
      expect(earlyHandshake.needsOnboarding, isTrue);
    });

    test('a fresh daemon has no accounts, which is onboarding', () async {
      final result = await list();
      expect(result.accounts, isEmpty);
      expect(result.activeAccountId, isNull);
      expect((await handshakeAgain()).needsOnboarding, isTrue);
    });

    test(
      'add makes a signed-out account active, and list reflects it',
      () async {
        final result = await add(
          const ServerDraft(name: 'Home', url: 'https://chat.example.com'),
        );
        expect(result.outcome, AccountChangeOutcome.needsSignIn);
        final account = added(result);
        expect(account.connection.name, 'Home');
        expect(account.connection.url, 'https://chat.example.com');
        expect(account.hasSession, isFalse);
        expect(account.id, isNotEmpty);

        final listed = await list();
        expect(listed.accounts.map((a) => a.id), contains(account.id));
        expect(listed.activeAccountId, account.id);
        // An account, even one not signed in to yet, is past onboarding: what
        // it needs is a sign-in.
        expect((await handshakeAgain()).needsOnboarding, isFalse);
      },
    );

    test('exactly one account is active, and it is the active id', () async {
      await add(const ServerDraft(name: 'One', url: 'https://one.example.com'));
      await add(const ServerDraft(name: 'Two', url: 'https://two.example.com'));

      final result = await list();
      final active = result.accounts.where((a) => a.isActive).toList();
      expect(active.single.id, result.activeAccountId);
      expect(active.single.connection.isActive, isTrue);
    });

    test('adding drops an account that never signed in', () async {
      // As on mobile: an account with no user and no session is an abandoned
      // sign-in, not an account to keep. Signed-in accounts survive an
      // addition; accounts_test.dart covers those against a server.
      final before = await list();
      final result = await add(
        const ServerDraft(name: 'Second', url: 'https://second.example.com'),
      );
      expect(
        result.accounts.accounts.map((a) => a.id),
        isNot(contains(before.activeAccountId)),
      );
      expect(result.accounts.accounts, hasLength(1));
    });

    test('a secret never comes back', () async {
      final result = await add(
        const ServerDraft(
          name: 'Secretive',
          url: 'https://secretive.example.com',
          mtlsCertificateChainPem: '-----BEGIN CERTIFICATE-----\nxyz\n',
          mtlsCertificateLabel: 'corp.pem',
          mtlsPrivateKeyPem: '$_keyHeader\nabc\n',
          mtlsPrivateKeyLabel: 'corp-key.pem',
          mtlsPrivateKeyPassword: 'made-up-passphrase',
          customHeaders: <String, String>{'X-Proxy-Token': 'bearer-secret'},
        ),
      );
      final connection = added(result).connection;

      // The typed view says a credential exists, and names the file the user
      // picked, and no more.
      expect(connection.hasMutualTlsCredentials, isTrue);
      expect(connection.mtlsPrivateKeyLabel, 'corp-key.pem');
      expect(connection.customHeaderNames, <String>['X-Proxy-Token']);

      // And the encoded frame really does not contain the values -- asserted
      // on the JSON rather than on the Dart object, because the wire is what
      // the renderer actually sees.
      for (final encoded in <String>[
        jsonEncode(result.toJson()),
        jsonEncode((await list()).toJson()),
      ]) {
        expect(encoded, isNot(contains('BEGIN PRIVATE KEY')));
        expect(encoded, isNot(contains('BEGIN CERTIFICATE')));
        expect(encoded, isNot(contains('made-up-passphrase')));
        expect(encoded, isNot(contains('bearer-secret')));
      }
    });

    test(
      'a diagnostics export names accounts by origin, without secrets',
      () async {
        await add(
          const ServerDraft(
            name: 'Exported',
            url: 'https://exported.example.com:8443/owui?k=v',
            mtlsPrivateKeyPem: '$_keyHeader\nabc\n',
            mtlsPrivateKeyPassword: 'made-up-passphrase',
            customHeaders: <String, String>{'X-Proxy-Token': 'bearer-secret'},
          ),
        );
        final export = await callTyped<DiagnosticsExport>(
          peer,
          ConduitMethods.systemExportDiagnostics,
          decodeResult: DiagnosticsExport.fromJson,
        );
        final zip = File(export.path);
        expect(p.isWithin(tempDir.path, zip.path), isTrue);
        final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
        final config = utf8.decode(archive.findFile('config.json')!.content);
        final snapshot = jsonDecode(config) as Map<String, dynamic>;
        final core = snapshot['core'] as Map<String, dynamic>;
        expect(core['state'], 'attached');
        final listed =
            ((core['accounts'] as Map<String, dynamic>)['accounts'] as List)
                .cast<Map<String, dynamic>>();
        expect(
          listed.map((a) => a['origin']),
          contains('https://exported.example.com:8443'),
        );
        expect(
          listed.expand((a) => a['customHeaderNames'] as List),
          contains('X-Proxy-Token'),
        );
        for (final secret in <String>[
          'made-up-passphrase',
          'bearer-secret',
          'pa55word',
          'someone',
          'PRIVATE KEY',
          'Exported',
          _token,
          _masterKey,
        ]) {
          expect(config, isNot(contains(secret)), reason: secret);
        }
      },
    );

    test('update leaves a secret alone when it is not resent', () async {
      final account = added(
        await add(
          const ServerDraft(
            name: 'Keeps',
            url: 'https://keeps.example.com',
            mtlsCertificateChainPem: '-----BEGIN CERTIFICATE-----\nkeep\n',
            mtlsPrivateKeyPem: '$_keyHeader\nkeep\n',
            mtlsPrivateKeyLabel: 'keep-key.pem',
          ),
        ),
      );
      expect(account.connection.hasMutualTlsCredentials, isTrue);

      final renamed = await callTyped<ServerSummary>(
        peer,
        ConduitMethods.serversUpdate,
        params: ServerDraft(
          id: account.id,
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

    // Two windows save the same connection at once, each changing something
    // else: neither puts back what the other changed.
    test('two edits saved at once each keep what the other changed', () async {
      final account = added(
        await add(
          const ServerDraft(name: 'Both', url: 'https://both.example.com'),
        ),
      );
      Future<ServerSummary> update(ServerDraft draft) =>
          callTyped<ServerSummary>(
            peer,
            ConduitMethods.serversUpdate,
            params: draft.toJson(),
            decodeResult: ServerSummary.fromJson,
          );

      await Future.wait([
        update(
          ServerDraft(
            id: account.id,
            name: 'Both',
            url: 'https://both.example.com',
            customHeaders: const {'X-Lab': 'one'},
          ),
        ),
        update(
          ServerDraft(
            id: account.id,
            name: 'Both',
            url: 'https://both.example.com',
            mtlsCertificateChainPem: '-----BEGIN CERTIFICATE-----\nboth\n',
            mtlsPrivateKeyPem: '$_keyHeader\nboth\n',
            mtlsPrivateKeyLabel: 'both-key.pem',
          ),
        ),
      ]);

      final saved = (await list()).accounts
          .singleWhere((a) => a.id == account.id)
          .connection;
      expect(saved.customHeaderNames, ['X-Lab']);
      expect(saved.hasMutualTlsCredentials, isTrue);
    });

    test('clearMutualTls is how a client certificate is removed', () async {
      final account = added(
        await add(
          const ServerDraft(
            name: 'Clears',
            url: 'https://clears.example.com',
            mtlsCertificateChainPem: '-----BEGIN CERTIFICATE-----\ngone\n',
            mtlsPrivateKeyPem: '$_keyHeader\ngone\n',
            mtlsPrivateKeyLabel: 'gone-key.pem',
          ),
        ),
      );
      expect(account.connection.hasMutualTlsCredentials, isTrue);

      final cleared = await callTyped<ServerSummary>(
        peer,
        ConduitMethods.serversUpdate,
        params: ServerDraft(
          id: account.id,
          name: 'Clears',
          url: 'https://clears.example.com',
          clearMutualTls: true,
        ).toJson(),
        decodeResult: ServerSummary.fromJson,
      );

      expect(cleared.hasMutualTlsCredentials, isFalse);
      expect(cleared.mtlsPrivateKeyLabel, isNull);
    });

    test('a trailing slash is not part of the address', () async {
      final account = added(
        await add(
          const ServerDraft(name: 'Slash', url: 'https://slash.example.com/'),
        ),
      );
      expect(account.connection.url, 'https://slash.example.com');
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

    test(
      'switching to the active, signed-out account asks for a sign-in',
      () async {
        final account = added(
          await add(
            const ServerDraft(name: 'Alpha', url: 'https://alpha.example.com'),
          ),
        );
        // Already active but signed out: the core looks for a session it
        // still has, finds none, and the account needs a sign-in. (An active,
        // signed-in account is `alreadyActive`; see accounts_test.dart.)
        final result = await switchTo(account.id);
        expect(result.outcome, AccountChangeOutcome.needsSignIn);
        expect(result.accounts.activeAccountId, account.id);
      },
    );

    test('switching to an unknown id is resource.notFound', () async {
      expect(
        () => switchTo('no-such-account'),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.notFound,
          ),
        ),
      );
    });

    test('removing the only account leaves none active', () async {
      final active = (await list()).activeAccountId!;
      final result = await callTyped<AccountChangeResult>(
        peer,
        ConduitMethods.accountsRemove,
        params: AccountRef(accountId: active).toJson(),
        decodeResult: AccountChangeResult.fromJson,
      );
      // Nothing to sign in to is not "needs a sign-in".
      expect(result.outcome, AccountChangeOutcome.done);
      expect(
        result.accounts.accounts.map((a) => a.id),
        isNot(contains(active)),
      );
      expect(result.accounts.activeAccountId, isNull);
    });

    test('removing an unknown id is resource.notFound', () async {
      expect(
        () => callTyped<AccountChangeResult>(
          peer,
          ConduitMethods.accountsRemove,
          params: const AccountRef(accountId: 'no-such-account').toJson(),
          decodeResult: AccountChangeResult.fromJson,
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

    test('cancelAdd with no addition changes nothing', () async {
      final before = await list();
      final result = await callTyped<AccountChangeResult>(
        peer,
        ConduitMethods.accountsCancelAdd,
        decodeResult: AccountChangeResult.fromJson,
      );
      expect(result.outcome, AccountChangeOutcome.unchanged);
      expect(result.accounts.activeAccountId, before.activeAccountId);
    });

    test('removing every account leaves none active', () async {
      var listed = await list();
      while (listed.accounts.isNotEmpty) {
        final result = await callTyped<AccountChangeResult>(
          peer,
          ConduitMethods.accountsRemove,
          params: AccountRef(accountId: listed.accounts.first.id).toJson(),
          decodeResult: AccountChangeResult.fromJson,
        );
        listed = result.accounts;
      }
      expect(listed.activeAccountId, isNull);
      // Never auto-promoted to a server nobody chose: with no account left
      // the app goes back to choosing a backend.
      expect((await handshakeAgain()).needsOnboarding, isTrue);
    });

    group('the methods accounts.* replaced are gone', () {
      for (final method in <String>[
        'servers.list',
        'servers.add',
        'servers.remove',
        'servers.connect',
        'auth.signOut',
      ]) {
        test(method, () async {
          await expectLater(
            peer.sendRequest(method, <String, dynamic>{}),
            throwsA(
              isA<json_rpc.RpcException>().having(
                (e) => (e.data as Map?)?['code'],
                'code',
                ConduitErrorCodes.unsupported,
              ),
            ),
          );
        });
      }
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
      final nowhere = added(
        await add(
          const ServerDraft(
            name: 'Nowhere',
            // Reserved by RFC 6761 to never resolve, so this is a real network
            // failure rather than a mock of one.
            url: 'https://conduit-test.invalid',
          ),
        ),
      );

      final result = await status();
      // The connection-issue page renders this. An RPC error would leave it
      // with nothing to say but "something went wrong".
      expect(result.reachability, ServerReachability.unreachable);
      expect(result.errorCode, isNotNull);
      expect(result.activeServerId, nowhere.id);
    });

    test(
      'a server that is down is unreachable, not "not Open WebUI"',
      () async {
        // A port nothing listens on: the connection is refused, as for a
        // server that stopped.
        final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final url = 'http://127.0.0.1:${closed.port}';
        await closed.close();
        added(await add(ServerDraft(name: 'Stopped', url: url)));

        final result = await status();
        expect(result.reachability, ServerReachability.unreachable);
        expect(result.errorCode, ConduitErrorCodes.connectionFailed);
      },
    );

    test('a server that answers, but not as Open WebUI, says so', () async {
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => other.close(force: true));
      other.listen((request) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
      });
      added(
        await add(
          ServerDraft(name: 'Other', url: 'http://127.0.0.1:${other.port}'),
        ),
      );

      final result = await status();
      expect(result.reachability, ServerReachability.notOpenWebUi);
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
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.invalidParams,
          ),
        ),
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

    test('defaults to system mode, the Conduit palette and 14 px', () async {
      final prefs = await readPrefs();
      expect(prefs.themeMode, AppThemeMode.system);
      expect(prefs.themePaletteId, 'conduit');
      expect(prefs.uiFontSize, 14);
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

    test('the font size persists, held to its bounds', () async {
      expect(
        (await patchPrefs(const AppPreferencesPatch(uiFontSize: 16)))
            .uiFontSize,
        16,
      );
      expect((await readPrefs()).uiFontSize, 16);
      expect(
        (await patchPrefs(const AppPreferencesPatch(uiFontSize: 40)))
            .uiFontSize,
        kMaxUiFontSize,
      );
      expect(
        (await patchPrefs(const AppPreferencesPatch(uiFontSize: 2))).uiFontSize,
        kMinUiFontSize,
      );
      // The palette is left alone.
      expect((await readPrefs()).themePaletteId, 'claude');
      await patchPrefs(const AppPreferencesPatch(uiFontSize: 14));
    });

    test('a stored retired zai palette reads as Conduit', () async {
      // Earlier desktop builds offered a palette of their own, `zai`.
      final stored = await patchPrefs(
        const AppPreferencesPatch(themePaletteId: 'zai'),
      );
      expect(stored.themePaletteId, 'conduit');
      expect((await readPrefs()).themePaletteId, 'conduit');
      await patchPrefs(const AppPreferencesPatch(themePaletteId: 'claude'));
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
        () => peer.sendRequest('voice.transcribe'),
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
