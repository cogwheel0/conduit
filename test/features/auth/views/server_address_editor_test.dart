import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/utils/account_display.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/openwebui_server_address.dart';
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
    await tester.tap(find.text('Save Address'));
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
        addressChangeReplyGuardProvider.overrideWithValue(() => true),
        addressChangeStopRepliesProvider.overrideWithValue(() => stops++),
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
    await tester.tap(find.text('Save Address'));
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
    await tester.tap(find.text('Save Address'));
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

  // Connecting names a server after the host it reached; edited to another
  // address, the server was still listed under the host it had left.
  test('an edited address renames the server listed under its old host',
      () async {
    await storage.saveServerConfigs([
      const ServerConfig(
        id: 'a',
        name: '100.64.0.3',
        url: 'http://100.64.0.3:8080',
      ),
    ]);
    await storage.setActiveServerId('a');
    final server = (await storage.getOpenWebUiRegistryStrict()).servers.single;

    check(
      await saveCheckedAddress(
        container,
        serverId: server.id,
        route: OpenWebUiEndpoint(
          id: server.endpoints.single.id,
          url: 'http://100.64.0.7:8080',
        ),
        adding: false,
        cookieOwner: null,
        headers: const {},
        sessionRevision: storage.sessionRevocationRevision,
      ),
    ).isTrue();

    final listed = await container.read(openWebUiAccountsProvider.future);
    check(serverDisplayName(listed.single.server)).equals('100.64.0.7');
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
