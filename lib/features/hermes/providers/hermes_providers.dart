import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/prompt.dart';
import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/providers/app_providers.dart'
    show activeServerProvider, reviewerModeProvider;
import '../../../core/providers/storage_providers.dart';
import '../../../core/services/secure_credential_storage.dart';
import '../models/hermes_capabilities.dart';
import '../models/hermes_config.dart';
import '../models/hermes_job.dart';
import '../models/hermes_session.dart';
import '../models/hermes_toolset.dart';
import '../services/hermes_api_service.dart';

/// Owns the Hermes config: non-secret fields from shared preferences, secrets
/// from secure storage. Exposes setters that persist and update state.
class HermesConfigController extends Notifier<HermesConfig> {
  @override
  HermesConfig build() {
    final enabled =
        PreferencesStore.getBool(PreferenceKeys.hermesEnabled) ?? false;
    final baseUrl =
        PreferencesStore.getString(PreferenceKeys.hermesBaseUrl) ?? '';
    // Secrets load asynchronously and patch the state in once available.
    unawaited(_loadSecrets());
    return HermesConfig(enabled: enabled, baseUrl: baseUrl);
  }

  SecureCredentialStorage get _secure =>
      SecureCredentialStorage(instance: ref.read(secureStorageProvider));

  Future<void> _loadSecrets() async {
    final apiKey = await _secure.getHermesApiKey();
    final sessionKey = await _secure.getHermesSessionKey();
    state = HermesConfig(
      enabled: state.enabled,
      baseUrl: state.baseUrl,
      apiKey: apiKey,
      sessionKey: sessionKey,
    );
  }

  Future<void> setEnabled(bool value) async {
    await PreferencesStore.put(PreferenceKeys.hermesEnabled, value);
    state = _withState(enabled: value);
  }

  Future<void> setBaseUrl(String value) async {
    final trimmed = value.trim();
    await PreferencesStore.put(PreferenceKeys.hermesBaseUrl, trimmed);
    state = _withState(baseUrl: trimmed);
  }

  Future<void> setApiKey(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await _secure.deleteHermesApiKey();
    } else {
      await _secure.saveHermesApiKey(trimmed);
    }
    state = _withState(apiKey: trimmed.isEmpty ? null : trimmed);
  }

  Future<void> setSessionKey(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await _secure.deleteHermesSessionKey();
    } else {
      await _secure.saveHermesSessionKey(trimmed);
    }
    state = _withState(sessionKey: trimmed.isEmpty ? null : trimmed);
  }

  /// Returns the long-term memory session key, generating and persisting a
  /// stable one when the user has not set their own. Keeps Hermes memory
  /// associated with this install across restarts.
  Future<String> ensureSessionKey() async {
    final existing = state.sessionKey;
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = const Uuid().v4();
    await _secure.saveHermesSessionKey(generated);
    state = _withState(sessionKey: generated);
    return generated;
  }

  HermesConfig _withState({
    bool? enabled,
    String? baseUrl,
    String? apiKey = _keep,
    String? sessionKey = _keep,
  }) {
    return HermesConfig(
      enabled: enabled ?? state.enabled,
      baseUrl: baseUrl ?? state.baseUrl,
      apiKey: identical(apiKey, _keep) ? state.apiKey : apiKey,
      sessionKey: identical(sessionKey, _keep) ? state.sessionKey : sessionKey,
    );
  }

  // Sentinel so setters can distinguish "leave unchanged" from "clear to null".
  static const String _keep = '__hermes_keep__';
}

final hermesConfigProvider =
    NotifierProvider<HermesConfigController, HermesConfig>(
      HermesConfigController.new,
    );

/// Whether the Hermes agent is toggled on (regardless of whether it is fully
/// configured). Used to decide whether to surface the synthetic model.
final hermesEnabledProvider = Provider<bool>(
  (ref) => ref.watch(hermesConfigProvider).enabled,
);

/// True when the app is running as a Hermes-only client: Hermes is fully
/// configured AND there is no OpenWebUI server. Drives UI gating (hide OWUI
/// tabs/affordances, make Hermes home). Reviewer mode takes precedence.
final hermesOnlyModeProvider = Provider<bool>((ref) {
  if (ref.watch(reviewerModeProvider)) return false;
  if (!ref.watch(hermesConfigProvider).isUsable) return false;
  final activeServer = ref.watch(activeServerProvider).asData?.value;
  return activeServer == null;
});

/// The Hermes client, or null when Hermes is disabled / not fully configured.
final hermesApiServiceProvider = Provider<HermesApiService?>((ref) {
  final config = ref.watch(hermesConfigProvider);
  if (!config.isUsable) return null;
  final service = HermesApiService(config: config);
  ref.onDispose(service.close);
  return service;
});

/// The Hermes agent's skills mapped to [Prompt]s so they can drive the existing
/// `/` slash-command overlay. Selecting one inserts `/skill-name ` into the
/// composer, which the agent interprets natively. Empty when Hermes is off.
final hermesSkillPromptsProvider = FutureProvider<List<Prompt>>((ref) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return const [];
  final skills = await service.listSkills();
  final prompts = <Prompt>[];
  for (final skill in skills) {
    final name = (skill['name'] ?? '').toString().trim();
    if (name.isEmpty) continue;
    final description = (skill['description'] ?? '').toString().trim();
    prompts.add(
      Prompt(command: '/$name', title: description, content: '/$name '),
    );
  }
  return prompts;
});

/// The Hermes server-side session bound to the current chat, or null for a
/// fresh chat with no session yet. Created lazily on the first Hermes turn and
/// reused for follow-ups; cleared on "new chat"; set when opening a session
/// from the sessions browser.
class HermesActiveSession extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? sessionId) => state = sessionId;
}

final hermesActiveSessionProvider =
    NotifierProvider<HermesActiveSession, String?>(HermesActiveSession.new);

/// The user's Hermes sessions (server-side transcripts), newest first.
class HermesSessionsController
    extends AsyncNotifier<List<HermesSessionSummary>> {
  @override
  Future<List<HermesSessionSummary>> build() async {
    final service = ref.watch(hermesApiServiceProvider);
    if (service == null) return const [];
    final raw = await service.listSessions();
    final sessions = <HermesSessionSummary>[];
    for (final item in raw) {
      final summary = HermesSessionSummary.fromJson(item);
      if (summary != null) sessions.add(summary);
    }
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    sessions.sort(
      (a, b) => (b.updatedAt ?? epoch).compareTo(a.updatedAt ?? epoch),
    );
    return sessions;
  }

  HermesApiService? get _service => ref.read(hermesApiServiceProvider);

  /// Forks a session and returns the new session id (null if Hermes is off).
  Future<String?> fork(String id) async {
    final service = _service;
    if (service == null) return null;
    final newId = await service.forkSession(id);
    ref.invalidateSelf();
    return newId;
  }

  Future<void> rename(String id, String title) async {
    final service = _service;
    if (service == null) return;
    await service.renameSession(id, title);
    ref.invalidateSelf();
  }

  Future<void> delete(String id) async {
    final service = _service;
    if (service == null) return;
    await service.deleteSession(id);
    ref.invalidateSelf();
  }
}

final hermesSessionsProvider =
    AsyncNotifierProvider<HermesSessionsController, List<HermesSessionSummary>>(
      HermesSessionsController.new,
    );

/// Server-advertised capabilities (`/v1/capabilities`). Falls back to the
/// optimistic all-enabled default when discovery fails, so features are only
/// hidden when the server explicitly says they're unsupported.
final hermesCapabilitiesProvider = FutureProvider<HermesCapabilities>((
  ref,
) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return HermesCapabilities.enabledByDefault;
  try {
    return HermesCapabilities.fromJson(await service.getCapabilities());
  } catch (_) {
    return HermesCapabilities.enabledByDefault;
  }
});

/// Synchronous best-effort view of capabilities for gating UI (optimistic
/// default while loading / on error).
HermesCapabilities hermesCapabilitiesNow(Ref ref) {
  return ref.read(hermesCapabilitiesProvider).asData?.value ??
      HermesCapabilities.enabledByDefault;
}

/// Resolved toolsets for the api_server platform (`/v1/toolsets`).
final hermesToolsetsProvider = FutureProvider<List<HermesToolset>>((ref) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return const [];
  final raw = await service.listToolsets();
  final toolsets = <HermesToolset>[];
  for (final item in raw) {
    final toolset = HermesToolset.fromJson(item);
    if (toolset != null) toolsets.add(toolset);
  }
  return toolsets;
});

/// Extended server status (`/health/detailed`): active sessions, running
/// agents, resource usage. Empty map when unavailable.
final hermesServerStatusProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return const {};
  return service.healthDetailed();
});

/// The user's scheduled Hermes jobs (`/api/jobs`).
class HermesJobsController extends AsyncNotifier<List<HermesJob>> {
  @override
  Future<List<HermesJob>> build() async {
    final service = ref.watch(hermesApiServiceProvider);
    if (service == null) return const [];
    final raw = await service.listJobs();
    final jobs = <HermesJob>[];
    for (final item in raw) {
      final job = HermesJob.fromJson(item);
      if (job != null) jobs.add(job);
    }
    return jobs;
  }

  HermesApiService? get _service => ref.read(hermesApiServiceProvider);

  Future<void> create({
    required String prompt,
    required String schedule,
  }) async {
    final service = _service;
    if (service == null) return;
    await service.createJob(prompt: prompt, schedule: schedule);
    ref.invalidateSelf();
  }

  Future<void> edit(
    String id, {
    String? prompt,
    String? schedule,
  }) async {
    final service = _service;
    if (service == null) return;
    await service.updateJob(id, prompt: prompt, schedule: schedule);
    ref.invalidateSelf();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final service = _service;
    if (service == null) return;
    if (enabled) {
      await service.resumeJob(id);
    } else {
      await service.pauseJob(id);
    }
    ref.invalidateSelf();
  }

  Future<void> runNow(String id) async {
    await _service?.runJob(id);
  }

  Future<void> delete(String id) async {
    final service = _service;
    if (service == null) return;
    await service.deleteJob(id);
    ref.invalidateSelf();
  }
}

final hermesJobsProvider =
    AsyncNotifierProvider<HermesJobsController, List<HermesJob>>(
      HermesJobsController.new,
    );

/// Persisted expand/collapse state for the "Scheduled Agents" section in the
/// Hermes sidebar tab (default expanded).
class HermesJobsSectionExpanded extends Notifier<bool> {
  @override
  bool build() =>
      PreferencesStore.getBool(PreferenceKeys.hermesShowJobs) ?? true;

  void toggle() {
    state = !state;
    PreferencesStore.put(PreferenceKeys.hermesShowJobs, state);
  }
}

final hermesJobsSectionExpandedProvider =
    NotifierProvider<HermesJobsSectionExpanded, bool>(
      HermesJobsSectionExpanded.new,
    );

/// Tracks the live event subscription + run id for each streaming Hermes
/// assistant message so a stop request can cancel the right run.
class HermesRunRegistry {
  final Map<String, _ActiveRun> _runs = {};

  void register(
    String assistantMessageId, {
    required String runId,
    required CancelToken cancelToken,
    required StreamSubscription<void> subscription,
  }) {
    _runs[assistantMessageId] = _ActiveRun(
      runId: runId,
      cancelToken: cancelToken,
      subscription: subscription,
    );
  }

  String? runIdFor(String assistantMessageId) =>
      _runs[assistantMessageId]?.runId;

  /// Cancels and forgets the run for [assistantMessageId], returning its run id
  /// (so the caller can POST `/stop`).
  String? cancel(String assistantMessageId) {
    final run = _runs.remove(assistantMessageId);
    if (run == null) return null;
    run.cancelToken.cancel('stopped');
    unawaited(run.subscription.cancel());
    return run.runId;
  }

  void complete(String assistantMessageId) {
    _runs.remove(assistantMessageId);
  }
}

class _ActiveRun {
  _ActiveRun({
    required this.runId,
    required this.cancelToken,
    required this.subscription,
  });

  final String runId;
  final CancelToken cancelToken;
  final StreamSubscription<void> subscription;
}

final hermesRunRegistryProvider = Provider<HermesRunRegistry>(
  (ref) => HermesRunRegistry(),
);
