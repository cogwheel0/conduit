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
  return _agentScopeOn(terminalId, chat, servers);
}

/// The terminals a chat can use: for a saved chat ([chatId]), the server's
/// own as it offers them to that chat, in a read of this lookup's own
/// ([terminalSystemServersForChatProvider]); a host holding no chat as the
/// active one has the sidebar's list, which leaves out a terminal that needs
/// a saved chat. For a new chat (null), the account's list.
Future<List<TerminalServerInfo>> _terminalsFor(dynamic ref, String? chatId) {
  if (chatId == null) {
    return ref.read(terminalAvailableServersProvider.future)
        as Future<List<TerminalServerInfo>>;
  }
  final read = ref.read(
    terminalSystemServersForChatProvider,
  ) as Future<List<TerminalServerInfo>> Function(String);
  return read(chatId);
}

/// The scope on [terminalId] for [chat], when [servers] lists it as one of
/// the server's own terminals.
TerminalAgentScope? _agentScopeOn(
  String terminalId,
  _AgentChat? chat,
  List<TerminalServerInfo>? servers,
) {
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

/// [terminalAgentScopeProvider]'s rule for [conversation] (null for a new
/// chat, [temporary] when that new chat is a temporary one), read rather
/// than watched: for a host that lists models for a chat it does not hold
/// as the active one (the desktop daemon answers for any window's chat).
/// The terminal list is awaited for up to [timeout]; one that cannot be
/// read in that time offers none.
Future<TerminalAgentScope?> terminalAgentScopeFor(
  dynamic ref,
  Conversation? conversation, {
  bool temporary = false,
  Duration timeout = const Duration(seconds: 3),
}) async {
  if (ref.read(reviewerModeProvider) == true) return null;
  if (ref.read(openWebUiAccountAvailableProvider) != true) return null;
  if (ref.read(terminalAgentsSupportedProvider) != true) return null;
  if (temporary) return null;
  final terminalId = (ref.read(selectedTerminalIdProvider) as String?)?.trim();
  if (terminalId == null || terminalId.isEmpty) return null;
  final chat = _agentChatOf(conversation);
  if (chat != null && !chat.eligible) return null;
  List<TerminalServerInfo>? servers;
  try {
    // Without a terminal service the list stays loading: a host asking for
    // a picker gives up rather than wait on it.
    servers = await _terminalsFor(ref, chat?.id).timeout(timeout);
  } catch (_) {
    return null;
  }
  return _agentScopeOn(terminalId, chat, servers);
}

/// The coding agents [scope]'s terminal offers, named for the picker, or
/// none when it could not be asked within [timeout] (a slow terminal leaves
/// them out rather than hold the picker, as
/// [readTerminalAgentModelsForPicker] does).
Future<List<Model>> terminalAgentModelsIn(
  dynamic ref,
  TerminalAgentScope? scope, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final api = ref.read(apiServiceProvider) as ApiService?;
  if (scope == null || api == null) return const <Model>[];
  try {
    return await api
        .getTerminalAgentModels(
          terminalId: scope.terminalId,
          chatId: scope.chatId,
          terminalName: scope.terminalName,
        )
        .timeout(timeout);
  } catch (error) {
    DebugLogger.warning(
      'agent-models-failed',
      scope: 'chat/agents',
      data: {'error': error.runtimeType.toString()},
    );
    return const <Model>[];
  }
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
/// terminal is selected again and asked for the agent. The terminal is the
/// one [modelId] names, whichever terminal is selected now. [ref] is a `Ref`
/// or a host's `ProviderContainer`; [timeout], when given, bounds each read
/// (a slow terminal throws a [TimeoutException], as a failed read throws).
Future<Model?> resolveTerminalAgentModel(
  dynamic ref,
  String modelId, {
  String? chatId,
  Duration? timeout,
}) async {
  Future<T> bounded<T>(Future<T> future) =>
      timeout == null ? future : future.timeout(timeout);
  final agent = parseTerminalAgentModelId(modelId);
  if (agent == null) return null;
  if (ref.read(terminalAgentsSupportedProvider) != true) return null;
  final api = ref.read(apiServiceProvider) as ApiService?;
  if (api == null) return null;
  final servers = await bounded(_terminalsFor(ref, chatId));
  final server = servers
      .where(
        (server) => server.isSystem && server.selectionId == agent.terminalId,
      )
      .firstOrNull;
  if (server == null) return null;
  final agents = await bounded(
    api.getTerminalAgentModels(
      terminalId: agent.terminalId,
      chatId: chatId,
      terminalName: server.displayName,
    ),
  );
  return agents.where((model) => model.id == modelId).firstOrNull;
}

/// Whether the terminal under [agent], a coding agent, is gone: the one rule
/// for every holder of an agent pick (the account's selection here, a Mac
/// window's New Chat pick in the daemon). Each fact given is checked:
///
/// - [selected], the terminal selected now (`id` null: none): gone when it
///   is not the agent's own, since a new chat runs on the terminal selected.
/// - [listed], the account's terminals as read: gone once a list is read
///   without the agent's terminal and a fresh read of the server's own
///   terminals ([service]) confirms it is not offered for [scope]. The
///   combined list also comes back without them when that read fails, so
///   the list alone proves nothing. A list loading or failed, no [service],
///   or a fresh read that fails: not gone.
///
/// A model that is no coding agent is never gone.
Future<bool> agentTerminalGone(
  Model? agent, {
  ({String? id})? selected,
  AsyncValue<List<TerminalServerInfo>>? listed,
  TerminalService? service,
  String scope = '',
}) async {
  final agentTerminal = terminalAgentTerminalId(agent);
  if (agentTerminal == null) return false;
  if (selected != null && agentTerminal != selected.id?.trim()) return true;
  if (listed is! AsyncData<List<TerminalServerInfo>>) return false;
  final stillListed = listed.value.any(
    (server) => server.isSystem && server.selectionId == agentTerminal,
  );
  if (stillListed || service == null) return false;
  final List<TerminalServerInfo> servers;
  try {
    servers = await service.getSystemTerminalServers();
  } catch (_) {
    return false;
  }
  return !servers.any(
    (server) =>
        server.selectionId == agentTerminal &&
        server.isAvailableForChatScope(scope),
  );
}

/// Puts the default model back when the terminal under a selected coding
/// agent is gone ([agentTerminalGone]): switched off or changed, as Open
/// WebUI does (the agent runs only on its own terminal), or no longer
/// offered by the server for this chat.
final terminalAgentSelectionGuardProvider = Provider<void>(
  _terminalAgentSelectionGuard,
);

void _terminalAgentSelectionGuard(Ref ref) {
  ref.listen<AsyncValue<List<TerminalServerInfo>>>(
    terminalAvailableServersProvider,
    (previous, next) {
      final selected = ref.read(selectedModelProvider);
      if (terminalAgentTerminalId(selected) == null) return;
      final gone = agentTerminalGone(
        selected,
        listed: next,
        service: ref.read(terminalServiceProvider),
        scope: ref.read(terminalSessionScopeIdProvider),
      );
      unawaited(
        gone.then((gone) {
          if (!gone || !ref.mounted) return;
          if (!identical(ref.read(selectedModelProvider), selected)) return;
          DebugLogger.log('agent-terminal-gone', scope: 'chat/agents');
          unawaited(restoreDefaultModel(ref));
        }),
      );
    },
    // A list already read counts too, not only the next one.
    fireImmediately: true,
  );
  ref.listen<String?>(selectedTerminalIdProvider, (previous, next) {
    final selected = ref.read(selectedModelProvider);
    unawaited(() async {
      if (!await agentTerminalGone(selected, selected: (id: next))) return;
      DebugLogger.log(
        'agent-terminal-changed',
        scope: 'chat/agents',
        data: {'cleared': next == null},
      );
      if (!ref.mounted) return;
      // Still gone once the change has settled, the same agent selected:
      // the default replaces it.
      final now = ref.read(selectedTerminalIdProvider);
      if (!await agentTerminalGone(selected, selected: (id: now))) return;
      if (!ref.mounted) return;
      if (!identical(ref.read(selectedModelProvider), selected)) return;
      unawaited(restoreDefaultModel(ref));
    }());
  });
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

/// Whether a chat talks to a coding agent, as
/// [activeChatUsesTerminalAgentProvider] decides for the active one: the
/// [selected] model is one, or [conversation] was started with one or has a
/// reply from one (whose Regenerate the phone hides too). For a host that
/// answers for a chat it does not hold active.
bool conversationUsesTerminalAgent(
  Model? selected,
  Conversation? conversation,
) {
  if (isTerminalAgentModel(selected)) return true;
  if (conversation == null) return false;
  return anyTerminalAgentModelId([
    conversation.model,
    for (final message in conversation.messages) message.model,
  ]);
}

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
