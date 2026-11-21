import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_protocol/conduit_protocol.dart';

import 'log.dart';

/// What ends a session or says the account changed: the caller's terminals
/// are then another account's, so the lookup's failure is the answer.
const Set<String> _sessionEnded = {
  ConduitErrorCodes.sessionExpired,
  ConduitErrorCodes.unauthenticated,
  ConduitErrorCodes.unauthorized,
};

/// The model a turn in [scope] runs with ([modelFor]; New Chat's outside a
/// saved chat), which a terminal made per model is used for. Null where no
/// model can run or it can't be read: a failed lookup holds back no other
/// terminal. A session that ended meanwhile is rethrown.
Future<String?> terminalModelIn(
  Future<String> Function(String? chatId)? modelFor,
  String scope, {
  DaemonLog? log,
}) async {
  try {
    return await modelFor?.call(
      isSavedTerminalChatScopeId(scope) ? scope : null,
    );
  } on RpcError catch (error) {
    if (_sessionEnded.contains(error.code)) rethrow;
    return null;
  } on Object catch (error) {
    log?.warn('terminal model lookup failed: ${error.runtimeType}');
    return null;
  }
}

/// [servers] as [scope] may use them: one made per model is used for its
/// model ([terminalModelIn]) and left out where there is none.
Future<List<TerminalServerInfo>> withTerminalModel(
  List<TerminalServerInfo> servers,
  Future<String> Function(String? chatId)? modelFor,
  String scope, {
  DaemonLog? log,
}) async {
  if (!servers.any((server) => server.requiresModelContext)) return servers;
  final modelId = await terminalModelIn(modelFor, scope, log: log);
  return [
    for (final server in servers)
      if (server.forModel(modelId) case final usable when !usable.needsModel)
        usable,
  ];
}
