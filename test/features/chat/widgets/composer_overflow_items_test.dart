import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/services/ios_keyboard_attachment_bridge.dart';
import 'package:conduit/features/chat/widgets/composer_overflow_items.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/testing.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _serverModel = Model(id: 'server-model', name: 'Server');

const _toggleFilter = ToggleFilter(
  id: 'test-toggle-filter',
  name: 'Test Toggle Filter',
  description: 'Adds a test system instruction.',
);

void main() {
  final l10n = AppLocalizationsEn();

  test('shared overflow items include selected model filters', () {
    final items = buildComposerOverflowItems(
      l10n: l10n,
      attachmentAvailability: const ComposerOverflowAttachmentAvailability(),
      webSearchAvailable: false,
      webSearchEnabled: false,
      imageGenerationAvailable: false,
      imageGenerationEnabled: false,
      availableTools: const [],
      selectedToolIds: const [],
      availableFilters: const [_toggleFilter],
      selectedFilterIds: const ['test-toggle-filter'],
    );

    final item = items.singleWhere(
      (candidate) =>
          candidate.id ==
          ComposerOverflowActionIds.filter('test-toggle-filter'),
    );
    expect(item.kind, ComposerOverflowItemKind.toggle);
    expect(item.section, ComposerOverflowSection.filters);
    expect(item.label, 'Test Toggle Filter');
    expect(item.subtitle, 'Adds a test system instruction.');
    expect(item.selected, isTrue);
    expect(item.dismissesKeyboard, isFalse);
  });

  test('iOS action configuration includes filters for OpenWebUI models', () {
    final actions = buildIosKeyboardAttachmentActions(
      l10n: l10n,
      attachmentAvailability: const ComposerOverflowAttachmentAvailability(),
      hermesMode: false,
      directMode: false,
      webSearchAvailable: false,
      webSearchEnabled: false,
      imageGenerationAvailable: false,
      imageGenerationEnabled: false,
      availableTools: const [],
      selectedToolIds: const [],
      availableFilters: const [_toggleFilter],
      selectedFilterIds: const ['test-toggle-filter'],
    );

    final action = actions.singleWhere(
      (candidate) =>
          candidate.id ==
          ComposerOverflowActionIds.filter('test-toggle-filter'),
    );
    expect(action.label, 'Test Toggle Filter');
    expect(action.section, 'filters');
    expect(action.selected, isTrue);
    expect(action.dismissesKeyboard, isFalse);
  });

  test('iOS action configuration keeps direct and Hermes restrictions', () {
    const attachmentAvailability = ComposerOverflowAttachmentAvailability(
      file: true,
      serverFile: true,
      photo: true,
      camera: true,
      web: true,
    );

    List<String> actionIds({
      required bool hermesMode,
      required bool directMode,
    }) {
      return buildIosKeyboardAttachmentActions(
        l10n: l10n,
        attachmentAvailability: attachmentAvailability,
        hermesMode: hermesMode,
        directMode: directMode,
        webSearchAvailable: true,
        webSearchEnabled: true,
        imageGenerationAvailable: true,
        imageGenerationEnabled: true,
        availableTools: const [],
        selectedToolIds: const [],
        availableFilters: const [_toggleFilter],
        selectedFilterIds: const ['test-toggle-filter'],
        // Personal valves are an Open WebUI feature, even when offered.
        toolSettingsAvailable: true,
      ).map((action) => action.id).toList();
    }

    expect(actionIds(hermesMode: false, directMode: true), [
      ComposerOverflowActionIds.file,
      ComposerOverflowActionIds.photo,
      ComposerOverflowActionIds.camera,
      ComposerOverflowActionIds.webSearch,
      ComposerOverflowActionIds.imageGeneration,
    ]);
    expect(actionIds(hermesMode: true, directMode: false), [
      ComposerOverflowActionIds.file,
      ComposerOverflowActionIds.photo,
      ComposerOverflowActionIds.camera,
    ]);
  });

  test('iOS menu offers Tool settings as a command in the tools section', () {
    List<IosKeyboardAttachmentActionConfig> actions({required bool available}) {
      return buildIosKeyboardAttachmentActions(
        l10n: l10n,
        attachmentAvailability: const ComposerOverflowAttachmentAvailability(),
        hermesMode: false,
        directMode: false,
        webSearchAvailable: false,
        webSearchEnabled: false,
        imageGenerationAvailable: false,
        imageGenerationEnabled: false,
        availableTools: const [],
        selectedToolIds: const [],
        availableFilters: const [],
        selectedFilterIds: const [],
        toolSettingsAvailable: available,
      );
    }

    expect(
      actions(available: false).map((action) => action.id),
      isNot(contains(ComposerOverflowActionIds.toolSettings)),
    );
    final action = actions(available: true)
        .singleWhere((a) => a.id == ComposerOverflowActionIds.toolSettings);
    // The native panel renders rows by section and sends this id back, which
    // the composer routes to the same handler as the Flutter panel's tile.
    expect(action.section, 'tools');
    expect(action.label, 'Tool settings');
    expect(action.selected, isFalse);
    expect(action.dismissesKeyboard, isTrue);
  });

  group('code interpreter action', () {
    const usable = (selected: false, block: null);
    const active = (selected: true, block: null);
    const browserEngine = (
      selected: false,
      block: CodeInterpreterBlock.unsupportedEngine,
    );
    const revoked = (selected: true, block: CodeInterpreterBlock.noPermission);

    List<ComposerOverflowItem> flutterItems(CodeInterpreterOffer? offer) =>
        buildComposerOverflowItems(
              l10n: l10n,
              attachmentAvailability:
                  const ComposerOverflowAttachmentAvailability(),
              webSearchAvailable: false,
              webSearchEnabled: false,
              imageGenerationAvailable: false,
              imageGenerationEnabled: false,
              availableTools: const [],
              selectedToolIds: const [],
              availableFilters: const [],
              selectedFilterIds: const [],
              codeInterpreter: offer,
            )
            .where(
              (item) => item.id == ComposerOverflowActionIds.codeInterpreter,
            )
            .toList();

    List<IosKeyboardAttachmentActionConfig> nativeActions(
      CodeInterpreterOffer? offer, {
      bool hermesMode = false,
      bool directMode = false,
    }) => buildIosKeyboardAttachmentActions(
      l10n: l10n,
      attachmentAvailability: const ComposerOverflowAttachmentAvailability(),
      hermesMode: hermesMode,
      directMode: directMode,
      webSearchAvailable: false,
      webSearchEnabled: false,
      imageGenerationAvailable: false,
      imageGenerationEnabled: false,
      availableTools: const [],
      selectedToolIds: const [],
      availableFilters: const [],
      selectedFilterIds: const [],
      codeInterpreter: offer,
    ).where((a) => a.id == ComposerOverflowActionIds.codeInterpreter).toList();

    // What each surface must say for each state, written out rather than read
    // back from the builder: the native presenter shows exactly these rows.
    const description =
        'Run code on the server to analyze data and make files.';
    const browserExplanation =
        "This server runs code in the browser, which Conduit can't do.";
    const unavailableExplanation =
        "The code interpreter isn't available for this server, account, or "
        'model.';
    final states =
        <
          String,
          ({
            CodeInterpreterOffer offer,
            String subtitle,
            bool selected,
            bool enabled,
          })
        >{
          'usable': (
            offer: usable,
            subtitle: description,
            selected: false,
            enabled: true,
          ),
          'chosen': (
            offer: active,
            subtitle: description,
            selected: true,
            enabled: true,
          ),
          // A browser-engine server is explained, never offered.
          'on a browser-engine server': (
            offer: browserEngine,
            subtitle: browserExplanation,
            selected: false,
            enabled: false,
          ),
          // A choice that no longer holds can still be turned off.
          'chosen but no longer allowed': (
            offer: revoked,
            subtitle: unavailableExplanation,
            selected: true,
            enabled: true,
          ),
        };

    for (final MapEntry(:key, :value) in states.entries) {
      test('is one features row, $key, in both menus', () {
        final item = flutterItems(value.offer).single;
        expect(item.label, 'Code interpreter');
        expect(item.section, ComposerOverflowSection.features);
        expect(item.subtitle, value.subtitle);
        expect(item.selected, value.selected);
        expect(item.enabled, value.enabled);

        final action = nativeActions(value.offer).single;
        expect(action.id, 'codeInterpreter');
        expect(action.label, 'Code interpreter');
        expect(action.section, 'features');
        expect(action.sfSymbol, 'chevron.left.forwardslash.chevron.right');
        expect(action.subtitle, value.subtitle);
        expect(action.selected, value.selected);
        expect(action.enabled, value.enabled);
        expect(action.dismissesKeyboard, isFalse);
      });
    }

    test(
      'is absent without an offer, and never offered to Direct or Hermes',
      () {
        expect(flutterItems(null), isEmpty);
        expect(nativeActions(null), isEmpty);
        expect(nativeActions(usable, directMode: true), isEmpty);
        expect(nativeActions(usable, hermesMode: true), isEmpty);
        expect(nativeActions(usable), hasLength(1));
      },
    );

    testWidgets('toggles the selection through the shared action', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          selectedModelProvider.overrideWith(() => _SeededModel(_serverModel)),
          ..._signedOut,
          codeInterpreterBlockProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      late WidgetRef ref;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, widgetRef, child) {
              ref = widgetRef;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      toggleComposerOverflowSelection(
        ref,
        ComposerOverflowActionIds.codeInterpreter,
      );
      expect(container.read(codeInterpreterEnabledProvider), isTrue);
      expect(
        composerOverflowSelectionState(
          ref,
          ComposerOverflowActionIds.codeInterpreter,
        ),
        isTrue,
      );

      toggleComposerOverflowSelection(
        ref,
        ComposerOverflowActionIds.codeInterpreter,
      );
      expect(container.read(codeInterpreterEnabledProvider), isFalse);
    });

    testWidgets('cannot be switched on where the server does not run it', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          selectedModelProvider.overrideWith(() => _SeededModel(_serverModel)),
          ..._signedOut,
          codeInterpreterBlockProvider.overrideWithValue(
            CodeInterpreterBlock.unsupportedEngine,
          ),
        ],
      );
      addTearDown(container.dispose);
      late WidgetRef ref;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, widgetRef, child) {
              ref = widgetRef;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      setComposerOverflowSelection(
        ref,
        actionId: ComposerOverflowActionIds.codeInterpreter,
        selected: true,
      );

      expect(container.read(codeInterpreterEnabledProvider), isFalse);
    });

    group('in the composer', () {
      Future<ProviderContainer> pump(
        WidgetTester tester, {
        required CodeInterpreterBlock? block,
        bool advanced = true,
        Model? model,
      }) async {
        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              selectedModelProvider.overrideWith(
                () => _SeededModel(model ?? _serverModel),
              ),
              apiServiceProvider.overrideWithValue(_Api()),
              authTokenProvider3.overrideWithValue('token'),
              isAuthenticatedProvider2.overrideWithValue(true),
              appSettingsProvider.overrideWith(
                () => _Settings(AppSettings(advancedFeaturesEnabled: advanced)),
              ),
              isChatStreamingProvider.overrideWithValue(false),
              webSearchAvailableProvider.overrideWithValue(false),
              imageGenerationAvailableProvider.overrideWithValue(false),
              toolsListProvider.overrideWith(_NoTools.new),
              userPermissionsProvider.overrideWith(
                (ref) async => const <String, dynamic>{},
              ),
              codeInterpreterBlockProvider.overrideWithValue(block),
            ],
            child: MaterialApp(
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    container = ProviderScope.containerOf(context);
                    return ModernChatInput(
                      onSendMessage: (_) {},
                      onFileAttachment: () {},
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        return container;
      }

      Future<void> openPanel(WidgetTester tester) async {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
      }

      testWidgets(
        'with Advanced off, the panel row selects it, and the panel and '
        'composer show it',
        (tester) async {
          final container = await pump(tester, block: null, advanced: false);
          await openPanel(tester);

          expect(find.text('Code interpreter'), findsOneWidget);
          await tester.tap(find.text('Code interpreter'));
          await tester.pumpAndSettle();
          expect(container.read(codeInterpreterEnabledProvider), isTrue);

          // The panel's check mark and the composer's own indicator both show it.
          expect(find.byIcon(Icons.check_rounded), findsOneWidget);
          expect(find.byIcon(Icons.code), findsWidgets);
        },
      );

      testWidgets('a chosen interpreter stays in view and turns off there', (
        tester,
      ) async {
        final container = await pump(tester, block: null);
        container.read(codeInterpreterEnabledProvider.notifier).set(true);
        await tester.pump();

        final pill = find.widgetWithText(GestureDetector, 'Code interpreter');
        expect(pill, findsWidgets);
        await tester.tap(find.text('Code interpreter').first);
        await tester.pump();

        expect(container.read(codeInterpreterEnabledProvider), isFalse);
        expect(find.text('Code interpreter'), findsNothing);
      });

      testWidgets('a browser-engine server is explained and cannot be chosen', (
        tester,
      ) async {
        final container = await pump(
          tester,
          block: CodeInterpreterBlock.unsupportedEngine,
        );
        await openPanel(tester);

        expect(
          find.text(
            "This server runs code in the browser, which Conduit can't do.",
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Code interpreter'));
        await tester.pumpAndSettle();

        expect(container.read(codeInterpreterEnabledProvider), isFalse);
      });

      testWidgets('a browser-engine server is explained only with Advanced on', (
        tester,
      ) async {
        await pump(
          tester,
          block: CodeInterpreterBlock.unsupportedEngine,
          advanced: false,
        );
        await openPanel(tester);

        expect(find.text('Code interpreter'), findsNothing);
      });

      testWidgets('Hermes never shows it', (tester) async {
        final container = await pump(
          tester,
          block: null,
          model: hermesSyntheticModel(),
        );
        container.read(codeInterpreterEnabledProvider.notifier).set(true);
        await tester.pump();

        expect(find.text('Code interpreter'), findsNothing);
      });
    });
  });

  testWidgets('filter actions update selected filter state', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    late WidgetRef ref;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, widgetRef, child) {
            ref = widgetRef;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    toggleComposerOverflowSelection(
      ref,
      ComposerOverflowActionIds.filter('test-toggle-filter'),
    );
    expect(container.read(selectedFilterIdsProvider), ['test-toggle-filter']);

    setComposerOverflowSelection(
      ref,
      actionId: ComposerOverflowActionIds.filter('test-toggle-filter'),
      selected: false,
    );
    expect(container.read(selectedFilterIdsProvider), isEmpty);
  });

  testWidgets('local MCP and provider features are mutually exclusive', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    late WidgetRef ref;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, widgetRef, child) {
            ref = widgetRef;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    container.read(imageGenerationEnabledProvider.notifier).set(true);
    container.read(webSearchEnabledProvider.notifier).set(true);
    setComposerOverflowSelection(
      ref,
      actionId: ComposerOverflowActionIds.tool('local_mcp:home'),
      selected: true,
    );
    expect(container.read(selectedToolIdsProvider), ['local_mcp:home']);
    expect(container.read(imageGenerationEnabledProvider), isFalse);
    expect(container.read(webSearchEnabledProvider), isFalse);

    setComposerOverflowSelection(
      ref,
      actionId: ComposerOverflowActionIds.imageGeneration,
      selected: true,
    );
    expect(container.read(selectedToolIdsProvider), isEmpty);
  });

  group('native personal connections', _nativePersonalConnectionTests);

  group('Compare models command', () {
    List<ComposerOverflowItem> items({required bool available}) =>
        buildComposerOverflowItems(
          l10n: l10n,
          attachmentAvailability:
              const ComposerOverflowAttachmentAvailability(),
          webSearchAvailable: false,
          webSearchEnabled: false,
          imageGenerationAvailable: false,
          imageGenerationEnabled: false,
          availableTools: const [],
          selectedToolIds: const [],
          availableFilters: const [],
          selectedFilterIds: const [],
          compareModelsAvailable: available,
        );

    List<IosKeyboardAttachmentActionConfig> nativeActions({
      required bool available,
      bool hermes = false,
      bool direct = false,
    }) => buildIosKeyboardAttachmentActions(
      l10n: l10n,
      attachmentAvailability: const ComposerOverflowAttachmentAvailability(
        file: true,
      ),
      hermesMode: hermes,
      directMode: direct,
      webSearchAvailable: false,
      webSearchEnabled: false,
      imageGenerationAvailable: false,
      imageGenerationEnabled: false,
      availableTools: const [],
      selectedToolIds: const [],
      availableFilters: const [],
      selectedFilterIds: const [],
      compareModelsAvailable: available,
    );

    test('is an action row only when the command is available', () {
      expect(
        items(
          available: false,
        ).any((item) => item.id == ComposerOverflowActionIds.compareModels),
        isFalse,
      );
      final item = items(
        available: true,
      ).singleWhere((item) => item.id == ComposerOverflowActionIds.compareModels);
      expect(item.kind, ComposerOverflowItemKind.action);
      expect(item.section, ComposerOverflowSection.features);
      expect(item.selected, isFalse);
      expect(item.label, l10n.chatCompareModelsAction);
    });

    test('reaches the native iOS panel under the id the composer handles', () {
      final action = nativeActions(
        available: true,
      ).singleWhere((action) => action.id == ComposerOverflowActionIds.compareModels);
      expect(action.section, 'features');
      expect(action.selected, isFalse);
      expect(action.label, l10n.chatCompareModelsAction);
      expect(
        nativeActions(
          available: false,
        ).any((action) => action.id == ComposerOverflowActionIds.compareModels),
        isFalse,
      );
    });

    test('is never offered for Hermes or Direct models', () {
      for (final actions in [
        nativeActions(available: true, hermes: true),
        nativeActions(available: true, direct: true),
      ]) {
        expect(
          actions.any(
            (action) => action.id == ComposerOverflowActionIds.compareModels,
          ),
          isFalse,
        );
      }
    });
  });
}

const _server = ServerConfig(
  id: 'server-1',
  name: 'Home server',
  url: 'https://owui.example',
);
const _boxUrl = 'https://box.example:8443/term?token=terminal-secret';
const _labUrl = 'https://lab.example/term?token=terminal-secret';

final class _AccountEpoch extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state += 1;
}

final _accountEpoch = NotifierProvider<_AccountEpoch, int>(_AccountEpoch.new);

Map<String, dynamic> _toolServer(
  String name, {
  String? id,
  bool enabled = true,
  String? url,
}) => <String, dynamic>{
  'type': 'openapi',
  'url': url ?? 'https://${name.toLowerCase()}.example/api?token=secret-$name',
  'spec_type': 'url',
  'path': 'openapi.json',
  'auth_type': 'bearer',
  'key': 'secret-$name',
  'config': <String, dynamic>{'enable': enabled},
  'info': <String, dynamic>{'id': ?id, 'name': name, 'description': ''},
};

Map<String, dynamic> _terminalEntry(String url, String name) =>
    <String, dynamic>{
      'url': url,
      'key': 'terminal-secret',
      'name': name,
      'path': '/openapi.json',
      'enabled': false,
      'config': <String, dynamic>{},
    };

TerminalServerInfo _terminal(String url, String name) => TerminalServerInfo(
  kind: TerminalServerKind.direct,
  selectionId: url,
  baseUrl: Uri.parse(url),
  name: name,
);

/// The tool servers account A starts with: two keyed, one of them switched
/// off, and two that never had an id.
List<dynamic> _accountATools() => <dynamic>[
  _toolServer('Alpha', id: 'alpha'),
  _toolServer('Off', id: 'off', enabled: false),
  _toolServer('Bare'),
  _toolServer('Other'),
];

void _nativePersonalConnectionTests() {
  final l10n = AppLocalizationsEn();
  const plainTool = Tool(id: 'tool-x', name: 'Plain tool');

  late FakeUserSettingsServer settings;
  late ApiService api;
  late ProviderContainer container;
  late WidgetRef ref;

  Future<void> start(WidgetTester tester) async {
    // Both accounts own a tool server keyed `alpha` and a terminal at the same
    // URL, so only the owner tells a stale tap from a current one.
    settings = FakeUserSettingsServer(const <String, dynamic>{})
      ..addAccount('token-a', <String, dynamic>{
        'ui': <String, dynamic>{
          'toolServers': _accountATools(),
          'terminalServers': <dynamic>[
            _terminalEntry(_boxUrl, 'Build box'),
            _terminalEntry(_labUrl, 'Lab'),
          ],
        },
      })
      ..addAccount('token-b', <String, dynamic>{
        'ui': <String, dynamic>{
          'toolServers': <dynamic>[_toolServer('B alpha', id: 'alpha')],
          'terminalServers': <dynamic>[_terminalEntry(_boxUrl, 'Build box')],
        },
      });
    // The service queues its settings writes on a future made at construction,
    // so it is built on the real clock the requests run on.
    api = (await tester.runAsync(
      () async => ApiService(
        serverConfig: _server,
        workerManager: WorkerManager(),
        authToken: 'token-a',
      ),
    ))!;
    api.dio.httpClientAdapter = settings;
    container = ProviderContainer(
      overrides: [
        personalConnectionsSessionProvider.overrideWith((ref) {
          final epoch = ref.watch(_accountEpoch);
          return PersonalConnectionsSession(
            api: api,
            authSnapshot: api.captureAuthSnapshot(),
            accountName: epoch == 0 ? 'A' : 'B',
            isCurrent: () => ref.mounted && ref.read(_accountEpoch) == epoch,
          );
        }),
        terminalServiceProvider.overrideWith((ref) {
          ref.watch(_accountEpoch);
          return TerminalService(api);
        }),
        terminalAvailableServersProvider.overrideWith((ref) async {
          final epoch = ref.watch(_accountEpoch);
          return <TerminalServerInfo>[
            _terminal(_boxUrl, 'Build box'),
            if (epoch == 0) _terminal(_labUrl, 'Lab'),
          ];
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, widgetRef, child) {
            ref = widgetRef;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }

  /// The connections once the signed-in account's settings and terminals
  /// have resolved.
  Future<ComposerPersonalConnections> load(WidgetTester tester) async {
    final connections = await tester.runAsync(() async {
      await container.read(personalConnectionsProvider.future);
      await container.read(terminalAvailableServersProvider.future);
      return readComposerPersonalConnections(container.read);
    });
    return connections!;
  }

  /// The panel configuration for the account that is signed in now.
  List<IosKeyboardAttachmentActionConfig> panel({
    bool directMode = false,
    bool hermesMode = false,
  }) {
    return buildIosKeyboardAttachmentActions(
      l10n: l10n,
      attachmentAvailability: const ComposerOverflowAttachmentAvailability(),
      hermesMode: hermesMode,
      directMode: directMode,
      webSearchAvailable: false,
      webSearchEnabled: false,
      imageGenerationAvailable: false,
      imageGenerationEnabled: false,
      availableTools: const [plainTool],
      selectedToolIds: container.read(selectedToolIdsProvider),
      availableFilters: const [],
      selectedFilterIds: const [],
      connections: readComposerPersonalConnections(container.read),
    );
  }

  String idOf(List<IosKeyboardAttachmentActionConfig> actions, String label) =>
      actions.singleWhere((action) => action.label == label).id;

  List<String> toolLabels(List<IosKeyboardAttachmentActionConfig> actions) => [
    for (final action in actions)
      if (action.section == 'tools') action.label,
  ];

  Set<String> selectedLabels(List<IosKeyboardAttachmentActionConfig> actions) =>
      <String>{
        for (final action in actions)
          if (action.selected) action.label,
      };

  /// A tap as the iOS panel sends it: through the Pigeon channel into the
  /// bridge, then applied the way the composer applies it.
  Future<void> tap(
    WidgetTester tester,
    String id, {
    required ComposerConnectionsOwner opened,
  }) async {
    await tester.runAsync(() async {
      final bridge = IosKeyboardAttachmentBridge.instance;
      final received = bridge.events.first;
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'dev.flutter.pigeon.conduit.NativeKeyboardAttachmentFlutterApi.onAction',
        NativeKeyboardAttachmentFlutterApi.pigeonChannelCodec.encodeMessage(
          <Object?>[PlatformKeyboardAttachmentActionEvent(id: id)],
        ),
        (_) {},
      );
      final event = await received as IosKeyboardAttachmentAction;
      expect(event.id, id);
      expect(isComposerConnectionAction(event.id), isTrue);
      await toggleComposerConnectionSelection(ref, event.id, opened: opened);
    });
  }

  testWidgets('tools panel offers usable personal connections and no secrets', (
    tester,
  ) async {
    await start(tester);
    await load(tester);
    final actions = panel();

    // The switched-off server is not offered; the others follow the ordinary
    // tools, in the tools section the native panel already renders.
    expect(toolLabels(actions), [
      'Plain tool',
      'Alpha',
      'Bare',
      'Other',
      'Build box',
      'Lab',
    ]);
    expect(selectedLabels(actions), isEmpty);
    for (final action in actions) {
      final text = '${action.id} ${action.subtitle}';
      expect(text, isNot(contains('secret')));
      expect(text, isNot(contains('token=')));
    }
    expect(
      actions.singleWhere((a) => a.label == 'Build box').subtitle,
      'box.example:8443/term',
    );

    // Direct and Hermes composers have no Open WebUI account behind them.
    for (final restricted in [
      panel(directMode: true),
      panel(hermesMode: true),
    ]) {
      expect(toolLabels(restricted), isNot(contains('Alpha')));
      expect(toolLabels(restricted), isNot(contains('Build box')));
    }
  });

  testWidgets('native taps select and clear a tool server and a terminal', (
    tester,
  ) async {
    await start(tester);
    container.read(selectedToolIdsProvider.notifier).set(['tool-x']);
    container.read(selectedFilterIdsProvider.notifier).set(['filter-1']);
    final connections = await load(tester);
    final opened = connections.owner;

    await tap(tester, idOf(panel(), 'Alpha'), opened: opened);
    expect(container.read(selectedToolIdsProvider), [
      'tool-x',
      'direct_server:alpha',
    ]);
    expect(selectedLabels(panel()), {'Plain tool', 'Alpha'});

    await tap(tester, idOf(panel(), 'Alpha'), opened: opened);
    expect(container.read(selectedToolIdsProvider), ['tool-x']);
    expect(container.read(selectedFilterIdsProvider), ['filter-1']);

    await tap(tester, idOf(panel(), 'Build box'), opened: opened);
    expect(container.read(selectedTerminalIdProvider), _boxUrl);
    // One terminal at a time: Lab replaces Build box, and the saved terminal
    // flags follow.
    await tap(tester, idOf(panel(), 'Lab'), opened: opened);
    expect(container.read(selectedTerminalIdProvider), _labUrl);
    expect(selectedLabels(panel()), {'Plain tool', 'Lab'});
    final saved =
        (settings.settingsOf('token-a')['ui'] as Map)['terminalServers']
            as List;
    expect([for (final t in saved) (t as Map)['enabled']], [false, true]);

    await tap(tester, idOf(panel(), 'Lab'), opened: opened);
    expect(container.read(selectedTerminalIdProvider), isNull);
  });

  final staleTools = <String, void Function(List<dynamic> tools)>{
    'switched off': (tools) =>
        (tools[0] as Map)['config'] = <String, dynamic>{'enable': false},
    'removed': (tools) => tools.removeAt(0),
  };
  for (final entry in staleTools.entries) {
    testWidgets('a tool server ${entry.key} after the panel opened is not '
        'selected', (tester) async {
      await start(tester);
      final connections = await load(tester);
      final alpha = idOf(panel(), 'Alpha');

      final ui = settings.settingsOf('token-a')['ui'] as Map;
      entry.value(ui['toolServers'] as List);
      container.invalidate(personalConnectionsProvider);
      await load(tester);

      await tap(tester, alpha, opened: connections.owner);
      expect(container.read(selectedToolIdsProvider), isEmpty);
    });
  }

  testWidgets('a keyless tool server that changed is not selected, one that '
      'moved is', (tester) async {
    await start(tester);
    final connections = await load(tester);
    final bare = idOf(panel(), 'Bare');
    final other = idOf(panel(), 'Other');

    // Bare points somewhere else now; its old id names no entry.
    final ui = settings.settingsOf('token-a')['ui'] as Map;
    final tools = ui['toolServers'] as List;
    (tools[2] as Map)['url'] = 'https://elsewhere.example';
    container.invalidate(personalConnectionsProvider);
    await load(tester);
    await tap(tester, bare, opened: connections.owner);
    expect(container.read(selectedToolIdsProvider), isEmpty);

    // Other moves up one place and is the same server there.
    tools
      ..clear()
      ..addAll(_accountATools());
    tools.insert(2, tools.removeAt(3));
    container.invalidate(personalConnectionsProvider);
    await load(tester);
    await tap(tester, other, opened: connections.owner);
    expect(selectedLabels(panel()), {'Other'});
  });

  testWidgets('a tap from the previous account selects nothing for the next', (
    tester,
  ) async {
    await start(tester);
    final connectionsA = await load(tester);
    final panelA = panel();
    final alphaA = idOf(panelA, 'Alpha');
    final boxA = idOf(panelA, 'Build box');
    final labA = idOf(panelA, 'Lab');

    api.updateAuthToken('token-b');
    container.read(_accountEpoch.notifier).bump();
    // While B's settings and terminals load, A's are not offered.
    // The read starts B's requests, so it runs on the real clock.
    final loading = await tester.runAsync(
      () async => readComposerPersonalConnections(container.read),
    );
    expect(loading!.toolServers, isEmpty);
    expect(loading.terminals, isEmpty);

    final connectionsB = await load(tester);
    expect(toolLabels(panel()), ['Plain tool', 'B alpha', 'Build box']);

    // B holds a server keyed `alpha` and a terminal at the same URL as A.
    for (final id in [alphaA, boxA, labA]) {
      await tap(tester, id, opened: connectionsA.owner);
    }
    expect(container.read(selectedToolIdsProvider), isEmpty);
    expect(container.read(selectedTerminalIdProvider), isNull);

    // A terminal B does not have is not selected even by a current panel.
    await tap(tester, labA, opened: connectionsB.owner);
    expect(container.read(selectedTerminalIdProvider), isNull);

    // The same taps from B's own panel go through.
    final panelB = panel();
    await tap(tester, idOf(panelB, 'B alpha'), opened: connectionsB.owner);
    await tap(tester, idOf(panelB, 'Build box'), opened: connectionsB.owner);
    expect(container.read(selectedToolIdsProvider), ['direct_server:alpha']);
    expect(container.read(selectedTerminalIdProvider), _boxUrl);
  });
}

/// The account identity the selection is tied to, without a real session.
final _signedOut = [
  openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
  currentUserProvider2.overrideWithValue(null),
  apiServiceProvider.overrideWithValue(null),
];

final class _SeededModel extends SelectedModel {
  _SeededModel(this.model);

  final Model model;

  @override
  Model build() => model;
}

final class _Settings extends AppSettingsNotifier {
  _Settings(this.settings);

  final AppSettings settings;

  @override
  AppSettings build() => settings;
}

final class _Api extends ApiService {
  _Api()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async =>
      const <String, dynamic>{};
}

final class _NoTools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const <Tool>[];
}
