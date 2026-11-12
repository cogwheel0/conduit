import '../../../core/services/native_sheet_bridge.dart';

/// Hermes Agent's page of Settings.
const hermesSettingsPageId = NativeSheetRoutes.hermes;

/// Prefix of a connection's editor; the editor's key follows: the
/// URI-encoded connection id, or [hermesNewConnectionKey] /
/// [hermesConnectConnectionKey] for one being added.
const hermesConnectionPagePrefix = 'hermes-connection:';

/// Prefix of a connection editor's Advanced page; the editor's key follows.
const hermesConnectionAdvancedPagePrefix = 'hermes-connection-advanced:';

/// Prefix of the server page of the connection in use: what it can do, its
/// toolsets, its gateway's actions and its status. The editor's key follows.
const hermesConnectionServerPagePrefix = 'hermes-connection-server:';

/// Prefix of the page adding an access header; the editor's key follows.
const hermesConnectionHeaderPagePrefix = 'hermes-connection-header:';

/// The key of the editor adding a connection from the Hermes page.
const hermesNewConnectionKey = 'new';

/// The key of the editor adding a connection from Add Account, whose Done
/// connects to it and puts it in use.
const hermesConnectConnectionKey = 'add';

/// Hermes' scheduled agents.
const hermesJobsPageId = 'hermes-jobs';

/// The Desktop Gateway's MCP servers.
const hermesMcpPageId = 'hermes-mcp';

/// Hermes chats hidden from the session list.
const hermesHiddenChatsPageId = 'hermes-hidden-chats';

/// The editor of saved connection [connectionId], or of a new one when it
/// is null.
String hermesConnectionPageId(String? connectionId) =>
    '$hermesConnectionPagePrefix'
    '${connectionId == null ? hermesNewConnectionKey : Uri.encodeComponent(connectionId)}';

/// The editor that adds and connects a connection, from Add Account.
const hermesConnectConnectionPageId =
    '$hermesConnectionPagePrefix$hermesConnectConnectionKey';

/// Prefix of the Hermes page's own rows.
const hermesSettingsRowPrefix = 'hermes.';

/// A row of the Hermes page: `hermes.<field>[:<argument>]`.
String hermesSettingsRowId(String field, [String? argument]) =>
    '$hermesSettingsRowPrefix$field'
    '${argument == null ? '' : ':${Uri.encodeComponent(argument)}'}';

/// Prefix of the rows of a connection's pages.
const hermesConnectionRowPrefix = 'hermes-connection.';

/// A row of a connection's pages: `hermes-connection.<field>:<key>`, with
/// [extra] after another colon.
String hermesConnectionRowId(String field, String key, [String? extra]) =>
    '$hermesConnectionRowPrefix$field:$key'
    '${extra == null ? '' : ':${Uri.encodeComponent(extra)}'}';

/// The field, editor key and extra a connection row id names.
({String field, String key, String? extra})? parseHermesConnectionRowId(
  String id,
) {
  if (!id.startsWith(hermesConnectionRowPrefix)) return null;
  final parts = id.substring(hermesConnectionRowPrefix.length).split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  return (
    field: parts[0],
    key: parts[1],
    extra: parts.length == 3 ? Uri.decodeComponent(parts[2]) : null,
  );
}

/// Prefix of the hidden chats' rows.
const hermesHiddenChatRowPrefix = 'hermes-hidden.';

/// A hidden chat's row (`open`) or its menu's action (`unhide`).
String hermesHiddenChatRowId(String field, String sessionId) =>
    '$hermesHiddenChatRowPrefix$field:${Uri.encodeComponent(sessionId)}';
