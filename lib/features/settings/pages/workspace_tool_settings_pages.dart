import 'dart:ui' show PlatformDispatcher, Offset, Rect;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/models/workspace_tool_content.dart';
import 'package:conduit_core/features/workspace/models/workspace_transfer.dart'
    show normalizeImportedTool;
import 'package:conduit_core/features/workspace/models/workspace_valve_values.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart';
import 'package:conduit_core/navigation/routes.dart' show WorkspaceSection;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../workspace/widgets/workspace_access_grants.dart'
    show workspaceAccessSummary;
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'workspace_access_settings_pages.dart';
import 'workspace_page_ids.dart';
import 'workspace_settings_pages.dart'
    show workspaceExportControllerProvider, workspaceSectionCapabilities;

/// The Python a new tool starts from, as Open WebUI's own does.
const String workspaceToolBoilerplate = '''"""
title: My Tool
description: Tools for performing various operations
required_open_webui_version: 0.10.2
version: 0.0.1
"""

import os
from pydantic import BaseModel, Field


class Tools:
    def __init__(self):
        pass

    # Add your custom tools using pure Python code here. Make sure to add type
    # hints and descriptions so the model knows how to call them.

    def get_current_time(self) -> str:
        """
        Get the current time in a human-readable format.
        """
        from datetime import datetime

        return datetime.now().strftime("%A, %B %d, %Y %I:%M:%S %p")
''';

/// One tool's editor while its page is open.
final class WorkspaceToolEditor {
  WorkspaceToolEditor(this.key, this.session);

  final String key;
  final WorkspaceSessionIdentity? session;

  WorkspaceToolSummary? summary;
  bool loaded = false;
  bool loadFailed = false;

  String name = '';
  String id = '';
  String description = '';
  String content = '';
  Map<String, dynamic> meta = {};
  List<WorkspaceAccessGrantInput> grants = [];

  /// The id was typed, so the name no longer writes it.
  bool idTyped = false;
  bool idError = false;

  bool dirty = false;
  bool busy = false;
  String? notice;
  bool noticeIsError = true;
  bool shownEdited = false;

  // The valves page.
  bool valvesUser = false;
  bool valvesLoading = false;
  bool valvesFailed = false;
  bool valvesLoaded = false;
  bool valvesBusy = false;
  bool valvesDirty = false;
  String? valvesNotice;
  WorkspaceValveSpec? serverSpec;
  WorkspaceValveSpec? userSpec;
  Map<String, dynamic> serverValues = {};
  Map<String, dynamic> userValues = {};

  // The page loading a new tool from a URL.
  String url = '';
  bool urlBusy = false;
  String? urlNotice;

  bool get isCreate => key == workspaceNewKey;
  bool get writeAccess => isCreate || (summary?.writeAccess ?? false);
  bool get readOnly => !writeAccess;
  bool get ready => isCreate || loaded;

  void adopt(WorkspaceToolSummary next) {
    summary = next;
    loaded = true;
    loadFailed = false;
    name = next.name;
    id = next.id;
    meta = Map<String, dynamic>.from(next.meta);
    description = meta['description']?.toString() ?? '';
    content = next.content ?? '';
    grants = [
      for (final grant in next.accessGrants)
        WorkspaceAccessGrantInput.fromGrant(grant),
    ];
    idTyped = true;
    idError = false;
    dirty = false;
  }

  /// Fills empty fields from the source's front matter, as a new tool's
  /// source says what it is.
  void prefillFrom(String source) {
    final front = WorkspaceToolContent.parseFrontmatter(source);
    final title = front['title']?.trim() ?? '';
    final about = front['description']?.trim() ?? '';
    if (title.isNotEmpty && name.trim().isEmpty) {
      name = WorkspaceToolContent.formatToolName(title);
      if (!idTyped) id = WorkspaceToolContent.nameToId(title);
    }
    if (about.isNotEmpty && description.trim().isEmpty) description = about;
  }
}

String _toolRow(String field, String key, [String? extra]) =>
    workspaceRowId('tool-$field', key, extra);

/// The required version a tool's source declares, when the server is
/// older, as `(required, current)`; null when it may run.
({String required, String current})? workspaceToolIncompatibility(
  String content,
  String? serverVersion,
) {
  final required = WorkspaceToolContent.requiredServerVersion(content);
  if (WorkspaceToolContent.meetsRequiredVersion(
    required: required,
    current: serverVersion,
  )) {
    return null;
  }
  return (required: required ?? '0.0.0', current: serverVersion ?? '?');
}

/// A tool's editor page: its name, id and description, its Python source
/// (a page of its own), what the server made of it, who may use it, and
/// the actions on it. A tool the account may only view reads without
/// fields.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceToolPage(
  AppLocalizations l10n, {
  required WorkspaceToolEditor editor,
  String? serverVersion,
  bool isAdmin = false,
  bool canExport = false,
}) {
  final key = editor.key;
  final pageId = '$workspaceToolPagePrefix$key';
  final title = editor.isCreate
      ? l10n.workspaceToolCreateTitle
      : (editor.name.trim().isEmpty ? l10n.workspaceTools : editor.name.trim());
  if (!editor.ready) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: title,
      items: [
        if (editor.loadFailed)
          NativeSheetItemConfig(
            id: _toolRow('retry', key),
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
  final readOnly = editor.readOnly;
  final summary = editor.summary;
  final canWrite = !readOnly && summary != null;
  final incompatible = workspaceToolIncompatibility(
    editor.content,
    serverVersion,
  );
  NativeSheetItemConfig field(
    String field,
    String title,
    String value, {
    required String symbol,
    String? placeholder,
    bool locked = false,
  }) => NativeSheetItemConfig(
    id: _toolRow(field, key),
    title: title,
    sfSymbol: symbol,
    kind: readOnly || locked
        ? NativeSheetItemKind.readOnlyText
        : NativeSheetItemKind.textField,
    value: value,
    placeholder: placeholder ?? title,
    disabled: editor.busy,
  );
  final manifest = workspaceJsonMap(summary?.meta['manifest']);
  final version = manifest['version']?.toString();
  final requiredVersion = manifest['required_open_webui_version']?.toString();
  final funding = manifest['funding_url']?.toString();
  return NativeSheetDetailConfig(
    id: pageId,
    title: title,
    confirmActionId: readOnly ? null : _toolRow('save', key),
    confirmActionLabel: editor.isCreate ? l10n.workspaceCreate : l10n.save,
    discardPrompt: readOnly ? null : nativeDiscardPrompt(l10n),
    edited: editor.dirty,
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
      if (readOnly)
        NativeSheetSectionConfig(
          items: [
            workspaceNote(
              '$pageId-read-only',
              l10n.workspaceReadOnlyExplanation,
              'lock',
            ),
          ],
        )
      else
        NativeSheetSectionConfig(
          items: [
            workspaceNote(
              '$pageId-warning',
              l10n.workspaceToolWarning,
              'exclamationmark.shield',
            ),
            if (incompatible != null)
              workspaceWarning(
                '$pageId-incompatible',
                l10n.workspaceToolIncompatible(
                  incompatible.required,
                  incompatible.current,
                ),
              ),
          ],
        ),
      NativeSheetSectionConfig(
        footer: editor.isCreate && !readOnly ? l10n.workspaceToolIdHint : null,
        items: [
          field(
            'name',
            l10n.workspaceToolName,
            editor.name,
            symbol: 'wrench.and.screwdriver',
            placeholder: l10n.workspaceToolNameHint,
          ),
          field(
            'id',
            l10n.workspaceToolId,
            editor.id,
            symbol: editor.idError ? 'exclamationmark.triangle' : 'number',
            locked: !editor.isCreate,
          ),
          field(
            'description',
            l10n.workspaceToolDescription,
            editor.description,
            symbol: 'text.alignleft',
            placeholder: l10n.workspaceToolDescriptionHint,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: '$workspaceToolCodePagePrefix$key',
            title: l10n.workspaceToolContent,
            sfSymbol: 'chevron.left.forwardslash.chevron.right',
          ),
          if (editor.isCreate && isAdmin)
            NativeSheetItemConfig(
              id: '$workspaceToolUrlPagePrefix$key',
              title: l10n.workspaceToolImportUrl,
              sfSymbol: 'link',
            ),
        ],
      ),
      if (summary != null && manifest.isNotEmpty)
        NativeSheetSectionConfig(
          title: l10n.workspaceToolManifest,
          items: [
            if (version != null)
              workspaceNote(
                '$pageId-manifest-version',
                l10n.workspaceToolManifestVersion(version),
                'number',
              ),
            if (requiredVersion != null)
              workspaceNote(
                '$pageId-manifest-required',
                l10n.workspaceToolManifestRequiredVersion(requiredVersion),
                'checkmark.seal',
              ),
            if (funding != null)
              workspaceNote(
                '$pageId-manifest-funding',
                l10n.workspaceToolManifestFunding(funding),
                'heart',
              ),
          ],
        ),
      if (summary != null)
        NativeSheetSectionConfig(
          title: l10n.workspaceToolSpecs,
          items: [
            if (summary.specs.isEmpty)
              workspaceNote(
                '$pageId-specs-empty',
                l10n.workspaceToolSpecsEmpty,
                'function',
              )
            else
              for (final (index, spec) in summary.specs.indexed)
                workspaceNote(
                  '$pageId-spec-$index',
                  spec['name']?.toString() ?? '',
                  'function',
                  (spec['description']?.toString() ?? '').isEmpty
                      ? null
                      : spec['description'].toString(),
                ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: workspaceAccessPageId(WorkspaceSection.tools, key),
            title: l10n.workspaceToolManageAccess,
            subtitle: workspaceAccessSummary(l10n, editor.grants),
            sfSymbol: 'person.2',
          ),
          if (canWrite)
            NativeSheetItemConfig(
              id: '$workspaceToolValvesPagePrefix$key',
              title: l10n.workspaceToolValves,
              sfSymbol: 'slider.horizontal.3',
            ),
        ],
      ),
      if (summary != null && (canWrite || canExport))
        NativeSheetSectionConfig(
          items: [
            if (canWrite)
              NativeSheetItemConfig(
                id: _toolRow('clone', key),
                title: l10n.workspaceToolClone,
                sfSymbol: 'plus.square.on.square',
                showsDisclosure: false,
                disabled: editor.busy,
              ),
            if (canWrite && summary.isActive != null)
              NativeSheetItemConfig(
                id: _toolRow('active', key),
                title: summary.isActive!
                    ? l10n.workspaceToolDeactivate
                    : l10n.workspaceToolActivate,
                sfSymbol: summary.isActive! ? 'pause.circle' : 'play.circle',
                showsDisclosure: false,
                disabled: editor.busy,
              ),
            if (canExport)
              NativeSheetItemConfig(
                id: _toolRow('export', key),
                title: l10n.workspaceToolExport,
                sfSymbol: 'square.and.arrow.up',
                showsDisclosure: false,
                disabled: editor.busy,
              ),
            if (canWrite)
              NativeSheetItemConfig(
                id: _toolRow('delete', key),
                title: l10n.workspaceToolDelete,
                sfSymbol: 'trash',
                destructive: true,
                showsDisclosure: false,
                disabled: editor.busy,
                confirmMessage: l10n.workspaceToolDeleteConfirmMessage(
                  summary.name.isEmpty ? summary.id : summary.name,
                ),
              ),
          ],
        ),
    ],
  );
}

/// A tool's Python source, a page of code of its own.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceToolCodePage(
  AppLocalizations l10n, {
  required WorkspaceToolEditor editor,
}) => NativeSheetDetailConfig(
  id: '$workspaceToolCodePagePrefix${editor.key}',
  title: l10n.workspaceToolContent,
  items: [
    NativeSheetItemConfig(
      id: _toolRow('content', editor.key),
      title: l10n.workspaceToolContent,
      kind: NativeSheetItemKind.code,
      value: editor.content,
      placeholder: l10n.workspaceToolContentHint,
      disabled: editor.readOnly || editor.busy,
    ),
  ],
);

/// A tool's valves: the server's, or the account's own, each a value of
/// its own or the default.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceToolValvesPage(
  AppLocalizations l10n, {
  required WorkspaceToolEditor editor,
}) {
  final key = editor.key;
  final pageId = '$workspaceToolValvesPagePrefix$key';
  final spec = editor.valvesUser ? editor.userSpec : editor.serverSpec;
  final values = editor.valvesUser ? editor.userValues : editor.serverValues;
  final scope = NativeSheetItemConfig(
    id: _toolRow('valves-scope', key),
    title: l10n.workspaceToolValvesTitle,
    sfSymbol: 'slider.horizontal.3',
    kind: NativeSheetItemKind.segment,
    value: editor.valvesUser ? 'user' : 'server',
    options: [
      NativeSheetOptionConfig(
        id: 'server',
        label: l10n.workspaceToolValvesServer,
      ),
      NativeSheetOptionConfig(id: 'user', label: l10n.workspaceToolValvesUser),
    ],
    disabled: editor.valvesBusy,
  );
  final sections = <NativeSheetSectionConfig>[
    if (editor.valvesNotice != null)
      NativeSheetSectionConfig(
        items: [workspaceWarning('$pageId-notice', editor.valvesNotice!)],
      ),
    NativeSheetSectionConfig(items: [scope]),
  ];
  if (!editor.valvesLoaded) {
    sections.add(
      NativeSheetSectionConfig(
        items: [
          if (editor.valvesFailed)
            NativeSheetItemConfig(
              id: _toolRow('valves-retry', key),
              title: l10n.workspaceToolValvesLoadFailed,
              subtitle: l10n.workspaceRetry,
              sfSymbol: 'exclamationmark.triangle',
              showsDisclosure: false,
            )
          else
            buildNativeLoadingItem(l10n, id: '$pageId-loading'),
        ],
      ),
    );
  } else if (spec == null || spec.isEmpty) {
    sections.add(
      NativeSheetSectionConfig(
        items: [
          workspaceNote(
            '$pageId-empty',
            l10n.workspaceToolValvesEmpty,
            'slider.horizontal.3',
          ),
        ],
      ),
    );
  } else {
    for (final property in spec.properties.keys) {
      final propertySpec = WorkspaceValveValues.propertySpec(spec, property);
      final required = spec.required.contains(property);
      final value = values[property];
      final custom = value != null;
      final title = propertySpec['title']?.toString() ?? property;
      final description = propertySpec['description']?.toString();
      final type = propertySpec['type']?.toString();
      final enumValues = propertySpec['enum'];
      final extra = property;
      sections.add(
        NativeSheetSectionConfig(
          title: required ? '$title · ${l10n.workspaceValveRequired}' : title,
          footer: description == null || description.isEmpty
              ? null
              : description,
          items: [
            NativeSheetItemConfig(
              id: _toolRow('valve-mode', key, extra),
              title: title,
              sfSymbol: 'slider.horizontal.3',
              kind: NativeSheetItemKind.segment,
              value: custom ? 'custom' : 'default',
              options: [
                NativeSheetOptionConfig(
                  id: 'default',
                  label: required
                      ? l10n.workspaceValveNone
                      : l10n.workspaceValveDefault,
                ),
                NativeSheetOptionConfig(
                  id: 'custom',
                  label: l10n.workspaceValveCustom,
                ),
              ],
              disabled: editor.valvesBusy,
            ),
            if (custom)
              if (enumValues is List && enumValues.isNotEmpty)
                NativeSheetItemConfig(
                  id: _toolRow('valve-value', key, extra),
                  title: l10n.workspaceValveCustom,
                  sfSymbol: 'list.bullet',
                  kind: NativeSheetItemKind.segment,
                  value: value.toString(),
                  options: [
                    for (final option in enumValues)
                      NativeSheetOptionConfig(
                        id: option.toString(),
                        label: option.toString(),
                      ),
                  ],
                  disabled: editor.valvesBusy,
                )
              else if (type == 'boolean')
                NativeSheetItemConfig(
                  id: _toolRow('valve-value', key, extra),
                  title: value == true
                      ? l10n.workspaceValveEnabled
                      : l10n.workspaceValveDisabled,
                  sfSymbol: 'switch.2',
                  kind: NativeSheetItemKind.toggle,
                  value: value == true,
                  disabled: editor.valvesBusy,
                )
              else
                NativeSheetItemConfig(
                  id: _toolRow('valve-value', key, extra),
                  title: l10n.workspaceValveCustom,
                  sfSymbol: 'textformat',
                  kind: WorkspaceValveValues.isPasswordProperty(propertySpec)
                      ? NativeSheetItemKind.secureTextField
                      : NativeSheetItemKind.textField,
                  value: value.toString(),
                  placeholder: title,
                  keyboard: type == 'integer' || type == 'number'
                      ? NativeSheetKeyboard.number
                      : null,
                  disabled: editor.valvesBusy,
                ),
          ],
        ),
      );
    }
  }
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.workspaceToolValvesTitle,
    confirmActionId: editor.valvesLoaded && !editor.readOnly
        ? _toolRow('valves-save', key)
        : null,
    confirmActionLabel: l10n.save,
    discardPrompt: nativeDiscardPrompt(l10n),
    edited: editor.valvesDirty,
    busy: editor.valvesBusy,
    announcement: editor.valvesNotice,
    sections: sections,
  );
}

/// Loads a new tool from a URL into the editor: a GitHub link to its
/// Python file, which the server fetches.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceToolUrlPage(
  AppLocalizations l10n, {
  required WorkspaceToolEditor editor,
}) {
  final key = editor.key;
  final pageId = '$workspaceToolUrlPagePrefix$key';
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.workspaceToolImportUrlTitle,
    confirmActionId: _toolRow('url-load', key),
    confirmActionLabel: l10n.workspaceToolImportUrl,
    discardPrompt: nativeDiscardPrompt(l10n),
    edited: editor.url.trim().isNotEmpty,
    busy: editor.urlBusy,
    announcement: editor.urlNotice,
    sections: [
      if (editor.urlNotice != null)
        NativeSheetSectionConfig(
          items: [workspaceWarning('$pageId-notice', editor.urlNotice!)],
        ),
      NativeSheetSectionConfig(
        footer: l10n.workspaceToolImportUrlHint,
        items: [
          NativeSheetItemConfig(
            id: _toolRow('url', key),
            title: l10n.workspaceToolImportUrlLabel,
            sfSymbol: 'link',
            kind: NativeSheetItemKind.textField,
            value: editor.url,
            placeholder: 'https://github.com/…',
            keyboard: NativeSheetKeyboard.url,
            disabled: editor.urlBusy,
          ),
        ],
      ),
    ],
  );
}

/// A tool's pages in Settings: its editor, its source, its valves, loading
/// a new one from a URL, and who may use it.
class WorkspaceToolSettingsPages extends SettingsPageModule {
  WorkspaceToolSettingsPages(this._ref) {
    _access = WorkspaceAccessPages(
      _ref,
      section: WorkspaceSection.tools,
      onSave: _saveAccess,
      onDone: _accessDone,
    );
  }

  final Ref _ref;
  late final WorkspaceAccessPages _access;
  AppLocalizations? _l10n;
  final Map<String, WorkspaceToolEditor> _editors = {};

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);
  WorkspaceTools get _notifier => _ref.read(workspaceToolsProvider.notifier);

  WorkspaceSectionCapabilities get _capabilities =>
      workspaceSectionCapabilities(
        _ref.read(workspaceCapabilitiesProvider).value,
        WorkspaceSection.tools,
      );

  bool get _isAdmin => _ref.read(currentUserProvider2)?.role == 'admin';

  @override
  bool ownsPage(String detailId) =>
      detailId.startsWith(workspaceToolPagePrefix) ||
      detailId.startsWith(workspaceToolCodePagePrefix) ||
      detailId.startsWith(workspaceToolValvesPagePrefix) ||
      detailId.startsWith(workspaceToolUrlPagePrefix) ||
      _access.ownsPage(detailId);

  WorkspaceSessionIdentity? _session() {
    try {
      return WorkspaceSessionIdentity.read(_ref);
    } on StateError {
      return null;
    }
  }

  bool _current(WorkspaceToolEditor editor) =>
      identical(_editors[editor.key], editor) &&
      (editor.session?.isCurrent(_ref) ?? false);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    if (_access.ownsPage(detailId)) {
      final key = _access.editorKeyOf(detailId);
      final editor = key == null ? null : _editors[key];
      if (editor != null && editor.ready) {
        _access.open(
          editorKey: editor.key,
          grants: editor.grants,
          readOnly: editor.readOnly,
          saveOnDone: !editor.isCreate,
          resourceName: editor.name.trim().isEmpty ? null : editor.name.trim(),
        );
      }
      await _access.hydrate(detailId, l10n);
      return;
    }
    if (detailId.startsWith(workspaceToolCodePagePrefix)) {
      final editor =
          _editors[detailId.substring(workspaceToolCodePagePrefix.length)];
      if (editor != null) {
        await _surface.applyDetail(
          buildWorkspaceToolCodePage(l10n, editor: editor),
        );
      }
      return;
    }
    if (detailId.startsWith(workspaceToolValvesPagePrefix)) {
      final editor =
          _editors[detailId.substring(workspaceToolValvesPagePrefix.length)];
      if (editor == null) return;
      await _applyValves(l10n, editor);
      if (!editor.valvesLoaded) await _loadValves(editor);
      return;
    }
    if (detailId.startsWith(workspaceToolUrlPagePrefix)) {
      final editor =
          _editors[detailId.substring(workspaceToolUrlPagePrefix.length)];
      if (editor != null) await _applyUrl(l10n, editor);
      return;
    }
    final key = detailId.substring(workspaceToolPagePrefix.length);
    final open = _editors[key];
    if (open != null) {
      await _applyEditor(l10n, open);
      return;
    }
    final editor = _editors[key] = WorkspaceToolEditor(key, _session());
    if (editor.isCreate) editor.content = workspaceToolBoilerplate;
    await _applyEditor(l10n, editor);
    if (!editor.isCreate) await _load(editor);
  }

  @override
  void pageLeft(String detailId) {
    if (_access.ownsPage(detailId)) {
      _access.pageLeft(detailId);
      return;
    }
    if (detailId.startsWith(workspaceToolValvesPagePrefix)) {
      // Left, the valves keep nothing changed on them, and are read again.
      final editor =
          _editors[detailId.substring(workspaceToolValvesPagePrefix.length)];
      editor
        ?..valvesLoaded = false
        ..valvesFailed = false
        ..valvesDirty = false
        ..valvesNotice = null
        ..serverValues = {}
        ..userValues = {};
      return;
    }
    if (detailId.startsWith(workspaceToolUrlPagePrefix)) {
      final editor =
          _editors[detailId.substring(workspaceToolUrlPagePrefix.length)];
      editor
        ?..url = ''
        ..urlNotice = null;
      return;
    }
    if (detailId.startsWith(workspaceToolPagePrefix)) {
      final key = detailId.substring(workspaceToolPagePrefix.length);
      _editors.remove(key);
      _access.forget(key);
    }
  }

  @override
  void settingsClosed() {
    _editors.clear();
    _access.clear();
  }

  // -- Loading -----------------------------------------------------------------

  Future<void> _load(WorkspaceToolEditor editor) async {
    final l10n = _l10n;
    final id = workspaceIdOfKey(editor.key);
    if (l10n == null || id == null) return;
    editor.loadFailed = false;
    WorkspaceToolSummary? summary;
    try {
      final provider = workspaceToolDetailProvider(id);
      final listening = _ref.listen(provider, (_, _) {});
      try {
        summary = await _ref.read(provider.future);
      } finally {
        listening.close();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-tool-load-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return;
    if (summary == null) {
      editor.loadFailed = true;
    } else {
      editor.adopt(summary);
    }
    await _applyEditor(l10n, editor);
  }

  Future<void> _loadValves(WorkspaceToolEditor editor) async {
    final l10n = _l10n;
    final id = editor.summary?.id;
    if (l10n == null || id == null || editor.valvesLoading) return;
    editor
      ..valvesLoading = true
      ..valvesFailed = false;
    WorkspaceValveSpec? serverSpec;
    WorkspaceValveSpec? userSpec;
    Map<String, dynamic>? serverValues;
    Map<String, dynamic>? userValues;
    try {
      serverSpec = await _notifier.toolValvesSpec(id);
      serverValues = await _notifier.toolValves(id);
      userSpec = await _notifier.userToolValvesSpec(id);
      userValues = await _notifier.userToolValves(id);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-tool-valves-load-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return;
    editor.valvesLoading = false;
    if (serverValues == null || userValues == null) {
      editor.valvesFailed = true;
    } else {
      editor
        ..serverSpec = serverSpec
        ..userSpec = userSpec
        ..serverValues = WorkspaceValveValues.hydrate(serverSpec, serverValues)
        ..userValues = WorkspaceValveValues.hydrate(userSpec, userValues)
        ..valvesLoaded = true
        ..valvesDirty = false;
    }
    await _applyValves(l10n, editor);
  }

  // -- Drawing -----------------------------------------------------------------

  Future<void> _applyEditor(
    AppLocalizations l10n,
    WorkspaceToolEditor editor, {
    bool withPages = true,
  }) {
    final key = editor.key;
    editor.shownEdited = editor.dirty;
    return _surface.applyDetail(
      buildWorkspaceToolPage(
        l10n,
        editor: editor,
        serverVersion: _ref.read(workspaceServerVersionProvider),
        isAdmin: _isAdmin,
        canExport: _capabilities.exportItems,
      ),
      detailSheets: [
        if (withPages && editor.ready) ...[
          buildWorkspaceToolCodePage(l10n, editor: editor),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: workspaceAccessPageId(WorkspaceSection.tools, key),
            title: l10n.workspaceToolManageAccess,
          ),
          if (editor.summary != null)
            buildNativeLoadingDetail(
              l10n: l10n,
              id: '$workspaceToolValvesPagePrefix$key',
              title: l10n.workspaceToolValvesTitle,
            ),
          if (editor.isCreate)
            buildNativeLoadingDetail(
              l10n: l10n,
              id: '$workspaceToolUrlPagePrefix$key',
              title: l10n.workspaceToolImportUrlTitle,
            ),
        ],
      ],
    );
  }

  /// A change made on a page the editor opened is the editor's: the editor
  /// page, under it, is drawn again once it turns edited.
  Future<void> _showEdited(AppLocalizations l10n, WorkspaceToolEditor editor) {
    if (editor.dirty == editor.shownEdited) return Future.value();
    return _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _applyValves(
    AppLocalizations l10n,
    WorkspaceToolEditor editor,
  ) => _surface.applyDetail(buildWorkspaceToolValvesPage(l10n, editor: editor));

  Future<void> _applyUrl(AppLocalizations l10n, WorkspaceToolEditor editor) =>
      _surface.applyDetail(buildWorkspaceToolUrlPage(l10n, editor: editor));

  // -- Changes -------------------------------------------------------------------

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    _l10n = l10n;
    if (await _access.handleChange(id, value, l10n)) return true;
    final row = parseWorkspaceRowId(id);
    if (row == null || !row.field.startsWith('tool-')) return false;
    final editor = _editors[row.key];
    if (editor == null) return true;
    final field = row.field.substring('tool-'.length);
    if (field == 'retry') {
      await _load(editor);
      return true;
    }
    if (!editor.ready) return true;
    switch (field) {
      case 'name' when value is String && !editor.readOnly && !editor.busy:
        final wasDirty = editor.dirty;
        editor
          ..name = value
          ..dirty = true;
        // A new tool's id follows its name until it is typed.
        if (editor.isCreate && !editor.idTyped) {
          editor.id = WorkspaceToolContent.nameToId(value);
          await _applyEditor(l10n, editor, withPages: false);
        } else if (!wasDirty) {
          await _applyEditor(l10n, editor, withPages: false);
        }
      case 'id' when value is String && editor.isCreate && !editor.busy:
        final wasError = editor.idError;
        final wasDirty = editor.dirty;
        editor
          ..id = value
          ..idTyped = true
          ..idError = false
          ..dirty = true;
        if (wasError || !wasDirty) {
          await _applyEditor(l10n, editor, withPages: false);
        }
      case 'description'
          when value is String && !editor.readOnly && !editor.busy:
        final wasDirty = editor.dirty;
        editor
          ..description = value
          ..dirty = true;
        if (!wasDirty) await _applyEditor(l10n, editor, withPages: false);
      case 'content' when value is String && !editor.readOnly && !editor.busy:
        if (value == editor.content) return true;
        editor
          ..content = value
          ..dirty = true;
        if (editor.isCreate) editor.prefillFrom(value);
        // The editor under the source shows what the source says now.
        await _applyEditor(l10n, editor, withPages: false);
      case 'save':
        await _save(l10n, editor);
      case 'clone':
        await _clone(l10n, editor);
      case 'active':
        await _toggleActive(l10n, editor);
      case 'export':
        await _exportOne(l10n, editor);
      case 'delete':
        await _delete(l10n, editor);
      case 'valves-retry':
        await _loadValves(editor);
      case 'valves-scope' when value is String:
        editor.valvesUser = value == 'user';
        await _applyValves(l10n, editor);
      case 'valve-mode' when value is String && row.extra != null:
        await _setValveMode(
          l10n,
          editor,
          row.extra!,
          custom: value == 'custom',
        );
      case 'valve-value' when row.extra != null:
        await _setValveValue(l10n, editor, row.extra!, value);
      case 'valves-save':
        await _saveValves(l10n, editor);
      case 'url' when value is String && !editor.urlBusy:
        final was = editor.url.trim().isNotEmpty;
        editor.url = value;
        if (was != value.trim().isNotEmpty) await _applyUrl(l10n, editor);
      case 'url-load':
        await _loadFromUrl(l10n, editor);
    }
    return true;
  }

  void _say(WorkspaceToolEditor editor, String message, {bool error = true}) {
    editor
      ..notice = message
      ..noticeIsError = error;
  }

  static bool _isConflict(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      return status == 400 || status == 409;
    }
    return false;
  }

  /// The id to save under, or null after saying on the page why there is
  /// none.
  String? _checked(AppLocalizations l10n, WorkspaceToolEditor editor) {
    final incompatible = workspaceToolIncompatibility(
      editor.content,
      _ref.read(workspaceServerVersionProvider),
    );
    if (incompatible != null) {
      _say(
        editor,
        l10n.workspaceToolIncompatible(
          incompatible.required,
          incompatible.current,
        ),
      );
      return null;
    }
    if (editor.name.trim().isEmpty) {
      _say(editor, l10n.workspaceToolNameRequired);
      return null;
    }
    final id = editor.isCreate ? editor.id.trim() : editor.summary!.id;
    if (editor.isCreate) {
      if (id.isEmpty || !WorkspaceToolContent.isValidId(id)) {
        editor.idError = true;
        _say(
          editor,
          id.isEmpty
              ? l10n.workspaceToolIdRequired
              : l10n.workspaceToolIdInvalid,
        );
        return null;
      }
    }
    if (editor.content.trim().isEmpty) {
      _say(editor, l10n.workspaceToolContentRequired);
      return null;
    }
    return id;
  }

  Future<void> _save(AppLocalizations l10n, WorkspaceToolEditor editor) async {
    if (editor.readOnly || editor.busy) return;
    final id = _checked(l10n, editor);
    if (id == null) {
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    final form = WorkspaceToolForm(
      id: id,
      name: editor.name.trim(),
      content: editor.content,
      meta: {...editor.meta, 'description': editor.description.trim()},
      accessGrants: editor.grants,
    );
    editor
      ..busy = true
      ..idError = false
      ..notice = null;
    await _applyEditor(l10n, editor, withPages: false);
    String? problem;
    try {
      if (editor.isCreate) {
        await _notifier.create(form);
      } else {
        await _notifier.updateItem(editor.summary!.id, form);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-tool-save-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      editor.idError = editor.isCreate && _isConflict(error);
      problem = editor.idError
          ? l10n.workspaceToolIdTaken
          : l10n.workspaceToolSaveFailed;
    }
    if (!_current(editor)) return;
    editor.busy = false;
    if (problem != null) {
      _say(editor, problem);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    editor.dirty = false;
    // Saved, the editor goes back to the list, which shows the tool.
    _editors.remove(editor.key);
    _access.forget(editor.key);
    await _surface.closeDetail('$workspaceToolPagePrefix${editor.key}');
  }

  /// Runs [operation] on a saved tool, the editor staying open.
  Future<bool> _operate(
    AppLocalizations l10n,
    WorkspaceToolEditor editor,
    Future<void> Function() operation, {
    String? failure,
  }) async {
    if (editor.busy) return false;
    editor
      ..busy = true
      ..notice = null;
    await _applyEditor(l10n, editor, withPages: false);
    Object? failed;
    try {
      await operation();
    } catch (error, stackTrace) {
      failed = error;
      DebugLogger.error(
        'workspace-tool-operation-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return false;
    editor.busy = false;
    if (failed != null) {
      _say(editor, failure ?? l10n.workspaceToolSaveFailed);
      await _applyEditor(l10n, editor, withPages: false);
      return false;
    }
    return true;
  }

  Future<void> _clone(AppLocalizations l10n, WorkspaceToolEditor editor) async {
    if (editor.summary == null || editor.readOnly) return;
    final base = editor.id.trim();
    // Clones never take the source tool's sharing grants.
    final form = WorkspaceToolForm(
      id: base.isEmpty ? 'tool_clone' : '${base}_clone',
      name: '${editor.name.trim()} ${l10n.workspaceToolCloneSuffix}',
      content: editor.content,
      meta: {...editor.meta, 'description': editor.description.trim()},
    );
    final ok = await _operate(l10n, editor, () => _notifier.create(form));
    if (!ok) return;
    _say(editor, l10n.workspaceToolSaved, error: false);
    await _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _toggleActive(
    AppLocalizations l10n,
    WorkspaceToolEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || editor.readOnly || summary.isActive == null) return;
    // Switching reads the tool again, which would drop what was changed.
    if (editor.dirty) {
      _say(editor, l10n.workspaceToolToggleSaveFirst);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    WorkspaceToolSummary? toggled;
    final ok = await _operate(
      l10n,
      editor,
      () async => toggled = await _notifier.toggle(summary.id),
    );
    if (!ok) return;
    if (toggled != null) editor.adopt(toggled!);
    _say(editor, l10n.workspaceToolSaved, error: false);
    await _applyEditor(l10n, editor, withPages: false);
  }

  Future<void> _delete(
    AppLocalizations l10n,
    WorkspaceToolEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || editor.readOnly) return;
    final ok = await _operate(l10n, editor, () => _notifier.delete(summary.id));
    if (!ok) return;
    _editors.remove(editor.key);
    _access.forget(editor.key);
    await _surface.closeDetail('$workspaceToolPagePrefix${editor.key}');
  }

  /// Where the share sheet opens from: the middle of the screen, as iPad
  /// asks for an origin.
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
    WorkspaceToolEditor editor,
  ) async {
    final summary = editor.summary;
    if (summary == null || !_capabilities.exportItems) return;
    Map<String, dynamic>? exported;
    final ok = await _operate(
      l10n,
      editor,
      () async => exported = await _notifier.exportOne(summary.id),
      failure: l10n.workspaceToolExportFailed,
    );
    final data = exported;
    if (!ok || data == null) return;
    await _applyEditor(l10n, editor, withPages: false);
    try {
      await _ref
          .read(workspaceExportControllerProvider)
          .shareJson(
            filename: 'tool-${summary.id}',
            data: [data],
            sharePositionOrigin: _shareOrigin(),
          );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-tool-share-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_current(editor)) return;
      _say(editor, l10n.workspaceToolExportFailed);
      await _applyEditor(l10n, editor, withPages: false);
    }
  }

  // -- Valves --------------------------------------------------------------------

  Map<String, dynamic> _valvesOf(WorkspaceToolEditor editor) =>
      editor.valvesUser ? editor.userValues : editor.serverValues;

  WorkspaceValveSpec? _specOf(WorkspaceToolEditor editor) =>
      editor.valvesUser ? editor.userSpec : editor.serverSpec;

  Future<void> _setValveMode(
    AppLocalizations l10n,
    WorkspaceToolEditor editor,
    String property, {
    required bool custom,
  }) async {
    final spec = _specOf(editor);
    if (spec == null || editor.valvesBusy) return;
    final values = _valvesOf(editor);
    if ((values[property] != null) == custom) return;
    values[property] = WorkspaceValveValues.toggleDefault(
      WorkspaceValveValues.propertySpec(spec, property),
      values[property],
    );
    editor.valvesDirty = true;
    await _applyValves(l10n, editor);
  }

  Future<void> _setValveValue(
    AppLocalizations l10n,
    WorkspaceToolEditor editor,
    String property,
    Object? value,
  ) async {
    final spec = _specOf(editor);
    if (spec == null || editor.valvesBusy) return;
    final values = _valvesOf(editor);
    final propertySpec = WorkspaceValveValues.propertySpec(spec, property);
    final enumValues = propertySpec['enum'];
    final redraw = !editor.valvesDirty || value is bool;
    if (enumValues is List && enumValues.isNotEmpty) {
      values[property] = WorkspaceValveValues.enumValueFor(
        enumValues,
        value?.toString(),
      );
    } else if (value is bool) {
      values[property] = value;
    } else if (value is String) {
      values[property] = WorkspaceValveValues.coerceText(
        propertySpec['type']?.toString(),
        value,
        values[property],
      );
    } else {
      return;
    }
    editor.valvesDirty = true;
    if (redraw) await _applyValves(l10n, editor);
  }

  Future<void> _saveValves(
    AppLocalizations l10n,
    WorkspaceToolEditor editor,
  ) async {
    final id = editor.summary?.id;
    if (id == null || !editor.valvesLoaded || editor.valvesBusy) return;
    final user = editor.valvesUser;
    final payload = WorkspaceValveValues.serialize(
      _specOf(editor),
      _valvesOf(editor),
    );
    editor
      ..valvesBusy = true
      ..valvesNotice = null;
    await _applyValves(l10n, editor);
    var saved = false;
    try {
      if (user) {
        await _notifier.updateUserToolValves(id, payload);
      } else {
        await _notifier.updateToolValves(id, payload);
      }
      saved = true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-tool-valves-save-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return;
    editor.valvesBusy = false;
    if (!saved) {
      editor.valvesNotice = l10n.workspaceToolValvesSaveFailed;
      await _applyValves(l10n, editor);
      return;
    }
    editor.valvesDirty = false;
    _say(editor, l10n.workspaceToolValvesSaved, error: false);
    await _applyEditor(l10n, editor, withPages: false);
    await _surface.closeDetail('$workspaceToolValvesPagePrefix${editor.key}');
  }

  // -- From a URL ------------------------------------------------------------------

  Future<void> _loadFromUrl(
    AppLocalizations l10n,
    WorkspaceToolEditor editor,
  ) async {
    if (!editor.isCreate || editor.urlBusy || !_isAdmin) return;
    final raw = editor.url.trim();
    final uri = Uri.tryParse(raw);
    String? problem;
    String? normalized;
    if (raw.isEmpty || uri == null || !uri.hasScheme || !uri.isAbsolute) {
      problem = l10n.workspaceToolImportUrlInvalid;
    } else {
      normalized = WorkspaceToolContent.githubUrlToRawUrl(raw);
      // Only GitHub tool URLs go to the server's fetch.
      if (!WorkspaceToolContent.isAllowedImportUrl(normalized)) {
        problem = l10n.workspaceToolImportUrlHost;
      }
    }
    if (problem != null || normalized == null) {
      editor.urlNotice = problem;
      await _applyUrl(l10n, editor);
      return;
    }
    editor
      ..urlBusy = true
      ..urlNotice = null;
    await _applyUrl(l10n, editor);
    Map<String, dynamic>? loaded;
    try {
      loaded = await _notifier.loadFromUrl(normalized);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-tool-url-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_current(editor)) return;
    editor.urlBusy = false;
    if (loaded == null) {
      editor.urlNotice = l10n.workspaceToolImportUrlFailed;
      await _applyUrl(l10n, editor);
      return;
    }
    final tool = normalizeImportedTool(loaded);
    editor
      ..name = tool['name']?.toString() ?? ''
      ..id = tool['id']?.toString() ?? ''
      ..meta = workspaceJsonMap(tool['meta'])
      ..content = tool['content']?.toString() ?? ''
      ..idTyped = true
      ..idError = false
      ..dirty = true
      ..url = '';
    editor.description = editor.meta['description']?.toString() ?? '';
    _say(editor, l10n.workspaceToolImportUrlLoaded, error: false);
    await _applyEditor(l10n, editor);
    await _surface.closeDetail('$workspaceToolUrlPagePrefix${editor.key}');
  }

  // -- Access ------------------------------------------------------------------------

  Future<String?> _saveAccess(
    WorkspaceAccessDraft draft,
    List<WorkspaceAccessGrantInput> grants,
  ) async {
    final l10n = _l10n;
    final editor = _editors[draft.editorKey];
    final summary = editor?.summary;
    if (l10n == null || editor == null || summary == null) return null;
    try {
      await _notifier.updateAccess(summary.id, grants);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-tool-access-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      return l10n.workspaceToolSaveFailed;
    }
    return null;
  }

  Future<void> _accessDone(
    WorkspaceAccessDraft draft,
    List<WorkspaceAccessGrantInput> grants, {
    required bool saved,
  }) async {
    final l10n = _l10n;
    final editor = _editors[draft.editorKey];
    if (l10n == null || editor == null || !_current(editor)) return;
    editor.grants = grants;
    if (saved) {
      _say(editor, l10n.workspaceToolSaved, error: false);
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    // A new tool keeps the list for its first save.
    editor.dirty = true;
    await _showEdited(l10n, editor);
    await _applyEditor(l10n, editor, withPages: false);
  }
}
