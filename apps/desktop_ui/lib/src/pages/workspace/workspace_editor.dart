import 'dart:async';
import 'dart:convert';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart' show Link;

import '../../l10n/strings.g.dart';
import '../../file_picker.dart';
import '../../rpc/rpc_providers.dart'
    show filePickerProvider, fileSaverProvider;
import '../../rpc/terminal_providers.dart';
import '../../rpc/workspace_providers.dart';
import '../../widgets/form_field.dart';
import 'workspace_access.dart';
import 'workspace_common.dart';
import 'workspace_files.dart';
import 'workspace_prompt_history.dart';
import 'workspace_valves.dart';

/// The capability switches Open WebUI offers on a model, in its order.
const List<String> modelCapabilityKeys = <String>[
  'vision',
  'file_upload',
  'web_search',
  'image_generation',
  'code_interpreter',
  'citations',
  'usage',
];

/// What a new item starts as. A new model has the capabilities Open
/// WebUI's own editor switches on for one.
WorkspaceDetail blankDetail(WorkspaceKind kind) => switch (kind) {
  WorkspaceKind.models => WorkspaceDetail(
    kind: kind,
    model: WorkspaceModelDto(
      capabilities: <String, bool>{
        for (final key in modelCapabilityKeys) key: key != 'usage',
      },
    ),
  ),
  WorkspaceKind.knowledge => WorkspaceDetail(
    kind: kind,
    knowledge: const WorkspaceKnowledgeDto(),
  ),
  WorkspaceKind.prompts => WorkspaceDetail(
    kind: kind,
    prompt: const WorkspacePromptDto(),
  ),
  WorkspaceKind.tools => WorkspaceDetail(
    kind: kind,
    tool: const WorkspaceToolDto(content: _toolTemplate),
  ),
  WorkspaceKind.skills => WorkspaceDetail(
    kind: kind,
    skill: const WorkspaceSkillDto(),
  ),
};

const String _toolTemplate = '''"""
title: My Tool
description: What this tool does
"""


class Tools:
    def __init__(self):
        pass

    def hello(self, name: str) -> str:
        """Greet someone by name."""
        return f"Hello, {name}!"
''';

String idOf(WorkspaceDetail detail) => switch (detail.kind) {
  WorkspaceKind.models => detail.model?.id ?? '',
  WorkspaceKind.knowledge => detail.knowledge?.id ?? '',
  WorkspaceKind.prompts => detail.prompt?.id ?? '',
  WorkspaceKind.tools => detail.tool?.id ?? '',
  WorkspaceKind.skills => detail.skill?.id ?? '',
};

String nameOf(WorkspaceDetail detail) => switch (detail.kind) {
  WorkspaceKind.models => detail.model?.name ?? '',
  WorkspaceKind.knowledge => detail.knowledge?.name ?? '',
  WorkspaceKind.prompts => detail.prompt?.name ?? '',
  WorkspaceKind.tools => detail.tool?.name ?? '',
  WorkspaceKind.skills => detail.skill?.name ?? '',
};

/// A copy of an item to start a new one from, taken by the next "new"
/// editor of its kind. Duplicate puts it here.
final workspaceTemplateProvider =
    NotifierProvider<WorkspaceTemplate, WorkspaceDetail?>(
      WorkspaceTemplate.new,
    );

class WorkspaceTemplate extends Notifier<WorkspaceDetail?> {
  @override
  WorkspaceDetail? build() => null;

  // ignore: use_setters_to_change_properties
  void set(WorkspaceDetail? detail) => state = detail;
}

/// Opens [id] of [kind] for editing, or a new one when [id] is null.
class WorkspaceEditor extends StatelessComponent {
  const WorkspaceEditor({
    required this.kind,
    required this.id,
    required this.access,
    super.key,
  });

  final WorkspaceKind kind;
  final String? id;
  final WorkspaceAccess access;

  @override
  Component build(BuildContext context) {
    final id = this.id;
    if (id == null) {
      final template = context.read(workspaceTemplateProvider);
      return WorkspaceEditorForm(
        initial: template != null && template.kind == kind
            ? template
            : blankDetail(kind),
        create: true,
        access: access,
      );
    }
    final detail = context.watch(workspaceDetailProvider((kind: kind, id: id)));
    if (detail.value case final value?) {
      return WorkspaceEditorForm(
        key: ValueKey('form-${kind.name}-$id'),
        initial: value,
        create: false,
        access: access,
      );
    }
    return div(classes: 'mx-auto w-full max-w-3xl space-y-3 p-6', [
      _backLink(kind),
      if (detail.hasError)
        isNotFound(detail.error)
            ? statusLine(t.desktop.desktopWorkspaceNotFound)
            : div(classes: 'space-y-2', [
                formError(t.app.workspaceLoadFailed),
                actionButton(
                  t.app.workspaceRetry,
                  onClick: () => context.invalidate(
                    workspaceDetailProvider((kind: kind, id: id)),
                  ),
                ),
              ])
      else
        statusLine(t.app.loadingShort),
    ]);
  }

  static Component _backLink(WorkspaceKind kind) => Link(
    to: sectionPath(kind),
    classes: 'text-xs text-muted-foreground hover:underline',
    child: Component.text('← ${sectionLabel(kind)}'),
  );
}

/// The editor for one item of any kind: the fields its kind has, and the
/// actions every kind shares -- save, access, export, duplicate, delete.
class WorkspaceEditorForm extends StatefulComponent {
  const WorkspaceEditorForm({
    required this.initial,
    required this.create,
    required this.access,
    super.key,
  });

  final WorkspaceDetail initial;
  final bool create;
  final WorkspaceAccess access;

  @override
  State<WorkspaceEditorForm> createState() => _WorkspaceEditorFormState();
}

class _WorkspaceEditorFormState extends State<WorkspaceEditorForm> {
  late WorkspaceDetail _original;
  late WorkspaceDetail _draft;

  /// Fields typed as text and read as something else -- a list, a JSON
  /// object -- kept as typed, so a comma is not eaten mid-word.
  final Map<String, String> _text = <String, String>{};
  String? _paramsError;

  /// Whether the user typed the id themselves; until then it follows the
  /// name, as Open WebUI's editor does.
  bool _idEdited = false;

  bool _busy = false;
  String? _status;
  bool _statusIsError = false;
  bool _confirmingDelete = false;
  bool _confirmingLeave = false;
  bool _confirmingReset = false;
  bool _accessOpen = false;
  bool _historyOpen = false;
  bool? _valvesUser;
  bool _urlOpen = false;
  String _url = '';

  late WorkspaceEditorDirty _dirty;

  WorkspaceKind get kind => _draft.kind;
  WorkspaceSectionAccess get _section => sectionAccess(component.access, kind);
  bool get _canWrite => component.create || _original.writeAccess;
  bool get _isDirty => _draft != _original || _paramsError != null;

  @override
  void initState() {
    super.initState();
    _original = component.create
        ? blankDetail(component.initial.kind)
        : component.initial;
    _draft = component.initial;
    _idEdited = !component.create || idOf(component.initial).isNotEmpty;
  }

  @override
  void dispose() {
    // Leaving the editor leaves nothing to guard.
    _dirty.set(false);
    super.dispose();
  }

  void _update(WorkspaceDetail next) {
    setState(() => _draft = next);
    _dirty.set(_isDirty);
  }

  void _say(String text, {bool error = false}) => setState(() {
    _status = text;
    _statusIsError = error;
  });

  // -------------------------------------------------------------------------
  // Saving
  // -------------------------------------------------------------------------

  String? _validate() {
    if (_paramsError != null) return t.app.workspaceModelInvalidJson;
    final token = RegExp(r'^[a-zA-Z0-9_-]+$');
    switch (kind) {
      case WorkspaceKind.models:
        final m = _draft.model!;
        if (m.id.trim().isEmpty) return t.app.workspaceModelIdRequired;
        if (m.name.trim().isEmpty) return t.app.workspaceModelNameRequired;
        if (!component.access.admin && (m.baseModelId ?? '').isEmpty) {
          return t.app.workspaceModelBaseModelRequired;
        }
      case WorkspaceKind.knowledge:
        if (_draft.knowledge!.name.trim().isEmpty) {
          return t.app.workspaceKnowledgeNameRequired;
        }
      case WorkspaceKind.prompts:
        final p = _draft.prompt!;
        final command = p.command.trim().replaceFirst(RegExp(r'^/+'), '');
        if (command.isEmpty) return t.app.workspacePromptCommandRequired;
        if (!token.hasMatch(command)) {
          return t.app.workspacePromptCommandInvalid;
        }
        if (p.name.trim().isEmpty) return t.app.workspacePromptNameRequired;
        if (p.content.trim().isEmpty) {
          return t.app.workspacePromptContentRequired;
        }
      case WorkspaceKind.tools:
        final tool = _draft.tool!;
        if (tool.id.trim().isEmpty) return t.app.workspaceToolIdRequired;
        if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(tool.id.trim())) {
          return t.app.workspaceToolIdInvalid;
        }
        if (tool.name.trim().isEmpty) return t.app.workspaceToolNameRequired;
        if (tool.content.trim().isEmpty) {
          return t.app.workspaceToolContentRequired;
        }
      case WorkspaceKind.skills:
        final s = _draft.skill!;
        if (s.id.trim().isEmpty) return t.app.workspaceSkillIdRequired;
        if (!token.hasMatch(s.id.trim())) return t.app.workspaceSkillIdInvalid;
        if (s.name.trim().isEmpty) return t.app.workspaceSkillNameRequired;
        if (s.content.trim().isEmpty) {
          return t.app.workspaceSkillContentRequired;
        }
    }
    return null;
  }

  String get _savedText => switch (kind) {
    WorkspaceKind.models => t.app.workspaceModelSaved,
    WorkspaceKind.knowledge => t.app.workspaceKnowledgeSaved,
    WorkspaceKind.prompts => t.app.workspacePromptSaved,
    WorkspaceKind.tools => t.app.workspaceToolSaved,
    WorkspaceKind.skills => t.app.workspaceSkillSaved,
  };

  String get _saveFailedText => switch (kind) {
    WorkspaceKind.models => t.app.workspaceModelSaveFailed,
    WorkspaceKind.knowledge => t.app.workspaceKnowledgeSaveFailed,
    WorkspaceKind.prompts => t.app.workspacePromptSaveFailed,
    WorkspaceKind.tools => t.app.workspaceToolSaveFailed,
    WorkspaceKind.skills => t.app.workspaceSkillSaveFailed,
  };

  String get _takenText => switch (kind) {
    WorkspaceKind.prompts => t.app.workspacePromptCommandTaken,
    WorkspaceKind.tools => t.app.workspaceToolIdTaken,
    WorkspaceKind.skills => t.app.workspaceSkillIdTaken,
    _ => _saveFailedText,
  };

  Future<void> _save(BuildContext context, {bool metadataOnly = false}) async {
    final invalid = _validate();
    if (invalid != null) {
      _say(invalid, error: true);
      return;
    }
    final go = context.read(workspaceNavigateProvider);
    final actions = context.read(workspaceActionsProvider);
    setState(() => _busy = true);
    try {
      final saved = await actions.save(
        _draft,
        create: component.create,
        metadataOnly: metadataOnly,
      );
      if (!mounted) return;
      _dirty.set(false);
      context.read(workspaceTemplateProvider.notifier).set(null);
      if (component.create) {
        go(context, sectionPath(kind, idOf(saved)), replace: true);
        return;
      }
      context.invalidate(
        workspaceDetailProvider((kind: kind, id: idOf(saved))),
      );
      setState(() {
        _original = saved;
        _draft = saved;
        _text.clear();
      });
      _say(metadataOnly ? t.app.workspacePromptDetailsSaved : _savedText);
    } on RpcError catch (error) {
      final detail = serverDetail(error);
      _say(
        error.code == ConduitErrorCodes.conflict && detail == null
            ? _takenText
            : detail == null
            ? _saveFailedText
            : '$_saveFailedText ($detail)',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final go = context.read(workspaceNavigateProvider);
    try {
      await context
          .read(workspaceActionsProvider)
          .delete(kind, idOf(_original));
      _dirty.set(false);
      go(context, sectionPath(kind), replace: true);
    } on Object {
      _say(_saveFailedText, error: true);
    }
  }

  Future<void> _export(BuildContext context) async {
    final saver = context.read(fileSaverProvider);
    try {
      final file = await context
          .read(workspaceActionsProvider)
          .export(kind, id: idOf(_original));
      saver.save(
        filename: file.filename,
        mimeType: file.mimeType,
        text: file.text,
        base64: file.base64,
      );
    } on Object {
      _say(t.app.workspaceModelExportFailed, error: true);
    }
  }

  void _duplicate(BuildContext context) {
    final copyName = '${nameOf(_draft)} ${t.app.workspaceModelCloneSuffix}';
    final copy = switch (kind) {
      WorkspaceKind.models => _draft.copyWith(
        model: _draft.model!.copyWith(
          id: '${_draft.model!.id}-copy',
          name: copyName,
        ),
      ),
      WorkspaceKind.knowledge => _draft.copyWith(
        knowledge: _draft.knowledge!.copyWith(id: '', name: copyName),
      ),
      WorkspaceKind.prompts => _draft.copyWith(
        prompt: _draft.prompt!.copyWith(
          id: '',
          command: '${_draft.prompt!.command}-copy',
          name: copyName,
          versionId: null,
        ),
      ),
      WorkspaceKind.tools => _draft.copyWith(
        tool: _draft.tool!.copyWith(
          id: '${_draft.tool!.id}_copy',
          name: copyName,
        ),
      ),
      WorkspaceKind.skills => _draft.copyWith(
        skill: _draft.skill!.copyWith(
          id: '${_draft.skill!.id}-copy',
          name: copyName,
        ),
      ),
    };
    context
        .read(workspaceTemplateProvider.notifier)
        .set(
          copy.copyWith(grants: const <WorkspaceGrant>[], writeAccess: true),
        );
    workspaceGo(context, '${sectionPath(kind)}/new');
  }

  Future<void> _reset(BuildContext context) async {
    try {
      final reset = await context
          .read(workspaceActionsProvider)
          .knowledgeReset(idOf(_original));
      context.invalidate(workspaceFilesProvider(idOf(_original)));
      setState(() {
        _original = reset;
        _draft = reset;
        _confirmingReset = false;
      });
      _say(t.app.workspaceKnowledgeResetDone);
    } on Object {
      _say(t.app.workspaceKnowledgeSaveFailed, error: true);
    }
  }

  Future<void> _loadUrl(BuildContext context) async {
    try {
      final tool = await context
          .read(workspaceActionsProvider)
          .toolFromUrl(_url);
      _update(
        _draft.copyWith(
          tool: _draft.tool!.copyWith(
            id: component.create ? tool.id : _draft.tool!.id,
            name: tool.name,
            description: tool.description,
            content: tool.content,
          ),
        ),
      );
      setState(() => _urlOpen = false);
      _say(t.app.workspaceToolImportUrlLoaded);
    } on RpcError catch (error) {
      _say(
        error.code == ConduitErrorCodes.invalidParams
            ? t.app.workspaceToolImportUrlHost
            : t.app.workspaceToolImportUrlFailed,
        error: true,
      );
    }
  }

  /// Fills a new skill from a Markdown file: its front matter's name, id
  /// and description, and the whole file as the instructions -- as Open
  /// WebUI's editor and mobile's do.
  Future<void> _importMarkdown(BuildContext context) async {
    final PickedTextFile? file;
    try {
      file = await context
          .read(filePickerProvider)
          .pickText(accept: '.md,.markdown,text/markdown');
    } on Object {
      _say(t.app.workspaceSkillImportMarkdownFailed, error: true);
      return;
    }
    if (file == null || !mounted) return;
    final front = skillFrontMatter(file.content);
    final name = front['name'] ?? '';
    final idSource = (front['id'] ?? '').isNotEmpty ? front['id']! : name;
    final skill = _draft.skill!;
    _idEdited = false;
    _update(
      _draft.copyWith(
        skill: skill.copyWith(
          content: file.content,
          name: name.isEmpty ? skill.name : _titleCase(name),
          id: idSource.isEmpty ? skill.id : _slug(idSource),
          description: front['description'] ?? skill.description,
        ),
      ),
    );
    _say(t.app.workspaceSkillImportMarkdownLoaded);
  }

  Future<void> _pickImage(BuildContext context) async {
    final String? dataUrl;
    try {
      dataUrl = await context.read(filePickerProvider).pickImageDataUrl();
    } on Object {
      _say(t.app.workspaceModelImageFailed, error: true);
      return;
    }
    if (dataUrl == null || !mounted) return;
    _update(_draft.copyWith(model: _draft.model!.copyWith(imageUrl: dataUrl)));
  }

  /// `code-review_guidelines` as `Code Review Guidelines`.
  static String _titleCase(String name) => name
      .replaceAll(RegExp('[-_]'), ' ')
      .replaceAllMapped(RegExp(r'\b\w'), (m) => m[0]!.toUpperCase());

  // -------------------------------------------------------------------------
  // Layout
  // -------------------------------------------------------------------------

  @override
  Component build(BuildContext context) {
    _dirty = context.read(workspaceEditorDirtyProvider.notifier);
    final title = component.create
        ? switch (kind) {
            WorkspaceKind.models => t.app.workspaceModelNewTitle,
            WorkspaceKind.knowledge => t.app.workspaceKnowledgeCreateTitle,
            WorkspaceKind.prompts => t.app.workspacePromptCreateTitle,
            WorkspaceKind.tools => t.app.workspaceToolCreateTitle,
            WorkspaceKind.skills => t.app.workspaceSkillCreateTitle,
          }
        : (nameOf(_original).isEmpty ? idOf(_original) : nameOf(_original));
    final existing = !component.create;
    return div(classes: 'mx-auto w-full max-w-3xl space-y-4 p-6', [
      button(
        [Component.text('← ${sectionLabel(kind)}')],
        classes: 'text-xs text-muted-foreground hover:underline',
        type: ButtonType.button,
        onClick: () {
          if (_isDirty) {
            setState(() => _confirmingLeave = true);
          } else {
            workspaceGo(context, sectionPath(kind));
          }
        },
      ),
      if (_confirmingLeave)
        confirmBox(
          title: t.app.workspaceEditorDiscardTitle,
          message: t.app.workspaceEditorDiscardMessage,
          confirmText: t.app.workspaceEditorDiscardConfirm,
          cancelText: t.app.workspaceEditorKeepEditing,
          onConfirm: () {
            _dirty.set(false);
            workspaceGo(context, sectionPath(kind));
          },
          onCancel: () => setState(() => _confirmingLeave = false),
        ),
      div(classes: 'flex flex-wrap items-center gap-2', [
        h2(classes: 'min-w-0 flex-1 truncate text-lg font-semibold', [
          Component.text(title),
        ]),
        if (!_canWrite) badge(t.app.workspaceReadOnlyBadge),
        if (existing && _section.share && _canWrite)
          actionButton(
            t.app.workspaceModelManageAccess,
            id: 'workspace-access',
            onClick: () => setState(() => _accessOpen = true),
          ),
        if (existing && kind == WorkspaceKind.prompts)
          actionButton(
            t.app.workspacePromptHistory,
            id: 'workspace-history',
            onClick: () => setState(() => _historyOpen = !_historyOpen),
          ),
        if (existing &&
            kind == WorkspaceKind.tools &&
            _canWrite &&
            (_original.tool?.hasValves ?? false))
          actionButton(
            t.app.workspaceToolValvesServer,
            id: 'workspace-valves',
            onClick: () => setState(() => _valvesUser = false),
          ),
        if (existing &&
            kind == WorkspaceKind.tools &&
            (_original.tool?.hasUserValves ?? false))
          actionButton(
            t.app.workspaceToolValvesUser,
            id: 'workspace-user-valves',
            onClick: () => setState(() => _valvesUser = true),
          ),
        if (existing && _section.exportItems)
          actionButton(
            t.desktop.desktopWorkspaceExport,
            onClick: () => unawaited(_export(context)),
          ),
        if (existing && kind != WorkspaceKind.knowledge)
          actionButton(
            t.app.workspaceModelClone,
            onClick: () => _duplicate(context),
          ),
        if (existing && kind == WorkspaceKind.knowledge && _canWrite)
          actionButton(
            t.app.workspaceKnowledgeReset,
            destructive: true,
            onClick: () => setState(() => _confirmingReset = true),
          ),
        if (existing && _canWrite)
          actionButton(
            t.app.delete,
            destructive: true,
            id: 'workspace-delete',
            onClick: () => setState(() => _confirmingDelete = true),
          ),
        if (_canWrite)
          actionButton(
            _busy ? t.app.workspaceEditorSaving : t.app.save,
            primary: true,
            id: 'workspace-save',
            disabled: _busy || (!component.create && !_isDirty),
            onClick: () => unawaited(_save(context)),
          ),
      ]),
      if (!_canWrite) statusLine(t.app.workspaceReadOnlyExplanation),
      if (_status case final status?) statusLine(status, error: _statusIsError),
      if (_confirmingDelete)
        confirmBox(
          title: switch (kind) {
            WorkspaceKind.models => t.app.workspaceModelDeleteConfirmTitle,
            WorkspaceKind.knowledge =>
              t.app.workspaceKnowledgeDeleteConfirmTitle,
            WorkspaceKind.prompts => t.app.workspacePromptDeleteConfirmTitle,
            WorkspaceKind.tools => t.app.workspaceToolDeleteConfirmTitle,
            WorkspaceKind.skills => t.app.workspaceSkillDeleteConfirmTitle,
          },
          message: t.app.workspaceModelDeleteConfirmMessage(
            name: nameOf(_original),
          ),
          confirmText: t.app.delete,
          onConfirm: () => unawaited(_delete(context)),
          onCancel: () => setState(() => _confirmingDelete = false),
        ),
      if (_confirmingReset)
        confirmBox(
          title: t.app.workspaceKnowledgeResetConfirmTitle,
          message: t.app.workspaceKnowledgeResetConfirmMessage(
            name: nameOf(_original),
          ),
          confirmText: t.app.workspaceKnowledgeReset,
          onConfirm: () => unawaited(_reset(context)),
          onCancel: () => setState(() => _confirmingReset = false),
        ),
      if (_historyOpen && existing)
        PromptHistoryPanel(
          promptId: idOf(_original),
          canWrite: _canWrite,
          onRestore: (version) {
            _update(
              _draft.copyWith(
                prompt: _draft.prompt!.copyWith(content: version.content),
              ),
            );
            _say(t.app.workspacePromptHistoryRestored);
          },
          onProduction: (detail) => setState(() {
            _original = detail;
            _draft = detail;
          }),
        ),
      form(
        classes: 'space-y-4',
        events: <String, EventCallback>{
          'submit': (event) {
            event.preventDefault();
            if (_canWrite && !_busy) unawaited(_save(context));
          },
        },
        switch (kind) {
          WorkspaceKind.models => _modelFields(context),
          WorkspaceKind.knowledge => _knowledgeFields(),
          WorkspaceKind.prompts => _promptFields(context),
          WorkspaceKind.tools => _toolFields(context),
          WorkspaceKind.skills => _skillFields(context),
        },
      ),
      if (existing && kind == WorkspaceKind.knowledge)
        KnowledgeFiles(knowledgeId: idOf(_original), canWrite: _canWrite),
      if (_accessOpen)
        AccessDialog(
          kind: kind,
          id: idOf(_original),
          grants: _original.grants,
          section: _section,
          allowUserGrants: component.access.allowUserGrants,
          onClose: () => setState(() => _accessOpen = false),
          onSaved: (detail) {
            setState(() {
              _original = _original.copyWith(grants: detail.grants);
              _draft = _draft.copyWith(grants: detail.grants);
              _accessOpen = false;
            });
            _say(t.desktop.desktopWorkspaceAccessSaved);
          },
        ),
      if (_valvesUser case final user?)
        ValvesDialog(
          toolId: idOf(_original),
          user: user,
          onClose: () => setState(() => _valvesUser = null),
        ),
    ]);
  }

  // -------------------------------------------------------------------------
  // Fields, per kind
  // -------------------------------------------------------------------------

  Component _section2(String title, List<Component> children) =>
      section(classes: 'space-y-3 rounded border border-border p-4', [
        h3(classes: 'text-sm font-semibold', [Component.text(title)]),
        ...children,
      ]);

  /// The id field of a new item, which follows [derived] from the name
  /// until the user types their own.
  String _followName(String name, String id, String Function(String) derived) =>
      _idEdited ? id : derived(name);

  static String _slug(String name) => name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^a-z0-9_-]'), '');

  static String _toolId(String name) => name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '')
      .replaceFirst(RegExp(r'^(?=[0-9])'), '_');

  String _textOf(String key, String initial) => _text[key] ?? initial;

  List<Component> _modelFields(BuildContext context) {
    final m = _draft.model!;
    final disabled = !_canWrite;
    void set(WorkspaceModelDto next) => _update(_draft.copyWith(model: next));
    final options = context.watch(workspaceModelOptionsProvider).value;
    Component picks(
      String title,
      String key,
      List<WorkspaceRelation> choices,
      List<String> selected,
      void Function(List<String>) onChanged,
    ) => div(classes: 'space-y-1', [
      p(classes: 'text-sm font-medium', [
        Component.text(title),
        span(classes: 'ml-2 text-xs font-normal text-muted-foreground', [
          Component.text(
            selected.isEmpty
                ? t.app.workspaceModelSelectNone
                : t.app.workspaceModelSelectCount(count: selected.length),
          ),
        ]),
      ]),
      if (choices.isEmpty)
        p(classes: 'text-xs text-muted-foreground', [
          Component.text(t.app.workspaceModelRelationshipEmpty),
        ])
      else
        div(
          classes:
              'grid max-h-40 grid-cols-2 gap-1 overflow-y-auto rounded border '
              'border-border p-2',
          [
            for (final choice in choices)
              checkboxField(
                id: 'model-$key-${choice.id}',
                text: choice.name.isEmpty ? choice.id : choice.name,
                checked: selected.contains(choice.id),
                disabled: disabled,
                onChanged: ({required value}) => onChanged(
                  value
                      ? [...selected, choice.id]
                      : [
                          for (final id in selected)
                            if (id != choice.id) id,
                        ],
                ),
              ),
          ],
        ),
    ]);
    final knowledgeChoices = <WorkspaceRelation>[
      ...?options?.knowledge,
      // A base the model names that the list did not include -- shared
      // with it, not with this user -- still shows, so it can be removed.
      for (final k in m.knowledge)
        if (!(options?.knowledge.any((o) => o.id == k.id) ?? false)) k,
    ];
    return [
      _section2(t.app.workspaceModelSectionBasics, [
        if (component.create)
          textField(
            id: 'model-id',
            labelText: t.app.workspaceModelIdLabel,
            value: m.id,
            disabled: disabled,
            onInput: (value) {
              _idEdited = true;
              set(m.copyWith(id: value));
            },
          ),
        textField(
          id: 'model-name',
          labelText: t.app.workspaceModelName,
          value: m.name,
          disabled: disabled,
          onInput: (value) => set(
            m.copyWith(
              name: value,
              id: component.create ? _followName(value, m.id, _slug) : m.id,
            ),
          ),
        ),
        div(classes: 'space-y-1.5', [
          label(htmlFor: 'model-base', classes: 'block text-sm font-medium', [
            Component.text(t.app.workspaceModelBaseModel),
          ]),
          select(
            [
              option(value: '', selected: (m.baseModelId ?? '').isEmpty, [
                Component.text(t.app.workspaceModelBaseModelNone),
              ]),
              for (final base in <WorkspaceRelation>[
                ...?options?.baseModels,
                if (m.baseModelId case final id?
                    when id.isNotEmpty &&
                        !(options?.baseModels.any((base) => base.id == id) ??
                            false))
                  WorkspaceRelation(id: id, name: id),
              ])
                option(value: base.id, selected: base.id == m.baseModelId, [
                  Component.text(base.name.isEmpty ? base.id : base.name),
                ]),
            ],
            id: 'model-base',
            classes:
                'w-full rounded border border-border bg-background px-3 py-2 '
                'text-sm',
            disabled: disabled,
            onChange: (values) => set(
              m.copyWith(
                baseModelId: values.isEmpty || values.first.isEmpty
                    ? null
                    : values.first,
              ),
            ),
          ),
        ]),
        textAreaField(
          id: 'model-description',
          labelText: t.app.workspaceModelDescription,
          value: m.description,
          rows: 2,
          disabled: disabled,
          onInput: (value) => set(m.copyWith(description: value)),
        ),
        textField(
          id: 'model-tags',
          labelText: t.app.workspaceModelTags,
          placeholder: t.desktop.desktopWorkspaceCommaSeparated,
          value: _textOf('tags', m.tags.join(', ')),
          disabled: disabled,
          onInput: (value) {
            _text['tags'] = value;
            set(m.copyWith(tags: splitList(value)));
          },
        ),
        div(classes: 'flex items-center gap-3', [
          // A data URL is the image itself; a server path would need the
          // server's auth, so only the former is previewed.
          if (m.imageUrl case final url? when url.startsWith('data:image/'))
            img(
              src: url,
              alt: t.app.workspaceModelProfileImage,
              classes: 'size-12 rounded-full border border-border object-cover',
            )
          else
            span(
              classes:
                  'flex size-12 items-center justify-center rounded-full '
                  'border border-border text-xs text-muted-foreground',
              [Component.text(t.app.workspaceModelProfileImage)],
            ),
          if (!disabled) ...[
            actionButton(
              t.app.workspaceModelChangeImage,
              onClick: () => unawaited(_pickImage(context)),
            ),
            if ((m.imageUrl ?? '').isNotEmpty)
              actionButton(
                t.app.workspaceModelRemoveImage,
                onClick: () => set(m.copyWith(imageUrl: '')),
              ),
          ],
        ]),
        checkboxField(
          id: 'model-active',
          text: t.desktop.desktopWorkspaceActive,
          checked: m.active,
          disabled: disabled,
          onChanged: ({required value}) => set(m.copyWith(active: value)),
        ),
        checkboxField(
          id: 'model-hidden',
          text: t.app.workspaceModelHide,
          checked: m.hidden,
          disabled: disabled,
          onChanged: ({required value}) => set(m.copyWith(hidden: value)),
        ),
      ]),
      _section2(t.app.workspaceModelSectionPrompt, [
        textAreaField(
          id: 'model-system',
          labelText: t.app.workspaceModelSystemPrompt,
          value: m.system,
          rows: 6,
          disabled: disabled,
          onInput: (value) => set(m.copyWith(system: value)),
        ),
        textAreaField(
          id: 'model-suggestions',
          labelText: t.app.workspaceModelSuggestionPrompts,
          placeholder: t.desktop.desktopWorkspaceOnePerLine,
          value: _textOf('suggestions', m.suggestionPrompts.join('\n')),
          rows: 3,
          disabled: disabled,
          onInput: (value) {
            _text['suggestions'] = value;
            set(
              m.copyWith(suggestionPrompts: splitList(value, separator: '\n')),
            );
          },
        ),
      ]),
      _section2(t.app.workspaceModelCapabilities, [
        div(classes: 'grid grid-cols-2 gap-2', [
          for (final key in <String>{
            ...modelCapabilityKeys,
            ...m.capabilities.keys,
          })
            checkboxField(
              id: 'model-capability-$key',
              text: key,
              checked: m.capabilities[key] ?? false,
              disabled: disabled,
              onChanged: ({required value}) => set(
                m.copyWith(capabilities: {...m.capabilities, key: value}),
              ),
            ),
        ]),
      ]),
      _section2(t.app.workspaceModelSectionRelationships, [
        picks(
          t.app.workspaceModelKnowledge,
          'knowledge',
          knowledgeChoices,
          [for (final k in m.knowledge) k.id],
          (ids) => set(
            m.copyWith(
              knowledge: [
                for (final id in ids)
                  knowledgeChoices.firstWhere(
                    (k) => k.id == id,
                    orElse: () => WorkspaceRelation(id: id),
                  ),
              ],
            ),
          ),
        ),
        picks(
          t.app.workspaceModelTools,
          'tools',
          options?.tools ?? const [],
          m.toolIds,
          (ids) => set(m.copyWith(toolIds: ids)),
        ),
        picks(
          t.app.workspaceModelSkills,
          'skills',
          options?.skills ?? const [],
          m.skillIds,
          (ids) => set(m.copyWith(skillIds: ids)),
        ),
        picks(
          t.app.workspaceModelFilters,
          'filters',
          options?.filters ?? const [],
          m.filterIds,
          (ids) => set(
            m.copyWith(
              filterIds: ids,
              defaultFilterIds: [
                for (final id in m.defaultFilterIds)
                  if (ids.contains(id)) id,
              ],
            ),
          ),
        ),
        if (m.filterIds.isNotEmpty)
          picks(
            t.app.workspaceModelDefaultFilters,
            'default-filters',
            [
              for (final f in options?.filters ?? const <WorkspaceRelation>[])
                if (m.filterIds.contains(f.id)) f,
            ],
            m.defaultFilterIds,
            (ids) => set(m.copyWith(defaultFilterIds: ids)),
          ),
        picks(
          t.app.workspaceModelActions,
          'actions',
          options?.actions ?? const [],
          m.actionIds,
          (ids) => set(m.copyWith(actionIds: ids)),
        ),
      ]),
      _section2(t.app.workspaceModelSectionAdvanced, [
        textField(
          id: 'model-stop',
          labelText: t.app.workspaceModelStopSequences,
          placeholder: t.app.workspaceModelStopHint,
          value: _textOf('stop', m.stop.join(', ')),
          disabled: disabled,
          onInput: (value) {
            _text['stop'] = value;
            set(m.copyWith(stop: splitList(value)));
          },
        ),
        textField(
          id: 'model-features',
          labelText: t.app.workspaceModelDefaultFeatures,
          placeholder: t.desktop.desktopWorkspaceDefaultFeaturesHint,
          value: _textOf('features', m.defaultFeatureIds.join(', ')),
          disabled: disabled,
          onInput: (value) {
            _text['features'] = value;
            set(m.copyWith(defaultFeatureIds: splitList(value)));
          },
        ),
        div(classes: 'space-y-1.5', [
          label(
            htmlFor: 'model-terminal',
            classes: 'block text-sm font-medium',
            [Component.text(t.app.workspaceModelTerminal)],
          ),
          select(
            [
              option(value: '', selected: m.terminalId.isEmpty, [
                Component.text(t.app.workspaceModelSelectNone),
              ]),
              for (final server in <TerminalServerDto>[
                ...?context.watch(terminalServersProvider).value?.servers,
                // One the model names that this account cannot see.
                if (m.terminalId.isNotEmpty &&
                    !(context
                            .watch(terminalServersProvider)
                            .value
                            ?.servers
                            .any((server) => server.id == m.terminalId) ??
                        false))
                  TerminalServerDto(id: m.terminalId, name: m.terminalId),
              ])
                option(value: server.id, selected: server.id == m.terminalId, [
                  Component.text(server.name.isEmpty ? server.id : server.name),
                ]),
            ],
            id: 'model-terminal',
            classes:
                'w-full rounded border border-border bg-background px-3 py-2 '
                'text-sm',
            disabled: disabled,
            onChange: (values) =>
                set(m.copyWith(terminalId: values.isEmpty ? '' : values.first)),
          ),
        ]),
        textField(
          id: 'model-tts',
          labelText: t.app.workspaceModelTtsVoice,
          value: m.ttsVoice,
          disabled: disabled,
          onInput: (value) => set(m.copyWith(ttsVoice: value)),
        ),
        textAreaField(
          id: 'model-params',
          labelText: t.app.workspaceModelAdvancedParams,
          placeholder: t.app.workspaceModelParamsHint,
          value: _textOf(
            'params',
            m.params.isEmpty
                ? ''
                : const JsonEncoder.withIndent('  ').convert(m.params),
          ),
          rows: 6,
          monospace: true,
          disabled: disabled,
          error: _paramsError,
          onInput: (value) {
            _text['params'] = value;
            try {
              final decoded = value.trim().isEmpty
                  ? <String, dynamic>{}
                  : jsonDecode(value);
              if (decoded is! Map<String, dynamic>) {
                throw const FormatException();
              }
              _paramsError = null;
              set(m.copyWith(params: decoded));
            } on FormatException {
              setState(() => _paramsError = t.app.workspaceModelInvalidJson);
              _dirty.set(true);
            }
          },
        ),
      ]),
    ];
  }

  List<Component> _knowledgeFields() {
    final k = _draft.knowledge!;
    void set(WorkspaceKnowledgeDto next) =>
        _update(_draft.copyWith(knowledge: next));
    return [
      textField(
        id: 'knowledge-name',
        labelText: t.app.workspaceKnowledgeName,
        value: k.name,
        disabled: !_canWrite,
        onInput: (value) => set(k.copyWith(name: value)),
      ),
      textAreaField(
        id: 'knowledge-description',
        labelText: t.app.workspaceKnowledgeDescription,
        value: k.description,
        rows: 2,
        disabled: !_canWrite,
        onInput: (value) => set(k.copyWith(description: value)),
      ),
    ];
  }

  List<Component> _promptFields(BuildContext context) {
    final p = _draft.prompt!;
    final disabled = !_canWrite;
    void set(WorkspacePromptDto next) => _update(_draft.copyWith(prompt: next));
    return [
      textField(
        id: 'prompt-name',
        labelText: t.app.workspacePromptName,
        value: p.name,
        disabled: disabled,
        onInput: (value) => set(
          p.copyWith(
            name: value,
            command: component.create
                ? _followName(value, p.command, _slug)
                : p.command,
          ),
        ),
      ),
      textField(
        id: 'prompt-command',
        labelText: t.app.workspacePromptCommand,
        placeholder: t.app.workspacePromptCommandHint,
        value: p.command.isEmpty ? '' : '/${p.command}',
        disabled: disabled,
        onInput: (value) {
          _idEdited = true;
          set(p.copyWith(command: value.replaceFirst(RegExp(r'^/+'), '')));
        },
      ),
      textAreaField(
        id: 'prompt-content',
        labelText: t.app.workspacePromptContent,
        placeholder: t.app.workspacePromptContentHint,
        value: p.content,
        rows: 10,
        disabled: disabled,
        onInput: (value) => set(p.copyWith(content: value)),
      ),
      textField(
        id: 'prompt-tags',
        labelText: t.app.workspacePromptTags,
        placeholder: t.desktop.desktopWorkspaceCommaSeparated,
        value: _textOf('tags', p.tags.join(', ')),
        disabled: disabled,
        onInput: (value) {
          _text['tags'] = value;
          set(p.copyWith(tags: splitList(value)));
        },
      ),
      if (!component.create && _canWrite)
        _section2(t.app.workspacePromptVersionSection, [
          textField(
            id: 'prompt-commit',
            labelText: t.app.workspacePromptCommitMessage,
            placeholder: t.app.workspacePromptCommitMessageHint,
            value: p.commitMessage ?? '',
            onInput: (value) =>
                set(p.copyWith(commitMessage: value.isEmpty ? null : value)),
          ),
          actionButton(
            t.app.workspacePromptUpdateDetails,
            id: 'prompt-save-details',
            disabled: _busy || !_isDirty,
            onClick: () => unawaited(_save(context, metadataOnly: true)),
          ),
          checkboxField(
            id: 'prompt-production',
            text: t.app.workspacePromptSetProduction,
            checked: p.production,
            onChanged: ({required value}) => set(p.copyWith(production: value)),
          ),
        ]),
    ];
  }

  List<Component> _toolFields(BuildContext context) {
    final tool = _draft.tool!;
    final disabled = !_canWrite;
    void set(WorkspaceToolDto next) => _update(_draft.copyWith(tool: next));
    return [
      p(
        classes:
            'rounded border border-destructive/40 bg-destructive/10 p-2 '
            'text-xs',
        [Component.text(t.app.workspaceToolWarning)],
      ),
      if (tool.requiresServerVersion case final version?)
        statusLine(
          t.app.workspaceToolManifestRequiredVersion(version: version),
          error: true,
        ),
      if (_canWrite)
        div(classes: 'flex items-end gap-2', [
          if (_urlOpen) ...[
            div(classes: 'flex-1', [
              textField(
                id: 'tool-url',
                labelText: t.app.workspaceToolImportUrlLabel,
                placeholder: t.app.workspaceToolImportUrlHint,
                value: _url,
                onInput: (value) => setState(() => _url = value),
              ),
            ]),
            actionButton(
              t.app.workspaceImportRun,
              disabled: _url.trim().isEmpty,
              onClick: () => unawaited(_loadUrl(context)),
            ),
          ] else
            actionButton(
              t.app.workspaceToolImportUrl,
              onClick: () => setState(() => _urlOpen = true),
            ),
        ]),
      textField(
        id: 'tool-name',
        labelText: t.app.workspaceToolName,
        placeholder: t.app.workspaceToolNameHint,
        value: tool.name,
        disabled: disabled,
        onInput: (value) => set(
          tool.copyWith(
            name: value,
            id: component.create
                ? _followName(value, tool.id, _toolId)
                : tool.id,
          ),
        ),
      ),
      if (component.create)
        textField(
          id: 'tool-id',
          labelText: t.app.workspaceToolId,
          placeholder: t.app.workspaceToolIdHint,
          value: tool.id,
          onInput: (value) {
            _idEdited = true;
            set(tool.copyWith(id: value));
          },
        ),
      textField(
        id: 'tool-description',
        labelText: t.app.workspaceToolDescription,
        placeholder: t.app.workspaceToolDescriptionHint,
        value: tool.description,
        disabled: disabled,
        onInput: (value) => set(tool.copyWith(description: value)),
      ),
      textAreaField(
        id: 'tool-content',
        labelText: t.app.workspaceToolContent,
        placeholder: t.app.workspaceToolContentHint,
        value: tool.content,
        rows: 20,
        monospace: true,
        disabled: disabled,
        onInput: (value) => set(tool.copyWith(content: value)),
      ),
      if (tool.functions.isNotEmpty)
        div(classes: 'space-y-1', [
          p(classes: 'text-sm font-medium', [
            Component.text(t.app.workspaceToolSpecs),
            span(classes: 'ml-2 text-xs font-normal text-muted-foreground', [
              Component.text(
                t.app.workspaceToolFunctionCount(count: tool.functions.length),
              ),
            ]),
          ]),
          ul(classes: 'flex flex-wrap gap-1', [
            for (final name in tool.functions)
              li([
                code(classes: 'rounded bg-muted px-1.5 py-0.5 text-xs', [
                  Component.text(name),
                ]),
              ]),
          ]),
        ]),
    ];
  }

  List<Component> _skillFields(BuildContext context) {
    final s = _draft.skill!;
    final disabled = !_canWrite;
    void set(WorkspaceSkillDto next) => _update(_draft.copyWith(skill: next));
    return [
      if (component.create)
        div([
          actionButton(
            t.app.workspaceSkillImportMarkdown,
            onClick: () => unawaited(_importMarkdown(context)),
          ),
        ]),
      textField(
        id: 'skill-name',
        labelText: t.app.workspaceSkillName,
        placeholder: t.app.workspaceSkillNameHint,
        value: s.name,
        disabled: disabled,
        onInput: (value) => set(
          s.copyWith(
            name: value,
            id: component.create ? _followName(value, s.id, _slug) : s.id,
          ),
        ),
      ),
      if (component.create)
        textField(
          id: 'skill-id',
          labelText: t.app.workspaceSkillId,
          placeholder: t.app.workspaceSkillIdHint,
          value: s.id,
          onInput: (value) {
            _idEdited = true;
            set(s.copyWith(id: value));
          },
        ),
      textField(
        id: 'skill-description',
        labelText: t.app.workspaceSkillDescription,
        placeholder: t.app.workspaceSkillDescriptionHint,
        value: s.description,
        disabled: disabled,
        onInput: (value) => set(s.copyWith(description: value)),
      ),
      textAreaField(
        id: 'skill-content',
        labelText: t.app.workspaceSkillContent,
        placeholder: t.app.workspaceSkillContentHint,
        value: s.content,
        rows: 12,
        disabled: disabled,
        onInput: (value) => set(s.copyWith(content: value)),
      ),
      checkboxField(
        id: 'skill-active',
        text: t.desktop.desktopWorkspaceActive,
        checked: s.active,
        disabled: disabled,
        onChanged: ({required value}) => set(s.copyWith(active: value)),
      ),
    ];
  }
}

/// A Markdown file's front matter -- the `---` block at its top -- as
/// `key: value` pairs, quotes taken off. The same reading as the core's
/// `WorkspaceSkillContent.parseFrontmatter`, which mobile uses.
Map<String, String> skillFrontMatter(String content) {
  final match = RegExp(r'^---\s*\n([\s\S]*?)\n---').firstMatch(content);
  if (match == null) return const <String, String>{};
  return <String, String>{
    for (final line in match[1]!.split('\n'))
      if (line.indexOf(':') case final colon when colon > 0)
        line.substring(0, colon).trim(): line
            .substring(colon + 1)
            .trim()
            .replaceAll(RegExp(r'''^["']|["']$'''), ''),
  };
}
