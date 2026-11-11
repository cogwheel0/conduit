import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart';

import '../../../core/services/native_sheet_bridge.dart' show NativeSheetRoutes;
import '../../direct_connections/controllers/direct_mcp_server_editor.dart'
    show directMcpNewServerId;

// The ids of Direct Connections' pages in Settings and of their rows. The
// Accounts page leads to some of them, so they stand apart from the pages.

/// The Direct Connections page: Apple's models, context limits, the
/// providers kept by Open WebUI and those on this device, MCP servers, and
/// how Direct sends images and searches the web.
const directConnectionsPageId = NativeSheetRoutes.directConnections;

/// Prefix of an Apple model's page; [directAppleOnDevice] or
/// [directApplePcc] follows.
const directApplePagePrefix = 'direct-apple:';
const directAppleOnDevice = 'on-device';
const directApplePcc = 'pcc';

/// The context limits of every Direct model that reports none, when there
/// are too many to list on the Direct page.
const directContextLimitsPageId = 'direct-context-limits';

/// Prefix of a provider's editor; its editor key follows.
const directConnectionPagePrefix = 'direct-connection:';

/// Prefix of an editor's Advanced page; the editor's key follows.
const directConnectionAdvancedPagePrefix = 'direct-connection-advanced:';

/// Prefix of the page adding a header to a provider; the editor's key
/// follows.
const directConnectionHeaderPagePrefix = 'direct-connection-header:';

/// Prefix of an MCP server's editor; the server's URI-encoded id follows,
/// or `new` for one being added.
const directMcpPagePrefix = 'direct-mcp:';

/// An editor key's source for the provider Add Account adds: one on this
/// device, whose editor goes back to Accounts once it is saved.
const _addAccountSource = 'account';
const _localSource = 'local';
const _openWebUiSource = 'openwebui';
const _newKey = 'new';

/// What an editor was opened for: where the provider is kept, which one,
/// and whether Add Account opened it.
typedef DirectEditorTarget = ({
  DirectConnectionEditorSource source,
  String? profileId,
  bool fromAddAccount,
});

/// The key of the editor of [profileId] kept in [source], or of a new
/// provider there when null. [fromAddAccount] marks the editor Add Account
/// opens, which adds one on this device.
String directConnectionEditorKey(
  DirectConnectionEditorSource source,
  String? profileId, {
  bool fromAddAccount = false,
}) {
  final sourceKey = fromAddAccount
      ? _addAccountSource
      : switch (source) {
          DirectConnectionEditorSource.local => _localSource,
          DirectConnectionEditorSource.openWebUi => _openWebUiSource,
        };
  return '$sourceKey:${Uri.encodeComponent(profileId ?? _newKey)}';
}

String directConnectionPageId(
  DirectConnectionEditorSource source,
  String? profileId, {
  bool fromAddAccount = false,
}) =>
    '$directConnectionPagePrefix'
    '${directConnectionEditorKey(source, profileId, fromAddAccount: fromAddAccount)}';

/// The editor Add Account opens to add a provider on this device.
final directConnectionAddAccountPageId = directConnectionPageId(
  DirectConnectionEditorSource.local,
  null,
  fromAddAccount: true,
);

String directMcpPageId(String? serverId) =>
    '$directMcpPagePrefix'
    '${Uri.encodeComponent(serverId ?? directMcpNewServerId)}';

String directApplePageId(String model) => '$directApplePagePrefix$model';

/// What the editor [key] names, or null for a key that names none.
DirectEditorTarget? parseDirectConnectionEditorKey(String key) {
  final parts = key.split(':');
  if (parts.length != 2) return null;
  final id = Uri.decodeComponent(parts[1]);
  final source = switch (parts[0]) {
    _localSource || _addAccountSource => DirectConnectionEditorSource.local,
    _openWebUiSource => DirectConnectionEditorSource.openWebUi,
    _ => null,
  };
  if (source == null || id.isEmpty) return null;
  return (
    source: source,
    profileId: id == _newKey ? null : id,
    fromAddAccount: parts[0] == _addAccountSource,
  );
}

/// A row of the Direct pages: `direct.<field>`, with [extra] after a colon.
String directRowId(String field, [String? extra]) =>
    'direct.$field${extra == null ? '' : ':${Uri.encodeComponent(extra)}'}';

/// A row of a provider's pages: `direct-connection.<field>:<editor key>`,
/// with [extra] after another colon.
String directConnectionRowId(String field, String key, [String? extra]) =>
    'direct-connection.$field:$key'
    '${extra == null ? '' : ':${Uri.encodeComponent(extra)}'}';

/// A row of an MCP server's page: `direct-mcp.<field>:<server key>`, with
/// [extra] after another colon.
String directMcpRowId(String field, String key, [String? extra]) =>
    'direct-mcp.$field:$key'
    '${extra == null ? '' : ':${Uri.encodeComponent(extra)}'}';
