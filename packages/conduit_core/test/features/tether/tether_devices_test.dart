import 'package:checks/checks.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/tether/tether_devices.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/socket_service.dart';
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
}
