import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_protocol/conduit_protocol.dart';

import 'log.dart';

/// [servers] as [scope] may use them: one made per model is used for the
/// model a turn there runs with ([modelFor]; New Chat's outside a saved
/// chat), and left out where no model can run or the model can't be read.
/// The others are never held back by the lookup.
Future<List<TerminalServerInfo>> withTerminalModel(
  List<TerminalServerInfo> servers,
  Future<String> Function(String? chatId)? modelFor,
  String scope, {
  DaemonLog? log,
}) async {
  if (!servers.any((server) => server.requiresModelContext)) return servers;
  String? modelId;
  try {
    modelId = await modelFor?.call(
      isSavedTerminalChatScopeId(scope) ? scope : null,
    );
  } on RpcError {
    // No model can run there.
  } on Object catch (error) {
    log?.warn('terminal model lookup failed: ${error.runtimeType}');
  }
  return [
    for (final server in servers)
      if (server.forModel(modelId) case final usable when !usable.needsModel)
        usable,
  ];
}
