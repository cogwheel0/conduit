import '../models/hermes_bot.dart';

import 'package:dio/dio.dart';

import '../models/hermes_model.dart';
import '../models/hermes_bot_group.dart';
import '../models/hermes_group_live_reply.dart';
import '../models/hermes_chat_input.dart';
import 'hermes_backend_service.dart';
import '../models/hermes_session.dart';

/// All operations are explicitly scoped to a bot profile or a hosted room.
/// This is separate from the general chat backend so older connections remain usable.
abstract interface class HermesWorkspaceService {
  Future<Map<String, dynamic>> describeBot(String profile);
  Future<void> configureBot(String profile, Map<String, dynamic> changes);
  Future<String> botHome(String profile);
  Future<String> botWorkspace(String profile);
  Future<String> initializeBotWorkspace(String profile);
  Future<bool?> botProviderReady(String profile);
  Future<void> setBotWorkspace(String profile, String path);
  Future<String> readBotMemory(String profile, {bool aboutUser = false});
  Future<void> writeBotMemory(
    String profile,
    String content, {
    required String expected,
    bool aboutUser = false,
  });
  Future<List<HermesDesktopModelOption>> botModels(String profile);
  Future<List<Map<String, dynamic>>> botOAuthProviders(String profile);
  Future<Map<String, dynamic>> startBotOAuth(String profile, String provider);
  Future<Map<String, dynamic>> pollBotOAuth(
    String profile,
    String provider,
    String session,
  );
  Future<void> cancelBotOAuth(String profile, String session);
  Future<List<Map<String, dynamic>>> botPlugins(String profile);
  Future<void> setBotPlugin(String profile, String key, bool enabled);
  Future<void> setBotHidden(HermesBot bot, bool hidden);
  Future<void> deleteBot(String profile);
  Future<void> compressBotSession(String profile, String sessionId);
  Future<HermesResponseStream> streamGroupInput(
    String sessionId,
    HermesChatInput input, {
    CancelToken? cancelToken,
  });
  Future<({String folder, List<String> paths})> uploadGroupFiles(
    HermesBotGroup group,
    List<HermesInputFilePart> files,
  );
  Future<void> archiveChat(String sessionId, bool archived);
  Future<List<HermesSessionSummary>> archivedChats();
  Future<void> removeBotGroup(HermesBotGroup group);
  Future<HermesBotGroup> readGroupHistory(
    HermesBotGroup group, {
    CancelToken? cancelToken,
  });
  Future<String?> findGroupMemberSession(HermesBotGroup group, String profile);

  /// Observes existing member turns; cancellation never interrupts the driver.
  Stream<HermesGroupLiveReply> watchGroupReplies(HermesBotGroup group);
  Future<Map<String, dynamic>> groupCapabilities();
  Future<Map<String, dynamic>> groupRequest(
    String action,
    Map<String, dynamic> params,
  );
  Future<void> mutateBotJob(
    String profile, {
    String? id,
    required String action,
    Map<String, dynamic> values = const {},
  });
}

class HermesWorkspaceMissing implements Exception {
  const HermesWorkspaceMissing(this.path);
  final String path;
}

class HermesBotModelConfirmation implements Exception {
  const HermesBotModelConfirmation(this.message);
  final String message;
}
