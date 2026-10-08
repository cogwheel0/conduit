import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/testing/fake_app_lifecycle.dart';
import 'package:hive_ce/hive.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _lan = 'http://10.0.0.2:3000';
const _tailscale = 'http://home.tailnet.ts.net:3000';
const _public = 'https://chat.example.com';

/// An address none of the server's routes reach.
const _elsewhere = 'https://typo.example';

/// Which of a server's routes the app uses.
///
/// The first route in the user's order that answers wins. A route that
/// stopped answering is left right away; moving up to a better one waits
/// while a reply is being written, since rebuilding the client cuts it off.
void main() {
  late Directory tempDir;
  late WorkerManager workerManager;
  late _GatedStorage storage;
  late ProviderContainer container;
  late Map<String, bool> answers;
  late List<String> probed;
  var replyInProgress = false;
  var signingIn = false;
  late FakeAppLifecycle lifecycle;
  Completer<void>? probesAnswer;
  late _Auth auth;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('route-resolver-test');
    Hive.init(tempDir.path);
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    workerManager = WorkerManager(maxConcurrentTasks: 1);
    storage = _GatedStorage(
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
    signingIn = false;
    lifecycle = FakeAppLifecycle();
    probesAnswer = null;
    auth = _Auth(AuthStatus.authenticated);

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
    await lifecycle.dispose();
    workerManager.dispose();
    PreferencesStore.debugReset();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<OpenWebUiRouteResolver> resolver() async {
    container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        openWebUiRouteProbeProvider.overrideWithValue((route) async {
          probed.add(route.url);
          await probesAnswer?.future;
          return answers[route.url] ?? false;
        }),
        accountChangeReplyGuardProvider.overrideWithValue(
          () => replyInProgress,
        ),
        openWebUiSignInPendingProvider.overrideWithValue(() => signingIn),
        appLifecycleProvider.overrideWithValue(lifecycle),
        authStateManagerProvider.overrideWith(() => auth),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
    final notifier = container.read(openWebUiRouteResolverProvider.notifier);
    // Let the resolver's own start-up check run and settle first.
    await Future<void>.delayed(Duration.zero);
    return notifier;
  }

  Future<String> routeInUse() async =>
      (await storage.getServerConfigsStrict()).single.url;

  /// Lets whatever a report started run to its end.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  Future<void> until(bool Function() condition) async {
    for (var turn = 0; turn < 100 && !condition(); turn++) {
      await Future<void>.delayed(Duration.zero);
    }
    check(condition()).isTrue();
  }

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

  // Storage counts it active with no id kept for it, as it does an account
  // only flagged active.
  test('checks the routes of the only account saved', () async {
    await storage.setActiveServerId(null);
    answers = {_lan: false, _tailscale: true, _public: true};
    final routes = await resolver();

    await routes.resolve();

    check(await routeInUse()).equals(_tailscale);
    check(routes.state.endpointId).equals('tailscale');
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

  // Moving would rebuild the client the sign-in is being checked on.
  test('a better route waits while the active account signs in', () async {
    answers = {_lan: false, _tailscale: false, _public: true};
    final routes = await resolver();
    await routes.resolve();

    answers[_lan] = true;
    signingIn = true;
    await routes.resolve();
    check(await routeInUse()).equals(_public);

    // As the check put off then does.
    signingIn = false;
    await routes.resolve();
    check(await routeInUse()).equals(_lan);
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

  test('reordering keeps the route in use until a check moves it', () async {
    answers = {_lan: true, _tailscale: true, _public: true};
    final routes = await resolver();
    final server = (await storage.getOpenWebUiRegistryStrict()).servers.single;

    await storage.saveServer(
      OpenWebUiServer(
        id: server.id,
        name: server.name,
        endpoints: server.endpoints.reversed.toList(),
      ),
    );
    check(await routeInUse()).equals(_lan);

    replyInProgress = true;
    await routes.resolve(reason: 'routes-edited');
    check(await routeInUse()).equals(_lan);

    replyInProgress = false;
    await routes.resolve(reason: 'routes-edited');
    check(await routeInUse()).equals(_public);
  });

  // A locked Keychain, say. Nothing else starts a check once it opens.
  test('a check that cannot read storage runs again', () async {
    answers = {_lan: true, _tailscale: true, _public: true};
    final routes = await resolver();
    storage.failNextRegistryRead = true;

    await routes.resolve();

    check(routes.retryPending).isTrue();
  });

  test('a check overtaken by a newer one still moves the client', () async {
    final routes = await resolver();
    check((await container.read(serverConfigsProvider.future)).single.url)
        .equals(_lan);
    answers = {_lan: false, _tailscale: true, _public: true};
    final gate = storage.gate = Completer<void>();

    final first = routes.resolve(reason: 'first');
    await until(() => storage.selectCalls == 1);
    final second = routes.resolve(reason: 'second');
    await until(() => storage.selectCalls == 2);
    gate.complete();
    await first;
    await second;

    check((await container.read(serverConfigsProvider.future)).single.url)
        .equals(_tailscale);
  });

  group('a request failing to reach its server', () {
    test('checks the routes when it was the route in use', () async {
      answers = {_lan: true, _tailscale: false, _public: true};
      final routes = await resolver();
      await routes.resolve();
      answers[_lan] = false;

      ConnectivityService.reportTransportFailure(Uri.parse('$_lan/api/chats'));

      await until(() => routes.state.endpointId == 'public');
      check(await routeInUse()).equals(_public);
    });

    test('checks them when it was the route a check moved to', () async {
      final routes = await resolver();
      answers = {_lan: false, _tailscale: false, _public: true};
      await routes.resolve();
      answers = {_lan: false, _tailscale: true, _public: false};

      ConnectivityService.reportTransportFailure(Uri.parse(_public));

      await until(() => routes.state.endpointId == 'tailscale');
    });

    // A check that just ran holds the next one back; a failure of the
    // route it moved to must still be looked at once that time has passed.
    test('soon after a check is held back, not dropped', () async {
      answers = {_lan: true, _tailscale: false, _public: true};
      final routes = await resolver();
      await routes.resolve();
      ConnectivityService.reportTransportFailure(Uri.parse(_lan));
      await settle();
      check(routes.trailingCheckPending).isFalse();

      ConnectivityService.reportTransportFailure(Uri.parse(_lan));
      await settle();

      check(routes.trailingCheckPending).isTrue();
      lifecycle.emit(AppLifecyclePhase.paused);
      check(routes.trailingCheckPending).isFalse();
    });

    // An address being checked, or another account's server.
    test('elsewhere checks nothing', () async {
      answers = {_lan: true, _tailscale: false, _public: true};
      final routes = await resolver();
      await routes.resolve();
      probed.clear();

      ConnectivityService.reportTransportFailure(Uri.parse(_elsewhere));
      await settle();

      check(probed).isEmpty();
    });

    // A check it started would hold back the next one for a while.
    test('elsewhere does not hold back a check of the route in use', () async {
      answers = {_lan: true, _tailscale: false, _public: true};
      final routes = await resolver();
      await routes.resolve();

      ConnectivityService.reportTransportFailure(Uri.parse(_elsewhere));
      await settle();
      answers[_lan] = false;
      ConnectivityService.reportTransportFailure(Uri.parse(_lan));

      await until(() => routes.state.endpointId == 'public');
      check(await routeInUse()).equals(_public);
    });
  });

  // Its session there expired: the address answers, with its sign-in.
  test('a proxy refusing the route in use checks the routes', () async {
    answers = {_lan: false, _tailscale: false, _public: true};
    final routes = await resolver();
    await routes.resolve();
    answers = {_lan: false, _tailscale: true, _public: false};

    ConnectivityService.reportRouteRejected(Uri.parse(_public));

    await until(() => routes.state.endpointId == 'tailscale');
    check(await routeInUse()).equals(_tailscale);
  });

  // The proxy can let the health check through and refuse only the requests
  // its expired session should carry.
  group('a proxy refusing a route that passes its health check', () {
    test('moves to another route that answers', () async {
      answers = {_lan: true, _tailscale: false, _public: true};
      final routes = await resolver();
      await routes.resolve();
      check(await routeInUse()).equals(_lan);

      ConnectivityService.reportRouteRejected(Uri.parse(_lan));

      await until(() => routes.state.endpointId == 'public');
      check(await routeInUse()).equals(_public);
    });

    test('moves even while a reply is being written', () async {
      answers = {_lan: false, _tailscale: false, _public: true};
      final routes = await resolver();
      await routes.resolve();
      answers[_tailscale] = true;
      replyInProgress = true;

      ConnectivityService.reportRouteRejected(Uri.parse(_public));

      await until(() => routes.state.endpointId == 'tailscale');
      check(await routeInUse()).equals(_tailscale);
    });
  });

  // A proxy refusing the route left showed a connection issue; nothing else
  // looks at the session again until Retry.
  group('a session left on a connection issue', () {
    test('is checked again once a check moves the route', () async {
      auth = _Auth(AuthStatus.error);
      answers = {_lan: true, _tailscale: false, _public: true};
      final routes = await resolver();
      await routes.resolve();
      check(auth.rechecks).equals(0);

      answers[_lan] = false;
      await routes.resolve();
      check(await routeInUse()).equals(_public);
      check(auth.rechecks).equals(1);

      await routes.resolve();
      check(auth.rechecks).equals(1);
    });

    test('is not checked again while a reply is being written', () async {
      auth = _Auth(AuthStatus.error);
      answers = {_lan: true, _tailscale: false, _public: true};
      final routes = await resolver();
      await routes.resolve();
      answers[_lan] = false;
      replyInProgress = true;

      await routes.resolve();

      check(await routeInUse()).equals(_public);
      check(auth.rechecks).equals(0);
    });

    test('is not checked again in the background', () async {
      auth = _Auth(AuthStatus.error);
      answers = {_lan: true, _tailscale: false, _public: true};
      final routes = await resolver();
      await routes.resolve();
      answers[_lan] = false;
      final answer = probesAnswer = Completer<void>();
      probed.clear();
      final checking = routes.resolve();
      await until(() => probed.isNotEmpty);

      lifecycle.emit(AppLifecyclePhase.paused);
      answer.complete();
      await checking;

      check(await routeInUse()).equals(_public);
      check(auth.rechecks).equals(0);
    });
  });

  test('a signed-in session is not checked again as the route moves', () async {
    answers = {_lan: true, _tailscale: false, _public: true};
    final routes = await resolver();
    await routes.resolve();
    answers[_lan] = false;

    await routes.resolve();

    check(await routeInUse()).equals(_public);
    check(auth.rechecks).equals(0);
  });

  group('in the background', () {
    // Every route, every 30 seconds, while nothing answers.
    test('a check waiting to run again stops', () async {
      final routes = await resolver();
      await routes.resolve();
      check(routes.retryPending).isTrue();

      lifecycle.emit(AppLifecyclePhase.paused);

      check(routes.retryPending).isFalse();
    });

    test('a check finishing there does not wait to run again', () async {
      final routes = await resolver();
      final answer = probesAnswer = Completer<void>();
      probed.clear();
      final checking = routes.resolve();
      await until(() => probed.isNotEmpty);

      lifecycle.emit(AppLifecyclePhase.paused);
      answer.complete();
      await checking;

      check(routes.state.noneAnswered).isTrue();
      check(routes.retryPending).isFalse();
    });

    test('a check that cannot read storage does not run again', () async {
      final routes = await resolver();
      lifecycle.emit(AppLifecyclePhase.paused);
      storage.failNextRegistryRead = true;

      await routes.resolve();

      check(routes.retryPending).isFalse();
    });

    test('a better route put off there waits for the app to return', () async {
      answers = {_lan: false, _tailscale: false, _public: true};
      final routes = await resolver();
      await routes.resolve();
      answers[_lan] = true;
      replyInProgress = true;
      final answer = probesAnswer = Completer<void>();
      probed.clear();
      final checking = routes.resolve();
      await until(() => probed.isNotEmpty);

      lifecycle.emit(AppLifecyclePhase.paused);
      answer.complete();
      await checking;

      check(await routeInUse()).equals(_public);
      check(routes.retryPending).isFalse();
    });

    test('a failure there does not hold back a check after it', () async {
      answers = {_lan: true, _tailscale: false, _public: true};
      final routes = await resolver();
      await routes.resolve();
      lifecycle.emit(AppLifecyclePhase.paused);
      ConnectivityService.reportTransportFailure(Uri.parse(_lan));
      lifecycle.emit(AppLifecyclePhase.resumed);
      await settle();

      answers[_lan] = false;
      ConnectivityService.reportTransportFailure(Uri.parse(_lan));

      await until(() => routes.state.endpointId == 'public');
    });

    test('nothing is checked until the app comes back', () async {
      lifecycle = FakeAppLifecycle(initial: AppLifecyclePhase.paused);
      final routes = await resolver();

      ConnectivityService.reportTransportFailure(Uri.parse(_lan));
      await settle();
      check(probed).isEmpty();

      lifecycle.emit(AppLifecyclePhase.resumed);
      await until(() => probed.isNotEmpty && !routes.state.checking);
      check(routes.retryPending).isTrue();
    });
  });

  test('a route probe keeps a cookie off while logout fences it', () async {
    final cookies = <String?>[];
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    origin.listen((request) async {
      cookies.add(request.headers.value(HttpHeaders.cookieHeader));
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write('{"status":true}');
      await request.response.close();
    });
    final probes = ProviderContainer();
    addTearDown(probes.dispose);
    final probe = probes.read(openWebUiRouteProbeProvider);
    final route = ServerConfig(
      id: 'account',
      name: 'Home',
      url: 'http://${InternetAddress.loopbackIPv4.address}:${origin.port}',
      customHeaders: const {'Cookie': 'proxy=1'},
    );

    check(await probe(route)).isTrue();
    probes.read(incompleteLogoutFenceProvider.notifier).setSuppressed(true);
    check(await probe(route)).isTrue();

    check(cookies).deepEquals(['proxy=1', null]);
  });

  test('a route probe carries that route, not the one in use', () async {
    answers = {_lan: true};
    final routes = await resolver();
    probed.clear();

    await routes.resolve();

    check(probed.toSet()).deepEquals({_lan, _tailscale, _public});
  });
}

/// An active account whose session is [status], counting the times it is
/// asked to check that session again.
final class _Auth extends AuthStateManager {
  _Auth(this.status);

  final AuthStatus status;
  var rechecks = 0;

  @override
  Future<AuthState> build() async => AuthState(status: status, token: 'token');

  @override
  Future<bool> recheckSessionAfterRouteChange() async {
    rechecks++;
    return false;
  }
}

/// Holds route selections at a gate, so two checks can overlap there, and
/// fails a read of the saved servers when asked to.
final class _GatedStorage extends OptimizedStorageService {
  _GatedStorage({
    required super.secureStorage,
    required super.boxes,
    required super.workerManager,
  });

  Completer<void>? gate;
  var selectCalls = 0;
  var failNextRegistryRead = false;

  @override
  Future<OpenWebUiRegistry> getOpenWebUiRegistryStrict() async {
    if (failNextRegistryRead) {
      failNextRegistryRead = false;
      throw StateError('Keychain locked');
    }
    return super.getOpenWebUiRegistryStrict();
  }

  @override
  Future<bool> selectEndpoint(String serverId, String endpointId) async {
    selectCalls++;
    await gate?.future;
    return super.selectEndpoint(serverId, endpointId);
  }
}
