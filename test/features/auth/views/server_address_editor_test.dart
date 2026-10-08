import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
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
import 'package:material_ui/material_ui.dart';
import 'package:hive_ce/hive.dart';

/// The address editor: opening an address of a saved server, checking it,
/// and saving it once checked.
void main() {
  late Directory tempDir;
  late WorkerManager workerManager;
  late _LockableSecureStore secure;
  late _CookieRefusingStorage storage;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('address-editor-test');
    Hive.init(tempDir.path);
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    workerManager = WorkerManager(maxConcurrentTasks: 1);
    secure = _LockableSecureStore();
    storage = _CookieRefusingStorage(
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

  // Nothing awaited the read, so its failure reached only the zone and the
  // form sat empty without a word.
  testWidgets('editing an address says when the saved server cannot be read', (
    tester,
  ) async {
    secure.locked = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerConnectionPage(routesOfServerId: 'home', endpointId: 'e'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text('Something went wrong. Please try again.'),
      findsOneWidget,
    );
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

/// Refuses to read the saved servers while [locked], as a locked Keychain
/// does.
final class _LockableSecureStore extends InMemorySecureKeyValueStore {
  var locked = false;

  @override
  Future<String?> read({required String key}) {
    if (locked && key == 'openwebui_registry_v1') {
      throw StateError('The keychain is locked.');
    }
    return super.read(key: key);
  }
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
