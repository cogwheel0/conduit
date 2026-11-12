part of 'chat_providers.dart';

/// Where the chat would ask for coding agents: one of the server's own
/// terminals, by its id and the name the picker shows, and the saved chat
/// the agents would answer in (null for a chat not yet started).
typedef TerminalAgentScope = ({
  String terminalId,
  String terminalName,
  String? chatId,
});

/// The active chat as agent discovery sees it: its id, and whether an agent
/// can answer there. Null for a chat not yet started.
typedef _AgentChat = ({String id, bool eligible});

_AgentChat? _agentChatOf(Conversation? conversation) {
  if (conversation == null) return null;
  return (
    id: conversation.id,
    // Open WebUI runs an agent only in a chat saved in its own database.
    eligible:
        !isTemporaryChat(conversation.id) &&
        chatMutationOwnerScopeForConversation(conversation) ==
            openWebUiChatMutationOwnerScope(conversation.id),
  );
}

/// The terminal whose coding agents the chat picker offers, or null when it
/// offers none.
///
/// Open WebUI (0.13.1 and later) lists a terminal's agents beside the
/// account's models once the chat has that terminal selected. Only the
/// server's own terminals can run one, never a terminal the user added by
/// address, and only in a saved chat, so a temporary chat offers none.
final terminalAgentScopeProvider = Provider<TerminalAgentScope?>(
  _terminalAgentScope,
);

TerminalAgentScope? _terminalAgentScope(Ref ref) {
  if (ref.watch(reviewerModeProvider)) return null;
  if (!ref.watch(openWebUiAccountAvailableProvider)) return null;
  if (!ref.watch(terminalAgentsSupportedProvider)) return null;
  if (ref.watch(temporaryChatEnabledProvider)) return null;
  final terminalId = ref.watch(selectedTerminalIdProvider)?.trim();
  if (terminalId == null || terminalId.isEmpty) return null;
  final chat = ref.watch(activeConversationProvider.select(_agentChatOf));
  if (chat != null && !chat.eligible) return null;
  final servers = ref.watch(terminalAvailableServersProvider).asData?.value;
  final server = servers
      ?.where((server) => server.isSystem && server.selectionId == terminalId)
      .firstOrNull;
  if (server == null) return null;
  return (
    terminalId: terminalId,
    terminalName: server.displayName,
    chatId: chat?.id,
  );
}

/// The coding agents the selected terminal offers the active chat, named
/// for the picker. Empty when [terminalAgentScopeProvider] offers none, or
/// when the terminal could not be asked: the picker then lists the account's
/// models alone.
final terminalAgentModelsProvider = FutureProvider<List<Model>>(
  _terminalAgentModels,
);

Future<List<Model>> _terminalAgentModels(Ref ref) async {
  final scope = ref.watch(terminalAgentScopeProvider);
  final api = ref.watch(apiServiceProvider);
  if (scope == null || api == null) return const <Model>[];
  try {
    return await api.getTerminalAgentModels(
      terminalId: scope.terminalId,
      chatId: scope.chatId,
      terminalName: scope.terminalName,
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'agent-models-failed',
      scope: 'chat/agents',
      error: error,
      stackTrace: stackTrace,
    );
    return const <Model>[];
  }
}

/// The coding agents for a picker that is opening: the list already loaded,
/// or the one that arrives within [timeout]. A slow terminal leaves them out
/// rather than hold the picker.
Future<List<Model>> readTerminalAgentModelsForPicker(
  dynamic ref, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final current =
      ref.read(terminalAgentModelsProvider) as AsyncValue<List<Model>>;
  if (current.hasValue && !current.isLoading) return current.requireValue;
  try {
    final future =
        ref.read(terminalAgentModelsProvider.future) as Future<List<Model>>;
    return await future.timeout(timeout);
  } catch (_) {
    return const <Model>[];
  }
}

/// The coding agent [modelId] names, as its terminal offers it to
/// [chatId], or null when the terminal is not one this chat can use or no
/// longer offers that agent.
///
/// A chat started with an agent reopens with it, as on Open WebUI: its
/// terminal is selected again and asked for the agent.
Future<Model?> resolveTerminalAgentModel(
  Ref ref,
  String modelId, {
  String? chatId,
}) async {
  final agent = parseTerminalAgentModelId(modelId);
  if (agent == null) return null;
  if (!ref.read(terminalAgentsSupportedProvider)) return null;
  final api = ref.read(apiServiceProvider);
  if (api == null) return null;
  final servers = await ref.read(terminalAvailableServersProvider.future);
  final server = servers
      .where(
        (server) => server.isSystem && server.selectionId == agent.terminalId,
      )
      .firstOrNull;
  if (server == null) return null;
  final agents = await api.getTerminalAgentModels(
    terminalId: agent.terminalId,
    chatId: chatId,
    terminalName: server.displayName,
  );
  return agents.where((model) => model.id == modelId).firstOrNull;
}

/// Puts the default model back when the terminal under a selected coding
/// agent is switched off or changed, as Open WebUI does: the agent runs only
/// on its own terminal. A terminal the server no longer offers this chat
/// counts as gone only once the server's own list is read without it: the
/// combined list also arrives without them when that read fails, and a list
/// that is loading or could not be read changes nothing.
final terminalAgentSelectionGuardProvider = Provider<void>(
  _terminalAgentSelectionGuard,
);

void _terminalAgentSelectionGuard(Ref ref) {
  ref.listen<AsyncValue<List<TerminalServerInfo>>>(
    terminalAvailableServersProvider,
    (previous, next) {
      if (next is! AsyncData<List<TerminalServerInfo>>) return;
      final selected = ref.read(selectedModelProvider);
      final agentTerminal = terminalAgentTerminalId(selected);
      if (agentTerminal == null) return;
      final listed = next.value.any(
        (server) => server.isSystem && server.selectionId == agentTerminal,
      );
      if (listed) return;
      unawaited(_dropAgentIfTerminalGone(ref, selected, agentTerminal));
    },
    // A list already read counts too, not only the next one.
    fireImmediately: true,
  );
  ref.listen<String?>(selectedTerminalIdProvider, (previous, next) {
    final selected = ref.read(selectedModelProvider);
    final agentTerminal = terminalAgentTerminalId(selected);
    if (agentTerminal == null || agentTerminal == next?.trim()) return;
    DebugLogger.log(
      'agent-terminal-changed',
      scope: 'chat/agents',
      data: {'cleared': next == null},
    );
    Future.microtask(() {
      if (!ref.mounted) return;
      // Still the same agent on another terminal: the default replaces it.
      if (!identical(ref.read(selectedModelProvider), selected)) return;
      if (terminalAgentTerminalId(selected) ==
          ref.read(selectedTerminalIdProvider)) {
        return;
      }
      unawaited(restoreDefaultModel(ref));
    });
  });
}

/// Asks the server for its terminals and restores the default model when
/// [agentTerminal] is not among those this chat may use. A read that fails
/// proves nothing and keeps [selected].
Future<void> _dropAgentIfTerminalGone(
  Ref ref,
  Model? selected,
  String agentTerminal,
) async {
  final service = ref.read(terminalServiceProvider);
  if (service == null) return;
  final scope = ref.read(terminalSessionScopeIdProvider);
  final List<TerminalServerInfo> servers;
  try {
    servers = await service.getSystemTerminalServers();
  } catch (_) {
    return;
  }
  if (!ref.mounted) return;
  final offered = servers.any(
    (server) =>
        server.selectionId == agentTerminal &&
        server.isAvailableForChatScope(scope),
  );
  if (offered) return;
  if (!identical(ref.read(selectedModelProvider), selected)) return;
  DebugLogger.log('agent-terminal-gone', scope: 'chat/agents');
  unawaited(restoreDefaultModel(ref));
}

/// The terminal a request for [model] runs on: a coding agent's own, else
/// the selected one when the model may use a terminal.
String? terminalIdForModelRequest(
  Model? model, {
  required String? selectedTerminalId,
}) {
  final agentTerminal = terminalAgentTerminalId(model);
  if (agentTerminal != null) return agentTerminal;
  return modelSupportsTerminal(model)
      ? _resolveTerminalIdForRequest(selectedTerminalId: selectedTerminalId)
      : null;
}

/// Whether the open chat talks to a coding agent: its model is one, or it
/// was started with one.
///
/// Open WebUI answers an agent only with a new message at the end of the
/// chat, as the agent keeps the conversation itself: a reply cannot be
/// regenerated, and a sent message cannot be edited and sent again.
final activeChatUsesTerminalAgentProvider = Provider<bool>(
  _activeChatUsesTerminalAgent,
);

bool _activeChatUsesTerminalAgent(Ref ref) {
  if (ref.watch(selectedModelProvider.select(isTerminalAgentModel))) {
    return true;
  }
  return ref.watch(
    activeConversationProvider.select(
      (conversation) => isTerminalAgentModelId(conversation?.model),
    ),
  );
}
