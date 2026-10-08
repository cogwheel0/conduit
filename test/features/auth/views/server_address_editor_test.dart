import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/openwebui_address_check.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
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

  testWidgets('an address typed while the saved one is read stays', (
    tester,
  ) async {
    final server = (await tester.runAsync(() async {
      await storage.saveServerConfigs([
        const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
      ]);
      return (await storage.getOpenWebUiRegistryStrict()).servers.single;
    }))!;
    final read = storage.registryHeld = Completer<void>();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerConnectionPage(
            routesOfServerId: server.id,
            endpointId: server.endpoints.single.id,
          ),
        ),
      ),
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('server-url-field')),
        matching: find.byType(EditableText),
      ),
      'https://typed.example',
    );
    read.complete();
    await tester.pumpAndSettle();

    expect(find.text('https://typed.example'), findsOneWidget);
    expect(find.text('https://chat.example'), findsNothing);
  });

  // Back abandons the edit: the address the server's accounts use stays.
  testWidgets('an address left while it is checked is not saved', (
    tester,
  ) async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final origin = (await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        final body = switch (request.uri.path) {
          '/health' => '{"status":true}',
          '/api/config' =>
            '{"status":true,"version":"0.6.0","name":"Open WebUI",'
                '"features":{}}',
          _ => null,
        };
        request.response
          ..statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(body ?? '{}');
        unawaited(request.response.close());
      });
      return 'http://127.0.0.1:${server.port}';
    }))!;
    final server = (await tester.runAsync(() async {
      await storage.saveServerConfigs([
        const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
      ]);
      return (await storage.getOpenWebUiRegistryStrict()).servers.single;
    }))!;
    // The second read is the address check's, after the address answered.
    final checking = storage.activeReadHeld = Completer<void>();
    storage
      ..activeReads = 0
      ..activeReadHeldFrom = 2;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerConnectionPage(
            routesOfServerId: server.id,
            endpointId: server.endpoints.single.id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('server-url-field')),
        matching: find.byType(EditableText),
      ),
      origin,
    );
    await tester.tap(find.text('Save address'));
    for (var i = 0; i < 100 && storage.activeReads < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    check(storage.activeReads).equals(2);

    // The editor goes while the address is checked.
    await tester.pumpWidget(const SizedBox());
    checking.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );

    final saved = await tester.runAsync(
      () async => (await storage.getOpenWebUiRegistryStrict()).servers.single,
    );
    check(saved!.endpoints.single.url).equals('https://chat.example');
  });

  // Saved, the address in use moves the clients off it, which would end the
  // reply arriving through them.
  testWidgets('saving the address in use while a reply is written asks '
      'first', (tester) async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final origin = (await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        final body = switch (request.uri.path) {
          '/health' => '{"status":true}',
          '/api/config' =>
            '{"status":true,"version":"0.6.0","name":"Open WebUI",'
                '"features":{}}',
          _ => null,
        };
        request.response
          ..statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(body ?? '{}');
        unawaited(request.response.close());
      });
      return 'http://127.0.0.1:${server.port}';
    }))!;
    final server = (await tester.runAsync(() async {
      await storage.saveServerConfigs([
        const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
      ]);
      return (await storage.getOpenWebUiRegistryStrict()).servers.single;
    }))!;
    var stops = 0;
    final replying = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        openWebUiRouteResolverProvider.overrideWith(
          () => _Routes(
            inUse: OpenWebUiRouteStatus(
              serverId: server.id,
              endpointId: server.endpoints.single.id,
            ),
          ),
        ),
        accountChangeReplyGuardProvider.overrideWithValue(() => true),
        accountChangeStopRepliesProvider.overrideWithValue(() => stops++),
      ],
    );
    addTearDown(replying.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: replying,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerConnectionPage(
            routesOfServerId: server.id,
            endpointId: server.endpoints.single.id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('server-url-field')),
        matching: find.byType(EditableText),
      ),
      origin,
    );
    await tester.tap(find.text('Save address'));
    final asked = find.text('A reply is still being written');
    for (var i = 0; i < 100 && asked.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(asked, findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();

    final saved = await tester.runAsync(
      () async => (await storage.getOpenWebUiRegistryStrict()).servers.single,
    );
    check(saved!.endpoints.single.url).equals('https://chat.example');
    check(stops).equals(0);
  });

  testWidgets('an address cannot be edited while it is checked', (
    tester,
  ) async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final origin = (await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        final body = switch (request.uri.path) {
          '/health' => '{"status":true}',
          '/api/config' =>
            '{"status":true,"version":"0.6.0","name":"Open WebUI",'
                '"features":{}}',
          _ => null,
        };
        request.response
          ..statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(body ?? '{}');
        unawaited(request.response.close());
      });
      return 'http://127.0.0.1:${server.port}';
    }))!;
    final server = (await tester.runAsync(() async {
      await storage.saveServerConfigs([
        const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
      ]);
      return (await storage.getOpenWebUiRegistryStrict()).servers.single;
    }))!;
    // The second read is the address check's, after the address answered.
    final checking = storage.activeReadHeld = Completer<void>();
    storage
      ..activeReads = 0
      ..activeReadHeldFrom = 2;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerConnectionPage(
            routesOfServerId: server.id,
            endpointId: server.endpoints.single.id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final urlField = find.descendant(
      of: find.byKey(const ValueKey<String>('server-url-field')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(urlField, origin);
    await tester.tap(find.text('Save address'));
    for (var i = 0; i < 100 && storage.activeReads < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    check(storage.activeReads).equals(2);

    await tester.tap(urlField, warnIfMissed: false);
    await tester.pump();

    check(tester.widget<EditableText>(urlField).focusNode.hasFocus).isFalse();
    check(tester.testTextInput.hasAnyClients).isFalse();

    await tester.pumpWidget(const SizedBox());
    checking.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
  });

  test('an address is saved with the cookie it was checked with', () async {
    await storage.saveServerConfigs([
      const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
    ]);
    await storage.setActiveServerId('a');
    final server = (await storage.getOpenWebUiRegistryStrict()).servers.single;
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

  // Saved without it, an address behind a proxy would be refused, with no
  // other to fall back to; the clients and the addresses shown stay put too.
  test('an address whose cookie cannot be kept is not saved', () async {
    await storage.saveServerConfigs([
      const ServerConfig(id: 'a', name: 'Chat', url: 'https://chat.example'),
    ]);
    await storage.setActiveServerId('a');
    secure.refusesCookie = true;
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
    final server = (await storage.getOpenWebUiRegistryStrict()).servers.single;

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
      endpoints: [OpenWebUiEndpoint(id: 'route', url: 'https://chat.example')],
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
    final server = (await storage.getOpenWebUiRegistryStrict()).servers.single;
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

    container.read(incompleteLogoutFenceProvider.notifier).setSuppressed(true);

    check(api.cookieCustomHeaderSuppressed).isTrue();
  });
}

/// Refuses to read the saved servers while [locked], as a locked Keychain
/// does, and to save them with a proxy cookie while [refusesCookie].
final class _LockableSecureStore extends InMemorySecureKeyValueStore {
  var locked = false;
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

  @override
  Future<String?> read({required String key}) {
    if (locked && key == 'openwebui_registry_v1') {
      throw StateError('The keychain is locked.');
    }
    return super.read(key: key);
  }
}

/// Storage whose reads of the active account and the saved servers can be
/// held.
final class _CookieRefusingStorage extends OptimizedStorageService {
  _CookieRefusingStorage({
    required super.secureStorage,
    required super.boxes,
    required super.workerManager,
  });

  /// Holds a read of the active account, from the [activeReadHeldFrom]th on,
  /// while set.
  Completer<void>? activeReadHeld;
  var activeReadHeldFrom = 1;
  var activeReads = 0;

  @override
  Future<String?> getEffectiveActiveServerId() async {
    if (++activeReads >= activeReadHeldFrom) await activeReadHeld?.future;
    return super.getEffectiveActiveServerId();
  }

  /// Holds a read of the saved servers back while set.
  Completer<void>? registryHeld;

  @override
  Future<OpenWebUiRegistry> getOpenWebUiRegistryStrict() async {
    await registryHeld?.future;
    return super.getOpenWebUiRegistryStrict();
  }
}

/// Records the route checks asked for instead of probing.
final class _Routes extends OpenWebUiRouteResolver {
  _Routes({this.inUse = const OpenWebUiRouteStatus()});

  static final reasons = <String>[];

  final OpenWebUiRouteStatus inUse;

  @override
  OpenWebUiRouteStatus build() => inUse;

  @override
  Future<void> resolve({String reason = 'manual'}) async => reasons.add(reason);
}

class _RealHttpOverrides extends HttpOverrides {}
