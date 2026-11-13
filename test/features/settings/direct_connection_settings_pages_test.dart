import 'dart:async';
import 'dart:io';

import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/settings/pages/direct_connection_page_ids.dart';
import 'package:conduit/features/settings/pages/direct_connection_settings_page_builders.dart';
import 'package:conduit/features/settings/pages/direct_connection_settings_pages.dart';
import 'package:conduit/features/settings/settings_controller.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/platform/flutter_secure_key_value_store.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/models/openwebui_direct_connection.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/direct_connections/services/apple_pcc_host.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_oauth.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_server_store.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/services/openwebui_direct_connection_store.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/secure_credential_storage.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../direct_connections/direct_connections_ui_test_support.dart';

final AppLocalizations _l10n = AppLocalizationsEn();

String _editor(DirectConnectionEditorSource source, [String? profileId]) =>
    directConnectionPageId(source, profileId);

String _key(DirectConnectionEditorSource source, [String? profileId]) =>
    directConnectionEditorKey(source, profileId);

const _local = DirectConnectionEditorSource.local;
const _server = DirectConnectionEditorSource.openWebUi;

/// Settings as the pages see it, answering the questions they ask with
/// [answer], or with what [onAsk] says, and keeping what was asked.
final class _Surface extends SettingsSurface {
  _Surface(super.ref);

  final asked = <String>[];
  String? answer;
  Future<String?> Function(String title)? onAsk;

  @override
  Future<String?> ask({
    required String title,
    String? message,
    required List<NativeSheetAlertAction> actions,
  }) async {
    asked.add(title);
    final handler = onAsk;
    return handler == null ? answer : handler(title);
  }
}

final class _Rig {
  _Rig(this.tester, this.container, this.surface);

  final WidgetTester tester;
  final ProviderContainer container;
  final _Surface surface;

  SettingsPageModule get module => container
      .read(settingsPageModulesProvider)
      .whereType<DirectConnectionSettingsPages>()
      .single;

  NativeSheetDetailConfig page(String id) =>
      container.read(settingsPagesProvider)[id]!;

  bool knows(String id) => container.read(settingsPagesProvider).contains(id);

  List<NativeSheetItemConfig> rows(String id) {
    final detail = page(id);
    return [...detail.items, for (final s in detail.sections) ...s.items];
  }

  NativeSheetItemConfig row(String pageId, String rowId) =>
      rows(pageId).singleWhere((row) => row.id == rowId);

  Iterable<String> titles(String id) => rows(id).map((row) => row.title);

  Iterable<String?> footers(String id) =>
      page(id).sections.map((section) => section.footer);

  List<String> get closed => [
    for (final MapEntry(:key, :value)
        in container.read(settingsPagesProvider).closeRequests.entries)
      for (var i = 0; i < value; i++) key,
  ];

  /// Opens page [id], as a row leading to it would.
  Future<void> open(String id) {
    if (!knows(id)) {
      container.read(settingsPagesProvider.notifier).register([
        NativeSheetDetailConfig(id: id, title: ''),
      ]);
    }
    return settle(module.hydrate(id, _l10n));
  }

  Future<void> change(String id, [Object? value = true]) =>
      settle(module.handleChange(id, value, _l10n));

  Future<void> settle(Future<Object?> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    while (!done) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await work;
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }
}

/// The app root as far as Settings needs it: it attaches the controller.
final class _App extends ConsumerStatefulWidget {
  const _App();

  @override
  ConsumerState<_App> createState() => _AppState();
}

final class _AppState extends ConsumerState<_App> {
  @override
  void initState() {
    super.initState();
    ref.read(settingsControllerProvider).attach(ref);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

Future<_Rig> _pump(
  WidgetTester tester, {
  List<Override> overrides = const [],
  bool attached = false,
}) async {
  late final _Surface surface;
  final container = ProviderContainer(
    overrides: [
      ...overrides,
      settingsSurfaceProvider.overrideWith((ref) => surface = _Surface(ref)),
    ],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  container.read(settingsSurfaceProvider);
  if (attached) {
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const _App()),
    );
  }
  final rig = _Rig(tester, container, surface);
  addTearDown(rig.module.settingsClosed);
  return rig;
}

/// A provider kept on this device, in the secure store the pages read.
List<Override> _storedProfiles(List<DirectConnectionProfile> profiles) {
  FlutterSecureStorage.setMockInitialValues({
    'direct_connection_profiles_v1': DirectConnectionProfilesDocument(profiles)
        .encode(),
  });
  return [
    secureStorageProvider.overrideWithValue(FlutterSecureKeyValueStore()),
  ];
}

OpenWebUiDirectConnectionsSnapshot _snapshot(
  List<String> urls, {
  String accountId = 'account',
  List<String>? keys,
  List<Map<String, Object?>>? configs,
}) => OpenWebUiDirectConnectionsCodec(serverId: 'server', accountId: accountId)
    .decode({
      'ui': {
        if (urls.isNotEmpty)
          'directConnections': {
            'OPENAI_API_BASE_URLS': urls,
            'OPENAI_API_KEYS': keys ?? [for (final _ in urls) 'server-key'],
            'OPENAI_API_CONFIGS': {
              for (var i = 0; i < urls.length; i++)
                '$i': configs?[i] ?? {'auth_type': 'bearer'},
            },
          },
      },
    });

void main() {
  group('Direct page', () {
    final local = DirectConnectionProfile(
      id: 'device-profile',
      name: 'Device provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://device.example/v1',
    );

    test('lists server and device providers apart, each opening its '
        'editor', () {
      final snapshot = _snapshot(['https://server.example/v1']);
      final page = buildDirectConnectionsPage(
        _l10n,
        DirectSettingsView(
          profiles: AsyncData([local]),
          openWebUi: AsyncData(snapshot),
          showOpenWebUi: true,
          syncWithOpenWebUi: true,
        ),
      );

      final titles = page.sections.map((section) => section.title).toList();
      expect(
        titles,
        containsAllInOrder(['Open WebUI Server', 'On This Device']),
      );
      final rows = [for (final section in page.sections) ...section.items];
      final server = rows.singleWhere(
        (row) => row.id == _editor(_server, snapshot.records.single.profile.id),
      );
      expect(server.title, 'server.example · 1');
      final device = rows.singleWhere(
        (row) => row.id == _editor(_local, local.id),
      );
      expect(device.subtitle, contains('https://device.example/v1'));
      // Each group adds its own.
      expect(rows.map((row) => row.id), contains(_editor(_server)));
      expect(rows.map((row) => row.id), contains(_editor(_local)));
      expect(
        rows.singleWhere((row) => row.id == directRowId('history-sync')).value,
        isTrue,
      );
    });

    test('without an Open WebUI account it offers no history or server '
        'providers', () {
      final page = buildDirectConnectionsPage(
        _l10n,
        DirectSettingsView(profiles: const AsyncData([])),
      );

      final ids = [
        for (final section in page.sections)
          for (final row in section.items) row.id,
      ];
      expect(ids, isNot(contains(directRowId('history-sync'))));
      expect(ids, isNot(contains(_editor(_server))));
      expect(
        page.sections.map((section) => section.title),
        contains('Connections'),
      );
      // An empty list says what to add.
      expect(
        page.sections.map((section) => section.footer),
        contains('Add an API provider to start chatting.'),
      );
    });

    test('a failed server reload shows with Retry and Add', () {
      final page = buildDirectConnectionsPage(
        _l10n,
        DirectSettingsView(
          profiles: const AsyncData([]),
          openWebUi: AsyncError(StateError('refresh failed'), StackTrace.empty),
          showOpenWebUi: true,
        ),
      );

      final titles = [
        for (final section in page.sections)
          for (final row in section.items) row.title,
      ];
      expect(titles, contains('Could not sync connections from Open WebUI.'));
      expect([
        for (final section in page.sections)
          for (final row in section.items) row.id,
      ], containsAll([directRowId('retry-openwebui'), _editor(_server)]));
      expect(titles.where((title) => title == 'Retry'), hasLength(1));
    });

    test('unreadable providers say why and offer Retry, not Add', () {
      final page = buildDirectConnectionsPage(
        _l10n,
        DirectSettingsView(
          profiles: AsyncError(const FormatException('bad'), StackTrace.empty),
        ),
      );
      final rows = [for (final section in page.sections) ...section.items];

      expect(
        rows.map((row) => row.subtitle),
        contains(_l10n.directSavedDataUnreadable),
      );
      expect(
        rows.map((row) => row.id),
        contains(directRowId('retry-profiles')),
      );
      expect(rows.map((row) => row.id), isNot(contains(_editor(_local))));
    });

    test('MCP servers list without what their endpoint query carries', () {
      final page = buildDirectConnectionsPage(
        _l10n,
        DirectSettingsView(
          profiles: const AsyncData([]),
          mcpServers: AsyncData([
            DirectMcpServer(
              id: 'tools',
              name: 'Tools',
              endpoint: 'https://mcp.example/mcp?token=query-secret',
            ),
          ]),
        ),
      );
      final rows = [for (final section in page.sections) ...section.items];
      final server = rows.singleWhere(
        (row) => row.id == directMcpPageId('tools'),
      );

      expect(server.subtitle, 'Enabled\nhttps://mcp.example/mcp');
      expect(server.subtitle, isNot(contains('query-secret')));
      expect(rows.map((row) => row.id), contains(directMcpPageId(null)));
    });

    test('an MCP storage failure says so, with Retry and Add', () {
      final page = buildDirectConnectionsPage(
        _l10n,
        DirectSettingsView(
          profiles: const AsyncData([]),
          mcpServers: AsyncError(StateError('locked'), StackTrace.empty),
        ),
      );
      final rows = [for (final section in page.sections) ...section.items];

      expect(
        rows.map((row) => row.title),
        contains('Could not load MCP servers from secure storage.'),
      );
      expect(
        rows.map((row) => row.id),
        containsAll([directRowId('retry-mcp'), directMcpPageId(null)]),
      );
    });

    test('Apple models open pages of their own, with quota and fallback', () {
      final onDevice = PlatformPccStatus(
        availability: PlatformPccAvailability.available,
        quotaStatus: PlatformPccQuotaStatus.unknown,
        quotaLimitReached: false,
        canIncreaseQuota: false,
        contextSize: 4096,
        supportsCurrentLocale: true,
      );
      final pcc = PlatformPccStatus(
        availability: PlatformPccAvailability.available,
        quotaStatus: PlatformPccQuotaStatus.approachingLimit,
        quotaLimitReached: false,
        canIncreaseQuota: true,
        contextSize: 32768,
        supportsCurrentLocale: false,
      );
      final direct = buildDirectConnectionsPage(
        _l10n,
        DirectSettingsView(
          profiles: const AsyncData([]),
          appleOnDevice: AsyncData(onDevice),
          applePcc: AsyncData(pcc),
        ),
      );
      final apple = direct.sections.firstWhere(
        (section) => section.title == 'Apple Intelligence',
      );
      expect(apple.items.map((row) => row.id), [
        directApplePageId(directAppleOnDevice),
        directApplePageId(directApplePcc),
      ]);
      expect(apple.items.first.subtitle, contains('Context limit: 4K'));

      final page = buildDirectApplePage(
        _l10n,
        model: directApplePcc,
        status: AsyncData(pcc),
        fallback: false,
      );
      final rows = [for (final section in page.sections) ...section.items];
      expect(rows.first.subtitle, contains('Nearing the daily usage limit'));
      expect(rows.first.subtitle, contains('Context limit: 32K'));
      expect(
        rows
            .singleWhere((row) => row.id == directRowId('apple-fallback'))
            .value,
        isFalse,
      );
      expect(rows.map((row) => row.id), contains(directRowId('apple-quota')));
      expect(
        page.sections.first.footer,
        _l10n.applePccCurrentLanguageUnsupported,
      );
      // On-device has neither.
      final device = buildDirectApplePage(
        _l10n,
        model: directAppleOnDevice,
        status: AsyncData(onDevice),
        fallback: false,
      );
      expect(
        [
          for (final section in device.sections)
            for (final row in section.items) row.id,
        ],
        [directRowId('apple-refresh', directAppleOnDevice)],
      );
    });

    test('context limits list models without one, and a long list moves '
        'to a page', () {
      final missing = Model(
        id: DirectModelId.encode('local', 'missing-context'),
        name: 'Unknown context model',
        metadata: const {
          'profileName': 'Local API',
          'adapterKey': kOllamaAdapterKey,
        },
      );
      final page = buildDirectConnectionsPage(
        _l10n,
        DirectSettingsView(
          profiles: const AsyncData([]),
          modelsWithoutContextLimit: [missing],
          contextLengthOverrides: {missing.id: 8192},
        ),
      );
      final section = page.sections.firstWhere(
        (section) => section.title == 'Context Compaction',
      );
      final row = section.items.single;
      expect(row.id, directRowId('context', missing.id));
      expect(row.value, '8192');
      expect(
        row.options.map((option) => option.label),
        contains('Context limit: 8K'),
      );
      // A limit picked for Ollama also sizes its context window.
      expect(section.footer, contains('context window Ollama loads the model'));

      final many = [
        for (var i = 0; i < kDirectContextLimitsInlineLimit + 1; i++)
          Model(id: DirectModelId.encode('gateway', 'model-$i'), name: 'M$i'),
      ];
      final long = DirectSettingsView(
        profiles: const AsyncData([]),
        modelsWithoutContextLimit: many,
      );
      final summary = buildDirectConnectionsPage(_l10n, long).sections
          .firstWhere((section) => section.title == 'Context Compaction')
          .items
          .single;
      expect(summary.id, directContextLimitsPageId);
      expect(summary.title, '6 models');
      expect(
        buildDirectContextLimitsPage(
          _l10n,
          long,
        ).sections.single.items.map((row) => row.title),
        [for (final model in many) model.name],
      );
    });
  });

  group('Direct page in Settings', () {
    List<Override> pageOverrides({
      OpenWebUiDirectConnectionsController? server,
      List<Override> extra = const [],
    }) {
      PreferencesStore.debugOverride(
        InMemoryKeyValueStore(<String, Object?>{}),
      );
      addTearDown(PreferencesStore.debugReset);
      return [
        directConnectionProfilesProvider.overrideWith(
          () => DirectTestStaticDirectProfiles(const []),
        ),
        directHistoryPolicyProvider.overrideWith(
          DirectTestStaticHistoryPolicy.new,
        ),
        directMcpServersProvider.overrideWithBuild((ref, _) async => const []),
        directModelDiscoveryProvider.overrideWith(() => _FixedDiscovery([])),
        if (server != null) ...[
          openWebUiDirectConnectionsAvailableProvider.overrideWithValue(true),
          openWebUiDirectConnectionsProvider.overrideWith(() => server),
        ],
        ...extra,
      ];
    }

    testWidgets('it reads server providers again on entry and on resume', (
      tester,
    ) async {
      final server = DirectTestTrackingReloadOpenWebUiConnections(
        _snapshot([]),
      );
      final rig = await _pump(tester, overrides: pageOverrides(server: server));

      await rig.open(directConnectionsPageId);
      expect(server.reloadCount, 1);

      _background(tester);
      _foreground(tester);
      await tester.pump();
      expect(server.reloadCount, 2);

      // Left, it stops.
      rig.module.pageLeft(directConnectionsPageId);
      _background(tester);
      _foreground(tester);
      await tester.pump();
      expect(server.reloadCount, 2);
    });

    testWidgets('it registers each editor it leads to', (tester) async {
      final server = DirectTestTrackingReloadOpenWebUiConnections(
        _snapshot(['https://server.example/v1']),
      );
      final rig = await _pump(tester, overrides: pageOverrides(server: server));

      await rig.open(directConnectionsPageId);
      await tester.pump();

      final record = (await rig.container.read(
        openWebUiDirectConnectionsProvider.future,
      ))!.records.single;
      for (final id in [
        _editor(_server, record.profile.id),
        _editor(_server),
        _editor(_local),
        directMcpPageId(null),
      ]) {
        expect(rig.knows(id), isTrue, reason: id);
      }
    });

    testWidgets('the history row sets the policy', (tester) async {
      final server = DirectTestTrackingReloadOpenWebUiConnections(
        _snapshot([]),
      );
      final rig = await _pump(tester, overrides: pageOverrides(server: server));
      await rig.open(directConnectionsPageId);

      await rig.change(directRowId('history-sync'), false);
      await tester.pump();

      expect(
        rig.container.read(directHistoryPolicyProvider),
        DirectHistoryPolicy.localOnly,
      );
    });

    testWidgets('it follows what it shows after a row change, as in the '
        'app', (tester) async {
      final server = DirectTestTrackingReloadOpenWebUiConnections(
        _snapshot([]),
      );
      final rig = await _pump(
        tester,
        overrides: pageOverrides(server: server),
        attached: true,
      );
      await rig.open(directConnectionsPageId);
      expect(
        rig.row(directConnectionsPageId, directRowId('history-sync')).value,
        true,
      );

      // Changed elsewhere, after a row change here read the modules again.
      await rig.change(directRowId('unknown-row'));
      await rig.container
          .read(directHistoryPolicyProvider.notifier)
          .setPolicy(DirectHistoryPolicy.localOnly);
      await rig.settle(Future<void>.value());

      expect(
        rig.row(directConnectionsPageId, directRowId('history-sync')).value,
        false,
      );
    });

    testWidgets('a failed Images per request save says so', (tester) async {
      final rig = await _pump(
        tester,
        overrides: pageOverrides(
          extra: [
            directMaxImagesPerRequestProvider.overrideWith(
              _FailingMaxImagesPerRequest.new,
            ),
          ],
        ),
      );
      await rig.open(directConnectionsPageId);

      await rig.change(directRowId('images'), '4');

      final page = rig.page(directConnectionsPageId);
      expect(
        page.announcement,
        'Images per request could not be saved. Try again.',
      );
      expect(
        rig.row(directConnectionsPageId, directRowId('images')).value,
        '10',
      );
    });

    testWidgets('a context limit picked is kept for its model', (tester) async {
      final missing = Model(
        id: DirectModelId.encode('local', 'missing'),
        name: 'Missing',
      );
      final rig = await _pump(tester, overrides: pageOverrides());
      await rig.open(directConnectionsPageId);

      await rig.change(directRowId('context', missing.id), '16384');

      expect(
        rig.container.read(directContextLengthOverridesProvider)[missing.id],
        16384,
      );
    });
  });

  group('provider editor', () {
    testWidgets('restores the OpenAI-family completion API', (tester) async {
      final rig = await _pump(
        tester,
        overrides: _storedProfiles([
          DirectConnectionProfile(
            id: 'lm-studio',
            name: 'LM Studio',
            adapterKey: kOpenAiCompatibleAdapterKey,
            baseUrl: 'http://localhost:1234/v1',
            openAiApiMode: DirectOpenAiApiMode.responses,
          ),
        ]),
      );
      final key = _key(_local, 'lm-studio');

      await rig.open(_editor(_local, 'lm-studio'));
      await rig.until(
        () => rig.titles(_editor(_local, 'lm-studio')).isNotEmpty,
      );
      await rig.open('$directConnectionAdvancedPagePrefix$key');

      final mode = rig.row(
        '$directConnectionAdvancedPagePrefix$key',
        directConnectionRowId('api-mode', key),
      );
      expect(mode.value, 'responses');
      expect(mode.options.map((option) => option.label), [
        'Chat Completions',
        'Responses',
      ]);
    });

    testWidgets('switching a provider to OpenRouter resets what follows it', (
      tester,
    ) async {
      final rig = await _pump(
        tester,
        overrides: _storedProfiles([
          DirectConnectionProfile(
            id: 'existing-generic',
            name: 'Existing provider',
            adapterKey: kOpenAiCompatibleAdapterKey,
            baseUrl: 'https://provider.example/v1',
            openAiApiMode: DirectOpenAiApiMode.responses,
          ),
        ]),
      );
      final key = _key(_local, 'existing-generic');
      final page = _editor(_local, 'existing-generic');
      await rig.open(page);

      await rig.change(directConnectionRowId('provider', key), 'openrouter');

      expect(
        rig.row(page, directConnectionRowId('url', key)).value,
        kOpenRouterApiBaseUrl,
      );
      expect(rig.row(page, directConnectionRowId('auth', key)).value, 'bearer');
      await rig.open('$directConnectionAdvancedPagePrefix$key');
      final mode = rig.row(
        '$directConnectionAdvancedPagePrefix$key',
        directConnectionRowId('api-mode', key),
      );
      expect(mode.kind, NativeSheetItemKind.info);
      expect(mode.subtitle, 'Chat Completions');
      // Changed on the editor, so leaving asks first.
      expect(rig.page(page).edited, isTrue);
    });

    testWidgets('a new provider offers its authentication choices', (
      tester,
    ) async {
      final rig = await _pump(
        tester,
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => DirectTestStaticDirectProfiles(const []),
          ),
        ],
      );
      final key = _key(_local);
      await rig.open(_editor(_local));
      await rig.until(() => rig.rows(_editor(_local)).length > 1);

      final auth = rig.row(_editor(_local), directConnectionRowId('auth', key));
      expect(auth.value, 'bearer');
      expect(auth.options.map((option) => option.id), [
        'bearer',
        'apiKeyHeader',
        'none',
      ]);
      final page = rig.page(_editor(_local));
      expect(page.title, 'Add Connection');
      expect(page.confirmActionId, directConnectionRowId('save', key));
      expect(page.discardPrompt, isNotNull);
      expect(
        rig.rows(_editor(_local)).map((row) => row.id),
        containsAll([
          directConnectionRowId('enabled', key),
          directConnectionRowId('provider', key),
          directConnectionRowId('test', key),
          '$directConnectionAdvancedPagePrefix$key',
        ]),
      );
      // Only a saved one can be deleted.
      expect(
        rig.rows(_editor(_local)).map((row) => row.id),
        isNot(contains(directConnectionRowId('delete', key))),
      );
    });

    testWidgets('its key is a secret, not a password to save', (tester) async {
      final rig = await _pump(
        tester,
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => DirectTestStaticDirectProfiles(const []),
          ),
        ],
      );
      final key = _key(_local);
      await rig.open(_editor(_local));
      await rig.until(() => rig.rows(_editor(_local)).length > 1);

      final apiKey = rig.row(
        _editor(_local),
        directConnectionRowId('api-key', key),
      );
      expect(apiKey.kind, NativeSheetItemKind.secureTextField);
      expect(apiKey.passwordRole, isNull);
    });

    testWidgets('a provider of an unknown kind keeps it, greyed', (
      tester,
    ) async {
      final profile = DirectConnectionProfile(
        id: 'custom-profile',
        name: 'Custom provider',
        adapterKey: 'plugin.custom-adapter',
        baseUrl: 'https://custom.example/v1',
      );
      final rig = await _pump(
        tester,
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => DirectTestStaticDirectProfiles([profile]),
          ),
        ],
      );
      final key = _key(_local, profile.id);
      await rig.open(_editor(_local, profile.id));
      await rig.until(() => rig.rows(_editor(_local, profile.id)).length > 1);

      final provider = rig.row(
        _editor(_local, profile.id),
        directConnectionRowId('provider', key),
      );
      expect(provider.value, 'plugin.custom-adapter');
      expect(provider.options.first.label, 'plugin.custom-adapter');
      expect(provider.options.first.enabled, isFalse);
    });

    testWidgets('a header is added on its own page and removed from its menu', (
      tester,
    ) async {
      final rig = await _pump(
        tester,
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => DirectTestStaticDirectProfiles(const []),
          ),
        ],
      );
      final key = _key(_local);
      final editor = _editor(_local);
      final advanced = '$directConnectionAdvancedPagePrefix$key';
      final header = '$directConnectionHeaderPagePrefix$key';
      await rig.open(editor);
      await rig.open(advanced);
      await rig.open(header);

      await rig.change(directConnectionRowId('header-name', key), 'Bad Name');
      await rig.change(directConnectionRowId('header-add', key));
      expect(rig.page(header).announcement, _l10n.headerNameInvalidChars);
      expect(rig.closed, isEmpty);

      await rig.change(directConnectionRowId('header-name', key), 'X-Tenant');
      await rig.change(directConnectionRowId('header-value', key), 'acme');
      await rig.change(directConnectionRowId('header-add', key));
      expect(rig.closed, [header]);
      final added = rig.row(
        advanced,
        directConnectionRowId('header', key, 'X-Tenant'),
      );
      expect(added.subtitle, 'acme');
      // The editor under it now asks before its changes are dropped.
      expect(rig.page(editor).edited, isTrue);

      await rig.change(added.rowActions.single.id);
      expect(
        rig.rows(advanced).map((row) => row.id),
        isNot(contains(directConnectionRowId('header', key, 'X-Tenant'))),
      );
    });

    testWidgets('a new provider saves and goes back', (tester) async {
      final profiles = DirectTestOnboardingDirectProfiles(
        const DirectConnectionProbe(reachable: true),
      );
      final rig = await _pump(
        tester,
        overrides: [
          directConnectionProfilesProvider.overrideWith(() => profiles),
        ],
      );
      final key = _key(_local);
      await rig.open(_editor(_local));
      await rig.until(() => rig.rows(_editor(_local)).length > 1);

      await rig.change(directConnectionRowId('name', key), 'Home');
      await rig.change(
        directConnectionRowId('url', key),
        'https://home.example/v1',
      );
      await rig.change(directConnectionRowId('api-key', key), 'home-secret');
      await rig.change(directConnectionRowId('save', key));

      expect(profiles.upsertCalls, 1);
      expect(profiles.lastUpsert?.name, 'Home');
      expect(profiles.lastUpsert?.apiKey, 'home-secret');
      expect(rig.closed, [_editor(_local)]);
    });

    testWidgets('one added from Add Account goes back to Accounts', (
      tester,
    ) async {
      final profiles = DirectTestOnboardingDirectProfiles(
        const DirectConnectionProbe(reachable: true),
      );
      final rig = await _pump(
        tester,
        overrides: [
          directConnectionProfilesProvider.overrideWith(() => profiles),
        ],
      );
      final key = directConnectionAddAccountPageId.substring(
        directConnectionPagePrefix.length,
      );
      await rig.open(directConnectionAddAccountPageId);
      await rig.until(
        () => rig.rows(directConnectionAddAccountPageId).length > 1,
      );

      await rig.change(directConnectionRowId('api-key', key), 'home-secret');
      await rig.change(directConnectionRowId('save', key));

      expect(profiles.upsertCalls, 1);
      expect(rig.closed, [nativeAccountsAddItemId]);
    });

    testWidgets('Test says how the provider answered', (tester) async {
      final profiles = DirectTestOnboardingDirectProfiles(
        const DirectConnectionProbe(reachable: true, modelCount: 3),
      );
      final rig = await _pump(
        tester,
        overrides: [
          directConnectionProfilesProvider.overrideWith(() => profiles),
        ],
      );
      final key = _key(_local);
      await rig.open(_editor(_local));
      await rig.until(() => rig.rows(_editor(_local)).length > 1);

      await rig.change(directConnectionRowId('api-key', key), 'home-secret');
      await rig.change(directConnectionRowId('test', key));

      expect(profiles.probeCalls, 1);
      expect(profiles.upsertCalls, 0);
      expect(
        rig.page(_editor(_local)).announcement,
        _l10n.directConnectionProbeConnectedModels(3),
      );
      expect(
        rig.titles(_editor(_local)),
        contains(_l10n.directConnectionProbeConnectedModels(3)),
      );
    });

    testWidgets('a save from a stale snapshot is refused', (tester) async {
      final profile = DirectConnectionProfile(
        id: 'shared-profile',
        name: 'Original provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://provider.example/v1',
        apiKey: 'original-secret',
      );
      final rig = await _pump(tester, overrides: _storedProfiles([profile]));
      final key = _key(_local, profile.id);
      final page = _editor(_local, profile.id);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);

      await rig.settle(
        rig.container
            .read(directConnectionProfilesProvider.notifier)
            .upsert(
              profile.copyWith(
                name: 'Concurrent provider',
                apiKey: 'concurrent-secret',
              ),
            ),
      );
      await rig.change(directConnectionRowId('name', key), 'Stale rename');
      await rig.change(directConnectionRowId('save', key));

      expect(
        rig.page(page).announcement,
        'This connection changed elsewhere. Reopen it before saving.',
      );
      expect(rig.closed, isEmpty);
      final saved = rig.container
          .read(directConnectionProfilesProvider)
          .requireValue
          .single;
      expect(saved.name, 'Concurrent provider');
      expect(saved.apiKey, 'concurrent-secret');
    });

    testWidgets('while Delete asks, nothing else runs', (tester) async {
      final profiles = DirectTestStaticDirectProfiles([
        DirectConnectionProfile(
          id: 'home',
          name: 'Home provider',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://provider.example/v1',
          apiKey: 'secret',
        ),
      ]);
      final rig = await _pump(
        tester,
        overrides: [
          directConnectionProfilesProvider.overrideWith(() => profiles),
        ],
      );
      final key = _key(_local, 'home');
      final page = _editor(_local, 'home');
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);
      rig.surface.onAsk = (_) async {
        await rig.module.handleChange(
          directConnectionRowId('test', key),
          true,
          _l10n,
        );
        return 'cancel';
      };

      await rig.change(directConnectionRowId('delete', key));

      expect(rig.surface.asked, ['Delete connection?']);
      expect(profiles.probeCalls, 0);
      final delete = rig.row(page, directConnectionRowId('delete', key));
      expect(delete.pending, isFalse);
      expect(delete.disabled, isFalse);
      expect(rig.closed, isEmpty);
    });

    testWidgets('Delete counts providers added while it asks', (tester) async {
      final backend = DirectTestTrackingPreferredBackendController();
      final rig = await _pump(
        tester,
        overrides: [
          ..._storedProfiles([
            DirectConnectionProfile(
              id: 'home',
              name: 'Home provider',
              adapterKey: kOpenAiCompatibleAdapterKey,
              baseUrl: 'https://provider.example/v1',
              apiKey: 'secret',
            ),
          ]),
          preferredBackendProvider.overrideWith(() => backend),
        ],
      );
      final key = _key(_local, 'home');
      await rig.open(_editor(_local, 'home'));
      await rig.until(() => rig.rows(_editor(_local, 'home')).length > 1);
      rig.surface.onAsk = (_) async {
        await rig.container
            .read(directConnectionProfilesProvider.notifier)
            .upsert(
              DirectConnectionProfile(
                id: 'backup',
                name: 'Backup provider',
                adapterKey: kOpenAiCompatibleAdapterKey,
                baseUrl: 'https://backup.example/v1',
                apiKey: 'backup-secret',
              ),
            );
        return 'delete';
      };

      await rig.change(directConnectionRowId('delete', key));

      expect(
        rig.container
            .read(directConnectionProfilesProvider)
            .requireValue
            .map((item) => item.id),
        ['backup'],
      );
      expect(
        rig.container.read(preferredBackendProvider),
        PreferredBackend.direct,
      );
      expect(backend.writes, isEmpty);
      expect(rig.closed, [_editor(_local, 'home')]);
    });

    testWidgets('a failed backend switch keeps the last provider', (
      tester,
    ) async {
      final rig = await _pump(
        tester,
        overrides: [
          ..._storedProfiles([
            DirectConnectionProfile(
              id: 'home',
              name: 'Home provider',
              adapterKey: kOpenAiCompatibleAdapterKey,
              baseUrl: 'https://provider.example/v1',
              apiKey: 'secret',
            ),
          ]),
          preferredBackendProvider.overrideWith(
            DirectTestFailingPreferredBackendController.new,
          ),
        ],
      );
      final key = _key(_local, 'home');
      final page = _editor(_local, 'home');
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);
      rig.surface.answer = 'delete';

      await rig.change(directConnectionRowId('delete', key));

      expect(rig.page(page).announcement, 'Could not delete this connection.');
      expect(
        rig.container
            .read(directConnectionProfilesProvider)
            .requireValue
            .single
            .id,
        'home',
      );
      expect(
        rig.container.read(preferredBackendProvider),
        PreferredBackend.direct,
      );
      final durable = await FlutterSecureKeyValueStore().read(
        key: 'direct_connection_profiles_v1',
      );
      expect(durable, contains('secret'));
    });

    testWidgets('a failed write puts the cleared backend back', (tester) async {
      final profile = DirectConnectionProfile(
        id: 'home',
        name: 'Home provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://provider.example/v1',
        apiKey: 'secret',
      );
      final backend = DirectTestTrackingPreferredBackendController();
      final rig = await _pump(
        tester,
        overrides: [
          secureStorageProvider.overrideWithValue(
            DirectTestRejectingProfileWriteSecureStorage(
              DirectConnectionProfilesDocument([profile]).encode(),
            ),
          ),
          preferredBackendProvider.overrideWith(() => backend),
        ],
      );
      final key = _key(_local, 'home');
      final page = _editor(_local, 'home');
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);
      rig.surface.answer = 'delete';

      await rig.change(directConnectionRowId('delete', key));

      expect(rig.page(page).announcement, 'Could not delete this connection.');
      expect(
        rig.container.read(preferredBackendProvider),
        PreferredBackend.direct,
      );
      expect(backend.writes, [PreferredBackend.unset, PreferredBackend.direct]);
    });

    testWidgets('closing Settings stops the editor', (tester) async {
      final rig = await _pump(
        tester,
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => DirectTestStaticDirectProfiles(const []),
          ),
        ],
      );
      final key = _key(_local);
      await rig.open(_editor(_local));
      await rig.change(directConnectionRowId('name', key), 'Draft');

      rig.module.settingsClosed();
      await rig.open(_editor(_local));

      expect(
        rig.row(_editor(_local), directConnectionRowId('name', key)).value,
        _l10n.directDefaultConnectionName,
      );
    });
  });

  group('server provider editor', () {
    List<Override> serverOverrides(
      OpenWebUiDirectConnectionsController controller, {
      NotifierProvider<DirectTestMutableAuthEpoch, Object>? epoch,
      List<Override> extra = const [],
    }) => [
      openWebUiDirectConnectionsProvider.overrideWith(() => controller),
      if (epoch != null)
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(epoch),
        ),
      ...extra,
    ];

    testWidgets('it says changes go to Open WebUI and keeps the name', (
      tester,
    ) async {
      final snapshot = _snapshot(['https://server.example/v1']);
      final id = snapshot.records.single.profile.id;
      final rig = await _pump(
        tester,
        overrides: serverOverrides(
          DirectTestStaticOpenWebUiConnections(snapshot),
        ),
      );
      final key = _key(_server, id);
      await rig.open(_editor(_server, id));
      await rig.until(() => rig.rows(_editor(_server, id)).length > 1);

      final ids = rig.rows(_editor(_server, id)).map((row) => row.id);
      expect(ids, isNot(contains(directConnectionRowId('name', key))));
      expect(ids, contains(directConnectionRowId('url', key)));
      final provider = rig.row(
        _editor(_server, id),
        directConnectionRowId('provider', key),
      );
      expect(provider.kind, NativeSheetItemKind.info);
      expect(
        rig.footers(_editor(_server, id)),
        contains(contains('Changes are saved to your Open WebUI account.')),
      );
    });

    testWidgets('a new draft is dropped when the account changes', (
      tester,
    ) async {
      final controller = DirectTestMutableOpenWebUiConnections(
        _snapshot([], accountId: 'account-a'),
      );
      final rig = await _pump(tester, overrides: serverOverrides(controller));
      final key = _key(_server);
      await rig.open(_editor(_server));
      await rig.until(() => rig.rows(_editor(_server)).length > 1);
      await rig.change(
        directConnectionRowId('url', key),
        'https://account-a.example/v1',
      );

      controller.setSnapshot(_snapshot([], accountId: 'account-b'));
      await rig.until(
        () => rig
            .titles(_editor(_server))
            .contains('Open WebUI connections are unavailable.'),
      );

      expect(
        rig.rows(_editor(_server)).map((row) => row.id),
        isNot(contains(directConnectionRowId('url', key))),
      );
    });

    testWidgets('Test stops when the account changes while it asks', (
      tester,
    ) async {
      final accountA = _snapshot(
        ['https://old.example/v1'],
        accountId: 'account-a',
        keys: ['old-secret'],
      );
      final remote = DirectTestMutableOpenWebUiConnections(accountA);
      final local = DirectTestStaticDirectProfiles(const []);
      final rig = await _pump(
        tester,
        overrides: serverOverrides(
          remote,
          extra: [directConnectionProfilesProvider.overrideWith(() => local)],
        ),
      );
      final id = accountA.records.single.profile.id;
      final key = _key(_server, id);
      await rig.open(_editor(_server, id));
      await rig.until(() => rig.rows(_editor(_server, id)).length > 1);
      await rig.change(
        directConnectionRowId('url', key),
        'https://new.example/v1',
      );
      await rig.change(directConnectionRowId('api-key', key), 'new-secret');
      rig.surface.onAsk = (_) async {
        remote.setSnapshot(_snapshot([], accountId: 'account-b'));
        return 'send';
      };

      await rig.change(directConnectionRowId('test', key));

      expect(rig.surface.asked, ['Use credentials with new server?']);
      expect(local.probeCalls, 0);
    });

    testWidgets('Save stops when sign-in changes while it asks', (
      tester,
    ) async {
      final snapshot = _snapshot(['https://old.example/v1'], keys: ['old']);
      final remote = DirectTestMutableOpenWebUiConnections(snapshot);
      final epoch = NotifierProvider<DirectTestMutableAuthEpoch, Object>(
        DirectTestMutableAuthEpoch.new,
      );
      final rig = await _pump(
        tester,
        overrides: serverOverrides(remote, epoch: epoch),
      );
      final id = snapshot.records.single.profile.id;
      final key = _key(_server, id);
      await rig.open(_editor(_server, id));
      await rig.until(() => rig.rows(_editor(_server, id)).length > 1);
      await rig.change(
        directConnectionRowId('url', key),
        'https://new.example/v1',
      );
      await rig.change(directConnectionRowId('api-key', key), 'new-secret');
      rig.surface.onAsk = (_) async {
        rig.container.read(epoch.notifier).rotate();
        return 'send';
      };

      await rig.change(directConnectionRowId('save', key));

      expect(remote.updateCalls, 0);
      expect(
        rig.titles(_editor(_server, id)),
        contains('Open WebUI connections are unavailable.'),
      );
      expect(
        rig.titles(_editor(_server, id)),
        isNot(contains('Could not save this connection.')),
      );
      expect(rig.closed, isEmpty);
    });

    testWidgets('a draft survives a reindex and saves to the new record', (
      tester,
    ) async {
      final initial = _snapshot([
        'https://earlier.example/v1',
        'https://target.example/v1',
      ]);
      final reindexed = _snapshot(['https://target.example/v1']);
      final initialRecord = initial.records[1];
      final refreshed = reindexed.records.single;
      expect(refreshed.profile.id, initialRecord.profile.id);
      final updateStarted = Completer<void>();
      final releaseUpdate = Completer<void>();
      addTearDown(() {
        if (!releaseUpdate.isCompleted) releaseUpdate.complete();
      });
      final remote = DirectTestMutableOpenWebUiConnections(initial)
        ..updateHandler = () async {
          if (!updateStarted.isCompleted) updateStarted.complete();
          await releaseUpdate.future;
        };
      final rig = await _pump(tester, overrides: serverOverrides(remote));
      final id = initialRecord.profile.id;
      final key = _key(_server, id);
      final advanced = '$directConnectionAdvancedPagePrefix$key';
      await rig.open(_editor(_server, id));
      await rig.until(() => rig.rows(_editor(_server, id)).length > 1);
      await rig.open(advanced);
      await rig.change(directConnectionRowId('api-version', key), '2026-07-15');

      remote.setSnapshot(reindexed);
      await tester.pump();
      await rig.open(advanced);
      expect(
        rig.row(advanced, directConnectionRowId('api-version', key)).value,
        '2026-07-15',
      );

      final saving = rig.module.handleChange(
        directConnectionRowId('save', key),
        true,
        _l10n,
      );
      await rig.until(() => updateStarted.isCompleted);
      expect(remote.updateCalls, 1);
      expect(remote.lastUpdatedRecord?.index, refreshed.index);
      expect(remote.lastUpdatedRecord?.revision, refreshed.revision);
      expect(remote.lastUpdatedProfile?.apiVersion, '2026-07-15');
      releaseUpdate.complete();
      await rig.settle(saving);
    });

    testWidgets('a content edit elsewhere keeps the stale base for Save', (
      tester,
    ) async {
      final initial = _snapshot(
        ['https://target.example/v1'],
        configs: [
          {
            'auth_type': 'bearer',
            'enable': true,
            'tags': [
              {'name': 'initial'},
            ],
          },
        ],
      );
      final editedElsewhere = _snapshot(
        ['https://target.example/v1'],
        configs: [
          {
            'auth_type': 'bearer',
            'enable': true,
            'tags': [
              {'name': 'remote-edit'},
            ],
          },
        ],
      );
      final initialRecord = initial.records.single;
      final remote = DirectTestMutableOpenWebUiConnections(initial);
      final rig = await _pump(tester, overrides: serverOverrides(remote));
      final id = initialRecord.profile.id;
      final key = _key(_server, id);
      await rig.open(_editor(_server, id));
      await rig.until(() => rig.rows(_editor(_server, id)).length > 1);
      await rig.change(directConnectionRowId('api-version', key), 'draft');

      remote.setSnapshot(editedElsewhere);
      await tester.pump();
      await rig.change(directConnectionRowId('save', key));

      expect(remote.updateCalls, 1);
      expect(remote.lastUpdatedRecord?.revision, initialRecord.revision);
      expect(
        remote.lastUpdatedRecord?.contentRevision,
        initialRecord.contentRevision,
      );
    });

    testWidgets('a conflict after sign-in changed says unavailable', (
      tester,
    ) async {
      final snapshot = _snapshot(['https://provider.example/v1']);
      final updateStarted = Completer<void>();
      final releaseUpdate = Completer<void>();
      addTearDown(() {
        if (!releaseUpdate.isCompleted) releaseUpdate.complete();
      });
      final remote = DirectTestMutableOpenWebUiConnections(snapshot)
        ..updateHandler = () async {
          if (!updateStarted.isCompleted) updateStarted.complete();
          await releaseUpdate.future;
          throw OpenWebUiDirectConnectionConflictException(snapshot);
        };
      final epoch = NotifierProvider<DirectTestMutableAuthEpoch, Object>(
        DirectTestMutableAuthEpoch.new,
      );
      final rig = await _pump(
        tester,
        overrides: serverOverrides(remote, epoch: epoch),
      );
      final id = snapshot.records.single.profile.id;
      final key = _key(_server, id);
      await rig.open(_editor(_server, id));
      await rig.until(() => rig.rows(_editor(_server, id)).length > 1);
      await rig.change(directConnectionRowId('api-version', key), '2026-07-15');

      final saving = rig.module.handleChange(
        directConnectionRowId('save', key),
        true,
        _l10n,
      );
      await rig.until(() => updateStarted.isCompleted);
      rig.container.read(epoch.notifier).rotate();
      releaseUpdate.complete();
      await rig.settle(saving);

      final titles = rig.titles(_editor(_server, id));
      expect(titles, contains('Open WebUI connections are unavailable.'));
      expect(
        titles,
        isNot(
          contains(
            'This connection changed elsewhere. Reopen it before saving.',
          ),
        ),
      );
      expect(titles, isNot(contains('Could not save this connection.')));
    });

    testWidgets('unsupported sign-in blocks Test and Save but not Delete', (
      tester,
    ) async {
      final snapshot = _snapshot(
        [kOpenRouterApiBaseUrl],
        keys: ['must-not-be-forwarded'],
        configs: [
          {'auth_type': 'session'},
        ],
      );
      final remote = DirectTestMutableOpenWebUiConnections(snapshot);
      final rig = await _pump(tester, overrides: serverOverrides(remote));
      final id = snapshot.records.single.profile.id;
      final key = _key(_server, id);
      final page = _editor(_server, id);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);

      expect(
        rig.row(page, directConnectionRowId('test', key)).disabled,
        isTrue,
      );
      expect(
        rig.row(page, directConnectionRowId('delete', key)).disabled,
        isFalse,
      );
      expect(rig.footers(page), contains(contains('cannot safely use')));

      await rig.change(directConnectionRowId('save', key));
      expect(remote.updateCalls, 0);
      expect(rig.page(page).announcement, contains('cannot safely use'));
    });

    testWidgets('switching no sign-in to bearer asks for a key', (
      tester,
    ) async {
      final snapshot = _snapshot(
        [kOpenRouterApiBaseUrl],
        keys: [''],
        configs: [
          {'auth_type': 'none'},
        ],
      );
      final remote = DirectTestMutableOpenWebUiConnections(snapshot);
      final rig = await _pump(tester, overrides: serverOverrides(remote));
      final id = snapshot.records.single.profile.id;
      final key = _key(_server, id);
      final page = _editor(_server, id);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);
      expect(rig.row(page, directConnectionRowId('auth', key)).value, 'none');

      await rig.change(directConnectionRowId('auth', key), 'bearer');
      await rig.change(directConnectionRowId('save', key));

      expect(remote.updateCalls, 0);
      expect(
        rig.page(page).announcement,
        'Enter an API key or choose no authentication.',
      );
    });

    group('Delete', () {
      final snapshot = _snapshot(
        ['https://delete.example/v1'],
        keys: ['delete-secret'],
      );
      final id = snapshot.records.single.profile.id;
      final key = _key(_server, id);
      final page = _editor(_server, id);

      testWidgets('a sign-in change puts the backend back', (tester) async {
        final remote = DirectTestMutableOpenWebUiConnections(snapshot);
        final epoch = NotifierProvider<DirectTestMutableAuthEpoch, Object>(
          DirectTestMutableAuthEpoch.new,
        );
        final backend = DirectTestBlockingPreferredBackendController();
        addTearDown(backend.release);
        final rig = await _pump(
          tester,
          overrides: serverOverrides(
            remote,
            epoch: epoch,
            extra: [
              effectiveDirectConnectionProfilesFutureProvider.overrideWith(
                (ref) async => [snapshot.records.single.profile],
              ),
              preferredBackendProvider.overrideWith(() => backend),
            ],
          ),
        );
        await rig.open(page);
        await rig.until(() => rig.rows(page).length > 1);
        rig.surface.answer = 'delete';

        final deleting = rig.module.handleChange(
          directConnectionRowId('delete', key),
          true,
          _l10n,
        );
        await rig.until(() => backend.unsetStarted.isCompleted);
        rig.container.read(epoch.notifier).rotate();
        backend.release();
        await rig.settle(deleting);

        expect(remote.deleteCalls, 0);
        expect(backend.writes, [
          PreferredBackend.unset,
          PreferredBackend.direct,
        ]);
        expect(
          rig.container.read(preferredBackendProvider),
          PreferredBackend.direct,
        );
        expect(
          rig.titles(page),
          contains('Open WebUI connections are unavailable.'),
        );
        expect(
          rig.titles(page),
          isNot(contains('Could not delete this connection.')),
        );
      });

      testWidgets('one committed before sign-in changed stays cleared', (
        tester,
      ) async {
        final deleteStarted = Completer<void>();
        final releaseDelete = Completer<void>();
        addTearDown(() {
          if (!releaseDelete.isCompleted) releaseDelete.complete();
        });
        final remote = DirectTestMutableOpenWebUiConnections(snapshot)
          ..deleteHandler = () async {
            if (!deleteStarted.isCompleted) deleteStarted.complete();
            await releaseDelete.future;
          };
        final epoch = NotifierProvider<DirectTestMutableAuthEpoch, Object>(
          DirectTestMutableAuthEpoch.new,
        );
        final backend = DirectTestTrackingPreferredBackendController();
        final rig = await _pump(
          tester,
          overrides: serverOverrides(
            remote,
            epoch: epoch,
            extra: [
              effectiveDirectConnectionProfilesFutureProvider.overrideWith(
                (ref) async => [snapshot.records.single.profile],
              ),
              preferredBackendProvider.overrideWith(() => backend),
            ],
          ),
        );
        await rig.open(page);
        await rig.until(() => rig.rows(page).length > 1);
        rig.surface.answer = 'delete';

        final deleting = rig.module.handleChange(
          directConnectionRowId('delete', key),
          true,
          _l10n,
        );
        await rig.until(() => deleteStarted.isCompleted);
        expect(
          rig.container.read(preferredBackendProvider),
          PreferredBackend.unset,
        );
        rig.container.read(epoch.notifier).rotate();
        releaseDelete.complete();
        await rig.settle(deleting);

        expect(remote.deleteCalls, 1);
        expect(backend.writes, [PreferredBackend.unset]);
        expect(
          rig.container.read(preferredBackendProvider),
          PreferredBackend.unset,
        );
        expect(
          rig.titles(page),
          contains('Open WebUI connections are unavailable.'),
        );
      });

      testWidgets('an uncertain commit leaves the backend cleared', (
        tester,
      ) async {
        final remote = DirectTestMutableOpenWebUiConnections(snapshot)
          ..deleteHandler = () async {
            throw const OpenWebUiDirectConnectionCommitUncertainException();
          };
        final backend = DirectTestTrackingPreferredBackendController();
        final rig = await _pump(
          tester,
          overrides: serverOverrides(
            remote,
            extra: [
              effectiveDirectConnectionProfilesFutureProvider.overrideWith(
                (ref) async => [snapshot.records.single.profile],
              ),
              preferredBackendProvider.overrideWith(() => backend),
            ],
          ),
        );
        await rig.open(page);
        await rig.until(() => rig.rows(page).length > 1);
        rig.surface.answer = 'delete';

        await rig.change(directConnectionRowId('delete', key));

        expect(remote.deleteCalls, 1);
        expect(backend.writes, [PreferredBackend.unset]);
        expect(
          rig.page(page).announcement,
          'Could not delete this connection.',
        );
      });

      testWidgets('a sign-in change while providers are read stops it', (
        tester,
      ) async {
        final readStarted = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final remote = DirectTestMutableOpenWebUiConnections(snapshot);
        final epoch = NotifierProvider<DirectTestMutableAuthEpoch, Object>(
          DirectTestMutableAuthEpoch.new,
        );
        final rig = await _pump(
          tester,
          overrides: serverOverrides(
            remote,
            epoch: epoch,
            extra: [
              effectiveDirectConnectionProfilesFutureProvider.overrideWith((
                ref,
              ) async {
                if (!readStarted.isCompleted) readStarted.complete();
                await release.future;
                return [
                  snapshot.records.single.profile,
                  DirectConnectionProfile(
                    id: 'backup',
                    name: 'Backup',
                    adapterKey: kOpenAiCompatibleAdapterKey,
                    baseUrl: 'https://backup.example/v1',
                  ),
                ];
              }),
            ],
          ),
        );
        await rig.open(page);
        await rig.until(() => rig.rows(page).length > 1);
        rig.surface.answer = 'delete';

        final deleting = rig.module.handleChange(
          directConnectionRowId('delete', key),
          true,
          _l10n,
        );
        await rig.until(() => readStarted.isCompleted);
        rig.container.read(epoch.notifier).rotate();
        release.complete();
        await rig.settle(deleting);

        expect(remote.deleteCalls, 0);
      });
    });
  });

  group('MCP server editor', () {
    late DirectMcpServerStore store;

    Future<_Rig> pumpMcp(WidgetTester tester, {http.Client? client}) async {
      FlutterSecureStorage.setMockInitialValues({});
      store = DirectMcpServerStore(
        SecureCredentialStorage(instance: FlutterSecureKeyValueStore()),
      );
      final coordinator = DirectMcpOAuthCoordinator(
        store: store,
        client: client,
      );
      addTearDown(coordinator.close);
      return _pump(
        tester,
        overrides: [
          directMcpServerStoreProvider.overrideWithValue(store),
          directMcpOAuthCoordinatorProvider.overrideWithValue(coordinator),
        ],
      );
    }

    testWidgets('a new server saves and goes back', (tester) async {
      final rig = await pumpMcp(tester);
      const key = 'new';
      final page = directMcpPageId(null);
      final header = '$directMcpHeaderPagePrefix$key';
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);
      expect(rig.page(page).title, 'Add MCP Server');

      await rig.change(directMcpRowId('name', key), 'Tools');
      await rig.change(
        directMcpRowId('endpoint', key),
        'https://mcp.example/mcp',
      );
      await rig.open(header);
      await rig.change(directMcpRowId('header-name', key), 'X-Tenant');
      await rig.change(directMcpRowId('header-value', key), 'acme');
      await rig.change(directMcpRowId('header-add', key));
      expect(rig.closed, [header]);
      await rig.change(directMcpRowId('save', key));

      final saved = (await store.load()).single;
      expect(saved.name, 'Tools');
      expect(saved.customHeaders, {'X-Tenant': 'acme'});
      expect(rig.closed, [header, page]);
    });

    testWidgets('headers are checked on their own page, one row each', (
      tester,
    ) async {
      final rig = await pumpMcp(tester);
      final server = DirectMcpServer(
        id: 'headers-ui',
        name: 'Headers UI',
        endpoint: 'https://resource.example/mcp',
        customHeaders: const {'X-Tenant': 'acme'},
      );
      await store.upsert(server);
      final key = Uri.encodeComponent(server.id);
      final page = directMcpPageId(server.id);
      final header = '$directMcpHeaderPagePrefix$key';
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);

      final tenant = rig.row(page, directMcpRowId('header', key, 'X-Tenant'));
      expect(tenant.subtitle, 'acme');
      expect(rig.page(page).edited, isFalse);

      // Checked as a provider's are: a taken name, then a reserved one.
      await rig.open(header);
      await rig.change(directMcpRowId('header-name', key), 'x-tenant');
      await rig.change(directMcpRowId('header-add', key));
      expect(rig.page(header).announcement, contains('x-tenant'));
      await rig.change(directMcpRowId('header-name', key), 'Authorization');
      await rig.change(directMcpRowId('header-add', key));
      expect(rig.page(header).announcement, contains('Authorization'));
      expect(rig.closed, isEmpty);

      await rig.change(directMcpRowId('header-name', key), 'X-Region');
      await rig.change(directMcpRowId('header-value', key), 'eu');
      await rig.change(directMcpRowId('header-add', key));
      expect(rig.closed, [header]);
      expect(
        rig
            .rows(page)
            .where((row) => row.id.startsWith('direct-mcp.header:'))
            .map((row) => row.title),
        ['X-Tenant', 'X-Region'],
      );
      // Changed on the page it opened: leaving the server asks first.
      expect(rig.page(page).edited, isTrue);

      await rig.change(tenant.rowActions.single.id);
      expect(
        rig.rows(page).map((row) => row.id),
        isNot(contains(directMcpRowId('header', key, 'X-Tenant'))),
      );
      await rig.change(directMcpRowId('save', key));
      expect((await store.load()).single.customHeaders, {'X-Region': 'eu'});
    });

    testWidgets('OAuth shows no secrets, and disconnects', (tester) async {
      final rig = await pumpMcp(tester);
      final server = DirectMcpServer(
        id: 'oauth-ui',
        name: 'OAuth UI',
        endpoint: 'https://resource.example/mcp',
        authMode: DirectMcpAuthMode.oauth,
        oauthTokens: _oauthTokens('https://resource.example/mcp'),
      );
      await store.upsert(server);
      final page = directMcpPageId(server.id);
      final key = Uri.encodeComponent(server.id);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);

      final text = [
        for (final section in rig.page(page).sections) ...[
          ?section.footer,
          for (final row in section.items) ...[row.title, ?row.subtitle],
        ],
      ].join('\n');
      expect(text, contains('auth.example'));
      expect(text, contains('tools.read'));
      expect(text, isNot(contains('access-ui-secret')));
      expect(text, isNot(contains('refresh-ui-secret')));
      expect(rig.titles(page), contains('Reconnect in Browser'));

      await rig.change(directMcpRowId('oauth-disconnect', key));

      expect((await store.load()).single.oauthTokens, isNull);
      expect(rig.titles(page), contains('Connect in Browser'));
      expect(rig.titles(page), isNot(contains('Disconnect OAuth')));
    });

    testWidgets('a browser sign-in under way shows on the page, with Cancel', (
      tester,
    ) async {
      // The authorization server answers only once the test lets it.
      final answer = Completer<http.Response>();
      final rig = await pumpMcp(
        tester,
        client: MockClient((_) => answer.future),
      );
      final server = DirectMcpServer(
        id: 'oauth-wait',
        name: 'OAuth Wait',
        endpoint: 'https://resource.example/mcp',
        authMode: DirectMcpAuthMode.oauth,
      );
      await store.upsert(server);
      final page = directMcpPageId(server.id);
      final key = Uri.encodeComponent(server.id);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);

      final connecting = rig.module.handleChange(
        directMcpRowId('oauth-connect', key),
        true,
        _l10n,
      );
      await rig.until(
        () => rig
            .rows(page)
            .any((row) => row.id == directMcpRowId('oauth-cancel', key)),
      );
      expect(rig.page(page).announcement, _l10n.directMcpOAuthPending);

      // The sign-in runs on in the browser; it is let go here.
      answer.completeError(http.ClientException('offline'));
      await rig.settle(connecting);
    });

    testWidgets('a server removed elsewhere while its page is open says so', (
      tester,
    ) async {
      final rig = await pumpMcp(tester);
      final server = DirectMcpServer(
        id: 'gone',
        name: 'Gone',
        endpoint: 'https://resource.example/mcp',
      );
      await store.upsert(server);
      final page = directMcpPageId(server.id);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);

      await rig.settle(
        rig.container.read(directMcpServersProvider.notifier).remove(server.id),
      );
      await rig.until(() => rig.rows(page).length == 1);

      expect(rig.rows(page).single.title, _l10n.directMcpMissing);
    });

    testWidgets("a header an MCP server can't carry is refused as it is "
        'added', (tester) async {
      final rig = await pumpMcp(tester);
      const key = 'new';
      final header = '$directMcpHeaderPagePrefix$key';
      await rig.open(directMcpPageId(null));
      await rig.open(header);

      await rig.change(directMcpRowId('header-name', key), 'Connection');
      await rig.change(directMcpRowId('header-value', key), 'close');
      await rig.change(directMcpRowId('header-add', key));

      expect(rig.closed, isEmpty);
      expect(rig.page(header).announcement, contains('Connection'));
    });

    testWidgets('Save waits while a test asks its questions', (tester) async {
      final rig = await pumpMcp(tester);
      const key = 'new';
      final page = directMcpPageId(null);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);
      await rig.change(directMcpRowId('name', key), 'Tools');
      // A key sent unencrypted, so the test asks first.
      await rig.change(
        directMcpRowId('endpoint', key),
        'http://mcp.example/mcp',
      );
      await rig.change(directMcpRowId('auth', key), 'bearer');
      await rig.change(directMcpRowId('token', key), 'synthetic-token');

      final question = Completer<String?>();
      rig.surface.onAsk = (_) => question.future;
      final testing = rig.module.handleChange(
        directMcpRowId('test', key),
        true,
        _l10n,
      );
      await tester.pump();
      expect(rig.surface.asked, isNotEmpty);
      await rig.change(directMcpRowId('save', key));

      expect(await store.load(), isEmpty);
      question.complete(null);
      await rig.settle(testing);
    });

    testWidgets('the fields wait while a test runs', (tester) async {
      final rig = await pumpMcp(tester);
      const key = 'new';
      final page = directMcpPageId(null);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);
      await rig.change(directMcpRowId('name', key), 'Tools');
      await rig.change(
        directMcpRowId('endpoint', key),
        'https://mcp.example/mcp',
      );

      final testing = rig.module.handleChange(
        directMcpRowId('test', key),
        true,
        _l10n,
      );
      expect(rig.row(page, directMcpRowId('name', key)).disabled, isTrue);
      await rig.settle(testing);
      expect(rig.row(page, directMcpRowId('name', key)).disabled, isFalse);
    });

    testWidgets('remembered approvals are revoked one or all', (tester) async {
      final rig = await pumpMcp(tester);
      final server = DirectMcpServer(
        id: 'remembered-ui',
        name: 'Remembered UI',
        endpoint: 'https://resource.example/mcp',
        rememberedApprovals: [
          _approval('a', 'lookup', 'Lookup'),
          _approval('b', 'search', 'Search'),
        ],
      );
      await store.upsert(server);
      final page = directMcpPageId(server.id);
      final key = Uri.encodeComponent(server.id);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);

      final lookup = rig.rows(page).singleWhere((row) => row.title == 'Lookup');
      expect(lookup.rowActions.single.label, 'Revoke');
      expect(rig.titles(page).join(), isNot(contains('a' * 64)));
      await rig.change(lookup.rowActions.single.id);
      expect((await store.load()).single.rememberedApprovals, hasLength(1));

      await rig.change(directMcpRowId('approvals-revoke-all', key));
      expect((await store.load()).single.rememberedApprovals, isEmpty);
      expect(
        rig.page(page).sections.map((section) => section.title),
        isNot(contains('Always Allowed Tools')),
      );
    });

    testWidgets('Save drops credentials when a move is declined', (
      tester,
    ) async {
      final rig = await pumpMcp(tester);
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
      final page = directMcpPageId(server.id);
      final key = Uri.encodeComponent(server.id);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);
      rig.surface.answer = 'cancel';

      await rig.change(
        directMcpRowId('endpoint', key),
        'http://127.0.0.1:1/other-mcp',
      );
      await rig.change(directMcpRowId('save', key));

      expect(rig.surface.asked, ['Use credentials with new server?']);
      final persisted = (await store.load()).single;
      expect(persisted.endpoint, 'http://127.0.0.1:1/other-mcp');
      expect(persisted.authMode, DirectMcpAuthMode.none);
      expect(persisted.bearerToken, isNull);
      expect(persisted.customHeaders, isEmpty);
    });

    testWidgets('a server page whose servers cannot be read offers Retry, '
        'which reads them again', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      store = DirectMcpServerStore(
        SecureCredentialStorage(instance: FlutterSecureKeyValueStore()),
      );
      // The first read fails; a read made again goes to the store.
      final rig = await _pump(
        tester,
        overrides: [
          directMcpServerStoreProvider.overrideWithValue(store),
          directMcpServersProvider.overrideWithBuild(
            (ref, _) async => throw StateError('locked'),
          ),
        ],
      );
      const key = 'new';
      final page = directMcpPageId(null);
      await rig.open(page);
      await rig.until(
        () =>
            rig.rows(page).any((row) => row.title == _l10n.directMcpLoadFailed),
      );
      expect(
        rig.rows(page).map((row) => row.id),
        contains(directMcpRowId('retry', key)),
      );

      await rig.change(directMcpRowId('retry', key));
      await rig.until(() => rig.rows(page).length > 2);

      expect(
        rig.rows(page).map((row) => row.title),
        isNot(contains(_l10n.directMcpLoadFailed)),
      );
    });

    testWidgets('a browser sign-in after the address changed asks before '
        'taking credentials along', (tester) async {
      final rig = await pumpMcp(
        tester,
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      final server = DirectMcpServer(
        id: 'oauth-move',
        name: 'OAuth Move',
        endpoint: 'https://resource.example/mcp',
        authMode: DirectMcpAuthMode.oauth,
        customHeaders: const {'X-Tenant': 'tenant-secret'},
      );
      await store.upsert(server);
      final page = directMcpPageId(server.id);
      final key = Uri.encodeComponent(server.id);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);
      rig.surface.answer = 'cancel';

      await rig.change(
        directMcpRowId('endpoint', key),
        'https://resource.example/other-mcp',
      );
      // The sign-in itself fails in the browser step; the server is saved
      // before it, which is what this checks.
      await rig.settle(
        rig.module.handleChange(
          directMcpRowId('oauth-connect', key),
          true,
          _l10n,
        ),
      );

      expect(rig.surface.asked, contains('Use credentials with new server?'));
      final persisted = (await store.load()).single;
      expect(persisted.endpoint, 'https://resource.example/other-mcp');
      expect(persisted.customHeaders, isEmpty);
    });

    testWidgets('Delete asks, then goes back', (tester) async {
      final rig = await pumpMcp(tester);
      final server = DirectMcpServer(
        id: 'gone',
        name: 'Gone',
        endpoint: 'https://resource.example/mcp',
      );
      await store.upsert(server);
      final page = directMcpPageId(server.id);
      await rig.open(page);
      await rig.until(() => rig.rows(page).length > 1);

      rig.surface.answer = 'cancel';
      await rig.change(directMcpRowId('delete', 'gone'));
      expect(await store.load(), hasLength(1));

      rig.surface.answer = 'delete';
      await rig.change(directMcpRowId('delete', 'gone'));
      expect(await store.load(), isEmpty);
      expect(rig.surface.asked, ['Delete MCP server?', 'Delete MCP server?']);
      expect(rig.closed, [page]);
    });
  });
}

void _background(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _foreground(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
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

DirectMcpOAuthTokens _oauthTokens(String resource) => DirectMcpOAuthTokens(
  accessToken: 'access-ui-secret',
  refreshToken: 'refresh-ui-secret',
  grantedScope: 'tools.read',
  expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  authorizationServerIssuer: 'https://auth.example/issuer',
  resource: resource,
  clientId: 'public-ui-client',
  tokenEndpoint: 'https://auth.example/token',
);

DirectMcpRememberedApproval _approval(
  String seed,
  String remoteName,
  String displayName,
) => DirectMcpRememberedApproval(
  digest: seed * 64,
  remoteToolName: remoteName,
  displayName: displayName,
  createdAt: DateTime.utc(2026),
);
