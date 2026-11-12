import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit_core/features/direct_connections/providers/apple_pcc_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/web_search/web_search.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../direct_connections/controllers/direct_connection_editor_form.dart';
import '../../direct_connections/controllers/direct_connection_editor_messages.dart';
import '../../direct_connections/controllers/direct_connection_editor_workflow.dart';
import '../../direct_connections/controllers/direct_mcp_server_editor.dart';
import '../../direct_connections/controllers/riverpod_direct_connection_editor_gateway.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'direct_connection_page_ids.dart';
import 'direct_connection_settings_page_builders.dart';

typedef _Row = ({String field, String key, String? extra});

/// Splits a row id of [prefix] into its field, its page's key of
/// [keyParts] parts, and what follows.
_Row? _parseRowId(String id, String prefix, {required int keyParts}) {
  final separator = id.indexOf(':');
  if (!id.startsWith(prefix) || separator < 0) return null;
  final rest = id.substring(separator + 1).split(':');
  if (rest.length < keyParts) return null;
  return (
    field: id.substring(prefix.length, separator),
    key: rest.take(keyParts).join(':'),
    extra: rest.length > keyParts
        ? Uri.decodeComponent(rest.skip(keyParts).join(':'))
        : null,
  );
}

/// One provider editor while it is open: the workflow that loads, checks
/// and saves it, what it held when it was read in, and the header being
/// added.
final class _ConnectionEditor {
  _ConnectionEditor(this.workflow);

  final DirectConnectionEditorWorkflow workflow;
  DirectEditorOperation running = DirectEditorOperation.idle;
  String? notice;

  /// The fields as they were when the provider was read in.
  String? baseline;

  /// Whether the editor page was last drawn edited.
  bool shownEdited = false;

  /// How the provider had loaded when the page was last drawn: a change
  /// redraws it.
  Object? shownLoad;

  String headerName = '';
  String headerValue = '';
  String? headerNotice;

  DirectConnectionEditorForm get form => workflow.form;

  bool get edited => baseline != null && _signature(form) != baseline;

  void dispose() => workflow.dispose();
}

/// Every field of [form], to tell whether any changed.
String _signature(DirectConnectionEditorForm form) => [
  form.enabled,
  form.providerPreset,
  form.authentication.name,
  form.openAiApiMode.name,
  form.name.text,
  form.baseUrl.text,
  form.apiKey.text,
  form.apiVersion.text,
  form.modelIdPrefix.text,
  form.tags.text,
  form.models.text,
  for (final header in form.customHeaders.entries)
    '${header.key}\u0001${header.value}',
].join('\u0000');

/// How an editor's provider loaded, as far as its page cares: whether it
/// is read in, whose it is, and whether the form holds it yet.
Object _loadKind(DirectConnectionEditorWorkflow workflow) =>
    switch (workflow.resourceState) {
      DirectEditorLoadLoading() => 'loading',
      DirectEditorLoadFailure() => 'failed',
      DirectEditorLoadData(:final resource) => (
        resource.availability,
        workflow.resourceOwnerMatches(resource),
        workflow.state.hydrated,
      ),
    };

/// One MCP server editor while it is open.
final class _McpEditor {
  _McpEditor(this.editor);

  final DirectMcpServerEditor editor;
  ProviderSubscription<AsyncValue<List<DirectMcpServer>>>? subscription;
  bool saving = false;
  bool testing = false;

  /// The header being added, and what is wrong with it.
  String headerName = '';
  String headerValue = '';
  String? headerNotice;

  /// The fields as they were when the server was read in.
  String? baseline;

  /// What the page last showed of the stored server.
  Object? shown;

  /// What the page last showed of the editor's own state: a sign-in under
  /// way, its message, the server gone.
  Object? shownStatus;

  bool get edited => baseline != null && _mcpSignature(editor) != baseline;

  void dispose() {
    subscription?.close();
    editor.dispose();
  }
}

String _mcpSignature(DirectMcpServerEditor editor) => [
  editor.name.text,
  editor.endpoint.text,
  editor.enabled,
  editor.authMode.name,
  editor.token.text,
  editor.headers.text,
].join('\u0000');

/// What an MCP page shows of its stored server, to tell whether a reload
/// changed it.
Object? _mcpShown(DirectMcpServer? server) => server == null
    ? null
    : (
        server.oauthTokens?.authorizationServerIssuer,
        server.oauthTokens?.grantedScope,
        server.oauthTokens != null,
        [for (final approval in server.rememberedApprovals) approval.digest]
            .join(','),
      );

/// Direct Connections as pages of Settings's own: the providers and MCP
/// servers with how Direct behaves, an editor for each provider with an
/// Advanced page, and one for each MCP server.
///
/// Onboarding sets providers up in pages of its own, which share these
/// editors' workflows.
class DirectConnectionSettingsPages extends SettingsPageModule {
  DirectConnectionSettingsPages(this._ref);

  final Ref _ref;
  final Map<String, _ConnectionEditor> _editors = {};
  final Map<String, _McpEditor> _mcpEditors = {};

  /// Pages that follow the app's state while they are open.
  final Set<String> _following = {};
  final List<ProviderSubscription<Object?>> _subscriptions = [];
  AppLifecycleListener? _lifecycle;
  AppLocalizations? _l10n;
  bool _redrawQueued = false;
  final Map<String, String> _notices = {};

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);

  DirectSettingsView get _view => DirectSettingsView.read(_ref.read);

  @override
  bool ownsPage(String detailId) =>
      detailId == directConnectionsPageId ||
      detailId == directContextLimitsPageId ||
      detailId.startsWith(directApplePagePrefix) ||
      detailId.startsWith(directConnectionPagePrefix) ||
      detailId.startsWith(directConnectionAdvancedPagePrefix) ||
      detailId.startsWith(directConnectionHeaderPagePrefix) ||
      detailId.startsWith(directMcpPagePrefix) ||
      detailId.startsWith(directMcpHeaderPagePrefix);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    if (detailId == directConnectionsPageId) {
      _follow(detailId);
      // What the server keeps may have changed since it was last read.
      unawaited(_reloadOpenWebUi());
      await _applyDirect(l10n, registerChildren: true);
    } else if (detailId == directContextLimitsPageId) {
      _follow(detailId);
      await _surface.applyDetail(buildDirectContextLimitsPage(l10n, _view));
    } else if (detailId.startsWith(directApplePagePrefix)) {
      _follow(detailId);
      await _applyApple(l10n, detailId.substring(directApplePagePrefix.length));
    } else if (detailId.startsWith(directConnectionPagePrefix)) {
      final key = detailId.substring(directConnectionPagePrefix.length);
      final editor = _editor(key, l10n);
      if (editor == null) return;
      await _applyEditor(l10n, key, editor, registerChildren: true);
    } else if (detailId.startsWith(directConnectionAdvancedPagePrefix)) {
      final key = detailId.substring(directConnectionAdvancedPagePrefix.length);
      final editor = _editor(key, l10n);
      if (editor == null) return;
      await _applyAdvanced(l10n, key, editor, registerChildren: true);
    } else if (detailId.startsWith(directConnectionHeaderPagePrefix)) {
      final key = detailId.substring(directConnectionHeaderPagePrefix.length);
      final editor = _editor(key, l10n);
      if (editor == null) return;
      editor
        ..headerName = ''
        ..headerValue = ''
        ..headerNotice = null;
      await _applyHeader(l10n, key, editor);
    } else if (detailId.startsWith(directMcpPagePrefix)) {
      final key = detailId.substring(directMcpPagePrefix.length);
      await _applyMcp(l10n, key, _mcpEditor(key), registerChildren: true);
    } else if (detailId.startsWith(directMcpHeaderPagePrefix)) {
      final key = detailId.substring(directMcpHeaderPagePrefix.length);
      final entry = _mcpEditor(key)
        ..headerName = ''
        ..headerValue = ''
        ..headerNotice = null;
      await _applyMcpHeader(l10n, key, entry);
    }
  }

  @override
  void pageLeft(String detailId) {
    if (_following.remove(detailId) && _following.isEmpty) _stopFollowing();
    if (detailId.startsWith(directConnectionPagePrefix)) {
      _editors
          .remove(detailId.substring(directConnectionPagePrefix.length))
          ?.dispose();
    } else if (detailId.startsWith(directMcpPagePrefix)) {
      _mcpEditors
          .remove(detailId.substring(directMcpPagePrefix.length))
          ?.dispose();
    }
  }

  @override
  void settingsClosed() {
    _following.clear();
    _stopFollowing();
    for (final editor in _editors.values) {
      editor.dispose();
    }
    _editors.clear();
    for (final editor in _mcpEditors.values) {
      editor.dispose();
    }
    _mcpEditors.clear();
    _notices.clear();
  }

  // -- Following the app while the Direct pages are open ------------------

  void _follow(String detailId) {
    _following.add(detailId);
    if (_subscriptions.isNotEmpty) return;
    void redraw(Object? _, Object? _) => _queueRedraw();
    final apple = _ref.read(applePccPlatformSupportedProvider);
    for (final provider in <ProviderListenable<Object?>>[
      directConnectionProfilesProvider,
      directMcpServersProvider,
      openWebUiDirectConnectionsAvailableProvider,
      openWebUiDirectConnectionsProvider,
      directHistoryPolicyProvider,
      if (apple) ...[
        appleOnDeviceEnabledProvider,
        applePccEnabledProvider,
        appleOnDeviceStatusProvider,
        applePccStatusProvider,
        applePccOnDeviceFallbackProvider,
      ],
      directModelDiscoveryProvider,
      directContextLengthOverridesProvider,
      directMaxImagesPerRequestProvider,
      appSettingsProvider,
      webSearchRegionProvider,
    ]) {
      _subscriptions.add(_ref.listen(provider, redraw));
    }
    // Back from the browser, say, after changing what the server keeps.
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_reloadOpenWebUi()),
    );
  }

  void _stopFollowing() {
    for (final subscription in _subscriptions) {
      subscription.close();
    }
    _subscriptions.clear();
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  /// Redraws the pages followed, once for changes that land together.
  void _queueRedraw() {
    if (_redrawQueued) return;
    _redrawQueued = true;
    scheduleMicrotask(() {
      _redrawQueued = false;
      final l10n = _l10n;
      if (l10n != null) unawaited(_redraw(l10n));
    });
  }

  Future<void> _redraw(AppLocalizations l10n) async {
    try {
      for (final detailId in [..._following]) {
        if (detailId == directConnectionsPageId) {
          await _applyDirect(l10n);
        } else if (detailId == directContextLimitsPageId) {
          await _surface.applyDetail(buildDirectContextLimitsPage(l10n, _view));
        } else if (detailId.startsWith(directApplePagePrefix)) {
          await _applyApple(
            l10n,
            detailId.substring(directApplePagePrefix.length),
          );
        }
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'direct-settings-redraw-failed',
        scope: 'settings/direct',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _reloadOpenWebUi() async {
    if (!_ref.read(openWebUiDirectConnectionsAvailableProvider)) return;
    try {
      await _ref.read(openWebUiDirectConnectionsProvider.notifier).reload();
    } catch (_) {
      // The page shows the failure, with Retry.
    }
  }

  /// Draws the Direct page. The pages it leads to are registered as it
  /// appears, and afterwards only those new to it: one open now keeps what
  /// it shows.
  Future<void> _applyDirect(
    AppLocalizations l10n, {
    bool registerChildren = false,
  }) {
    final view = _view;
    final known = _ref.read(settingsPagesProvider);
    return _surface.applyDetail(
      buildDirectConnectionsPage(
        l10n,
        view,
        notice: _notices.remove(directConnectionsPageId),
      ),
      detailSheets: [
        for (final page in directConnectionsChildPages(l10n, view))
          if (registerChildren || !known.contains(page.id)) page,
      ],
    );
  }

  Future<void> _applyApple(AppLocalizations l10n, String model) {
    final view = _view;
    return _surface.applyDetail(
      buildDirectApplePage(
        l10n,
        model: model,
        status: view.appleStatus(model),
        fallback: view.applePccFallback,
        notice: _notices.remove(directApplePageId(model)),
      ),
    );
  }

  // -- Provider editors ----------------------------------------------------

  /// The editor [key] names, opened now when it is not open yet; null for
  /// a key that names none.
  _ConnectionEditor? _editor(String key, AppLocalizations l10n) {
    final open = _editors[key];
    if (open != null) return open;
    final target = parseDirectConnectionEditorKey(key);
    if (target == null) return null;
    final profileId = target.profileId;
    final mode = profileId == null
        ? DirectConnectionEditorMode.create(source: target.source)
        : DirectConnectionEditorMode.edit(
            profileId: profileId,
            source: target.source,
          );
    final workflow = DirectConnectionEditorWorkflow(
      gateway: riverpodDirectConnectionEditorGateway(_ref.container, mode),
      defaultConnectionName: l10n.directDefaultConnectionName,
    );
    final editor = _editors[key] = _ConnectionEditor(workflow);
    editor.shownLoad = _loadKind(workflow);
    _settleBaseline(editor);
    // The provider read in, or gone, or another account's now: the page
    // says so.
    workflow.addListener(() {
      if (!identical(_editors[key], editor)) return;
      _settleBaseline(editor);
      final load = _loadKind(workflow);
      if (load == editor.shownLoad) return;
      editor.shownLoad = load;
      final current = _l10n;
      if (current != null) unawaited(_applyEditor(current, key, editor));
    });
    return editor;
  }

  void _settleBaseline(_ConnectionEditor editor) {
    if (editor.baseline == null && editor.workflow.state.hydrated) {
      editor.baseline = _signature(editor.form);
    }
  }

  Future<void> _applyEditor(
    AppLocalizations l10n,
    String key,
    _ConnectionEditor editor, {
    bool registerChildren = false,
  }) {
    final known = _ref.read(settingsPagesProvider);
    editor.shownEdited = editor.edited;
    return _surface.applyDetail(
      buildDirectConnectionEditorPage(
        l10n,
        editorKey: key,
        workflow: editor.workflow,
        running: editor.running,
        edited: editor.edited,
        notice: editor.notice,
      ),
      detailSheets: [
        for (final page in [
          buildDirectConnectionAdvancedPage(
            l10n,
            editorKey: key,
            form: editor.form,
          ),
          buildDirectConnectionHeaderPage(l10n, editorKey: key),
        ])
          if (registerChildren || !known.contains(page.id)) page,
      ],
    );
  }

  /// A change made on the Advanced page or one it opened is the editor's:
  /// the editor page, under them, is drawn again once it turns edited (or
  /// back), so leaving it -- or swiping Settings away -- asks first.
  Future<void> _showEdited(
    AppLocalizations l10n,
    String key,
    _ConnectionEditor editor,
  ) async {
    if (editor.edited == editor.shownEdited) return;
    await _applyEditor(l10n, key, editor);
  }

  Future<void> _applyAdvanced(
    AppLocalizations l10n,
    String key,
    _ConnectionEditor editor, {
    bool registerChildren = false,
  }) {
    final header = buildDirectConnectionHeaderPage(l10n, editorKey: key);
    return _surface.applyDetail(
      buildDirectConnectionAdvancedPage(
        l10n,
        editorKey: key,
        form: editor.form,
      ),
      detailSheets: [
        if (registerChildren ||
            !_ref.read(settingsPagesProvider).contains(header.id))
          header,
      ],
    );
  }

  Future<void> _applyHeader(
    AppLocalizations l10n,
    String key,
    _ConnectionEditor editor,
  ) => _surface.applyDetail(
    buildDirectConnectionHeaderPage(
      l10n,
      editorKey: key,
      name: editor.headerName,
      value: editor.headerValue,
      notice: editor.headerNotice,
    ),
  );

  // -- MCP editors ---------------------------------------------------------

  _McpEditor _mcpEditor(String key) {
    final open = _mcpEditors[key];
    if (open != null) return open;
    final entry = _mcpEditors[key] = _McpEditor(
      DirectMcpServerEditor(_ref.container, serverId: Uri.decodeComponent(key)),
    );
    void take(List<DirectMcpServer> servers) {
      entry.editor.observe(servers);
      entry.baseline ??= _mcpSignature(entry.editor);
    }

    entry.subscription = _ref.listen<AsyncValue<List<DirectMcpServer>>>(
      directMcpServersProvider,
      (_, next) {
        if (!identical(_mcpEditors[key], entry)) return;
        final first = !entry.editor.initialized;
        if (next.value case final servers?) take(servers);
        // A reload that changed only what the page does not show leaves
        // the page, and what is being typed into it, alone.
        final shown = _mcpShown(entry.editor.previous);
        if (!first && !next.hasError && shown == entry.shown) return;
        entry.shown = shown;
        final l10n = _l10n;
        if (l10n != null) unawaited(_applyMcp(l10n, key, entry));
      },
    );
    if (_ref.read(directMcpServersProvider).value case final servers?) {
      take(servers);
      entry.shown = _mcpShown(entry.editor.previous);
    }
    // A sign-in starting or ending, or what an action said, changes the page
    // although the stored server may not: its Cancel row, its message.
    entry.editor.addListener(() {
      if (!identical(_mcpEditors[key], entry)) return;
      if (_mcpStatus(entry.editor) == entry.shownStatus) return;
      final l10n = _l10n;
      if (l10n != null) unawaited(_applyMcp(l10n, key, entry));
    });
    return entry;
  }

  static Object _mcpStatus(DirectMcpServerEditor editor) =>
      (editor.oauthPending, editor.message, editor.missing);

  Future<void> _applyMcp(
    AppLocalizations l10n,
    String key,
    _McpEditor entry, {
    bool registerChildren = false,
  }) {
    final header = buildDirectMcpHeaderPage(l10n, serverKey: key);
    entry.shownStatus = _mcpStatus(entry.editor);
    return _surface.applyDetail(
      buildDirectMcpServerPage(
        l10n,
        serverKey: key,
        editor: entry.editor,
        loadFailed: _ref.read(directMcpServersProvider).hasError,
        edited: entry.edited,
        saving: entry.saving,
        testing: entry.testing,
      ),
      detailSheets: [
        if (registerChildren ||
            !_ref.read(settingsPagesProvider).contains(header.id))
          header,
      ],
    );
  }

  Future<void> _applyMcpHeader(
    AppLocalizations l10n,
    String key,
    _McpEditor entry,
  ) => _surface.applyDetail(
    buildDirectMcpHeaderPage(
      l10n,
      serverKey: key,
      name: entry.headerName,
      value: entry.headerValue,
      notice: entry.headerNotice,
    ),
  );

  /// Adds the header typed on the Add Header page and goes back to the
  /// server, now edited; or says there what is wrong with it.
  Future<void> _addMcpHeader(
    AppLocalizations l10n,
    String key,
    _McpEditor entry,
  ) async {
    final problem = entry.editor.addHeader(entry.headerName, entry.headerValue);
    if (problem != null) {
      entry.headerNotice = directHeaderValidationMessage(l10n, problem);
      await _applyMcpHeader(l10n, key, entry);
      return;
    }
    entry
      ..headerName = ''
      ..headerValue = ''
      ..headerNotice = null;
    await _surface.closeDetail('$directMcpHeaderPagePrefix$key');
    await _applyMcp(l10n, key, entry);
  }

  // -- Rows ----------------------------------------------------------------

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    _l10n = l10n;
    if (id.startsWith('direct.')) {
      await _handleDirectRow(id, value, l10n);
      return true;
    }
    if (id.startsWith('direct-connection.')) {
      final row = _parseRowId(id, 'direct-connection.', keyParts: 2);
      if (row != null) await _handleEditorRow(row, value, l10n);
      return true;
    }
    if (id.startsWith('direct-mcp.')) {
      final row = _parseRowId(id, 'direct-mcp.', keyParts: 1);
      if (row != null) await _handleMcpRow(row, value, l10n);
      return true;
    }
    return false;
  }

  Future<void> _handleDirectRow(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    final separator = id.indexOf(':');
    final field = id.substring(
      'direct.'.length,
      separator < 0 ? id.length : separator,
    );
    final extra = separator < 0
        ? null
        : Uri.decodeComponent(id.substring(separator + 1));
    switch (field) {
      case 'history-sync' when value is bool:
        await _ref
            .read(directHistoryPolicyProvider.notifier)
            .setPolicy(
              value
                  ? DirectHistoryPolicy.syncWithOpenWebUI
                  : DirectHistoryPolicy.localOnly,
            );
      case 'images' when value is String:
        final count = int.tryParse(value);
        if (count == null) return;
        try {
          await _ref
              .read(directMaxImagesPerRequestProvider.notifier)
              .set(count);
        } catch (_) {
          // The row goes back to the stored value; the page says why.
          _notices[directConnectionsPageId] =
              l10n.directImagesPerRequestSaveFailed;
          await _applyDirect(l10n);
        }
      case 'context' when extra != null && value is String:
        final tokens = int.tryParse(value);
        if (tokens == null) return;
        await _ref
            .read(directContextLengthOverridesProvider.notifier)
            .set(extra, tokens);
      case 'web-engine' when value is String:
        await _ref
            .read(appSettingsProvider.notifier)
            .setWebSearchEngine(WebSearchEngineChoice.parse(value));
      case 'web-safe-search' when value is String:
        await _ref
            .read(appSettingsProvider.notifier)
            .setWebSearchSafeSearch(parseSafeSearch(value));
      case 'web-region' when value is String:
        await _ref.read(appSettingsProvider.notifier).setWebSearchRegion(value);
      case 'retry-profiles':
        await _ref.read(directConnectionProfilesProvider.notifier).reload();
      case 'retry-openwebui':
        await _reloadOpenWebUi();
      case 'retry-mcp':
        await _ref.read(directMcpServersProvider.notifier).reload();
      case 'apple-refresh' when extra != null:
        _ref.invalidate(
          extra == directAppleOnDevice
              ? appleOnDeviceStatusProvider
              : applePccStatusProvider,
        );
      case 'apple-fallback' when value is bool:
        await _ref
            .read(applePccOnDeviceFallbackProvider.notifier)
            .setEnabled(value);
      case 'apple-quota':
        final shown = await _ref
            .read(applePccAdapterProvider)
            .showQuotaIncreaseSuggestion();
        _ref.invalidate(applePccStatusProvider);
        if (!shown) {
          _notices[directApplePageId(directApplePcc)] =
              l10n.applePccUnavailable;
          await _applyApple(l10n, directApplePcc);
        }
    }
  }

  Future<void> _handleEditorRow(
    _Row row,
    Object? value,
    AppLocalizations l10n,
  ) async {
    final key = row.key;
    // A row of an editor already closed (a second Done on its way) does
    // nothing; nor does one that arrives while it saves or tests.
    final editor = _editors[key];
    if (editor == null) return;
    if (row.field == 'retry') {
      await editor.workflow.reload();
      return;
    }
    if (editor.running != DirectEditorOperation.idle) return;
    final form = editor.form;
    editor.notice = null;
    switch (row.field) {
      case 'enabled' when value is bool:
        form.setEnabled(value);
      case 'provider' when value is String:
        form.selectProviderPreset(
          value,
          ollamaDefaultName: l10n.ollamaCloudDefaultName,
          openRouterDefaultName: l10n.openRouterProviderName,
        );
        // Its address, name and sign-in follow the kind of provider.
        await _applyEditor(l10n, key, editor);
      case 'name' when value is String:
        form.name.text = value;
      case 'url' when value is String:
        form.baseUrl.text = value;
      case 'auth' when value is String:
        final mode = DirectAuthenticationMode.values.asNameMap()[value];
        if (mode == null) return;
        form.setAuthentication(mode);
        await _applyEditor(l10n, key, editor);
      case 'api-key' when value is String:
        form.apiKey.text = value;
      case 'api-mode' when value is String:
        final mode = DirectOpenAiApiMode.values.asNameMap()[value];
        if (mode == null) return;
        form.setOpenAiApiMode(mode);
        await _applyAdvanced(l10n, key, editor);
      case 'api-version' when value is String:
        form.apiVersion.text = value;
      case 'prefix' when value is String:
        form.modelIdPrefix.text = value;
      case 'tags' when value is String:
        form.tags.text = value;
      case 'models' when value is String:
        form.models.text = value;
      case 'header-remove' when row.extra != null:
        form.removeCustomHeader(row.extra!);
        await _applyAdvanced(l10n, key, editor);
      case 'header-name' when value is String:
        editor.headerName = value;
      case 'header-value' when value is String:
        editor.headerValue = value;
      case 'header-add':
        await _addHeader(l10n, key, editor);
      case 'test':
        await _test(l10n, key, editor);
      case 'save':
        await _save(l10n, key, editor);
      case 'delete':
        await _delete(l10n, key, editor);
    }
    // Changed on the Advanced page or one it opened.
    if (const {
          'api-mode',
          'api-version',
          'prefix',
          'tags',
          'models',
          'header-remove',
          'header-add',
        }.contains(row.field) &&
        identical(_editors[key], editor)) {
      await _showEdited(l10n, key, editor);
    }
  }

  /// Adds the header typed on the Add Header page, or says there what is
  /// wrong with it.
  Future<void> _addHeader(
    AppLocalizations l10n,
    String key,
    _ConnectionEditor editor,
  ) async {
    final form = editor.form;
    if (editor.headerName.trim().isEmpty) {
      editor.headerNotice = l10n.directConnectionHeaderNameRequired;
      await _applyHeader(l10n, key, editor);
      return;
    }
    form.headerName.text = editor.headerName;
    form.headerValue.text = editor.headerValue;
    if (!form.addCustomHeader()) {
      final problem = directHeaderValidationMessage(l10n, form.headerError);
      // Nothing stays typed into the form: a save would add it.
      form.headerName.clear();
      form.headerValue.clear();
      editor.headerNotice = problem ?? l10n.errorMessage;
      await _applyHeader(l10n, key, editor);
      return;
    }
    editor
      ..headerName = ''
      ..headerValue = ''
      ..headerNotice = null;
    await _surface.closeDetail('$directConnectionHeaderPagePrefix$key');
    await _applyAdvanced(l10n, key, editor);
  }

  Future<bool> _confirmCredentialTransfer(AppLocalizations l10n) async =>
      await _surface.ask(
        title: l10n.directConnectionCredentialTransferTitle,
        message: l10n.directConnectionCredentialTransferMessage,
        actions: [
          NativeSheetAlertAction(
            'cancel',
            l10n.cancel,
            style: NativeSheetAlertStyle.cancel,
          ),
          NativeSheetAlertAction(
            'send',
            l10n.directConnectionCredentialTransferConfirm,
          ),
        ],
      ) ==
      'send';

  Future<void> _test(
    AppLocalizations l10n,
    String key,
    _ConnectionEditor editor,
  ) async {
    editor.running = DirectEditorOperation.testing;
    await _applyEditor(l10n, key, editor);
    try {
      await editor.workflow.testConnection(
        messages: directEditorMessages(l10n),
        confirmCredentialTransfer: (_) => _confirmCredentialTransfer(l10n),
      );
    } finally {
      editor.running = DirectEditorOperation.idle;
    }
    if (identical(_editors[key], editor)) {
      await _applyEditor(l10n, key, editor);
    }
  }

  /// Saves the provider and goes back; a refusal stays on the editor with
  /// why.
  Future<void> _save(
    AppLocalizations l10n,
    String key,
    _ConnectionEditor editor,
  ) async {
    editor.running = DirectEditorOperation.saving;
    await _applyEditor(l10n, key, editor);
    final DirectEditorActionResult result;
    try {
      result = await editor.workflow.save(
        messages: directEditorMessages(l10n),
        confirmCredentialTransfer: (_) => _confirmCredentialTransfer(l10n),
      );
    } finally {
      editor.running = DirectEditorOperation.idle;
    }
    // Left meanwhile, the editor is nobody's now.
    if (!identical(_editors[key], editor)) return;
    if (result.succeeded) {
      _editors.remove(key)?.dispose();
      await _close(key);
      return;
    }
    await _applyEditor(l10n, key, editor);
  }

  /// Deletes the provider once the user agrees, and goes back.
  Future<void> _delete(
    AppLocalizations l10n,
    String key,
    _ConnectionEditor editor,
  ) async {
    final DirectEditorActionResult result;
    try {
      result = await editor.workflow.delete(
        messages: directEditorMessages(l10n),
        confirmDelete: (saved) async {
          final answer = await _surface.ask(
            title: l10n.directConnectionDeleteTitle,
            message: editor.workflow.policy.showsManagedSource
                ? l10n.openWebUiDirectConnectionDeleteMessage(saved.name)
                : l10n.directConnectionDeleteMessage(saved.name),
            actions: [
              NativeSheetAlertAction(
                'cancel',
                l10n.cancel,
                style: NativeSheetAlertStyle.cancel,
              ),
              NativeSheetAlertAction(
                'delete',
                l10n.delete,
                style: NativeSheetAlertStyle.destructive,
              ),
            ],
          );
          if (answer != 'delete' || !identical(_editors[key], editor)) {
            return false;
          }
          editor.running = DirectEditorOperation.deleting;
          await _applyEditor(l10n, key, editor);
          return true;
        },
      );
    } finally {
      editor.running = DirectEditorOperation.idle;
    }
    if (!identical(_editors[key], editor)) return;
    if (result.succeeded) {
      _editors.remove(key)?.dispose();
      await _close(key);
      return;
    }
    if (result.outcome == DirectEditorActionOutcome.failed) {
      DebugLogger.error(
        'Direct profile deletion failed',
        scope: 'settings/direct',
        data: {'errorType': result.error.runtimeType.toString()},
      );
      editor.notice = l10n.directConnectionDeleteFailed;
    }
    await _applyEditor(l10n, key, editor);
  }

  /// Goes back from the editor [key]: for the one Add Account opened, to
  /// Accounts, past the page that offered it; else to the page it came
  /// from.
  Future<void> _close(String key) =>
      parseDirectConnectionEditorKey(key)?.fromAddAccount == true
      ? _surface.closeDetail(nativeAccountsAddItemId)
      : _surface.closeDetail('$directConnectionPagePrefix$key');

  // -- MCP rows ------------------------------------------------------------

  Future<bool> _confirmMcp(
    AppLocalizations l10n,
    DirectMcpEditorQuestion question,
  ) async {
    final (title, message, label) = switch (question) {
      DirectMcpEditorQuestion.credentialTransfer => (
        l10n.directMcpCredentialTransferTitle,
        l10n.directMcpCredentialTransferMessage,
        l10n.directMcpCredentialTransferConfirm,
      ),
      DirectMcpEditorQuestion.insecureCredentials => (
        l10n.directMcpInsecureCredentialsTitle,
        l10n.directMcpInsecureCredentialsMessage,
        l10n.directMcpInsecureCredentialsConfirm,
      ),
    };
    return await _surface.ask(
          title: title,
          message: message,
          actions: [
            NativeSheetAlertAction(
              'cancel',
              l10n.cancel,
              style: NativeSheetAlertStyle.cancel,
            ),
            NativeSheetAlertAction('go-ahead', label),
          ],
        ) ==
        'go-ahead';
  }

  Future<void> _handleMcpRow(
    _Row row,
    Object? value,
    AppLocalizations l10n,
  ) async {
    final key = row.key;
    final entry = _mcpEditors[key];
    if (entry == null || entry.saving) return;
    final editor = entry.editor;
    if (row.field == 'oauth-cancel') {
      await editor.cancelOAuth();
      await _applyMcp(l10n, key, entry);
      return;
    }
    if (editor.busy) return;
    Future<bool> confirm(DirectMcpEditorQuestion question) =>
        _confirmMcp(l10n, question);
    switch (row.field) {
      case 'name' when value is String:
        editor.name.text = value;
      case 'endpoint' when value is String:
        editor.endpoint.text = value;
      case 'token' when value is String:
        editor.token.text = value;
      case 'header-name' when value is String:
        entry.headerName = value;
      case 'header-value' when value is String:
        entry.headerValue = value;
      case 'header-add':
        await _addMcpHeader(l10n, key, entry);
      case 'header-remove' when row.extra != null:
        editor.removeHeader(row.extra!);
        // Drawn again, the server's page shows it edited.
        await _applyMcp(l10n, key, entry);
      case 'enabled' when value is bool:
        editor.setEnabled(value);
      case 'auth' when value is String:
        final mode = DirectMcpAuthMode.values.asNameMap()[value];
        if (mode == null) return;
        editor.setAuthMode(mode);
        await _applyMcp(l10n, key, entry);
      case 'oauth-connect':
        // The sign-in waits on the browser for as long as it takes; Cancel
        // must still get through.
        unawaited(_connectOAuth(l10n, key, entry, confirm));
      case 'oauth-disconnect':
        await editor.disconnectOAuth(l10n);
        await _applyMcp(l10n, key, entry);
      case 'approval-revoke' when row.extra != null:
        await editor.revokeApproval(l10n, row.extra);
        await _applyMcp(l10n, key, entry);
      case 'approvals-revoke-all':
        await editor.revokeApproval(l10n, null);
        await _applyMcp(l10n, key, entry);
      case 'test':
        entry.testing = true;
        await _applyMcp(l10n, key, entry);
        try {
          await editor.test(l10n, confirm: confirm);
        } finally {
          entry.testing = false;
        }
        if (identical(_mcpEditors[key], entry)) {
          await _applyMcp(l10n, key, entry);
        }
      case 'save':
        entry.saving = true;
        await _applyMcp(l10n, key, entry);
        final bool saved;
        try {
          saved = await editor.save(l10n, confirm: confirm);
        } finally {
          entry.saving = false;
        }
        if (!identical(_mcpEditors[key], entry)) return;
        if (saved) {
          _mcpEditors.remove(key)?.dispose();
          await _surface.closeDetail('$directMcpPagePrefix$key');
          return;
        }
        await _applyMcp(l10n, key, entry);
      case 'delete':
        final deleted = await editor.delete(
          l10n,
          confirmDelete: (server) async =>
              await _surface.ask(
                title: l10n.directMcpDeleteTitle,
                message: l10n.directMcpDeleteMessage(server.name),
                actions: [
                  NativeSheetAlertAction(
                    'cancel',
                    l10n.cancel,
                    style: NativeSheetAlertStyle.cancel,
                  ),
                  NativeSheetAlertAction(
                    'delete',
                    l10n.delete,
                    style: NativeSheetAlertStyle.destructive,
                  ),
                ],
              ) ==
              'delete',
        );
        if (!identical(_mcpEditors[key], entry)) return;
        if (deleted) {
          _mcpEditors.remove(key)?.dispose();
          await _surface.closeDetail('$directMcpPagePrefix$key');
          return;
        }
        await _applyMcp(l10n, key, entry);
    }
  }

  Future<void> _connectOAuth(
    AppLocalizations l10n,
    String key,
    _McpEditor entry,
    DirectMcpEditorConfirm confirm,
  ) async {
    final connecting = entry.editor.connectOAuth(l10n, confirm: confirm);
    await _applyMcp(l10n, key, entry);
    await connecting;
    if (identical(_mcpEditors[key], entry)) {
      await _applyMcp(l10n, key, entry);
    }
  }
}
