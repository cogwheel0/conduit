import 'dart:async';

import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_form.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart'
    hide HermesDeliveryOptions;
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart'
    as delivery
    show HermesDeliveryOptions;
import 'package:conduit_core/features/hermes/models/hermes_toolset.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart'
    show HermesDesktopRpcException;
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_validation.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'hermes_service.dart';
import 'settled.dart';

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
  HermesAdminService(this._container, {EventBus? events, this.hermes})
    : _events = events {
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

  /// Hermes's sessions, told of the sessions a job's runs wrote so they
  /// open as any other.
  final HermesService? hermes;
  ProviderSubscription<HermesBackendService?>? _serviceWatch;

  void dispose() => _serviceWatch?.close();

  HermesConfigController get _config =>
      _container.read(hermesConfigProvider.notifier);

  void _announce() => _events?.emit(ConduitEventSpecs.hermesChanged, null);

  void _forgetConnection() {
    _stopping.clear();
    _runPending.clear();
    _notices.clear();
    _stopUnsupported = false;
    _deliveryOptions = null;
    _mcpTools.clear();
  }

  // ---------------------------------------------------------------------------
  // Connections
  // ---------------------------------------------------------------------------

  /// Hermes's switch and every saved connection, the one in use marked.
  Future<HermesConnections> connections({String? savedId}) async {
    await _config.waitForSecretsHydration();
    final active = _container.read(hermesConfigProvider);
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
      rows.add(_connectionDto(profile, config, active: isActive));
    }
    return HermesConnections(
      enabled: active.enabled,
      activeId: active.connectionId,
      connections: rows,
      canAdd: profiles.length < kMaxHermesConnections,
      savedId: savedId,
    );
  }

  static HermesConnectionDto _connectionDto(
    HermesConnectionProfile profile,
    HermesConfig? config, {
    required bool active,
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
      legacyToken: edit.legacyToken ?? '',
      desktopCredentialsDirty: edit.legacyToken != null,
      initialAccessHeaders: saved.accessHeaders,
      accessHeaders: saved.accessHeaders,
    );
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
      if (reason == 'plainHttpConsent') rethrow;
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

  Future<HermesMcpServers> mcpServers() => _guard(() async {
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

  Future<HermesMcpCatalog> mcpCatalog() => _guard(() async {
    final entries = await _gatewayService().mcpCatalog();
    return HermesMcpCatalog(
      entries: <HermesMcpCatalogEntryDto>[
        for (final entry in entries)
          HermesMcpCatalogEntryDto(
            name: entry.name,
            description: entry.description,
          ),
      ],
    );
  });

  Future<HermesMcpServers> addMcp(HermesMcpAdd add) => _guard(() async {
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
    return mcpServers();
  });

  Future<HermesMcpServers> addMcpFromCatalog(String name) => _guard(() async {
    // The catalog's entry by name, added as it stands: a server that needs
    // credentials is not asked for them here yet, and the dashboard's refusal
    // of an incomplete install comes back as the error.
    final service = _gatewayService();
    final entry = (await service.mcpCatalog())
        .where((e) => e.name == name)
        .firstOrNull;
    if (entry == null) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'no MCP catalog entry named $name',
      );
    }
    await service.addMcpCatalogEntry(entry);
    return mcpServers();
  });

  Future<HermesMcpServers> setMcpApiKey(HermesMcpApiKey request) =>
      _guard(() async {
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
        return mcpServers();
      });

  Future<HermesMcpServers> removeMcp(String name) => _guard(() async {
    await _gatewayService().removeMcpServer(name);
    _mcpTools.remove(name);
    return mcpServers();
  });

  Future<HermesMcpTestResultDto> testMcp(String name) => _guard(() async {
    final result = await _gatewayService().testMcpServer(name);
    if (result.toolNames.isNotEmpty) _mcpTools[name] = result.toolNames;
    return HermesMcpTestResultDto(
      ok: result.ok,
      tools: result.tools,
      resources: result.resources,
      prompts: result.prompts,
      error: result.error,
      toolNames: result.toolNames,
    );
  });

  Future<HermesMcpServers> setMcpEnabled(HermesMcpToggle toggle) => _guard(
    () async {
      await _gatewayService().setMcpServerEnabled(toggle.name, toggle.enabled);
      return mcpServers();
    },
  );

  /// OAuth in the browser (the window opens the page): answers once it is
  /// done, or refuses when it failed or timed out.
  Future<HermesMcpServers> authenticateMcp(String name) => _guard(() async {
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
    return mcpServers();
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
  Future<HermesJobs> jobs() => _guard(() async {
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
    _settleStops(list);
    final capabilities = await readSettled(
      _container,
      hermesCapabilitiesProvider.future,
    ).catchError((Object _) => hermesCapabilitiesFallback(service));
    final scheduling = service is HermesDesktopApiService;
    final options = scheduling ? await _cachedDeliveryOptions(service) : null;
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
      enabled: job.enabled,
      lastStatus: job.lastStatus,
      lastError: job.lastError,
      lastRunAtMs: job.lastRun?.millisecondsSinceEpoch,
      nextRunAtMs: job.nextRun?.millisecondsSinceEpoch,
      state: job.state,
      deliver: <HermesDeliveryTargetDto>[
        for (final target in parseHermesDeliveryTargets(job.deliveryTarget))
          _target(
            options?.optionFor(target) ?? describeHermesDeliveryTarget(target),
          ),
      ],
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
  Future<HermesDeliveryOptions> deliveryOptions() => _guard(() async {
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
          _target(option),
      ],
    );
  });

  Future<HermesJobs> saveJob(HermesJobEdit edit) => _guard(() async {
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
    final deliver = scheduling ? _deliverValue(edit.deliver) : null;
    final catchUp = scheduling ? _catchUp(edit.catchUp) : null;
    if (edit.id == null) {
      await _jobs.create(
        name: name,
        prompt: prompt,
        schedule: schedule,
        deliver: deliver,
        catchUp: catchUp ?? HermesJobCatchUp.hermesDefault,
      );
    } else {
      await _jobs.edit(
        edit.id!,
        name: name,
        prompt: prompt,
        schedule: schedule,
        deliver: deliver,
        catchUp: catchUp,
      );
    }
    _announce();
    return jobs();
  });

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

  Future<HermesJobs> setJobEnabled(HermesJobToggle toggle) => _guard(() async {
    await _jobs.setEnabled(toggle.id, toggle.enabled);
    _announce();
    return jobs();
  });

  /// Runs job [id] now. Hermes answers the trigger only once its run
  /// ends, so a run that started is reported running: the list follows it
  /// (and `hermes.changed` comes when it ends). A trigger Hermes refuses
  /// at once (a run already going) is refused here.
  Future<HermesJobs> runJob(String id) => _guard(() async {
    if (_runPending.contains(id)) return jobs();
    final service = _container.read(hermesApiServiceProvider);
    if (service == null) return jobs();
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
      _runPending.remove(id);
      if (early != null) throw early;
      _announce();
      return jobs();
    }
    unawaited(
      done.future.then((error) {
        if (!identical(_container.read(hermesApiServiceProvider), service)) {
          return;
        }
        _runPending.remove(id);
        if (error != null) {
          _notices.add(HermesJobNotice(jobId: id, kind: 'runFailed'));
        }
        _announce();
      }),
    );
    return jobs();
  });

  static final Object _stillRunning = Object();

  /// Stops job [id]'s running run. How it settles comes in the notices of
  /// a later list.
  Future<HermesJobs> stopJob(String id) => _guard(() async {
    if (_stopping.containsKey(id)) return jobs();
    if (_stopUnsupported) {
      _notices.add(HermesJobNotice(jobId: id, kind: 'stopUnsupported'));
      return jobs();
    }
    _stopping[id] = null;
    try {
      final result = await _jobs.stopRun(id);
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
      _stopping.remove(id);
      _stopUnsupported = true;
      _notices.add(HermesJobNotice(jobId: id, kind: 'stopUnsupported'));
    } on Object {
      _stopping.remove(id);
      _notices.add(HermesJobNotice(jobId: id, kind: 'stopFailed'));
    }
    return jobs();
  });

  Future<HermesJobs> deleteJob(String id) => _guard(() async {
    await _jobs.delete(id);
    _stopping.remove(id);
    _runPending.remove(id);
    _announce();
    return jobs();
  });

  /// The sessions job [id]'s runs wrote, newest first, each openable as a
  /// Hermes chat (a run's session is the scheduler's: it opens read-only,
  /// to continue here or in a copy).
  Future<HermesSessions> jobRuns(String id) => _guard(() async {
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
  Future<HermesCatalog> catalog() => _guard(() async {
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
