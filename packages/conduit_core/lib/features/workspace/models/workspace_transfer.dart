import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_model_draft.dart';
import 'package:conduit_core/features/workspace/models/workspace_prompt_command.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/models/workspace_skill_content.dart';
import 'package:conduit_core/features/workspace/models/workspace_tool_content.dart';

// Import and export shapes for the workspace sections, shared by the mobile
// editors and the desktop daemon so a file exported from one imports into
// the other. They follow Open WebUI's own export files.

/// Coerces decoded JSON into a list of item maps. Accepts a bare list, a single
/// object, or an envelope of the form `{ "items": [...] }` / `{ "<key>": [...] }`.
List<Map<String, dynamic>> workspaceImportItemsFromJson(dynamic decoded) {
  if (decoded is List) {
    return workspaceJsonList(decoded);
  }
  if (decoded is Map) {
    final map = workspaceJsonMap(decoded);
    for (final value in map.values) {
      if (value is List) return workspaceJsonList(value);
    }
    // A single object is treated as a one-item import.
    return [map];
  }
  return const [];
}

/// Applies front-matter overrides from a loaded/import tool payload, mirroring
/// Open WebUI's ImportModal: an id defaults to `nameToId(name)`, a front-matter
/// `title` overrides the name, and the description falls back to the name.
Map<String, dynamic> normalizeImportedTool(Map<String, dynamic> tool) {
  final result = Map<String, dynamic>.from(tool);
  final name = result['name']?.toString() ?? '';
  final content = result['content']?.toString() ?? '';
  final rawId = result['id']?.toString().trim() ?? '';
  final frontmatter = WorkspaceToolContent.parseFrontmatter(content);

  final title = frontmatter['title']?.trim();
  final resolvedName = (title != null && title.isNotEmpty) ? title : name;
  result['name'] = resolvedName;
  // Derive the id from the original name *before* the front-matter title
  // override (matching upstream's ImportModal), so a payload like
  // `{name: 'main', content: '---\ntitle: Web Search\n---'}` keeps id `main`
  // rather than retargeting to `web_search`.
  var derivedId = rawId;
  if (derivedId.isEmpty) {
    derivedId = WorkspaceToolContent.nameToId(name);
  }
  // A whitespace-/punctuation-only name is non-empty but slugifies to '', so
  // fall back to the front-matter title (then a safe default) — otherwise the
  // id would be empty/invalid and rejected by the server.
  if (derivedId.isEmpty) {
    derivedId = WorkspaceToolContent.nameToId(resolvedName);
  }
  if (derivedId.isEmpty) {
    derivedId = 'tool';
  }
  result['id'] = derivedId;

  final meta = workspaceJsonMap(result['meta']);
  final fmDescription = frontmatter['description']?.trim();
  meta['description'] = (fmDescription != null && fmDescription.isNotEmpty)
      ? fmDescription
      : (meta['description']?.toString() ?? resolvedName);
  result['meta'] = meta;
  return result;
}

WorkspacePromptForm workspacePromptFormFromImport(Map<String, dynamic> json) {
  final rawCommand = json['command']?.toString() ?? '';
  final name = json['name']?.toString() ?? json['title']?.toString() ?? '';
  final command = WorkspacePromptCommand.strip(rawCommand);
  return WorkspacePromptForm(
    command: command.isEmpty ? WorkspacePromptCommand.slugify(name) : command,
    name: name,
    content: json['content']?.toString() ?? '',
    tags: workspaceStringList(json['tags']),
    meta: json['meta'] is Map ? workspaceJsonMap(json['meta']) : null,
    data: json['data'] is Map ? workspaceJsonMap(json['data']) : null,
  );
}

Map<String, dynamic> workspacePromptExportMap(WorkspacePromptSummary item) => {
  'command': WorkspacePromptCommand.strip(item.command),
  'name': item.name,
  'content': item.content,
  'tags': item.tags,
  if (item.meta != null) 'meta': item.meta,
  if (item.data != null) 'data': item.data,
};

WorkspaceToolForm workspaceToolFormFromImport(Map<String, dynamic> json) {
  final normalized = normalizeImportedTool(json);
  final rawId = normalized['id']?.toString().trim() ?? '';
  final name = normalized['name']?.toString() ?? '';
  final id = rawId.isEmpty ? WorkspaceToolContent.nameToId(name) : rawId;
  return WorkspaceToolForm(
    id: id,
    name: name,
    content: normalized['content']?.toString() ?? '',
    meta: workspaceJsonMap(normalized['meta']),
  );
}

WorkspaceSkillForm workspaceSkillFormFromImport(Map<String, dynamic> json) {
  final rawId = json['id']?.toString().trim() ?? '';
  final name = json['name']?.toString() ?? json['title']?.toString() ?? '';
  final id = rawId.isEmpty ? WorkspaceSkillContent.slugify(name) : rawId;
  return WorkspaceSkillForm(
    id: id,
    name: name,
    description: json['description']?.toString(),
    content: json['content']?.toString() ?? '',
    meta: json['meta'] is Map ? workspaceJsonMap(json['meta']) : const {},
    isActive: workspaceBool(json['is_active'], true),
  );
}

Map<String, dynamic> workspaceSkillExportMap(WorkspaceSkillSummary item) => {
  'id': item.id,
  'name': item.name,
  if (item.description != null) 'description': item.description,
  'content': item.content ?? '',
  'meta': item.meta,
  'is_active': item.isActive,
};

/// A model as Open WebUI's model import reads it.
Map<String, dynamic> workspaceModelExportMap(WorkspaceModelSummary item) =>
    WorkspaceModelDraft.fromSummary(item).toForm().toJson();
