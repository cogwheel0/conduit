import 'dart:async';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/models/openwebui_direct_connection.dart';
import 'package:conduit/features/direct_connections/services/openwebui_direct_connection_store.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_page.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/features/profile/widgets/adaptive_segmented_selector.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/model_list_tile.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  group('direct connection form parsing', () {
    test('parses string custom headers', () {
      check(
        parseDirectCustomHeaders(
          '{"X-Organization":"team-a","X-Region":"local"}',
        ),
      ).deepEquals({'X-Organization': 'team-a', 'X-Region': 'local'});
    });

    test('rejects non-string custom header values', () {
      check(
        () => parseDirectCustomHeaders('{"X-Retry": 2}'),
      ).throws<FormatException>();
    });

    test('normalizes surrounding custom header name whitespace', () {
      check(
        parseDirectCustomHeaders('{" X-Organization ":"team-a"}'),
      ).deepEquals({'X-Organization': 'team-a'});
    });

    test('deduplicates manual model ids while preserving order', () {
      check(
        parseDirectManualModelIds('model-a\n model-b,model-a\n'),
      ).deepEquals(['model-a', 'model-b']);
    });

    test('deduplicates model tags while preserving order', () {
      check(
        parseDirectModelTags('local, private\nlocal'),
      ).deepEquals(['local', 'private']);
    });

    test('normalizes whitespace and trailing slash', () {
      check(
        normalizeDirectBaseUrl(' https://provider.example/v1/ '),
      ).equals('https://provider.example/v1');
      check(
        normalizeDirectBaseUrl('http://localhost:11434/'),
      ).equals('http://localhost:11434/');
    });

    test('preserves only an untouched existing keyless server bearer', () {
      check(
        requiresDirectApiKey(
          authentication: DirectAuthenticationMode.bearer,
          isOpenWebUi: true,
          isNew: false,
          savedOpenWebUiAuthType: 'bearer',
          apiKeyDirty: false,
          originChanged: false,
        ),
      ).isFalse();
      check(
        requiresDirectApiKey(
          authentication: DirectAuthenticationMode.bearer,
          isOpenWebUi: true,
          isNew: false,
          savedOpenWebUiAuthType: 'none',
          apiKeyDirty: true,
          originChanged: false,
        ),
      ).isTrue();
      check(
        requiresDirectApiKey(
          authentication: DirectAuthenticationMode.bearer,
          isOpenWebUi: true,
          isNew: false,
          savedOpenWebUiAuthType: 'bearer',
          apiKeyDirty: false,
          originChanged: true,
        ),
      ).isTrue();
    });

    test('an edited origin cannot inherit TLS material for a probe', () {
      final previous = DirectConnectionProfile(
        id: 'secure-profile',
        name: 'Secure provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://old.example/v1',
        apiKey: 'old-key',
        allowSelfSignedCertificates: true,
        mtlsCertificateChainPem: 'CERT',
        mtlsPrivateKeyPem: 'KEY',
        mtlsPrivateKeyPassword: 'password',
      );
      final draft = previous.copyWith(
        baseUrl: 'https://new.example/v1',
        apiKey: 'new-key',
      );

      final safe = secureDirectDraftForEditedOrigin(
        previous: previous,
        draft: draft,
        secretsConfirmedForNewOrigin: true,
      );

      check(safe.apiKey).equals('new-key');
      check(safe.allowSelfSignedCertificates).isFalse();
      check(safe.mtlsCertificateChainPem).isNull();
      check(safe.mtlsPrivateKeyPem).isNull();
      check(safe.mtlsPrivateKeyPassword).isNull();
    });

    test(
      'origin edits require explicit confirmation for the whole header map',
      () {
        final previous = DirectConnectionProfile(
          id: 'secure-profile',
          name: 'Secure provider',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://old.example/v1',
          customHeaders: const {'X-Api-Key': 'old-key', 'X-Tenant': 'tenant-a'},
        );
        final whitespaceOnly = previous.copyWith(
          baseUrl: 'https://new.example/v1',
          customHeaders: parseDirectCustomHeaders(
            '{  "X-Api-Key" : "old-key", "X-Tenant": "tenant-a" }',
          ),
        );
        final oneHeaderEdited = whitespaceOnly.copyWith(
          customHeaders: const {'X-Api-Key': 'new-key', 'X-Tenant': 'tenant-a'},
        );

        check(
          requiresDirectOriginCredentialConfirmation(
            previous: previous,
            draft: whitespaceOnly,
          ),
        ).isTrue();
        check(
          requiresDirectOriginCredentialConfirmation(
            previous: previous,
            draft: oneHeaderEdited,
          ),
        ).isTrue();
        check(
          requiresDirectOriginCredentialConfirmation(
            previous: previous,
            draft: oneHeaderEdited.copyWith(customHeaders: const {}),
          ),
        ).isFalse();
      },
    );
  });

  test('direct model badge uses its configured profile name', () {
    const model = Model(
      id: 'direct:home:encoded',
      name: 'Local model',
      metadata: {'backend': 'direct', 'profileName': 'Home Ollama'},
    );
    check(directModelSourceLabel(model)).equals('Home Ollama');
    check(
      directModelSourceLabel(const Model(id: 'server', name: 'Server')),
    ).isNull();
  });

  testWidgets('direct source and model tags deduplicate case-insensitively', (
    tester,
  ) async {
    const model = Model(
      id: 'direct:work:model',
      name: 'Local model',
      metadata: {
        'backend': 'direct',
        'profileName': 'Work',
        'tags': ['work'],
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ModelListTile(model: model, isSelected: false, onTap: _noop),
        ),
      ),
    );

    expect(find.byType(ModelTagChip), findsOneWidget);
    expect(find.text('WORK'), findsOneWidget);
  });

  testWidgets('loaded model badge is visible without changing selection', (
    tester,
  ) async {
    const model = Model(id: 'direct:home:model', name: 'Local model');

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ModelListTile(
            model: model,
            isSelected: false,
            isLoaded: true,
            onTap: _noop,
          ),
        ),
      ),
    );

    check(find.byType(ModelLoadedChip).evaluate()).length.equals(1);
    check(find.text('Loaded').evaluate()).length.equals(1);
    check(find.byIcon(Icons.check).evaluate()).isEmpty();
  });

  testWidgets('management content shows profiles and history policy', (
    tester,
  ) async {
    var syncEnabled = true;
    final profiles = [
      DirectConnectionProfile(
        id: 'home',
        name: 'Home Ollama',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://192.168.1.5:11434',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: profiles,
            syncWithOpenWebUi: syncEnabled,
            isOnboarding: false,
            showHistorySync: true,
            onSyncChanged: (value) => syncEnabled = value,
            onAdd: () {},
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Direct Connections'), findsOneWidget);
    expect(find.text('Open WebUI history'), findsOneWidget);
    expect(find.text('Home Ollama'), findsOneWidget);
    expect(find.textContaining('http://192.168.1.5:11434'), findsOneWidget);
    expect(find.text('Add connection'), findsOneWidget);

    await tester.tap(find.byType(AdaptiveSwitch));
    await tester.pump();
    check(syncEnabled).isFalse();
  });

  testWidgets('management labels server and device connections separately', (
    tester,
  ) async {
    final local = DirectConnectionProfile(
      id: 'device-profile',
      name: 'Device provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://device.example/v1',
    );
    final snapshot =
        OpenWebUiDirectConnectionsCodec(
          serverId: 'server',
          accountId: 'account',
        ).decode({
          'ui': {
            'directConnections': {
              'OPENAI_API_BASE_URLS': ['https://server.example/v1'],
              'OPENAI_API_KEYS': ['server-key'],
              'OPENAI_API_CONFIGS': {
                '0': {'auth_type': 'bearer'},
              },
            },
          },
        });
    String? editedLocal;
    String? editedServer;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: [local],
            openWebUiConnections: AsyncData(snapshot),
            showOpenWebUi: true,
            syncWithOpenWebUi: true,
            isOnboarding: false,
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (id) => editedLocal = id,
            onAddOpenWebUi: () {},
            onEditOpenWebUi: (id) => editedServer = id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Open WebUI server'), findsOneWidget);
    expect(find.text('On this device'), findsOneWidget);
    expect(find.text('server.example · 1'), findsOneWidget);
    expect(find.text('Device provider'), findsOneWidget);
    expect(find.text('Open WebUI'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);

    await tester.tap(find.text('server.example · 1'));
    await tester.ensureVisible(find.text('Device provider'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Device provider'));
    expect(editedServer, snapshot.records.single.profile.id);
    expect(editedLocal, local.id);
  });

  testWidgets('management hides Open WebUI history without a server', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: const [],
            syncWithOpenWebUi: true,
            isOnboarding: false,
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Open WebUI history'), findsNothing);
  });

  testWidgets('separate connection groups fit a 320px-wide layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final snapshot =
        OpenWebUiDirectConnectionsCodec(
          serverId: 'server',
          accountId: 'account',
        ).decode({
          'ui': {
            'directConnections': {
              'OPENAI_API_BASE_URLS': ['https://server.example/v1'],
              'OPENAI_API_KEYS': ['key'],
              'OPENAI_API_CONFIGS': {
                '0': {'auth_type': 'bearer'},
              },
            },
          },
        });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: [
              DirectConnectionProfile(
                id: 'local',
                name: 'Local provider',
                adapterKey: kOpenAiCompatibleAdapterKey,
                baseUrl: 'https://local.example/v1',
              ),
            ],
            openWebUiConnections: AsyncData(snapshot),
            showOpenWebUi: true,
            syncWithOpenWebUi: true,
            isOnboarding: false,
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
            onAddOpenWebUi: () {},
            onEditOpenWebUi: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Open WebUI server'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('On this device'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('On this device'), findsOneWidget);
  });

  testWidgets('server reload failure is visible after an empty snapshot', (
    tester,
  ) async {
    final emptySnapshot = OpenWebUiDirectConnectionsCodec(
      serverId: 'server',
      accountId: 'account',
    ).decode({'ui': <String, Object?>{}});
    final controller = _RefreshFailureOpenWebUiConnections(emptySnapshot);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiDirectConnectionsProvider.overrideWith(() => controller),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) => DirectConnectionsContent(
              profiles: const [],
              openWebUiConnections: ref.watch(
                openWebUiDirectConnectionsProvider,
              ),
              showOpenWebUi: true,
              syncWithOpenWebUi: true,
              isOnboarding: false,
              onSyncChanged: (_) {},
              onAdd: () {},
              onEdit: (_) {},
              onAddOpenWebUi: () {},
              onEditOpenWebUi: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.failRefresh();
    await tester.pump();

    expect(find.text('No server connections yet'), findsOneWidget);
    expect(
      find.text('Could not sync connections from Open WebUI.'),
      findsOneWidget,
    );
  });

  testWidgets('management refreshes server connections on entry and resume', (
    tester,
  ) async {
    final snapshot = OpenWebUiDirectConnectionsCodec(
      serverId: 'server',
      accountId: 'account',
    ).decode({'ui': <String, Object?>{}});
    final remoteController = _TrackingReloadOpenWebUiConnections(snapshot);
    final availableStore = OpenWebUiDirectConnectionStore(
      serverId: 'server',
      accountId: 'account',
      readSettings: () async => const <String, dynamic>{},
      writeSettings: (_) async {},
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => _StaticDirectProfiles(const []),
          ),
          directHistoryPolicyProvider.overrideWith(_StaticHistoryPolicy.new),
          openWebUiDirectConnectionStoreProvider.overrideWithValue(
            availableStore,
          ),
          openWebUiDirectConnectionsProvider.overrideWith(
            () => remoteController,
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(remoteController.reloadCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(remoteController.reloadCount, 2);
  });

  testWidgets('server editor reuses the form with a synced-source label', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final snapshot =
        OpenWebUiDirectConnectionsCodec(
          serverId: 'server',
          accountId: 'account',
        ).decode({
          'ui': {
            'directConnections': {
              'OPENAI_API_BASE_URLS': ['https://server.example/v1'],
              'OPENAI_API_KEYS': ['server-key'],
              'OPENAI_API_CONFIGS': {
                '0': {'auth_type': 'bearer'},
              },
            },
          },
        });
    final record = snapshot.records.single;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiDirectConnectionsProvider.overrideWith(
            () => _StaticOpenWebUiConnections(snapshot),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionEditorPage(
            profileId: record.profile.id,
            isOpenWebUi: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Open WebUI'), findsOneWidget);
    expect(
      find.text('Changes are saved to your Open WebUI account.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('direct-connection-name-field')),
      findsNothing,
    );
    expect(find.text('Ollama'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('direct-base-url-field')),
      findsOneWidget,
    );
  });

  testWidgets('a new server draft is revoked when the account changes', (
    tester,
  ) async {
    final accountA = OpenWebUiDirectConnectionsCodec(
      serverId: 'server',
      accountId: 'account-a',
    ).decode({'ui': <String, Object?>{}});
    final accountB = OpenWebUiDirectConnectionsCodec(
      serverId: 'server',
      accountId: 'account-b',
    ).decode({'ui': <String, Object?>{}});
    final controller = _MutableOpenWebUiConnections(accountA);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiDirectConnectionsProvider.overrideWith(() => controller),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(
            profileId: 'new',
            isOpenWebUi: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('direct-base-url-field')),
      'https://account-a.example/v1',
    );

    controller.setSnapshot(accountB);
    await tester.pumpAndSettle();

    expect(
      find.text('Open WebUI connections are unavailable.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('direct-base-url-field')),
      findsNothing,
    );
  });

  testWidgets(
    'server probe stops when the account changes during confirmation',
    (tester) async {
      final accountA =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account-a',
          ).decode({
            'ui': {
              'directConnections': {
                'OPENAI_API_BASE_URLS': ['https://old.example/v1'],
                'OPENAI_API_KEYS': ['old-secret'],
                'OPENAI_API_CONFIGS': {
                  '0': {'auth_type': 'bearer'},
                },
              },
            },
          });
      final accountB = OpenWebUiDirectConnectionsCodec(
        serverId: 'server',
        accountId: 'account-b',
      ).decode({'ui': <String, Object?>{}});
      final remoteController = _MutableOpenWebUiConnections(accountA);
      final localController = _StaticDirectProfiles(const []);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            directConnectionProfilesProvider.overrideWith(
              () => localController,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              profileId: accountA.records.single.profile.id,
              isOpenWebUi: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('direct-base-url-field')),
        'https://new.example/v1',
      );
      await tester.scrollUntilVisible(
        find.byKey(
          const ValueKey<String>('direct-api-key-field'),
          skipOffstage: false,
        ),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('direct-api-key-field')),
        'new-secret',
      );
      await tester.scrollUntilVisible(
        find.text('Test connection'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Test connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Use credentials with new server?'), findsOneWidget);
      remoteController.setSnapshot(accountB);
      await tester.pump();
      await tester.tap(find.text('Use credentials'));
      await tester.pumpAndSettle();

      expect(localController.probeCalls, 0);
    },
  );

  testWidgets(
    'server save reports unavailable when auth changes during confirmation',
    (tester) async {
      final snapshot =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
          ).decode({
            'ui': {
              'directConnections': {
                'OPENAI_API_BASE_URLS': ['https://old.example/v1'],
                'OPENAI_API_KEYS': ['old-secret'],
                'OPENAI_API_CONFIGS': {
                  '0': {'auth_type': 'bearer'},
                },
              },
            },
          });
      final remoteController = _MutableOpenWebUiConnections(snapshot);
      final epochSource = NotifierProvider<_MutableAuthEpoch, Object>(
        _MutableAuthEpoch.new,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(epochSource),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              profileId: snapshot.records.single.profile.id,
              isOpenWebUi: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DirectConnectionEditorPage)),
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('direct-base-url-field')),
        'https://new.example/v1',
      );
      await tester.scrollUntilVisible(
        find.byKey(
          const ValueKey<String>('direct-api-key-field'),
          skipOffstage: false,
        ),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('direct-api-key-field')),
        'new-secret',
      );
      final save = tester.widget<ConduitButton>(
        find.byWidgetPredicate(
          (widget) => widget is ConduitButton && widget.text == 'Save',
          skipOffstage: false,
        ),
      );
      save.onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Use credentials with new server?'), findsOneWidget);
      container.read(epochSource.notifier).rotate();
      await tester.tap(find.text('Use credentials'));
      await tester.pumpAndSettle();

      expect(remoteController.updateCalls, 0);
      expect(
        find.text('Open WebUI connections are unavailable.'),
        findsOneWidget,
      );
      expect(find.text('Could not save this connection.'), findsNothing);
    },
  );

  testWidgets(
    'server editor preserves its draft and submits a refreshed reindexed record',
    (tester) async {
      final codec = OpenWebUiDirectConnectionsCodec(
        serverId: 'server',
        accountId: 'account',
      );
      final initial = codec.decode({
        'ui': {
          'directConnections': {
            'OPENAI_API_BASE_URLS': [
              'https://earlier.example/v1',
              'https://target.example/v1',
            ],
            'OPENAI_API_KEYS': ['earlier-secret', 'target-secret'],
            'OPENAI_API_CONFIGS': {
              '0': {'auth_type': 'bearer'},
              '1': {'auth_type': 'bearer'},
            },
          },
        },
      });
      final reindexed = codec.decode({
        'ui': {
          'directConnections': {
            'OPENAI_API_BASE_URLS': ['https://target.example/v1'],
            'OPENAI_API_KEYS': ['target-secret'],
            'OPENAI_API_CONFIGS': {
              '0': {'auth_type': 'bearer'},
            },
          },
        },
      });
      final initialRecord = initial.records[1];
      final refreshedRecord = reindexed.records.single;
      expect(refreshedRecord.profile.id, initialRecord.profile.id);
      expect(refreshedRecord.index, 0);
      expect(refreshedRecord.revision, isNot(initialRecord.revision));

      final updateStarted = Completer<void>();
      final releaseUpdate = Completer<void>();
      addTearDown(() {
        if (!releaseUpdate.isCompleted) releaseUpdate.complete();
      });
      final remoteController = _MutableOpenWebUiConnections(initial)
        ..updateHandler = () async {
          if (!updateStarted.isCompleted) updateStarted.complete();
          await releaseUpdate.future;
        };

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              profileId: initialRecord.profile.id,
              isOpenWebUi: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final apiVersionField = find.byKey(
        const ValueKey<String>('direct-api-version-field'),
      );
      await tester.scrollUntilVisible(
        apiVersionField,
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(apiVersionField, '2026-07-15');

      remoteController.setSnapshot(reindexed);
      await tester.pumpAndSettle();

      expect(
        tester.widget<AccessibleFormField>(apiVersionField).controller!.text,
        '2026-07-15',
      );
      final save = tester.widget<ConduitButton>(
        find.byWidgetPredicate(
          (widget) => widget is ConduitButton && widget.text == 'Save',
          skipOffstage: false,
        ),
      );
      save.onPressed!();
      await tester.pump();
      await updateStarted.future.timeout(const Duration(seconds: 1));

      expect(remoteController.updateCalls, 1);
      expect(remoteController.lastUpdatedRecord?.index, refreshedRecord.index);
      expect(
        remoteController.lastUpdatedRecord?.revision,
        refreshedRecord.revision,
      );
      expect(
        remoteController.lastUpdatedRecord?.profile.id,
        refreshedRecord.profile.id,
      );
      expect(remoteController.lastUpdatedProfile?.apiVersion, '2026-07-15');

      releaseUpdate.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'server editor retains its stale CAS base for a same-id content edit',
    (tester) async {
      final codec = OpenWebUiDirectConnectionsCodec(
        serverId: 'server',
        accountId: 'account',
      );
      final initial = codec.decode({
        'ui': {
          'directConnections': {
            'OPENAI_API_BASE_URLS': ['https://target.example/v1'],
            'OPENAI_API_KEYS': ['target-secret'],
            'OPENAI_API_CONFIGS': {
              '0': {
                'auth_type': 'bearer',
                'enable': true,
                'tags': [
                  {'name': 'initial'},
                ],
              },
            },
          },
        },
      });
      final editedElsewhere = codec.decode({
        'ui': {
          'directConnections': {
            'OPENAI_API_BASE_URLS': ['https://target.example/v1'],
            'OPENAI_API_KEYS': ['target-secret'],
            'OPENAI_API_CONFIGS': {
              '0': {
                'auth_type': 'bearer',
                'enable': true,
                'tags': [
                  {'name': 'remote-edit'},
                ],
              },
            },
          },
        },
      });
      final initialRecord = initial.records.single;
      final remoteRecord = editedElsewhere.records.single;
      expect(remoteRecord.profile.id, initialRecord.profile.id);
      expect(
        remoteRecord.contentRevision,
        isNot(initialRecord.contentRevision),
      );

      final remoteController = _MutableOpenWebUiConnections(initial);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              profileId: initialRecord.profile.id,
              isOpenWebUi: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final apiVersionField = find.byKey(
        const ValueKey<String>('direct-api-version-field'),
      );
      await tester.scrollUntilVisible(
        apiVersionField,
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(apiVersionField, 'draft-version');

      remoteController.setSnapshot(editedElsewhere);
      await tester.pumpAndSettle();

      final save = tester.widget<ConduitButton>(
        find.byWidgetPredicate(
          (widget) => widget is ConduitButton && widget.text == 'Save',
          skipOffstage: false,
        ),
      );
      save.onPressed!();
      await tester.pumpAndSettle();

      expect(remoteController.updateCalls, 1);
      expect(
        remoteController.lastUpdatedRecord?.revision,
        initialRecord.revision,
      );
      expect(
        remoteController.lastUpdatedRecord?.contentRevision,
        initialRecord.contentRevision,
      );
    },
  );

  testWidgets(
    'server conflict completing after auth rotation reports unavailable',
    (tester) async {
      final snapshot =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
          ).decode({
            'ui': {
              'directConnections': {
                'OPENAI_API_BASE_URLS': ['https://provider.example/v1'],
                'OPENAI_API_KEYS': ['provider-secret'],
                'OPENAI_API_CONFIGS': {
                  '0': {'auth_type': 'bearer'},
                },
              },
            },
          });
      final updateStarted = Completer<void>();
      final releaseUpdate = Completer<void>();
      addTearDown(() {
        if (!releaseUpdate.isCompleted) releaseUpdate.complete();
      });
      final remoteController = _MutableOpenWebUiConnections(snapshot)
        ..updateHandler = () async {
          if (!updateStarted.isCompleted) updateStarted.complete();
          await releaseUpdate.future;
          throw OpenWebUiDirectConnectionConflictException(snapshot);
        };
      final epochSource = NotifierProvider<_MutableAuthEpoch, Object>(
        _MutableAuthEpoch.new,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(epochSource),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              profileId: snapshot.records.single.profile.id,
              isOpenWebUi: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DirectConnectionEditorPage)),
      );
      final apiVersionField = find.byKey(
        const ValueKey<String>('direct-api-version-field'),
      );
      await tester.scrollUntilVisible(
        apiVersionField,
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(apiVersionField, '2026-07-15');
      final save = tester.widget<ConduitButton>(
        find.byWidgetPredicate(
          (widget) => widget is ConduitButton && widget.text == 'Save',
          skipOffstage: false,
        ),
      );
      save.onPressed!();
      await tester.pump();
      await updateStarted.future.timeout(const Duration(seconds: 1));

      container.read(epochSource.notifier).rotate();
      releaseUpdate.complete();
      await tester.pumpAndSettle();

      expect(remoteController.updateCalls, 1);
      expect(
        find.text('Open WebUI connections are unavailable.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'This connection changed elsewhere. Reopen it before saving.',
        ),
        findsNothing,
      );
      expect(find.text('Could not save this connection.'), findsNothing);
    },
  );

  testWidgets('server delete stops when auth changes during profile lookup', (
    tester,
  ) async {
    final snapshot =
        OpenWebUiDirectConnectionsCodec(
          serverId: 'server',
          accountId: 'account',
        ).decode({
          'ui': {
            'directConnections': {
              'OPENAI_API_BASE_URLS': ['https://delete.example/v1'],
              'OPENAI_API_KEYS': ['delete-secret'],
              'OPENAI_API_CONFIGS': {
                '0': {'auth_type': 'bearer'},
              },
            },
          },
        });
    final backup = DirectConnectionProfile(
      id: 'backup',
      name: 'Backup',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://backup.example/v1',
    );
    final profilesReadStarted = Completer<void>();
    final releaseProfiles = Completer<void>();
    addTearDown(() {
      if (!releaseProfiles.isCompleted) releaseProfiles.complete();
    });
    final remoteController = _MutableOpenWebUiConnections(snapshot);
    final epochSource = NotifierProvider<_MutableAuthEpoch, Object>(
      _MutableAuthEpoch.new,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiDirectConnectionsProvider.overrideWith(
            () => remoteController,
          ),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(epochSource),
          ),
          effectiveDirectConnectionProfilesFutureProvider.overrideWith((
            ref,
          ) async {
            if (!profilesReadStarted.isCompleted) {
              profilesReadStarted.complete();
            }
            await releaseProfiles.future;
            return [snapshot.records.single.profile, backup];
          }),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionEditorPage(
            profileId: snapshot.records.single.profile.id,
            isOpenWebUi: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectConnectionEditorPage)),
    );
    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await profilesReadStarted.future.timeout(const Duration(seconds: 1));

    container.read(epochSource.notifier).rotate();
    releaseProfiles.complete();
    await tester.pumpAndSettle();

    expect(remoteController.deleteCalls, 0);
  });

  testWidgets(
    'server delete restores preference and reports changed ownership',
    (tester) async {
      final snapshot =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
          ).decode({
            'ui': {
              'directConnections': {
                'OPENAI_API_BASE_URLS': ['https://delete.example/v1'],
                'OPENAI_API_KEYS': ['delete-secret'],
                'OPENAI_API_CONFIGS': {
                  '0': {'auth_type': 'bearer'},
                },
              },
            },
          });
      final remoteController = _MutableOpenWebUiConnections(snapshot);
      final epochSource = NotifierProvider<_MutableAuthEpoch, Object>(
        _MutableAuthEpoch.new,
      );
      final backendController = _BlockingPreferredBackendController();
      addTearDown(backendController.release);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(epochSource),
            ),
            effectiveDirectConnectionProfilesFutureProvider.overrideWith(
              (ref) async => [snapshot.records.single.profile],
            ),
            preferredBackendProvider.overrideWith(() => backendController),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              profileId: snapshot.records.single.profile.id,
              isOpenWebUi: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DirectConnectionEditorPage)),
      );
      await tester.scrollUntilVisible(
        find.text('Delete connection'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Delete connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await backendController.unsetStarted.future.timeout(
        const Duration(seconds: 1),
      );

      container.read(epochSource.notifier).rotate();
      backendController.release();
      await tester.pumpAndSettle();

      expect(remoteController.deleteCalls, 0);
      expect(backendController.writes, [
        PreferredBackend.unset,
        PreferredBackend.direct,
      ]);
      expect(container.read(preferredBackendProvider), PreferredBackend.direct);
      expect(
        find.text('Open WebUI connections are unavailable.'),
        findsOneWidget,
      );
      expect(find.text('Could not delete this connection.'), findsNothing);
    },
  );

  testWidgets(
    'committed server delete does not restore preference after ownership change',
    (tester) async {
      final snapshot =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
          ).decode({
            'ui': {
              'directConnections': {
                'OPENAI_API_BASE_URLS': ['https://delete.example/v1'],
                'OPENAI_API_KEYS': ['delete-secret'],
                'OPENAI_API_CONFIGS': {
                  '0': {'auth_type': 'bearer'},
                },
              },
            },
          });
      final deleteStarted = Completer<void>();
      final releaseDelete = Completer<void>();
      addTearDown(() {
        if (!releaseDelete.isCompleted) releaseDelete.complete();
      });
      final remoteController = _MutableOpenWebUiConnections(snapshot)
        ..deleteHandler = () async {
          if (!deleteStarted.isCompleted) deleteStarted.complete();
          await releaseDelete.future;
        };
      final epochSource = NotifierProvider<_MutableAuthEpoch, Object>(
        _MutableAuthEpoch.new,
      );
      final backendController = _TrackingPreferredBackendController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(epochSource),
            ),
            effectiveDirectConnectionProfilesFutureProvider.overrideWith(
              (ref) async => [snapshot.records.single.profile],
            ),
            preferredBackendProvider.overrideWith(() => backendController),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              profileId: snapshot.records.single.profile.id,
              isOpenWebUi: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DirectConnectionEditorPage)),
      );
      await tester.scrollUntilVisible(
        find.text('Delete connection'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Delete connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await deleteStarted.future.timeout(const Duration(seconds: 1));

      expect(container.read(preferredBackendProvider), PreferredBackend.unset);
      container.read(epochSource.notifier).rotate();
      releaseDelete.complete();
      await tester.pumpAndSettle();

      expect(remoteController.deleteCalls, 1);
      expect(backendController.writes, [PreferredBackend.unset]);
      expect(container.read(preferredBackendProvider), PreferredBackend.unset);
      expect(
        find.text('Open WebUI connections are unavailable.'),
        findsOneWidget,
      );
      expect(find.text('Could not delete this connection.'), findsNothing);
    },
  );

  testWidgets(
    'commit-uncertain server delete leaves the direct preference cleared',
    (tester) async {
      final snapshot =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
          ).decode({
            'ui': {
              'directConnections': {
                'OPENAI_API_BASE_URLS': ['https://delete.example/v1'],
                'OPENAI_API_KEYS': ['delete-secret'],
                'OPENAI_API_CONFIGS': {
                  '0': {'auth_type': 'bearer'},
                },
              },
            },
          });
      final remoteController = _MutableOpenWebUiConnections(snapshot)
        ..deleteHandler = () async {
          throw const OpenWebUiDirectConnectionCommitUncertainException();
        };
      final backendController = _TrackingPreferredBackendController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            effectiveDirectConnectionProfilesFutureProvider.overrideWith(
              (ref) async => [snapshot.records.single.profile],
            ),
            preferredBackendProvider.overrideWith(() => backendController),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              profileId: snapshot.records.single.profile.id,
              isOpenWebUi: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DirectConnectionEditorPage)),
      );
      await tester.scrollUntilVisible(
        find.text('Delete connection'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Delete connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(remoteController.deleteCalls, 1);
      expect(backendController.writes, [PreferredBackend.unset]);
      expect(container.read(preferredBackendProvider), PreferredBackend.unset);
      expect(find.text('Could not delete this connection.'), findsOneWidget);
    },
  );

  testWidgets('unsupported server auth blocks execution but permits deletion', (
    tester,
  ) async {
    final snapshot =
        OpenWebUiDirectConnectionsCodec(
          serverId: 'server',
          accountId: 'account',
        ).decode({
          'ui': {
            'directConnections': {
              'OPENAI_API_BASE_URLS': ['https://session.example/v1'],
              'OPENAI_API_KEYS': ['must-not-be-forwarded'],
              'OPENAI_API_CONFIGS': {
                '0': {'auth_type': 'session'},
              },
            },
          },
        });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiDirectConnectionsProvider.overrideWith(
            () => _StaticOpenWebUiConnections(snapshot),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionEditorPage(
            profileId: snapshot.records.single.profile.id,
            isOpenWebUi: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );

    final buttons = tester.widgetList<ConduitButton>(
      find.byType(ConduitButton, skipOffstage: false),
    );
    expect(
      buttons.singleWhere((button) => button.text == 'Save').onPressed,
      isNull,
    );
    expect(
      buttons
          .singleWhere((button) => button.text == 'Test connection')
          .onPressed,
      isNull,
    );
    expect(
      buttons
          .singleWhere((button) => button.text == 'Delete connection')
          .onPressed,
      isNotNull,
    );
    expect(find.textContaining('cannot safely use'), findsOneWidget);
  });

  testWidgets('switching a server connection to bearer requires a key', (
    tester,
  ) async {
    final snapshot =
        OpenWebUiDirectConnectionsCodec(
          serverId: 'server',
          accountId: 'account',
        ).decode({
          'ui': {
            'directConnections': {
              'OPENAI_API_BASE_URLS': ['https://none.example/v1'],
              'OPENAI_API_KEYS': [''],
              'OPENAI_API_CONFIGS': {
                '0': {'auth_type': 'none'},
              },
            },
          },
        });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiDirectConnectionsProvider.overrideWith(
            () => _StaticOpenWebUiConnections(snapshot),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionEditorPage(
            profileId: snapshot.records.single.profile.id,
            isOpenWebUi: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('No authentication'),
      500,
      scrollable: find.byType(Scrollable).first,
    );

    final authenticationSelector = tester
        .widget<DropdownButtonFormField<DirectAuthenticationMode>>(
          find.byKey(
            const Key('direct-authentication-selector-openai-compatible'),
          ),
        );
    authenticationSelector.onChanged?.call(DirectAuthenticationMode.bearer);
    await tester.pump();

    final save = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) => widget is ConduitButton && widget.text == 'Save',
        skipOffstage: false,
      ),
    );
    save.onPressed!();
    await tester.pump();

    final keyField = tester.widget<AccessibleFormField>(
      find.byKey(
        const ValueKey<String>('direct-api-key-field'),
        skipOffstage: false,
      ),
    );
    expect(keyField.errorText, 'Enter an API key or choose no authentication.');
  });

  testWidgets('editor restores the OpenAI-family completion API mode', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'lm-studio',
      name: 'LM Studio',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'http://localhost:1234/v1',
      openAiApiMode: DirectOpenAiApiMode.responses,
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(profileId: 'lm-studio'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -420));
    await tester.pumpAndSettle();

    final selector = tester
        .widget<AdaptiveSegmentedSelector<DirectOpenAiApiMode>>(
          find.byKey(const ValueKey<String>('direct-openai-api-mode-selector')),
        );
    expect(selector.value, DirectOpenAiApiMode.responses);
    expect(find.text('Chat Completions'), findsOneWidget);
    expect(find.text('Responses'), findsOneWidget);
  });

  testWidgets('editor rejects a save from a stale profile snapshot', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'shared-profile',
      name: 'Original provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      apiKey: 'original-secret',
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(profileId: 'shared-profile'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectConnectionEditorPage)),
    );

    await container
        .read(directConnectionProfilesProvider.notifier)
        .upsert(
          profile.copyWith(
            name: 'Concurrent provider',
            apiKey: 'concurrent-secret',
          ),
        );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('direct-connection-name-field')),
      'Stale rename',
    );
    await tester.scrollUntilVisible(
      find.text('Save'),
      500,
      scrollable: find.byType(Scrollable).first,
    );

    final save = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) => widget is ConduitButton && widget.text == 'Save',
        skipOffstage: false,
      ),
    );
    save.onPressed!();
    await tester.pumpAndSettle();

    expect(
      find.text('This connection changed elsewhere. Reopen it before saving.'),
      findsAtLeastNWidgets(1),
    );
    final saved = container
        .read(directConnectionProfilesProvider)
        .requireValue
        .single;
    expect(saved.name, 'Concurrent provider');
    expect(saved.apiKey, 'concurrent-secret');
  });

  testWidgets('delete confirmation serializes editor operations', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'home',
      name: 'Home provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      apiKey: 'secret',
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(profileId: 'home'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Delete connection?'), findsOneWidget);
    final save = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) => widget is ConduitButton && widget.text == 'Save',
      ),
    );
    final testConnection = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) => widget is ConduitButton && widget.text == 'Test connection',
      ),
    );
    final delete = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ConduitButton && widget.text == 'Delete connection',
      ),
    );
    expect(save.onPressed, isNull);
    expect(testConnection.onPressed, isNull);
    expect(delete.isLoading, isTrue);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final restoredDelete = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ConduitButton && widget.text == 'Delete connection',
      ),
    );
    expect(restoredDelete.isLoading, isFalse);
    expect(restoredDelete.onPressed, isNotNull);
  });

  testWidgets('delete checks profiles added while confirmation is open', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'home',
      name: 'Home provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      apiKey: 'secret',
    );
    final alternate = DirectConnectionProfile(
      id: 'backup',
      name: 'Backup provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://backup.example/v1',
      apiKey: 'backup-secret',
    );
    final backendController = _TrackingPreferredBackendController();
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });
    final router = GoRouter(
      initialLocation: '/edit',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const SizedBox.shrink(),
          routes: [
            GoRoute(
              path: 'edit',
              builder: (_, _) =>
                  const DirectConnectionEditorPage(profileId: 'home'),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
          preferredBackendProvider.overrideWith(() => backendController),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectConnectionEditorPage)),
    );

    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await container
        .read(directConnectionProfilesProvider.notifier)
        .upsert(alternate);
    await tester.pump();
    expect(
      container.read(directConnectionProfilesProvider).requireValue,
      hasLength(2),
    );

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
      container
          .read(directConnectionProfilesProvider)
          .requireValue
          .map((item) => item.id),
      ['backup'],
    );
    expect(container.read(preferredBackendProvider), PreferredBackend.direct);
    expect(backendController.writes, isEmpty);
  });

  testWidgets('backend preference failure preserves the last direct profile', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'home',
      name: 'Home provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      apiKey: 'secret',
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
          preferredBackendProvider.overrideWith(
            _FailingPreferredBackendController.new,
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(profileId: 'home'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectConnectionEditorPage)),
    );

    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Could not delete this connection.'), findsOneWidget);
    expect(
      container.read(directConnectionProfilesProvider).requireValue.single.id,
      'home',
    );
    expect(container.read(preferredBackendProvider), PreferredBackend.direct);
    final durable = await const FlutterSecureStorage().read(
      key: 'direct_connection_profiles_v1',
    );
    expect(durable, contains('secret'));
  });

  testWidgets(
    'profile write failure restores a pre-cleared direct preference',
    (tester) async {
      final profile = DirectConnectionProfile(
        id: 'home',
        name: 'Home provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://provider.example/v1',
        apiKey: 'secret',
      );
      final backendController = _TrackingPreferredBackendController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStorageProvider.overrideWithValue(
              _RejectingProfileWriteSecureStorage(
                DirectConnectionProfilesDocument([profile]).encode(),
              ),
            ),
            preferredBackendProvider.overrideWith(() => backendController),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const DirectConnectionEditorPage(profileId: 'home'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DirectConnectionEditorPage)),
      );

      await tester.scrollUntilVisible(
        find.text('Delete connection'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Delete connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Could not delete this connection.'), findsOneWidget);
      expect(
        container.read(directConnectionProfilesProvider).requireValue.single.id,
        'home',
      );
      expect(container.read(preferredBackendProvider), PreferredBackend.direct);
      expect(backendController.writes, [
        PreferredBackend.unset,
        PreferredBackend.direct,
      ]);
    },
  );
}

void _noop() {}

final class _StaticOpenWebUiConnections
    extends OpenWebUiDirectConnectionsController {
  _StaticOpenWebUiConnections(this.snapshot);

  final OpenWebUiDirectConnectionsSnapshot snapshot;

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async => snapshot;
}

final class _RefreshFailureOpenWebUiConnections
    extends OpenWebUiDirectConnectionsController {
  _RefreshFailureOpenWebUiConnections(this.snapshot);

  final OpenWebUiDirectConnectionsSnapshot snapshot;

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async => snapshot;

  void failRefresh() {
    state = AsyncError<OpenWebUiDirectConnectionsSnapshot?>(
      StateError('refresh failed'),
      StackTrace.current,
    );
  }
}

final class _TrackingReloadOpenWebUiConnections
    extends OpenWebUiDirectConnectionsController {
  _TrackingReloadOpenWebUiConnections(this.snapshot);

  final OpenWebUiDirectConnectionsSnapshot snapshot;
  int reloadCount = 0;

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async => snapshot;

  @override
  Future<void> reload() async {
    reloadCount++;
  }
}

final class _MutableOpenWebUiConnections
    extends OpenWebUiDirectConnectionsController {
  _MutableOpenWebUiConnections(this.snapshot);

  OpenWebUiDirectConnectionsSnapshot snapshot;
  int deleteCalls = 0;
  int updateCalls = 0;
  OpenWebUiDirectConnectionRecord? lastUpdatedRecord;
  DirectConnectionProfile? lastUpdatedProfile;
  String? lastUpdatedAuthType;
  Future<void> Function()? updateHandler;
  Future<void> Function()? deleteHandler;

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async => snapshot;

  void setSnapshot(OpenWebUiDirectConnectionsSnapshot value) {
    snapshot = value;
    state = AsyncData(value);
  }

  @override
  Future<void> delete(OpenWebUiDirectConnectionRecord record) async {
    deleteCalls++;
    await deleteHandler?.call();
  }

  @override
  Future<void> updateConnection(
    OpenWebUiDirectConnectionRecord record,
    DirectConnectionProfile profile, {
    String? authType,
  }) async {
    updateCalls++;
    lastUpdatedRecord = record;
    lastUpdatedProfile = profile;
    lastUpdatedAuthType = authType;
    await updateHandler?.call();
  }
}

final class _StaticDirectProfiles extends DirectConnectionProfilesController {
  _StaticDirectProfiles(this.profiles);

  final List<DirectConnectionProfile> profiles;
  int probeCalls = 0;

  @override
  Future<List<DirectConnectionProfile>> build() async => profiles;

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    probeCalls++;
    return const DirectConnectionProbe(reachable: true);
  }
}

final class _MutableAuthEpoch extends Notifier<Object> {
  @override
  Object build() => Object();

  void rotate() => state = Object();
}

final class _StaticHistoryPolicy extends DirectHistoryPolicyController {
  @override
  DirectHistoryPolicy build() => DirectHistoryPolicy.syncWithOpenWebUI;
}

final class _FailingPreferredBackendController
    extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.direct;

  @override
  Future<void> set(PreferredBackend backend) async {
    throw StateError('preference write failed');
  }
}

final class _TrackingPreferredBackendController
    extends PreferredBackendController {
  final List<PreferredBackend> writes = [];

  @override
  PreferredBackend build() => PreferredBackend.direct;

  @override
  Future<void> set(PreferredBackend backend) async {
    writes.add(backend);
    state = backend;
  }
}

final class _BlockingPreferredBackendController
    extends PreferredBackendController {
  final List<PreferredBackend> writes = [];
  final Completer<void> unsetStarted = Completer<void>();
  final Completer<void> _releaseUnset = Completer<void>();

  @override
  PreferredBackend build() => PreferredBackend.direct;

  @override
  Future<void> set(PreferredBackend backend) async {
    writes.add(backend);
    if (backend == PreferredBackend.unset) {
      if (!unsetStarted.isCompleted) unsetStarted.complete();
      await _releaseUnset.future;
    }
    state = backend;
  }

  void release() {
    if (!_releaseUnset.isCompleted) _releaseUnset.complete();
  }
}

final class _RejectingProfileWriteSecureStorage
    implements FlutterSecureStorage {
  _RejectingProfileWriteSecureStorage(this.raw);

  final String raw;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => raw;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('profile write failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
