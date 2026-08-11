import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../models/workspace_common.dart';
import '../../models/workspace_model_draft.dart';
import '../../models/workspace_resources.dart';
import '../../providers/workspace_model_relationships.dart';
import '../../widgets/workspace_editor_session.dart';
import '../../workspace_navigation.dart';

enum WorkspaceModelDraftSyncIssue { params, builtinTools }

enum WorkspaceModelRelationshipKind {
  knowledge,
  tools,
  skills,
  filters,
  defaultFilters,
  actions,
}

enum WorkspaceModelRelationshipPickOutcome { cancelled, updated, failed }

@immutable
final class WorkspaceModelRelationshipPickResult {
  const WorkspaceModelRelationshipPickResult._(
    this.outcome, {
    this.error,
    this.stackTrace,
  });

  const WorkspaceModelRelationshipPickResult.cancelled()
    : this._(WorkspaceModelRelationshipPickOutcome.cancelled);

  const WorkspaceModelRelationshipPickResult.updated()
    : this._(WorkspaceModelRelationshipPickOutcome.updated);

  const WorkspaceModelRelationshipPickResult.failed(
    Object error,
    StackTrace stackTrace,
  ) : this._(
        WorkspaceModelRelationshipPickOutcome.failed,
        error: error,
        stackTrace: stackTrace,
      );

  final WorkspaceModelRelationshipPickOutcome outcome;
  final Object? error;
  final StackTrace? stackTrace;
}

/// Owns the text-input lifecycle for a workspace model draft.
final class WorkspaceModelFormBindings {
  WorkspaceModelFormBindings(WorkspaceModelDraft draft)
    : id = TextEditingController(text: draft.id),
      name = TextEditingController(text: draft.name),
      description = TextEditingController(text: draft.description),
      system = TextEditingController(text: draft.system),
      stop = TextEditingController(text: draft.stop.join(', ')),
      terminal = TextEditingController(text: draft.terminalId),
      tts = TextEditingController(text: draft.ttsVoice),
      defaultFeatures = TextEditingController(
        text: draft.defaultFeatureIds.join(', '),
      ),
      params = TextEditingController(
        text: draft.advancedParams.isEmpty
            ? ''
            : const JsonEncoder.withIndent('  ').convert(draft.advancedParams),
      ),
      builtinTools = TextEditingController(
        text: draft.builtinTools.isEmpty
            ? ''
            : const JsonEncoder.withIndent('  ').convert(draft.builtinTools),
      );

  final TextEditingController id;
  final TextEditingController name;
  final TextEditingController description;
  final TextEditingController system;
  final TextEditingController stop;
  final TextEditingController terminal;
  final TextEditingController tts;
  final TextEditingController defaultFeatures;
  final TextEditingController params;
  final TextEditingController builtinTools;

  void dispose() {
    id.dispose();
    name.dispose();
    description.dispose();
    system.dispose();
    stop.dispose();
    terminal.dispose();
    tts.dispose();
    defaultFeatures.dispose();
    params.dispose();
    builtinTools.dispose();
  }
}

/// Owns mutable model-editor state and exposes typed editing intents.
final class WorkspaceModelEditorController extends ChangeNotifier {
  WorkspaceModelEditorController({
    required WorkspaceRouteMode mode,
    required WorkspaceModelDraft initialDraft,
    required this.writeAccess,
    WorkspaceModelSummary? summary,
  }) : session = WorkspaceEditorSession(mode) {
    _draft = initialDraft.deepCopy(
      accessGrants: summary?.accessGrants
          .map(WorkspaceAccessGrantInput.fromGrant)
          .toList(),
    );
    fields = WorkspaceModelFormBindings(_draft);
    session.addListener(_notify);
  }

  final bool writeAccess;
  final WorkspaceEditorSession session;
  late final WorkspaceModelFormBindings fields;
  late final WorkspaceModelDraft _draft;

  bool _advancedExpanded = false;
  WorkspaceModelDraftSyncIssue? _syncIssue;
  bool _avatarRemoved = false;
  bool _disposed = false;

  WorkspaceModelDraft get draft => _draft;
  bool get readOnly => !writeAccess || session.isDetail;
  bool get advancedExpanded => _advancedExpanded;
  WorkspaceModelDraftSyncIssue? get syncIssue => _syncIssue;
  bool get avatarRemoved => _avatarRemoved;
  bool get isDisposed => _disposed;

  void markDirty() => session.markDirty();

  void setBaseModel(String? value) => _mutate(() => _draft.baseModelId = value);

  void removeTag(String tag) => _mutate(() => _draft.tags.remove(tag));

  void addTag(String tag) => _mutate(() => _draft.tags.add(tag));

  void removeSuggestion(int index) =>
      _mutate(() => _draft.suggestionPrompts.removeAt(index));

  void addSuggestion(String prompt) =>
      _mutate(() => _draft.suggestionPrompts.add(prompt));

  void setCapability(String capability, bool value) =>
      _mutate(() => _draft.capabilities[capability] = value);

  void setAdvancedExpanded(bool value) {
    if (_advancedExpanded == value) return;
    _advancedExpanded = value;
    _notify();
  }

  void setAvatar(String dataUrl) {
    _mutate(() {
      _draft.profileImageUrl = dataUrl;
      _avatarRemoved = false;
    });
  }

  void removeAvatar() {
    _mutate(() {
      _draft.profileImageUrl = null;
      _avatarRemoved = true;
    });
  }

  void replaceAccessGrants(List<WorkspaceAccessGrantInput> grants) {
    _draft.accessGrants = List<WorkspaceAccessGrantInput>.from(grants);
    _notify();
  }

  void toggleHidden() {
    _draft.hidden = !_draft.hidden;
    _notify();
  }

  bool syncTextIntoDraft() {
    _draft.id = fields.id.text.trim();
    _draft.name = fields.name.text;
    _draft.description = fields.description.text;
    _draft.system = fields.system.text;
    _draft.stop = _splitList(fields.stop.text);
    _draft.terminalId = fields.terminal.text;
    _draft.ttsVoice = fields.tts.text;
    _draft.defaultFeatureIds = _splitList(fields.defaultFeatures.text);

    final params = _parseJsonObject(fields.params.text);
    if (params == null) {
      _setSyncIssue(WorkspaceModelDraftSyncIssue.params);
      return false;
    }
    final builtinTools = _parseJsonObject(fields.builtinTools.text);
    if (builtinTools == null) {
      _setSyncIssue(WorkspaceModelDraftSyncIssue.builtinTools);
      return false;
    }
    _draft.advancedParams = params;
    _draft.builtinTools = builtinTools;
    if (_syncIssue != null) {
      _syncIssue = null;
      _notify();
    }
    return true;
  }

  WorkspaceModelDraft buildClone(String suffix) {
    return _draft.deepCopy(
      id: '${_draft.id}-copy',
      name: '${_draft.name} $suffix',
      accessGrants: const [],
    );
  }

  List<String> selectedRelationshipIds(WorkspaceModelRelationshipKind kind) =>
      List<String>.unmodifiable(switch (kind) {
        WorkspaceModelRelationshipKind.knowledge => _draft.knowledge.map(
          (item) => item.id,
        ),
        WorkspaceModelRelationshipKind.tools => _draft.toolIds,
        WorkspaceModelRelationshipKind.skills => _draft.skillIds,
        WorkspaceModelRelationshipKind.filters => _draft.filterIds,
        WorkspaceModelRelationshipKind.defaultFilters =>
          _draft.defaultFilterIds,
        WorkspaceModelRelationshipKind.actions => _draft.actionIds,
      });

  Map<WorkspaceModelRelationshipKind, int> get relationshipCounts => {
    WorkspaceModelRelationshipKind.knowledge: _draft.knowledge.length,
    WorkspaceModelRelationshipKind.tools: _draft.toolIds.length,
    WorkspaceModelRelationshipKind.skills: _draft.skillIds.length,
    WorkspaceModelRelationshipKind.filters: _draft.filterIds.length,
    WorkspaceModelRelationshipKind.defaultFilters:
        _draft.defaultFilterIds.length,
    WorkspaceModelRelationshipKind.actions: _draft.actionIds.length,
  };

  bool applyRelationshipSelection(
    WorkspaceModelRelationshipKind kind,
    List<String> selectedIds,
    List<WorkspaceRelationshipOption> options,
  ) {
    if (_disposed) return false;
    final selection = List<String>.from(selectedIds);
    switch (kind) {
      case WorkspaceModelRelationshipKind.knowledge:
        final existing = {for (final item in _draft.knowledge) item.id: item};
        final labels = {for (final option in options) option.id: option.label};
        _draft.knowledge = [
          for (final id in selection)
            existing[id] ??
                WorkspaceModelKnowledgeRef(id: id, name: labels[id] ?? id),
        ];
        break;
      case WorkspaceModelRelationshipKind.tools:
        _draft.toolIds = selection;
        break;
      case WorkspaceModelRelationshipKind.skills:
        _draft.skillIds = selection;
        break;
      case WorkspaceModelRelationshipKind.filters:
        _draft.filterIds = selection;
        break;
      case WorkspaceModelRelationshipKind.defaultFilters:
        _draft.defaultFilterIds = selection;
        break;
      case WorkspaceModelRelationshipKind.actions:
        _draft.actionIds = selection;
        break;
    }
    _notifyDraftMutation();
    return true;
  }

  void _mutate(VoidCallback mutation) {
    mutation();
    _notifyDraftMutation();
  }

  void _notifyDraftMutation() {
    if (session.dirty) {
      _notify();
    } else {
      session.markDirty();
    }
  }

  void _setSyncIssue(WorkspaceModelDraftSyncIssue issue) {
    _syncIssue = issue;
    _advancedExpanded = true;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static List<String> _splitList(String raw) => raw
      .split(RegExp(r'[,\n]'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  static Map<String, dynamic>? _parseJsonObject(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    try {
      final decoded = json.decode(trimmed);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_notify);
    session.dispose();
    fields.dispose();
    super.dispose();
  }
}

/// Owns the asynchronous load-present-apply workflow for relationships.
final class WorkspaceModelRelationshipCoordinator {
  const WorkspaceModelRelationshipCoordinator(this.controller);

  final WorkspaceModelEditorController controller;

  Future<WorkspaceModelRelationshipPickResult> pick(
    WorkspaceModelRelationshipKind kind, {
    required Future<List<WorkspaceRelationshipOption>> Function() load,
    required Future<List<String>?> Function(
      List<WorkspaceRelationshipOption> options,
      List<String> selectedIds,
    )
    present,
  }) async {
    try {
      final options = await load();
      if (controller.isDisposed) {
        return const WorkspaceModelRelationshipPickResult.cancelled();
      }
      final selected = await present(
        options,
        controller.selectedRelationshipIds(kind),
      );
      if (selected == null || controller.isDisposed) {
        return const WorkspaceModelRelationshipPickResult.cancelled();
      }
      controller.applyRelationshipSelection(kind, selected, options);
      return const WorkspaceModelRelationshipPickResult.updated();
    } catch (error, stackTrace) {
      return WorkspaceModelRelationshipPickResult.failed(error, stackTrace);
    }
  }
}
