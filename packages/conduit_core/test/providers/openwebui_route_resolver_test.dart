import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:hive_ce/hive.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _lan = 'http://10.0.0.2:3000';
const _tailscale = 'http://home.tailnet.ts.net:3000';
const _public = 'https://chat.example.com';

/// Which of a server's routes the app uses.
///
/// The first route in the user's order that answers wins. A route that
/// stopped answering is left right away; moving up to a better one waits
/// while a reply is being written, since rebuilding the client cuts it off.
void main() {
  late Directory tempDir;
  late WorkerManager workerManager;
  late OptimizedStorageService storage;
  late Map<String, bool> answers;
  late List<String> probed;
  var replyInProgress = false;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('route-resolver-test');
    Hive.init(tempDir.path);
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    workerManager = WorkerManager(maxConcurrentTasks: 1);
    storage = OptimizedStorageService(
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
    answers = {};
    probed = [];
    replyInProgress = false;

    await storage.saveServerConfigs([
      const ServerConfig(id: 'account', name: 'Home', url: _lan),
    ]);
    await storage.setActiveServerId('account');
    final registry = await storage.getOpenWebUiRegistryStrict();
    final server = registry.servers.single;
    await storage.saveServer(
      OpenWebUiServer(
        id: server.id,
        name: server.name,
        endpoints: [
          server.endpoints.single,
          OpenWebUiEndpoint(id: 'tailscale', url: _tailscale),
          OpenWebUiEndpoint(id: 'public', url: _public),
        ],
      ),
    );
  });

  tearDown(() async {
    workerManager.dispose();
    PreferencesStore.debugReset();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<OpenWebUiRouteResolver> resolver() async {
    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        openWebUiRouteProbeProvider.overrideWithValue((route) async {
          probed.add(route.url);
          return answers[route.url] ?? false;
        }),
        accountChangeReplyGuardProvider.overrideWithValue(
          () => replyInProgress,
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(openWebUiRouteResolverProvider.notifier);
    // Let the resolver's own start-up check run and settle first.
    await Future<void>.delayed(Duration.zero);
    return notifier;
  }

  Future<String> routeInUse() async =>
      (await storage.getServerConfigsStrict()).single.url;

  test('uses the first route in order that answers', () async {
    answers = {_lan: false, _tailscale: true, _public: true};
    final routes = await resolver();

    await routes.resolve();

    check(await routeInUse()).equals(_tailscale);
    check(routes.state.endpointId).equals('tailscale');
    check(PreferencesStore.getString(PreferenceKeys.openWebUiEndpointHint))
        .isNotNull()
        .contains('tailscale');
  });

  test('goes back to a better route once it answers again', () async {
    answers = {_lan: false, _tailscale: false, _public: true};
    final routes = await resolver();
    await routes.resolve();
    check(await routeInUse()).equals(_public);

    answers[_lan] = true;
    await routes.resolve();

    check(await routeInUse()).equals(_lan);
  });

  test('a better route waits while a reply is being written', () async {
    answers = {_lan: false, _tailscale: false, _public: true};
    final routes = await resolver();
    await routes.resolve();

    answers[_lan] = true;
    replyInProgress = true;
    await routes.resolve();

    check(await routeInUse()).equals(_public);
  });

  test('a route that stopped answering is left even mid-reply', () async {
    answers = {_lan: true, _tailscale: false, _public: true};
    final routes = await resolver();
    await routes.resolve();
    check(await routeInUse()).equals(_lan);

    answers[_lan] = false;
    replyInProgress = true;
    await routes.resolve();

    check(await routeInUse()).equals(_public);
  });

  test('when nothing answers the route in use is kept', () async {
    final routes = await resolver();

    await routes.resolve();

    check(await routeInUse()).equals(_lan);
    check(routes.state.noneAnswered).isTrue();
  });

  test('a server with one route is never probed', () async {
    final registry = await storage.getOpenWebUiRegistryStrict();
    final server = registry.servers.single;
    await storage.saveServer(
      OpenWebUiServer(
        id: server.id,
        name: server.name,
        endpoints: [server.endpoints.first],
      ),
    );
    final routes = await resolver();

    await routes.resolve();

    check(probed).isEmpty();
    check(routes.state.endpointId).equals(server.endpoints.first.id);
  });

  test('a route probe carries that route, not the one in use', () async {
    answers = {_lan: true};
    final routes = await resolver();
    probed.clear();

    await routes.resolve();

    check(probed.toSet()).deepEquals({_lan, _tailscale, _public});
  });
}
