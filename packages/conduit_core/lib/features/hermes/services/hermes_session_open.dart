/// What opening a Hermes session reads, whichever app opens it: the phone's
/// session list (`openHermesSession`) and the desktop daemon's
/// `local:hermes_<session>` chats.
///
/// A session's transcript is Hermes's own, with two things this device
/// adds: the earlier messages of a REST copy of another app's chat, which
/// Hermes' API server never stores (kept in [HermesCopiedHistoryStore]),
/// and whether Hermes refuses this app's turns in it (a session another
/// Hermes app owns, opened read-only).
library;

import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show
        HermesConfigController,
        hermesCapabilitiesProvider,
        hermesCopiedHistoryStoreProvider;
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_copied_history_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// The connection [service] talks to, as the device's stores key it: its
/// endpoint, and that endpoint with [principalId] (null without an
/// endpoint).
({String? endpointIdentity, String? connectionIdentity})
hermesSessionConnectionIdentity(
  HermesBackendService service,
  String principalId,
) {
  final endpointIdentity = HermesConfigController.connectionEndpoint(
    service.config.baseUrl,
  );
  return (
    endpointIdentity: endpointIdentity,
    connectionIdentity: endpointIdentity == null
        ? null
        : HermesLocalDocumentTrustStore.connectionIdentity(
            endpointIdentity: endpointIdentity,
            principalId: principalId,
          ),
  );
}

/// The store a REST copy's earlier messages are kept in, for [service]:
/// none on a Desktop Gateway (its session keeps the whole transcript) or
/// without a [connectionIdentity].
HermesCopiedHistoryStore? hermesCopiedHistoryFor(
  dynamic ref,
  HermesBackendService service,
  String? connectionIdentity,
) => service is HermesApiService && connectionIdentity != null
    ? ref.read(hermesCopiedHistoryStoreProvider) as HermesCopiedHistoryStore
    : null;

/// [server] after the earlier messages saved for copy [sessionId], if any.
/// A failed read keeps the server's messages: only the copy's earlier
/// context is missing.
Future<List<Map<String, dynamic>>> withHermesCopiedHistory(
  HermesCopiedHistoryStore? store,
  String? connectionIdentity,
  String sessionId,
  List<Map<String, dynamic>> server,
) async {
  if (store == null || connectionIdentity == null) return server;
  try {
    final saved = await store.load(
      connectionIdentity: connectionIdentity,
      sessionId: sessionId,
    );
    return saved == null ? server : mergeHermesCopiedHistory(saved, server);
  } catch (error) {
    DebugLogger.warning(
      'copied-history-load-failed',
      scope: 'hermes/sessions',
      data: {'errorType': error.runtimeType.toString()},
    );
    return server;
  }
}

/// The earlier messages of copy [sessionId] could not be kept: the copy was
/// removed (as far as Hermes let it be), and nothing opens.
final class HermesCopyHistoryException implements Exception {
  const HermesCopyHistoryException(this.cause);

  final Object cause;

  @override
  String toString() => 'HermesCopyHistoryException($cause)';
}

/// Saves [transcript] as new session [sessionId]'s earlier messages and
/// answers with what was kept (the newest that fit). Unsaved, they would
/// vanish from the copy on its next open and from what its turns replay,
/// so on failure -- nothing fits either -- the copy is deleted from
/// [service] (best effort) and [HermesCopyHistoryException] is thrown.
Future<List<Map<String, dynamic>>> saveHermesCopyHistory({
  required HermesCopiedHistoryStore store,
  required String connectionIdentity,
  required HermesBackendService service,
  required String sessionId,
  required List<Map<String, dynamic>> transcript,
}) async {
  try {
    final kept = await store.save(
      connectionIdentity: connectionIdentity,
      sessionId: sessionId,
      messages: transcript,
    );
    // Nothing fit (the newest message alone is over the limit): the copy
    // would open blank and replay nothing, so it is a failed save too.
    if (kept.isEmpty && transcript.isNotEmpty) {
      throw StateError('No earlier message fits in the copy.');
    }
    return kept;
  } catch (error) {
    DebugLogger.warning(
      'copied-history-save-failed',
      scope: 'hermes/sessions',
      data: {'errorType': error.runtimeType.toString()},
    );
    try {
      await service.deleteSession(sessionId);
    } catch (_) {
      // Best effort: the copy stays as an empty session.
    }
    throw HermesCopyHistoryException(error);
  }
}

/// Whether [session] opens read-only on [service]: Hermes v0.22.1+ refuses
/// REST turns into a session another Hermes surface owns, so such a chat
/// offers a copy instead of failing. Unknown capabilities open it as usual
/// (a refused send still marks it).
Future<bool> hermesSessionOpensReadOnly(
  dynamic ref,
  HermesBackendService service,
  HermesSessionSummary session,
) async {
  if (service is! HermesApiService ||
      !isForeignHermesSessionSource(session.source)) {
    return false;
  }
  try {
    final capabilities = await ref.read(hermesCapabilitiesProvider.future);
    return capabilities.apiOwnsSessions == true;
  } catch (_) {
    return false;
  }
}

/// The product name of the Hermes app a session [source] names ("cli" →
/// "Hermes CLI", "telegram" → "Telegram"), or [source] as Hermes sent it.
String hermesSessionSourceName(String source) =>
    _hermesSessionSourceNames[source.trim().toLowerCase()] ?? source.trim();

const Map<String, String> _hermesSessionSourceNames = {
  'cli': 'Hermes CLI',
  'tui': 'Hermes TUI',
  'gui': 'Hermes Desktop',
  'desktop': 'Hermes Desktop',
  'webapp': 'Hermes Webapp',
  'acp': 'ACP',
  'cron': 'Hermes cron',
  'telegram': 'Telegram',
  'discord': 'Discord',
  'slack': 'Slack',
  'whatsapp': 'WhatsApp',
  'whatsapp_cloud': 'WhatsApp',
  'signal': 'Signal',
  'matrix': 'Matrix',
  'mattermost': 'Mattermost',
  'email': 'Email',
  'sms': 'SMS',
  'teams': 'Microsoft Teams',
  'msteams': 'Microsoft Teams',
  'google_chat': 'Google Chat',
  'homeassistant': 'Home Assistant',
  'bluebubbles': 'iMessage',
  'imessage': 'iMessage',
  'feishu': 'Feishu',
  'dingtalk': 'DingTalk',
  'wecom': 'WeCom',
  'weixin': 'WeChat',
  'qqbot': 'QQ',
  'webhook': 'Webhook',
};
