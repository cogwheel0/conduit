import 'package:dio/dio.dart';

import '../models/hermes_bot.dart';
import '../models/hermes_bot_group.dart';
import '../models/hermes_session.dart';
import '../models/hermes_run_event.dart';
import 'hermes_backend_service.dart';

/// Profile-aware, read-only discovery and explicit Bot Mode actions.
abstract interface class HermesMessagesBackend {
  Future<List<HermesBot>> listBots();
  Future<String?> botAvatar(String profile);
  Future<String> openBotChat(HermesBot bot);

  /// Read-only canonical Bot Chat registry; does not resume or create a chat.
  Future<HermesSessionSummary?> findBotChat(
    String profile, {
    CancelToken? cancelToken,
  });
  void bindBotSession(String profile, String sessionId);
  Future<List<HermesSessionSummary>> listProfileSessions(
    String profile, {
    CancelToken? cancelToken,
  });
  Future<List<Map<String, dynamic>>> readStoredTranscript(
    String id, {
    String? profile,
    CancelToken? cancelToken,
  });
  Future<List<HermesBotGroup>> listBotGroups();
  Future<HermesBotGroup> saveBotGroup(HermesBotGroup group);
  Future<HermesBot> createBot(HermesBotDraft draft);
  Future<HermesBot> finishBotSetup(HermesBotDraft draft);
  Future<List<Map<String, dynamic>>> listProfileJobs(
    String profile, {
    CancelToken? cancelToken,
  });
  Future<List<Map<String, dynamic>>> listProfileSkills(String profile);
  Future<List<Map<String, dynamic>>> listProfileToolsets(String profile);
  Future<String> openGroupMemberSession(
    HermesBotGroup group,
    String profile, {
    CancelToken? cancelToken,
  });
  Future<HermesResponseStream> streamGroupMemberResponse(
    String sessionId,
    String text, {
    CancelToken? cancelToken,
  });
  Future<void> resolveApprovalChoiceForSession(
    String storedSessionId, {
    required String approvalId,
    required String choice,
  });
  Future<void> respondToDecision({
    required String runtimeId,
    String? storedSessionId,
    required String requestId,
    required HermesDecisionKind kind,
    required String value,
    String? mcpServer,
    String? mcpAction,
  });
}
