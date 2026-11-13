import 'dart:typed_data';

import 'package:conduit_core/navigation/routes.dart' show WorkspaceSection;

import '../../../core/services/native_sheet_bridge.dart';

/// The Workspace's own page of Settings: its sections, as the root's
/// Workspace row opens it.
const workspaceHubPageId = NativeSheetRoutes.workspace;

/// Prefix of a Workspace section's list; the section's name follows.
const workspaceSectionPagePrefix = 'workspace-section:';

/// Prefix of a model's editor; the editor key follows.
const workspaceModelPagePrefix = 'workspace-model:';

/// Prefix of a model editor's Advanced page; the editor key follows.
const workspaceModelAdvancedPagePrefix = 'workspace-model-advanced:';

/// Prefix of a model editor's page choosing one kind of relationship: the
/// kind's name, `:`, then the editor key.
const workspaceModelRelationshipPagePrefix = 'workspace-model-relationship:';

/// Prefix of a prompt's editor; the editor key follows.
const workspacePromptPagePrefix = 'workspace-prompt:';

/// Prefix of a prompt's version history; the editor key follows.
const workspacePromptHistoryPagePrefix = 'workspace-prompt-history:';

/// Prefix of one version of a prompt: the editor key, `:`, then the
/// URI-encoded version id.
const workspacePromptVersionPagePrefix = 'workspace-prompt-version:';

/// Prefix of the comparison of one version of a prompt with its live one:
/// the editor key, `:`, then the URI-encoded version id.
const workspacePromptDiffPagePrefix = 'workspace-prompt-diff:';

/// Prefix of a resource's Access page: the section's name, `:`, then the
/// editor key.
const workspaceAccessPagePrefix = 'workspace-access:';

/// Prefix of the page adding people or groups to a resource's access:
/// `users` or `groups`, `:`, the section's name, `:`, then the editor key.
const workspaceAccessAddPagePrefix = 'workspace-access-add:';

/// The key of an editor creating a resource. `+` is escaped in every
/// encoded id, so no saved resource has this key.
const workspaceNewKey = '+new';

/// The editor key of resource [id], or of a new one when [id] is null.
String workspaceEditorKey(String? id) =>
    id == null ? workspaceNewKey : Uri.encodeComponent(id);

/// The resource id editor [key] stands for, or null for a new one.
String? workspaceIdOfKey(String key) =>
    key == workspaceNewKey ? null : Uri.decodeComponent(key);

String workspaceSectionPageId(WorkspaceSection section) =>
    '$workspaceSectionPagePrefix${section.name}';

String workspaceModelPageId(String? id) =>
    '$workspaceModelPagePrefix${workspaceEditorKey(id)}';

String workspacePromptPageId(String? id) =>
    '$workspacePromptPagePrefix${workspaceEditorKey(id)}';

String workspaceAccessPageId(WorkspaceSection section, String key) =>
    '$workspaceAccessPagePrefix${section.name}:$key';

String workspaceAccessAddPageId(
  WorkspaceSection section,
  String key, {
  required bool groups,
}) =>
    '$workspaceAccessAddPagePrefix${groups ? 'groups' : 'users'}:'
    '${section.name}:$key';

/// A row of a Workspace page: [field], `:`, the page's key, then [extra],
/// URI-encoded, when the row stands for one item of a list.
String workspaceRowId(String field, String key, [String? extra]) => [
  'workspace.$field',
  key,
  if (extra != null) Uri.encodeComponent(extra),
].join(':');

/// The parts of row [id] made by [workspaceRowId]: the field, the key, and
/// the item, decoded, when there is one. Null for any other id.
({String field, String key, String? extra})? parseWorkspaceRowId(String id) {
  if (!id.startsWith('workspace.')) return null;
  final parts = id.substring('workspace.'.length).split(':');
  if (parts.length < 2) return null;
  return (
    field: parts[0],
    key: parts[1],
    extra: parts.length > 2
        ? Uri.decodeComponent(parts.sublist(2).join(':'))
        : null,
  );
}

/// The section named [name], or null.
WorkspaceSection? workspaceSectionNamed(String name) =>
    WorkspaceSection.values.where((s) => s.name == name).firstOrNull;

NativeSheetItemConfig workspaceNote(
  String id,
  String title, [
  String symbol = 'info.circle',
  String? subtitle,
]) => NativeSheetItemConfig(
  id: id,
  title: title,
  subtitle: subtitle,
  sfSymbol: symbol,
  kind: NativeSheetItemKind.info,
);

/// What went wrong, as a row with a warning sign.
NativeSheetItemConfig workspaceWarning(String id, String title) =>
    workspaceNote(id, title, 'exclamationmark.triangle');

/// The picture a `data:image` URL holds, or null.
Uint8List? workspaceDataUrlBytes(String? url) {
  if (url == null || !url.startsWith('data:image')) return null;
  try {
    return UriData.parse(url).contentAsBytes();
  } on FormatException {
    return null;
  }
}
