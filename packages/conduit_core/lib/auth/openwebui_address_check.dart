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

  /// The address is on a host none of the server's routes uses, and the user
  /// chose not to send it a session to check it. Nothing was sent.
  declined,
}

/// Checks that [serverId]'s new [address] reaches the same server before it
/// is saved.
///
/// Every session kept for the server's accounts may be sent to whichever of
/// its addresses answers first, the active account's and the others' alike,
/// so the address has to prove itself with one of their tokens: the active
/// account's live one first, else one kept for another account. [userAt]
/// asks the new address whose token it is, and throws when it refuses it.
///
/// Answering a health check only shows that some Open WebUI server is there,
/// and the token is a session. Before the first one goes to a host none of
/// the server's routes already uses, [confirmSendingSession] asks the user.
Future<OpenWebUiAddressCheck> checkOpenWebUiAddress({
  required OpenWebUiRegistry registry,
  required String serverId,
  required String address,
  required String? activeAccountId,
  required String? liveToken,
  required Future<String?> Function(String accountId) keptTokenFor,
  required Set<String> accountsWithSession,
  required Future<bool> Function(Uri address) confirmSendingSession,
  required Future<String> Function(String token) userAt,
}) async {
  final candidate = Uri.tryParse(address);
  final routes = registry.server(serverId)?.endpoints ?? const [];
  // A host one of the routes uses already receives these sessions.
  var mayReceiveSession =
      candidate != null &&
      routes.any((endpoint) => _sameOrigin(endpoint.url, candidate));
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
    if (!mayReceiveSession) {
      if (candidate == null || !await confirmSendingSession(candidate)) {
        return OpenWebUiAddressCheck.declined;
      }
      mayReceiveSession = true;
    }
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

/// Whether [url] and [other] share a scheme, host and port: a session sent
/// to one already goes to the other.
bool _sameOrigin(String url, Uri other) {
  final parsed = Uri.tryParse(url);
  if (parsed == null || parsed.host.isEmpty || other.host.isEmpty) {
    return false;
  }
  return parsed.scheme.toLowerCase() == other.scheme.toLowerCase() &&
      parsed.host.toLowerCase() == other.host.toLowerCase() &&
      parsed.port == other.port;
}
