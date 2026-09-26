import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart' show Link;

import '../../l10n/strings.g.dart';
import '../../rpc/rpc_providers.dart'
    show filePickerProvider, fileSaverProvider;
import '../../rpc/workspace_providers.dart';
import '../../widgets/form_field.dart';
import 'workspace_common.dart';
import 'workspace_editor.dart';
import '../../widgets/ui.dart';

/// The workspace: models, knowledge, prompts, tools and skills on the
/// account's server, each a list and an editor.
///
/// [section] null opens the first section the user may manage. [id] opens
/// an item; [create] a new one.
class WorkspaceScreen extends StatelessComponent {
  const WorkspaceScreen({
    this.section,
    this.id,
    this.create = false,
    super.key,
  });

  final String? section;
  final String? id;
  final bool create;

  @override
  Component build(BuildContext context) {
    final access = context.watch(workspaceAccessProvider);
    final sections = access.value == null
        ? const <WorkspaceKind>[]
        : manageableSections(access.value!);
    final kind = sectionFromPath(section);
    if (access.value != null && kind == null && sections.isNotEmpty) {
      // The bare /workspace: the first section there is.
      final go = context.read(workspaceNavigateProvider);
      Future<void>.microtask(
        () => go(context, sectionPath(sections.first), replace: true),
      );
    }
    return div(
      classes: 'flex min-h-0 min-w-0 flex-1 overflow-hidden rounded-lg border border-border bg-panel text-foreground',
      [
        _SectionNav(sections: sections, current: kind),
        main_(classes: 'flex min-w-0 flex-1 flex-col overflow-y-auto', [
          if (access.isLoading && access.value == null)
            _centered(t.app.loadingShort)
          else if (access.hasError && access.value == null)
            _centered(t.app.workspaceLoadFailed)
          else if (sections.isEmpty)
            _centered(t.desktop.desktopWorkspaceNoSections)
          else if (kind == null)
            _centered(t.app.loadingShort)
          else if (!sections.contains(kind))
            _centered(t.app.workspaceDenied)
          else if (id == null && !create)
            WorkspaceList(
              key: ValueKey('list-${kind.name}'),
              kind: kind,
              access: sectionAccess(access.value!, kind),
            )
          else
            WorkspaceEditor(
              key: ValueKey('editor-${kind.name}-${id ?? 'new'}'),
              kind: kind,
              id: id,
              access: access.value!,
            ),
        ]),
      ],
    );
  }

  Component _centered(String text) => div(
    classes: 'flex flex-1 items-center justify-center p-8',
    [
      p(classes: 'text-ui-base text-foreground-subtle', [Component.text(text)]),
    ],
  );
}

/// The sections, down the left. Leaving an editor with changes asks first.
class _SectionNav extends StatefulComponent {
  const _SectionNav({required this.sections, required this.current});

  final List<WorkspaceKind> sections;
  final WorkspaceKind? current;

  @override
  State<_SectionNav> createState() => _SectionNavState();
}

class _SectionNavState extends State<_SectionNav> {
  /// Where the user asked to go while an editor had changes.
  String? _pending;

  void _go(BuildContext context, String to) {
    if (context.read(workspaceEditorDirtyProvider)) {
      setState(() => _pending = to);
      return;
    }
    workspaceGo(context, to);
  }

  @override
  Component build(BuildContext context) {
    return nav(
      classes: 'flex w-56 shrink-0 flex-col gap-1 border-r border-border bg-surface p-3',
      attributes: <String, String>{'aria-label': t.app.workspaceTitle},
      [
        div(classes: 'mb-2 flex items-center gap-2', [
          button(
            [icon(LucideIcon.arrowLeft, classes: 'size-4')],
            classes: 'rounded-lg px-2 py-1 text-ui-base hover:bg-hover',
            type: ButtonType.button,
            attributes: <String, String>{'aria-label': t.app.back},
            onClick: () => _go(context, '/'),
          ),
          h1(classes: 'text-ui-base font-semibold', [
            Component.text(t.app.workspaceTitle),
          ]),
        ]),
        for (final kind in component.sections)
          button(
            [Component.text(sectionLabel(kind))],
            classes:
                'block w-full rounded-lg px-2 py-1.5 text-left text-ui-base '
                'hover:bg-hover aria-[current=page]:bg-accent '
                'aria-[current=page]:font-medium',
            type: ButtonType.button,
            attributes: <String, String>{
              if (kind == component.current) 'aria-current': 'page',
            },
            onClick: () => _go(context, sectionPath(kind)),
          ),
        if (_pending case final target?)
          div(classes: 'mt-3', [
            confirmBox(
              title: t.app.workspaceEditorDiscardTitle,
              message: t.app.workspaceEditorDiscardMessage,
              confirmText: t.app.workspaceEditorDiscardConfirm,
              cancelText: t.app.workspaceEditorKeepEditing,
              onConfirm: () {
                context.read(workspaceEditorDirtyProvider.notifier).set(false);
                setState(() => _pending = null);
                workspaceGo(context, target);
              },
              onCancel: () => setState(() => _pending = null),
            ),
          ]),
      ],
    );
  }
}

/// One section's items: search, filters, the list a page at a time, and
/// import and export.
class WorkspaceList extends StatefulComponent {
  const WorkspaceList({required this.kind, required this.access, super.key});

  final WorkspaceKind kind;
  final WorkspaceSectionAccess access;

  @override
  State<WorkspaceList> createState() => _WorkspaceListState();
}

class _WorkspaceListState extends State<WorkspaceList> {
  Timer? _searchTimer;
  String? _search;
  String? _status;
  bool _statusIsError = false;
  bool _busy = false;

  WorkspaceKind get kind => component.kind;

  @override
  void dispose() {
    _searchTimer?.cancel();
    super.dispose();
  }

  void _say(String text, {bool error = false}) => setState(() {
    _status = text;
    _statusIsError = error;
  });

  Future<void> _import(BuildContext context) async {
    final picker = context.read(filePickerProvider);
    final actions = context.read(workspaceActionsProvider);
    final file = await picker.pickText(accept: '.json,application/json');
    if (file == null) return;
    setState(() => _busy = true);
    try {
      final result = await actions.import(kind, file.content);
      final total = result.imported + result.failed.length;
      final summary = t.app.workspaceImportSummary(
        success: result.imported,
        total: total,
      );
      _say(
        result.failed.isEmpty
            ? summary
            : '$summary. ${t.desktop.desktopWorkspaceImportFailed(items: [for (final f in result.failed) '${f.label} (${f.reason})'].join(', '))}',
        error: result.imported == 0,
      );
    } on RpcError catch (error) {
      _say(
        error.code == ConduitErrorCodes.invalidParams
            ? t.app.workspaceImportInvalidJson
            : t.app.workspaceImportBatchFailed,
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportAll(BuildContext context) async {
    final saver = context.read(fileSaverProvider);
    final actions = context.read(workspaceActionsProvider);
    setState(() => _busy = true);
    try {
      final file = await actions.export(kind);
      saver.save(
        filename: file.filename,
        mimeType: file.mimeType,
        text: file.text,
        base64: file.base64,
      );
    } on Object {
      _say(t.app.workspaceModelExportFailed, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(BuildContext context, WorkspaceItem item) async {
    final notifier = context.read(workspacePageProvider(kind).notifier);
    try {
      notifier.replace(
        await context.read(workspaceActionsProvider).toggle(kind, item.id),
      );
    } on Object {
      _say(t.app.workspaceLoadFailed, error: true);
    }
  }

  @override
  Component build(BuildContext context) {
    final page = context.watch(workspacePageProvider(kind));
    final filter = context.watch(workspaceFilterProvider(kind));
    final access = component.access;
    final items = page.value?.items ?? const <WorkspaceItem>[];
    return div(classes: 'mx-auto w-full max-w-4xl space-y-4 p-6', [
      div(classes: 'flex flex-wrap items-center gap-2', [
        h2(classes: 'flex-1 text-ui-xl font-semibold', [
          Component.text(sectionLabel(kind)),
          if (page.value case final value?)
            span(
              classes: 'ml-2 text-ui-base font-normal text-foreground-subtle',
              [Component.text('${value.total}')],
            ),
        ]),
        if (access.importItems && kind != WorkspaceKind.knowledge)
          actionButton(
            t.desktop.desktopWorkspaceImport,
            disabled: _busy,
            onClick: () => unawaited(_import(context)),
          ),
        if (access.exportItems && kind != WorkspaceKind.knowledge)
          actionButton(
            t.desktop.desktopWorkspaceExportAll,
            disabled: _busy,
            onClick: () => unawaited(_exportAll(context)),
          ),
        actionButton(
          t.app.workspaceCreate,
          primary: true,
          id: 'workspace-create',
          onClick: () => workspaceGo(context, '${sectionPath(kind)}/new'),
        ),
      ]),
      div(classes: 'flex flex-wrap items-end gap-2', [
        div(classes: 'min-w-60 flex-1', [
          textField(
            id: 'workspace-search',
            labelText: t.app.workspaceSearchHint,
            hideLabel: true,
            placeholder: t.app.workspaceSearchHint,
            value: _search ?? filter.query,
            onInput: (value) {
              setState(() => _search = value);
              _searchTimer?.cancel();
              _searchTimer = Timer(const Duration(milliseconds: 300), () {
                context
                    .read(workspaceFilterProvider(kind).notifier)
                    .setQuery(value);
              });
            },
          ),
        ]),
        _select(
          id: 'workspace-view',
          label: t.app.workspaceKnowledgeViewAll,
          value: filter.view,
          options: {
            'all': t.app.workspaceKnowledgeViewAll,
            'created': t.app.workspaceKnowledgeViewCreated,
            'shared': t.app.workspaceKnowledgeViewShared,
          },
          onChange: (value) => context
              .read(workspaceFilterProvider(kind).notifier)
              .setView(value),
        ),
        if (kind == WorkspaceKind.knowledge)
          _select(
            id: 'workspace-source',
            label: t.app.workspaceKnowledgeSourceAll,
            value: filter.source,
            options: {
              '': t.app.workspaceKnowledgeSourceAll,
              'local': t.app.workspaceKnowledgeSourceLocal,
              'external': t.app.workspaceKnowledgeSourceExternal,
            },
            onChange: (value) => context
                .read(workspaceFilterProvider(kind).notifier)
                .setSource(value),
          ),
      ]),
      if (_status case final status?) statusLine(status, error: _statusIsError),
      if (page.isLoading && page.value == null)
        statusLine(t.app.loadingShort)
      else if (page.hasError && page.value == null)
        div(classes: 'space-y-2', [
          formError(t.app.workspaceLoadFailed),
          actionButton(
            t.app.workspaceRetry,
            onClick: () => context.invalidate(workspacePageProvider(kind)),
          ),
        ])
      else if (items.isEmpty)
        statusLine(t.app.workspaceEmpty)
      else
        ul(classes: 'divide-y divide-border rounded-lg border border-border', [
          for (final item in items) _row(context, item),
        ]),
      if (page.value?.hasMore ?? false)
        actionButton(
          t.app.workspaceLoadMore,
          onClick: () => unawaited(
            context.read(workspacePageProvider(kind).notifier).loadMore(),
          ),
        ),
    ]);
  }

  Component _row(BuildContext context, WorkspaceItem item) => li(
    classes: 'flex items-center gap-3 px-3 py-2',
    attributes: <String, String>{'data-item': item.id},
    [
      div(classes: 'min-w-0 flex-1', [
        div(classes: 'flex items-center gap-2', [
          Link(
            to: sectionPath(kind, item.id),
            classes: 'truncate text-ui-base font-medium hover:underline',
            child: Component.text(item.name.isEmpty ? item.id : item.name),
          ),
          if (item.public) badge(t.app.workspaceAccessVisibilityLabel),
          if (!item.writeAccess) badge(t.app.workspaceReadOnlyBadge),
          if (item.active == false) badge(t.app.workspaceModelDeactivate),
        ]),
        if (item.subtitle case final subtitle?)
          p(classes: 'truncate text-ui-sm text-foreground-subtle', [
            Component.text(subtitle),
          ]),
        p(classes: 'text-ui-xs text-foreground-subtle', [
          Component.text(
            [
              ?item.ownerName,
              if (item.updatedAtMs case final ms?)
                t.desktop.desktopWorkspaceUpdated(date: dayOf(ms)),
              if (item.tags.isNotEmpty) item.tags.join(', '),
            ].join(' · '),
          ),
        ]),
      ]),
      if (item.active != null && item.writeAccess)
        label(classes: 'flex items-center gap-1.5 text-ui-sm', [
          input<bool>(
            classes: 'size-4',
            type: InputType.checkbox,
            checked: item.active,
            attributes: <String, String>{
              'aria-label': '${t.desktop.desktopWorkspaceActive}: ${item.name}',
            },
            onChange: (_) => unawaited(_toggle(context, item)),
          ),
          Component.text(t.desktop.desktopWorkspaceActive),
        ]),
    ],
  );

  Component _select({
    required String id,
    required String label,
    required String value,
    required Map<String, String> options,
    required void Function(String value) onChange,
  }) => select(
    [
      for (final entry in options.entries)
        option(value: entry.key, selected: entry.key == value, [
          Component.text(entry.value),
        ]),
    ],
    id: id,
    classes:
        'rounded-lg border border-border bg-panel px-2 py-2 text-ui-base '
        'text-foreground',
    attributes: <String, String>{'aria-label': label},
    onChange: (values) => onChange(values.isEmpty ? '' : values.first),
  );
}
