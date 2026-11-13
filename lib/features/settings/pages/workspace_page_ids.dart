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

/// Prefix of a knowledge base's editor; the editor key follows.
const workspaceKnowledgePagePrefix = 'workspace-knowledge:';

/// Prefix of one folder of a knowledge base's files: the editor key, `:`,
/// then the URI-encoded folder id, empty for the top level.
const workspaceKnowledgeFolderPagePrefix = 'workspace-knowledge-folder:';

/// Prefix of a small form acting on a knowledge base's files: its kind
/// (`text`, `folder`, `rename-file`, `rename-folder`, `move`, `attach`),
/// `:`, the editor key, `:`, then the URI-encoded folder or file it is for.
const workspaceKnowledgeFormPagePrefix = 'workspace-knowledge-form:';

/// Prefix of a tool's editor; the editor key follows.
const workspaceToolPagePrefix = 'workspace-tool:';

/// Prefix of the page editing a tool's Python source; the editor key
/// follows.
const workspaceToolCodePagePrefix = 'workspace-tool-code:';

/// Prefix of a tool's valves; the editor key follows.
const workspaceToolValvesPagePrefix = 'workspace-tool-valves:';

/// Prefix of the page loading a new tool from a URL; the editor key follows.
const workspaceToolUrlPagePrefix = 'workspace-tool-url:';

/// Prefix of a skill's editor; the editor key follows.
const workspaceSkillPagePrefix = 'workspace-skill:';

/// Prefix of the page editing a skill's instructions; the editor key
/// follows.
const workspaceSkillContentPagePrefix = 'workspace-skill-content:';

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

String workspaceKnowledgePageId(String? id) =>
    '$workspaceKnowledgePagePrefix${workspaceEditorKey(id)}';

/// The page of folder [directoryId] (empty for the top level) of the
/// knowledge base whose editor is [key].
String workspaceKnowledgeFolderPageId(String key, String directoryId) =>
    '$workspaceKnowledgeFolderPagePrefix$key:'
    '${Uri.encodeComponent(directoryId)}';

/// The form of [kind] for [target], a folder or file id, of the knowledge
/// base whose editor is [key].
String workspaceKnowledgeFormPageId(String kind, String key, String target) =>
    '$workspaceKnowledgeFormPagePrefix$kind:$key:'
    '${Uri.encodeComponent(target)}';

/// The editor key and the decoded folder id of a knowledge folder page, or
/// null for any other id.
({String key, String directoryId})? workspaceKnowledgeFolderOf(String id) {
  if (!id.startsWith(workspaceKnowledgeFolderPagePrefix)) return null;
  final parts = id
      .substring(workspaceKnowledgeFolderPagePrefix.length)
      .split(':');
  if (parts.length != 2) return null;
  return (key: parts[0], directoryId: Uri.decodeComponent(parts[1]));
}

/// The kind, editor key and decoded target of a knowledge form page, or
/// null for any other id.
({String kind, String key, String target})? workspaceKnowledgeFormOf(
  String id,
) {
  if (!id.startsWith(workspaceKnowledgeFormPagePrefix)) return null;
  final parts = id
      .substring(workspaceKnowledgeFormPagePrefix.length)
      .split(':');
  if (parts.length != 3) return null;
  return (kind: parts[0], key: parts[1], target: Uri.decodeComponent(parts[2]));
}

String workspaceToolPageId(String? id) =>
    '$workspaceToolPagePrefix${workspaceEditorKey(id)}';

String workspaceSkillPageId(String? id) =>
    '$workspaceSkillPagePrefix${workspaceEditorKey(id)}';

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
