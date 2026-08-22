import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/core/platform/conduit_platform_apis.g.dart';
import 'package:conduit/core/models/model.dart';
import 'package:checks/checks.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/openwebui_direct_connection_store.dart';
import 'package:conduit/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'direct_connections_ui_test_support.dart';

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets('iOS management uses native grouped rows', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    final profile = DirectConnectionProfile(
      id: 'native-profile',
      name: 'Native provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://native.example/v1',
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: [profile],
            syncWithOpenWebUi: true,
            isOnboarding: false,
            showHistorySync: true,
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final nativeSections = tester
        .widgetList<InsetGroupedSection>(find.byType(InsetGroupedSection))
        .where((section) => section.useNativeSurface);
    expect(nativeSections.length, greaterThanOrEqualTo(2));
    final syncRow = tester.widget<UtilityRow>(
      find.widgetWithText(UtilityRow, 'Open WebUI history'),
    );
    final profileRow = tester.widget<UtilityRow>(
      find.widgetWithText(UtilityRow, 'Native provider'),
    );
    expect(syncRow.titleFontWeight, FontWeight.w400);
    expect(syncRow.subtitle, isNull);
    expect(profileRow.titleFontWeight, FontWeight.w400);
    expect(profileRow.showChevron, isTrue);
    expect(find.text('This device'), findsNothing);
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
          localizationsDelegates: conduitLocalizationsDelegates,
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

    expect(find.text('Direct Connections'), findsAtLeastNWidgets(1));
    expect(find.text('Open WebUI history'), findsAtLeastNWidgets(1));
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
          localizationsDelegates: conduitLocalizationsDelegates,
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
          localizationsDelegates: conduitLocalizationsDelegates,
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

  testWidgets('PCC settings show quota and fallback controls', (tester) async {
    var fallback = false;
    var quotaOptionsOpened = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: const [],
            syncWithOpenWebUi: false,
            isOnboarding: false,
            appleOnDeviceStatus: AsyncData(
              PlatformPccStatus(
                availability: PlatformPccAvailability.available,
                quotaStatus: PlatformPccQuotaStatus.unknown,
                quotaLimitReached: false,
                canIncreaseQuota: false,
                contextSize: 4096,
                supportsCurrentLocale: true,
              ),
            ),
            applePccStatus: AsyncData(
              PlatformPccStatus(
                availability: PlatformPccAvailability.available,
                quotaStatus: PlatformPccQuotaStatus.approachingLimit,
                quotaLimitReached: false,
                canIncreaseQuota: true,
                contextSize: 32768,
                supportsCurrentLocale: true,
              ),
            ),
            applePccOnDeviceFallback: fallback,
            onApplePccFallbackChanged: (value) => fallback = value,
            onShowApplePccQuotaOptions: () => quotaOptionsOpened = true,
            onRefreshApplePcc: () {},
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Apple On-Device'), findsOneWidget);
    expect(find.textContaining('4K token context'), findsOneWidget);
    expect(find.text('Apple Private Cloud Compute'), findsOneWidget);
    expect(
      find.textContaining('Nearing the daily usage limit'),
      findsOneWidget,
    );
    expect(find.textContaining('32K token context'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('apple-pcc-fallback-row')));
    await tester.tap(find.byKey(const ValueKey('apple-pcc-quota-options-row')));
    expect(fallback, isTrue);
    expect(quotaOptionsOpened, isTrue);
  });

  testWidgets('context fallback appears only for models without a limit', (
    tester,
  ) async {
    final missingId = DirectModelId.encode('local', 'missing-context');
    final knownId = DirectModelId.encode('local', 'known-context');
    final models = <Model>[
      Model(
        id: missingId,
        name: 'Unknown context model',
        metadata: const {'profileName': 'Local API'},
      ),
      Model(
        id: knownId,
        name: 'Known context model',
        capabilities: const {'context_length': 32768},
        metadata: const {'profileName': 'Local API'},
      ),
    ];
    String? changedModelId;
    int? changedContextLength;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: const [],
            modelsWithoutContextLimit: models
                .where(
                  (model) => directModelAdvertisedContextLength(model) == null,
                )
                .toList(),
            syncWithOpenWebUi: false,
            isOnboarding: false,
            onContextLengthChanged: (modelId, contextLength) {
              changedModelId = modelId;
              changedContextLength = contextLength;
            },
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Context compaction'), findsOneWidget);
    expect(find.text('Unknown context model'), findsOneWidget);
    expect(find.text('Known context model'), findsNothing);
    expect(find.textContaining('4K token context'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey<String>('direct-context-limit-$missingId')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('8K token context'));
    await tester.pumpAndSettle();

    expect(changedModelId, missingId);
    expect(changedContextLength, 8192);
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
          localizationsDelegates: conduitLocalizationsDelegates,
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
    final controller = DirectTestRefreshFailureOpenWebUiConnections(
      emptySnapshot,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiDirectConnectionsProvider.overrideWith(() => controller),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
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
    final remoteController = DirectTestTrackingReloadOpenWebUiConnections(
      snapshot,
    );
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
            () => DirectTestStaticDirectProfiles(const []),
          ),
          directHistoryPolicyProvider.overrideWith(
            DirectTestStaticHistoryPolicy.new,
          ),
          openWebUiDirectConnectionStoreProvider.overrideWithValue(
            availableStore,
          ),
          openWebUiDirectConnectionsProvider.overrideWith(
            () => remoteController,
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
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
}
