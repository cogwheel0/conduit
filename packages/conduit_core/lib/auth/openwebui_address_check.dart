import '../models/openwebui_registry.dart';

/// What checking a new address for a saved Open WebUI server found.
enum OpenWebUiAddressCheck {
  /// A token one of the server's accounts holds names that account's user
  /// there: it is the same server.
  sameServer,

  /// The token is refused there, or names someone else.
  differentServer,

  /// The server's accounts keep a saved sign-in but no token to check with.
  /// Their password would go to the address unchecked, so sign in first.
  needsSignIn,

  /// None of the server's accounts keeps anything the address could receive.
  nothingToProtect,
}

/// Checks that [serverId]'s new address reaches the same server before it is
/// saved.
///
/// Every session kept for the server's accounts may be sent to whichever of
/// its addresses answers first, the active account's and the others' alike,
/// so the address has to prove itself with one of their tokens: the active
/// account's live one first, else one kept for another account. [userAt]
/// asks the new address whose token it is, and throws when it refuses it.
Future<OpenWebUiAddressCheck> checkOpenWebUiAddress({
  required OpenWebUiRegistry registry,
  required String serverId,
  required String? activeAccountId,
  required String? liveToken,
  required Future<String?> Function(String accountId) keptTokenFor,
  required Set<String> accountsWithSession,
  required Future<String> Function(String token) userAt,
}) async {
  final accounts = [...registry.accountsOn(serverId)]
    ..sort(
      (a, b) => (b.id == activeAccountId ? 1 : 0).compareTo(
        a.id == activeAccountId ? 1 : 0,
      ),
    );
  for (final account in accounts) {
    final userId = account.userId;
    if (userId == null) continue;
    final token = account.id == activeAccountId
        ? liveToken
        : await keptTokenFor(account.id);
    if (token == null || token.isEmpty) continue;
    try {
      return await userAt(token) == userId
          ? OpenWebUiAddressCheck.sameServer
          : OpenWebUiAddressCheck.differentServer;
    } catch (_) {
      return OpenWebUiAddressCheck.differentServer;
    }
  }
  return accounts.any((account) => accountsWithSession.contains(account.id))
      ? OpenWebUiAddressCheck.needsSignIn
      : OpenWebUiAddressCheck.nothingToProtect;
}
