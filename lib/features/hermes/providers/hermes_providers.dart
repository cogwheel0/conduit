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
  Future<void> _mutationQueue = Future<void>.value();
  Future<void>? _secretsHydration;
  Future<String>? _sessionKeyFuture;
  int _secretLoadEpoch = 0;

  @override
  HermesConfig build() {
    final enabled =
        PreferencesStore.getBool(PreferenceKeys.hermesEnabled) ?? false;
    final baseUrl =
        PreferencesStore.getString(PreferenceKeys.hermesBaseUrl) ?? '';
    // Secrets load asynchronously and patch the state in once available.
    final epoch = ++_secretLoadEpoch;
    final hydration = _loadSecrets(epoch);
    _secretsHydration = hydration;
    unawaited(hydration);
    return HermesConfig(enabled: enabled, baseUrl: baseUrl);
  }

  SecureCredentialStorage get _secure =>
      SecureCredentialStorage(instance: ref.read(secureStorageProvider));

  Future<void> _loadSecrets(int epoch) async {
    try {
      final apiKey = await _secure.getHermesApiKey();
      final sessionKey = await _secure.getHermesSessionKey();
      if (epoch != _secretLoadEpoch || !ref.mounted) return;
      ref.read(hermesSecretsErrorProvider.notifier).clear();
      state = HermesConfig(
        enabled: state.enabled,
        baseUrl: state.baseUrl,
        apiKey: apiKey,
        sessionKey: sessionKey,
      );
    } catch (error) {
      if (epoch != _secretLoadEpoch || !ref.mounted) return;
      // Missing secrets are represented by successful null reads. A thrown
      // keychain/keystore failure is materially different: preserve it so the
      // UI can explain the outage and offer a retry instead of pretending the
      // user never configured Hermes.
      ref.read(hermesSecretsErrorProvider.notifier).set(error);
    } finally {
      if (epoch == _secretLoadEpoch && ref.mounted) {
        ref.read(hermesSecretsLoadingProvider.notifier).set(false);
      }
    }
  }

  Future<void> retrySecrets() {
    final epoch = ++_secretLoadEpoch;
    ref.read(hermesSecretsErrorProvider.notifier).clear();
    ref.read(hermesSecretsLoadingProvider.notifier).set(true);
    final hydration = _loadSecrets(epoch);
    _secretsHydration = hydration;
    return hydration;
  }

  Future<void> setEnabled(bool value) async {
    await _serializeMutation(() async {
      if (state.enabled && !value) {
        await _stopActiveRuns();
      }
      await PreferencesStore.put(PreferenceKeys.hermesEnabled, value);
      state = _withState(enabled: value);
    });
  }

  Future<void> setBaseUrl(String value) async {
    await saveConnection(baseUrl: value);
  }

  Future<void> setApiKey(String value) async {
    await saveConnection(
      baseUrl: state.baseUrl,
      apiKeyChanged: true,
      apiKey: value,
    );
  }

  Future<void> setSessionKey(String value) async {
    await saveConnection(
      baseUrl: state.baseUrl,
      sessionKeyChanged: true,
      sessionKey: value,
    );
  }

  /// Atomically commits connection edits. Secrets are retained only when the
  /// normalized origin (scheme + host + port) is unchanged.
  Future<void> saveConnection({
    required String baseUrl,
    bool apiKeyChanged = false,
    String? apiKey,
    bool sessionKeyChanged = false,
    String? sessionKey,
  }) {
    final trimmedUrl = baseUrl.trim();
    final nextOrigin = connectionOrigin(trimmedUrl);
    if (trimmedUrl.isNotEmpty && nextOrigin == null) {
      return Future<void>.error(
        ArgumentError.value(baseUrl, 'baseUrl', 'Use a valid http(s) URL'),
      );
    }

    return _serializeMutation(() async {
      // Resolve the one cold-start read before applying edits. This prevents a
      // same-origin save from accidentally replacing not-yet-hydrated secrets
      // with null, while the serialized queue prevents write reordering.
      await _secretsHydration;
      _throwIfSecretsUnavailable();
      final originChanged = connectionOrigin(state.baseUrl) != nextOrigin;
      final endpointChanged =
          connectionEndpoint(state.baseUrl) != connectionEndpoint(trimmedUrl);
      final identityChanged = apiKeyChanged || sessionKeyChanged;
      final serviceWillRotate = state.baseUrl != trimmedUrl || identityChanged;
      var nextApiKey = state.apiKey;
      var nextSessionKey = state.sessionKey;

      if (serviceWillRotate) {
        // Active runs retain the service that created them. Stop them through
        // that owner before changing config, because the state update below
        // disposes the old HermesApiService provider instance.
        await _stopActiveRuns();
      }
      if (endpointChanged || identityChanged) {
        // Endpoint and secret changes can switch servers, accounts, or memory
        // principals. Never carry the old server-side session across them.
        ref.read(hermesActiveSessionProvider.notifier).set(null);
      }

      if (originChanged) {
        await _secure.deleteHermesApiKey();
        await _secure.deleteHermesSessionKey();
        nextApiKey = null;
        nextSessionKey = null;
      }

      if (apiKeyChanged) {
        final value = apiKey?.trim() ?? '';
        if (value.isEmpty) {
          await _secure.deleteHermesApiKey();
          nextApiKey = null;
        } else {
          await _secure.saveHermesApiKey(value);
          nextApiKey = value;
        }
      }

      if (sessionKeyChanged) {
        final value = sessionKey?.trim() ?? '';
        if (value.isEmpty) {
          await _secure.deleteHermesSessionKey();
          nextSessionKey = null;
        } else {
          await _secure.saveHermesSessionKey(value);
          nextSessionKey = value;
        }
      }

      await PreferencesStore.put(PreferenceKeys.hermesBaseUrl, trimmedUrl);
      state = HermesConfig(
        enabled: state.enabled,
        baseUrl: trimmedUrl,
        apiKey: nextApiKey,
        sessionKey: nextSessionKey,
      );
    });
  }

  Future<void> _serializeMutation(Future<void> Function() operation) {
    // Keep the caller-visible result separate from the internal queue tail. The
    // result must preserve this operation's error, while the tail must always
    // settle successfully so one failed secure-storage/preferences write cannot
    // prevent every later mutation from running.
    final result = _mutationQueue.then<void>(
      (_) => operation(),
      // Defensive recovery if an older implementation or unexpected callback
      // ever left the internal tail in an error state.
      onError: (Object _, StackTrace _) => operation(),
    );
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _stopActiveRuns() async {
    final stopFutures = ref.read(hermesRunRegistryProvider).cancelAll();
    await Future.wait<void>([
      for (final stop in stopFutures) stop.catchError((_) {}),
    ]);
  }

  /// Canonical origin used to bind secrets to their intended server.
  static String? connectionOrigin(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:$port';
  }

  /// Canonical request root used to detect when the currently configured
  /// Hermes endpoint changes. `/v1` and a trailing slash are equivalent because
  /// [HermesApiService] strips them before composing request paths.
  static String? connectionEndpoint(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.endsWith('/v1')) {
      normalized = normalized.substring(0, normalized.length - '/v1'.length);
    }

    final uri = Uri.tryParse(normalized);
    final origin = connectionOrigin(normalized);
    if (uri == null || origin == null) return null;
    return '$origin${uri.path}'
        '${uri.hasQuery ? '?${uri.query}' : ''}'
        '${uri.hasFragment ? '#${uri.fragment}' : ''}';
  }

  /// Returns the long-term memory session key, generating and persisting a
  /// stable one when the user has not set their own. Keeps Hermes memory
  /// associated with this install across restarts.
  Future<String> ensureSessionKey() async {
    await _secretsHydration;
    _throwIfSecretsUnavailable();
    final existing = state.sessionKey;
    if (existing != null && existing.isNotEmpty) return existing;
    return _sessionKeyFuture ??= _generateSessionKey();
  }

  void _throwIfSecretsUnavailable() {
    if (ref.read(hermesSecretsErrorProvider) != null) {
      throw StateError(
        'Hermes secure storage is unavailable. Retry credential loading first.',
      );
    }
  }

  Future<String> _generateSessionKey() async {
    try {
      final generated = const Uuid().v4();
      await _serializeMutation(() async {
        await _secure.saveHermesSessionKey(generated);
        state = _withState(sessionKey: generated);
      });
      return generated;
    } finally {
      _sessionKeyFuture = null;
    }
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

class HermesSecretsLoading extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

/// True until the initial secure-storage hydration settles (success or error).
final hermesSecretsLoadingProvider =
    NotifierProvider<HermesSecretsLoading, bool>(HermesSecretsLoading.new);

class HermesSecretsError extends Notifier<Object?> {
  @override
  Object? build() => null;

  void set(Object error) => state = error;

  void clear() => state = null;
}

/// A secure-storage access failure, distinct from successfully reading no key.
final hermesSecretsErrorProvider =
    NotifierProvider<HermesSecretsError, Object?>(HermesSecretsError.new);

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
  final activeServer = ref.watch(activeServerProvider);
  return activeServer.hasValue && activeServer.requireValue == null;
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

  HermesApiService get _service =>
      ref.read(hermesApiServiceProvider) ??
      (throw StateError('Hermes is not configured'));

  Future<void> create({
    required String prompt,
    required String schedule,
  }) async {
    final service = _service;
    await service.createJob(prompt: prompt, schedule: schedule);
    ref.invalidateSelf();
  }

  Future<void> edit(String id, {String? prompt, String? schedule}) async {
    final service = _service;
    await service.updateJob(id, prompt: prompt, schedule: schedule);
    ref.invalidateSelf();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final service = _service;
    if (enabled) {
      await service.resumeJob(id);
    } else {
      await service.pauseJob(id);
    }
    ref.invalidateSelf();
  }

  Future<void> runNow(String id) async {
    await _service.runJob(id);
  }

  Future<void> delete(String id) async {
    final service = _service;
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

  CancelToken registerPending(
    String assistantMessageId, {
    CancelToken? cancelToken,
    Future<void>? cancellationSettled,
    required void Function() onCancelled,
  }) {
    final token = cancelToken ?? CancelToken();
    final existing = _runs[assistantMessageId];
    if (existing != null &&
        !existing.cancelled &&
        identical(existing.cancelToken, token)) {
      existing.onCancelled.add(onCancelled);
      existing.cancellationSettled ??= cancellationSettled;
      return token;
    }

    final previousStop = cancel(assistantMessageId);
    if (previousStop != null) unawaited(previousStop);
    _runs[assistantMessageId] = _ActiveRun(
      cancelToken: token,
      onCancelled: [onCancelled],
      cancellationSettled: cancellationSettled,
    );
    return token;
  }

  /// Attaches server state to a pending run. Returns false when the pending
  /// entry was already cancelled, in which case the subscription is cancelled.
  bool attachRun(
    String assistantMessageId, {
    required CancelToken cancelToken,
    required String runId,
    required StreamSubscription<void> subscription,
    required Future<void> Function(String runId) stopRemote,
  }) {
    final run = _runs[assistantMessageId];
    if (run == null ||
        run.cancelled ||
        !identical(run.cancelToken, cancelToken)) {
      unawaited(subscription.cancel());
      return false;
    }
    run.runId = runId;
    run.subscription = subscription;
    run.stopRemote = stopRemote;
    return true;
  }

  /// Compatibility helper for callers that already have a live run.
  void register(
    String assistantMessageId, {
    required String runId,
    required CancelToken cancelToken,
    required StreamSubscription<void> subscription,
    required Future<void> Function(String runId) stopRemote,
  }) {
    registerPending(
      assistantMessageId,
      cancelToken: cancelToken,
      onCancelled: () {},
    );
    attachRun(
      assistantMessageId,
      cancelToken: cancelToken,
      runId: runId,
      subscription: subscription,
      stopRemote: stopRemote,
    );
  }

  String? runIdFor(String assistantMessageId) =>
      _runs[assistantMessageId]?.runId;

  /// Cancels and forgets the run for [assistantMessageId]. The returned future
  /// waits for both the owner-bound remote stop (when the run id is known) and
  /// pending transport settlement (when create/preflight is still in flight).
  Future<void>? cancel(String assistantMessageId) {
    final run = _runs.remove(assistantMessageId);
    if (run == null) return null;
    run.cancelled = true;
    run.cancelToken.cancel('stopped');
    for (final callback in run.onCancelled) {
      try {
        callback();
      } catch (_) {
        // One UI cleanup callback must not prevent subscription/remote cleanup.
      }
    }
    final subscription = run.subscription;
    if (subscription != null) unawaited(subscription.cancel());
    final pending = <Future<void>>[];
    final cancellationSettled = run.cancellationSettled;
    if (cancellationSettled != null) pending.add(cancellationSettled);
    final runId = run.runId;
    final stopRemote = run.stopRemote;
    if (runId != null && stopRemote != null) {
      pending.add(Future<void>.sync(() => stopRemote(runId)));
    }
    return Future.wait<void>(pending);
  }

  List<Future<void>> cancelAll() {
    final stops = <Future<void>>[];
    for (final id in _runs.keys.toList(growable: false)) {
      final stop = cancel(id);
      if (stop != null) stops.add(stop);
    }
    return stops;
  }

  bool complete(String assistantMessageId, {required CancelToken cancelToken}) {
    final run = _runs[assistantMessageId];
    if (run == null || !identical(run.cancelToken, cancelToken)) return false;
    _runs.remove(assistantMessageId);
    return true;
  }
}

class _ActiveRun {
  _ActiveRun({
    required this.cancelToken,
    required this.onCancelled,
    this.cancellationSettled,
  });

  String? runId;
  final CancelToken cancelToken;
  final List<void Function()> onCancelled;
  Future<void>? cancellationSettled;
  StreamSubscription<void>? subscription;
  Future<void> Function(String runId)? stopRemote;
  bool cancelled = false;
}

final hermesRunRegistryProvider = Provider<HermesRunRegistry>(
  (ref) => HermesRunRegistry(),
);
