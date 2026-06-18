import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/providers/app_providers.dart';
import '../../tools/providers/tools_providers.dart';
import '../models/terminal_models.dart';
import '../services/terminal_service.dart';

typedef TerminalChannelConnector = WebSocketChannel Function(Uri uri);

final terminalServiceProvider = Provider<TerminalService?>((ref) {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return null;
  }

  return TerminalService(api);
});

final terminalAvailableServersProvider =
    FutureProvider<List<TerminalServerInfo>>((ref) async {
      final service = ref.watch(terminalServiceProvider);
      if (service == null) {
        // No API/service yet (startup, auth/active-server rebuild). This is a
        // PLACEHOLDER, not a real probe — do NOT persist it as "terminal
        // disabled", or a transient service gap would poison the cache and keep
        // the tab hidden offline for a terminal-enabled server.
        return const <TerminalServerInfo>[];
      }

      final servers = await service.getAvailableServers();
      // A real probe succeeded for the current API/session: persist whether
      // terminal is enabled so the offline/error fallback reflects the true
      // last-known state. Deferred — can't mutate a provider during build.
      Future.microtask(
        () => ref
            .read(terminalFeatureEnabledProvider.notifier)
            .setEnabled(servers.isNotEmpty),
      );
      return servers;
    });

/// Whether the Terminal tab should be visible. When the server list resolves,
/// use it live (terminal is enabled iff at least one server exists); while it is
/// loading or errored (e.g. offline), fall back to the cached last-known value
/// (written by [terminalAvailableServersProvider] after a real probe) instead of
/// optimistically showing the tab — so a server with terminal disabled doesn't
/// surface the tab offline (matching notes/channels).
final terminalTabVisibleProvider = Provider<bool>((ref) {
  final cached = ref.watch(terminalFeatureEnabledProvider);
  final serversAsync = ref.watch(terminalAvailableServersProvider);
  return serversAsync.maybeWhen(
    data: (servers) => servers.isNotEmpty,
    orElse: () => cached,
  );
});

final terminalSelectedServerProvider = FutureProvider<TerminalServerInfo?>((
  ref,
) async {
  final servers = await ref.watch(terminalAvailableServersProvider.future);
  final selectedTerminalId = ref.watch(selectedTerminalIdProvider);
  return resolveSelectedTerminalServerForTest(servers, selectedTerminalId);
});

final terminalSessionScopeIdProvider = Provider<String>((ref) {
  final activeConversation = ref.watch(activeConversationProvider);
  final conversationId = activeConversation?.id.trim();
  if (conversationId != null && conversationId.isNotEmpty) {
    return conversationId;
  }

  return 'sidebar-terminal';
});

final terminalCurrentPathProvider =
    NotifierProvider<TerminalCurrentPathNotifier, String>(
      TerminalCurrentPathNotifier.new,
    );

final terminalEntriesProvider =
    NotifierProvider<TerminalEntriesNotifier, List<TerminalFileEntry>>(
      TerminalEntriesNotifier.new,
    );

final terminalListeningPortsProvider =
    NotifierProvider<
      TerminalListeningPortsNotifier,
      List<TerminalListeningPort>
    >(TerminalListeningPortsNotifier.new);

final terminalConnectionStateProvider =
    NotifierProvider<TerminalConnectionStateNotifier, TerminalConnectionState>(
      TerminalConnectionStateNotifier.new,
    );

final terminalActiveSessionProvider =
    NotifierProvider<TerminalActiveSessionNotifier, TerminalSessionInfo?>(
      TerminalActiveSessionNotifier.new,
    );

final terminalBrowserRefreshTokenProvider =
    NotifierProvider<TerminalBrowserRefreshTokenNotifier, int>(
      TerminalBrowserRefreshTokenNotifier.new,
    );

final terminalChannelConnectorProvider = Provider<TerminalChannelConnector>((
  ref,
) {
  return (uri) => WebSocketChannel.connect(uri);
});

final terminalAutoConnectProvider = Provider<bool>((ref) => true);

final terminalSelectionControllerProvider =
    Provider<TerminalSelectionController>(TerminalSelectionController.new);

class TerminalSelectionController {
  TerminalSelectionController(this.ref);

  final Ref ref;

  Future<void> select(TerminalServerInfo? server) async {
    final service = ref.read(terminalServiceProvider);
    if (service != null) {
      await service.updateDirectTerminalSelection(
        server != null && server.isDirect ? server.selectionId : null,
      );
    }

    final selectedTerminalNotifier = ref.read(
      selectedTerminalIdProvider.notifier,
    );
    if (server == null) {
      selectedTerminalNotifier.clear();
    } else {
      selectedTerminalNotifier.set(server.selectionId);
    }

    _resetTerminalState();
  }

  Future<void> toggle(TerminalServerInfo server) async {
    final selectedTerminalId = ref.read(selectedTerminalIdProvider);
    if (selectedTerminalId == server.selectionId) {
      await select(null);
      return;
    }

    await select(server);
  }

  void refreshAvailableServers() {
    ref.invalidate(terminalAvailableServersProvider);
    ref.invalidate(terminalSelectedServerProvider);
  }

  void requestTerminalRefresh() {
    ref.read(terminalBrowserRefreshTokenProvider.notifier).increment();
  }

  void _resetTerminalState() {
    ref.read(terminalCurrentPathProvider.notifier).set('/');
    ref.read(terminalEntriesProvider.notifier).set(const <TerminalFileEntry>[]);
    ref
        .read(terminalListeningPortsProvider.notifier)
        .set(const <TerminalListeningPort>[]);
    ref.read(terminalActiveSessionProvider.notifier).clear();
    ref
        .read(terminalConnectionStateProvider.notifier)
        .set(const TerminalConnectionState.disconnected());
    refreshAvailableServers();
    requestTerminalRefresh();
  }
}

class TerminalCurrentPathNotifier extends Notifier<String> {
  @override
  String build() => '/';

  void set(String path) => state = path;
}

class TerminalEntriesNotifier extends Notifier<List<TerminalFileEntry>> {
  @override
  List<TerminalFileEntry> build() => const <TerminalFileEntry>[];

  void set(List<TerminalFileEntry> entries) => state = entries;
}

class TerminalListeningPortsNotifier
    extends Notifier<List<TerminalListeningPort>> {
  @override
  List<TerminalListeningPort> build() => const <TerminalListeningPort>[];

  void set(List<TerminalListeningPort> ports) => state = ports;
}

class TerminalConnectionStateNotifier
    extends Notifier<TerminalConnectionState> {
  @override
  TerminalConnectionState build() =>
      const TerminalConnectionState.disconnected();

  void set(TerminalConnectionState value) => state = value;
}

class TerminalActiveSessionNotifier extends Notifier<TerminalSessionInfo?> {
  @override
  TerminalSessionInfo? build() => null;

  void set(TerminalSessionInfo? session) => state = session;

  void clear() => state = null;
}

class TerminalBrowserRefreshTokenNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
}

class TerminalSidebarPanelNotifier extends Notifier<TerminalSidebarPanel> {
  @override
  TerminalSidebarPanel build() => TerminalSidebarPanel.console;

  void setPanel(TerminalSidebarPanel panel) => state = panel;
}

final terminalSidebarPanelProvider =
    NotifierProvider<TerminalSidebarPanelNotifier, TerminalSidebarPanel>(
      TerminalSidebarPanelNotifier.new,
    );
