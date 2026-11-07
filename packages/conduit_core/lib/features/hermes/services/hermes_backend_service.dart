import 'package:dio/dio.dart';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';

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

  /// Sets a session's sidebar flags; a null flag is left as it is.
  Future<void> setSessionFlags(
    String id, {
    bool? pinned,
    bool? archived,
    bool? hidden,
  });

  /// Archived sessions, newest first, or null when the server cannot list
  /// them (the API server lists only sessions that are not archived).
  Future<List<Map<String, dynamic>>?> listArchivedSessions();

  /// One session's row, or null when the server no longer has it.
  Future<Map<String, dynamic>?> getSession(String id);
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

  /// [voiceContext] marks the turn as one a realtime call handed over: the
  /// recent spoken conversation, which the model reads and the session's
  /// transcript does not keep.
  Future<HermesResponseStream> streamDesktopResponse(
    HermesChatInput input, {
    String? sessionId,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
    String? voiceContext,
  });
}

typedef HermesTurnStarter = Future<HermesResponseStream> Function(
  CancelToken cancelToken,
);

/// A model switch Hermes held for the user's confirmation (a pricier,
/// data-sharing or smaller-context model): the chat is still on its old
/// model, so the message was not sent. [message] says why, for the chat.
final class HermesModelSwitchHeld implements Exception {
  const HermesModelSwitchHeld(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Hermes rejected a steer without saying whether the running turn already
/// saw it (an acknowledgement that timed out after delivery). It is not
/// sent again, since the agent may have it: the user decides.
final class HermesSteerUncertain implements Exception {
  const HermesSteerUncertain();

  @override
  String toString() => 'Hermes did not confirm the steer.';
}

/// Hermes kept answering that its gateway is not ready (it is starting,
/// restarting or draining), which is not a sign-in problem.
final class HermesDesktopGatewayStartingException implements Exception {
  const HermesDesktopGatewayStartingException();

  String get message =>
      'Hermes is starting or restarting. Try again in a moment.';

  @override
  String toString() => message;
}
