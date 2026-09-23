import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../terminal_port.dart';
import 'rpc_providers.dart';
import 'session_providers.dart';

/// xterm.js and the shell's socket, overridden in `main.dart` (M7).
final terminalViewProvider = Provider<TerminalViewPort>(
  (ref) => RecordingTerminalView(),
);

/// Every call the terminal makes to the daemon, in one place so a test
/// replaces the daemon by overriding this.
final terminalActionsProvider = Provider<TerminalActions>(TerminalActions.new);

class TerminalActions {
  TerminalActions(this._ref);

  final Ref _ref;

  Future<T> _call<T>(
    String method,
    Map<String, dynamic> params,
    T Function(Map<String, dynamic>) decode,
  ) =>
      _ref.read(rpcClientProvider).call(method, params: params, decode: decode);

  Future<TerminalServers> servers({String scopeId = ''}) => _call(
    ConduitMethods.terminalServers,
    TerminalScope(scopeId: scopeId).toJson(),
    TerminalServers.fromJson,
  );

  Future<TerminalServers> select(String? serverId) => _call(
    ConduitMethods.terminalSelect,
    TerminalSelect(serverId: serverId).toJson(),
    TerminalServers.fromJson,
  );

  Future<TerminalAttached> attach(String serverId, {String scopeId = ''}) =>
      _call(
        ConduitMethods.terminalAttach,
        TerminalAttach(serverId: serverId, scopeId: scopeId).toJson(),
        TerminalAttached.fromJson,
      );

  Future<TerminalListing> list(String handle, String path) => _call(
    ConduitMethods.terminalList,
    TerminalPath(handle: handle, path: path).toJson(),
    TerminalListing.fromJson,
  );

  Future<TerminalFileContent> read(String handle, String path) => _call(
    ConduitMethods.terminalRead,
    TerminalPath(handle: handle, path: path).toJson(),
    TerminalFileContent.fromJson,
  );

  Future<TerminalFileContent> download(String handle, String path) => _call(
    ConduitMethods.terminalDownload,
    TerminalPath(handle: handle, path: path).toJson(),
    TerminalFileContent.fromJson,
  );

  Future<void> fileAction(
    String handle,
    TerminalFileOp op,
    String path, {
    String? destination,
  }) => _call(
    ConduitMethods.terminalFileAction,
    TerminalFileAction(
      handle: handle,
      op: op,
      path: path,
      destination: destination,
    ).toJson(),
    (json) => json,
  );

  Future<TerminalPorts> ports(String handle) => _call(
    ConduitMethods.terminalPorts,
    TerminalHandleRef(handle: handle).toJson(),
    TerminalPorts.fromJson,
  );

  Future<String> previewPort(String handle, int port) async => (await _call(
    ConduitMethods.terminalPreviewPort,
    TerminalPortRef(handle: handle, port: port).toJson(),
    TerminalPreview.fromJson,
  )).url;
}

/// The terminal servers this account may use, empty without one. The
/// sidebar offers the terminal only when there is at least one.
final terminalServersProvider = FutureProvider<TerminalServers>((ref) async {
  ref.watch(coreConnectionProvider);
  final signedIn =
      ref.watch(authStatusProvider).value?.isAuthenticated ?? false;
  if (!signedIn) return const TerminalServers();
  try {
    return await ref.read(terminalActionsProvider).servers();
  } on RpcError {
    // A server without terminals, or one that refuses the settings read,
    // simply has none to offer.
    return const TerminalServers();
  }
});
