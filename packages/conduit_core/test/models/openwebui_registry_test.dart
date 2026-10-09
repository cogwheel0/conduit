import 'package:checks/checks.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:test/test.dart';

/// The saved-server registry and its [ServerConfig] projection.
///
/// Everything outside storage still reads and writes [ServerConfig]s, so the
/// property that matters most is that a list of configs survives a write and
/// a read unchanged, while two accounts on one server really share it.
void main() {
  ServerConfig config(
    String id, {
    String? url,
    Map<String, String> headers = const <String, String>{},
    bool isActive = false,
    String? mtlsKey,
  }) => ServerConfig(
    id: id,
    name: 'Server $id',
    url: url ?? 'https://$id.example.com',
    customHeaders: headers,
    isActive: isActive,
    mtlsCertificateChainPem: mtlsKey == null ? null : 'chain-$mtlsKey',
    mtlsPrivateKeyPem: mtlsKey,
  );

  group('mergeServerConfigs', () {
    test('round-trips the configs it was given', () {
      final configs = [
        config('a', isActive: true),
        config(
          'b',
          headers: const {'X-Tenant': 'one', 'Cookie': 'proxy=b'},
          mtlsKey: 'key-b',
        ).copyWith(allowSelfSignedCertificates: true),
      ];

      final registry = OpenWebUiRegistry.empty.mergeServerConfigs(configs);

      check(registry.projectAll()).deepEquals(configs);
      check(OpenWebUiRegistry.decode(registry.encode()).projectAll())
          .deepEquals(configs);
    });

    test('never stores a legacy apiKey', () {
      final registry = OpenWebUiRegistry.empty.mergeServerConfigs([
        config('a').copyWith(apiKey: 'legacy-bearer'),
      ]);

      check(registry.projectAll().single.apiKey).isNull();
      check(registry.encode()).not((it) => it.contains('legacy-bearer'));
    });

    test('accounts that reach a server identically share it', () {
      final registry = OpenWebUiRegistry.empty.mergeServerConfigs([
        config('a', url: 'https://chat.example.com'),
        config('b', url: 'https://chat.example.com'),
        config('c', url: 'https://other.example.com'),
      ]);

      check(registry.servers).length.equals(2);
      check(registry.account('a')!.serverId)
          .equals(registry.account('b')!.serverId);
      check(registry.account('c')!.serverId)
          .not((it) => it.equals(registry.account('a')!.serverId));
    });

    test('a different client identity is a different server', () {
      final registry = OpenWebUiRegistry.empty.mergeServerConfigs([
        config('a', url: 'https://chat.example.com', mtlsKey: 'one'),
        config('b', url: 'https://chat.example.com', mtlsKey: 'two'),
      ]);

      check(registry.servers).length.equals(2);
    });

    test('a captured cookie belongs to its account, not the endpoint', () {
      final registry = OpenWebUiRegistry.empty.mergeServerConfigs([
        config(
          'a',
          url: 'https://chat.example.com',
          headers: const {'X-Tenant': 't', 'Cookie': 'proxy=alice'},
        ),
        config(
          'b',
          url: 'https://chat.example.com',
          headers: const {'X-Tenant': 't', 'cookie': 'proxy=bob'},
        ),
      ]);

      check(registry.servers).length.equals(1);
      check(registry.servers.single.endpoints.single.customHeaders)
          .deepEquals({'X-Tenant': 't'});
      check(registry.project('a')!.customHeaders)
          .deepEquals({'X-Tenant': 't', 'Cookie': 'proxy=alice'});
      check(registry.project('b')!.customHeaders)
          .deepEquals({'X-Tenant': 't', 'cookie': 'proxy=bob'});
    });

    test('an endpoint edit through one account reaches the other', () {
      final shared = OpenWebUiRegistry.empty.mergeServerConfigs([
        config('a', url: 'https://chat.example.com'),
        config('b', url: 'https://chat.example.com'),
      ]);
      final configs = shared.projectAll();

      // The edited copy of a is saved alongside b's unchanged copy, the way a
      // read-modify-write of the whole list does. b must not undo the edit.
      final edited = shared.mergeServerConfigs([
        configs[0].copyWith(url: 'https://chat.example.org'),
        configs[1],
      ]);

      check(edited.project('a')!.url).equals('https://chat.example.org');
      check(edited.project('b')!.url).equals('https://chat.example.org');
      check(edited.servers).length.equals(1);
    });

    test('of two different edits to a shared endpoint, the later wins', () {
      final shared = OpenWebUiRegistry.empty.mergeServerConfigs([
        config('a', url: 'https://chat.example.com'),
        config('b', url: 'https://chat.example.com'),
      ]);
      final configs = shared.projectAll();

      final edited = shared.mergeServerConfigs([
        configs[0].copyWith(url: 'https://chat.example.org'),
        configs[1].copyWith(url: 'https://chat.example.net'),
      ]);

      check(edited.project('a')!.url).equals('https://chat.example.net');
      check(edited.project('b')!.url).equals('https://chat.example.net');
      check(edited.servers).length.equals(1);
    });

    test('dropping the last account of a server drops the server', () {
      final registry = OpenWebUiRegistry.empty.mergeServerConfigs([
        config('a'),
        config('b'),
      ]);

      final next = registry.mergeServerConfigs([registry.project('b')!]);

      check(next.accounts.map((account) => account.id)).deepEquals(['b']);
      check(next.servers).length.equals(1);
      check(next.servers.single.id).equals(registry.account('b')!.serverId);
    });

    test('an account keeps its proven user across edits', () {
      final registry = OpenWebUiRegistry.empty.mergeServerConfigs([
        config('a'),
      ]);
      final bound = registry.withAccount(
        registry.account('a')!.copyWith(userId: 'user-1'),
      );

      final edited = bound.mergeServerConfigs([
        bound.project('a')!.copyWith(customHeaders: const {'X-New': 'v'}),
      ]);

      check(edited.account('a')!.userId).equals('user-1');
    });

    test('projects the selected endpoint and its own cookie', () {
      final registry = OpenWebUiRegistry(
        servers: [
          OpenWebUiServer(
            id: 's',
            name: 'Home',
            endpoints: [
              OpenWebUiEndpoint(id: 'lan', url: 'http://10.0.0.2:3000'),
              OpenWebUiEndpoint(
                id: 'proxy',
                url: 'https://chat.example.com',
                customHeaders: const {'X-Gate': 'g'},
              ),
            ],
          ),
        ],
        accounts: [
          OpenWebUiAccount(
            id: 'a',
            serverId: 's',
            capturedHeaders: const {
              'proxy': {'Cookie': 'session=1'},
            },
          ),
        ],
      );

      check(registry.project('a')!.url).equals('http://10.0.0.2:3000');
      check(registry.project('a')!.customHeaders).isEmpty();

      final viaProxy = registry.project(
        'a',
        selectedEndpoints: const {'s': 'proxy'},
      )!;
      check(viaProxy.url).equals('https://chat.example.com');
      check(viaProxy.customHeaders)
          .deepEquals({'X-Gate': 'g', 'Cookie': 'session=1'});
    });

    test('a config read on a route not in use is saved to that route', () {
      final registry = OpenWebUiRegistry(
        servers: [
          OpenWebUiServer(
            id: 's',
            name: 'Home',
            endpoints: [
              OpenWebUiEndpoint(id: 'lan', url: 'http://10.0.0.2:3000'),
              OpenWebUiEndpoint(id: 'proxy', url: 'https://chat.example.com'),
            ],
          ),
        ],
        accounts: [OpenWebUiAccount(id: 'a', serverId: 's')],
      );
      // Read while the proxy route was in use; saved once the LAN is.
      final viaProxy = registry.project(
        'a',
        selectedEndpoints: const {'s': 'proxy'},
      )!;

      final next = registry.mergeServerConfigs([
        viaProxy.copyWith(customHeaders: const {'Cookie': 'session=2'}),
      ]);

      check(next.servers.single.endpoints.map((endpoint) => endpoint.url))
          .deepEquals(['http://10.0.0.2:3000', 'https://chat.example.com']);
      check(next.account('a')!.capturedHeaders).deepEquals({
        'proxy': {'Cookie': 'session=2'},
      });
      check(next.project('a')!.customHeaders).isEmpty();
    });

    test('a config read on a route sharing the URL in use is saved to it', () {
      final registry = OpenWebUiRegistry(
        servers: [
          OpenWebUiServer(
            id: 's',
            name: 'Home',
            endpoints: [
              OpenWebUiEndpoint(id: 'main', url: 'https://chat.example.com'),
              OpenWebUiEndpoint(
                id: 'tenant',
                url: 'https://chat.example.com',
                customHeaders: const {'X-Tenant': 'b'},
              ),
            ],
          ),
        ],
        accounts: [OpenWebUiAccount(id: 'a', serverId: 's')],
      );
      // Read while the tenant route was in use; saved once main is.
      final viaTenant = registry.project(
        'a',
        selectedEndpoints: const {'s': 'tenant'},
      )!;

      final next = registry.mergeServerConfigs([
        viaTenant.copyWith(
          customHeaders: const {'X-Tenant': 'b', 'Cookie': 'session=2'},
        ),
      ], selectedEndpoints: const {'s': 'main'});

      check(
        next.servers.single.endpoints.map((endpoint) => endpoint.customHeaders),
      ).deepEquals([
        const <String, String>{},
        const {'X-Tenant': 'b'},
      ]);
      check(next.account('a')!.capturedHeaders).deepEquals({
        'tenant': {'Cookie': 'session=2'},
      });
    });
  });

  test('an address never keeps a session header', () {
    final route = OpenWebUiEndpoint(
      id: 'e',
      url: 'https://chat.example.com',
      customHeaders: const {'X-Gate': 'g', 'cookie': 'proxy=1'},
    );

    check(route.customHeaders).deepEquals({'X-Gate': 'g'});
  });

  group('fromLegacyServerConfigs', () {
    test('keeps only configs that can still reach a session', () {
      final registry = OpenWebUiRegistry.fromLegacyServerConfigs(
        [config('stale-1'), config('active'), config('stale-2'), config('v')],
        priority: const ['active', 'v'],
        userIdFor: (_) => null,
      );

      check(registry.accounts.map((account) => account.id))
          .deepEquals(['active', 'v']);
      check(registry.servers).length.equals(2);
    });

    test('binds the user an owner marker proved', () {
      final registry = OpenWebUiRegistry.fromLegacyServerConfigs(
        [config('a')],
        priority: const ['a'],
        userIdFor: (id) => id == 'a' ? ' user-1 ' : null,
      );

      check(registry.account('a')!.userId).equals('user-1');
    });

    test('one user on one server collapses into the preferred account', () {
      final registry = OpenWebUiRegistry.fromLegacyServerConfigs(
        [
          config('older', url: 'https://chat.example.com'),
          config('active', url: 'https://chat.example.com'),
        ],
        priority: const ['active', 'older'],
        userIdFor: (_) => 'user-1',
      );

      check(registry.accounts.map((account) => account.id))
          .deepEquals(['active']);
      check(registry.servers).length.equals(1);
    });

    test('an id listed twice ranks where it is listed first', () {
      final collapsed = <String, String>{};
      final registry = OpenWebUiRegistry.fromLegacyServerConfigs(
        [
          config('older', url: 'https://chat.example.com'),
          config('active', url: 'https://chat.example.com'),
        ],
        // The active account first, and again later as a vaulted id.
        priority: const ['active', 'older', 'active'],
        userIdFor: (_) => 'user-1',
        onCollapsed: (dropped, kept) => collapsed[dropped] = kept,
      );

      check(registry.accounts.map((account) => account.id))
          .deepEquals(['active']);
      check(collapsed).deepEquals({'older': 'active'});
    });

    test('two users on one server stay two accounts on it', () {
      final registry = OpenWebUiRegistry.fromLegacyServerConfigs(
        [
          config('a', url: 'https://chat.example.com'),
          config('b', url: 'https://chat.example.com'),
        ],
        priority: const ['a', 'b'],
        userIdFor: (id) => 'user-$id',
      );

      check(registry.accounts).length.equals(2);
      check(registry.servers).length.equals(1);
    });
  });

  group('decode', () {
    test('rejects a newer document version', () {
      check(
        () => OpenWebUiRegistry.decode(
          '{"version":2,"servers":[],"accounts":[]}',
        ),
      ).throws<FormatException>();
    });

    test('rejects an account whose server is not saved', () {
      check(
        () => OpenWebUiRegistry.decode(
          '{"version":1,"servers":[],'
          '"accounts":[{"id":"a","serverId":"missing"}]}',
        ),
      ).throws<FormatException>();
    });

    test('rejects a server without endpoints', () {
      check(
        () => OpenWebUiRegistry.decode(
          '{"version":1,"servers":[{"id":"s","name":"n","endpoints":[]}],'
          '"accounts":[]}',
        ),
      ).throws<FormatException>();
    });
  });

  group('withEditedRoute', () {
    final lan = OpenWebUiEndpoint(id: 'lan', url: 'http://10.0.0.2:3000');
    final proxy = OpenWebUiEndpoint(id: 'proxy', url: 'https://proxy.example');
    final edited = OpenWebUiEndpoint(
      id: 'proxy',
      url: 'https://edited.example',
    );

    test('saves an edit in place', () {
      check(withEditedRoute([proxy, lan], edited, adding: false))
          .deepEquals([edited, lan]);
    });

    // Removed while the edit was being checked; saving would bring it back.
    test('fails for an address no longer saved', () {
      check(() => withEditedRoute([lan], edited, adding: false))
          .throws<StateError>();
    });

    test('appends only an addition', () {
      check(withEditedRoute([lan], proxy, adding: true))
          .deepEquals([lan, proxy]);
      // An addition saved already, by a save that went wrong after it, is
      // saved in place rather than twice.
      check(withEditedRoute([proxy, lan], edited, adding: true))
          .deepEquals([edited, lan]);
    });
  });

  test('server identity URLs ignore case and a trailing slash', () {
    check(openWebUiServerIdentityUrl('HTTPS://Chat.Example.com/'))
        .equals('https://chat.example.com');
    check(openWebUiServerIdentityUrl('https://chat.example.com/owui//'))
        .equals('https://chat.example.com/owui');
  });
}
