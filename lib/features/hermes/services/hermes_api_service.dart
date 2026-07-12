import 'package:dio/dio.dart';

import '../../../core/utils/debug_logger.dart';
import '../models/hermes_config.dart';
import '../models/hermes_run_event.dart';
import 'hermes_stream_parser.dart';

Future<bool> testHermesDraftConnection(
  HermesConfig config, {
  Future<bool> Function(HermesConfig probeConfig)? probe,
}) async {
  // Enabling a backend and verifying its draft are separate operations.
  final probeConfig = config.copyWith(enabled: true);
  if (probe != null) return probe(probeConfig);

  final service = HermesApiService(config: probeConfig);
  try {
    return await service.health();
  } finally {
    service.close();
  }
}

/// Thin client for the direct Hermes Agent API server.
///
/// Deliberately separate from the ~6000-line OpenWebUI `ApiService`: Hermes is a
/// different backend with its own bearer auth and `X-Hermes-*` headers, and
/// reusing the OpenWebUI auth interceptor (with its public-endpoint list and
/// 401/403 escalation) would be wrong here.
class HermesApiService {
  HermesApiService({required this.config, Dio? dio})
    : _root = _normalizeRoot(config.baseUrl),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              // Regular endpoints get a finite timeout so they can't hang
              // forever; the long-lived SSE stream opts out per-request below.
              receiveTimeout: const Duration(seconds: 60),
              followRedirects: false,
              headers: {
                if ((config.apiKey ?? '').isNotEmpty)
                  'Authorization': 'Bearer ${config.apiKey}',
              },
            ),
          ) {
    // Injected clients are used by tests and embedders. Enforce the same
    // boundary there: Dio preserves custom headers across redirects, so an
    // automatic cross-origin redirect could leak bearer/session credentials.
    _dio.options.followRedirects = false;
  }

  final HermesConfig config;
  final Dio _dio;
  final String _root;

  /// Strips a trailing slash and optional `/v1` so endpoints can be composed
  /// uniformly as `<root>/v1/...` and `<root>/health`.
  static String _normalizeRoot(String baseUrl) {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/v1')) {
      url = url.substring(0, url.length - '/v1'.length);
    }
    return url;
  }

  Map<String, String> _sessionHeaders({String? sessionId}) {
    return {
      if ((sessionId ?? '').isNotEmpty) 'X-Hermes-Session-Id': sessionId!,
      if ((config.sessionKey ?? '').isNotEmpty)
        'X-Hermes-Session-Key': config.sessionKey!,
    };
  }

  /// Returns true when the server answers `GET /health` with a 2xx.
  Future<bool> health() async {
    try {
      final resp = await _dio.get<dynamic>(
        '$_root/health',
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      final code = resp.statusCode ?? 0;
      return code >= 200 && code < 300;
    } catch (e) {
      DebugLogger.warning(
        'health-check-failed',
        scope: 'hermes/api',
        data: {'error': e.toString()},
      );
      return false;
    }
  }

  /// Lists models exposed by the Hermes server (`GET /v1/models`).
  Future<List<Map<String, dynamic>>> getModels() async {
    final resp = await _dio.get<dynamic>('$_root/v1/models');
    final data = resp.data;
    final list = data is Map ? data['data'] : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Lists the agent's skills (`GET /v1/skills`), the slash-commands invokable
  /// in chat input as `/skill-name args`. Read-only, bearer-gated.
  Future<List<Map<String, dynamic>>> listSkills() async {
    final resp = await _dio.get<dynamic>('$_root/v1/skills');
    final data = resp.data;
    final list = data is Map ? (data['skills'] ?? data['data']) : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Creates a run (`POST /v1/runs`) and returns its `run_id`.
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    CancelToken? cancelToken,
  }) async {
    final resp = await _dio.post<dynamic>(
      '$_root/v1/runs',
      cancelToken: cancelToken,
      data: {
        'input': input,
        'session_id': ?sessionId,
        'instructions': ?instructions,
        'previous_response_id': ?previousResponseId,
      },
      options: Options(headers: _sessionHeaders(sessionId: sessionId)),
    );
    final data = resp.data;
    final runId = data is Map
        ? (data['run_id'] ?? data['id'])?.toString()
        : null;
    if (runId == null || runId.isEmpty) {
      throw StateError('Hermes createRun returned no run_id');
    }
    return runId;
  }

  /// Opens the run event stream (`GET /v1/runs/{id}/events`) and decodes it into
  /// typed [HermesRunEvent]s. The caller owns the returned subscription.
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) async* {
    final resp = await _dio.get<ResponseBody>(
      '$_root/v1/runs/$runId/events',
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        // Runs event streams are long-lived (the agent can pause between
        // tokens); disable the receive timeout for this request only.
        // Duration.zero means "no timeout" in Dio and overrides BaseOptions.
        receiveTimeout: Duration.zero,
        headers: {
          'Accept': 'text/event-stream',
          ..._sessionHeaders(sessionId: sessionId),
        },
      ),
    );
    final body = resp.data;
    if (body == null) return;
    // Dio yields a Stream<Uint8List>; cast to Stream<List<int>> so the UTF-8
    // decoder's StreamTransformer<List<int>, String> binds without a runtime
    // variance error.
    yield* parseHermesRunStream(body.stream.cast<List<int>>());
  }

  /// Fetches the current state of a run (`GET /v1/runs/{id}`) — used to recover
  /// a final result when the events stream drops before a terminal event.
  Future<Map<String, dynamic>> getRun(
    String runId, {
    CancelToken? cancelToken,
  }) async {
    final resp = await _dio.get<dynamic>(
      '$_root/v1/runs/$runId',
      cancelToken: cancelToken,
    );
    final data = resp.data;
    if (data is! Map) {
      throw const FormatException('Hermes getRun returned a non-object body');
    }
    final map = data.cast<String, dynamic>();
    for (final key in const ['run', 'data', 'result']) {
      final nested = map[key];
      if (nested is Map) return nested.cast<String, dynamic>();
    }
    return map;
  }

  /// Stops a run (`POST /v1/runs/{id}/stop`).
  Future<void> stopRun(String runId, {CancelToken? cancelToken}) async {
    try {
      await _dio.post<dynamic>(
        '$_root/v1/runs/$runId/stop',
        cancelToken: cancelToken,
      );
    } catch (e) {
      DebugLogger.warning(
        'stop-run-failed',
        scope: 'hermes/api',
        data: {'runId': runId, 'error': e.toString()},
      );
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Sessions API (`/api/sessions/*`) — server-side transcript persistence.
  // ---------------------------------------------------------------------------

  /// Creates a session (`POST /api/sessions`) and returns its id.
  Future<String> createSession({
    String? title,
    CancelToken? cancelToken,
  }) async {
    final resp = await _dio.post<dynamic>(
      '$_root/api/sessions',
      cancelToken: cancelToken,
      data: {'title': ?title},
    );
    final id = _sessionId(resp.data);
    if (id == null) throw StateError('Hermes createSession returned no id');
    return id;
  }

  /// Lists sessions (`GET /api/sessions`).
  Future<List<Map<String, dynamic>>> listSessions() async {
    final resp = await _dio.get<dynamic>('$_root/api/sessions');
    final data = resp.data;
    final list = data is Map
        ? (data['sessions'] ?? data['data'] ?? data['items'])
        : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Fetches a session's message history (`GET /api/sessions/{id}/messages`).
  Future<List<Map<String, dynamic>>> getSessionMessages(String id) async {
    final resp = await _dio.get<dynamic>('$_root/api/sessions/$id/messages');
    final data = resp.data;
    final list = data is Map ? (data['messages'] ?? data['data']) : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Renames a session (`PATCH /api/sessions/{id}`).
  Future<void> renameSession(String id, String title) async {
    await _dio.patch<dynamic>(
      '$_root/api/sessions/$id',
      data: {'title': title},
    );
  }

  /// Deletes a session (`DELETE /api/sessions/{id}`).
  Future<void> deleteSession(String id) async {
    await _dio.delete<dynamic>('$_root/api/sessions/$id');
  }

  /// Forks a session via lineage (`POST /api/sessions/{id}/fork`) and returns
  /// the new session id.
  Future<String> forkSession(String id) async {
    final resp = await _dio.post<dynamic>('$_root/api/sessions/$id/fork');
    final newId = _sessionId(resp.data);
    if (newId == null) throw StateError('Hermes forkSession returned no id');
    return newId;
  }

  // ---------------------------------------------------------------------------
  // Discovery (`/v1/capabilities`, `/v1/toolsets`, `/health/detailed`).
  // ---------------------------------------------------------------------------

  /// Machine-readable server capabilities (`GET /v1/capabilities`).
  Future<Map<String, dynamic>> getCapabilities() async {
    final resp = await _dio.get<dynamic>('$_root/v1/capabilities');
    final data = resp.data;
    return data is Map ? data.cast<String, dynamic>() : const {};
  }

  /// Resolved toolsets and their concrete tools (`GET /v1/toolsets`).
  Future<List<Map<String, dynamic>>> listToolsets() async {
    final resp = await _dio.get<dynamic>('$_root/v1/toolsets');
    final data = resp.data;
    final list = data is Map ? (data['toolsets'] ?? data['data']) : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Extended health (`GET /health/detailed`): active sessions, running agents,
  /// resource usage. Returns an empty map on any failure.
  Future<Map<String, dynamic>> healthDetailed() async {
    try {
      final resp = await _dio.get<dynamic>('$_root/health/detailed');
      final data = resp.data;
      return data is Map ? data.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  // ---------------------------------------------------------------------------
  // Jobs API (`/api/jobs/*`) — scheduled/background agent runs.
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> listJobs() async {
    final resp = await _dio.get<dynamic>('$_root/api/jobs');
    final data = resp.data;
    final list = data is Map ? (data['jobs'] ?? data['data']) : data;
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  }

  /// Creates a scheduled job. [schedule] is a cron expression.
  Future<Map<String, dynamic>> createJob({
    required String prompt,
    required String schedule,
    bool enabled = true,
  }) async {
    final resp = await _dio.post<dynamic>(
      '$_root/api/jobs',
      data: {'prompt': prompt, 'schedule': schedule, 'enabled': enabled},
    );
    final data = resp.data;
    return data is Map ? data.cast<String, dynamic>() : const {};
  }

  /// Partially updates a job (any of prompt / schedule / enabled).
  Future<void> updateJob(
    String id, {
    String? prompt,
    String? schedule,
    bool? enabled,
  }) async {
    await _dio.patch<dynamic>(
      '$_root/api/jobs/$id',
      data: {'prompt': ?prompt, 'schedule': ?schedule, 'enabled': ?enabled},
    );
  }

  Future<void> deleteJob(String id) async {
    await _dio.delete<dynamic>('$_root/api/jobs/$id');
  }

  Future<void> pauseJob(String id) async {
    await _dio.post<dynamic>('$_root/api/jobs/$id/pause');
  }

  Future<void> resumeJob(String id) async {
    await _dio.post<dynamic>('$_root/api/jobs/$id/resume');
  }

  /// Triggers an immediate run outside the schedule (`POST /api/jobs/{id}/run`).
  Future<void> runJob(String id) async {
    await _dio.post<dynamic>('$_root/api/jobs/$id/run');
  }

  static String? _sessionId(dynamic data) {
    if (data is! Map) return null;
    final direct = data['id'] ?? data['session_id'];
    if (direct != null) return direct.toString();
    final session = data['session'];
    if (session is Map) {
      final nested = session['id'] ?? session['session_id'];
      if (nested != null) return nested.toString();
    }
    return null;
  }

  /// Resolves a pending approval gate (`POST /v1/runs/{id}/approval`).
  Future<void> resolveApproval(
    String runId, {
    required String approvalId,
    required bool approved,
  }) async {
    final encodedRunId = Uri.encodeComponent(runId);
    await _dio.post<dynamic>(
      '$_root/v1/runs/$encodedRunId/approval',
      data: {
        'approval_id': approvalId,
        'approved': approved,
        'decision': approved ? 'approve' : 'deny',
      },
    );
  }

  void close() => _dio.close(force: true);
}
