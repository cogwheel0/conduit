import 'dart:async';

import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_form.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_mcp.dart';
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart'
    hide HermesDeliveryOptions;
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart'
    as delivery
    show HermesDeliveryOptions;
import 'package:conduit_core/features/hermes/models/hermes_toolset.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_access.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_http_session.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_connection_coordinator.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart'
    show HermesDesktopRpcException;
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart'
    hide HermesCadenceKind;
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart'
    as core_cadence
    show HermesCadenceKind;
import 'package:conduit_core/features/hermes/utils/hermes_schedule_validation.dart';
import 'package:conduit_core/features/push/services/hermes_push_backend.dart'
    show
        hermesDeliverIncludesConduit,
        hermesDeliverWithConduit,
        kConduitHermesPluginName;
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'hermes_connection.dart';
import 'hermes_dashboard_cookies.dart';
import 'hermes_service.dart';
import 'settled.dart';

/// A job's `deliver` as the editor sent it ([deliver], its targets, which
/// never list Conduit's push plugin), with the plugin kept as [notify]
/// says: a phone's Notify Me survives an edit made on this Mac.
String hermesJobDeliverKeepingNotifyMe(String deliver, {required bool notify}) {
  final has = parseHermesDeliveryTargets(deliver)
      .contains(kConduitHermesPluginName);
  if (has == notify) return deliver;
  return hermesDeliverWithConduit(deliver, notify: notify);
}

/// How long a Run Now waits for Hermes to refuse it before answering: the
/// gateway answers a trigger only once its run ends, so a run that started
/// is reported running and followed by the job list.
const Duration kHermesRunRefusalWindow = Duration(milliseconds: 1500);

/// How long the delivery targets read for the job list are kept: three
/// lookups (one over the gateway's socket) for every poll would be a lot.
const Duration _kDeliveryOptionsTtl = Duration(seconds: 60);

/// Implements Hermes's administration over the core's providers, as the
/// phone's settings pages use them: `hermes.connections.*` (the switch and
/// the saved connections), `hermes.mcp.*` (a Desktop Gateway's MCP
/// servers), the scheduled agents (`hermes.jobs`, `hermes.saveJob`, ...,
/// `hermes.jobs.*`) and `hermes.catalog`.
///
/// What the phone's pages keep in their state -- a Run Now waiting for its
/// run, a Stop waiting for its run to end -- is kept here, per connection,
/// so the window only polls the list while it shows it.
final class HermesAdminService {
  HermesAdminService(
    this._container, {
    EventBus? events,
    this.hermes,
    DaemonHermesDashboardCookies? dashboardCookies,
  }) : _events = events,
       _dashboardCookies = dashboardCookies {
    // A connection switch leaves nothing of the previous one's jobs to
    // settle.
    _serviceWatch = _container.listen<HermesBackendService?>(
      hermesApiServiceProvider,
      (previous, next) {
        if (!identical(previous, next)) _forgetConnection();
      },
    );
  }

  final ProviderContainer _container;
  final EventBus? _events;

  /// The dashboard sessions the window's sign-in hands over.
  final DaemonHermesDashboardCookies? _dashboardCookies;

  /// Hermes's sessions, told of the sessions a job's runs wrote so they
  /// open as any other.
  final HermesService? hermes;
  ProviderSubscription<HermesBackendService?>? _serviceWatch;

  void dispose() => _serviceWatch?.close();

  HermesConfigController get _config =>
      _container.read(hermesConfigProvider.notifier);

  void _announce() => _events?.emit(
    ConduitEventSpecs.hermesChanged,
    HermesChanged(connection: hermes?.connection.current),
  );

  /// The daemon's name for the connection in use now.
  String? get _connection => hermes?.connection.current;

  /// What a request is made under: the connection's name and the
  /// configuration in use, read together once, before any wait. A request
  /// naming another connection (its `connection`; none from an older
  /// window) is refused.
  _Scope _enter([String? asked]) {
    hermes?.connection.require(asked);
    return (
      connection: _connection,
      active: _container.read(hermesConfigProvider),
    );
  }

  /// The one check: [scope]'s connection is still the one in use.
  bool _current(_Scope scope) => scope.connection == _connection;

  /// Refuses to write, keep or answer anything under [scope] once another
  /// connection is in use.
  void _check(_Scope scope) {
    if (!_current(scope)) {
      throw HermesConnectionKey.stale(
        scope.connection ?? '',
        _connection ?? '',
      );
    }
  }

  /// [_bound] for a change: it must name the connection it was made under.
  /// One naming none (a window that never knew it) is refused
  /// (`invalidParams`, reason `connectionRequired`) rather than made on
  /// whichever connection is in use by the time it arrives.
  Future<T> _change<T>(String? asked, Future<T> Function(_Scope scope) body) {
    if (hermes != null && asked == null) {
      return Future<T>.error(
        const RpcError(
          code: ConduitErrorCodes.invalidParams,
          args: <String, String>{'reason': 'connectionRequired'},
          debugMessage: 'a Hermes settings change names no connection',
        ),
      );
    }
    return _bound(asked, body);
  }

  /// The jobs read again after a change that was made: a read that fails
  /// says so (`listFailed`, with [saved] still naming what the change
  /// wrote) rather than turning the change into an error. Another
  /// connection in use meanwhile is still refused.
  Future<HermesJobs> _jobsAfter({String? saved}) async {
    try {
      return (await jobs()).copyWith(savedId: saved);
    } on RpcError catch (error) {
      if (error.code == ConduitErrorCodes.sessionExpired) rethrow;
      return HermesJobs(savedId: saved, listFailed: true);
    }
  }

  /// The servers read again after a change that was made, as [_jobsAfter].
  Future<HermesMcpServers> _mcpAfter() async {
    try {
      return await mcpServers();
    } on RpcError catch (error) {
      if (error.code == ConduitErrorCodes.sessionExpired) rethrow;
      return const HermesMcpServers(available: true, listFailed: true);
    }
  }

  /// [body], made under the connection in use now (refusing [asked] when
  /// it names another): its answer is checked against that connection
  /// last, and [body] checks it before each write or change after a wait.
  Future<T> _bound<T>(String? asked, Future<T> Function(_Scope scope) body) =>
      _guard(() async {
        final scope = _enter(asked);
        final answer = await body(scope);
        _check(scope);
        return answer;
      });

  void _forgetConnection() {
    _stopping.clear();
    _runPending.clear();
    _notices.clear();
    _stopUnsupported = false;
    _deliveryOptions = null;
    _mcpTools.clear();
    _catalog = null;
  }

  // ---------------------------------------------------------------------------
  // Connections
  // ---------------------------------------------------------------------------

  /// Hermes's switch and every saved connection, the one in use marked,
  /// with the daemon's name for it. The one in use and its name are read
  /// together once; a switch while the others are read starts the list
  /// again, so a list never names one connection and another's key.
  Future<HermesConnections> connections({String? savedId}) async {
    await _config.waitForSecretsHydration();
    for (var attempt = 1; ; attempt++) {
      final scope = _enter();
      final active = scope.active;
      final profiles = _container.read(hermesConnectionsProvider);
      final rows = <HermesConnectionDto>[];
      for (final profile in profiles) {
        final isActive = profile.id == active.connectionId;
        HermesConfig? config = isActive ? active : null;
        if (config == null) {
          try {
            config = await _config.savedConnectionConfig(profile.id);
          } on Object {
            config = null;
          }
        }
        rows.add(
          _connectionDto(
            profile,
            config,
            active: isActive,
            dashboardSignedIn:
                profile.desktopAuthKind ==
                    HermesDesktopAuthKind.dashboardCookie &&
                (_dashboardCookies?.hasSession(profile.baseUrl) ?? false),
          ),
        );
      }
      if (!_current(scope) && attempt < 3) continue;
      _check(scope);
      return HermesConnections(
        enabled: active.enabled,
        activeId: active.connectionId,
        connections: rows,
        canAdd: profiles.length < kMaxHermesConnections,
        savedId: savedId,
        connection: scope.connection,
      );
    }
  }

  static HermesConnectionDto _connectionDto(
    HermesConnectionProfile profile,
    HermesConfig? config, {
    required bool active,
    bool dashboardSignedIn = false,
  }) => HermesConnectionDto(
    id: profile.id,
    name: profile.name,
    baseUrl: profile.baseUrl,
    mode: _modeName(profile.mode),
    desktopAuthKind: profile.desktopAuthKind.name,
    desktopProfile: profile.desktopProfile,
    allowSelfSignedCertificates: profile.allowSelfSignedCertificates,
    active: active,
    plainHttp: HermesConfig.plainHttpOrigin(profile.baseUrl) != null,
    hasApiKey: config?.apiKey?.trim().isNotEmpty ?? false,
    hasLegacyToken:
        config?.desktopCredentials?.legacyToken?.trim().isNotEmpty ?? false,
    desktopSignedIn: config?.desktopCredentials?.nativeTokens != null,
    accessHeaderNames: config?.accessHeaders.keys.toList() ?? const [],
    hasMemoryKey: config?.sessionKey?.trim().isNotEmpty ?? false,
    dashboardSignedIn: dashboardSignedIn,
  );

  /// The stored connection [id] (with its secrets), or a blank one for a
  /// new connection.
  Future<HermesConfig> _saved(String? id) async {
    await _config.waitForSecretsHydration();
    if (id == null) return const HermesConfig();
    try {
      return await _config.savedConnectionConfig(id);
    } on StateError {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'connectionId': id},
        debugMessage: 'no such Hermes connection',
      );
    }
  }

  /// [edit] as core's connection form: a secret left out keeps the one
  /// saved for the same server.
  static HermesConnectionForm _form(
    HermesConnectionEdit edit,
    HermesConfig saved,
  ) {
    final name = edit.name;
    final headers = edit.accessHeaders == null
        ? saved.accessHeaders
        : _accessHeaders(edit.accessHeaders!, saved.accessHeaders);
    final headersDirty =
        edit.accessHeaders != null &&
        !_sameHeaders(headers, saved.accessHeaders);
    return HermesConnectionForm(
      connectionId: edit.id,
      name: name ?? '',
      nameDirty: name != null,
      nameSource: name == null
          ? null
          : name.trim().isEmpty
          ? HermesConnectionNameSource.derived
          : HermesConnectionNameSource.user,
      url: edit.baseUrl,
      mode: _mode(edit.mode),
      desktopAuthKind: _authKind(edit.desktopAuthKind),
      desktopProfile:
          HermesConfig.isValidDesktopProfile(edit.desktopProfile.trim())
          ? edit.desktopProfile.trim()
          : 'default',
      allowSelfSignedCertificates: edit.allowSelfSignedCertificates,
      plainHttpConsentOrigin: edit.allowPlainHttp
          ? HermesConfig.plainHttpOrigin(edit.baseUrl)
          : null,
      apiKey: edit.apiKey ?? '',
      apiKeyDirty: edit.apiKey != null,
      sessionKey: edit.memoryKey ?? '',
      sessionKeyDirty: edit.memoryKey != null,
      legacyToken: edit.legacyToken ?? '',
      desktopCredentialsDirty: edit.legacyToken != null || headersDirty,
      initialAccessHeaders: saved.accessHeaders,
      accessHeaders: headers,
      accessHeadersDirty: headersDirty,
    );
  }

  /// The headers [rows] make: a row without a value keeps the saved value
  /// of the header it was. A list the core refuses is `invalidParams`
  /// (`reason: accessHeader`, the `issue` and the `header`).
  static Map<String, String> _accessHeaders(
    List<HermesAccessHeaderEdit> rows,
    Map<String, String> saved,
  ) {
    String? savedValue(String name) => saved.entries
        .where((entry) => entry.key.toLowerCase() == name.toLowerCase())
        .firstOrNull
        ?.value;
    final headers = <String, String>{};
    for (final row in rows) {
      final value = row.value ?? savedValue(row.savedName ?? row.name);
      if (value == null) {
        throw RpcError(
          code: ConduitErrorCodes.invalidParams,
          args: <String, String>{
            'reason': 'accessHeader',
            'issue': HermesAccessHeaderIssue.invalidValue.name,
            'header': row.name,
          },
          debugMessage: 'a new header needs its value',
        );
      }
      if (headers.keys.any((k) => k.toLowerCase() == row.name.toLowerCase())) {
        throw RpcError(
          code: ConduitErrorCodes.invalidParams,
          args: <String, String>{
            'reason': 'accessHeader',
            'issue': HermesAccessHeaderIssue.duplicate.name,
            'header': row.name,
          },
          debugMessage: 'header names must be unique',
        );
      }
      headers[row.name] = value;
    }
    final problem = HermesConfig.accessHeadersProblem(headers);
    if (problem != null) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{
          'reason': 'accessHeader',
          'issue': problem.issue.name,
          'header': ?problem.name,
        },
        debugMessage: HermesConfig.validateAccessHeaders(headers) ?? '',
      );
    }
    return headers;
  }

  static bool _sameHeaders(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    final ak = a.keys.toList();
    final bk = b.keys.toList();
    for (var i = 0; i < ak.length; i++) {
      if (ak[i] != bk[i] || a[ak[i]] != b[bk[i]]) return false;
    }
    return true;
  }

  /// The draft [edit] makes, or the reason it cannot be used: an address
  /// Hermes cannot use (`invalidUrl`), an API server without its key
  /// (`keyRequired`), or credentials that would go unencrypted without
  /// the user's agreement (`plainHttpConsent`).
  ({HermesConfig config, HermesConfig saved, HermesConnectionForm form}) _draft(
    HermesConnectionEdit edit,
    HermesConfig saved,
  ) {
    final form = _form(edit, saved);
    switch (validateHermesConnectionForm(saved, form)) {
      case HermesConnectionValidationIssue.invalidUrl:
        throw const RpcError(
          code: ConduitErrorCodes.invalidParams,
          args: <String, String>{'reason': 'invalidUrl'},
          debugMessage: 'use a valid http(s) address',
        );
      case HermesConnectionValidationIssue.credentialsReentryRequired:
        throw const RpcError(
          code: ConduitErrorCodes.invalidParams,
          args: <String, String>{'reason': 'keyRequired'},
          debugMessage: 'an API server needs its key',
        );
      case null:
        break;
    }
    final config = buildHermesConnectionDraft(saved, form).config;
    if (!config.mayUsePlainHttp) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': 'plainHttpConsent'},
        debugMessage: 'credentials would travel unencrypted',
      );
    }
    return (config: config, saved: saved, form: form);
  }

  /// Saves a connection, as the phone's editor does. The first saved is
  /// put in use and turns Hermes on (the account sheet's Connect), joining
  /// the backend already in use, or becoming it when there is none.
  Future<HermesConnections> saveConnection(HermesConnectionEdit edit) async {
    final saved = await _saved(edit.id);
    final draft = _draft(edit, saved);
    final hadActive = _container.read(hermesConfigProvider).connectionId;
    final String? id;
    try {
      id = await _container
          .read(hermesConnectionGatewayProvider)
          .persist(buildHermesConnectionDraft(draft.saved, draft.form));
    } on ArgumentError catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: const <String, String>{'reason': 'invalidUrl'},
        debugMessage: '${error.message}',
      );
    } on StateError catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: error.message,
      );
    }
    if (hadActive == null && edit.id == null) {
      await _config.setEnabled(true);
      final preferred = _container.read(preferredBackendProvider.notifier);
      if (_container.read(preferredBackendProvider) == PreferredBackend.unset) {
        await preferred.set(PreferredBackend.hermes);
      }
    }
    _announce();
    return connections(savedId: id);
  }

  /// Tries [edit] without saving it, as the editor's Test does: reached or
  /// not, and the name the server suggests.
  Future<HermesConnectionTestResult> testConnection(
    HermesConnectionEdit edit,
  ) async {
    final saved = await _saved(edit.id);
    final HermesConfig config;
    try {
      config = _draft(edit, saved).config;
    } on RpcError catch (error) {
      final reason = error.args['reason'];
      if (reason == 'plainHttpConsent' || reason == 'accessHeader') rethrow;
      return HermesConnectionTestResult(
        reason: reason == 'keyRequired' ? 'keyRequired' : 'invalid',
      );
    }
    final gateway = _container.read(hermesConnectionGatewayProvider);
    var ok = false;
    String? reason;
    try {
      ok = await gateway.probe(config);
    } on DioException catch (error) {
      reason = _refusal(error);
    } on Object {
      ok = false;
    }
    if (!ok && reason == null) reason = await _classify(config);
    if (!ok) return HermesConnectionTestResult(reason: reason ?? 'unreachable');
    return HermesConnectionTestResult(
      ok: true,
      suggestedName: await gateway.suggestDisplayName(config),
    );
  }

  static String _refusal(DioException error) {
    final status = error.response?.statusCode;
    return status == 401 || status == 403 ? 'unauthorized' : 'unreachable';
  }

  /// Why a probe failed, when asking again cannot spend anything: a legacy
  /// token or an API key is only sent, never rotated.
  Future<String?> _classify(HermesConfig config) async {
    if (config.mode != HermesBackendMode.desktopGateway ||
        config.desktopAuthKind != HermesDesktopAuthKind.legacyToken) {
      return null;
    }
    final service = HermesDesktopApiService(config: config);
    try {
      await service.statusProbe(refresh: true);
      return null;
    } on DioException catch (error) {
      return _refusal(error);
    } on Object {
      return null;
    } finally {
      service.close();
    }
  }

  /// Puts connection [id] in use: sessions, jobs and servers follow it.
  Future<HermesConnections> activate(String id) => _guard(() async {
    await _config.setActiveConnection(id);
    _container.invalidate(hermesSessionsProvider);
    _announce();
    return connections();
  });

  /// Deletes connection [id] and its credentials. With none left, a
  /// Hermes-only setup goes back to choosing a backend, as on a phone.
  Future<HermesConnections> deleteConnection(String id) => _guard(() async {
    await _config.deleteConnection(id);
    if (_container.read(hermesConnectionsProvider).isEmpty &&
        _container.read(preferredBackendProvider) == PreferredBackend.hermes) {
      await _container
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.unset);
    }
    _announce();
    return connections();
  });

  /// Turns Hermes on or off. Off, a Hermes-only setup goes back to choosing
  /// a backend, as on a phone.
  Future<HermesConnections> setEnabled(bool enabled) => _guard(() async {
    await _config.setEnabled(enabled);
    if (!enabled &&
        _container.read(preferredBackendProvider) == PreferredBackend.hermes) {
      await _container
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.unset);
    }
    _announce();
    return connections();
  });

  /// The profiles a Desktop Gateway offers [edit]'s connection, as the
  /// phone's Refresh Profiles lists them: through the live connection when
  /// the form is the one in use, unchanged, else through one made for the
  /// form. When none can be listed, why (the form keeps its profile).
  Future<HermesProfiles> profiles(HermesConnectionEdit edit) async {
    final saved = await _saved(edit.id);
    final draft = buildHermesConnectionDraft(
      saved,
      _form(edit, saved),
    ).config.copyWith(enabled: true);
    final blocked = hermesProfileListBlocker(draft);
    if (blocked != null) return HermesProfiles(issue: blocked.name);
    final active = _container.read(hermesConfigProvider);
    final live = _container.read(hermesApiServiceProvider);
    final editsActive = edit.id != null && edit.id == active.connectionId;
    // A token refresh while listing lands with the connection it belongs
    // to, and only while the form still matches it.
    final writeCredentials = _config.credentialsWriterFor(saved);
    final coordinator = HermesDesktopConnectionCoordinator(
      openExternalUrl: _container.read(openExternalUrlProvider),
      dashboardBridgeFactory: _container.read(
        hostHermesDashboardBridgeFactoryProvider,
      ),
    );
    try {
      final listed = await coordinator.profiles(
        draft,
        service: switch (live) {
          final HermesDesktopApiService service
              when editsActive &&
                  hermesDesktopConnectionMatches(saved, draft) =>
            service,
          _ => null,
        },
        onCredentialsChanged: (credentials) async {
          if (!hermesDesktopConnectionMatches(saved, draft)) {
            throw StateError(
              'Save the Hermes server before refreshing its sign-in.',
            );
          }
          await writeCredentials(credentials);
        },
      );
      if (listed.isEmpty) {
        return HermesProfiles(issue: HermesProfileListIssue.empty.name);
      }
      return HermesProfiles(
        profiles: listed,
        selected: hermesProfileAfterRefresh(listed, draft.desktopProfile),
      );
    } on Object {
      return HermesProfiles(issue: HermesProfileListIssue.signInFirst.name);
    }
  }

  // ---------------------------------------------------------------------------
  // Toolsets and skills (a Desktop Gateway's)
  // ---------------------------------------------------------------------------

  /// Turns toolset [toggle] on or off for new sessions, as the phone's
  /// switch does, on the connection it names; answers the catalog read
  /// again.
  Future<HermesCatalog> setToolset(HermesToolsetToggle toggle) =>
      _change(toggle.connection, (scope) async {
        final service = _gatewayService();
        _check(scope);
        await service.configureTools([toggle.name], enabled: toggle.enabled);
        _check(scope);
        _container.invalidate(hermesToolsetsProvider);
        return catalog();
      });

  /// Has the gateway [request] names read its skills again (Reload
  /// Skills); answers the catalog, whose `/` commands the window's Hermes
  /// chats then offer.
  Future<HermesCatalog> reloadSkills(HermesConnectionRef request) =>
      _change(request.connection, (scope) async {
        final service = _gatewayService();
        _check(scope);
        await service.reloadSkills();
        _check(scope);
        _container.invalidate(hermesSkillPromptsProvider);
        _container.invalidate(hermesInstalledSkillsProvider);
        return catalog();
      });

  // ---------------------------------------------------------------------------
  // Dashboard sign-in
  // ---------------------------------------------------------------------------

  /// Where connection [id]'s dashboard sign-in opens. The window's browser
  /// window, a WKWebView as on an iPhone, cannot add the access headers to
  /// the dashboard page's own requests, so with headers it is unsupported,
  /// as on an iPhone. Only for the connection in use [request] names.
  Future<HermesDashboardPlan> dashboardStart(HermesDashboardStart request) =>
      _change(request.connection, (scope) async {
        final saved = await _dashboardConnection(scope, request.id);
        final root = hermesDashboardRoot(saved.baseUrl);
        return HermesDashboardPlan(
          loginUrl: hermesDashboardLoginUrl(root).toString(),
          origin: root.origin,
          supported: hermesDashboardHeadersSupported(
            isIOS: true,
            accessHeaders: saved.accessHeaders,
          ),
        );
      });

  /// The sign-in windows closed (`hermes.dashboard.cancel`), newest last:
  /// their sign-ins keep nothing from then on. A few are enough: a window's
  /// completions come while it is open.
  final List<String> _closedAttempts = <String>[];

  /// Sign-in window [request]'s attempt closed: a completion still out for
  /// it keeps nothing it has not kept already (checked where the cookies
  /// would be kept), and any later one is refused the same way.
  Future<CancelledResult> dashboardCancel(HermesDashboardCancel request) async {
    _closedAttempts
      ..remove(request.attempt)
      ..add(request.attempt);
    if (_closedAttempts.length > 32) _closedAttempts.removeAt(0);
    return const CancelledResult(cancelled: true);
  }

  bool _open(String? attempt) =>
      attempt == null || !_closedAttempts.contains(attempt);

  /// Whether saved connection [id] is the one in use under [scope], and
  /// [scope] is still current.
  bool _inUse(_Scope scope, String id) =>
      _current(scope) && scope.active.connectionId == id;

  /// Saved connection [id] for a dashboard sign-in, the one guard of every
  /// dashboard path: only the connection in use under [scope] (another
  /// saved one, never put in use, is refused as a stale connection), and
  /// only a Desktop Gateway.
  Future<HermesConfig> _dashboardConnection(_Scope scope, String id) async {
    if (!_inUse(scope, id)) {
      throw HermesConnectionKey.stale(scope.connection ?? '', id);
    }
    final saved = await _saved(id);
    _check(scope);
    if (!_inUse(scope, id)) {
      throw HermesConnectionKey.stale(scope.connection ?? '', id);
    }
    if (saved.mode != HermesBackendMode.desktopGateway) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'dashboard sign-in needs a Desktop Gateway',
      );
    }
    return saved;
  }

  /// Takes the cookies a dashboard page in the sign-in window had: kept,
  /// and the connection's dashboard requests sent with them, once the
  /// dashboard says they are a signed-in session. Not yet: nothing is kept
  /// and the window waits for the next page.
  /// Refused when it names no connection, or once another than the one
  /// the sign-in started under is in use.
  Future<HermesDashboardResult> dashboardComplete(
    HermesDashboardCookies request,
  ) => _change(request.connection, (scope) async {
    final store = _dashboardCookies;
    if (store == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'this daemon keeps no dashboard sessions',
      );
    }
    if (!_open(request.attempt)) return const HermesDashboardResult();
    final saved = await _dashboardConnection(scope, request.id);
    final root = hermesDashboardRoot(saved.baseUrl);
    final signedIn = await store.adopt(
      root,
      [for (final cookie in request.cookies) ?_cookie(cookie)],
      accessHeaders: saved.accessHeaders,
      httpClient: hermesDashboardHttpClientFor(root, saved),
      // Checked again where the cookies would be kept, after the dashboard
      // answered: nothing is kept for a connection no longer in use.
      // Nor for a sign-in window that closed meanwhile.
      wanted: () => _inUse(scope, request.id) && _open(request.attempt),
    );
    if (!signedIn) return const HermesDashboardResult();
    _check(scope);
    // As the phone after its sign-in page: what the gateway offers is read
    // again, through the session.
    _container.invalidate(hermesDesktopModelsProvider);
    _container.invalidate(hermesSessionsProvider);
    _container.invalidate(hermesCapabilitiesProvider);
    _container.invalidate(hermesToolsetsProvider);
    _announce();
    return HermesDashboardResult(
      signedIn: true,
      connections: await connections(),
    );
  });

  static HermesDashboardCookie? _cookie(HermesCookieDto dto) {
    final domain = dto.domain.trim().toLowerCase();
    if (dto.name.isEmpty || domain.replaceFirst('.', '').isEmpty) return null;
    return HermesDashboardCookie(
      name: dto.name,
      value: dto.value,
      domain: domain.startsWith('.') ? domain.substring(1) : domain,
      path: dto.path.startsWith('/') ? dto.path : '/',
      secure: dto.secure,
      httpOnly: dto.httpOnly,
      hostOnly: !domain.startsWith('.'),
      expires: dto.expiresMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(dto.expiresMs!, isUtc: true),
    );
  }

  // ---------------------------------------------------------------------------
  // MCP servers
  // ---------------------------------------------------------------------------

  /// What a test found of each server's tools, for servers whose list
  /// carries none.
  final Map<String, List<String>> _mcpTools = <String, List<String>>{};

  HermesDesktopApiService _gatewayService() {
    final service = _container.read(hermesApiServiceProvider);
    if (service is HermesDesktopApiService) return service;
    throw const RpcError(
      code: ConduitErrorCodes.unsupported,
      debugMessage: 'MCP servers need a Desktop Gateway connection',
    );
  }

  Future<HermesMcpServers> mcpServers() => _bound(null, (scope) async {
    final service = _container.read(hermesApiServiceProvider);
    if (service is! HermesDesktopApiService) return const HermesMcpServers();
    final servers = await service.mcpServers();
    return HermesMcpServers(
      available: true,
      canSetApiKey: service.supportsMcpCredentialUpdate,
      servers: <HermesMcpServerDto>[
        for (final server in servers)
          HermesMcpServerDto(
            name: server.name,
            description: server.description,
            enabled: server.enabled,
            auth: server.auth == null || server.auth!.trim().isEmpty
                ? null
                : server.auth,
            tools: server.tools.isNotEmpty
                ? server.tools
                : _mcpTools[server.name] ?? const <String>[],
            toolFilter: server.toolFilter?.summary,
          ),
      ],
    );
  });

  /// The catalog as last read, with the connection it was read from: an
  /// add hands core the entry the window was shown.
  ({HermesDesktopApiService service, List<HermesMcpCatalogEntry> entries})?
  _catalog;

  Future<List<HermesMcpCatalogEntry>> _readCatalog(
    HermesDesktopApiService service,
  ) async {
    final entries = await service.mcpCatalog();
    _catalog = (service: service, entries: entries);
    return entries;
  }

  Future<HermesMcpCatalog> mcpCatalog() => _bound(null, (scope) async {
    final entries = await _readCatalog(_gatewayService());
    return HermesMcpCatalog(
      entries: <HermesMcpCatalogEntryDto>[
        for (final entry in entries) _catalogEntryDto(entry),
      ],
    );
  });

  static HermesMcpCatalogEntryDto _catalogEntryDto(
    HermesMcpCatalogEntry entry,
  ) => HermesMcpCatalogEntryDto(
    name: entry.name,
    description: entry.description,
    authType: entry.authType,
    credentials: <HermesMcpCatalogCredentialDto>[
      for (final credential in entry.credentials)
        HermesMcpCatalogCredentialDto(
          name: credential.name,
          prompt: credential.prompt,
          required: credential.required,
        ),
    ],
    canAdd: entry.canAdd,
    fromDashboard: entry.fromDashboard,
    oauth: entry.usesOAuth,
  );

  Future<HermesMcpServers> addMcp(HermesMcpAdd add) => _change(add.connection, (
    scope,
  ) async {
    final name = add.name.trim();
    final url = add.url?.trim() ?? '';
    final command = add.command?.trim() ?? '';
    if (name.isEmpty || (url.isEmpty == command.isEmpty)) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'an MCP server needs a name and an address or command',
      );
    }
    await _gatewayService().addMcpServer(
      name: name,
      url: url,
      command: command,
      arguments: <String>[
        for (final arg in add.args)
          if (arg.trim().isNotEmpty) arg.trim(),
      ],
      bearerToken: add.apiKey,
    );
    // Every window reads the list again, so one read before the
    // change cannot leave it out.
    _announce();
    return _mcpAfter();
  });

  /// Adds catalog entry [request.name] with the values it asks for, as the
  /// phone's catalog page does, on the connection [request] names: a
  /// required value left empty is refused (`invalidParams`, reason
  /// `missingCredential`), an entry this connection cannot add with all it
  /// needs too (`cannotAdd`). The values go to Hermes once and are never
  /// kept or logged here. Says whether Hermes is still installing it, and
  /// whether it signs in with OAuth next, which the window starts
  /// (`hermes.mcp.authenticate`) since a sign-in in the browser can outlast
  /// a call.
  Future<HermesMcpCatalogAdded> addMcpFromCatalog(
    HermesMcpCatalogAdd request,
  ) => _change(request.connection, (scope) async {
    final service = _gatewayService();
    HermesMcpCatalogEntry? find(List<HermesMcpCatalogEntry> entries) =>
        entries.where((e) => e.name == request.name).firstOrNull;
    final cached = _catalog;
    var entry = cached != null && identical(cached.service, service)
        ? find(cached.entries)
        : null;
    entry ??= find(await _readCatalog(service));
    if (entry == null) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: const <String, String>{'reason': 'notInCatalog'},
        debugMessage: 'no MCP catalog entry named ${request.name}',
      );
    }
    if (!entry.canAdd) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': 'cannotAdd'},
        debugMessage: 'this connection cannot send what the entry needs',
      );
    }
    final credentials = hermesMcpCatalogCredentialValues(
      entry,
      request.credentials,
    );
    if (credentials == null) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': 'missingCredential'},
        debugMessage: 'a required value is empty',
      );
    }
    // The entry was read from the connection in use when asked.
    _check(scope);
    final bool stillInstalling;
    try {
      stillInstalling = await service.addMcpCatalogEntry(
        entry,
        credentials: credentials,
      );
    } finally {
      // Listed again even when a step after the install failed, so the
      // entry is not asked for again; every window reads the list again,
      // so one read before the change cannot leave it out.
      _catalog = null;
      _announce();
    }
    // Made: a list that cannot be read says so rather than failing the add.
    final servers = await _mcpAfter();
    // A server Hermes set up to sign in with OAuth goes on to signing in;
    // when the list cannot be read, the catalog says whether it does.
    final signsIn = servers.listFailed
        ? entry.usesOAuth
        : servers.servers.any(
            (server) => server.name == entry!.name && server.auth == 'oauth',
          );
    return HermesMcpCatalogAdded(
      servers: servers,
      stillInstalling: stillInstalling,
      signIn: !stillInstalling && signsIn,
    );
  });

  Future<HermesMcpServers> setMcpApiKey(HermesMcpApiKey request) =>
      _change(request.connection, (scope) async {
        final service = _gatewayService();
        if (!service.supportsMcpCredentialUpdate) {
          throw const RpcError(
            code: ConduitErrorCodes.unsupported,
            debugMessage: 'update Hermes to set an MCP server key',
          );
        }
        if (request.apiKey.isEmpty) {
          throw const RpcError(
            code: ConduitErrorCodes.invalidParams,
            debugMessage: 'an empty key',
          );
        }
        await service.setMcpApiKey(request.name, request.apiKey);
        // Every window reads the list again, so one read before the
        // change cannot leave it out.
        _announce();
        return _mcpAfter();
      });

  Future<HermesMcpServers> removeMcp(HermesMcpRef ref) =>
      _change(ref.connection, (scope) async {
        final name = ref.name;
        await _gatewayService().removeMcpServer(name);
        _check(scope);
        _mcpTools.remove(name);
        // Every window reads the list again, so one read before the
        // change cannot leave it out.
        _announce();
        return _mcpAfter();
      });

  Future<HermesMcpTestResultDto> testMcp(HermesMcpRef ref) =>
      _change(ref.connection, (scope) async {
        final name = ref.name;
        final result = await _gatewayService().testMcpServer(name);
        // Another connection's server of the same name is not this one.
        _check(scope);
        if (result.toolNames.isNotEmpty) {
          _mcpTools[name] = result.toolNames;
        }
        return HermesMcpTestResultDto(
          ok: result.ok,
          tools: result.tools,
          resources: result.resources,
          prompts: result.prompts,
          error: result.error,
          toolNames: result.toolNames,
        );
      });

  Future<HermesMcpServers> setMcpEnabled(HermesMcpToggle toggle) => _change(
    toggle.connection,
    (scope) async {
      await _gatewayService().setMcpServerEnabled(toggle.name, toggle.enabled);
      // Every window reads the list again, so one read before the
      // change cannot leave it out.
      _announce();
      return _mcpAfter();
    },
  );

  /// OAuth in the browser (the window opens the page): answers once it is
  /// done, or refuses when it failed or timed out.
  Future<HermesMcpServers> authenticateMcp(HermesMcpRef ref) =>
      _change(ref.connection, (scope) async {
        final name = ref.name;
        final signedIn = await _gatewayService().authenticateMcpServer(name);
        // A window that stopped waiting (past its call's limit) reads the
        // servers again on this.
        _announce();
        if (!signedIn) {
          throw const RpcError(
            code: ConduitErrorCodes.unauthorized,
            debugMessage: 'MCP sign-in did not finish',
          );
        }
        return _mcpAfter();
      });

  // ---------------------------------------------------------------------------
  // Scheduled agents
  // ---------------------------------------------------------------------------

  /// Jobs with a Stop sent, to the run each targets: null until Hermes
  /// answers the Stop, empty when it named no run.
  final Map<String, String?> _stopping = <String, String?>{};

  /// Jobs whose Run Now Hermes has not answered yet (it answers when the
  /// run ends).
  final Set<String> _runPending = <String>{};

  /// What the next list says once.
  final List<HermesJobNotice> _notices = <HermesJobNotice>[];
  bool _stopUnsupported = false;

  ({
    HermesBackendService service,
    DateTime at,
    delivery.HermesDeliveryOptions? options,
  })?
  _deliveryOptions;

  HermesJobsController get _jobs =>
      _container.read(hermesJobsProvider.notifier);

  /// The jobs, with their runs' state. Read quietly once listed (as the
  /// phone's page polls), so a window watching a run gets the live list.
  Future<HermesJobs> jobs() => _bound(null, (scope) async {
    final service = _container.read(hermesApiServiceProvider);
    if (service == null) return const HermesJobs();
    final current = _container.read(hermesJobsProvider).value;
    final quiet = current == null ? null : await _jobs.refreshQuietly();
    final List<HermesJob> list =
        quiet ??
        await readSettled<List<HermesJob>>(
          _container,
          hermesJobsProvider.future,
        );
    // What the list settles (Stops) and says once (notices) is this
    // connection's.
    _check(scope);
    _settleStops(list);
    final capabilities = await readSettled(
      _container,
      hermesCapabilitiesProvider.future,
    ).catchError((Object _) => hermesCapabilitiesFallback(service));
    final scheduling = service is HermesDesktopApiService;
    final options = scheduling ? await _cachedDeliveryOptions(service) : null;
    _check(scope);
    final notices = List<HermesJobNotice>.of(_notices);
    _notices.clear();
    return HermesJobs(
      jobs: <HermesJobDto>[for (final job in list) _job(job, options)],
      writable: capabilities.jobsAdmin,
      scheduling: scheduling,
      notices: notices,
    );
  });

  /// Settles each Stop by the run it targeted, never by "some run is
  /// live", as the phone's page does.
  void _settleStops(List<HermesJob> jobs) {
    for (final MapEntry(key: id, value: execution) in Map<String, String?>.of(
      _stopping,
    ).entries) {
      if (execution == null) continue;
      final job = jobs.where((j) => j.id == id).firstOrNull;
      final outcome = hermesJobStopOutcome(job, execution);
      if (outcome == HermesJobStopOutcome.pending) continue;
      _stopping.remove(id);
      _notices.add(
        HermesJobNotice(
          jobId: id,
          kind: outcome == HermesJobStopOutcome.cancelled
              ? 'stopped'
              : 'finishedBeforeStop',
        ),
      );
    }
  }

  HermesJobDto _job(HermesJob job, delivery.HermesDeliveryOptions? options) {
    final running = job.runInFlight || _runPending.contains(job.id);
    return HermesJobDto(
      id: job.id,
      name: job.name,
      prompt: job.prompt,
      schedule: job.schedule,
      scheduleText: describeHermesCronSchedule(job.schedule),
      cadence: hermesCadenceDto(parseHermesCronSchedule(job.schedule)),
      enabled: job.enabled,
      lastStatus: job.lastStatus,
      lastError: job.lastError,
      lastRunAtMs: job.lastRun?.millisecondsSinceEpoch,
      nextRunAtMs: job.nextRun?.millisecondsSinceEpoch,
      state: job.state,
      // Routes the core could not read are not shown as `local`: an edit
      // of what is shown would replace them.
      deliver: <HermesDeliveryTargetDto>[
        // A phone's Notify Me (`conduit`) is its own switch, not a target
        // this Mac lists or edits; a save keeps it as it was.
        if (job.deliveryKnown)
          for (final target in parseHermesDeliveryTargets(job.deliveryTarget))
            if (target != kConduitHermesPluginName)
              _target(
                options?.optionFor(target) ??
                    describeHermesDeliveryTarget(target),
              ),
      ],
      deliveryKnown: job.deliveryKnown,
      lastDeliveryError: job.lastDeliveryError,
      catchUp: _catchUpName(job.catchUpChoice),
      running: running,
      stopping: _stopping.containsKey(job.id),
      lastCancelReason: running ? null : job.lastCancelReason,
    );
  }

  static HermesDeliveryTargetDto _target(HermesDeliveryOption option) =>
      HermesDeliveryTargetDto(
        target: option.target,
        kind: option.kind.name,
        name: option.name,
        available: option.available,
      );

  Future<delivery.HermesDeliveryOptions?> _cachedDeliveryOptions(
    HermesBackendService service,
  ) async {
    final cached = _deliveryOptions;
    if (cached != null &&
        identical(cached.service, service) &&
        DateTime.now().difference(cached.at) < _kDeliveryOptionsTtl) {
      return cached.options;
    }
    delivery.HermesDeliveryOptions? options;
    try {
      options = await readSettled(
        _container,
        hermesJobDeliveryOptionsProvider.future,
      );
    } on Object {
      options = null;
    }
    _deliveryOptions = (service: service, at: DateTime.now(), options: options);
    return options;
  }

  /// Where the connection's jobs can deliver (`hermes.jobs.delivery`).
  Future<HermesDeliveryOptions> deliveryOptions() => _bound(null, (
    scope,
  ) async {
    final service = _container.read(hermesApiServiceProvider);
    if (service is! HermesDesktopApiService) {
      return const HermesDeliveryOptions();
    }
    _deliveryOptions = null;
    final options = await _cachedDeliveryOptions(service);
    return HermesDeliveryOptions(
      available: true,
      options: <HermesDeliveryTargetDto>[
        for (final option
            in (options ?? delivery.HermesDeliveryOptions.localOnly).options)
          if (option.target != kConduitHermesPluginName) _target(option),
      ],
    );
  });

  Future<HermesJobs> saveJob(HermesJobEdit edit) => _change(edit.connection, (
    scope,
  ) async {
    final prompt = edit.prompt.trim();
    final schedule = edit.schedule.trim();
    final typed = edit.name?.trim() ?? '';
    // An unnamed job is named after its prompt, as before names were
    // asked for.
    final name = typed.isNotEmpty
        ? typed
        : HermesJob(id: '-', prompt: prompt, schedule: '').displayName;
    final errors = validateHermesJobDraft(
      name: name,
      prompt: prompt,
      schedule: schedule,
    );
    if (!hermesJobDraftIsValid(errors)) {
      final (field, error) = errors.prompt != null
          ? ('prompt', errors.prompt!)
          : errors.schedule != null
          ? ('schedule', errors.schedule!)
          : ('name', errors.name!);
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'field': field, 'reason': error.name},
        debugMessage: 'the job draft is not valid',
      );
    }
    final scheduling =
        _container.read(hermesApiServiceProvider) is HermesDesktopApiService;
    // An edit never replaces routes the core could not read: they were
    // never shown, so no choice of the user's is about them. A phone's
    // Notify Me is kept as it was.
    final unread =
        edit.id != null &&
        (_container.read(hermesJobsProvider).value ?? const <HermesJob>[]).any(
          (j) => j.id == edit.id && !j.deliveryKnown,
        );
    final deliver = scheduling && !unread
        ? _deliverValue(
            edit.deliver == null
                ? null
                : hermesJobDeliverKeepingNotifyMe(
                    edit.deliver!,
                    notify: edit.id != null && await _notifiesConduit(edit.id!),
                  ),
          )
        : null;
    // Read on the connection the edit was made under.
    _check(scope);
    final catchUp = scheduling ? _catchUp(edit.catchUp) : null;
    // The job written, named in the answer: an editor left open saves to
    // it from then on rather than making another.
    final String? saved;
    if (edit.id == null) {
      final created = await _jobs.create(
        name: name,
        prompt: prompt,
        schedule: schedule,
        deliver: deliver,
        catchUp: catchUp ?? HermesJobCatchUp.hermesDefault,
      );
      saved = created?.id;
    } else {
      await _jobs.edit(
        edit.id!,
        name: name,
        prompt: prompt,
        schedule: schedule,
        deliver: deliver,
        catchUp: catchUp,
      );
      saved = edit.id;
    }
    // The list read next, and the notices it takes, are this connection's.
    _check(scope);
    _announce();
    return _jobsAfter(saved: saved);
  });

  /// Whether job [id] delivers to Conduit's push plugin: a phone's Notify
  /// Me, which an edit made here keeps.
  Future<bool> _notifiesConduit(String id) async {
    final listed =
        _container.read(hermesJobsProvider).value ??
        await readSettled<List<HermesJob>>(
          _container,
          hermesJobsProvider.future,
        ).catchError((Object _) => const <HermesJob>[]);
    final job = listed.where((j) => j.id == id).firstOrNull;
    return hermesDeliverIncludesConduit(job?.deliveryTarget);
  }

  /// [value]'s targets as Hermes stores them, or null when the edit leaves
  /// them alone.
  static String? _deliverValue(String? value) {
    if (value == null) return null;
    final joined = parseHermesDeliveryTargets(value).join(',');
    if (joined.length > kMaxHermesJobDeliverCharacters) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'field': 'deliver', 'reason': 'tooLong'},
        debugMessage: 'too many delivery targets',
      );
    }
    return joined;
  }

  Future<HermesJobs> setJobEnabled(HermesJobToggle toggle) =>
      _change(toggle.connection, (scope) async {
        await _jobs.setEnabled(toggle.id, toggle.enabled);
        _check(scope);
        _announce();
        return _jobsAfter();
      });

  /// Runs job [id] now. Hermes answers the trigger only once its run
  /// ends, so a run that started is reported running: the list follows it
  /// (and `hermes.changed` comes when it ends). A trigger Hermes refuses
  /// at once (a run already going) is refused here.
  Future<HermesJobs> runJob(String id, {String? connection}) =>
      _change(connection, (scope) async {
        if (_runPending.contains(id)) return _jobsAfter();
        final service = _container.read(hermesApiServiceProvider);
        if (service == null) return _jobsAfter();
        _runPending.add(id);
        final done = Completer<Object?>();
        unawaited(
          _jobs
              .runNow(id)
              .then<void>(
                (_) => done.complete(null),
                onError: (Object error, StackTrace _) => done.complete(error),
              ),
        );
        final early = await done.future.timeout(
          kHermesRunRefusalWindow,
          onTimeout: () => _stillRunning,
        );
        if (!identical(early, _stillRunning)) {
          // The pending mark is the next connection's once it is in use.
          _check(scope);
          _runPending.remove(id);
          if (early != null) throw early;
          _announce();
          return _jobsAfter();
        }
        unawaited(
          done.future.then((error) {
            if (!_current(scope)) return;
            _runPending.remove(id);
            if (error != null) {
              _notices.add(HermesJobNotice(jobId: id, kind: 'runFailed'));
            }
            _announce();
          }),
        );
        return _jobsAfter();
      });

  static final Object _stillRunning = Object();

  /// Stops job [id]'s running run. How it settles comes in the notices of
  /// a later list.
  Future<HermesJobs> stopJob(String id, {String? connection}) =>
      _change(connection, (scope) async {
        if (_stopping.containsKey(id)) return _jobsAfter();
        if (_stopUnsupported) {
          _notices.add(HermesJobNotice(jobId: id, kind: 'stopUnsupported'));
          return _jobsAfter();
        }
        _stopping[id] = null;
        try {
          final result = await _jobs.stopRun(id);
          // Settled after another connection came into use: what it found
          // is the last connection's, not the next one's to keep.
          _check(scope);
          if (result.beforeStart) {
            _stopping.remove(id);
            _runPending.remove(id);
            _notices.add(HermesJobNotice(jobId: id, kind: 'stopped'));
          } else if (!result.cancelled) {
            _stopping.remove(id);
            _notices.add(HermesJobNotice(jobId: id, kind: 'nothingToStop'));
          } else {
            _stopping[id] = result.executionId ?? '';
          }
        } on HermesJobStopUnsupportedException {
          _check(scope);
          _stopping.remove(id);
          _stopUnsupported = true;
          _notices.add(HermesJobNotice(jobId: id, kind: 'stopUnsupported'));
        } on Object {
          _check(scope);
          _stopping.remove(id);
          _notices.add(HermesJobNotice(jobId: id, kind: 'stopFailed'));
        }
        return _jobsAfter();
      });

  Future<HermesJobs> deleteJob(String id, {String? connection}) =>
      _change(connection, (scope) async {
        await _jobs.delete(id);
        _check(scope);
        _stopping.remove(id);
        _runPending.remove(id);
        _announce();
        return _jobsAfter();
      });

  /// The sessions job [id]'s runs wrote, newest first, each openable as a
  /// Hermes chat (a run's session is the scheduler's: it opens read-only,
  /// to continue here or in a copy).
  Future<HermesSessions> jobRuns(String id, {String? connection}) =>
      _bound(connection, (scope) async {
        final service = _container.read(hermesApiServiceProvider);
        if (service is! HermesDesktopApiService) return const HermesSessions();
        final generation = hermes?.serverGeneration;
        _container.invalidate(hermesJobRunsProvider(id));
        final runs = await readSettled(
          _container,
          hermesJobRunsProvider(id).future,
        );
        // Answered after the connection or the account's server changed: the
        // last server's runs, never told to the sessions kept for this one.
        if (generation != hermes?.serverGeneration) {
          throw const RpcError(
            code: ConduitErrorCodes.sessionExpired,
            debugMessage: 'the Hermes connection changed during the read',
          );
        }
        return HermesSessions(
          sessions: <HermesSessionDto>[
            for (final run in runs)
              hermes?.remember(run) ??
                  HermesSessionDto(
                    id: run.id,
                    chatId: hermesChatId(run.id),
                    title: run.title,
                    preview: run.preview,
                    updatedAtMs: run.updatedAt?.millisecondsSinceEpoch,
                    source: run.source,
                  ),
          ],
        );
      });

  // ---------------------------------------------------------------------------
  // Catalog
  // ---------------------------------------------------------------------------

  /// The agent's skills and toolsets, and the `/` commands a Hermes chat
  /// offers (the phone's skill prompts: none when the server says it has
  /// no skills).
  Future<HermesCatalog> catalog() => _bound(null, (scope) async {
    final service = _container.read(hermesApiServiceProvider);
    if (service == null) return const HermesCatalog();
    final skills = await service.listSkills().catchError(
      (Object _) => const <Map<String, dynamic>>[],
    );
    _container.invalidate(hermesToolsetsProvider);
    final toolsets = await readSettled(
      _container,
      hermesToolsetsProvider.future,
    ).catchError((Object _) => <HermesToolset>[]);
    final capabilities = await readSettled(
      _container,
      hermesCapabilitiesProvider.future,
    ).catchError((Object _) => hermesCapabilitiesFallback(service));
    final commands = <HermesSkillDto>[];
    if (capabilities.skills) {
      _container.invalidate(hermesSkillPromptsProvider);
      final prompts = await readSettled(
        _container,
        hermesSkillPromptsProvider.future,
      ).catchError((Object _) => <Prompt>[]);
      for (final prompt in prompts) {
        final name = prompt.command.replaceFirst(RegExp(r'^/'), '');
        if (name.isEmpty) continue;
        commands.add(
          HermesSkillDto(
            name: name,
            description: prompt.title.trim().isEmpty ? null : prompt.title,
          ),
        );
      }
    }
    return HermesCatalog(
      skills: <HermesSkillDto>[
        for (final skill in skills)
          if ((skill['name'] ?? skill['id'])?.toString() case final name?
              when name.trim().isNotEmpty)
            HermesSkillDto(
              name: name,
              description: skill['description']?.toString(),
            ),
      ],
      toolsets: <HermesToolsetDto>[
        for (final toolset in toolsets)
          HermesToolsetDto(
            name: toolset.name,
            label: toolset.label,
            description: toolset.description,
            enabled: toolset.enabled,
            tools: toolset.tools,
          ),
      ],
      commands: commands,
    );
  });

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  static String _modeName(HermesBackendMode mode) => switch (mode) {
    HermesBackendMode.responsesApi => 'responses',
    HermesBackendMode.desktopGateway => 'desktop',
  };

  static HermesBackendMode _mode(String name) => name == 'desktop'
      ? HermesBackendMode.desktopGateway
      : HermesBackendMode.responsesApi;

  static HermesDesktopAuthKind _authKind(String name) =>
      HermesDesktopAuthKind.values.where((k) => k.name == name).firstOrNull ??
      HermesDesktopAuthKind.legacyToken;

  static String _catchUpName(HermesJobCatchUp value) => switch (value) {
    HermesJobCatchUp.hermesDefault => 'default',
    HermesJobCatchUp.runOnce => 'runOnce',
    HermesJobCatchUp.skip => 'skip',
  };

  static HermesJobCatchUp? _catchUp(String? name) => switch (name) {
    null => null,
    'runOnce' => HermesJobCatchUp.runOnce,
    'skip' => HermesJobCatchUp.skip,
    _ => HermesJobCatchUp.hermesDefault,
  };

  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on RpcError {
      rethrow;
    } on StateError catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        retryable: true,
        debugMessage: error.message,
      );
    } on HermesDesktopHttpException catch (error) {
      throw RpcError(
        code: switch (error.status) {
          401 || 403 => ConduitErrorCodes.unauthorized,
          404 => ConduitErrorCodes.notFound,
          409 => ConduitErrorCodes.conflict,
          _ => ConduitErrorCodes.serverError,
        },
        args: <String, String>{
          'status': '${error.status}',
          'detail': ?error.detail,
        },
        debugMessage: 'Hermes request failed (${error.status})',
        retryable: error.status >= 500,
      );
    } on HermesDesktopRpcException catch (error) {
      throw RpcError(
        code: error.code == -32601
            ? ConduitErrorCodes.unsupported
            : ConduitErrorCodes.serverError,
        args: <String, String>{'detail': error.message},
        debugMessage: 'Hermes refused the request (${error.code})',
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw RpcError(
        code: switch (status) {
          401 || 403 => ConduitErrorCodes.unauthorized,
          404 => ConduitErrorCodes.notFound,
          409 => ConduitErrorCodes.conflict,
          null => ConduitErrorCodes.connectionFailed,
          _ => ConduitErrorCodes.serverError,
        },
        args: <String, String>{'status': '${status ?? ''}'},
        debugMessage: 'Hermes request failed ($status)',
        retryable: status == null || status >= 500,
      );
    }
  }
}

/// The capabilities a connection is assumed to have when it does not say
/// (the phone's optimistic default).
HermesCapabilities hermesCapabilitiesFallback(HermesBackendService service) =>
    service is HermesDesktopApiService
    ? HermesCapabilities.desktopCoreOnly
    : HermesCapabilities.enabledByDefault;

/// The connection a request is made under (`HermesAdminService._enter`):
/// its name and the configuration in use, read together.
typedef _Scope = ({String? connection, HermesConfig active});

/// [cadence] on the wire (null when core could not read the schedule).
HermesCadenceDto? hermesCadenceDto(HermesCadence? cadence) => switch (cadence) {
  null => null,
  final c => HermesCadenceDto(
    kind: switch (c.kind) {
      core_cadence.HermesCadenceKind.none => HermesCadenceKind.none,
      core_cadence.HermesCadenceKind.everyMinute =>
        HermesCadenceKind.everyMinute,
      core_cadence.HermesCadenceKind.everyMinutes =>
        HermesCadenceKind.everyMinutes,
      core_cadence.HermesCadenceKind.everyHour => HermesCadenceKind.everyHour,
      core_cadence.HermesCadenceKind.everyHours => HermesCadenceKind.everyHours,
      core_cadence.HermesCadenceKind.daily => HermesCadenceKind.daily,
      core_cadence.HermesCadenceKind.weekdays => HermesCadenceKind.weekdays,
      core_cadence.HermesCadenceKind.weekends => HermesCadenceKind.weekends,
      core_cadence.HermesCadenceKind.weekly => HermesCadenceKind.weekly,
      core_cadence.HermesCadenceKind.monthly => HermesCadenceKind.monthly,
    },
    every: c.every,
    hour: c.hour,
    minute: c.minute,
    weekday: c.weekday,
    day: c.day,
  ),
};
