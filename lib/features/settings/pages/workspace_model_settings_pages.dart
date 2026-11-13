import 'dart:async';
import 'dart:ui' show PlatformDispatcher, Offset, Rect;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/editor/workspace_model_editor_state.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_model_draft.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_model_relationships.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../workspace/services/workspace_model_avatar_codec.dart';
import '../../workspace/widgets/workspace_access_grants.dart'
    show workspaceAccessSummary;
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'workspace_access_settings_pages.dart';
import 'workspace_page_ids.dart';
import 'workspace_settings_pages.dart'
    show workspaceExportControllerProvider, workspaceSectionCapabilities;

/// A model's editor while its page is open: the account it opened for, the
/// model's state, and the text typed into its fields.
final class WorkspaceModelEditor {
  WorkspaceModelEditor(this.key, this.session);

  final String key;

  /// The account the editor opened for; null when none was signed in.
  final WorkspaceSessionIdentity? session;

  WorkspaceModelEditorState? state;
  WorkspaceModelSummary? summary;
  bool loading = false;
  bool loadFailed = false;
  WorkspaceModelFieldText text = const WorkspaceModelFieldText();
  bool busy = false;

  /// What the editor last said, and whether it went wrong.
  String? notice;
  bool noticeIsError = true;

  /// Whether the editor page was last drawn as edited.
  bool shownEdited = false;

  final Map<WorkspaceModelRelationshipKind, List<WorkspaceRelationshipOption>>
  options = {};
  final Set<WorkspaceModelRelationshipKind> optionsLoading = {};
  final Set<WorkspaceModelRelationshipKind> optionsFailed = {};

  bool get isCreate => key == workspaceNewKey;
  bool get readOnly => state?.readOnly ?? true;
  bool get edited => state?.session.dirty ?? false;

  void adopt(WorkspaceModelEditorState next, {WorkspaceModelSummary? from}) {
    state?.dispose();
    state = next;
    summary = from;
    text = WorkspaceModelFieldText.fromDraft(next.draft);
    loadFailed = false;
  }

  void dispose() {
    state?.dispose();
    state = null;
  }
}

/// [text] with [field] set to [value].
WorkspaceModelFieldText _withText(
  WorkspaceModelFieldText text,
  String field,
  String value,
) => WorkspaceModelFieldText(
  id: field == 'id' ? value : text.id,
  name: field == 'name' ? value : text.name,
  description: field == 'description' ? value : text.description,
  system: field == 'system' ? value : text.system,
  stop: field == 'stop' ? value : text.stop,
  terminal: field == 'terminal' ? value : text.terminal,
  tts: field == 'tts' ? value : text.tts,
  defaultFeatures: field == 'features' ? value : text.defaultFeatures,
  params: field == 'params' ? value : text.params,
  builtinTools: field == 'builtin' ? value : text.builtinTools,
);

/// What model capability [key] is called. A capability a newer server adds
/// reads as its key.
String workspaceModelCapabilityLabel(AppLocalizations l10n, String key) =>
    switch (key) {
      'vision' => l10n.workspaceModelCapabilityVision,
      'file_upload' => l10n.workspaceModelCapabilityFileUpload,
      'web_search' => l10n.webSearch,
      'image_generation' => l10n.imageGeneration,
      'code_interpreter' => l10n.codeInterpreter,
      'citations' => l10n.workspaceModelCapabilityCitations,
      'usage' => l10n.workspaceModelCapabilityUsage,
      _ => key,
    };

String _relationshipTitle(
  AppLocalizations l10n,
  WorkspaceModelRelationshipKind kind,
) => switch (kind) {
  WorkspaceModelRelationshipKind.knowledge => l10n.workspaceModelKnowledge,
  WorkspaceModelRelationshipKind.tools => l10n.workspaceModelTools,
  WorkspaceModelRelationshipKind.skills => l10n.workspaceModelSkills,
  WorkspaceModelRelationshipKind.filters => l10n.workspaceModelFilters,
  WorkspaceModelRelationshipKind.defaultFilters =>
    l10n.workspaceModelDefaultFilters,
  WorkspaceModelRelationshipKind.actions => l10n.workspaceModelActions,
};

String _relationshipSymbol(WorkspaceModelRelationshipKind kind) =>
    switch (kind) {
      WorkspaceModelRelationshipKind.knowledge => 'books.vertical',
      WorkspaceModelRelationshipKind.tools => 'wrench.and.screwdriver',
      WorkspaceModelRelationshipKind.skills => 'graduationcap',
      WorkspaceModelRelationshipKind.filters =>
        'line.3.horizontal.decrease.circle',
      WorkspaceModelRelationshipKind.defaultFilters => 'checklist',
      WorkspaceModelRelationshipKind.actions => 'bolt',
    };

String workspaceModelRelationshipPageId(
  WorkspaceModelRelationshipKind kind,
  String key,
) => '$workspaceModelRelationshipPagePrefix${kind.name}:$key';

/// A model's editor page: its picture, name and id, base model,
/// description and tags; its system prompt and suggested prompts; what it
/// may use; who may open it; Advanced; and, for a saved model, the actions
/// on it. A model the account may only view reads without fields.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceModelPage(
  AppLocalizations l10n, {
  required WorkspaceModelEditor editor,
  required WorkspaceSectionCapabilities capabilities,
  required List<WorkspaceRelationshipOption>? baseModels,
  required bool baseModelRequired,
  bool baseModelsFailed = false,
}) {
  final key = editor.key;
  final pageId = '$workspaceModelPagePrefix$key';
  final state = editor.state;
  final fallbackTitle = editor.isCreate
      ? l10n.workspaceModelNewTitle
      : l10n.workspaceModels;
  if (state == null) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: fallbackTitle,
      items: [
        if (editor.loadFailed)
          NativeSheetItemConfig(
            id: workspaceRowId('model-retry', key),
            title: l10n.workspaceLoadFailed,
            subtitle: l10n.workspaceRetry,
            sfSymbol: 'exclamationmark.triangle',
            showsDisclosure: false,
          )
        else
          buildNativeLoadingItem(l10n, id: '$pageId-loading'),
      ],
    );
  }
  final draft = state.draft;
  final text = editor.text;
  final readOnly = editor.readOnly;
  final locked = readOnly || editor.busy;
  final name = text.name.trim();
  NativeSheetItemConfig field(
    String field,
    String title,
    String value, {
    String symbol = 'textformat',
    bool multiline = false,
    String? placeholder,
  }) => NativeSheetItemConfig(
    id: workspaceRowId('model-$field', key),
    title: title,
    sfSymbol: symbol,
    kind: readOnly
        ? NativeSheetItemKind.readOnlyText
        : multiline
        ? NativeSheetItemKind.multilineTextField
        : NativeSheetItemKind.textField,
    value: value,
    placeholder: placeholder ?? title,
    disabled: editor.busy,
  );
  final avatar = workspaceDataUrlBytes(draft.profileImageUrl);
  final counts = state.relationshipCounts;
  return NativeSheetDetailConfig(
    id: pageId,
    title: editor.isCreate
        ? l10n.workspaceModelNewTitle
        : (name.isEmpty ? fallbackTitle : name),
    confirmActionId: readOnly ? null : workspaceRowId('model-save', key),
    confirmActionLabel: l10n.save,
    discardPrompt: readOnly ? null : nativeDiscardPrompt(l10n),
    edited: editor.edited,
    busy: editor.busy,
    announcement: editor.notice,
    sections: [
      if (editor.notice != null)
        NativeSheetSectionConfig(
          items: [
            editor.noticeIsError
                ? workspaceWarning('$pageId-notice', editor.notice!)
                : workspaceNote(
                    '$pageId-notice',
                    editor.notice!,
                    'checkmark.circle',
                  ),
          ],
        ),
      if (readOnly && !editor.isCreate)
        NativeSheetSectionConfig(
          items: [
            workspaceNote(
              '$pageId-read-only',
              l10n.workspaceReadOnlyExplanation,
              'lock',
            ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: '$pageId-image',
            title: l10n.workspaceModelProfileImage,
            sfSymbol: 'photo',
            kind: NativeSheetItemKind.info,
            avatarBytes: avatar,
            avatarName: avatar == null ? null : name,
          ),
          if (!locked)
            NativeSheetItemConfig(
              id: workspaceRowId('model-image-pick', key),
              title: l10n.workspaceModelChangeImage,
              sfSymbol: 'photo.badge.plus',
              accent: true,
              showsDisclosure: false,
            ),
          if (!locked && draft.profileImageUrl != null)
            NativeSheetItemConfig(
              id: workspaceRowId('model-image-remove', key),
              title: l10n.workspaceModelRemoveImage,
              sfSymbol: 'xmark.circle',
              showsDisclosure: false,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.workspaceModelSectionBasics,
        items: [
          field('name', l10n.workspaceModelName, text.name, symbol: 'cube'),
          if (editor.isCreate)
            field('id', l10n.workspaceModelIdLabel, text.id, symbol: 'number')
          else
            NativeSheetItemConfig(
              id: '$pageId-id',
              title: l10n.workspaceModelIdLabel,
              subtitle: draft.id,
              sfSymbol: 'number',
              kind: NativeSheetItemKind.info,
            ),
          NativeSheetItemConfig(
            id: workspaceRowId('model-base', key),
            title: l10n.workspaceModelBaseModel,
            sfSymbol: 'cpu',
            kind: readOnly
                ? NativeSheetItemKind.info
                : NativeSheetItemKind.searchablePicker,
            subtitle: readOnly
                ? (draft.baseModelId?.trim().isEmpty ?? true
                      ? l10n.workspaceModelBaseModelNone
                      : draft.baseModelId)
                : null,
            value: draft.baseModelId?.trim() ?? '',
            disabled: editor.busy || baseModels == null,
            options: [
              if (!baseModelRequired)
                NativeSheetOptionConfig(
                  id: '',
                  label: l10n.workspaceModelBaseModelNone,
                ),
              for (final option
                  in baseModels ?? const <WorkspaceRelationshipOption>[])
                NativeSheetOptionConfig(
                  id: option.id,
                  label: option.label,
                  subtitle: option.subtitle == option.label
                      ? null
                      : option.subtitle,
                ),
            ],
          ),
          if (!readOnly && baseModels == null && baseModelsFailed)
            NativeSheetItemConfig(
              id: workspaceRowId('model-base-retry', key),
              title: l10n.workspaceLoadFailed,
              subtitle: l10n.workspaceRetry,
              sfSymbol: 'exclamationmark.triangle',
              showsDisclosure: false,
            ),
          field(
            'description',
            l10n.workspaceModelDescription,
            text.description,
            symbol: 'text.alignleft',
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.workspaceModelTags,
        items: [
          for (final tag in draft.tags)
            NativeSheetItemConfig(
              id: '$pageId-tag-${Uri.encodeComponent(tag)}',
              title: tag,
              sfSymbol: 'tag',
              kind: NativeSheetItemKind.info,
              rowActions: [
                if (!locked)
                  NativeSheetRowAction(
                    id: workspaceRowId('model-tag-remove', key, tag),
                    label: l10n.delete,
                    sfSymbol: 'trash',
                    destructive: true,
                  ),
              ],
            ),
          if (!locked)
            NativeSheetItemConfig(
              id: workspaceRowId('model-tag-add', key),
              title: l10n.workspaceModelTagsHint,
              sfSymbol: 'plus.circle',
              kind: NativeSheetItemKind.textField,
              value: '',
              placeholder: l10n.workspaceModelTagsHint,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.workspaceModelSectionPrompt,
        items: [
          field(
            'system',
            l10n.workspaceModelSystemPrompt,
            text.system,
            symbol: 'text.bubble',
            multiline: true,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.workspaceModelSuggestionPrompts,
        items: [
          for (final (index, prompt) in draft.suggestionPrompts.indexed)
            NativeSheetItemConfig(
              id: '$pageId-suggestion-$index',
              title: prompt,
              sfSymbol: 'lightbulb',
              kind: NativeSheetItemKind.info,
              rowActions: [
                if (!locked)
                  NativeSheetRowAction(
                    id: workspaceRowId(
                      'model-suggestion-remove',
                      key,
                      '$index',
                    ),
                    label: l10n.workspaceModelRemoveSuggestion,
                    sfSymbol: 'trash',
                    destructive: true,
                  ),
              ],
            ),
          if (!locked)
            NativeSheetItemConfig(
              id: workspaceRowId('model-suggestion-add', key),
              title: l10n.workspaceModelAddSuggestion,
              sfSymbol: 'plus.circle',
              kind: NativeSheetItemKind.textField,
              value: '',
              placeholder: l10n.workspaceModelAddSuggestion,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.workspaceModelSectionRelationships,
        items: [
          for (final kind in WorkspaceModelRelationshipKind.values)
            NativeSheetItemConfig(
              id: workspaceModelRelationshipPageId(kind, key),
              title: _relationshipTitle(l10n, kind),
              subtitle: (counts[kind] ?? 0) == 0
                  ? l10n.workspaceModelSelectNone
                  : l10n.workspaceModelSelectCount(counts[kind]!),
              sfSymbol: _relationshipSymbol(kind),
            ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.workspaceModelSectionAccess,
        items: [
          NativeSheetItemConfig(
            id: workspaceAccessPageId(WorkspaceSection.models, key),
            title: l10n.workspaceModelManageAccess,
            subtitle: workspaceAccessSummary(
              l10n,
              draft.normalizedAccessGrants,
            ),
            sfSymbol: 'person.2',
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: '$workspaceModelAdvancedPagePrefix$key',
            title: l10n.workspaceModelSectionAdvanced,
            subtitle: state.syncIssue == null
                ? null
                : l10n.workspaceModelInvalidJson,
            sfSymbol: state.syncIssue == null
                ? 'slider.horizontal.3'
                : 'exclamationmark.triangle',
          ),
        ],
      ),
      if (!editor.isCreate)
        NativeSheetSectionConfig(
          items: [
            if (state.writeAccess)
              NativeSheetItemConfig(
                id: workspaceRowId('model-clone', key),
                title: l10n.workspaceModelClone,
                sfSymbol: 'plus.square.on.square',
                showsDisclosure: false,
                disabled: editor.busy,
              ),
            if (state.writeAccess)
              NativeSheetItemConfig(
                id: workspaceRowId('model-active', key),
                title: draft.isActive
                    ? l10n.workspaceModelDeactivate
                    : l10n.workspaceModelActivate,
                sfSymbol: draft.isActive ? 'pause.circle' : 'play.circle',
                showsDisclosure: false,
                disabled: editor.busy,
              ),
            if (state.writeAccess)
              NativeSheetItemConfig(
                id: workspaceRowId('model-hidden', key),
                title: draft.hidden
                    ? l10n.workspaceModelUnhide
                    : l10n.workspaceModelHide,
                sfSymbol: draft.hidden ? 'eye' : 'eye.slash',
                showsDisclosure: false,
                disabled: editor.busy,
              ),
            if (capabilities.exportItems)
              NativeSheetItemConfig(
                id: workspaceRowId('model-export', key),
                title: l10n.workspaceModelExport,
                sfSymbol: 'square.and.arrow.up',
                showsDisclosure: false,
                disabled: editor.busy,
              ),
            if (state.writeAccess)
              NativeSheetItemConfig(
                id: workspaceRowId('model-delete', key),
                title: l10n.workspaceModelDelete,
                sfSymbol: 'trash',
                destructive: true,
                showsDisclosure: false,
                disabled: editor.busy,
                confirmMessage: l10n.workspaceModelDeleteConfirmMessage(
                  name.isEmpty ? draft.id : name,
                ),
              ),
          ],
        ),
    ],
  );
}

/// A model editor's Advanced page: what the model can do, its stop
/// sequences, terminal and voice, its default features, and its
/// parameters and built-in tools as JSON.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceModelAdvancedPage(
  AppLocalizations l10n, {
  required WorkspaceModelEditor editor,
}) {
  final key = editor.key;
  final pageId = '$workspaceModelAdvancedPagePrefix$key';
  final state = editor.state;
  if (state == null) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: l10n.workspaceModelSectionAdvanced,
      items: [buildNativeLoadingItem(l10n, id: '$pageId-loading')],
    );
  }
  final readOnly = editor.readOnly;
  final text = editor.text;
  NativeSheetItemConfig field(
    String field,
    String title,
    String value, {
    String symbol = 'textformat',
    bool multiline = false,
    String? placeholder,
  }) => NativeSheetItemConfig(
    id: workspaceRowId('model-$field', key),
    title: title,
    sfSymbol: symbol,
    kind: readOnly
        ? NativeSheetItemKind.readOnlyText
        : multiline
        ? NativeSheetItemKind.multilineTextField
        : NativeSheetItemKind.textField,
    value: value,
    placeholder: placeholder ?? title,
    disabled: editor.busy,
  );
  final issue = state.syncIssue;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.workspaceModelSectionAdvanced,
    sections: [
      if (issue != null)
        NativeSheetSectionConfig(
          items: [
            workspaceWarning('$pageId-issue', l10n.workspaceModelInvalidJson),
          ],
        ),
      NativeSheetSectionConfig(
        title: l10n.workspaceModelCapabilities,
        items: [
          for (final entry in state.draft.capabilities.entries)
            NativeSheetItemConfig(
              id: workspaceRowId('model-capability', key, entry.key),
              title: workspaceModelCapabilityLabel(l10n, entry.key),
              sfSymbol: 'checkmark.seal',
              kind: NativeSheetItemKind.toggle,
              value: entry.value,
              disabled: readOnly || editor.busy,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        footer: readOnly ? null : l10n.workspaceModelStopHint,
        items: [
          field(
            'stop',
            l10n.workspaceModelStopSequences,
            text.stop,
            symbol: 'stop.circle',
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          field(
            'terminal',
            l10n.workspaceModelTerminal,
            text.terminal,
            symbol: 'terminal',
          ),
          field(
            'tts',
            l10n.workspaceModelTtsVoice,
            text.tts,
            symbol: 'speaker.wave.2',
          ),
          field(
            'features',
            l10n.workspaceModelDefaultFeatures,
            text.defaultFeatures,
            symbol: 'switch.2',
          ),
        ],
      ),
      NativeSheetSectionConfig(
        footer: readOnly ? null : l10n.workspaceModelParamsHint,
        items: [
          field(
            'params',
            l10n.workspaceModelAdvancedParams,
            text.params,
            symbol: issue == WorkspaceModelDraftSyncIssue.params
                ? 'exclamationmark.triangle'
                : 'curlybraces',
            multiline: true,
          ),
          field(
            'builtin',
            l10n.workspaceModelBuiltinTools,
            text.builtinTools,
            symbol: issue == WorkspaceModelDraftSyncIssue.builtinTools
                ? 'exclamationmark.triangle'
                : 'curlybraces.square',
            multiline: true,
          ),
        ],
      ),
    ],
  );
}

/// A model editor's page choosing one kind of relationship: a check per
/// knowledge base, tool, skill, filter or action the server offers.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceModelRelationshipPage(
  AppLocalizations l10n, {
  required WorkspaceModelEditor editor,
  required WorkspaceModelRelationshipKind kind,
}) {
  final key = editor.key;
  final pageId = workspaceModelRelationshipPageId(kind, key);
  final state = editor.state;
  final options = editor.options[kind];
  final selected = state?.selectedRelationshipIds(kind).toSet() ?? const {};
  final locked = editor.readOnly || editor.busy;
  // What is chosen but no longer offered stays listed, so it can be
  // unchosen.
  final offered = {for (final option in options ?? const []) option.id};
  return NativeSheetDetailConfig(
    id: pageId,
    title: _relationshipTitle(l10n, kind),
    items: [
      if (state == null ||
          (options == null && editor.optionsLoading.contains(kind)))
        buildNativeLoadingItem(l10n, id: '$pageId-loading')
      else if (options == null && editor.optionsFailed.contains(kind))
        NativeSheetItemConfig(
          id: workspaceRowId('model-relationship-retry', key, kind.name),
          title: l10n.workspaceLoadFailed,
          subtitle: l10n.workspaceRetry,
          sfSymbol: 'exclamationmark.triangle',
          showsDisclosure: false,
        )
      else ...[
        if ((options ?? const []).isEmpty &&
            selected.every((id) => !offered.contains(id)) &&
            selected.isEmpty)
          workspaceNote(
            '$pageId-empty',
            l10n.workspaceModelRelationshipEmpty,
            _relationshipSymbol(kind),
          ),
        for (final option in options ?? const <WorkspaceRelationshipOption>[])
          NativeSheetItemConfig(
            id: workspaceRowId(
              'model-relationship',
              key,
              '${kind.name}|${option.id}',
            ),
            title: option.label,
            subtitle: option.subtitle,
            sfSymbol: _relationshipSymbol(kind),
            checked: selected.contains(option.id),
            showsDisclosure: false,
            disabled: locked,
          ),
        for (final id in selected)
          if (!offered.contains(id))
            NativeSheetItemConfig(
              id: workspaceRowId('model-relationship', key, '${kind.name}|$id'),
              title: id,
              sfSymbol: _relationshipSymbol(kind),
              checked: true,
              showsDisclosure: false,
              disabled: locked,
            ),
      ],
    ],
  );
}

/// Models' editors in Settings.
class WorkspaceModelSettingsPages extends SettingsPageModule {
  WorkspaceModelSettingsPages(this._ref) {
    _access = WorkspaceAccessPages(
      _ref,
      section: WorkspaceSection.models,
      onSave: _saveAccess,
      onDone: _accessDone,
    );
  }

  final Ref _ref;
  late final WorkspaceAccessPages _access;
  AppLocalizations? _l10n;
  final Map<String, WorkspaceModelEditor> _editors = {};
  List<WorkspaceRelationshipOption>? _baseModels;
  WorkspaceSessionIdentity? _baseModelsSession;
  bool _baseModelsLoading = false;
  bool _baseModelsFailed = false;

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);
  WorkspaceModels get _notifier => _ref.read(workspaceModelsProvider.notifier);

  WorkspaceSectionCapabilities get _capabilities =>
      workspaceSectionCapabilities(
        _ref.read(workspaceCapabilitiesProvider).value,
        WorkspaceSection.models,
      );

  bool get _isAdmin => _ref.read(currentUserProvider2)?.role == 'admin';

  bool _baseModelRequired(WorkspaceModelEditor editor) =>
      !_isAdmin &&
      (editor.isCreate ||
          (editor.summary?.baseModelId?.trim().isNotEmpty ?? false));

  @override
  bool ownsPage(String detailId) =>
      detailId.startsWith(workspaceModelPagePrefix) ||
      detailId.startsWith(workspaceModelAdvancedPagePrefix) ||
      detailId.startsWith(workspaceModelRelationshipPagePrefix) ||
      _access.ownsPage(detailId);

  WorkspaceSessionIdentity? _session() {
    try {
      return WorkspaceSessionIdentity.read(_ref);
    } on StateError {
      return null;
    }
  }

  /// Whether [editor] is still open, for the account it opened for.
  bool _current(WorkspaceModelEditor editor) =>
      identical(_editors[editor.key], editor) &&
      (editor.session?.isCurrent(_ref) ?? false);

  /// Drops the editor [key] names when it was opened for an account since
  /// gone, unseen, with its access draft; returns whether it did.
  bool _dropStale(String? key) {
    final editor = key == null ? null : _editors[key];
    if (key == null || editor == null || _current(editor)) return false;
    _editors.remove(key);
    _access.forget(key);
    return true;
  }

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    if (_access.ownsPage(detailId)) {
      final key = _access.editorKeyOf(detailId);
      // A page of another account's editor: closed, never drawn for this one.
      if (_dropStale(key)) {
        await _surface.closeDetail(detailId);
        return;
      }
      final editor = key == null ? null : _editors[key];
      final state = editor?.state;
      if (editor != null && state != null) {
        _access.open(
          editorKey: editor.key,
          grants: state.draft.normalizedAccessGrants,
          readOnly: state.readOnly,
          saveOnDone: !editor.isCreate,
          resourceName: editor.text.name.trim().isEmpty
              ? null
              : editor.text.name.trim(),
        );
      }
      await _access.hydrate(detailId, l10n);
      return;
    }
    if (detailId.startsWith(workspaceModelAdvancedPagePrefix)) {
      final key = detailId.substring(workspaceModelAdvancedPagePrefix.length);
      // A page of an editor gone, or of another account's: closed, never
      // drawn for this one.
      final editor = _dropStale(key) ? null : _editors[key];
      if (editor == null) {
        await _surface.closeDetail(detailId);
        return;
      }
      await _applyAdvanced(l10n, editor);
      return;
    }
    if (detailId.startsWith(workspaceModelRelationshipPagePrefix)) {
      final rest = detailId.substring(
        workspaceModelRelationshipPagePrefix.length,
      );
      final colon = rest.indexOf(':');
      if (colon < 0) return;
      final kind = WorkspaceModelRelationshipKind.values
          .where((value) => value.name == rest.substring(0, colon))
          .firstOrNull;
      if (kind == null) return;
      final key = rest.substring(colon + 1);
      final editor = _dropStale(key) ? null : _editors[key];
      if (editor == null) {
        await _surface.closeDetail(detailId);
        return;
      }
      await _applyRelationship(l10n, editor, kind);
      unawaited(_loadOptions(editor, kind));
      return;
    }
    final key = detailId.substring(workspaceModelPagePrefix.length);
    final open = _editors[key];
    if (open != null && _current(open)) {
      // Back from one of its own pages.
      await _applyEditor(l10n, open);
      return;
    }
    // Another account's editor, kept from before it signed in: dropped
    // unseen, with its access draft, and this account's model read afresh.
    _dropStale(key);
    final editor = _editors[key] = WorkspaceModelEditor(key, _session());
    unawaited(_loadBaseModels());
    if (editor.isCreate) {
      editor.adopt(
        WorkspaceModelEditorState(
          mode: WorkspaceRouteMode.create,
          initialDraft: WorkspaceModelDraft.empty(),
          writeAccess: true,
        ),
      );
      await _applyEditor(l10n, editor);
      return;
    }
    await _applyEditor(l10n, editor);
    await _load(editor);
  }

  @override
  void pageLeft(String detailId) {
    if (_access.ownsPage(detailId)) {
      _access.pageLeft(detailId);
      return;
    }
    if (detailId.startsWith(workspaceModelPagePrefix)) {
      final key = detailId.substring(workspaceModelPagePrefix.length);
      // Left, the edit is abandoned, its access list with it.
      _editors.remove(key)?.dispose();
      _access.forget(key);
      // The last editor gone, the next one reads the server's base models
      // afresh: Settings's own pages are never closed as the sheet is.
      if (_editors.isEmpty) _forgetBaseModels();
    }
  }

  void _forgetBaseModels() {
    if (_baseModels != null || _baseModelsFailed) {
      _ref.invalidate(workspaceBaseModelsProvider);
    }
    _baseModels = null;
    _baseModelsSession = null;
    _baseModelsFailed = false;
  }

  @override
  void settingsClosed() {
    for (final editor in _editors.values) {
      editor.dispose();
    }
    _editors.clear();
    _access.clear();
    _forgetBaseModels();
  }

  // -- Loading -----------------------------------------------------------------

  Future<void> _load(WorkspaceModelEditor editor) async {
    final l10n = _l10n;
    final id = workspaceIdOfKey(editor.key);
    if (l10n == null || id == null) return;
    editor
      ..loading = true
      ..loadFailed = false;
    WorkspaceModelSummary? summary;
    try {
      final provider = workspaceModelDetailProvider(id);
      final listening = _ref.listen(provider, (_, _) {});
      try {
        summary = await _ref.read(provider.future);
      } finally {
        listening.close();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-model-load-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return;
    editor.loading = false;
    if (summary == null) {
      editor.loadFailed = true;
    } else {
      editor.adopt(_stateFor(summary), from: summary);
    }
    await _applyEditor(l10n, editor);
  }

  WorkspaceModelEditorState _stateFor(WorkspaceModelSummary summary) =>
      WorkspaceModelEditorState(
        mode: summary.writeAccess
            ? WorkspaceRouteMode.edit
            : WorkspaceRouteMode.detail,
        initialDraft: WorkspaceModelDraft.fromSummary(summary),
        writeAccess: summary.writeAccess,
        summary: summary,
      );

  Future<void> _loadBaseModels() async {
    // The list is the account's it was read for: another one reads its own.
    final session = _session();
    if (_baseModelsSession != null &&
        !(_baseModelsSession?.isCurrent(_ref) ?? false)) {
      _baseModels = null;
      _baseModelsSession = null;
    }
    if (_baseModels != null || _baseModelsLoading) return;
    _baseModelsLoading = true;
    _baseModelsFailed = false;
    var stale = false;
    try {
      final listening = _ref.listen(workspaceBaseModelsProvider, (_, _) {});
      try {
        final models = await _ref.read(workspaceBaseModelsProvider.future);
        // Read for an account since gone: not this one's list.
        if (session == null || !session.isCurrent(_ref)) {
          stale = true;
        } else {
          _baseModels = models;
          _baseModelsSession = session;
        }
      } finally {
        listening.close();
      }
    } catch (error, stackTrace) {
      _baseModelsFailed = true;
      DebugLogger.error(
        'workspace-base-models-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _baseModelsLoading = false;
    }
    if (stale) {
      // An editor the account signed in since opened waited on this read:
      // it reads its own list now.
      if (_session() != null && _editors.isNotEmpty) {
        unawaited(_loadBaseModels());
      }
      return;
    }
    final l10n = _l10n;
    if (l10n == null) return;
    for (final editor in _editors.values.toList()) {
      if (_current(editor)) await _applyEditor(l10n, editor, withPages: false);
    }
  }

  Future<void> _loadOptions(
    WorkspaceModelEditor editor,
    WorkspaceModelRelationshipKind kind,
  ) async {
    final l10n = _l10n;
    if (l10n == null || editor.optionsLoading.contains(kind)) return;
    editor.optionsLoading.add(kind);
    editor.optionsFailed.remove(kind);
    try {
      final options = await _readOptions(kind);
      if (!_current(editor)) return;
      editor.options[kind] = options;
    } catch (error, stackTrace) {
      DebugLogger.error(
        '${kind.name}-relationship-load-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_current(editor)) return;
      editor.optionsFailed.add(kind);
    } finally {
      editor.optionsLoading.remove(kind);
    }
    await _applyRelationship(l10n, editor, kind);
  }

  /// Every item of a paged list, a page at a time until the server's total
  /// is reached or a page brings nothing new.
  static Future<List<T>> _readAllPages<T>(
    Future<WorkspacePagedResponse<T>> Function(int page) read,
  ) async {
    final items = <T>[];
    for (var page = 1; ; page++) {
      final response = await read(page);
      items.addAll(response.items);
      if (response.items.isEmpty || items.length >= response.total) {
        return items;
      }
    }
  }

  Future<List<WorkspaceRelationshipOption>> _readOptions(
    WorkspaceModelRelationshipKind kind,
  ) async {
    switch (kind) {
      case WorkspaceModelRelationshipKind.knowledge:
        // Every page, read without the filters the Workspace list is
        // browsing with: any base may be chosen.
        final api = WorkspaceSessionIdentity.read(_ref).api;
        final items = await _readAllPages(
          (page) => api.getWorkspaceKnowledge(page: page),
        );
        return [
          for (final item in items)
            WorkspaceRelationshipOption(
              id: item.id,
              label: item.name,
              subtitle: item.description,
            ),
        ];
      case WorkspaceModelRelationshipKind.tools:
        // Read without the search the Workspace Tools list may be filtered
        // by: any tool may be chosen.
        final tools = await WorkspaceSessionIdentity.read(_ref).api
            .getWorkspaceTools();
        return [
          for (final tool in tools)
            WorkspaceRelationshipOption(id: tool.id, label: tool.name),
        ];
      case WorkspaceModelRelationshipKind.skills:
        // Every page, read without the filters the Workspace list is
        // browsing with: any skill may be chosen.
        final api = WorkspaceSessionIdentity.read(_ref).api;
        final skills = await _readAllPages(
          (page) => api.getWorkspaceSkills(page: page),
        );
        return [
          for (final skill in skills)
            WorkspaceRelationshipOption(
              id: skill.id,
              label: skill.name,
              subtitle: skill.description,
            ),
        ];
      case WorkspaceModelRelationshipKind.filters ||
          WorkspaceModelRelationshipKind.defaultFilters ||
          WorkspaceModelRelationshipKind.actions:
        final listening = _ref.listen(workspaceFunctionsProvider, (_, _) {});
        final functions = await _ref
            .read(workspaceFunctionsProvider.future)
            .whenComplete(listening.close);
        final filters = kind != WorkspaceModelRelationshipKind.actions;
        return [
          for (final item in functions)
            if (filters ? item.isFilter : item.isAction)
              WorkspaceRelationshipOption(
                id: item.id,
                label: item.name,
                subtitle: item.type,
              ),
        ];
    }
  }

  // -- Drawing ------------------------------------------------------------------

  Future<void> _applyEditor(
    AppLocalizations l10n,
    WorkspaceModelEditor editor, {
    bool withPages = true,
  }) {
    final key = editor.key;
    editor.shownEdited = editor.edited;
    final known = _ref.read(settingsPagesProvider);
    return _surface.applyDetail(
      buildWorkspaceModelPage(
        l10n,
        editor: editor,
        capabilities: _capabilities,
        baseModels: _baseModels,
        baseModelRequired: _baseModelRequired(editor),
        baseModelsFailed: _baseModelsFailed,
      ),
      detailSheets: [
        if (withPages && editor.state != null) ...[
          buildWorkspaceModelAdvancedPage(l10n, editor: editor),
          // Stand-ins only for pages not drawn yet: an open one keeps its
          // rows.
          for (final kind in WorkspaceModelRelationshipKind.values)
            if (!known.contains(workspaceModelRelationshipPageId(kind, key)))
              buildNativeLoadingDetail(
                l10n: l10n,
                id: workspaceModelRelationshipPageId(kind, key),
                title: _relationshipTitle(l10n, kind),
              ),
          if (!known.contains(
            workspaceAccessPageId(WorkspaceSection.models, key),
          ))
            buildNativeLoadingDetail(
              l10n: l10n,
              id: workspaceAccessPageId(WorkspaceSection.models, key),
              title: l10n.workspaceModelManageAccess,
            ),
        ],
      ],
    );
  }

  /// A change made on one of the editor's own pages is the editor's: its
  /// page, under them, is drawn again once it turns edited (or back), so
  /// leaving it -- or swiping Settings away -- asks first.
  Future<void> _showEdited(AppLocalizations l10n, WorkspaceModelEditor editor) {
    if (editor.edited == editor.shownEdited) return Future.value();
    return _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _applyAdvanced(
    AppLocalizations l10n,
    WorkspaceModelEditor editor,
  ) => _surface.applyDetail(
    buildWorkspaceModelAdvancedPage(l10n, editor: editor),
  );

  Future<void> _applyRelationship(
    AppLocalizations l10n,
    WorkspaceModelEditor editor,
    WorkspaceModelRelationshipKind kind,
  ) => _surface.applyDetail(
    buildWorkspaceModelRelationshipPage(l10n, editor: editor, kind: kind),
  );

  // -- Changes ------------------------------------------------------------------

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    _l10n = l10n;
    if (await _access.handleChange(id, value, l10n)) return true;
    final row = parseWorkspaceRowId(id);
    if (row == null || !row.field.startsWith('model-')) return false;
    final editor = _editors[row.key];
    if (editor == null) return true;
    if (row.field == 'model-retry') {
      await _load(editor);
      return true;
    }
    final state = editor.state;
    if (state == null || editor.busy) return true;
    final field = row.field.substring('model-'.length);
    switch (field) {
      case 'name' ||
              'id' ||
              'description' ||
              'system' ||
              'stop' ||
              'terminal' ||
              'tts' ||
              'features' ||
              'params' ||
              'builtin'
          when value is String && !editor.readOnly:
        final before = editor.edited;
        editor.text = _withText(editor.text, field, value);
        state.markDirty();
        // Typed on the Advanced page, the editor under it learns of it.
        if (const {
          'stop',
          'terminal',
          'tts',
          'features',
          'params',
          'builtin',
        }.contains(field)) {
          if (before != editor.edited) await _showEdited(l10n, editor);
        } else if (field == 'name' && !before) {
          await _applyEditor(l10n, editor, withPages: false);
        }
      case 'base' when value is String && !editor.readOnly:
        state.setBaseModel(value.isEmpty ? null : value);
        await _applyEditor(l10n, editor, withPages: false);
      case 'tag-add' when value is String && !editor.readOnly:
        final tag = value.trim();
        if (tag.isNotEmpty && !state.draft.tags.contains(tag)) {
          state.addTag(tag);
        }
        await _applyEditor(l10n, editor, withPages: false);
      case 'tag-remove' when row.extra != null && !editor.readOnly:
        state.removeTag(row.extra!);
        await _applyEditor(l10n, editor, withPages: false);
      case 'suggestion-add' when value is String && !editor.readOnly:
        final prompt = value.trim();
        if (prompt.isNotEmpty) state.addSuggestion(prompt);
        await _applyEditor(l10n, editor, withPages: false);
      case 'suggestion-remove' when row.extra != null && !editor.readOnly:
        final index = int.tryParse(row.extra!);
        if (index != null &&
            index >= 0 &&
            index < state.draft.suggestionPrompts.length) {
          state.removeSuggestion(index);
        }
        await _applyEditor(l10n, editor, withPages: false);
      case 'capability' when row.extra != null && value is bool:
        if (editor.readOnly) return true;
        final before = editor.edited;
        state.setCapability(row.extra!, value);
        await _applyAdvanced(l10n, editor);
        if (before != editor.edited) await _showEdited(l10n, editor);
      case 'relationship' when row.extra != null && !editor.readOnly:
        await _toggleRelationship(l10n, editor, row.extra!);
      case 'relationship-retry' when row.extra != null:
        final kind = WorkspaceModelRelationshipKind.values
            .where((value) => value.name == row.extra)
            .firstOrNull;
        if (kind != null) await _loadOptions(editor, kind);
      case 'base-retry':
        // Read afresh: a failed read is not kept as the answer.
        _ref.invalidate(workspaceBaseModelsProvider);
        await _loadBaseModels();
      case 'image-pick' when !editor.readOnly:
        await _pickImage(l10n, editor);
      case 'image-remove' when !editor.readOnly:
        state.removeAvatar();
        await _applyEditor(l10n, editor, withPages: false);
      case 'save':
        await _save(l10n, editor);
      case 'clone':
        await _clone(l10n, editor);
      case 'active':
        await _toggleActive(l10n, editor);
      case 'hidden':
        await _toggleHidden(l10n, editor);
      case 'export':
        await _exportOne(l10n, editor);
      case 'delete':
        await _delete(l10n, editor);
    }
    return true;
  }

  Future<void> _toggleRelationship(
    AppLocalizations l10n,
    WorkspaceModelEditor editor,
    String extra,
  ) async {
    final state = editor.state!;
    final bar = extra.indexOf('|');
    if (bar < 0) return;
    final kind = WorkspaceModelRelationshipKind.values
        .where((value) => value.name == extra.substring(0, bar))
        .firstOrNull;
    if (kind == null) return;
    final id = extra.substring(bar + 1);
    final selected = [...state.selectedRelationshipIds(kind)];
    if (!selected.remove(id)) selected.add(id);
    state.applyRelationshipSelection(
      kind,
      selected,
      editor.options[kind] ?? const [],
    );
    await _applyRelationship(l10n, editor, kind);
    // The count on the editor's row changes even when it stays edited.
    await _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _pickImage(
    AppLocalizations l10n,
    WorkspaceModelEditor editor,
  ) async {
    try {
      // Over the Settings sheet, as a picker opened from one of its rows.
      final file = await FilePicker.pickFile(type: FileType.image);
      if (file == null || !_current(editor)) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || !_current(editor)) return;
      final avatar = await WorkspaceModelAvatarCodec.prepare(
        bytes,
        extension: file.extension,
      );
      if (!_current(editor)) return;
      editor.state?.setAvatar(avatar.toDataUrl());
      editor.notice = null;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-model-image-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_current(editor)) return;
      editor
        ..notice = l10n.workspaceModelImageFailed
        ..noticeIsError = true;
    }
    await _applyEditor(l10n, editor, withPages: false);
  }

  void _say(WorkspaceModelEditor editor, String message, {bool error = true}) {
    editor
      ..notice = message
      ..noticeIsError = error;
  }

  /// Copies the typed text into the model. False, with the reason on the
  /// page, when a JSON field holds no object.
  bool _sync(AppLocalizations l10n, WorkspaceModelEditor editor) {
    final state = editor.state!;
    if (state.syncFieldText(editor.text)) return true;
    _say(editor, l10n.workspaceModelInvalidJson);
    return false;
  }

  Future<void> _save(AppLocalizations l10n, WorkspaceModelEditor editor) async {
    final state = editor.state!;
    if (editor.readOnly || editor.busy) return;
    if (!_sync(l10n, editor)) {
      await _applyEditor(l10n, editor, withPages: false);
      await _applyAdvanced(l10n, editor);
      return;
    }
    final draft = state.draft;
    if (!draft.isValid) {
      _say(
        editor,
        draft.id.trim().isEmpty
            ? l10n.workspaceModelIdRequired
            : l10n.workspaceModelNameRequired,
      );
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    if (_baseModelRequired(editor) &&
        (draft.baseModelId?.trim().isEmpty ?? true)) {
      _say(editor, l10n.workspaceModelBaseModelRequired);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    editor
      ..busy = true
      ..notice = null;
    await _applyEditor(l10n, editor, withPages: false);
    // Another account signed in while the editor was drawn busy: nothing is
    // sent, with no await between this and the write.
    if (!_current(editor)) return;
    final form = draft.toForm();
    String? problem;
    try {
      if (editor.isCreate) {
        await _notifier.create(form);
      } else {
        await _notifier.updateItem(form);
      }
    } on WorkspaceModelBaseRequiredException {
      problem = l10n.workspaceModelBaseModelRequired;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-model-save-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      problem = l10n.workspaceModelSaveFailed;
    }
    // Left, or another account signed in, while it saved: nothing to say.
    if (!_current(editor)) return;
    editor.busy = false;
    if (problem != null) {
      _say(editor, problem);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    state.session.markClean();
    final id = workspaceIdOfKey(editor.key);
    if (id != null) _ref.invalidate(workspaceModelDetailProvider(id));
    // Saved, the editor goes back to the list, which shows the model.
    _editors.remove(editor.key)?.dispose();
    _access.forget(editor.key);
    await _surface.closeDetail('$workspaceModelPagePrefix${editor.key}');
  }

  /// Runs [operation] on a saved model, the editor staying open; [done]
  /// follows a success.
  Future<void> _operate(
    AppLocalizations l10n,
    WorkspaceModelEditor editor,
    Future<void> Function() operation, {
    required String failure,
    Future<void> Function()? done,
  }) async {
    if (editor.busy) return;
    editor
      ..busy = true
      ..notice = null;
    await _applyEditor(l10n, editor, withPages: false);
    if (!_current(editor)) return;
    Object? failed;
    try {
      await operation();
    } catch (error, stackTrace) {
      failed = error;
      DebugLogger.error(
        'workspace-model-operation-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return;
    editor.busy = false;
    if (failed != null) {
      _say(editor, failure);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    await done?.call();
  }

  Future<void> _reload(
    AppLocalizations l10n,
    WorkspaceModelEditor editor,
  ) async {
    final id = workspaceIdOfKey(editor.key);
    if (id == null) return;
    _ref.invalidate(workspaceModelDetailProvider(id));
    final notice = editor.notice;
    final noticeIsError = editor.noticeIsError;
    await _load(editor);
    if (!_current(editor)) return;
    editor
      ..notice = notice
      ..noticeIsError = noticeIsError;
    await _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _clone(
    AppLocalizations l10n,
    WorkspaceModelEditor editor,
  ) async {
    final state = editor.state!;
    if (!state.writeAccess || !_sync(l10n, editor)) {
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    if (!_isAdmin && (state.draft.baseModelId?.trim().isEmpty ?? true)) {
      _say(editor, l10n.workspaceModelBaseModelRequired);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    final clone = state.buildClone(l10n.workspaceModelCloneSuffix);
    await _operate(
      l10n,
      editor,
      () => _notifier.create(clone.toForm()),
      failure: l10n.workspaceModelSaveFailed,
      done: () async {
        // The copy is in the list now; this model's page stays as it was.
        _say(editor, l10n.workspaceModelSaved, error: false);
        await _applyEditor(l10n, editor, withPages: false);
      },
    );
  }

  Future<void> _toggleActive(
    AppLocalizations l10n,
    WorkspaceModelEditor editor,
  ) async {
    final state = editor.state!;
    final id = state.draft.id;
    if (!state.writeAccess || id.isEmpty) return;
    // Switching on or off reads the model again, so what is typed would go.
    if (editor.edited) {
      final answer = await _surface.ask(
        title: l10n.workspaceEditorDiscardTitle,
        message: l10n.workspaceEditorDiscardMessage,
        actions: [
          NativeSheetAlertAction(
            'keep',
            l10n.workspaceEditorKeepEditing,
            style: NativeSheetAlertStyle.cancel,
          ),
          NativeSheetAlertAction(
            'discard',
            l10n.workspaceEditorDiscardConfirm,
            style: NativeSheetAlertStyle.destructive,
          ),
        ],
      );
      if (answer != 'discard' || !_current(editor)) return;
    }
    await _operate(
      l10n,
      editor,
      () => _notifier.toggle(id),
      failure: l10n.workspaceModelSaveFailed,
      done: () async {
        _say(editor, l10n.workspaceModelSaved, error: false);
        await _reload(l10n, editor);
      },
    );
  }

  Future<void> _toggleHidden(
    AppLocalizations l10n,
    WorkspaceModelEditor editor,
  ) async {
    final state = editor.state!;
    if (!state.writeAccess || state.draft.id.isEmpty) return;
    // There is no endpoint for hiding alone: the whole model is saved.
    if (!_sync(l10n, editor)) {
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    state.toggleHidden();
    await _operate(
      l10n,
      editor,
      () => _notifier.updateItem(state.draft.toForm()),
      failure: l10n.workspaceModelSaveFailed,
      done: () async {
        state.session.markClean();
        _say(editor, l10n.workspaceModelSaved, error: false);
        await _reload(l10n, editor);
      },
    );
    if (_current(editor) && editor.noticeIsError && editor.notice != null) {
      // Not saved: the switch goes back.
      state.toggleHidden();
      await _applyEditor(l10n, editor, withPages: false);
    }
  }

  Rect? _shareOrigin() {
    final view = PlatformDispatcher.instance.views.firstOrNull;
    if (view == null) return null;
    final size = view.physicalSize / view.devicePixelRatio;
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 1,
      height: 1,
    );
  }

  Future<void> _exportOne(
    AppLocalizations l10n,
    WorkspaceModelEditor editor,
  ) async {
    final state = editor.state!;
    if (!_sync(l10n, editor)) {
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    try {
      await _ref
          .read(workspaceExportControllerProvider)
          .shareJson(
            filename: state.draft.id.isEmpty ? 'model' : state.draft.id,
            data: [state.draft.toForm().toJson()],
            sharePositionOrigin: _shareOrigin(),
          );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-model-export-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_current(editor)) return;
      _say(editor, l10n.workspaceModelExportFailed);
      await _applyEditor(l10n, editor, withPages: false);
    }
  }

  Future<void> _delete(
    AppLocalizations l10n,
    WorkspaceModelEditor editor,
  ) async {
    final state = editor.state!;
    final id = state.draft.id;
    if (!state.writeAccess || id.isEmpty) return;
    await _operate(
      l10n,
      editor,
      () => _notifier.delete(id),
      failure: l10n.workspaceModelSaveFailed,
      done: () async {
        _editors.remove(editor.key)?.dispose();
        _access.forget(editor.key);
        await _surface.closeDetail('$workspaceModelPagePrefix${editor.key}');
      },
    );
  }

  // -- Access ----------------------------------------------------------------------

  Future<String?> _saveAccess(
    WorkspaceAccessDraft draft,
    List<WorkspaceAccessGrantInput> grants,
  ) async {
    final l10n = _l10n;
    final editor = _editors[draft.editorKey];
    final state = editor?.state;
    if (l10n == null || editor == null || state == null) return null;
    // Another account signed in while the page was drawn: nothing is sent,
    // and the page says it was not saved.
    if (!_current(editor)) return l10n.workspaceModelSaveFailed;
    try {
      final saved = await _notifier.updateAccess(
        state.draft.id,
        state.draft.name,
        grants,
      );
      draft.kept = [
        for (final grant in saved.accessGrants)
          WorkspaceAccessGrantInput.fromGrant(grant),
      ];
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-model-access-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      return l10n.workspaceModelSaveFailed;
    }
    if (!_current(editor)) return null;
    return null;
  }

  Future<void> _accessDone(
    WorkspaceAccessDraft draft,
    List<WorkspaceAccessGrantInput> grants, {
    required bool saved,
  }) async {
    final l10n = _l10n;
    final editor = _editors[draft.editorKey];
    final state = editor?.state;
    if (l10n == null || editor == null || state == null || !_current(editor)) {
      return;
    }
    // Saved already, the list is no change left to save; a new model keeps
    // it for its first save.
    state.replaceAccessGrants(grants, markDirty: !saved);
    if (saved) {
      final id = workspaceIdOfKey(editor.key);
      if (id != null) _ref.invalidate(workspaceModelDetailProvider(id));
      _say(editor, l10n.workspaceModelSaved, error: false);
    }
    await _applyEditor(l10n, editor, withPages: false);
  }
}
