import 'package:flutter/foundation.dart';

import 'workspace_common.dart';
import 'workspace_resources.dart';

/// Known meta keys that get a dedicated editor field. Any other key present in
/// [WorkspaceModelSummary.meta] is preserved verbatim through [extraMeta] so we
/// never drop server-managed metadata on save.
const _managedMetaKeys = <String>{
  'description',
  'profile_image_url',
  'tags',
  'capabilities',
  'suggestion_prompts',
  'knowledge',
  'toolIds',
  'skillIds',
  'filterIds',
  'defaultFilterIds',
  'actionIds',
  'defaultFeatureIds',
  'builtinTools',
  'terminalId',
  'tts',
  'hidden',
};

/// Params keys with dedicated fields; everything else round-trips through
/// [advancedParams].
const _managedParamKeys = <String>{'system', 'stop'};

/// The canonical capability toggles Open WebUI exposes on a model. Mirrors
/// `DEFAULT_CAPABILITIES` in `ModelEditor.svelte`.
const workspaceModelCapabilityKeys = <String>[
  'vision',
  'file_upload',
  'web_search',
  'image_generation',
  'code_interpreter',
  'citations',
  'usage',
];

List<String> _stringList(dynamic value) => value is List
    ? value
          .where((item) => item != null)
          .map((item) => item.toString())
          .toList()
    : <String>[];

/// Coerces Open WebUI's `meta.tags` shape (`[{name: ...}]`) into plain strings.
List<String> _tagList(dynamic value) {
  if (value is! List) return <String>[];
  final result = <String>[];
  for (final item in value) {
    final tag = switch (item) {
      String() => item,
      Map() => (item['name'] ?? item['id'])?.toString(),
      _ => null,
    };
    final trimmed = tag?.trim();
    if (trimmed != null && trimmed.isNotEmpty && !result.contains(trimmed)) {
      result.add(trimmed);
    }
  }
  return result;
}

Map<String, bool> _capabilityMap(dynamic value) {
  final source = workspaceJsonMap(value);
  return {
    for (final key in workspaceModelCapabilityKeys)
      key: workspaceBool(source[key]),
    // preserve any non-default capabilities the server sent
    ...{
      for (final entry in source.entries)
        if (!workspaceModelCapabilityKeys.contains(entry.key))
          entry.key: workspaceBool(entry.value),
    },
  };
}

/// A knowledge/relationship reference stored on `meta.knowledge`. Open WebUI
/// persists whole objects there, so we keep the raw map to avoid data loss and
/// expose the [id]/[name] for the picker UI.
@immutable
class WorkspaceModelKnowledgeRef {
  const WorkspaceModelKnowledgeRef({
    required this.id,
    required this.name,
    this.raw = const {},
  });

  final String id;
  final String name;
  final Map<String, dynamic> raw;

  factory WorkspaceModelKnowledgeRef.fromJson(Map<String, dynamic> json) =>
      WorkspaceModelKnowledgeRef(
        id: json['id']?.toString() ?? '',
        name:
            json['name']?.toString() ??
            json['title']?.toString() ??
            json['id']?.toString() ??
            '',
        raw: json,
      );

  Map<String, dynamic> toJson() =>
      raw.isNotEmpty ? raw : {'id': id, 'name': name};
}

/// Mutable working copy of a workspace model, split into typed fields for the
/// editor and reconstituted into a [WorkspaceModelForm] on save. Unknown
/// `meta`/`params` keys are preserved so saves are non-destructive.
class WorkspaceModelDraft {
  WorkspaceModelDraft({
    required this.id,
    required this.name,
    this.baseModelId,
    this.description = '',
    this.profileImageUrl,
    List<String>? tags,
    this.system = '',
    List<String>? stop,
    List<String>? suggestionPrompts,
    Map<String, bool>? capabilities,
    List<WorkspaceModelKnowledgeRef>? knowledge,
    List<String>? toolIds,
    List<String>? skillIds,
    List<String>? filterIds,
    List<String>? defaultFilterIds,
    List<String>? actionIds,
    List<String>? defaultFeatureIds,
    Map<String, dynamic>? builtinTools,
    this.terminalId = '',
    this.ttsVoice = '',
    this.isActive = true,
    this.hidden = false,
    Map<String, dynamic>? advancedParams,
    Map<String, dynamic>? extraMeta,
    List<WorkspaceAccessGrantInput>? accessGrants,
  }) : tags = tags ?? <String>[],
       stop = stop ?? <String>[],
       suggestionPrompts = suggestionPrompts ?? <String>[],
       capabilities =
           capabilities ??
           {for (final key in workspaceModelCapabilityKeys) key: false},
       knowledge = knowledge ?? <WorkspaceModelKnowledgeRef>[],
       toolIds = toolIds ?? <String>[],
       skillIds = skillIds ?? <String>[],
       filterIds = filterIds ?? <String>[],
       defaultFilterIds = defaultFilterIds ?? <String>[],
       actionIds = actionIds ?? <String>[],
       defaultFeatureIds = defaultFeatureIds ?? <String>[],
       builtinTools = builtinTools ?? <String, dynamic>{},
       advancedParams = advancedParams ?? <String, dynamic>{},
       extraMeta = extraMeta ?? <String, dynamic>{},
       accessGrants = accessGrants ?? <WorkspaceAccessGrantInput>[];

  String id;
  String name;
  String? baseModelId;
  String description;
  String? profileImageUrl;
  List<String> tags;
  String system;
  List<String> stop;
  List<String> suggestionPrompts;
  Map<String, bool> capabilities;
  List<WorkspaceModelKnowledgeRef> knowledge;
  List<String> toolIds;
  List<String> skillIds;
  List<String> filterIds;
  List<String> defaultFilterIds;
  List<String> actionIds;
  List<String> defaultFeatureIds;
  Map<String, dynamic> builtinTools;
  String terminalId;
  String ttsVoice;
  bool isActive;
  bool hidden;
  Map<String, dynamic> advancedParams;
  Map<String, dynamic> extraMeta;
  List<WorkspaceAccessGrantInput> accessGrants;

  /// Builds a draft for a brand new model.
  factory WorkspaceModelDraft.empty() =>
      WorkspaceModelDraft(id: '', name: '');

  /// Hydrates a draft from an existing summary/detail record.
  factory WorkspaceModelDraft.fromSummary(WorkspaceModelSummary summary) {
    final meta = Map<String, dynamic>.from(summary.meta);
    final params = Map<String, dynamic>.from(summary.params);
    final tts = workspaceJsonMap(meta['tts']);

    return WorkspaceModelDraft(
      id: summary.id,
      name: summary.name,
      baseModelId: summary.baseModelId,
      description: meta['description']?.toString() ?? '',
      profileImageUrl: meta['profile_image_url']?.toString(),
      tags: _tagList(meta['tags']),
      system: params['system']?.toString() ?? '',
      stop: _stringList(params['stop']),
      suggestionPrompts: _stringList(meta['suggestion_prompts']),
      capabilities: _capabilityMap(meta['capabilities']),
      knowledge: workspaceJsonList(meta['knowledge'])
          .map(WorkspaceModelKnowledgeRef.fromJson)
          .toList(),
      toolIds: _stringList(meta['toolIds']),
      skillIds: _stringList(meta['skillIds']),
      filterIds: _stringList(meta['filterIds']),
      defaultFilterIds: _stringList(meta['defaultFilterIds']),
      actionIds: _stringList(meta['actionIds']),
      defaultFeatureIds: _stringList(meta['defaultFeatureIds']),
      builtinTools: workspaceJsonMap(meta['builtinTools']),
      terminalId: meta['terminalId']?.toString() ?? '',
      ttsVoice: tts['voice']?.toString() ?? '',
      isActive: summary.isActive,
      hidden: workspaceBool(meta['hidden']),
      advancedParams: {
        for (final entry in params.entries)
          if (!_managedParamKeys.contains(entry.key)) entry.key: entry.value,
      },
      extraMeta: {
        for (final entry in meta.entries)
          if (!_managedMetaKeys.contains(entry.key)) entry.key: entry.value,
      },
      accessGrants: summary.accessGrants
          .map(WorkspaceAccessGrantInput.fromGrant)
          .toList(),
    );
  }

  /// Reconstructs the `meta` payload, dropping empty managed keys the way Open
  /// WebUI's editor does while preserving unknown keys.
  Map<String, dynamic> buildMeta() {
    final meta = <String, dynamic>{...extraMeta};

    final trimmedDescription = description.trim();
    if (trimmedDescription.isNotEmpty) {
      meta['description'] = trimmedDescription;
    } else {
      meta.remove('description');
    }

    final image = profileImageUrl?.trim();
    if (image != null && image.isNotEmpty) {
      meta['profile_image_url'] = image;
    } else {
      meta.remove('profile_image_url');
    }

    if (tags.isNotEmpty) {
      meta['tags'] = [
        for (final tag in tags) {'name': tag},
      ];
    } else {
      meta.remove('tags');
    }

    meta['capabilities'] = {
      for (final entry in capabilities.entries) entry.key: entry.value,
    };

    _putListOrRemove(meta, 'suggestion_prompts', suggestionPrompts);
    if (knowledge.isNotEmpty) {
      meta['knowledge'] = knowledge.map((ref) => ref.toJson()).toList();
    } else {
      meta.remove('knowledge');
    }
    _putListOrRemove(meta, 'toolIds', toolIds);
    _putListOrRemove(meta, 'skillIds', skillIds);
    _putListOrRemove(meta, 'filterIds', filterIds);
    _putListOrRemove(meta, 'defaultFilterIds', defaultFilterIds);
    _putListOrRemove(meta, 'actionIds', actionIds);
    _putListOrRemove(meta, 'defaultFeatureIds', defaultFeatureIds);

    if (builtinTools.isNotEmpty) {
      meta['builtinTools'] = builtinTools;
    } else {
      meta.remove('builtinTools');
    }

    final terminal = terminalId.trim();
    if (terminal.isNotEmpty) {
      meta['terminalId'] = terminal;
    } else {
      meta.remove('terminalId');
    }

    final voice = ttsVoice.trim();
    if (voice.isNotEmpty) {
      meta['tts'] = {'voice': voice};
    } else {
      meta.remove('tts');
    }

    if (hidden) {
      meta['hidden'] = true;
    } else {
      meta.remove('hidden');
    }

    return meta;
  }

  /// Reconstructs the `params` payload from the advanced map plus the dedicated
  /// system/stop fields.
  Map<String, dynamic> buildParams() {
    final params = <String, dynamic>{...advancedParams};
    final trimmedSystem = system.trim();
    if (trimmedSystem.isNotEmpty) {
      params['system'] = trimmedSystem;
    } else {
      params.remove('system');
    }
    if (stop.isNotEmpty) {
      params['stop'] = stop;
    } else {
      params.remove('stop');
    }
    return params;
  }

  /// Whether the draft has the minimum required fields to be saved.
  bool get isValid => id.trim().isNotEmpty && name.trim().isNotEmpty;

  WorkspaceModelForm toForm() => WorkspaceModelForm(
    id: id.trim(),
    name: name.trim(),
    baseModelId: (baseModelId?.trim().isEmpty ?? true)
        ? null
        : baseModelId!.trim(),
    meta: buildMeta(),
    params: buildParams(),
    accessGrants: normalizedAccessGrants,
    isActive: isActive,
  );

  List<WorkspaceAccessGrantInput> get normalizedAccessGrants {
    final seen = <String>{};
    final result = <WorkspaceAccessGrantInput>[];
    for (final grant in accessGrants) {
      if (grant.principalId.isEmpty) continue;
      final key =
          '${grant.principalType.name}:${grant.principalId}:${grant.permission.name}';
      if (seen.add(key)) result.add(grant);
    }
    return result;
  }

  static void _putListOrRemove(
    Map<String, dynamic> target,
    String key,
    List<String> values,
  ) {
    if (values.isNotEmpty) {
      target[key] = List<String>.from(values);
    } else {
      target.remove(key);
    }
  }
}
