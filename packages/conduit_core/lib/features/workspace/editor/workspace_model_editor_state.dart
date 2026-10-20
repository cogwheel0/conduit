import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../navigation/routes.dart' show WorkspaceRouteMode;
import '../models/workspace_common.dart';
import '../models/workspace_model_draft.dart';
import '../models/workspace_resources.dart';
import '../providers/workspace_model_relationships.dart';
import 'workspace_editor_session.dart';

/// Which JSON field stopped [WorkspaceModelEditorState.syncFieldText].
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

/// The model form's free-text fields, as the editor's text inputs hold them.
///
/// The editor keeps its own text controllers; they seed from [fromDraft] and
/// hand their current text back to [WorkspaceModelEditorState.syncFieldText].
@immutable
final class WorkspaceModelFieldText {
  const WorkspaceModelFieldText({
    this.id = '',
    this.name = '',
    this.description = '',
    this.system = '',
    this.stop = '',
    this.terminal = '',
    this.tts = '',
    this.defaultFeatures = '',
    this.params = '',
    this.builtinTools = '',
  });

  /// The text each field starts with: lists comma-joined, JSON maps indented
  /// (an empty map is an empty field).
  factory WorkspaceModelFieldText.fromDraft(WorkspaceModelDraft draft) =>
      WorkspaceModelFieldText(
        id: draft.id,
        name: draft.name,
        description: draft.description,
        system: draft.system,
        stop: draft.stop.join(', '),
        terminal: draft.terminalId,
        tts: draft.ttsVoice,
        defaultFeatures: draft.defaultFeatureIds.join(', '),
        params: _prettyJson(draft.advancedParams),
        builtinTools: _prettyJson(draft.builtinTools),
      );

  final String id;
  final String name;
  final String description;
  final String system;
  final String stop;
  final String terminal;
  final String tts;
  final String defaultFeatures;
  final String params;
  final String builtinTools;

  static String _prettyJson(Map<String, dynamic> value) =>
      value.isEmpty ? '' : const JsonEncoder.withIndent('  ').convert(value);
}

/// Owns mutable model-editor state and exposes typed editing intents.
///
/// Flutter-free: the editor subclasses it with its text controllers and
/// passes their text to [syncFieldText]. The listener API has the shape of
/// Flutter's `ChangeNotifier` (`addListener`, `removeListener`, `dispose`),
/// as [WorkspaceEditorSession]'s does, and session changes are forwarded to
/// the same listeners.
base class WorkspaceModelEditorState {
  WorkspaceModelEditorState({
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
    session.addListener(_notify);
  }

  final bool writeAccess;
  final WorkspaceEditorSession session;
  late final WorkspaceModelDraft _draft;
  final List<void Function()> _listeners = <void Function()>[];

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

  void addListener(void Function() listener) {
    if (_disposed) return;
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  @mustCallSuper
  void dispose() {
    _disposed = true;
    _listeners.clear();
    session.removeListener(_notify);
    session.dispose();
  }

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

  void replaceAccessGrants(
    List<WorkspaceAccessGrantInput> grants, {
    bool markDirty = true,
  }) {
    _draft.accessGrants = List<WorkspaceAccessGrantInput>.from(grants);
    if (markDirty) {
      _notifyDraftMutation();
    } else {
      _notify();
    }
  }

  void toggleHidden() {
    _draft.hidden = !_draft.hidden;
    _notify();
  }

  /// Copies the form's text into the draft. Returns false, records the
  /// [syncIssue] and expands the advanced section when a JSON field does not
  /// hold an object; the draft keeps its previous JSON values then.
  bool syncFieldText(WorkspaceModelFieldText text) {
    _draft.id = text.id.trim();
    _draft.name = text.name;
    _draft.description = text.description;
    _draft.system = text.system;
    _draft.stop = _splitList(text.stop);
    _draft.terminalId = text.terminal;
    _draft.ttsVoice = text.tts;
    _draft.defaultFeatureIds = _splitList(text.defaultFeatures);

    final params = _parseJsonObject(text.params);
    if (params == null) {
      _setSyncIssue(WorkspaceModelDraftSyncIssue.params);
      return false;
    }
    final builtinTools = _parseJsonObject(text.builtinTools);
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

  /// A copy of the draft for a clone: `<id>-copy`, the name plus [suffix],
  /// and no sharing grants.
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

  /// Replaces one relationship list with [selectedIds]. Knowledge keeps each
  /// existing reference (its raw server map) and names new ones from
  /// [options].
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
      case WorkspaceModelRelationshipKind.tools:
        _draft.toolIds = selection;
      case WorkspaceModelRelationshipKind.skills:
        _draft.skillIds = selection;
      case WorkspaceModelRelationshipKind.filters:
        _draft.filterIds = selection;
      case WorkspaceModelRelationshipKind.defaultFilters:
        _draft.defaultFilterIds = selection;
      case WorkspaceModelRelationshipKind.actions:
        _draft.actionIds = selection;
    }
    _notifyDraftMutation();
    return true;
  }

  void _mutate(void Function() mutation) {
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

  /// Calls every listener registered when the notification starts; a
  /// listener removed by an earlier one in the same pass is skipped.
  void _notify() {
    if (_disposed || _listeners.isEmpty) return;
    for (final listener in List<void Function()>.of(_listeners)) {
      if (_listeners.contains(listener)) listener();
    }
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
}

/// Owns the asynchronous load-present-apply workflow for relationships.
final class WorkspaceModelRelationshipCoordinator {
  const WorkspaceModelRelationshipCoordinator(this.controller);

  final WorkspaceModelEditorState controller;

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
