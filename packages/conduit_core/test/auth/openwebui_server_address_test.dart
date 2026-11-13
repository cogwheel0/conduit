import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/openwebui_address_check.dart';
import 'package:conduit_core/auth/openwebui_server_address.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:hive_ce/hive.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// An address of a saved Open WebUI server: what is wrong with one typed
/// into an editor, why connecting to it failed, and saving it once checked.
void main() {
  group('an address typed into an editor', () {
    test('is given a scheme and loses its trailing slash', () {
      check(formatServerAddressInput(' chat.example/ '))
          .equals('http://chat.example');
      check(formatServerAddressInput('https://chat.example:8443'))
          .equals('https://chat.example:8443');
      check(formatServerAddressInput('10.0.0.255')).equals('http://10.0.0.255');
    });

    for (final (input, problem) in [
      ('  ', ServerAddressProblem.addressEmpty),
      ('http://[::1', ServerAddressProblem.invalidAddress),
      ('http://', ServerAddressProblem.missingHost),
      ('http://chat.example:0', ServerAddressProblem.portOutOfRange),
      ('http://10.0.0.256', ServerAddressProblem.invalidIpAddress),
    ]) {
      test('"$input" is refused as ${problem.name}', () {
        check(() => formatServerAddressInput(input))
            .throws<ServerAddressInputException>()
            .has((error) => error.problem, 'problem')
            .equals(problem);
      });
    }
  });

  group('a custom header', () {
    for (final (name, value, problem) in [
      ('', 'v', ServerAddressProblem.headerFieldMissing),
      ('X-Gate', '', ServerAddressProblem.headerFieldMissing),
      ('X' * 65, 'v', ServerAddressProblem.headerNameTooLong),
      ('X Gate', 'v', ServerAddressProblem.headerNameInvalidCharacters),
      ('Authorization', 'v', ServerAddressProblem.headerNameReserved),
      ('X-Gate', 'v' * 1025, ServerAddressProblem.headerValueTooLong),
      (
        'X-Gate',
        'caf\u00e9',
        ServerAddressProblem.headerValueInvalidCharacters,
      ),
      ('X-Gate', '<b>', ServerAddressProblem.headerValueUnsafe),
      ('X-Gate', 'Script', ServerAddressProblem.headerValueUnsafe),
      ('X-Kept', 'v', ServerAddressProblem.headerAlreadyAdded),
    ]) {
      test('$name: "${value.length > 8 ? '${value.substring(0, 8)}…' : value}" '
          'is refused as ${problem.name}', () {
        check(
          validateServerAddressHeader(
            const {'X-Kept': 'kept'},
            name: name,
            value: value,
          ),
        ).equals(problem);
      });
    }

    test('beyond the most an address carries is refused', () {
      final full = {
        for (var i = 0; i < maxServerAddressHeaders; i++) 'X-$i': 'v',
      };
      check(validateServerAddressHeader(full, name: 'X-New', value: 'v'))
          .equals(ServerAddressProblem.tooManyHeaders);
      full.remove('X-0');
      check(validateServerAddressHeader(full, name: 'X-New', value: 'v\tw'))
          .isNull();
    });

    // Typed one field at a time, an empty field is not yet wrong.
    test('field left empty is not a problem of the field', () {
      check(validateServerAddressHeaderName('')).isNull();
      check(validateServerAddressHeaderValue('')).isNull();
    });
  });

  group('a client certificate', () {
    test('needs its key, and a password needs both', () {
      ServerAddressProblem? of({String? cert, String? key, String pw = ''}) =>
          validateServerAddressMutualTls(
            ServerAddressDraft(
              certificatePem: cert,
              privateKeyPem: key,
              privateKeyPassword: pw,
            ),
          );
      check(of()).isNull();
      check(of(pw: '  ')).isNull();
      check(of(cert: 'c', key: 'k', pw: 'p')).isNull();
      check(of(pw: 'p')).equals(ServerAddressProblem.mutualTlsIncomplete);
      check(of(cert: 'c')).equals(ServerAddressProblem.mutualTlsIncomplete);
      check(of(key: 'k')).equals(ServerAddressProblem.mutualTlsIncomplete);
    });

    test('picked files must be PEM of the right kind', () {
      check(
        validatePickedPem('-----BEGIN CERTIFICATE-----', isPrivateKey: false),
      ).isNull();
      check(
        validatePickedPem('-----BEGIN PRIVATE KEY-----', isPrivateKey: false),
      ).equals(ServerAddressProblem.certificatePemRequired);
      check(
        validatePickedPem('-----BEGIN EC PRIVATE KEY-----', isPrivateKey: true),
      ).isNull();
      check(
        validatePickedPem('-----BEGIN CERTIFICATE-----', isPrivateKey: true),
      ).equals(ServerAddressProblem.privateKeyPemRequired);
    });

    test('a picked file that is empty or not text cannot be read', () {
      check(decodePickedPem(' pem\n'.codeUnits)).equals('pem');
      for (final bytes in [
        <int>[],
        <int>[0xff, 0xfe],
      ]) {
        check(() => decodePickedPem(bytes))
            .throws<ServerAddressInputException>()
            .has((error) => error.problem, 'problem')
            .equals(ServerAddressProblem.pemFileUnreadable);
      }
    });

    test('a picked file is called by its name, else its path', () {
      check(pickedFileLabel(name: ' a.pem ', path: '/x/b.pem', fallback: 'f'))
          .equals('a.pem');
      check(pickedFileLabel(name: '', path: r'C:\x\b.pem', fallback: 'f'))
          .equals('b.pem');
      check(pickedFileLabel(name: '', path: '/x/', fallback: 'f')).equals('f');
    });
  });

  group('connecting to an address failed', () {
    ServerAddressFailure classify(Object error, {bool mutualTls = false}) =>
        classifyServerConnectionError(
          error,
          sensitiveValues: const ['hunter2'],
          hasMutualTlsInput: mutualTls,
        );
    ServerAddressFailure problem(ServerAddressProblem problem) =>
        ServerAddressProblemFailure(problem);
    final request = RequestOptions(path: '/health');

    test('for what was typed', () {
      check(
        classify(
          const ServerAddressInputException(
            ServerAddressProblem.portOutOfRange,
          ),
        ),
      ).equals(problem(ServerAddressProblem.portOutOfRange));
    });

    test('in the transport, as a problem of its kind', () {
      check(
        classify(
          DioException(
            requestOptions: request,
            type: DioExceptionType.badCertificate,
          ),
        ),
      ).equals(problem(ServerAddressProblem.certificateRejected));
      check(
        classify(
          DioException.connectionError(
            requestOptions: request,
            reason: 'refused',
          ),
        ),
      ).equals(problem(ServerAddressProblem.unreachable));
      check(classify(const SocketException('refused')))
          .equals(problem(ServerAddressProblem.unreachable));
      check(classify(const HttpException('broken')))
          .equals(problem(ServerAddressProblem.serverError));
      check(classify(const HandshakeException('bad')))
          .equals(problem(ServerAddressProblem.certificateRejected));
    });

    test('with a client certificate, as the certificate\'s problem', () {
      check(classify(const HandshakeException('bad'), mutualTls: true))
          .equals(problem(ServerAddressProblem.mutualTlsRefused));
      check(
        classify(
          Exception(
            'Connection closed before full header was received, '
            'uri = https://chat.example/health',
          ),
          mutualTls: true,
        ),
      ).equals(problem(ServerAddressProblem.mutualTlsConnectionClosed));
    });

    test('with what the server said, its secrets kept out', () {
      final failure = classify(
        DioException(
          requestOptions: request,
          response: Response(
            requestOptions: request,
            statusCode: 502,
            data: {'detail': 'gate hunter2 down'},
          ),
        ),
      );
      check(failure).isA<ServerAddressErrorText>()
        ..has((f) => f.text, 'text').startsWith('HTTP 502 - from the server')
        ..has((f) => f.text, 'text').not((t) => t.contains('hunter2'));
    });

    test('as an error that is not Open WebUI, or else as it reads', () {
      check(
        classify(Exception('This does not appear to be an Open-WebUI server.')),
      ).equals(problem(ServerAddressProblem.notOpenWebUi));
      check(classify(Exception('mTLS certificate setup failed: hunter2')))
          .equals(
            const ServerAddressErrorText(
              'mTLS certificate setup failed: [REDACTED]',
            ),
          );
      check(classify(Exception('  ')))
          .equals(problem(ServerAddressProblem.unreachable));
    });
  });

  group('a server\'s addresses', () {
    final a = OpenWebUiEndpoint(id: 'a', url: 'https://a.example');
    final b = OpenWebUiEndpoint(id: 'b', url: 'https://b.example');
    final c = OpenWebUiEndpoint(id: 'c', url: 'https://c.example');

    test('are ordered as dragged, those not named after', () {
      check(serverAddressesInOrder([a, b, c], ['c', 'gone', 'a']))
          .deepEquals([c, a, b]);
    });

    test('lose one removed, and keep their last', () {
      check(withoutServerAddress([a, b], 'a')).deepEquals([b]);
      check(
        serverAddressesRemovable(
          OpenWebUiServer(id: 's', name: 'S', endpoints: [a, b]),
        ),
      ).isTrue();
      check(
        serverAddressesRemovable(
          OpenWebUiServer(id: 's', name: 'S', endpoints: [a]),
        ),
      ).isFalse();
      check(serverAddressesRemovable(null)).isFalse();
    });

    test('have one in use only on the server it is in use for', () {
      const route = OpenWebUiRouteStatus(serverId: 's', endpointId: 'a');
      check(isServerAddressInUse(route, serverId: 's', endpointId: 'a'))
          .isTrue();
      check(isServerAddressInUse(route, serverId: 's', endpointId: 'b'))
          .isFalse();
      check(isServerAddressInUse(route, serverId: 't', endpointId: 'a'))
          .isFalse();
    });
  });

  group('checking and saving an address', () {
    late Directory tempDir;
    late WorkerManager workerManager;
    late _CookieRefusingSecureStore secure;
    late OptimizedStorageService storage;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('server-address-test');
      Hive.init(tempDir.path);
      PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
      await PreferencesStore.ensureInitialized();
      workerManager = WorkerManager(maxConcurrentTasks: 1);
      secure = _CookieRefusingSecureStore();
      storage = OptimizedStorageService(
        secureStorage: secure,
        boxes: HiveBoxes(
          preferences: await Hive.openBox<dynamic>(HiveBoxNames.preferences),
          caches: await Hive.openBox<dynamic>(HiveBoxNames.caches),
          attachmentQueue: await Hive.openBox<dynamic>(
            HiveBoxNames.attachmentQueue,
          ),
          metadata: await Hive.openBox<dynamic>(HiveBoxNames.metadata),
        ),
        workerManager: workerManager,
      );
      _Routes.reasons.clear();
      container = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          openWebUiRouteResolverProvider.overrideWith(_Routes.new),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      workerManager.dispose();
      PreferencesStore.debugReset();
      await Hive.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('moves the addresses of the server to the new order', () async {
      await storage.saveServerConfigs([
        const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
      ]);
      final stored =
          (await storage.getOpenWebUiRegistryStrict()).servers.single;
      final first = stored.endpoints.single;
      await storage.saveServer(
        OpenWebUiServer(
          id: stored.id,
          name: stored.name,
          endpoints: [
            first,
            OpenWebUiEndpoint(id: 'away', url: 'https://away.example'),
          ],
        ),
      );

      await editServerAddresses(
        container,
        stored.id,
        (endpoints) => serverAddressesInOrder(endpoints, ['away']),
      );

      final saved = await storage.getOpenWebUiRegistryStrict();
      check([
        for (final endpoint in saved.servers.single.endpoints) endpoint.id,
      ]).deepEquals(['away', first.id]);
      check(_Routes.reasons).deepEquals(['routes-edited']);
    });

    test('an address is saved with the cookie it was checked with', () async {
      await storage.saveServerConfigs([
        const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
      ]);
      await storage.setActiveServerId('a');
      final server =
          (await storage.getOpenWebUiRegistryStrict()).servers.single;
      final route = OpenWebUiEndpoint(
        id: server.endpoints.single.id,
        url: 'https://moved.example',
      );

      final kept = await saveCheckedAddress(
        container,
        serverId: server.id,
        route: route,
        adding: false,
        cookieOwner: 'a',
        headers: const {'X-Gate': 'g', 'Cookie': 'proxy=1'},
        sessionRevision: storage.sessionRevocationRevision,
      );

      check(kept).isTrue();
      final stored = await storage.getOpenWebUiRegistryStrict();
      check(stored.servers.single.endpoints.single.url)
          .equals('https://moved.example');
      check(stored.account('a')!.capturedHeaders).deepEquals({
        route.id: {'Cookie': 'proxy=1'},
      });
      check(_Routes.reasons).deepEquals(['routes-edited']);
    });

    // A new client ends the reply arriving through it: an edit of an address
    // not in use leaves the active connection, and its clients, as they are.
    test(
      'saving an address not in use leaves the active connection alone',
      () async {
        await storage.saveServerConfigs([
          const ServerConfig(
            id: 'a',
            name: 'Chat',
            url: 'https://chat.example',
          ),
        ]);
        await storage.setActiveServerId('a');
        final stored =
            (await storage.getOpenWebUiRegistryStrict()).servers.single;
        await storage.saveServer(
          OpenWebUiServer(
            id: stored.id,
            name: stored.name,
            endpoints: [
              ...stored.endpoints,
              OpenWebUiEndpoint(id: 'away', url: 'https://away.example'),
            ],
          ),
        );
        await container.read(activeServerProvider.future);
        var changes = 0;
        container.listen(activeServerProvider, (_, _) => changes++);
        Future<bool> save(String routeId, String url) => saveCheckedAddress(
          container,
          serverId: stored.id,
          route: OpenWebUiEndpoint(id: routeId, url: url),
          adding: false,
          cookieOwner: null,
          headers: const {},
          sessionRevision: storage.sessionRevocationRevision,
        );

        check(await save('away', 'https://moved-away.example')).isTrue();
        await Future<void>.delayed(Duration.zero);
        check(changes).equals(0);

        check(await save(stored.endpoints.single.id, 'https://moved.example'))
            .isTrue();
        await Future<void>.delayed(Duration.zero);
        check(changes).isGreaterThan(0);
      },
    );

    // Saved without it, an address behind a proxy would be refused, with no
    // other to fall back to; the clients and the addresses shown stay put too.
    test('an address whose cookie cannot be kept is not saved', () async {
      await storage.saveServerConfigs([
        const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
      ]);
      await storage.setActiveServerId('a');
      secure.refusesCookie = true;
      final server =
          (await storage.getOpenWebUiRegistryStrict()).servers.single;
      // What the client is built from, and what the addresses screen shows.
      Future<String> inUse() async =>
          (await container.read(serverConfigsProvider.future)).single.url;
      Future<String> shown() async {
        final accounts = await container.read(openWebUiAccountsProvider.future);
        return accounts.single.server.endpoints.single.url;
      }

      check(await inUse()).equals('https://chat.example');
      check(await shown()).equals('https://chat.example');

      await check(
        saveCheckedAddress(
          container,
          serverId: server.id,
          route: OpenWebUiEndpoint(
            id: server.endpoints.single.id,
            url: 'https://moved.example',
          ),
          adding: false,
          cookieOwner: 'a',
          headers: const {'Cookie': 'proxy=1'},
          sessionRevision: storage.sessionRevocationRevision,
        ),
      ).throws<StateError>();

      secure.refusesCookie = false;
      final stored = await storage.getOpenWebUiRegistryStrict();
      check(stored.servers.single.endpoints.single.url)
          .equals('https://chat.example');
      check(await inUse()).equals('https://chat.example');
      check(await shown()).equals('https://chat.example');
      check(_Routes.reasons).isEmpty();
    });

    // Saved without its cookie, the address would be refused by its proxy,
    // while the editor closed as though it worked.
    test('an address whose cookie is for no account is not saved', () async {
      await storage.saveServerConfigs([
        const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
      ]);
      final server =
          (await storage.getOpenWebUiRegistryStrict()).servers.single;

      final kept = await saveCheckedAddress(
        container,
        serverId: server.id,
        route: OpenWebUiEndpoint(
          id: server.endpoints.single.id,
          url: 'https://moved.example',
        ),
        adding: false,
        cookieOwner: null,
        headers: const {'Cookie': 'proxy=1'},
        sessionRevision: storage.sessionRevocationRevision,
      );

      check(kept).isFalse();
      final stored = await storage.getOpenWebUiRegistryStrict();
      check(stored.servers.single.endpoints.single.url)
          .equals('https://chat.example');
      check(_Routes.reasons).isEmpty();
    });

    group('the account a proxy sign-in on an address is kept for', () {
      final chat = OpenWebUiServer(
        id: 'chat',
        name: 'Chat',
        endpoints: [
          OpenWebUiEndpoint(id: 'route', url: 'https://chat.example'),
        ],
      );
      final other = OpenWebUiServer(
        id: 'other',
        name: 'Other',
        endpoints: [OpenWebUiEndpoint(id: 'elsewhere', url: 'https://o.test')],
      );
      OpenWebUiRegistry registryWith(List<OpenWebUiAccount> accounts) =>
          OpenWebUiRegistry(servers: [chat, other], accounts: accounts);
      String? ownerOf(
        OpenWebUiRegistry registry, {
        String? provedBy,
        String? active,
      }) => addressCookieOwner(
        registry,
        serverId: chat.id,
        provedBy: provedBy,
        activeAccountId: active,
      );

      test('is the one whose session proved the address', () {
        final registry = registryWith([
          OpenWebUiAccount(id: 'a', serverId: 'chat', userId: 'user-a'),
          OpenWebUiAccount(id: 'b', serverId: 'chat', userId: 'user-b'),
        ]);
        check(ownerOf(registry, provedBy: 'b', active: 'a')).equals('b');
      });

      test('is the active account when it is the server\'s', () {
        final registry = registryWith([
          OpenWebUiAccount(id: 'a', serverId: 'chat', userId: 'user-a'),
          OpenWebUiAccount(id: 'b', serverId: 'chat', userId: 'user-b'),
        ]);
        check(ownerOf(registry, active: 'b')).equals('b');
      });

      // Another server active, and nothing of this one's to prove it with.
      test('is the server\'s only account while another is active', () {
        final registry = registryWith([
          OpenWebUiAccount(id: 'a', serverId: 'chat', userId: 'user-a'),
          OpenWebUiAccount(id: 'pending', serverId: 'chat'),
          OpenWebUiAccount(id: 'o', serverId: 'other', userId: 'user-o'),
        ]);
        check(ownerOf(registry, active: 'o')).equals('a');
        check(ownerOf(registry)).equals('a');
      });

      test('is none when it could be any of several', () {
        final registry = registryWith([
          OpenWebUiAccount(id: 'a', serverId: 'chat', userId: 'user-a'),
          OpenWebUiAccount(id: 'b', serverId: 'chat', userId: 'user-b'),
          OpenWebUiAccount(id: 'o', serverId: 'other', userId: 'user-o'),
        ]);
        check(ownerOf(registry, active: 'o')).isNull();
      });

      test('is none for an account still being signed in to', () {
        final registry = registryWith([
          OpenWebUiAccount(id: 'pending', serverId: 'chat'),
        ]);
        check(ownerOf(registry, active: 'pending')).isNull();
      });
    });

    // A sign-out since the address was first contacted revoked the cookie;
    // the editor says so rather than close as though the address was saved.
    test('an address whose cookie was revoked is not saved', () async {
      await storage.saveServerConfigs([
        const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
      ]);
      await storage.setActiveServerId('a');
      final server =
          (await storage.getOpenWebUiRegistryStrict()).servers.single;
      Future<String> shown() async {
        final accounts = await container.read(openWebUiAccountsProvider.future);
        return accounts.single.server.endpoints.single.url;
      }

      check(await shown()).equals('https://chat.example');
      final revision = storage.sessionRevocationRevision;
      await storage.clearActiveAccountAuthDataIf(canClear: () => true);

      final kept = await saveCheckedAddress(
        container,
        serverId: server.id,
        route: OpenWebUiEndpoint(
          id: server.endpoints.single.id,
          url: 'https://moved.example',
        ),
        adding: false,
        cookieOwner: 'a',
        headers: const {'Cookie': 'proxy=1'},
        sessionRevision: revision,
      );

      check(kept).isFalse();
      final stored = await storage.getOpenWebUiRegistryStrict();
      check(stored.servers.single.endpoints.single.url)
          .equals('https://chat.example');
      check(await shown()).equals('https://chat.example');
      check(_Routes.reasons).isEmpty();
    });

    // The only account saved is active with no id kept for it. Looked for
    // among inactive accounts, it had no session, and a valid address was
    // refused as needing a sign-in.
    test('the only account checks an address with its live session', () async {
      await storage.saveServerConfigs([
        const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
      ]);
      await storage.setActiveServerId(null);
      await storage.bindAccountUser('a', 'user-a');
      await storage.saveAuthToken('live-a');
      check(await storage.getActiveServerId()).isNull();
      final signedIn = ProviderContainer(
        overrides: [
          optimizedStorageServiceProvider.overrideWithValue(storage),
          openWebUiRouteResolverProvider.overrideWith(_Routes.new),
          authTokenProvider3.overrideWithValue('live-a'),
        ],
      );
      addTearDown(signedIn.dispose);
      final registry = await storage.getOpenWebUiRegistryStrict();
      final sent = <String>[];

      final (:found, :activeAccountId) = await checkSavedServerAddress(
        signedIn,
        registry: registry,
        serverId: registry.servers.single.id,
        address: 'https://chat.example',
        confirmSendingSession: (_) async => true,
        userAt: (accountId, token) async {
          sent.add(token);
          if (token != 'live-a') throw StateError('401');
          return 'user-a';
        },
      );

      check(found.result).equals(OpenWebUiAddressCheck.sameServer);
      check(sent).deepEquals(['live-a']);
      check(found.provedBy).equals('a');
      check(activeAccountId).equals('a');
    });

    // An address being edited is checked with the cookie kept there, and the
    // check can outlast the editor into an incomplete logout.
    test('an address check keeps a cookie off while logout fences it', () {
      final api = buildAddressCheckApi(
        container,
        const ServerConfig(
          id: 'a',
          name: 'Chat',
          url: 'https://chat.example',
          customHeaders: {'Cookie': 'proxy=1'},
        ),
      );
      addTearDown(api.dispose);
      check(api.cookieCustomHeaderSuppressed).isFalse();

      container
          .read(incompleteLogoutFenceProvider.notifier)
          .setSuppressed(true);

      check(api.cookieCustomHeaderSuppressed).isTrue();
    });
  });
}

/// Refuses to save the saved servers with a proxy cookie while
/// [refusesCookie], as an unavailable Keychain does.
final class _CookieRefusingSecureStore extends InMemorySecureKeyValueStore {
  var refusesCookie = false;

  @override
  Future<void> write({required String key, required String? value}) {
    if (refusesCookie &&
        key == 'openwebui_registry_v1' &&
        (value?.contains('proxy=1') ?? false)) {
      throw StateError('Keychain unavailable');
    }
    return super.write(key: key, value: value);
  }
}

/// Records the route checks asked for instead of probing.
final class _Routes extends OpenWebUiRouteResolver {
  _Routes();

  static final reasons = <String>[];

  @override
  OpenWebUiRouteStatus build() => const OpenWebUiRouteStatus();

  @override
  Future<void> resolve({String reason = 'manual'}) async => reasons.add(reason);
}
