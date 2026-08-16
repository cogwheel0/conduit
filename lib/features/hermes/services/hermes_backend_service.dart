import 'package:dio/dio.dart';

import '../models/hermes_config.dart';
import '../models/hermes_chat_input.dart';
import '../models/hermes_run_event.dart';

final class HermesResponseStream {
  const HermesResponseStream({required this.events, this.sessionId});

  final Stream<HermesRunEvent> events;
  final String? sessionId;
}

final class HermesDesktopSessionOptions {
  const HermesDesktopSessionOptions({
    this.model,
    this.provider,
    this.reasoningEffort,
    this.fast,
  });

  final String? model;
  final String? provider;
  final String? reasoningEffort;
  final bool? fast;

  String get fingerprint =>
      '${provider ?? ''}\u0000${model ?? ''}\u0000${reasoningEffort ?? ''}\u0000${fast ?? ''}';
}

/// Shared settings, session, and scheduler surface implemented by both Hermes
/// connection modes. Turn streaming remains transport-specific.
abstract interface class HermesBackendService {
  HermesConfig get config;

  Future<bool> health();
  Future<List<Map<String, dynamic>>> listSkills();
  Future<String> createSession({String? title, CancelToken? cancelToken});
  Future<List<Map<String, dynamic>>> listSessions();
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String id, {
    CancelToken? cancelToken,
  });
  Future<void> renameSession(String id, String title);
  Future<void> deleteSession(String id, {CancelToken? cancelToken});
  Future<String> forkSession(String id);
  Future<Map<String, dynamic>> getCapabilities();
  Future<List<Map<String, dynamic>>> listToolsets();
  Future<Map<String, dynamic>> healthDetailed();
  Future<List<Map<String, dynamic>>> listJobs();
  Future<Map<String, dynamic>> createJob({
    required String name,
    required String prompt,
    required String schedule,
  });
  Future<void> updateJob(
    String id, {
    String? name,
    String? prompt,
    String? schedule,
    bool? enabled,
  });
  Future<void> deleteJob(String id);
  Future<void> pauseJob(String id);
  Future<void> resumeJob(String id);
  Future<void> runJob(String id);
  Future<void> resolveApproval(
    String runId, {
    required String approvalId,
    required bool approved,
  });
  void close();
}

abstract interface class HermesResponsesTurnService
    implements HermesBackendService {
  Future<HermesResponseStream> streamResponseWithReasoning(
    HermesChatInput input, {
    String? sessionId,
    String? conversation,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    String? instructions,
    String? reasoningEffort,
    CancelToken? cancelToken,
  });
}

/// Legacy name retained for Responses transport test doubles and callers.
abstract interface class HermesTurnService
    implements HermesResponsesTurnService {}

abstract interface class HermesDesktopTurnService
    implements HermesBackendService {
  Future<String> createDesktopSession({
    String? title,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
  });

  Future<HermesResponseStream> streamDesktopResponse(
    HermesChatInput input, {
    String? sessionId,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
  });
}

typedef HermesTurnStarter = Future<HermesResponseStream> Function(
  CancelToken cancelToken,
);
