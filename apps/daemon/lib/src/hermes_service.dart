import 'dart:async';

import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_toolset.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_connection_coordinator.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';

/// The chat id a Hermes session opens as, the same one mobile uses.
String hermesChatId(String sessionId) => 'local:hermes_$sessionId';

/// The session behind a Hermes chat id, or null for any other chat.
String? hermesSessionOf(String chatId) =>
    chatId.startsWith('local:hermes_') && chatId.length > 'local:hermes_'.length
    ? chatId.substring('local:hermes_'.length)
    : null;

/// Implements `hermes.*` over the core's Hermes providers.
///
/// The connection, its secrets and every session action go through the
/// providers mobile uses -- which check that the connection did not change
/// under an action, and forget a session's document trust before deleting
/// it -- so the daemon adds nothing to what they already guard.
final class HermesService {
  HermesService(this._container, {EventBus? events}) : _events = events;

  final ProviderContainer _container;
  final EventBus? _events;

  HermesConfigController get _config =>
      _container.read(hermesConfigProvider.notifier);

  void _announce() => _events?.publish(ConduitEvents.hermesChanged);

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  Future<HermesSettings> settings() async {
    await _config.waitForSecretsHydration();
    final config = _container.read(hermesConfigProvider);
    return HermesSettings(
      enabled: config.enabled,
      baseUrl: config.baseUrl,
      mode: _modeName(config.mode),
      hasApiKey: config.apiKey?.trim().isNotEmpty ?? false,
      hasSessionKey: config.sessionKey?.trim().isNotEmpty ?? false,
      desktopProfile: config.desktopProfile,
      desktopAuthKind: config.desktopAuthKind.name,
      desktopSignedIn: config.desktopCredentials?.nativeTokens != null,
      allowSelfSignedCertificates: config.allowSelfSignedCertificates,
      usable: config.isUsable,
    );
  }

  Future<HermesSettings> saveSettings(HermesSettingsEdit edit) async {
    await _config.waitForSecretsHydration();
    try {
      await _config.saveConnection(
        baseUrl: edit.baseUrl,
        mode: _mode(edit.mode),
        desktopAuthKind: _authKind(edit.desktopAuthKind),
        desktopProfile: edit.desktopProfile,
        allowSelfSignedCertificates: edit.allowSelfSignedCertificates,
        apiKeyChanged: edit.apiKey != null,
        apiKey: _blankIsNull(edit.apiKey),
        sessionKeyChanged: edit.sessionKey != null,
        sessionKey: _blankIsNull(edit.sessionKey),
      );
      await _config.setEnabled(edit.enabled);
    } on ArgumentError catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: '${error.message}',
      );
    }
    _announce();
    return settings();
  }

  /// Tries [edit] without saving it, as the settings form's Test does.
  Future<HermesTestResult> test(HermesSettingsEdit edit) async {
    await _config.waitForSecretsHydration();
    final saved = _container.read(hermesConfigProvider);
    // A secret left blank in the form means the saved one, when the form
    // is about the same server.
    final sameServer =
        HermesConfig.connectionEndpoint(saved.baseUrl) ==
        HermesConfig.connectionEndpoint(edit.baseUrl);
    final draft = saved.copyWith(
      enabled: true,
      baseUrl: edit.baseUrl.trim(),
      mode: _mode(edit.mode),
      desktopProfile: edit.desktopProfile,
      desktopAuthKind: _authKind(edit.desktopAuthKind),
      allowSelfSignedCertificates: edit.allowSelfSignedCertificates,
      apiKey: edit.apiKey ?? (sameServer ? saved.apiKey : null),
    );
    if (HermesConfig.connectionOrigin(draft.baseUrl) == null) {
      return const HermesTestResult(reason: 'invalid');
    }
    try {
      if (draft.mode == HermesBackendMode.desktopGateway) {
        final service = HermesDesktopApiService(config: draft);
        try {
          await service.statusProbe(refresh: true);
        } finally {
          service.close();
        }
        return const HermesTestResult(ok: true);
      }
      final ok = await testHermesDraftConnection(draft);
      return HermesTestResult(ok: ok, reason: ok ? null : 'unreachable');
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      return HermesTestResult(
        reason: status == 401 || status == 403 ? 'unauthorized' : 'unreachable',
      );
    } on Object {
      return const HermesTestResult(reason: 'unreachable');
    }
  }

  Future<HermesStatus> status() async {
    await _config.waitForSecretsHydration();
    final config = _container.read(hermesConfigProvider);
    final service = _container.read(hermesApiServiceProvider);
    if (!config.isUsable || service == null) {
      return HermesStatus(configured: config.isUsable);
    }
    final reachable = await service.health().catchError((Object _) => false);
    final capabilities = await readSettled(
      _container,
      hermesCapabilitiesProvider.future,
    ).catchError((Object _) => HermesCapabilities.enabledByDefault);
    final details = reachable
        ? await service.healthDetailed().catchError(
            (Object _) => const <String, dynamic>{},
          )
        : const <String, dynamic>{};
    return HermesStatus(
      configured: true,
      reachable: reachable,
      capabilities: HermesCapabilitiesDto(
        runApproval: capabilities.runApproval,
        skills: capabilities.skills,
        toolsets: capabilities.toolsets,
        jobs: capabilities.jobs,
        jobsAdmin: capabilities.jobsAdmin,
        sessions: capabilities.sessions,
        inputImages: capabilities.inputImages,
        inputFiles: capabilities.inputFiles,
      ),
      details: details,
    );
  }

  /// Signs in to a desktop gateway with native PKCE: the gateway's page
  /// opens in the system browser, and the tokens it gives back are kept
  /// with the other Hermes secrets.
  Future<HermesSettings> signIn() async {
    final service = _container.read(hermesApiServiceProvider);
    if (service is! HermesDesktopApiService) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'save a desktop-gateway connection first',
      );
    }
    try {
      await const HermesDesktopConnectionCoordinator().signInNative(
        _container.read(hermesConfigProvider),
        service: service,
        onCredentialsChanged: (credentials) =>
            _config.setDesktopNativeTokens(credentials.nativeTokens),
      );
    } on DioException catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.unauthorized,
        debugMessage: 'Hermes sign-in failed (${error.response?.statusCode})',
      );
    }
    _announce();
    return settings();
  }

  Future<HermesSettings> signOut() async {
    await _config.signOutDesktop();
    _announce();
    return settings();
  }

  // ---------------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------------

  Future<HermesSessions> sessions() => _guard(() async {
    if (_container.read(hermesApiServiceProvider) == null) {
      return const HermesSessions();
    }
    _container.invalidate(hermesSessionsProvider);
    final sessions = await readSettled(
      _container,
      hermesSessionsProvider.future,
    );
    return HermesSessions(
      sessions: <HermesSessionDto>[
        for (final session in sessions)
          HermesSessionDto(
            id: session.id,
            chatId: hermesChatId(session.id),
            title: session.title,
            preview: session.preview,
            updatedAtMs: session.updatedAt?.millisecondsSinceEpoch,
          ),
      ],
    );
  });

  Future<HermesSessions> rename(HermesRename request) => _guard(() async {
    await _sessions().rename(request.id, request.title.trim());
    _announce();
    return sessions();
  });

  Future<HermesSessions> delete(String id) => _guard(() async {
    final deleted = await _sessions().delete(id);
    _transcripts.remove(id);
    if (!deleted) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        retryable: true,
        debugMessage: 'the Hermes connection changed; try again',
      );
    }
    _announce();
    return sessions();
  });

  /// A copy of a session to go on from; answers with the copy.
  Future<HermesSessionDto> fork(String id) => _guard(() async {
    final forked = await _sessions().fork(id);
    if (forked == null) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'the session could not be forked',
      );
    }
    _announce();
    final all = await sessions();
    return all.sessions.firstWhere(
      (s) => s.id == forked,
      orElse: () => HermesSessionDto(id: forked, chatId: hermesChatId(forked)),
    );
  });

  HermesSessionsController _sessions() =>
      _container.read(hermesSessionsProvider.notifier);

  // ---------------------------------------------------------------------------
  // Transcripts
  // ---------------------------------------------------------------------------

  /// Each open session's messages: read from Hermes once, then kept as
  /// turns add to them. Hermes is where they are stored; this is what the
  /// window is shown between reads.
  final Map<String, List<ChatMessage>> _transcripts =
      <String, List<ChatMessage>>{};

  Future<List<ChatMessage>> transcript(
    String sessionId, {
    bool reload = false,
  }) async {
    final cached = _transcripts[sessionId];
    if (cached != null && !reload) return List<ChatMessage>.of(cached);
    final service = _container.read(hermesApiServiceProvider);
    if (service == null) return const <ChatMessage>[];
    final raw = await _guard(() => service.getSessionMessages(sessionId));
    final messages = hermesMessagesToChatMessages(
      raw,
      modelId: kHermesDefaultModelId,
    );
    _transcripts[sessionId] = messages;
    return List<ChatMessage>.of(messages);
  }

  void append(String sessionId, ChatMessage message) =>
      (_transcripts[sessionId] ??= <ChatMessage>[]).add(message);

  /// The session's title as the list has it, for a chat header.
  Future<String?> titleOf(String sessionId) async {
    final sessions = _container.read(hermesSessionsProvider).value;
    return sessions?.where((s) => s.id == sessionId).firstOrNull?.title;
  }

  void announceSessions() {
    _container.invalidate(hermesSessionsProvider);
    _announce();
  }

  // ---------------------------------------------------------------------------
  // Jobs and catalog
  // ---------------------------------------------------------------------------

  Future<HermesJobs> jobs() => _guard(() async {
    if (_container.read(hermesApiServiceProvider) == null) {
      return const HermesJobs();
    }
    _container.invalidate(hermesJobsProvider);
    final jobs = await readSettled(_container, hermesJobsProvider.future);
    return HermesJobs(jobs: jobs.map(_job).toList(growable: false));
  });

  Future<HermesJobs> saveJob(HermesJobEdit edit) => _guard(() async {
    final prompt = edit.prompt.trim();
    final schedule = edit.schedule.trim();
    if (prompt.isEmpty || schedule.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a job needs a prompt and a schedule',
      );
    }
    final name = edit.name?.trim();
    final jobs = _container.read(hermesJobsProvider.notifier);
    if (edit.id == null) {
      await jobs.create(
        name: name == null || name.isEmpty ? prompt : name,
        prompt: prompt,
        schedule: schedule,
      );
    } else {
      await jobs.edit(edit.id!, name: name, prompt: prompt, schedule: schedule);
    }
    _announce();
    return this.jobs();
  });

  Future<HermesJobs> setJobEnabled(HermesJobToggle toggle) => _guard(() async {
    await _container
        .read(hermesJobsProvider.notifier)
        .setEnabled(toggle.id, toggle.enabled);
    _announce();
    return jobs();
  });

  Future<HermesJobs> runJob(String id) => _guard(() async {
    await _container.read(hermesJobsProvider.notifier).runNow(id);
    return jobs();
  });

  Future<HermesJobs> deleteJob(String id) => _guard(() async {
    await _container.read(hermesJobsProvider.notifier).delete(id);
    _announce();
    return jobs();
  });

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
    );
  });

  static HermesJobDto _job(HermesJob job) => HermesJobDto(
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
  );

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

  static String? _blankIsNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

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
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw RpcError(
        code: switch (status) {
          401 || 403 => ConduitErrorCodes.unauthorized,
          404 => ConduitErrorCodes.notFound,
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
