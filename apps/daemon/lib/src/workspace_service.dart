import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/workspace/models/workspace_model_draft.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/models/workspace_tool_content.dart';
import 'package:conduit_core/features/workspace/models/workspace_transfer.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_knowledge_files.dart';
import 'package:conduit_core/features/workspace/providers/workspace_model_relationships.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';

/// Implements `workspace.*` over the core's workspace providers (M6).
///
/// The providers are mobile's: one collection per section, paged and
/// filtered by the notifier, and one file browser per knowledge base. The
/// daemon maps them to the protocol's typed items, keeps what an editor
/// does not show when it saves, and tells every window with
/// `workspace.changed` when a section moved.
final class WorkspaceService {
  WorkspaceService(this._container, {EventBus? events}) : _events = events;

  final ProviderContainer _container;
  final EventBus? _events;

  Future<WorkspaceAccess> capabilities() => _guard(() async {
    final caps = await readSettled(
      _container,
      workspaceCapabilitiesProvider.future,
    );
    WorkspaceSectionAccess section(WorkspaceSectionCapabilities s) =>
        WorkspaceSectionAccess(
          manage: s.manage,
          importItems: s.importItems,
          exportItems: s.exportItems,
          share: s.share,
          sharePublicly: s.sharePublicly,
        );
    return WorkspaceAccess(
      models: section(caps.models),
      knowledge: section(caps.knowledge),
      prompts: section(caps.prompts),
      tools: section(caps.tools),
      skills: section(caps.skills),
      allowUserGrants: caps.allowUserGrants,
      admin: _isAdmin,
    );
  });

  // ---------------------------------------------------------------------------
  // Lists
  // ---------------------------------------------------------------------------

  Future<WorkspacePage> list(WorkspaceQuery query) => _guard(() async {
    switch (query.kind) {
      case WorkspaceKind.models:
        final p = workspaceModelsProvider;
        final n = _container.read(p.notifier);
        return _page(
          query,
          () => readSettled(_container, p.future),
          () => _container.read(p).requireValue,
          _modelItem,
          (
            setQuery: n.setQuery,
            setView: n.setView,
            setSource: null,
            refresh: n.refresh,
            loadMore: n.loadMore,
          ),
        );
      case WorkspaceKind.knowledge:
        final p = workspaceKnowledgeProvider;
        final n = _container.read(p.notifier);
        return _page(
          query,
          () => readSettled(_container, p.future),
          () => _container.read(p).requireValue,
          _knowledgeItem,
          (
            setQuery: n.setQuery,
            setView: n.setView,
            setSource: n.setSource,
            refresh: n.refresh,
            loadMore: n.loadMore,
          ),
        );
      case WorkspaceKind.prompts:
        final p = workspacePromptsProvider;
        final n = _container.read(p.notifier);
        return _page(
          query,
          () => readSettled(_container, p.future),
          () => _container.read(p).requireValue,
          _promptItem,
          (
            setQuery: n.setQuery,
            setView: n.setView,
            setSource: null,
            refresh: n.refresh,
            loadMore: n.loadMore,
          ),
        );
      case WorkspaceKind.tools:
        final p = workspaceToolsProvider;
        final n = _container.read(p.notifier);
        return _page(
          query,
          () => readSettled(_container, p.future),
          () => _container.read(p).requireValue,
          _toolItem,
          (
            setQuery: n.setQuery,
            setView: n.setView,
            setSource: null,
            refresh: n.refresh,
            loadMore: n.loadMore,
          ),
        );
      case WorkspaceKind.skills:
        final p = workspaceSkillsProvider;
        final n = _container.read(p.notifier);
        return _page(
          query,
          () => readSettled(_container, p.future),
          () => _container.read(p).requireValue,
          _skillItem,
          (
            setQuery: n.setQuery,
            setView: n.setView,
            setSource: null,
            refresh: n.refresh,
            loadMore: n.loadMore,
          ),
        );
    }
  });

  /// Brings a section's collection to [query] and answers with it. The
  /// notifier refetches when a filter changes; an unchanged one is
  /// refreshed, so opening a section shows what the server has now.
  Future<WorkspacePage> _page<T>(
    WorkspaceQuery query,
    Future<WorkspaceCollectionState<T>> Function() settle,
    WorkspaceCollectionState<T> Function() current,
    WorkspaceItem Function(T item) toItem,
    _Controls c,
  ) async {
    var state = await settle();
    if (query.more) {
      await c.loadMore();
    } else {
      var fetched = false;
      if (state.query != query.query) {
        await c.setQuery(query.query);
        fetched = true;
      }
      if (state.view != query.view) {
        await c.setView(query.view);
        fetched = true;
      }
      final setSource = c.setSource;
      if (setSource != null && state.source != query.source) {
        await setSource(query.source);
        fetched = true;
      }
      if (!fetched) await c.refresh();
    }
    state = current();
    if (state.error case final error?) throw error;
    return WorkspacePage(
      kind: query.kind,
      items: state.items.map(toItem).toList(growable: false),
      total: state.total,
      hasMore: state.hasMore,
    );
  }

  // ---------------------------------------------------------------------------
  // One item
  // ---------------------------------------------------------------------------

  Future<WorkspaceDetail> get(WorkspaceRef ref) =>
      _guard(() => _detail(ref.kind, ref.id));

  Future<WorkspaceDetail> _detail(WorkspaceKind kind, String id) async {
    switch (kind) {
      case WorkspaceKind.models:
        final model = await readSettled(
          _container,
          workspaceModelDetailProvider(id).future,
        );
        if (model == null) throw _notFound(kind, id);
        return _modelDetail(model);
      case WorkspaceKind.knowledge:
        final knowledge = await readSettled(
          _container,
          workspaceKnowledgeDetailProvider(id).future,
        );
        if (knowledge == null) throw _notFound(kind, id);
        final summary = knowledge.summary;
        return WorkspaceDetail(
          kind: kind,
          knowledge: WorkspaceKnowledgeDto(
            id: summary.id,
            name: summary.name,
            description: summary.description,
            fileCount: knowledge.files.length,
          ),
          grants: _grants(summary.accessGrants),
          writeAccess: _writable(summary.writeAccess, summary.userId),
          ownerName: summary.owner?.name,
          updatedAtMs: _ms(summary.updatedAt),
        );
      case WorkspaceKind.prompts:
        final prompt = await readSettled(
          _container,
          workspacePromptDetailProvider(id).future,
        );
        if (prompt == null) throw _notFound(kind, id);
        return WorkspaceDetail(
          kind: kind,
          prompt: WorkspacePromptDto(
            id: prompt.id,
            command: prompt.command,
            name: prompt.name,
            content: prompt.content,
            tags: prompt.tags,
            active: prompt.isActive,
            versionId: prompt.versionId,
          ),
          grants: _grants(prompt.accessGrants),
          writeAccess: _writable(prompt.writeAccess, prompt.userId),
          ownerName: prompt.owner?.name,
          updatedAtMs: _ms(prompt.updatedAt),
        );
      case WorkspaceKind.tools:
        final tool = await readSettled(
          _container,
          workspaceToolDetailProvider(id).future,
        );
        if (tool == null) throw _notFound(kind, id);
        final tools = _container.read(workspaceToolsProvider.notifier);
        // Valves are optional; a tool without them answers with nothing,
        // an older server with an error. Either way there is no form.
        Future<bool> hasValves(Future<WorkspaceValveSpec?> spec) => spec
            .then((s) => s != null && s.properties.isNotEmpty)
            .catchError((Object _) => false);
        final (valves, userValves) = await (
          hasValves(tools.toolValvesSpec(id)),
          hasValves(tools.userToolValvesSpec(id)),
        ).wait;
        return WorkspaceDetail(
          kind: kind,
          tool: _toolDto(
            id: tool.id,
            name: tool.name,
            meta: tool.meta,
            content: tool.content ?? '',
            specs: tool.specs,
            hasValves: valves,
            hasUserValves: userValves,
          ),
          grants: _grants(tool.accessGrants),
          writeAccess: _writable(tool.writeAccess, tool.userId),
          ownerName: tool.owner?.name,
          updatedAtMs: _ms(tool.updatedAt),
        );
      case WorkspaceKind.skills:
        final skill = await readSettled(
          _container,
          workspaceSkillDetailProvider(id).future,
        );
        if (skill == null) throw _notFound(kind, id);
        return _skillDetail(skill);
    }
  }

  Future<WorkspaceDetail> save(WorkspaceSave request) => _guard(() async {
    final detail = request.detail;
    final create = request.create;
    final grants = [for (final g in detail.grants) _grantInput(g)];
    final String id;
    switch (detail.kind) {
      case WorkspaceKind.models:
        final dto = _require(detail.model, detail.kind);
        final notifier = _container.read(workspaceModelsProvider.notifier);
        // An existing model is saved over as the server has it, so keys
        // this editor does not show survive.
        final draft = create
            ? WorkspaceModelDraft.empty()
            : WorkspaceModelDraft.fromSummary(
                await _api().getWorkspaceModel(dto.id) ??
                    (throw _notFound(detail.kind, dto.id)),
              );
        _applyModel(draft, dto);
        if (create) draft.accessGrants = grants;
        if (!draft.isValid) throw _invalid('a model needs an id and a name');
        final saved = create
            ? await notifier.create(draft.toForm())
            : await notifier.updateItem(draft.toForm());
        id = saved.id;
      case WorkspaceKind.knowledge:
        final dto = _require(detail.knowledge, detail.kind);
        final notifier = _container.read(workspaceKnowledgeProvider.notifier);
        if (dto.name.trim().isEmpty) throw _invalid('knowledge needs a name');
        if (create) {
          final saved = await notifier.create(
            WorkspaceKnowledgeForm(
              name: dto.name.trim(),
              description: dto.description.trim(),
              accessGrants: grants,
            ),
          );
          id = saved.summary.id;
        } else {
          final existing = await _api().getWorkspaceKnowledgeDetail(dto.id);
          if (existing == null) throw _notFound(detail.kind, dto.id);
          await notifier.updateItem(
            dto.id,
            WorkspaceKnowledgeForm(
              name: dto.name.trim(),
              description: dto.description.trim(),
              accessGrants: _inputs(existing.summary.accessGrants),
            ),
          );
          id = dto.id;
        }
      case WorkspaceKind.prompts:
        final dto = _require(detail.prompt, detail.kind);
        final notifier = _container.read(workspacePromptsProvider.notifier);
        final command = dto.command.trim().replaceFirst(RegExp(r'^/+'), '');
        if (command.isEmpty || dto.content.trim().isEmpty) {
          throw _invalid('a prompt needs a command and content');
        }
        final existing = create
            ? null
            : await _api().getWorkspacePrompt(dto.id);
        if (!create && existing == null) {
          throw _notFound(detail.kind, dto.id);
        }
        final commit = dto.commitMessage?.trim();
        final form = WorkspacePromptForm(
          command: command,
          name: dto.name.trim(),
          content: dto.content,
          tags: dto.tags,
          data: existing?.data,
          meta: existing?.meta,
          accessGrants: existing == null
              ? grants
              : _inputs(existing.accessGrants),
          versionId: existing?.versionId,
          commitMessage: commit == null || commit.isEmpty ? null : commit,
          isProduction: dto.production,
        );
        final saved = create
            ? await notifier.create(form)
            : await notifier.updateItem(dto.id, form);
        id = saved.id;
      case WorkspaceKind.tools:
        final dto = _require(detail.tool, detail.kind);
        final notifier = _container.read(workspaceToolsProvider.notifier);
        final toolId = dto.id.trim();
        if (!WorkspaceToolContent.isValidId(toolId) ||
            dto.name.trim().isEmpty) {
          throw _invalid('a tool needs a valid id and a name');
        }
        final required = WorkspaceToolContent.requiredServerVersion(
          dto.content,
        );
        if (!WorkspaceToolContent.meetsRequiredVersion(
          required: required,
          current: _container.read(workspaceServerVersionProvider),
        )) {
          throw RpcError(
            code: ConduitErrorCodes.conflict,
            args: <String, String>{'version': required ?? ''},
            debugMessage: 'the tool needs Open WebUI $required',
          );
        }
        final existing = create
            ? null
            : WorkspaceToolSummary.fromJson(await _api().getTool(toolId));
        final meta = <String, dynamic>{
          ...?existing?.meta,
          'description': dto.description.trim(),
        };
        final form = WorkspaceToolForm(
          id: toolId,
          name: dto.name.trim(),
          content: dto.content,
          meta: meta,
          accessGrants: existing == null
              ? grants
              : _inputs(existing.accessGrants),
        );
        final saved = create
            ? await notifier.create(form)
            : await notifier.updateItem(toolId, form);
        id = saved.id;
      case WorkspaceKind.skills:
        final dto = _require(detail.skill, detail.kind);
        final notifier = _container.read(workspaceSkillsProvider.notifier);
        final skillId = dto.id.trim();
        if (skillId.isEmpty || dto.name.trim().isEmpty) {
          throw _invalid('a skill needs an id and a name');
        }
        final existing = create
            ? null
            : await _api().getWorkspaceSkill(skillId);
        if (!create && existing == null) {
          throw _notFound(detail.kind, skillId);
        }
        final description = dto.description.trim();
        final form = WorkspaceSkillForm(
          id: skillId,
          name: dto.name.trim(),
          description: description.isEmpty ? null : description,
          content: dto.content,
          meta: existing?.meta ?? const <String, dynamic>{},
          isActive: dto.active,
          accessGrants: existing == null
              ? grants
              : _inputs(existing.accessGrants),
        );
        final saved = create
            ? await notifier.create(form)
            : await notifier.updateItem(skillId, form);
        id = saved.id;
    }
    _announce(detail.kind, id);
    return _detail(detail.kind, id);
  });

  Future<void> delete(WorkspaceRef ref) => _guard(() async {
    switch (ref.kind) {
      case WorkspaceKind.models:
        await _container.read(workspaceModelsProvider.notifier).delete(ref.id);
      case WorkspaceKind.knowledge:
        await _container
            .read(workspaceKnowledgeProvider.notifier)
            .delete(ref.id);
      case WorkspaceKind.prompts:
        await _container.read(workspacePromptsProvider.notifier).delete(ref.id);
      case WorkspaceKind.tools:
        await _container.read(workspaceToolsProvider.notifier).delete(ref.id);
      case WorkspaceKind.skills:
        await _container.read(workspaceSkillsProvider.notifier).delete(ref.id);
    }
    _announce(ref.kind, ref.id);
  });

  Future<WorkspaceItem> toggle(WorkspaceRef ref) => _guard(() async {
    final item = switch (ref.kind) {
      WorkspaceKind.models => _modelItem(
        await _container.read(workspaceModelsProvider.notifier).toggle(ref.id),
      ),
      WorkspaceKind.prompts => _promptItem(
        await _container.read(workspacePromptsProvider.notifier).toggle(ref.id),
      ),
      WorkspaceKind.skills => _skillItem(
        await _container.read(workspaceSkillsProvider.notifier).toggle(ref.id),
      ),
      _ => throw _invalid('${ref.kind.name} cannot be switched off'),
    };
    _announce(ref.kind, ref.id);
    return item;
  });

  Future<WorkspaceDetail> setAccess(WorkspaceAccessEdit edit) =>
      _guard(() async {
        final grants = [for (final g in edit.grants) _grantInput(g)];
        switch (edit.kind) {
          case WorkspaceKind.models:
            final model = await _api().getWorkspaceModel(edit.id);
            if (model == null) throw _notFound(edit.kind, edit.id);
            await _container
                .read(workspaceModelsProvider.notifier)
                .updateAccess(edit.id, model.name, grants);
          case WorkspaceKind.knowledge:
            await _container
                .read(workspaceKnowledgeProvider.notifier)
                .updateAccess(edit.id, grants);
          case WorkspaceKind.prompts:
            await _container
                .read(workspacePromptsProvider.notifier)
                .updateAccess(edit.id, grants);
          case WorkspaceKind.tools:
            await _container
                .read(workspaceToolsProvider.notifier)
                .updateAccess(edit.id, grants);
          case WorkspaceKind.skills:
            await _container
                .read(workspaceSkillsProvider.notifier)
                .updateAccess(edit.id, grants);
        }
        _announce(edit.kind, edit.id);
        return _detail(edit.kind, edit.id);
      });

  Future<WorkspacePrincipals> principals(WorkspacePrincipalQuery query) =>
      _guard(() async {
        final api = _api();
        final text = query.query.trim().toLowerCase();
        // Groups are few and listed whole; users are searched. A user who
        // may not search users still sees the groups.
        final groups = await api.getWorkspaceGroups();
        final users = query.ids.isNotEmpty || text.isEmpty
            ? const <WorkspacePrincipalPreview>[]
            : await api
                  .searchWorkspaceUsers(text)
                  .then((page) => page.items)
                  .catchError((Object _) => <WorkspacePrincipalPreview>[]);
        bool wanted(WorkspacePrincipalPreview p) => query.ids.isNotEmpty
            ? query.ids.contains(p.id)
            : text.isEmpty || p.name.toLowerCase().contains(text);
        return WorkspacePrincipals(
          items: <WorkspacePrincipal>[
            for (final p in [...groups, ...users])
              if (wanted(p) || users.contains(p))
                WorkspacePrincipal(
                  type: p.type.name,
                  id: p.id,
                  name: p.name,
                  email: p.email,
                ),
          ],
        );
      });

  // ---------------------------------------------------------------------------
  // Import and export
  // ---------------------------------------------------------------------------

  Future<WorkspaceExportFile> export(WorkspaceExportQuery query) =>
      _guard(() async {
        final id = query.id;
        final api = _api();
        String json(Object data) =>
            const JsonEncoder.withIndent('  ').convert(data);
        String name(String base) => '${_fileSafe(base)}.json';
        switch (query.kind) {
          case WorkspaceKind.models:
            final models = id == null
                ? await _container
                      .read(workspaceModelsProvider.notifier)
                      .exportAll()
                : <WorkspaceModelSummary>[
                    await api.getWorkspaceModel(id) ??
                        (throw _notFound(query.kind, id)),
                  ];
            return WorkspaceExportFile(
              filename: name(id ?? 'models'),
              text: json(models.map(workspaceModelExportMap).toList()),
            );
          case WorkspaceKind.knowledge:
            if (id == null) throw _invalid('knowledge exports one at a time');
            final detail = await api.getWorkspaceKnowledgeDetail(id);
            final bytes = await _container
                .read(workspaceKnowledgeProvider.notifier)
                .export(id);
            return WorkspaceExportFile(
              filename: '${_fileSafe(detail?.summary.name ?? id)}.zip',
              mimeType: 'application/zip',
              base64: base64Encode(bytes),
            );
          case WorkspaceKind.prompts:
            final prompts = id == null
                ? await _container
                      .read(workspacePromptsProvider.notifier)
                      .loadAllForExport()
                : <WorkspacePromptSummary>[
                    await api.getWorkspacePrompt(id) ??
                        (throw _notFound(query.kind, id)),
                  ];
            return WorkspaceExportFile(
              filename: name(id == null ? 'prompts' : prompts.first.command),
              text: json(prompts.map(workspacePromptExportMap).toList()),
            );
          case WorkspaceKind.tools:
            final tools = _container.read(workspaceToolsProvider.notifier);
            final data = id == null
                ? await tools.exportAll()
                : <Map<String, dynamic>>[await tools.exportOne(id)];
            return WorkspaceExportFile(
              filename: name(id ?? 'tools'),
              text: json(data),
            );
          case WorkspaceKind.skills:
            final skills = id == null
                ? await _container
                      .read(workspaceSkillsProvider.notifier)
                      .exportAll()
                : <WorkspaceSkillSummary>[
                    await api.getWorkspaceSkill(id) ??
                        (throw _notFound(query.kind, id)),
                  ];
            return WorkspaceExportFile(
              filename: name(id ?? 'skills'),
              text: json(skills.map(workspaceSkillExportMap).toList()),
            );
        }
      });

  /// Imports every item in an exported file, one at a time as mobile does,
  /// so one clash does not stop the rest.
  Future<WorkspaceImportResult> import(WorkspaceImport request) =>
      _guard(() async {
        final Object? decoded;
        try {
          decoded = jsonDecode(request.text);
        } on FormatException {
          throw _invalid('not a JSON file');
        }
        final items = workspaceImportItemsFromJson(decoded);
        if (items.isEmpty) throw _invalid('nothing to import');
        final Future<void> Function(Map<String, dynamic> item) one =
            switch (request.kind) {
              WorkspaceKind.models =>
                (item) => _container
                    .read(workspaceModelsProvider.notifier)
                    .importItems(<Map<String, dynamic>>[item]),
              WorkspaceKind.prompts =>
                (item) => _container
                    .read(workspacePromptsProvider.notifier)
                    .importPrompt(workspacePromptFormFromImport(item)),
              WorkspaceKind.tools =>
                (item) => _container
                    .read(workspaceToolsProvider.notifier)
                    .importTool(workspaceToolFormFromImport(item)),
              WorkspaceKind.skills =>
                (item) => _container
                    .read(workspaceSkillsProvider.notifier)
                    .importSkill(workspaceSkillFormFromImport(item)),
              WorkspaceKind.knowledge => throw _invalid(
                'knowledge is not imported from JSON',
              ),
            };
        var imported = 0;
        final failed = <WorkspaceImportFailure>[];
        for (final (index, item) in items.indexed) {
          try {
            await one(item);
            imported++;
          } catch (error) {
            failed.add(
              WorkspaceImportFailure(
                label:
                    (item['name'] ??
                            item['title'] ??
                            item['id'] ??
                            item['command'])
                        ?.toString() ??
                    '#${index + 1}',
                reason: _reason(error),
              ),
            );
          }
        }
        if (imported > 0) {
          await _refresh(request.kind);
          _announce(request.kind, null);
        }
        return WorkspaceImportResult(imported: imported, failed: failed);
      });

  // ---------------------------------------------------------------------------
  // Models
  // ---------------------------------------------------------------------------

  Future<WorkspaceModelOptions> modelOptions() => _guard(() async {
    List<WorkspaceRelation> settle<T>(
      AsyncValue<T> value,
      List<WorkspaceRelation> Function(T) map,
    ) => value.hasValue ? map(value.requireValue) : const [];
    // Each picker is optional: a section the user may not read leaves its
    // picker empty rather than failing the editor.
    Future<AsyncValue<T>> load<T>(Future<T> future) =>
        AsyncValue.guard(() => future);
    final (base, knowledge, tools, skills, functions) = await (
      load(readSettled(_container, workspaceBaseModelsProvider.future)),
      load(readSettled(_container, workspaceKnowledgeProvider.future)),
      load(readSettled(_container, workspaceToolsProvider.future)),
      load(readSettled(_container, workspaceSkillsProvider.future)),
      load(readSettled(_container, workspaceFunctionsProvider.future)),
    ).wait;
    return WorkspaceModelOptions(
      baseModels: settle(
        base,
        (options) => [
          for (final o in options)
            WorkspaceRelation(id: o.id, name: o.label, subtitle: o.subtitle),
        ],
      ),
      knowledge: settle(
        knowledge,
        (state) => [
          for (final k in state.items)
            WorkspaceRelation(id: k.id, name: k.name, subtitle: k.description),
        ],
      ),
      tools: settle(
        tools,
        (state) => [
          for (final t in state.items)
            WorkspaceRelation(id: t.id, name: t.name),
        ],
      ),
      skills: settle(
        skills,
        (state) => [
          for (final s in state.items)
            WorkspaceRelation(id: s.id, name: s.name),
        ],
      ),
      filters: settle(
        functions,
        (fns) => [
          for (final f in fns)
            if (f.isFilter) WorkspaceRelation(id: f.id, name: f.name),
        ],
      ),
      actions: settle(
        functions,
        (fns) => [
          for (final f in fns)
            if (f.isAction) WorkspaceRelation(id: f.id, name: f.name),
        ],
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Prompts
  // ---------------------------------------------------------------------------

  Future<WorkspacePromptHistory> promptHistory(String promptId) =>
      _guard(() async {
        final prompts = _container.read(workspacePromptsProvider.notifier);
        final (prompt, entries) = await (
          _api().getWorkspacePrompt(promptId),
          prompts.history(promptId),
        ).wait;
        final production = prompt?.versionId;
        return WorkspacePromptHistory(
          promptId: promptId,
          versions: <WorkspacePromptVersion>[
            for (final entry in entries)
              WorkspacePromptVersion(
                id: entry.id,
                parentId: entry.parentId,
                commitMessage: entry.commitMessage,
                authorName: entry.owner?.name,
                createdAtMs: _ms(entry.createdAt) ?? 0,
                name: entry.snapshot['name']?.toString() ?? '',
                command: entry.snapshot['command']?.toString() ?? '',
                content: entry.snapshot['content']?.toString() ?? '',
                production: entry.id == production,
              ),
          ],
        );
      });

  Future<WorkspacePromptDiff> promptDiff(WorkspacePromptDiffQuery query) =>
      _guard(() async {
        final diff = await _container
            .read(workspacePromptsProvider.notifier)
            .historyDiff(
              query.promptId,
              fromId: query.fromId,
              toId: query.toId,
            );
        return WorkspacePromptDiff(
          lines: workspaceStringList(diff['content_diff']),
          nameChanged: diff['name_changed'] == true,
        );
      });

  Future<WorkspaceDetail> promptSetVersion(WorkspacePromptVersionRef ref) =>
      _guard(() async {
        await _container
            .read(workspacePromptsProvider.notifier)
            .setProductionVersion(ref.promptId, ref.versionId);
        _announce(WorkspaceKind.prompts, ref.promptId);
        return _detail(WorkspaceKind.prompts, ref.promptId);
      });

  Future<void> promptDeleteVersion(WorkspacePromptVersionRef ref) =>
      _guard(() async {
        await _container
            .read(workspacePromptsProvider.notifier)
            .deleteHistoryEntry(ref.promptId, ref.versionId);
        _announce(WorkspaceKind.prompts, ref.promptId);
      });

  // ---------------------------------------------------------------------------
  // Tools
  // ---------------------------------------------------------------------------

  Future<WorkspaceValves> valves(WorkspaceValvesQuery query) => _guard(
    () async {
      final tools = _container.read(workspaceToolsProvider.notifier);
      final id = query.toolId;
      final (spec, values) = query.user
          ? await (tools.userToolValvesSpec(id), tools.userToolValves(id)).wait
          : await (tools.toolValvesSpec(id), tools.toolValves(id)).wait;
      return WorkspaceValves(
        toolId: id,
        user: query.user,
        schema: spec?.schema ?? const <String, dynamic>{},
        values: values,
      );
    },
  );

  Future<WorkspaceValves> saveValves(WorkspaceValves valves) =>
      _guard(() async {
        final tools = _container.read(workspaceToolsProvider.notifier);
        if (valves.user) {
          await tools.updateUserToolValves(valves.toolId, valves.values);
        } else {
          await tools.updateToolValves(valves.toolId, valves.values);
        }
        return this.valves(
          WorkspaceValvesQuery(toolId: valves.toolId, user: valves.user),
        );
      });

  /// Loads a tool from GitHub for the editor to fill in. Only `https`
  /// GitHub addresses are passed on: the server fetches the URL itself,
  /// and must not be pointed at a host inside its own network.
  Future<WorkspaceToolDto> toolFromUrl(String url) => _guard(() async {
    final raw = WorkspaceToolContent.githubUrlToRawUrl(url);
    if (!WorkspaceToolContent.isAllowedImportUrl(raw)) {
      throw _invalid('tools load from https GitHub addresses only');
    }
    final tool = normalizeImportedTool(
      await _container.read(workspaceToolsProvider.notifier).loadFromUrl(raw),
    );
    return _toolDto(
      id: tool['id']?.toString() ?? '',
      name: tool['name']?.toString() ?? '',
      meta: workspaceJsonMap(tool['meta']),
      content: tool['content']?.toString() ?? '',
      specs: const [],
    );
  });

  // ---------------------------------------------------------------------------
  // Knowledge files
  // ---------------------------------------------------------------------------

  Future<WorkspaceFiles> files(WorkspaceFilesQuery query) => _guard(() async {
    final provider = workspaceKnowledgeFilesProvider(query.knowledgeId);
    var state = await readSettled(_container, provider.future);
    final notifier = _container.read(provider.notifier);
    if (query.more && state.directoryId == query.directoryId) {
      await notifier.loadMore();
    } else if (state.directoryId != query.directoryId) {
      await notifier.openDirectory(query.directoryId);
    } else {
      await notifier.refresh();
    }
    state = _container.read(provider).requireValue;
    if (state.error case final error?) throw error;
    return _filesOf(query.knowledgeId, state);
  });

  Future<WorkspaceFiles> attachFiles(WorkspaceFilesAttach request) =>
      _knowledgeFiles(request.knowledgeId, request.directoryId, (n) {
        return n.batchAttach(request.fileIds);
      });

  Future<WorkspaceFiles> fileAction(WorkspaceFileAction action) async {
    final provider = workspaceKnowledgeFilesProvider(action.knowledgeId);
    final state = await _guard(() => readSettled(_container, provider.future));
    return _knowledgeFiles(action.knowledgeId, state.directoryId, (n) {
      final id = action.fileId;
      return switch (action.op) {
        WorkspaceFileOp.rename => n.rename(
          id,
          (action.filename ?? '').trim().isEmpty
              ? throw _invalid('a file needs a name')
              : action.filename!.trim(),
        ),
        WorkspaceFileOp.move => n.move(id, action.directoryId),
        WorkspaceFileOp.reindex => n.reindex(id),
        WorkspaceFileOp.remove => n.detach(id, deleteUnderlying: false),
        WorkspaceFileOp.delete => n.detach(id, deleteUnderlying: true),
      };
    });
  }

  Future<WorkspaceFiles> directoryAction(WorkspaceDirectoryAction action) {
    final name = action.name.trim();
    final directoryId = action.directoryId;
    switch (action.op) {
      case WorkspaceDirectoryOp.create:
        if (name.isEmpty) throw _invalid('a folder needs a name');
        // The notifier makes folders in the one it has open.
        return _knowledgeFiles(
          action.knowledgeId,
          action.parentId,
          (n) => n.createDirectory(name),
        );
      case WorkspaceDirectoryOp.rename:
        if (name.isEmpty || directoryId == null) {
          throw _invalid('rename needs a folder and a name');
        }
        return _knowledgeFiles(
          action.knowledgeId,
          action.parentId,
          (n) => n.updateDirectory(directoryId, name),
        );
      case WorkspaceDirectoryOp.delete:
        if (directoryId == null) throw _invalid('delete needs a folder');
        return _knowledgeFiles(
          action.knowledgeId,
          action.parentId,
          (n) => n.deleteDirectory(directoryId),
        );
    }
  }

  Future<WorkspaceDetail> knowledgeReset(String knowledgeId) =>
      _guard(() async {
        await _container
            .read(workspaceKnowledgeProvider.notifier)
            .reset(knowledgeId);
        _container.invalidate(workspaceKnowledgeFilesProvider(knowledgeId));
        _announce(WorkspaceKind.knowledge, knowledgeId);
        return _detail(WorkspaceKind.knowledge, knowledgeId);
      });

  Future<WorkspaceFiles> knowledgeCleanup(String knowledgeId) async {
    final provider = workspaceKnowledgeFilesProvider(knowledgeId);
    final state = await _guard(() => readSettled(_container, provider.future));
    return _knowledgeFiles(
      knowledgeId,
      state.directoryId,
      (n) => n.cleanupFailed(),
    );
  }

  /// Runs [action] on a knowledge base's file browser with [directoryId]
  /// open, then answers with that folder as it is now.
  Future<WorkspaceFiles> _knowledgeFiles(
    String knowledgeId,
    String directoryId,
    Future<void> Function(WorkspaceKnowledgeFiles notifier) action,
  ) => _guard(() async {
    final provider = workspaceKnowledgeFilesProvider(knowledgeId);
    final state = await readSettled(_container, provider.future);
    final notifier = _container.read(provider.notifier);
    if (state.directoryId != directoryId) {
      await notifier.openDirectory(directoryId);
    }
    await action(notifier);
    _announce(WorkspaceKind.knowledge, knowledgeId);
    return _filesOf(knowledgeId, _container.read(provider).requireValue);
  });

  WorkspaceFiles _filesOf(
    String knowledgeId,
    WorkspaceKnowledgeBrowserState state,
  ) {
    WorkspaceDirectory directory(WorkspaceKnowledgeDirectory d) =>
        WorkspaceDirectory(id: d.id, name: d.name, parentId: d.parentId);
    return WorkspaceFiles(
      knowledgeId: knowledgeId,
      directoryId: state.directoryId,
      breadcrumbs: state.breadcrumbs.map(directory).toList(growable: false),
      directories: state.directories.map(directory).toList(growable: false),
      files: <WorkspaceFile>[
        for (final file in state.files)
          WorkspaceFile(
            id: file.id,
            filename: file.filename,
            contentType: file.contentType,
            size: file.size,
            updatedAtMs: _ms(file.updatedAt),
            status: file.status,
          ),
      ],
      pending: <WorkspaceFile>[
        for (final file in state.pending)
          WorkspaceFile(
            id: file.id,
            filename:
                (file.raw['filename'] ??
                        workspaceJsonMap(file.raw['meta'])['name'] ??
                        file.id)
                    .toString(),
            status: file.status ?? 'processing',
            error: file.error,
          ),
      ],
      total: state.total,
      hasMore: state.hasMore,
    );
  }

  // ---------------------------------------------------------------------------
  // Mapping
  // ---------------------------------------------------------------------------

  WorkspaceItem _modelItem(WorkspaceModelSummary model) {
    final draft = WorkspaceModelDraft.fromSummary(model);
    return WorkspaceItem(
      kind: WorkspaceKind.models,
      id: model.id,
      name: model.name,
      subtitle: draft.description.isEmpty ? null : draft.description,
      ownerName: model.owner?.name,
      writeAccess: _writable(model.writeAccess, model.userId),
      active: model.isActive,
      public: model.accessGrants.any((g) => g.isPublic),
      updatedAtMs: _ms(model.updatedAt),
      tags: draft.tags,
    );
  }

  WorkspaceItem _knowledgeItem(WorkspaceKnowledgeSummary knowledge) =>
      WorkspaceItem(
        kind: WorkspaceKind.knowledge,
        id: knowledge.id,
        name: knowledge.name,
        subtitle: knowledge.description.isEmpty ? null : knowledge.description,
        ownerName: knowledge.owner?.name,
        writeAccess: _writable(knowledge.writeAccess, knowledge.userId),
        public: knowledge.accessGrants.any((g) => g.isPublic),
        updatedAtMs: _ms(knowledge.updatedAt),
      );

  WorkspaceItem _promptItem(WorkspacePromptSummary prompt) => WorkspaceItem(
    kind: WorkspaceKind.prompts,
    id: prompt.id,
    name: prompt.name,
    subtitle: '/${prompt.command}',
    ownerName: prompt.owner?.name,
    writeAccess: _writable(prompt.writeAccess, prompt.userId),
    active: prompt.isActive,
    public: prompt.accessGrants.any((g) => g.isPublic),
    updatedAtMs: _ms(prompt.updatedAt),
    tags: prompt.tags,
  );

  WorkspaceItem _toolItem(WorkspaceToolSummary tool) {
    final description = tool.meta['description']?.toString() ?? '';
    return WorkspaceItem(
      kind: WorkspaceKind.tools,
      id: tool.id,
      name: tool.name,
      subtitle: description.isEmpty ? null : description,
      ownerName: tool.owner?.name,
      writeAccess: _writable(tool.writeAccess, tool.userId),
      public: tool.accessGrants.any((g) => g.isPublic),
      updatedAtMs: _ms(tool.updatedAt),
    );
  }

  WorkspaceItem _skillItem(WorkspaceSkillSummary skill) => WorkspaceItem(
    kind: WorkspaceKind.skills,
    id: skill.id,
    name: skill.name,
    subtitle: (skill.description ?? '').isEmpty ? null : skill.description,
    ownerName: skill.owner?.name,
    writeAccess: _writable(skill.writeAccess, skill.userId),
    active: skill.isActive,
    public: skill.accessGrants.any((g) => g.isPublic),
    updatedAtMs: _ms(skill.updatedAt),
  );

  WorkspaceDetail _modelDetail(WorkspaceModelSummary model) {
    final draft = WorkspaceModelDraft.fromSummary(model);
    return WorkspaceDetail(
      kind: WorkspaceKind.models,
      model: WorkspaceModelDto(
        id: draft.id,
        name: draft.name,
        baseModelId: draft.baseModelId,
        description: draft.description,
        imageUrl: draft.profileImageUrl,
        tags: draft.tags,
        system: draft.system,
        stop: draft.stop,
        suggestionPrompts: draft.suggestionPrompts,
        capabilities: draft.capabilities,
        knowledge: <WorkspaceRelation>[
          for (final k in draft.knowledge)
            WorkspaceRelation(id: k.id, name: k.name),
        ],
        toolIds: draft.toolIds,
        skillIds: draft.skillIds,
        filterIds: draft.filterIds,
        defaultFilterIds: draft.defaultFilterIds,
        actionIds: draft.actionIds,
        defaultFeatureIds: draft.defaultFeatureIds,
        ttsVoice: draft.ttsVoice,
        active: draft.isActive,
        hidden: draft.hidden,
        params: draft.advancedParams,
      ),
      grants: _grants(model.accessGrants),
      writeAccess: _writable(model.writeAccess, model.userId),
      ownerName: model.owner?.name,
      updatedAtMs: _ms(model.updatedAt),
    );
  }

  WorkspaceDetail _skillDetail(WorkspaceSkillSummary skill) => WorkspaceDetail(
    kind: WorkspaceKind.skills,
    skill: WorkspaceSkillDto(
      id: skill.id,
      name: skill.name,
      description: skill.description ?? '',
      content: skill.content ?? '',
      active: skill.isActive,
    ),
    grants: _grants(skill.accessGrants),
    writeAccess: _writable(skill.writeAccess, skill.userId),
    ownerName: skill.owner?.name,
    updatedAtMs: _ms(skill.updatedAt),
  );

  WorkspaceToolDto _toolDto({
    required String id,
    required String name,
    required Map<String, dynamic> meta,
    required String content,
    required List<Map<String, dynamic>> specs,
    bool hasValves = false,
    bool hasUserValves = false,
  }) {
    final required = WorkspaceToolContent.requiredServerVersion(content);
    final meets = WorkspaceToolContent.meetsRequiredVersion(
      required: required,
      current: _container.read(workspaceServerVersionProvider),
    );
    return WorkspaceToolDto(
      id: id,
      name: name,
      description: meta['description']?.toString() ?? '',
      content: content,
      functions: <String>[
        for (final spec in specs)
          if (spec['name'] != null) spec['name'].toString(),
      ],
      hasValves: hasValves,
      hasUserValves: hasUserValves,
      requiresServerVersion: meets ? null : required,
    );
  }

  /// Lays the editor's fields over [draft], which carries what the editor
  /// does not show.
  void _applyModel(WorkspaceModelDraft draft, WorkspaceModelDto dto) {
    final known = {for (final k in draft.knowledge) k.id: k};
    draft
      ..id = dto.id.trim()
      ..name = dto.name.trim()
      ..baseModelId = dto.baseModelId
      ..description = dto.description
      ..profileImageUrl = dto.imageUrl ?? draft.profileImageUrl
      ..tags = [...dto.tags]
      ..system = dto.system
      ..stop = [...dto.stop]
      ..suggestionPrompts = [...dto.suggestionPrompts]
      ..capabilities = {...draft.capabilities, ...dto.capabilities}
      ..knowledge = [
        for (final k in dto.knowledge)
          known[k.id] ?? WorkspaceModelKnowledgeRef(id: k.id, name: k.name),
      ]
      ..toolIds = [...dto.toolIds]
      ..skillIds = [...dto.skillIds]
      ..filterIds = [...dto.filterIds]
      ..defaultFilterIds = [...dto.defaultFilterIds]
      ..actionIds = [...dto.actionIds]
      ..defaultFeatureIds = [...dto.defaultFeatureIds]
      ..ttsVoice = dto.ttsVoice
      ..isActive = dto.active
      ..hidden = dto.hidden
      ..advancedParams = {...dto.params};
  }

  static List<WorkspaceGrant> _grants(List<WorkspaceAccessGrant> grants) => [
    for (final g in grants)
      WorkspaceGrant(
        principalType: g.principalType.name,
        principalId: g.principalId,
        write: g.permission == WorkspaceGrantPermission.write,
      ),
  ];

  static List<WorkspaceAccessGrantInput> _inputs(
    List<WorkspaceAccessGrant> grants,
  ) => grants.map(WorkspaceAccessGrantInput.fromGrant).toList(growable: false);

  static WorkspaceAccessGrantInput _grantInput(WorkspaceGrant grant) =>
      WorkspaceAccessGrantInput(
        principalType: grant.principalType == 'group'
            ? WorkspacePrincipalType.group
            : WorkspacePrincipalType.user,
        principalId: grant.principalId,
        permission: grant.write
            ? WorkspaceGrantPermission.write
            : WorkspaceGrantPermission.read,
      );

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  bool get _isAdmin => _container.read(currentUserProvider2)?.role == 'admin';

  /// Open WebUI reports `write_access` only on newer servers; the owner and
  /// an admin may always write.
  bool _writable(bool writeAccess, String ownerId) =>
      writeAccess ||
      _isAdmin ||
      ownerId == _container.read(currentUserProvider2)?.id;

  ApiService _api() =>
      _container.read(apiServiceProvider) ??
      (throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'the workspace lives on the server; sign in first',
      ));

  Future<void> _refresh(WorkspaceKind kind) => switch (kind) {
    WorkspaceKind.models =>
      _container.read(workspaceModelsProvider.notifier).refresh(),
    WorkspaceKind.knowledge =>
      _container.read(workspaceKnowledgeProvider.notifier).refresh(),
    WorkspaceKind.prompts =>
      _container.read(workspacePromptsProvider.notifier).refresh(),
    WorkspaceKind.tools =>
      _container.read(workspaceToolsProvider.notifier).refresh(),
    WorkspaceKind.skills =>
      _container.read(workspaceSkillsProvider.notifier).refresh(),
  };

  void _announce(WorkspaceKind kind, String? id) => _events?.publish(
    ConduitEvents.workspaceChanged,
    payload: WorkspaceChanged(kind: kind, id: id).toJson(),
  );

  /// Runs [body], turning the core's and the server's failures into the
  /// protocol's errors.
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on RpcError {
      rethrow;
    } on WorkspaceSessionChanged {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        retryable: true,
        debugMessage: 'the account changed while the request ran',
      );
    } on WorkspaceModelBaseRequiredException {
      throw _invalid('a model needs a base model');
    } on StateError catch (error) {
      if (error.message.contains('authenticated server session')) {
        throw const RpcError(
          code: ConduitErrorCodes.unauthenticated,
          debugMessage: 'the workspace lives on the server; sign in first',
        );
      }
      rethrow;
    } on DioException catch (error) {
      throw _fromDio(error);
    }
  }

  static RpcError _fromDio(DioException error) {
    final status = error.response?.statusCode;
    final detail = _detailOf(error);
    return switch (status) {
      401 => const RpcError(code: ConduitErrorCodes.sessionExpired),
      403 => RpcError(
        code: ConduitErrorCodes.unauthorized,
        debugMessage: detail,
      ),
      404 => RpcError(code: ConduitErrorCodes.notFound, debugMessage: detail),
      400 || 409 || 422 => RpcError(
        code: ConduitErrorCodes.conflict,
        args: <String, String>{'detail': ?detail},
        debugMessage: detail,
      ),
      _ => RpcError(
        code: status == null
            ? ConduitErrorCodes.connectionFailed
            : ConduitErrorCodes.serverError,
        args: <String, String>{'status': '${status ?? ''}'},
        debugMessage: detail ?? error.message,
        retryable: true,
      ),
    };
  }

  /// Open WebUI's reason for a refusal, when it gave one.
  static String? _detailOf(DioException error) {
    final data = error.response?.data;
    final detail = data is Map ? data['detail'] : null;
    return switch (detail) {
      final String text when text.isNotEmpty => text,
      _ => null,
    };
  }

  static String _reason(Object error) => switch (error) {
    DioException() => _detailOf(error) ?? 'HTTP ${error.response?.statusCode}',
    WorkspaceModelBaseRequiredException() => 'needs a base model',
    _ => error.toString(),
  };

  static T _require<T>(T? value, WorkspaceKind kind) =>
      value ?? (throw _invalid('the ${kind.name} fields are missing'));

  static RpcError _invalid(String message) =>
      RpcError(code: ConduitErrorCodes.invalidParams, debugMessage: message);

  static RpcError _notFound(WorkspaceKind kind, String id) => RpcError(
    code: ConduitErrorCodes.notFound,
    debugMessage: 'no ${kind.name} $id',
  );

  static String _fileSafe(String name) {
    final safe = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), '_');
    return safe.isEmpty ? 'export' : safe;
  }

  /// Milliseconds from Open WebUI's stamps, which are seconds in most
  /// places and nanoseconds in a few.
  static int? _ms(int stamp) => switch (stamp) {
    <= 0 => null,
    final v when v > 100000000000000000 => v ~/ 1000000,
    final v when v > 100000000000000 => v ~/ 1000,
    final v when v > 100000000000 => v,
    final v => v * 1000,
  };
}

/// A section notifier's filters and paging, by name.
typedef _Controls = ({
  Future<void> Function(String) setQuery,
  Future<void> Function(String) setView,
  Future<void> Function(String)? setSource,
  Future<void> Function() refresh,
  Future<void> Function() loadMore,
});
