import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import 'chat_providers.dart';
import 'rpc_providers.dart';

/// The direct connections, secrets reported only as present (WP-4.2).
final directConnectionsProvider = FutureProvider<DirectConnectionList>((
  ref,
) async {
  ref.watch(coreConnectionProvider);
  return ref
      .read(rpcClientProvider)
      .call(ConduitMethods.directList, decode: DirectConnectionList.fromJson);
});

final directActionsProvider = Provider<DirectActions>(DirectActions.new);

/// Every change answers with the list, and changes which models exist --
/// a connection's models join the picker -- so both are refetched.
class DirectActions {
  DirectActions(this._ref);

  final Ref _ref;

  Future<void> save(DirectConnectionEdit edit) =>
      _mutate(ConduitMethods.directSave, edit.toJson());

  Future<void> remove(String id) =>
      _mutate(ConduitMethods.directRemove, DirectRef(id: id).toJson());

  Future<void> setEnabled(String id, {required bool enabled}) => _mutate(
    ConduitMethods.directSetEnabled,
    DirectEnable(id: id, enabled: enabled).toJson(),
  );

  /// The welcome screen's choice: direct connections, or a server.
  Future<void> setPreferred({required bool preferred}) => _mutate(
    ConduitMethods.directSetPreferred,
    DirectPreferred(preferred: preferred).toJson(),
  );

  Future<void> setHistory({required bool localOnly}) => _mutate(
    ConduitMethods.directSetHistory,
    DirectHistory(localOnly: localOnly).toJson(),
  );

  Future<DirectTestResult> test(DirectConnectionEdit edit) => _ref
      .read(rpcClientProvider)
      .call(
        ConduitMethods.directTest,
        params: edit.toJson(),
        decode: DirectTestResult.fromJson,
      );

  /// An Ollama connection's models, or one of the Ollama actions
  /// (`direct.ollamaLoad` and the rest) on one of them. Each answers with
  /// the connection's models as they are afterwards.
  Future<OllamaModelList> ollama(
    String method, {
    required String connectionId,
    OllamaModelAction? action,
  }) => _ref
      .read(rpcClientProvider)
      .call(
        method,
        params: action?.toJson() ?? DirectRef(id: connectionId).toJson(),
        decode: OllamaModelList.fromJson,
      );

  Future<void> _mutate(String method, Map<String, dynamic> params) async {
    await _ref
        .read(rpcClientProvider)
        .call(method, params: params, decode: DirectConnectionList.fromJson);
    _ref
      ..invalidate(directConnectionsProvider)
      ..invalidate(modelListProvider);
  }
}
