import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_protocol/conduit_protocol.dart';

/// The model a terminal made per model is used for in [scope]: the one a
/// turn there runs with ([modelFor]), a new chat's outside a saved chat.
/// Null where none can run, and the terminal is then not offered.
Future<String?> terminalModelFor(
  Future<String> Function(String? chatId)? modelFor,
  String scope,
) async {
  if (modelFor == null) return null;
  try {
    return await modelFor(isSavedTerminalChatScopeId(scope) ? scope : null);
  } on RpcError {
    return null;
  }
}
