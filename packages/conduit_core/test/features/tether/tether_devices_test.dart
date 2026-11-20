import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/tether/tether_devices.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/tools_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _Models extends Models {
  static int refreshes = 0;

  @override
  Future<List<Model>> build() async => const <Model>[];

  @override
  Future<void> refresh() async => refreshes++;
}

final class _Tools extends ToolsList {
  static int refreshes = 0;

  @override
  Future<List<Tool>> build() async => const <Tool>[];

  @override
  Future<void> refresh() async => refreshes++;
}

/// Direct discovery, the first step of reading the models again: the first
/// read waits for [release], so a read is still under way when the next
/// change arrives.
final class _HeldDiscovery extends DirectModelDiscoveryController {
  final _released = Completer<void>();
  int reads = 0;

  void release() => _released.complete();

  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState();

  @override
  Future<void> refresh() async {
    reads++;
    if (reads == 1) await _released.future;
  }
}

final class _Hermes extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

/// The models, read again as the app does.
final class _ServerModels extends Models {
  @override
  Future<List<Model>> build() async => const <Model>[];
}

/// The tools, read again as the app does.
final class _ServerTools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const <Tool>[];
}

/// The server's tool list, answered when a test says.
final class _HeldToolsService extends ToolsService {
  _HeldToolsService(super.api);

  final answers = <Completer<List<Tool>>>[];

  @override
  Future<List<Tool>> getTools() {
    final answer = Completer<List<Tool>>();
    answers.add(answer);
    return answer.future;
  }
}

final class _Storage implements OptimizedStorageService {
  List<Tool>? savedTools;

  @override
  Future<void> saveLocalTools(List<Tool> tools) async => savedTools = tools;

  @override
  Future<List<Model>> getLocalModels() async => const <Model>[];

  @override
  Future<void> saveLocalModels(List<Model> models) async {}

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

  test('reads the models, tools and terminals again, then says so', () async {
    _Models.refreshes = 0;
    _Tools.refreshes = 0;
    var terminalReads = 0;
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Models.new),
        toolsListProvider.overrideWith(_Tools.new),
        terminalAvailableServersProvider.overrideWith((ref) async {
          terminalReads++;
          return const <TerminalServerInfo>[];
        }),
      ],
    );
    addTearDown(container.dispose);
    final terminals = container.listen(
      terminalAvailableServersProvider,
      (_, _) {},
    );
    addTearDown(terminals.close);
    await container.read(terminalAvailableServersProvider.future);
    final before = container.read(tetherDevicesProvider);

    await container.read(tetherDevicesProvider.notifier).changed();
    await container.read(terminalAvailableServersProvider.future);

    check(_Models.refreshes).equals(1);
    check(_Tools.refreshes).equals(1);
    check(terminalReads).equals(2);
    check(container.read(tetherDevicesProvider)).equals(before + 1);
  });

  group('a change while the lists are still being read for an earlier one', () {
    test(
      'reads the models again rather than taking the earlier read',
      () async {
        final discovery = _HeldDiscovery();
        final container = ProviderContainer(
          overrides: [
            modelsProvider.overrideWith(_ServerModels.new),
            reviewerModeProvider.overrideWithValue(false),
            directModelDiscoveryProvider.overrideWith(() => discovery),
            hermesConfigProvider.overrideWith(_Hermes.new),
            isAuthenticatedProvider2.overrideWithValue(false),
            isAuthLoadingProvider2.overrideWithValue(false),
            optimizedStorageServiceProvider.overrideWithValue(_Storage()),
            toolsListProvider.overrideWith(_Tools.new),
            terminalAvailableServersProvider.overrideWith(
              (ref) async => const <TerminalServerInfo>[],
            ),
          ],
        );
        addTearDown(container.dispose);
        final devices = container.read(tetherDevicesProvider.notifier);

        final first = devices.changed();
        // The device leaves while the models are read for its arrival.
        final second = devices.changed();
        discovery.release();
        await Future.wait([first, second]);

        check(discovery.reads).equals(2);
      },
    );

    test(
      'keeps the newer tool list when the earlier read answers last',
      () async {
        final workerManager = WorkerManager();
        addTearDown(workerManager.dispose);
        final api = ApiService(
          serverConfig: _server,
          workerManager: workerManager,
          authToken: 'token-1',
        );
        final service = _HeldToolsService(api);
        final storage = _Storage();
        final container = ProviderContainer(
          overrides: [
            toolsListProvider.overrideWith(_ServerTools.new),
            toolsServiceProvider.overrideWithValue(service),
            apiServiceProvider.overrideWithValue(api),
            activeServerProvider.overrideWith((ref) async => _server),
            isAuthenticatedProvider2.overrideWithValue(true),
            authTokenProvider3.overrideWithValue('token-1'),
            openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
            optimizedStorageServiceProvider.overrideWithValue(storage),
            modelsProvider.overrideWith(_Models.new),
            terminalAvailableServersProvider.overrideWith(
              (ref) async => const <TerminalServerInfo>[],
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(activeServerProvider.future);
        await container.read(toolsListProvider.future);
        final devices = container.read(tetherDevicesProvider.notifier);
        const device = '3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d';
        const offered = Tool(
          id: 'server:tether:$device:garage_tools',
          name: 'Studio Mac · Garage tools',
        );

        // The device connects, then leaves; the server answers the second
        // read first.
        final connected = devices.changed();
        final left = devices.changed();
        check(service.answers).length.equals(2);
        service.answers[1].complete(const <Tool>[]);
        await left;
        service.answers[0].complete(const <Tool>[offered]);
        await connected;

        check(container.read(toolsListProvider).value).isNotNull().isEmpty();
        check(storage.savedTools).isNotNull().isEmpty();
      },
    );
  });
}
