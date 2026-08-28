import 'dart:async';

import 'package:conduit/core/models/tool.dart';
import 'package:conduit/core/services/secure_credential_storage.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_mcp_oauth.dart';
import 'package:conduit/features/direct_connections/services/direct_mcp_server_store.dart';
import 'package:conduit/features/chat/widgets/composer_overflow_items.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/features/direct_connections/views/direct_mcp_server_editor_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
  });

  test('direct native actions expose only local MCP tool bundles', () {
    const tool = Tool(id: 'local_mcp:home', name: 'Home MCP');
    final actions = buildIosKeyboardAttachmentActions(
      l10n: AppLocalizationsEn(),
      attachmentAvailability: const ComposerOverflowAttachmentAvailability(),
      hermesMode: false,
      directMode: true,
      webSearchAvailable: false,
      webSearchEnabled: false,
      imageGenerationAvailable: false,
      imageGenerationEnabled: false,
      availableTools: const [tool],
      selectedToolIds: const ['local_mcp:home'],
      availableFilters: const [],
      selectedFilterIds: const [],
    );

    expect(actions.single.id, ComposerOverflowActionIds.tool(tool.id));
    expect(actions.single.selected, isTrue);
    expect(actions.single.section, 'tools');
  });

  testWidgets('management lists MCP servers without endpoint query secrets', (
    tester,
  ) async {
    String? edited;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: const [],
            mcpServers: [
              DirectMcpServer(
                id: 'home',
                name: 'Home MCP',
                endpoint: 'http://192.168.1.4:3000/mcp?token=secret',
              ),
            ],
            syncWithOpenWebUi: false,
            isOnboarding: false,
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
            onEditMcp: (id) => edited = id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MCP servers'), findsOneWidget);
    expect(find.text('Home MCP'), findsOneWidget);
    expect(find.textContaining('token=secret'), findsNothing);
    expect(find.textContaining('http://192.168.1.4:3000/mcp'), findsOneWidget);

    await tester.tap(find.text('Home MCP'));
    expect(edited, 'home');
  });

  testWidgets('empty MCP section exposes an add action', (tester) async {
    var additions = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: const [],
            syncWithOpenWebUi: false,
            isOnboarding: false,
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
            onAddMcp: () => additions++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('No MCP servers yet'));
    expect(additions, 1);
  });

  test('server mutation refreshes its dependent tool inventory', () async {
    final store = _managementStore();
    final server = DirectMcpServer(
      id: 'refresh-smoke',
      name: 'Refresh smoke server',
      endpoint: 'http://127.0.0.1:1234/mcp',
    );
    await store.upsert(server);
    final container = ProviderContainer(
      overrides: [
        directMcpServerStoreProvider.overrideWithValue(store),
        directMcpToolsProvider.overrideWith((ref) async {
          final servers = await ref.watch(directMcpServersProvider.future);
          return [
            for (final server in servers)
              if (server.enabled)
                Tool(id: 'local_mcp:${server.id}', name: server.name),
          ];
        }),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(directMcpToolsProvider, (_, _) {});
    addTearDown(subscription.close);

    expect(
      (await container.read(directMcpToolsProvider.future)).single.id,
      'local_mcp:refresh-smoke',
    );
    final servers = await container
        .read(directMcpServersProvider.notifier)
        .upsert(server.copyWith(enabled: false), expectedPrevious: server);

    expect(servers.single.enabled, isFalse);
    expect(await container.read(directMcpToolsProvider.future), isEmpty);
  });

  testWidgets('management shows an MCP secure-storage load failure', (
    tester,
  ) async {
    var additions = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: const [],
            mcpLoadFailed: true,
            syncWithOpenWebUi: false,
            isOnboarding: false,
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
            onAddMcp: () => additions++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Could not load MCP servers from secure storage.'),
      findsOneWidget,
    );
    expect(find.text('No MCP servers yet'), findsNothing);
    await tester.tap(find.text('Add connection').last);
    expect(additions, 1);
  });

  testWidgets('MCP editor hosts Material fields on an iOS utility route', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directMcpServersProvider.overrideWithBuild(
            (ref, notifier) async => const [],
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectMcpServerEditorPage(serverId: 'new'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('direct-mcp-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-mcp-endpoint')), findsOneWidget);
  });

  testWidgets('MCP editor reinitializes after the new route gets an id', (
    tester,
  ) async {
    final store = _managementStore();
    final server = await _saveManagementOAuthServer(
      store,
      Uri.parse('https://resource.example/mcp'),
    );
    final coordinator = DirectMcpOAuthCoordinator(store: store);
    addTearDown(coordinator.close);

    await _pumpOAuthEditor(
      tester,
      store,
      coordinator,
      'new',
      editorKey: const ValueKey('same-route-editor'),
    );
    expect(find.text('Add MCP server'), findsOneWidget);

    await _pumpOAuthEditor(
      tester,
      store,
      coordinator,
      server.id,
      editorKey: const ValueKey('same-route-editor'),
    );
    expect(find.text('Edit MCP server'), findsOneWidget);
    expect(find.text('OAuth UI'), findsOneWidget);
    expect(find.text('https://resource.example/mcp'), findsOneWidget);
    expect(find.text('This MCP server no longer exists.'), findsNothing);
  });

  testWidgets('OAuth editor renders no secrets and disconnects', (
    tester,
  ) async {
    final store = _managementStore();
    final server = await _saveManagementOAuthServer(
      store,
      Uri.parse('https://resource.example/mcp'),
      connected: true,
    );
    final coordinator = DirectMcpOAuthCoordinator(store: store);
    addTearDown(coordinator.close);
    await _pumpOAuthEditor(tester, store, coordinator, server.id);

    expect(find.textContaining('auth.example'), findsOneWidget);
    expect(find.textContaining('tools.read'), findsOneWidget);
    expect(find.text('Reconnect in browser'), findsOneWidget);
    expect(find.text('Disconnect OAuth'), findsOneWidget);
    expect(find.textContaining('access-ui-secret'), findsNothing);
    expect(find.textContaining('refresh-ui-secret'), findsNothing);
    expect(find.textContaining('authorization-code'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('direct-mcp-oauth-disconnect')));
    await tester.pumpAndSettle();

    expect(find.text('Connect in browser'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('direct-mcp-oauth-details')),
      findsNothing,
    );
    expect((await store.load()).single.oauthTokens, isNull);
  });

  testWidgets('MCP editor revokes remembered tool approvals', (tester) async {
    final store = _managementStore();
    final server = DirectMcpServer(
      id: 'remembered-ui',
      name: 'Remembered UI',
      endpoint: 'https://resource.example/mcp',
      rememberedApprovals: [
        _managementApproval('a', 'lookup', 'Lookup'),
        _managementApproval('b', 'search', 'Search'),
      ],
    );
    await store.upsert(server);
    final coordinator = DirectMcpOAuthCoordinator(store: store);
    addTearDown(coordinator.close);
    await _pumpOAuthEditor(tester, store, coordinator, server.id);

    expect(find.text('Always allowed tools'), findsOneWidget);
    expect(find.text('Lookup'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.textContaining('a' * 64), findsNothing);
    final firstRevoke = find.text('Revoke').first;
    await tester.ensureVisible(firstRevoke);
    await tester.tap(firstRevoke);
    await tester.pumpAndSettle();
    expect((await store.load()).single.rememberedApprovals, hasLength(1));

    final revokeAll = find.byKey(
      const ValueKey('direct-mcp-remembered-revoke-all'),
    );
    await tester.ensureVisible(revokeAll);
    await tester.tap(revokeAll);
    await tester.pumpAndSettle();
    expect((await store.load()).single.rememberedApprovals, isEmpty);
    expect(find.text('Always allowed tools'), findsNothing);
  });

  testWidgets('Save strips credentials when path transfer is declined', (
    tester,
  ) async {
    final store = _managementStore();
    final server = DirectMcpServer(
      id: 'transfer-ui',
      name: 'Transfer UI',
      endpoint: 'http://127.0.0.1:1/mcp',
      authMode: DirectMcpAuthMode.bearer,
      bearerToken: 'bearer-secret',
      allowInsecureCredentials: true,
      customHeaders: const {'X-Tenant': 'tenant-secret'},
    );
    await store.upsert(server);
    final coordinator = DirectMcpOAuthCoordinator(store: store);
    addTearDown(coordinator.close);
    await _pumpOAuthEditor(tester, store, coordinator, server.id);
    await tester.enterText(
      find.byKey(const ValueKey('direct-mcp-endpoint')),
      'http://127.0.0.1:1/other-mcp',
    );
    final save = find.byKey(const ValueKey('direct-mcp-save'));
    tester.widget<ConduitButton>(save).onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('Use credentials with new server?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final persisted = (await store.load()).single;
    expect(persisted.endpoint, 'http://127.0.0.1:1/other-mcp');
    expect(persisted.authMode, DirectMcpAuthMode.none);
    expect(persisted.bearerToken, isNull);
    expect(persisted.customHeaders, isEmpty);
    expect(persisted.requestHeaders, isEmpty);
  });

  testWidgets('OAuth editor adopts a token-only secure-store reload', (
    tester,
  ) async {
    final store = _managementStore();
    final server = await _saveManagementOAuthServer(
      store,
      Uri.parse('https://resource.example/mcp'),
    );
    final coordinator = DirectMcpOAuthCoordinator(store: store);
    addTearDown(coordinator.close);
    final container = ProviderContainer(
      overrides: [
        directMcpServerStoreProvider.overrideWithValue(store),
        directMcpOAuthCoordinatorProvider.overrideWithValue(coordinator),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectMcpServerEditorPage(serverId: server.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connect in browser'), findsOneWidget);

    await store.upsert(
      server.copyWith(oauthTokens: _managementOAuthTokens(server.endpoint)),
      expectedPrevious: server,
      oauthFlowCompletedForExactMutation: true,
    );
    await container.read(directMcpServersProvider.notifier).reload();
    await tester.pumpAndSettle();

    expect(find.text('Reconnect in browser'), findsOneWidget);
    expect(find.textContaining('auth.example'), findsOneWidget);
    expect(find.textContaining('access-ui-secret'), findsNothing);
    expect(find.textContaining('refresh-ui-secret'), findsNothing);
  });

  testWidgets('OAuth editor restores and cancels a pending browser flow', (
    tester,
  ) async {
    final store = _managementStore();
    final saved = await _saveManagementOAuthServer(
      store,
      Uri.parse('https://resource.example/mcp'),
    );
    final server = (await store.upsert(
      saved.copyWith(
        rememberedApprovals: [_managementApproval('a', 'lookup', 'Lookup')],
      ),
      expectedPrevious: saved,
    )).single;
    final client = _BlockedHttpClient();
    final coordinator = DirectMcpOAuthCoordinator(
      store: store,
      client: client,
      requestTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(coordinator.close);
    await _pumpOAuthEditor(
      tester,
      store,
      coordinator,
      server.id,
      editorKey: const ValueKey('first-editor'),
    );

    final connect = find.byKey(const ValueKey('direct-mcp-oauth-connect'));
    await tester.ensureVisible(connect);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect in browser'));
    await tester.pump();
    expect(find.text('Cancel'), findsOneWidget);
    expect(coordinator.isPending(server.id), isTrue);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('direct-mcp-endpoint')))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Revoke'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('direct-mcp-remembered-revoke-all')),
          )
          .onPressed,
      isNull,
    );

    await _pumpOAuthEditor(
      tester,
      store,
      coordinator,
      server.id,
      editorKey: const ValueKey('remounted-editor'),
    );
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('direct-mcp-oauth-connect')));
    for (
      var attempt = 0;
      attempt < 100 && coordinator.isPending(server.id);
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(coordinator.isPending(server.id), isFalse);
    client.release();
    await tester.pumpAndSettle();

    expect((await store.load()).single.oauthTokens, isNull);
  });

  testWidgets('OAuth cancel during save never starts a browser flow', (
    tester,
  ) async {
    final storage = _BlockingMcpSecureStorage();
    final store = DirectMcpServerStore(
      SecureCredentialStorage(instance: storage),
    );
    final server = await _saveManagementOAuthServer(
      store,
      Uri.parse('https://resource.example/mcp'),
    );
    final client = _BlockedHttpClient();
    final coordinator = DirectMcpOAuthCoordinator(store: store, client: client);
    addTearDown(coordinator.close);
    await _pumpOAuthEditor(tester, store, coordinator, server.id);
    storage.blockNextWrite();

    await tester.tap(find.byKey(const ValueKey('direct-mcp-oauth-connect')));
    await storage.writeStarted.future;
    await tester.pump();
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('direct-mcp-oauth-connect')));
    await tester.pump();
    storage.releaseWrite();
    await tester.pumpAndSettle();

    expect(client.sendCount, 0);
    expect(coordinator.isPending(server.id), isFalse);
    expect(find.text('Cancel'), findsNothing);
  });
}

DirectMcpServerStore _managementStore() => DirectMcpServerStore(
  SecureCredentialStorage(instance: const FlutterSecureStorage()),
);

Future<DirectMcpServer> _saveManagementOAuthServer(
  DirectMcpServerStore store,
  Uri endpoint, {
  bool connected = false,
}) async {
  final server = DirectMcpServer(
    id: 'oauth-ui',
    name: 'OAuth UI',
    endpoint: endpoint.toString(),
    authMode: DirectMcpAuthMode.oauth,
    oauthTokens: connected ? _managementOAuthTokens(endpoint.toString()) : null,
  );
  await store.upsert(server);
  return server;
}

DirectMcpOAuthTokens _managementOAuthTokens(String resource) =>
    DirectMcpOAuthTokens(
      accessToken: 'access-ui-secret',
      refreshToken: 'refresh-ui-secret',
      grantedScope: 'tools.read',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      authorizationServerIssuer: 'https://auth.example/issuer',
      resource: resource,
      clientId: 'public-ui-client',
      tokenEndpoint: 'https://auth.example/token',
    );

DirectMcpRememberedApproval _managementApproval(
  String seed,
  String remoteName,
  String displayName,
) => DirectMcpRememberedApproval(
  digest: seed * 64,
  remoteToolName: remoteName,
  displayName: displayName,
  createdAt: DateTime.utc(2026),
);

Future<void> _pumpOAuthEditor(
  WidgetTester tester,
  DirectMcpServerStore store,
  DirectMcpOAuthCoordinator coordinator,
  String serverId, {
  Key? editorKey,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        directMcpServerStoreProvider.overrideWithValue(store),
        directMcpOAuthCoordinatorProvider.overrideWithValue(coordinator),
      ],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DirectMcpServerEditorPage(key: editorKey, serverId: serverId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _BlockedHttpClient extends http.BaseClient {
  final Completer<http.StreamedResponse> _response = Completer();
  bool _released = false;
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sendCount++;
    if (_released) {
      return Future.value(http.StreamedResponse(const Stream.empty(), 404));
    }
    return _response.future;
  }

  void release() {
    if (_released) return;
    _released = true;
    _response.complete(http.StreamedResponse(const Stream.empty(), 404));
  }

  @override
  void close() => release();
}

final class _BlockingMcpSecureStorage implements FlutterSecureStorage {
  String? _source;
  bool _block = false;
  final writeStarted = Completer<void>();
  final _writeRelease = Completer<void>();

  void blockNextWrite() => _block = true;
  void releaseWrite() => _writeRelease.complete();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) return Future<String?>.value(_source);
    if (invocation.memberName == #delete) {
      _source = null;
      return Future<void>.value();
    }
    if (invocation.memberName == #write) {
      final value = invocation.namedArguments[#value] as String?;
      if (!_block) {
        _source = value;
        return Future<void>.value();
      }
      _block = false;
      writeStarted.complete();
      return _writeRelease.future.then<void>((_) => _source = value);
    }
    return super.noSuchMethod(invocation);
  }
}
