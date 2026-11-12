import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/hermes/models/hermes_mcp.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'hermes_page_ids.dart';

/// Prefix of an MCP server's page; its URI-encoded name follows.
const hermesMcpServerPagePrefix = 'hermes-mcp-server:';

/// The page adding an MCP server by hand.
const hermesMcpAddPageId = 'hermes-mcp-add';

/// The catalog of MCP servers Hermes can install.
const hermesMcpCatalogPageId = 'hermes-mcp-catalog';

/// Prefix of a catalog server's page; its URI-encoded name follows.
const hermesMcpCatalogEntryPagePrefix = 'hermes-mcp-catalog-entry:';

/// Prefix of the page setting a server's API key; its URI-encoded name
/// follows.
const hermesMcpKeyPagePrefix = 'hermes-mcp-key:';

/// Prefix of the rows of the MCP pages.
const hermesMcpRowPrefix = 'hermes-mcp.';

String hermesMcpServerPageId(String name) =>
    '$hermesMcpServerPagePrefix${Uri.encodeComponent(name)}';

/// A row of the MCP pages: `hermes-mcp.<field>:<argument>`.
String hermesMcpRowId(String field, [String argument = '', String? extra]) =>
    '$hermesMcpRowPrefix$field:${Uri.encodeComponent(argument)}'
    '${extra == null ? '' : ':${Uri.encodeComponent(extra)}'}';

/// What the MCP pages show.
@immutable
@visibleForTesting
final class HermesMcpState {
  const HermesMcpState({
    required this.servers,
    this.failed = false,
    this.testResults = const {},
    this.testing = const {},
    this.authenticating = const {},
    this.busy = const {},
    this.supportsCredentialUpdate = false,
    this.notice,
  });

  /// Null while they are read.
  final List<HermesMcpServer>? servers;
  final bool failed;
  final Map<String, HermesMcpTestResult> testResults;
  final Set<String> testing;
  final Set<String> authenticating;
  final Set<String> busy;
  final bool supportsCredentialUpdate;
  final String? notice;

  HermesMcpServer? server(String name) =>
      servers?.where((server) => server.name == name).firstOrNull;
}

String _serverSummary(
  AppLocalizations l10n,
  HermesMcpServer server,
  HermesMcpTestResult? result,
) {
  final tools = result?.toolNames ?? server.tools;
  final filter = server.toolFilter?.summary;
  return [
    server.enabled ? l10n.enabledLabel : l10n.disabledLabel,
    if (server.auth?.isNotEmpty == true) server.auth!,
    if (server.description.isNotEmpty) server.description,
    if (tools.isNotEmpty) l10n.hermesMcpToolsList(tools.join(', ')),
    if (filter != null) l10n.hermesMcpToolFilterSummary(filter),
    if (result != null)
      l10n.hermesMcpResourcesPrompts(result.resources, result.prompts),
  ].join('\n');
}

String _testOutcome(AppLocalizations l10n, HermesMcpTestResult result) =>
    result.ok
    ? l10n.hermesMcpTestConnected(
        result.tools,
        result.resources,
        result.prompts,
      )
    : result.error ?? l10n.hermesMcpTestFailed;

/// The Desktop Gateway's MCP servers: rows adding one by hand or from the
/// catalog, then each server, opening its page; its menu tests or removes
/// it.
@visibleForTesting
NativeSheetDetailConfig buildHermesMcpPage(
  AppLocalizations l10n,
  HermesMcpState state,
) {
  const pageId = hermesMcpPageId;
  NativeSheetItemConfig note(String id, String title, String symbol) =>
      NativeSheetItemConfig(
        id: '$pageId-$id',
        title: title,
        sfSymbol: symbol,
        kind: NativeSheetItemKind.info,
      );
  final servers = state.servers;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.hermesMcpServers,
    announcement: state.notice,
    sections: [
      if (state.notice != null)
        NativeSheetSectionConfig(
          items: [note('notice', state.notice!, 'info.circle')],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: hermesMcpAddPageId,
            title: l10n.hermesMcpAddServer,
            sfSymbol: 'plus.circle',
            accent: true,
          ),
          NativeSheetItemConfig(
            id: hermesMcpCatalogPageId,
            title: l10n.hermesMcpAddFromCatalog,
            sfSymbol: 'sparkles',
            accent: true,
          ),
        ],
      ),
      if (state.failed)
        NativeSheetSectionConfig(
          items: [
            note(
              'failed',
              l10n.hermesMcpLoadFailed,
              'exclamationmark.triangle',
            ),
          ],
        )
      else if (servers == null)
        NativeSheetSectionConfig(
          items: [buildNativeLoadingItem(l10n, id: '$pageId-loading')],
        )
      else if (servers.isEmpty)
        NativeSheetSectionConfig(
          items: [
            note(
              'empty',
              l10n.hermesMcpNone,
              'point.3.connected.trianglepath.dotted',
            ),
          ],
        )
      else
        NativeSheetSectionConfig(
          items: [
            for (final server in servers)
              NativeSheetItemConfig(
                id: hermesMcpServerPageId(server.name),
                title: server.name,
                subtitle: _serverSummary(
                  l10n,
                  server,
                  state.testResults[server.name],
                ),
                sfSymbol: 'point.3.connected.trianglepath.dotted',
                pending:
                    state.testing.contains(server.name) ||
                        state.authenticating.contains(server.name) ||
                        state.busy.contains(server.name)
                    ? true
                    : null,
                rowActions: [
                  NativeSheetRowAction(
                    id: hermesMcpRowId('test', server.name),
                    label: l10n.hermesMcpTest,
                    sfSymbol: 'bolt.horizontal',
                  ),
                  NativeSheetRowAction(
                    id: hermesMcpRowId('remove', server.name),
                    label: l10n.hermesMcpRemove,
                    sfSymbol: 'trash',
                    destructive: true,
                    confirmMessage: l10n.hermesMcpRemoveMessage,
                  ),
                ],
              ),
          ],
        ),
    ],
  );
}

/// An MCP server's page: whether its tools are on, what it offers, Test,
/// Authenticate, its API key, and Remove.
@visibleForTesting
NativeSheetDetailConfig buildHermesMcpServerPage(
  AppLocalizations l10n,
  HermesMcpState state,
  String name,
) {
  final pageId = hermesMcpServerPageId(name);
  final server = state.server(name);
  NativeSheetItemConfig fact(
    String id,
    String title,
    String? value, [
    String symbol = 'info.circle',
  ]) => NativeSheetItemConfig(
    id: '$pageId-$id',
    title: title,
    subtitle: value,
    sfSymbol: symbol,
    kind: NativeSheetItemKind.info,
  );
  if (server == null) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: name,
      items: [
        if (state.servers == null && !state.failed)
          buildNativeLoadingItem(l10n, id: '$pageId-loading')
        else
          fact(
            'gone',
            l10n.hermesMcpLoadFailed,
            null,
            'exclamationmark.triangle',
          ),
      ],
    );
  }
  final result = state.testResults[name];
  final busy = state.busy.contains(name);
  final testing = state.testing.contains(name);
  final authenticating = state.authenticating.contains(name);
  final tools = result?.toolNames ?? server.tools;
  final filter = server.toolFilter?.summary;
  return NativeSheetDetailConfig(
    id: pageId,
    title: name,
    announcement: state.notice,
    sections: [
      if (state.notice != null)
        NativeSheetSectionConfig(items: [fact('notice', state.notice!, null)]),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: hermesMcpRowId('enabled', name),
            title: l10n.tools,
            subtitle: server.enabled ? l10n.enabledLabel : l10n.disabledLabel,
            sfSymbol: 'wrench.and.screwdriver',
            kind: NativeSheetItemKind.toggle,
            value: server.enabled,
            disabled: busy,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          if (server.description.isNotEmpty)
            fact('description', server.description, null, 'text.alignleft'),
          if (server.auth?.isNotEmpty == true)
            fact(
              'auth',
              l10n.directAuthentication,
              server.auth,
              'person.badge.key',
            ),
          if (tools.isNotEmpty)
            fact(
              'tools',
              l10n.tools,
              tools.join(', '),
              'wrench.and.screwdriver',
            ),
          if (filter != null)
            fact(
              'filter',
              l10n.hermesMcpToolFilter,
              filter,
              'line.3.horizontal.decrease',
            ),
          if (result != null)
            fact(
              'test',
              _testOutcome(l10n, result),
              null,
              result.ok ? 'checkmark.circle' : 'exclamationmark.triangle',
            ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: hermesMcpRowId('test', name),
            title: l10n.hermesMcpTest,
            sfSymbol: 'bolt.horizontal',
            accent: true,
            showsDisclosure: false,
            pending: testing ? true : null,
            disabled: testing || busy,
          ),
          NativeSheetItemConfig(
            id: hermesMcpRowId('oauth', name),
            title: l10n.hermesMcpAuthenticate,
            sfSymbol: 'person.badge.key',
            accent: true,
            showsDisclosure: false,
            pending: authenticating ? true : null,
            disabled: authenticating || busy,
          ),
          if (state.supportsCredentialUpdate)
            NativeSheetItemConfig(
              id: '$hermesMcpKeyPagePrefix${Uri.encodeComponent(name)}',
              title: l10n.hermesMcpSetApiKey,
              sfSymbol: 'key',
              disabled: busy,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: hermesMcpRowId('remove', name),
            title: l10n.hermesMcpRemove,
            sfSymbol: 'trash',
            destructive: true,
            showsDisclosure: false,
            disabled: busy,
            confirmMessage: l10n.hermesMcpRemoveMessage,
          ),
        ],
      ),
    ],
  );
}

/// The form adding an MCP server by hand: its name, an HTTP URL or a stdio
/// command with its arguments, and an optional API key.
@visibleForTesting
NativeSheetDetailConfig buildHermesMcpAddPage(
  AppLocalizations l10n, {
  String name = '',
  String url = '',
  String command = '',
  String arguments = '',
  String? notice,
  bool busy = false,
}) {
  const pageId = hermesMcpAddPageId;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.hermesMcpAddServer,
    confirmActionId: hermesMcpRowId('add'),
    confirmActionLabel: l10n.hermesMcpAdd,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: busy,
    announcement: notice,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$pageId-notice',
              title: notice,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: hermesMcpRowId('add-name'),
            title: l10n.name,
            sfSymbol: 'textformat',
            kind: NativeSheetItemKind.textField,
            value: name,
          ),
          NativeSheetItemConfig(
            id: hermesMcpRowId('add-url'),
            title: l10n.hermesMcpHttpUrl,
            sfSymbol: 'link',
            kind: NativeSheetItemKind.textField,
            value: url,
            keyboard: NativeSheetKeyboard.url,
          ),
          NativeSheetItemConfig(
            id: hermesMcpRowId('add-command'),
            title: l10n.hermesMcpStdioCommand,
            sfSymbol: 'terminal',
            kind: NativeSheetItemKind.textField,
            value: command,
          ),
          NativeSheetItemConfig(
            id: hermesMcpRowId('add-arguments'),
            title: l10n.hermesMcpArguments,
            sfSymbol: 'list.bullet',
            kind: NativeSheetItemKind.multilineTextField,
            value: arguments,
          ),
          NativeSheetItemConfig(
            id: hermesMcpRowId('add-key'),
            title: l10n.hermesMcpApiKeyOptional,
            sfSymbol: 'key',
            kind: NativeSheetItemKind.secureTextField,
          ),
        ],
      ),
    ],
  );
}

String _catalogSubtitle(AppLocalizations l10n, HermesMcpCatalogEntry entry) {
  // An optional value is named as optional; only the required ones are
  // what this connection cannot send.
  final asks = entry.credentials
      .map((it) => it.required ? it.name : l10n.hermesMcpValueOptional(it.name))
      .join(', ');
  final required = entry.credentials.where((it) => it.required);
  final needs = (required.isEmpty ? entry.credentials : required)
      .map((it) => it.name)
      .join(', ');
  return [
    if (entry.description.isNotEmpty) entry.description,
    if (entry.credentials.isNotEmpty)
      entry.canAdd
          ? l10n.hermesMcpCatalogAsks(asks)
          : l10n.hermesMcpCatalogNeeds(needs),
  ].join('\n');
}

/// The catalog of servers Hermes can install, each opening its page; one
/// that needs what this connection cannot send is shown, dimmed.
@visibleForTesting
NativeSheetDetailConfig buildHermesMcpCatalogPage(
  AppLocalizations l10n, {
  required List<HermesMcpCatalogEntry>? entries,
  bool failed = false,
}) {
  const pageId = hermesMcpCatalogPageId;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.hermesMcpAddFromCatalog,
    sections: [
      if (failed)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$pageId-failed',
              title: l10n.hermesMcpActionFailed,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        )
      else if (entries == null)
        NativeSheetSectionConfig(
          items: [buildNativeLoadingItem(l10n, id: '$pageId-loading')],
        )
      else
        NativeSheetSectionConfig(
          items: [
            for (final entry in entries)
              NativeSheetItemConfig(
                id:
                    '$hermesMcpCatalogEntryPagePrefix'
                    '${Uri.encodeComponent(entry.name)}',
                title: entry.name,
                subtitle: _catalogSubtitle(l10n, entry),
                sfSymbol: 'shippingbox',
                disabled: !entry.canAdd,
              ),
          ],
        ),
    ],
  );
}

/// A catalog server's page: what it is, a field for each value it needs
/// (hidden as typed), and Add.
@visibleForTesting
NativeSheetDetailConfig buildHermesMcpCatalogEntryPage(
  AppLocalizations l10n,
  HermesMcpCatalogEntry entry, {
  String? notice,
  bool busy = false,
}) {
  final pageId =
      '$hermesMcpCatalogEntryPagePrefix${Uri.encodeComponent(entry.name)}';
  return NativeSheetDetailConfig(
    id: pageId,
    title: entry.name,
    confirmActionId: hermesMcpRowId('catalog-add', entry.name),
    confirmActionLabel: l10n.hermesMcpAdd,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: busy,
    announcement: notice,
    sections: [
      NativeSheetSectionConfig(
        items: [
          if (notice != null)
            NativeSheetItemConfig(
              id: '$pageId-notice',
              title: notice,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          if (entry.description.isNotEmpty)
            NativeSheetItemConfig(
              id: '$pageId-description',
              title: entry.description,
              sfSymbol: 'text.alignleft',
              kind: NativeSheetItemKind.info,
            ),
        ],
      ),
      if (entry.credentials.isNotEmpty)
        NativeSheetSectionConfig(
          footer: l10n.hermesMcpKeepsValues(entry.name),
          items: [
            for (final credential in entry.credentials)
              NativeSheetItemConfig(
                id: hermesMcpRowId(
                  'catalog-credential',
                  entry.name,
                  credential.name,
                ),
                title: credential.prompt ?? credential.name,
                subtitle: credential.required
                    ? l10n.hermesMcpValueRequired(credential.name)
                    : l10n.hermesMcpValueOptional(credential.name),
                sfSymbol: 'key',
                kind: NativeSheetItemKind.secureTextField,
              ),
          ],
        ),
    ],
  );
}

/// The page setting an MCP server's API key.
@visibleForTesting
NativeSheetDetailConfig buildHermesMcpKeyPage(
  AppLocalizations l10n,
  String name, {
  String? notice,
  bool busy = false,
}) {
  final pageId = '$hermesMcpKeyPagePrefix${Uri.encodeComponent(name)}';
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.hermesMcpSetApiKeyFor(name),
    confirmActionId: hermesMcpRowId('key-save', name),
    confirmActionLabel: l10n.save,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: busy,
    items: [
      if (notice != null)
        NativeSheetItemConfig(
          id: '$pageId-notice',
          title: notice,
          sfSymbol: 'exclamationmark.triangle',
          kind: NativeSheetItemKind.info,
        ),
      NativeSheetItemConfig(
        id: hermesMcpRowId('key', name),
        title: l10n.hermesApiKeyTitle,
        sfSymbol: 'key',
        kind: NativeSheetItemKind.secureTextField,
      ),
    ],
  );
}

/// The Desktop Gateway's MCP servers in pages of Settings. What is typed
/// into its forms, secrets included, is kept only until Add or Save sends
/// it, or the page is left.
class HermesMcpSettingsPages extends SettingsPageModule {
  HermesMcpSettingsPages(this._ref);

  final Ref _ref;
  List<HermesMcpServer>? _servers;
  bool _failed = false;
  final Map<String, HermesMcpTestResult> _testResults = {};
  final Set<String> _testing = {};
  final Set<String> _authenticating = {};
  final Set<String> _busy = {};
  String? _notice;
  List<HermesMcpCatalogEntry>? _catalog;
  bool _catalogFailed = false;

  /// The Hermes connection the lists above were read from.
  String? _readFor;

  /// Counts visits to the Add, catalog entry and key forms: a request's
  /// answer arriving after its form was left belongs to no form shown.
  int _formVisit = 0;

  // The forms, as typed.
  final Map<String, String> _add = {};
  String? _addNotice;
  bool _adding = false;
  final Map<String, String> _credentials = {};
  String? _catalogNotice;
  bool _catalogAdding = false;
  String _key = '';
  String? _keyNotice;
  bool _keySaving = false;

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);

  HermesDesktopApiService? get _service {
    final service = _ref.read(hermesApiServiceProvider);
    return service is HermesDesktopApiService ? service : null;
  }

  @override
  bool ownsPage(String detailId) =>
      detailId == hermesMcpPageId ||
      detailId == hermesMcpAddPageId ||
      detailId == hermesMcpCatalogPageId ||
      detailId.startsWith(hermesMcpServerPagePrefix) ||
      detailId.startsWith(hermesMcpCatalogEntryPagePrefix) ||
      detailId.startsWith(hermesMcpKeyPagePrefix);

  HermesMcpState _state() => HermesMcpState(
    servers: _servers,
    failed: _failed,
    testResults: Map.of(_testResults),
    testing: Set.of(_testing),
    authenticating: Set.of(_authenticating),
    busy: Set.of(_busy),
    supportsCredentialUpdate: _service?.supportsMcpCredentialUpdate ?? false,
    notice: _notice,
  );

  /// Another connection in use since the lists were read: they are its
  /// last one's, and their rows would act on this one with that one's
  /// names. They are read again.
  void _forgetOtherConnection() {
    final connection = _ref.read(hermesActiveConnectionIdProvider);
    if (connection == _readFor) return;
    _readFor = connection;
    // Reads still on their way are the last connection's.
    _listReads++;
    _servers = null;
    _failed = false;
    _testResults.clear();
    _catalog = null;
    _catalogFailed = false;
  }

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _forgetOtherConnection();
    if (detailId == hermesMcpPageId) {
      await _applyList(l10n);
      await _load(l10n);
    } else if (detailId.startsWith(hermesMcpServerPagePrefix)) {
      await _applyServer(
        l10n,
        Uri.decodeComponent(
          detailId.substring(hermesMcpServerPagePrefix.length),
        ),
      );
    } else if (detailId == hermesMcpAddPageId) {
      _formVisit++;
      _add.clear();
      _addNotice = null;
      await _surface.applyDetail(buildHermesMcpAddPage(l10n));
    } else if (detailId == hermesMcpCatalogPageId) {
      await _loadCatalog(l10n);
    } else if (detailId.startsWith(hermesMcpCatalogEntryPagePrefix)) {
      final entry = _catalogEntry(
        Uri.decodeComponent(
          detailId.substring(hermesMcpCatalogEntryPagePrefix.length),
        ),
      );
      if (entry == null) return;
      _formVisit++;
      _credentials.clear();
      _catalogNotice = null;
      await _surface.applyDetail(buildHermesMcpCatalogEntryPage(l10n, entry));
    } else if (detailId.startsWith(hermesMcpKeyPagePrefix)) {
      _formVisit++;
      _key = '';
      _keyNotice = null;
      await _surface.applyDetail(
        buildHermesMcpKeyPage(
          l10n,
          Uri.decodeComponent(
            detailId.substring(hermesMcpKeyPagePrefix.length),
          ),
        ),
      );
    }
  }

  @override
  void pageLeft(String detailId) {
    // What a form held, secrets included, goes with it.
    if (detailId == hermesMcpAddPageId) {
      _formVisit++;
      _add.clear();
    } else if (detailId.startsWith(hermesMcpCatalogEntryPagePrefix)) {
      _formVisit++;
      _credentials.clear();
    } else if (detailId.startsWith(hermesMcpKeyPagePrefix)) {
      _formVisit++;
      _key = '';
    } else if (detailId == hermesMcpPageId) {
      _notice = null;
    }
  }

  @override
  void settingsClosed() {
    _add.clear();
    _credentials.clear();
    _key = '';
    _notice = null;
  }

  HermesMcpCatalogEntry? _catalogEntry(String name) =>
      _catalog?.where((entry) => entry.name == name).firstOrNull;

  Future<void> _applyList(AppLocalizations l10n) {
    final state = _state();
    return _surface.applyDetail(
      buildHermesMcpPage(l10n, state),
      detailSheets: [
        buildHermesMcpAddPage(l10n),
        buildNativeLoadingDetail(
          l10n: l10n,
          id: hermesMcpCatalogPageId,
          title: l10n.hermesMcpAddFromCatalog,
        ),
        for (final server in state.servers ?? const <HermesMcpServer>[])
          buildHermesMcpServerPage(l10n, state, server.name),
      ],
    );
  }

  Future<void> _applyServer(AppLocalizations l10n, String name) {
    final state = _state();
    return _surface.applyDetail(
      buildHermesMcpServerPage(l10n, state, name),
      detailSheets: [
        if (state.supportsCredentialUpdate) buildHermesMcpKeyPage(l10n, name),
      ],
    );
  }

  /// Draws the list and [name]'s page again, wherever they are.
  Future<void> _applyAll(AppLocalizations l10n, [String? name]) async {
    await _applyList(l10n);
    if (name != null) await _applyServer(l10n, name);
  }

  /// Counts list reads: one that started before a later one does not
  /// replace what the later one read (the list after an addition, say).
  int _listReads = 0;

  Future<void> _readServers(HermesDesktopApiService service) async {
    final read = ++_listReads;
    final servers = await service.mcpServers();
    // Kept only as the newest read, through the connection in use now: a
    // read through the last one's service never fills this one's list.
    if (read == _listReads && identical(service, _service)) {
      _servers = servers;
    }
  }

  /// Reads the servers again; answers whether that worked.
  Future<bool> _load(AppLocalizations l10n) async {
    final service = _service;
    if (service == null) {
      _failed = true;
      await _applyList(l10n);
      return false;
    }
    var read = false;
    try {
      await _readServers(service);
      _failed = false;
      read = true;
    } catch (error) {
      DebugLogger.warning(
        'mcp-load-failed',
        scope: 'settings/hermes-mcp',
        data: {'errorType': error.runtimeType.toString()},
      );
      _failed = _servers == null;
    }
    await _applyList(l10n);
    return read;
  }

  Future<void> _loadCatalog(AppLocalizations l10n) async {
    _catalogFailed = false;
    await _surface.applyDetail(
      buildHermesMcpCatalogPage(l10n, entries: _catalog),
    );
    try {
      final service = _service;
      if (service == null) {
        throw StateError('Desktop Gateway is not connected.');
      }
      _catalog = await service.mcpCatalog();
    } catch (error) {
      DebugLogger.warning(
        'mcp-catalog-load-failed',
        scope: 'settings/hermes-mcp',
        data: {'errorType': error.runtimeType.toString()},
      );
      _catalogFailed = _catalog == null;
    }
    await _surface.applyDetail(
      buildHermesMcpCatalogPage(
        l10n,
        entries: _catalog,
        failed: _catalogFailed,
      ),
      detailSheets: [
        for (final entry in _catalog ?? const <HermesMcpCatalogEntry>[])
          buildHermesMcpCatalogEntryPage(l10n, entry),
      ],
    );
  }

  /// Runs [action] on server [name], its rows waiting meanwhile; a failure
  /// is said on the pages.
  Future<bool> _run(
    AppLocalizations l10n,
    String name,
    Set<String> marks,
    Future<void> Function(HermesDesktopApiService service) action,
  ) async {
    final service = _service;
    if (service == null || !marks.add(name)) return false;
    _notice = null;
    await _applyAll(l10n, name);
    var succeeded = false;
    try {
      await action(service);
      succeeded = true;
    } catch (error) {
      DebugLogger.warning(
        'mcp-action-failed',
        scope: 'settings/hermes-mcp',
        data: {'errorType': error.runtimeType.toString()},
      );
      _notice = l10n.hermesMcpActionFailed;
    } finally {
      marks.remove(name);
    }
    await _applyAll(l10n, name);
    return succeeded;
  }

  Future<void> _test(AppLocalizations l10n, String name) =>
      _run(l10n, name, _testing, (service) async {
        final result = await service.testMcpServer(name);
        _testResults[name] = result;
        _notice = _testOutcome(l10n, result);
      });

  Future<void> _oauth(AppLocalizations l10n, String name) =>
      _run(l10n, name, _authenticating, (service) async {
        if (!await service.authenticateMcpServer(name)) {
          throw StateError('MCP authentication failed.');
        }
        await _readServers(service);
      });

  Future<void> _setEnabled(AppLocalizations l10n, String name, bool enabled) =>
      _run(l10n, name, _busy, (service) async {
        await service.setMcpServerEnabled(name, enabled);
        await _readAfter(l10n, service);
      });

  Future<void> _remove(AppLocalizations l10n, String name) async {
    final removed = await _run(l10n, name, _busy, (service) async {
      await service.removeMcpServer(name);
      // Removed, whatever the read after it says: it leaves the list now.
      _servers = [
        for (final server in _servers ?? const <HermesMcpServer>[])
          if (server.name != name) server,
      ];
      _testResults.remove(name);
      await _readAfter(l10n, service);
    });
    if (removed) await _surface.closeDetail(hermesMcpServerPageId(name));
  }

  /// Reads the list after a change that went through. Not read, the change
  /// still stands; the page says the list could not be read.
  Future<void> _readAfter(
    AppLocalizations l10n,
    HermesDesktopApiService service,
  ) async {
    try {
      await _readServers(service);
    } catch (error) {
      DebugLogger.warning(
        'mcp-reload-failed',
        scope: 'settings/hermes-mcp',
        data: {'errorType': error.runtimeType.toString()},
      );
      _notice = l10n.hermesMcpLoadFailed;
    }
  }

  Future<void> _addServer(AppLocalizations l10n) async {
    final service = _service;
    final name = _add['name']?.trim() ?? '';
    if (_adding) return;
    if (name.isEmpty) {
      _addNotice = l10n.nameRequired;
      return _applyAdd(l10n);
    }
    if (service == null) {
      _addNotice = l10n.hermesMcpActionFailed;
      return _applyAdd(l10n);
    }
    _adding = true;
    _addNotice = null;
    await _applyAdd(l10n);
    final visit = _formVisit;
    try {
      await service.addMcpServer(
        name: name,
        url: _add['url']?.trim() ?? '',
        command: _add['command']?.trim() ?? '',
        arguments: (_add['arguments'] ?? '')
            .split('\n')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(),
        bearerToken: _add['key'] ?? '',
      );
      _adding = false;
      // Left and opened again meanwhile: the new visit's form is its own.
      if (visit != _formVisit) {
        await _load(l10n);
        return;
      }
      // The only copy of the key here goes as soon as it is sent.
      _add.clear();
      await _surface.closeDetail(hermesMcpAddPageId);
      await _load(l10n);
    } catch (error) {
      DebugLogger.warning(
        'mcp-add-failed',
        scope: 'settings/hermes-mcp',
        data: {'errorType': error.runtimeType.toString()},
      );
      _adding = false;
      if (visit != _formVisit) return;
      _addNotice = l10n.hermesMcpActionFailed;
      await _applyAdd(l10n);
    }
  }

  Future<void> _applyAdd(AppLocalizations l10n) => _surface.applyDetail(
    buildHermesMcpAddPage(
      l10n,
      name: _add['name'] ?? '',
      url: _add['url'] ?? '',
      command: _add['command'] ?? '',
      arguments: _add['arguments'] ?? '',
      notice: _addNotice,
      busy: _adding,
    ),
  );

  Future<void> _addFromCatalog(AppLocalizations l10n, String name) async {
    final entry = _catalogEntry(name);
    final service = _service;
    if (entry == null || service == null || _catalogAdding) return;
    Future<void> applyEntry() => _surface.applyDetail(
      buildHermesMcpCatalogEntryPage(
        l10n,
        entry,
        notice: _catalogNotice,
        busy: _catalogAdding,
      ),
    );
    final credentials = hermesMcpCatalogCredentialValues(entry, _credentials);
    if (credentials == null) {
      _catalogNotice = l10n.hermesMcpFillRequired;
      return applyEntry();
    }
    _catalogAdding = true;
    _catalogNotice = null;
    await applyEntry();
    final visit = _formVisit;
    bool stillInstalling;
    try {
      stillInstalling = await service.addMcpCatalogEntry(
        entry,
        credentials: credentials,
      );
    } catch (error) {
      DebugLogger.warning(
        'mcp-catalog-add-failed',
        scope: 'settings/hermes-mcp',
        data: {'errorType': error.runtimeType.toString()},
      );
      _catalogAdding = false;
      // Shows what Hermes has even when a step after the install failed,
      // so the entry is not asked for again.
      await _load(l10n);
      if (visit != _formVisit) return;
      _catalogNotice = l10n.hermesMcpActionFailed;
      return applyEntry();
    }
    _catalogAdding = false;
    // Left and opened again meanwhile: the new visit's form is its own.
    if (visit != _formVisit) {
      await _load(l10n);
      return;
    }
    _credentials.clear();
    await _surface.closeDetail(
      '$hermesMcpCatalogEntryPagePrefix${Uri.encodeComponent(name)}',
    );
    await _surface.closeDetail(hermesMcpCatalogPageId);
    final listed = await _load(l10n);
    if (stillInstalling) {
      // Listed, and ready to sign in to, only once Hermes has built it.
      _notice = entry.usesOAuth
          ? l10n.hermesMcpStillInstallingSignIn(name)
          : l10n.hermesMcpStillInstalling(name);
      return _applyList(l10n);
    }
    // A server Hermes set up to sign in with OAuth goes straight on to
    // signing in. When the list cannot be read, the catalog says whether it
    // signs in that way.
    final servers = listed ? _servers : null;
    final signsIn = servers == null
        ? entry.usesOAuth
        : servers.any(
            (server) => server.name == name && server.auth == 'oauth',
          );
    if (!signsIn) return;
    await _oauth(l10n, name);
    if (_notice == l10n.hermesMcpActionFailed) {
      _notice = l10n.hermesMcpAddedSignInUnfinished(name);
      await _applyList(l10n);
    }
  }

  Future<void> _saveKey(AppLocalizations l10n, String name) async {
    final service = _service;
    final pageId = '$hermesMcpKeyPagePrefix${Uri.encodeComponent(name)}';
    if (service == null || _keySaving || _key.isEmpty) return;
    _keySaving = true;
    _keyNotice = null;
    await _surface.applyDetail(buildHermesMcpKeyPage(l10n, name, busy: true));
    final visit = _formVisit;
    try {
      await service.setMcpApiKey(name, _key);
      _keySaving = false;
      // Left and opened again meanwhile: the new visit's key is its own.
      if (visit != _formVisit) {
        await _load(l10n);
        return;
      }
      _key = '';
      await _surface.closeDetail(pageId);
      await _load(l10n);
    } catch (error) {
      DebugLogger.warning(
        'mcp-key-failed',
        scope: 'settings/hermes-mcp',
        data: {'errorType': error.runtimeType.toString()},
      );
      _keySaving = false;
      if (visit != _formVisit) return;
      _keyNotice = l10n.hermesMcpActionFailed;
      await _surface.applyDetail(
        buildHermesMcpKeyPage(l10n, name, notice: _keyNotice),
      );
    }
  }

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    if (!id.startsWith(hermesMcpRowPrefix)) return false;
    final parts = id.substring(hermesMcpRowPrefix.length).split(':');
    if (parts.length < 2) return true;
    final field = parts[0];
    final argument = Uri.decodeComponent(parts[1]);
    final extra = parts.length > 2 ? Uri.decodeComponent(parts[2]) : null;
    switch (field) {
      case 'test':
        await _test(l10n, argument);
      case 'oauth':
        await _oauth(l10n, argument);
      case 'enabled' when value is bool:
        await _setEnabled(l10n, argument, value);
      case 'remove':
        await _remove(l10n, argument);
      case 'add-name' ||
              'add-url' ||
              'add-command' ||
              'add-arguments' ||
              'add-key'
          when value is String:
        _add[field.substring('add-'.length)] = value;
      case 'add':
        await _addServer(l10n);
      case 'catalog-credential' when extra != null && value is String:
        _credentials[extra] = value;
      case 'catalog-add':
        await _addFromCatalog(l10n, argument);
      case 'key' when value is String:
        _key = value;
      case 'key-save':
        await _saveKey(l10n, argument);
    }
    return true;
  }
}
