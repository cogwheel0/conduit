import 'dart:async';
import 'dart:io';

import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:conduit_core/network/conduit_user_agent.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/utils/list_loads.dart';

import '../models/terminal_models.dart';
import '../services/terminal_service.dart';

typedef TerminalChannelConnector = WebSocketChannel Function(
  Uri uri, {
  required TerminalServerKind kind,
});

final terminalServiceProvider = Provider<TerminalService?>((ref) {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return null;
  }

  return TerminalService(api);
});

final terminalAvailableServersProvider =
    FutureProvider<List<TerminalServerInfo>>(_terminalAvailableServers);

/// Moves on when the server's terminals may have changed while nothing a
/// terminal list watches did, as when one of the user's Tether devices
/// connects or leaves. Every [terminalAvailableServersProvider] watches it,
/// a chat session scope's included, so each is read again.
final terminalsChangedProvider = NotifierProvider<TerminalsChanged, int>(
  TerminalsChanged.new,
);

class TerminalsChanged extends Notifier<int> {
  @override
  int build() => 0;

  void changed() => state++;
}

/// The reads of [terminalAvailableServersProvider], one per build. Each chat
/// session scope has its own ([chatSessionScopedTerminalOverrides]).
final _terminalListLoadsProvider = Provider<ListLoads>((ref) => ListLoads());

Future<List<TerminalServerInfo>> _terminalAvailableServers(Ref ref) {
  ref.watch(terminalsChangedProvider);
  final service = ref.watch(terminalServiceProvider);
  final sessionScopeId = ref.watch(terminalSessionScopeIdProvider);
  if (service == null) {
    // No API/service yet (startup, auth/active-server rebuild). There is no
    // real probe to report: stay UNRESOLVED (loading) rather than resolving
    // to an empty list, so consumers fall back to their cached/last-known
    // state (e.g. terminalTabVisibleProvider keeps the cached flag) instead
    // of treating "no service" as "terminal disabled" — which would poison
    // the cache and hide the tab offline for a terminal-enabled server. The
    // future is abandoned (replaced) as soon as the service becomes
    // available and this provider recomputes.
    return Completer<List<TerminalServerInfo>>().future;
  }

  // Only the newest build publishes: Riverpod drops an earlier one's result.
  final load = ref.read(_terminalListLoadsProvider).start();
  return _probeTerminalServers(
    ref,
    service,
    sessionScopeId,
    load,
  ).whenComplete(load.finish);
}

Future<List<TerminalServerInfo>> _probeTerminalServers(
  Ref ref,
  TerminalService service,
  String sessionScopeId,
  ListLoad load,
) async {
  final listed = await service.getAvailableServers();
  // A terminal made per model is offered while the chat has a model. Which
  // model is the selected terminal's to follow ([_terminalSelectedServer]):
  // a change of model reads nothing here, so no other terminal reconnects.
  final hasModel =
      listed.any((server) => server.requiresModelContext) &&
      ref.watch(selectedModelProvider.select((model) => model != null));
  final servers = listed
      .where(
        (server) =>
            server.isAvailableForChatScope(sessionScopeId) &&
            (!server.requiresModelContext || hasModel),
      )
      .toList(growable: false);
  // A real probe succeeded for the current API/session: persist whether
  // terminal is enabled so the offline/error fallback reflects the true
  // last-known state. Deferred — can't mutate a provider during build.
  unawaited(
    load.write(() async {
      if (!ref.mounted ||
          !identical(ref.read(terminalServiceProvider), service) ||
          ref.read(terminalSessionScopeIdProvider) != sessionScopeId) {
        return;
      }
      final enabled = servers.isNotEmpty;
      ref.read(terminalFeatureEnabledProvider.notifier).setEnabled(enabled);
      ref
          .read(_terminalScopedAvailabilityProvider.notifier)
          .setEnabled(service, sessionScopeId, enabled);
    }),
  );
  return servers;
}

/// Reads the server's own terminals offered to a saved chat (a host listing
/// models for a chat it does not hold as the active one, as the desktop
/// daemon does, where [terminalAvailableServersProvider] is the sidebar's
/// list and leaves out a terminal that needs a saved chat). Each call is
/// its own read of the server: nothing is kept between reads, so a terminal
/// granted or taken away since shows at the next one, and two lookups at
/// once never share, or cancel, each other's read.
final terminalSystemServersForChatProvider =
    Provider<Future<List<TerminalServerInfo>> Function(String chatId)>((ref) {
      final service = ref.watch(terminalServiceProvider);
      return (chatId) async {
        if (service == null) {
          return Completer<List<TerminalServerInfo>>().future;
        }
        final servers = await service.getSystemTerminalServers();
        return servers
            .where((server) => server.isAvailableForChatScope(chatId))
            .toList(growable: false);
      };
    });

typedef _TerminalAvailabilityScope = ({
  TerminalService? service,
  String sessionScopeId,
});

final _terminalScopedAvailabilityProvider =
    NotifierProvider<
      _TerminalScopedAvailabilityNotifier,
      Map<_TerminalAvailabilityScope, bool>
    >(_TerminalScopedAvailabilityNotifier.new);

class _TerminalScopedAvailabilityNotifier
    extends Notifier<Map<_TerminalAvailabilityScope, bool>> {
  @override
  Map<_TerminalAvailabilityScope, bool> build() {
    final service = ref.watch(terminalServiceProvider);
    final cached = ref.read(terminalFeatureEnabledProvider);
    final sessionScopeId = ref.read(terminalSessionScopeIdProvider);
    return {(service: service, sessionScopeId: sessionScopeId): cached};
  }

  void setEnabled(
    TerminalService service,
    String sessionScopeId,
    bool enabled,
  ) {
    state = {
      ...state,
      (service: service, sessionScopeId: sessionScopeId): enabled,
    };
  }
}

/// Whether the Terminal tab should be visible. When the server list resolves,
/// use it live (terminal is enabled iff at least one server exists); while it is
/// loading or errored (e.g. offline), fall back to the cached last-known value
/// (written by [terminalAvailableServersProvider] after a real probe) instead of
/// optimistically showing the tab — so a server with terminal disabled doesn't
/// surface the tab offline (matching notes/channels).
final terminalTabVisibleProvider = Provider<bool>((ref) {
  final service = ref.watch(terminalServiceProvider);
  final sessionScopeId = ref.watch(terminalSessionScopeIdProvider);
  final cached = ref.watch(
    _terminalScopedAvailabilityProvider,
  )[(service: service, sessionScopeId: sessionScopeId)];
  final serversAsync = ref.watch(terminalAvailableServersProvider);
  return serversAsync.maybeWhen(
    data: (servers) => servers.isNotEmpty,
    orElse: () => cached ?? false,
  );
});

final terminalSelectedServerProvider = FutureProvider<TerminalServerInfo?>(
  _terminalSelectedServer,
);

Future<TerminalServerInfo?> _terminalSelectedServer(Ref ref) async {
  final servers = await ref.watch(terminalAvailableServersProvider.future);
  final selectedTerminalId = ref.watch(selectedTerminalIdProvider);
  final server = resolveSelectedTerminalServerForTest(
    servers,
    selectedTerminalId,
  );
  if (server == null || !server.requiresModelContext) return server;
  // The chat's model's own machine: only this terminal follows a change of
  // model.
  return server.forModel(
    ref.watch(selectedModelProvider.select((model) => model?.id)),
  );
}

final terminalSessionScopeIdProvider = Provider<String>(
  _terminalSessionScopeId,
);

/// This library's share of a chat session scope (`ChatSessionScope` in the
/// chat library): the terminal session a chat uses is its own, keyed by the
/// scope's conversation, and so are the terminals the server offers that
/// chat (a saved chat may use some a new one may not) and the server its
/// selected terminal names.
List<Override> chatSessionScopedTerminalOverrides() => <Override>[
  terminalSessionScopeIdProvider.overrideWith(_terminalSessionScopeId),
  _terminalListLoadsProvider.overrideWith((ref) => ListLoads()),
  terminalAvailableServersProvider.overrideWith(_terminalAvailableServers),
  terminalSelectedServerProvider.overrideWith(_terminalSelectedServer),
  // A file a chat's terminal tool asked to show belongs to that chat.
  terminalDisplayFileProvider.overrideWith(TerminalDisplayFileNotifier.new),
];

String _terminalSessionScopeId(Ref ref) {
  final activeConversation = ref.watch(activeConversationProvider);
  final conversationId = activeConversation?.id.trim();
  if (conversationId != null && conversationId.isNotEmpty) {
    return conversationId;
  }

  return 'sidebar-terminal';
}

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
  final systemClient = HttpClient()..userAgent = ConduitUserAgent.value;
  ref.onDispose(() => systemClient.close(force: true));

  return (uri, {required kind}) {
    if (kind == TerminalServerKind.direct) {
      return WebSocketChannel.connect(uri);
    }
    return IOWebSocketChannel.connect(uri, customClient: systemClient);
  };
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

final class TerminalFileRequest {
  const TerminalFileRequest(this.path, {this.page});

  final String path;
  final int? page;
}

class TerminalDisplayFileNotifier extends Notifier<TerminalFileRequest?> {
  @override
  TerminalFileRequest? build() {
    ref.watch(terminalSessionScopeIdProvider);
    ref.watch(terminalServiceProvider);
    return null;
  }

  void show(String path, {int? page}) {
    state = TerminalFileRequest(
      path,
      page: page != null && page > 0 ? page : null,
    );
  }

  void handleEvent(String type, Map<String, dynamic> data) {
    final path = data['path'] is String ? (data['path'] as String).trim() : '';
    if (type == 'terminal:display_file') {
      if (path.isEmpty) return;
      final rawPage = data['page'];
      final page = rawPage is int ? rawPage : int.tryParse('$rawPage');
      show(path, page: page);
    } else if (type == 'terminal:write_file' ||
        type == 'terminal:replace_file_content' ||
        type == 'terminal:run_command') {
      if (type != 'terminal:run_command' && path.isEmpty) return;
      ref
          .read(terminalCurrentPathProvider.notifier)
          .set(type == 'terminal:run_command' ? '/' : parentTerminalPath(path));
      ref.read(terminalBrowserRefreshTokenProvider.notifier).increment();
    }
  }

  void clear() => state = null;
}

final terminalDisplayFileProvider =
    NotifierProvider<TerminalDisplayFileNotifier, TerminalFileRequest?>(
      TerminalDisplayFileNotifier.new,
    );
