import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/tether/tether_devices.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/tools_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _device = '3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d';

/// What a device that just connected offers, as Open WebUI 0.13.4 lists it.
final _offeredModel = Model.fromJson(const <String, dynamic>{
  'id': 'garage-llama',
  'name': 'garage-llama',
  'connection_type': 'local',
  'tags': <dynamic>[
    <String, dynamic>{'name': 'Studio Mac · Garage lab'},
  ],
  'base_url': 'tether://$_device',
});
const _offeredTool = Tool(
  id: 'server:tether:$_device:garage_tools',
  name: 'Studio Mac · Garage tools',
);
final _offeredTerminal = TerminalServerInfo(
  kind: TerminalServerKind.system,
  selectionId: 'tether:$_device',
  systemServerId: 'tether:$_device',
  baseUrl: Uri.parse('https://owui.example/api/v1/terminals/d'),
  name: 'Studio Mac',
);

/// The models, which list the device's once read again.
final class _Models extends Models {
  @override
  Future<List<Model>> build() async => const <Model>[];

  @override
  Future<void> refresh() async =>
      state = AsyncData<List<Model>>(<Model>[_offeredModel]);
}

/// The tools, which list the device's once read again.
final class _Tools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const <Tool>[];

  @override
  Future<void> refresh() async =>
      state = const AsyncData<List<Tool>>(<Tool>[_offeredTool]);
}

final class _Hermes extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

final class _Preferred extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.owui;
}

final class _Discovery extends DirectModelDiscoveryController {
  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState();

  @override
  Future<void> refresh() async {}
}

/// Answers held until a test gives them, in the order they were asked for.
final class _Answers<T> {
  final asked = <Completer<T>>[];
  final _waiting = <(int, Completer<void>)>[];

  Future<T> ask() {
    final answer = Completer<T>();
    asked.add(answer);
    for (final (count, reached) in _waiting) {
      if (asked.length >= count && !reached.isCompleted) reached.complete();
    }
    return answer.future;
  }

  /// Completes once [count] reads have been asked for.
  Future<void> askedFor(int count) {
    if (asked.length >= count) return Future<void>.value();
    final reached = Completer<void>();
    _waiting.add((count, reached));
    return reached.future;
  }
}

/// The server's model list, answered when a test says.
final class _HeldModelsApi extends ApiService {
  _HeldModelsApi(WorkerManager workerManager)
    : super(serverConfig: _server, workerManager: workerManager);

  final reads = _Answers<List<Model>>();

  @override
  Future<List<Model>> getModels({
    bool includeHidden = false,
    ApiAuthSnapshot? authSnapshot,
  }) => reads.ask();
}

/// The server's tool list, answered when a test says.
final class _HeldToolsService extends ToolsService {
  _HeldToolsService(super.api);

  final reads = _Answers<List<Tool>>();

  @override
  Future<List<Tool>> getTools() => reads.ask();
}

/// The server's terminals, answered when a test says.
final class _HeldTerminalService extends TerminalService {
  _HeldTerminalService(super.api);

  final reads = _Answers<List<TerminalServerInfo>>();

  @override
  Future<List<TerminalServerInfo>> getAvailableServers() => reads.ask();
}

/// Whether the server offers terminals, as each read last wrote it.
final class _TerminalsOffered extends TerminalFeatureEnabledNotifier {
  final written = <bool>[];

  @override
  bool build() => false;

  @override
  void setEnabled(bool enabled) {
    written.add(enabled);
    state = enabled;
  }
}

/// A cache that starts empty and keeps every list written to it. The next
/// tool list written waits for [holdNextToolsSave] when one is set, as a
/// write does while the database opens. Reads of the cache are answered when
/// a test says, through [modelCacheReads] and [toolCacheReads], when set, as
/// a read does while a worker decodes the stored list.
final class _Storage implements OptimizedStorageService {
  final savedModels = <List<Model>>[];
  List<Tool>? savedTools;
  Completer<void>? holdNextToolsSave;
  final toolsSaveHeld = Completer<void>();
  _Answers<List<Model>>? modelCacheReads;
  _Answers<List<Tool>>? toolCacheReads;

  @override
  Future<List<Model>> getLocalModels() async =>
      await modelCacheReads?.ask() ?? const <Model>[];

  @override
  Future<void> saveLocalModels(List<Model> models) async =>
      savedModels.add(models);

  @override
  Future<List<Tool>> getLocalTools() async =>
      await toolCacheReads?.ask() ?? const <Tool>[];

  @override
  Future<void> saveLocalTools(List<Tool> tools) async {
    final hold = holdNextToolsSave;
    holdNextToolsSave = null;
    if (hold != null) {
      toolsSaveHeld.complete();
      await hold.future;
    }
    savedTools = tools;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

const _server = ServerConfig(
  id: 'server-1',
  name: 'Home server',
  url: 'https://owui.example',
);

void main() {
  test('a device changing what it offers reaches the account, not a chat', () {
    final service = SocketService(
      serverConfig: const ServerConfig(
        id: 'server-1',
        name: 'Home server',
        url: 'https://owui.example',
      ),
      authToken: 'token-1',
      allowWebsocketUpgrade: false,
    );
    addTearDown(service.dispose);
    var changes = 0;
    var delivered = 0;
    service.tetherDevicesChangedHandler = () => changes++;
    service.addChatEventHandler(handler: (_, _) => delivered++);

    // As Open WebUI 0.13.4 emits it when a device connects, leaves or is
    // renamed: to the user's room, naming no chat.
    service.debugHandleChatEvent(<String, dynamic>{
      'data': <String, dynamic>{'type': 'terminals:changed'},
    });

    check(changes).equals(1);
    check(delivered).equals(0);
  });

  test('reads the models, tools and terminals again, an open chat\'s own '
      'terminals included, then says so', () async {
    final workerManager = WorkerManager();
    addTearDown(workerManager.dispose);
    final terminals = _HeldTerminalService(_HeldModelsApi(workerManager));
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Models.new),
        toolsListProvider.overrideWith(_Tools.new),
        terminalServiceProvider.overrideWithValue(terminals),
        terminalFeatureEnabledProvider.overrideWith(_TerminalsOffered.new),
      ],
    );
    addTearDown(container.dispose);
    // A chat session scope holds the terminals the server offers its chat.
    final chat = ProviderContainer(
      parent: container,
      overrides: chatSessionScopedTerminalOverrides(),
    );
    addTearDown(chat.dispose);
    final scopes = [container, chat];
    for (final scope in scopes) {
      scope.listen(terminalAvailableServersProvider, (_, _) {});
    }
    await terminals.reads.askedFor(2);
    for (final read in terminals.reads.asked) {
      read.complete(const <TerminalServerInfo>[]);
    }
    await container.read(modelsProvider.future);
    await container.read(toolsListProvider.future);
    final before = container.read(tetherDevicesProvider);

    await container.read(tetherDevicesProvider.notifier).changed();
    await pumpEventQueue();
    check(terminals.reads.asked).length.equals(4);
    for (final read in terminals.reads.asked.skip(2)) {
      read.complete([_offeredTerminal]);
    }

    check(container.read(modelsProvider).value)
        .isNotNull()
        .deepEquals([_offeredModel]);
    check(container.read(toolsListProvider).value)
        .isNotNull()
        .deepEquals([_offeredTool]);
    for (final scope in scopes) {
      check(await scope.read(terminalAvailableServersProvider.future))
          .deepEquals([_offeredTerminal]);
    }
    check(container.read(tetherDevicesProvider)).equals(before + 1);
  });

  group('a read that a later one superseded publishes and saves nothing', () {
    /// The signed-in account, with the server's lists read through [models],
    /// [tools] and [terminals]; the other two lists stay put.
    ProviderContainer signedIn(
      _Storage storage,
      _HeldModelsApi api, {
      bool models = false,
      _HeldToolsService? tools,
      _HeldTerminalService? terminals,
      _TerminalsOffered? offered,
    }) {
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          preferredBackendProvider.overrideWith(_Preferred.new),
          isAuthenticatedProvider2.overrideWithValue(true),
          isAuthLoadingProvider2.overrideWithValue(false),
          authStatusProvider.overrideWithValue(AuthStatus.authenticated),
          authTokenProvider3.overrideWithValue('token-1'),
          openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
          activeServerProvider.overrideWith((ref) async => _server),
          apiServiceProvider.overrideWithValue(api),
          optimizedStorageServiceProvider.overrideWithValue(storage),
          hermesConfigProvider.overrideWith(_Hermes.new),
          directModelDiscoveryProvider.overrideWith(_Discovery.new),
          if (!models) modelsProvider.overrideWith(_Models.new),
          if (tools != null)
            toolsServiceProvider.overrideWithValue(tools)
          else
            toolsListProvider.overrideWith(_Tools.new),
          if (terminals != null) ...[
            terminalServiceProvider.overrideWithValue(terminals),
            terminalFeatureEnabledProvider.overrideWith(() => offered!),
          ] else
            terminalAvailableServersProvider.overrideWith(
              (ref) async => const <TerminalServerInfo>[],
            ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test("the models' first read, answering after a device's change", () async {
      final workerManager = WorkerManager();
      addTearDown(workerManager.dispose);
      final api = _HeldModelsApi(workerManager);
      final storage = _Storage();
      final container = signedIn(storage, api, models: true);
      await container.read(activeServerProvider.future);
      container.listen(modelsProvider, (_, _) {});
      await api.reads.askedFor(1);

      // The device leaves while the list is read for the first time; the
      // server answers the later read first.
      final change = container.read(tetherDevicesProvider.notifier).changed();
      await api.reads.askedFor(2);
      api.reads.asked[1].complete(const <Model>[]);
      await change;
      api.reads.asked[0].complete(<Model>[_offeredModel]);
      await pumpEventQueue();

      check(container.read(modelsProvider).value).isNotNull().isEmpty();
      check(storage.savedModels.lastOrNull).isNotNull().isEmpty();
    });

    test("the models' earlier refresh, answering after a later one", () async {
      final workerManager = WorkerManager();
      addTearDown(workerManager.dispose);
      final api = _HeldModelsApi(workerManager);
      final storage = _Storage();
      final container = signedIn(storage, api, models: true);
      await container.read(activeServerProvider.future);
      container.listen(modelsProvider, (_, _) {});
      await api.reads.askedFor(1);
      api.reads.asked[0].complete(const <Model>[]);
      await container.read(modelsProvider.future);
      final models = container.read(modelsProvider.notifier);

      final earlier = models.refresh();
      await api.reads.askedFor(2);
      final later = models.refresh();
      await api.reads.askedFor(3);
      api.reads.asked[2].complete(const <Model>[]);
      api.reads.asked[1].complete(<Model>[_offeredModel]);
      await Future.wait([earlier, later]);

      check(container.read(modelsProvider).value).isNotNull().isEmpty();
      check(storage.savedModels.lastOrNull).isNotNull().isEmpty();
    });

    test("the tools' first read, answering after a device's change", () async {
      final workerManager = WorkerManager();
      addTearDown(workerManager.dispose);
      final api = _HeldModelsApi(workerManager);
      final tools = _HeldToolsService(api);
      final storage = _Storage();
      final container = signedIn(storage, api, tools: tools);
      await container.read(activeServerProvider.future);
      container.listen(toolsListProvider, (_, _) {});
      await tools.reads.askedFor(1);

      final change = container.read(tetherDevicesProvider.notifier).changed();
      await tools.reads.askedFor(2);
      tools.reads.asked[1].complete(const <Tool>[]);
      await change;
      tools.reads.asked[0].complete(const <Tool>[_offeredTool]);
      await pumpEventQueue();

      check(container.read(toolsListProvider).value).isNotNull().isEmpty();
      check(storage.savedTools).isNotNull().isEmpty();
    });

    test("the tools' earlier refresh, answering after a later one", () async {
      final workerManager = WorkerManager();
      addTearDown(workerManager.dispose);
      final api = _HeldModelsApi(workerManager);
      final tools = _HeldToolsService(api);
      final storage = _Storage();
      final container = signedIn(storage, api, tools: tools);
      await container.read(activeServerProvider.future);
      container.listen(toolsListProvider, (_, _) {});
      await tools.reads.askedFor(1);
      tools.reads.asked[0].complete(const <Tool>[]);
      await container.read(toolsListProvider.future);
      final devices = container.read(tetherDevicesProvider.notifier);

      // The device connects, then leaves; the server answers the second
      // read first.
      final connected = devices.changed();
      final left = devices.changed();
      await tools.reads.askedFor(3);
      tools.reads.asked[2].complete(const <Tool>[]);
      await left;
      tools.reads.asked[1].complete(const <Tool>[_offeredTool]);
      await connected;

      check(container.read(toolsListProvider).value).isNotNull().isEmpty();
      check(storage.savedTools).isNotNull().isEmpty();
    });

    test(
      "the tools' earlier refresh, whose save lands after a later one's",
      () async {
        final workerManager = WorkerManager();
        addTearDown(workerManager.dispose);
        final api = _HeldModelsApi(workerManager);
        final tools = _HeldToolsService(api);
        final storage = _Storage();
        final container = signedIn(storage, api, tools: tools);
        await container.read(activeServerProvider.future);
        container.listen(toolsListProvider, (_, _) {});
        await tools.reads.askedFor(1);
        tools.reads.asked[0].complete(const <Tool>[]);
        await container.read(toolsListProvider.future);
        final list = container.read(toolsListProvider.notifier);

        // The earlier read's list is still being written, as while the
        // database opens, when the later read's list is ready to be.
        final release = storage.holdNextToolsSave = Completer<void>();
        final earlier = list.refresh();
        await tools.reads.askedFor(2);
        tools.reads.asked[1].complete(const <Tool>[_offeredTool]);
        await storage.toolsSaveHeld.future;
        final later = list.refresh();
        await tools.reads.askedFor(3);
        tools.reads.asked[2].complete(const <Tool>[]);
        release.complete();
        await Future.wait([earlier, later]);

        check(container.read(toolsListProvider).value).isNotNull().isEmpty();
        check(storage.savedTools).isNotNull().isEmpty();
      },
    );

    // A build the list's dependencies retired still runs on: its cache read
    // answering after the build that replaced it must not let it read the
    // server as the newest, leaving the live build nothing to publish.
    test("the models' retired build, whose cache answers last", () async {
      final workerManager = WorkerManager();
      addTearDown(workerManager.dispose);
      final api = _HeldModelsApi(workerManager);
      final cache = _Answers<List<Model>>();
      final storage = _Storage()..modelCacheReads = cache;
      final container = signedIn(storage, api, models: true);
      await container.read(activeServerProvider.future);
      container.listen(modelsProvider, (_, _) {});
      await cache.askedFor(1);

      container.invalidate(modelsProvider);
      container.read(modelsProvider);
      await cache.askedFor(2);
      cache.asked[1].complete(const <Model>[]);
      await api.reads.askedFor(1);
      cache.asked[0].complete(const <Model>[]);
      await pumpEventQueue();
      for (final read in api.reads.asked) {
        read.complete(<Model>[_offeredModel]);
      }
      await pumpEventQueue();

      check(container.read(modelsProvider).value)
          .isNotNull()
          .deepEquals([_offeredModel]);
      check(storage.savedModels.lastOrNull)
          .isNotNull()
          .deepEquals([_offeredModel]);
    });

    // The list was restored from the cache once and refreshed, so a later
    // build that restores it again refreshes nothing.
    test("the models' cache, read again and answering after a device's "
        'change', () async {
      final workerManager = WorkerManager();
      addTearDown(workerManager.dispose);
      final api = _HeldModelsApi(workerManager);
      final cache = _Answers<List<Model>>();
      final storage = _Storage()..modelCacheReads = cache;
      final container = signedIn(storage, api, models: true);
      await container.read(activeServerProvider.future);
      container.listen(modelsProvider, (_, _) {});
      await cache.askedFor(1);
      cache.asked[0].complete(<Model>[_offeredModel]);
      await api.reads.askedFor(1);
      api.reads.asked[0].complete(<Model>[_offeredModel]);
      await container.read(modelsProvider.future);

      container.invalidate(modelsProvider);
      container.read(modelsProvider);
      await cache.askedFor(2);
      // The device leaves while the cache is read again.
      final change = container.read(tetherDevicesProvider.notifier).changed();
      await api.reads.askedFor(2);
      api.reads.asked[1].complete(const <Model>[]);
      await change;
      cache.asked[1].complete(<Model>[_offeredModel]);
      await pumpEventQueue();

      check(container.read(modelsProvider).value).isNotNull().isEmpty();
    });

    test("the tools' cache, answering after a device's change", () async {
      final workerManager = WorkerManager();
      addTearDown(workerManager.dispose);
      final api = _HeldModelsApi(workerManager);
      final tools = _HeldToolsService(api);
      final cache = _Answers<List<Tool>>();
      final storage = _Storage()..toolCacheReads = cache;
      final container = signedIn(storage, api, tools: tools);
      await container.read(activeServerProvider.future);
      container.listen(toolsListProvider, (_, _) {});
      await cache.askedFor(1);

      // The device leaves while the cache is read.
      final change = container.read(tetherDevicesProvider.notifier).changed();
      await tools.reads.askedFor(1);
      tools.reads.asked[0].complete(const <Tool>[]);
      await change;
      cache.asked[0].complete(const <Tool>[_offeredTool]);
      await pumpEventQueue();

      check(container.read(toolsListProvider).value).isNotNull().isEmpty();
    });

    test("the tools' retired build, whose cache answers last", () async {
      final workerManager = WorkerManager();
      addTearDown(workerManager.dispose);
      final api = _HeldModelsApi(workerManager);
      final tools = _HeldToolsService(api);
      final cache = _Answers<List<Tool>>();
      final storage = _Storage()..toolCacheReads = cache;
      final container = signedIn(storage, api, tools: tools);
      await container.read(activeServerProvider.future);
      container.listen(toolsListProvider, (_, _) {});
      await cache.askedFor(1);

      container.invalidate(toolsListProvider);
      container.read(toolsListProvider);
      await cache.askedFor(2);
      cache.asked[1].complete(const <Tool>[]);
      await tools.reads.askedFor(1);
      cache.asked[0].complete(const <Tool>[]);
      await pumpEventQueue();
      for (final read in tools.reads.asked) {
        read.complete(const <Tool>[_offeredTool]);
      }
      await pumpEventQueue();

      check(container.read(toolsListProvider).value)
          .isNotNull()
          .deepEquals([_offeredTool]);
      check(storage.savedTools).isNotNull().deepEquals([_offeredTool]);
    });

    test(
      "the terminals' first read, answering after a device's change",
      () async {
        final workerManager = WorkerManager();
        addTearDown(workerManager.dispose);
        final api = _HeldModelsApi(workerManager);
        final terminals = _HeldTerminalService(api);
        final offered = _TerminalsOffered();
        final container = signedIn(
          _Storage(),
          api,
          terminals: terminals,
          offered: offered,
        );
        await container.read(activeServerProvider.future);
        container.listen(terminalAvailableServersProvider, (_, _) {});
        await terminals.reads.askedFor(1);

        final change = container.read(tetherDevicesProvider.notifier).changed();
        await terminals.reads.askedFor(2);
        terminals.reads.asked[1].complete(const <TerminalServerInfo>[]);
        await change;
        check(await container.read(terminalAvailableServersProvider.future))
            .isEmpty();
        terminals.reads.asked[0].complete(<TerminalServerInfo>[
          _offeredTerminal,
        ]);
        await pumpEventQueue();

        check(container.read(terminalAvailableServersProvider).value)
            .isNotNull()
            .isEmpty();
        check(offered.written)
          ..isNotEmpty()
          ..every((it) => it.isFalse());
      },
    );
  });
}
