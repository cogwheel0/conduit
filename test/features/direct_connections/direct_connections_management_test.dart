import 'dart:io';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/direct_connections/services/apple_pcc_host.dart';
import 'package:conduit_core/models/model.dart';
import 'package:checks/checks.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/openwebui_direct_connection_store.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'direct_connections_ui_test_support.dart';
import '../../support/native_platform_views.dart';

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets('iOS management uses native grouped rows', (tester) async {
    stubNativePlatformViews();
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
      find.widgetWithText(UtilityRow, 'Open WebUI History'),
    );
    final profileRow = tester.widget<UtilityRow>(
      find.widgetWithText(UtilityRow, 'Native provider'),
    );
    expect(syncRow.titleFontWeight, FontWeight.w400);
    expect(syncRow.subtitle, isNull);
    expect(profileRow.titleFontWeight, FontWeight.w400);
    expect(profileRow.showChevron, isTrue);
    expect(find.text('This device'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

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
    expect(find.text('Open WebUI History'), findsAtLeastNWidgets(1));
    expect(find.text('Home Ollama'), findsOneWidget);
    expect(find.textContaining('http://192.168.1.5:11434'), findsOneWidget);
    expect(find.text('Add Connection'), findsOneWidget);

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

    expect(find.text('Open WebUI Server'), findsOneWidget);
    expect(find.text('On This Device'), findsOneWidget);
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

    expect(find.text('Open WebUI History'), findsNothing);
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
    expect(find.textContaining('Context limit: 4K'), findsOneWidget);
    expect(find.text('Apple Private Cloud Compute'), findsOneWidget);
    expect(
      find.textContaining('Nearing the daily usage limit'),
      findsOneWidget,
    );
    expect(find.textContaining('Context limit: 32K'), findsOneWidget);
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

    expect(find.text('Context Compaction'), findsOneWidget);
    expect(find.text('Unknown context model'), findsOneWidget);
    expect(find.text('Known context model'), findsNothing);
    expect(find.textContaining('Context limit: 4K'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey<String>('direct-context-limit-$missingId')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Context limit: 8K'));
    await tester.pumpAndSettle();

    expect(changedModelId, missingId);
    expect(changedContextLength, 8192);
  });

  testWidgets('the context limit list explains Ollama memory use', (
    tester,
  ) async {
    Widget content(Map<String, dynamic> metadata) => ProviderScope(
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DirectConnectionsContent(
          profiles: const [],
          modelsWithoutContextLimit: [
            Model(
              id: DirectModelId.encode('local', 'model'),
              name: 'Local model',
              metadata: metadata,
            ),
          ],
          syncWithOpenWebUi: false,
          isOnboarding: false,
          onContextLengthChanged: (_, _) {},
          onSyncChanged: (_) {},
          onAdd: () {},
          onEdit: (_) {},
        ),
      ),
    );
    final note = find.textContaining('context window Ollama loads the model');

    await tester.pumpWidget(content(const {'adapterKey': kOllamaAdapterKey}));
    await tester.pumpAndSettle();
    expect(note, findsOneWidget);

    await tester.pumpWidget(
      content(const {'adapterKey': kOpenAiCompatibleAdapterKey}),
    );
    await tester.pumpAndSettle();
    expect(note, findsNothing);
  });

  testWidgets('images per request opens a picker outside onboarding', (
    tester,
  ) async {
    int? changed;
    Widget content({required bool isOnboarding}) => ProviderScope(
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DirectConnectionsContent(
          profiles: const [],
          syncWithOpenWebUi: false,
          isOnboarding: isOnboarding,
          maxImagesPerRequest: kDefaultDirectMaxImagesPerRequest,
          onMaxImagesPerRequestChanged: (count) => changed = count,
          onSyncChanged: (_) {},
          onAdd: () {},
          onEdit: (_) {},
        ),
      ),
    );

    await tester.pumpWidget(content(isOnboarding: true));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('direct-images-per-request')),
      findsNothing,
    );

    await tester.pumpWidget(content(isOnboarding: false));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('direct-images-per-request'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: row, matching: find.text('Images per request')),
      findsOneWidget,
    );
    expect(find.descendant(of: row, matching: find.text('10')), findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4'));
    await tester.pumpAndSettle();

    expect(changed, 4);
  });

  testWidgets('a long context fallback list moves to its own page', (
    tester,
  ) async {
    final models = <Model>[
      for (var i = 0; i < kDirectContextCompactionInlineLimit + 1; i++)
        Model(
          id: DirectModelId.encode('gateway', 'model-$i'),
          name: 'Model $i',
        ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directModelDiscoveryProvider.overrideWith(
            () => _FixedDiscovery(models),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionsContent(
            profiles: const [],
            modelsWithoutContextLimit: models,
            syncWithOpenWebUi: false,
            isOnboarding: false,
            onContextLengthChanged: (_, _) {},
            onSyncChanged: (_) {},
            onAdd: () {},
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // One row instead of a row per model.
    expect(find.text('Model 0'), findsNothing);
    await tester.tap(find.text('6 models'));
    await tester.pumpAndSettle();

    for (final model in models) {
      expect(find.text(model.name), findsOneWidget);
    }
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
    expect(find.text('Open WebUI Server'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('On This Device'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('On This Device'), findsOneWidget);
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

    expect(find.text('No Server Connections Yet'), findsOneWidget);
    expect(
      find.text('Could not sync connections from Open WebUI.'),
      findsOneWidget,
    );
  });

  testWidgets('a failed Images per request save says so', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => DirectTestStaticDirectProfiles(const []),
          ),
          directHistoryPolicyProvider.overrideWith(
            DirectTestStaticHistoryPolicy.new,
          ),
          directMaxImagesPerRequestProvider.overrideWith(
            _FailingMaxImagesPerRequest.new,
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
    final row = find.byKey(const ValueKey('direct-images-per-request'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4'));
    await tester.pumpAndSettle();

    expect(
      find.text('Images per request could not be saved. Try again.'),
      findsOneWidget,
    );
    expect(find.descendant(of: row, matching: find.text('10')), findsOneWidget);
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

final class _FailingMaxImagesPerRequest
    extends DirectMaxImagesPerRequestController {
  @override
  int build() => kDefaultDirectMaxImagesPerRequest;

  @override
  Future<void> set(int count) =>
      Future<void>.error(const FileSystemException('disk full'));
}

final class _FixedDiscovery extends DirectModelDiscoveryController {
  _FixedDiscovery(this.models);

  final List<Model> models;

  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState(models: models);
}
