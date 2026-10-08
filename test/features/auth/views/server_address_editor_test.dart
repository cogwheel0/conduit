import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// The address editor: saving an address of a saved server once it has
/// been checked.
void main() {
  late Directory tempDir;
  late WorkerManager workerManager;
  late _CookieRefusingStorage storage;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('address-editor-test');
    Hive.init(tempDir.path);
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    workerManager = WorkerManager(maxConcurrentTasks: 1);
    storage = _CookieRefusingStorage(
      secureStorage: InMemorySecureKeyValueStore(),
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

  // Otherwise the address in use is saved somewhere new while the client
  // and the addresses shown stay where it was.
  test('an address saved without its cookie still moves the client', () async {
    await storage.saveServerConfigs([
      const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
    ]);
    await storage.setActiveServerId('a');
    final server = (await storage.getOpenWebUiRegistryStrict()).servers.single;
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

    check(await inUse()).equals('https://moved.example');
    check(await shown()).equals('https://moved.example');
    check(_Routes.reasons).deepEquals(['routes-edited']);
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

    container.read(incompleteLogoutFenceProvider.notifier).setSuppressed(true);

    check(api.cookieCustomHeaderSuppressed).isTrue();
  });
}

/// Fails to keep a proxy cookie, as a Keychain refusing a write does.
final class _CookieRefusingStorage extends OptimizedStorageService {
  _CookieRefusingStorage({
    required super.secureStorage,
    required super.boxes,
    required super.workerManager,
  });

  @override
  Future<bool> saveEndpointSessionHeaders({
    required String accountId,
    required OpenWebUiEndpoint route,
    required Map<String, String> headers,
    required int sessionRevision,
  }) async => throw StateError('Keychain unavailable');
}

/// Records the route checks asked for instead of probing.
final class _Routes extends OpenWebUiRouteResolver {
  static final reasons = <String>[];

  @override
  OpenWebUiRouteStatus build() => const OpenWebUiRouteStatus();

  @override
  Future<void> resolve({String reason = 'manual'}) async => reasons.add(reason);
}
