import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import 'rpc_providers.dart';

/// The MCP servers, secrets reported only as present (M4).
final mcpServersProvider = FutureProvider<McpServerList>((ref) async {
  ref.watch(coreConnectionProvider);
  return ref
      .read(rpcClientProvider)
      .call(ConduitMethods.mcpList, decode: McpServerList.fromJson);
});

final mcpActionsProvider = Provider<McpActions>(McpActions.new);

/// Every change answers with the list, which replaces the cached one.
class McpActions {
  McpActions(this._ref);

  final Ref _ref;

  Future<McpServerList> save(McpServerEdit edit) =>
      _mutate(ConduitMethods.mcpSave, edit.toJson());

  Future<McpServerList> remove(String id) =>
      _mutate(ConduitMethods.mcpRemove, McpRef(id: id).toJson());

  Future<McpServerList> setEnabled(String id, {required bool enabled}) =>
      _mutate(
        ConduitMethods.mcpSetEnabled,
        McpEnable(id: id, enabled: enabled).toJson(),
      );

  /// Answers once the browser sign-in has finished.
  Future<McpServerList> connect(String id) =>
      _mutate(ConduitMethods.mcpConnect, McpRef(id: id).toJson());

  Future<void> cancelConnect(String id) => _ref
      .read(rpcClientProvider)
      .call(
        ConduitMethods.mcpCancelConnect,
        params: McpRef(id: id).toJson(),
        decode: (json) => json,
      );

  Future<McpServerList> disconnect(String id) =>
      _mutate(ConduitMethods.mcpDisconnect, McpRef(id: id).toJson());

  Future<McpServerList> forgetApproval(String serverId, {String? digest}) =>
      _mutate(
        ConduitMethods.mcpForgetApproval,
        McpForgetApproval(serverId: serverId, digest: digest).toJson(),
      );

  Future<McpTestResult> test(McpServerEdit edit) => _ref
      .read(rpcClientProvider)
      .call(
        ConduitMethods.mcpTest,
        params: edit.toJson(),
        decode: McpTestResult.fromJson,
      );

  Future<McpServerList> _mutate(
    String method,
    Map<String, dynamic> params,
  ) async {
    final list = await _ref
        .read(rpcClientProvider)
        .call(method, params: params, decode: McpServerList.fromJson);
    _ref.invalidate(mcpServersProvider);
    return list;
  }
}
