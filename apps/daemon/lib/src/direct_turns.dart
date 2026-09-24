part of 'turns_service.dart';

/// Turns answered by a direct connection rather than Open WebUI.
///
/// The daemon talks to the provider itself, through the core's adapters,
/// and writes the conversation to the database the way the mobile app
/// does: a `direct-local:` chat when history stays on this computer, a
/// `local:` one queued for Open WebUI when it is mirrored there. The sync
/// engine later swaps that `local:` id for the server's, which the renderer
/// hears about as `route.remap`.
///
/// What the renderer sees is the same `turn.*` stream an Open WebUI turn
/// produces, so nothing downstream needs to know which kind this was.
extension _DirectTurns on TurnsService {
  Future<SendTurnAccepted> _sendDirect(
    SendTurn request, {
    required String model,
    required String text,
    required ({String profileId, String remoteModelId}) route,
  }) async {
    final (profile, adapter) = await _directConnection(route.profileId);

    final chatId = request.chatId;
    if (chatId != null) _requireIdle(chatId);
    final history = chatId == null
        ? const <ChatMessage>[]
        : await _historyFor(chatId);
    final parent = history.lastOrNull;

    final now = DateTime.now();
    final userMessage = ChatMessage(
      id: TurnsService._uuid.v4(),
      role: 'user',
      content: text,
      timestamp: now,
      metadata: <String, dynamic>{'parentId': ?parent?.id},
    );
    final placeholder = ChatMessage(
      id: TurnsService._uuid.v4(),
      role: 'assistant',
      content: '',
      timestamp: now,
      model: model,
      isStreaming: true,
      metadata: <String, dynamic>{'parentId': userMessage.id},
    );

    // Where the chat lives. A temporary chat lives nowhere: the daemon's
    // memory holds it, as it does an Open WebUI temporary chat.
    final ChatDatabaseLocation? location;
    final String resolvedChatId;
    if (chatId == null && request.temporary) {
      location = null;
      resolvedChatId = 'local:${TurnsService._uuid.v4()}';
      temporary.start(resolvedChatId);
    } else if (chatId != null && temporary.contains(chatId)) {
      location = null;
      resolvedChatId = chatId;
    } else if (chatId == null) {
      (location, resolvedChatId) = await _createDirectChat(
        model: model,
        title: TurnsService._titleFor(text),
        messages: <ChatMessage>[userMessage, placeholder],
      );
    } else {
      location = await _container
          .read(chatDatabaseRepositoryProvider)
          .resolveChat(chatId);
      if (location == null) {
        throw RpcError(
          code: ConduitErrorCodes.notFound,
          debugMessage: 'no chat $chatId',
        );
      }
      resolvedChatId = chatId;
      await _appendDirectTurn(
        location,
        chatId: chatId,
        parent: parent,
        user: userMessage,
        assistant: placeholder,
      );
    }
    _requireIdle(resolvedChatId);
    if (location == null) temporary.append(resolvedChatId, userMessage);

    await _startDirect(
      chatId: resolvedChatId,
      model: model,
      adapter: adapter,
      profile: profile,
      remoteModelId: route.remoteModelId,
      location: location,
      placeholder: placeholder,
      webSearch: request.webSearch,
      toolIds: request.toolIds,
      prompt: <ChatMessage>[...history, userMessage],
    );
    return SendTurnAccepted(
      chatId: resolvedChatId,
      userMessageId: userMessage.id,
      assistantMessageId: placeholder.id,
    );
  }

  /// Answers [user] again, as another child of it: a branch, as on Open
  /// WebUI, so the answer being replaced stays reachable.
  Future<SendTurnAccepted> _regenerateDirect({
    required String chatId,
    required String model,
    required ({String profileId, String remoteModelId}) route,
    required List<ChatMessage> prompt,
    required ChatMessage user,
  }) async {
    final (profile, adapter) = await _directConnection(route.profileId);
    final location = await _container
        .read(chatDatabaseRepositoryProvider)
        .resolveChat(chatId);
    if (location == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no chat $chatId',
      );
    }
    final placeholder = ChatMessage(
      id: TurnsService._uuid.v4(),
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
      model: model,
      isStreaming: true,
      metadata: <String, dynamic>{'parentId': user.id},
    );
    await _container.read(chatLocksProvider).runExclusive(chatId, () async {
      await _container
          .read(chatDatabaseRepositoryProvider)
          .persistDirectMessages(
            location,
            chatId: chatId,
            messages: <MessageRowData>[
              directMessageRow(
                chatId: chatId,
                message: user,
                parentId: message_tree.chatMessageParentId(user),
                childrenIds: <String>{
                  ...message_tree.chatMessageChildrenIds(user),
                  placeholder.id,
                }.toList(growable: false),
                orderIndex: 0,
              ),
              directMessageRow(
                chatId: chatId,
                message: placeholder,
                parentId: user.id,
                childrenIds: const <String>[],
                orderIndex: 1,
              ),
            ],
            currentMessageId: placeholder.id,
            updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          );
    });
    _requireIdle(chatId);
    await _startDirect(
      chatId: chatId,
      model: model,
      adapter: adapter,
      profile: profile,
      remoteModelId: route.remoteModelId,
      location: location,
      placeholder: placeholder,
      webSearch: false,
      prompt: prompt,
    );
    return SendTurnAccepted(
      chatId: chatId,
      userMessageId: user.id,
      assistantMessageId: placeholder.id,
    );
  }

  /// Asks an edited question beside the original: same parent, so the two
  /// are siblings and the old branch stays reachable.
  Future<SendTurnAccepted> _editDirect({
    required String chatId,
    required String model,
    required ({String profileId, String remoteModelId}) route,
    required List<ChatMessage> before,
    required ChatMessage? parent,
    required String text,
  }) async {
    final (profile, adapter) = await _directConnection(route.profileId);
    final location = await _container
        .read(chatDatabaseRepositoryProvider)
        .resolveChat(chatId);
    if (location == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no chat $chatId',
      );
    }
    final now = DateTime.now();
    final user = ChatMessage(
      id: TurnsService._uuid.v4(),
      role: 'user',
      content: text,
      timestamp: now,
      metadata: <String, dynamic>{'parentId': ?parent?.id},
    );
    final placeholder = ChatMessage(
      id: TurnsService._uuid.v4(),
      role: 'assistant',
      content: '',
      timestamp: now,
      model: model,
      isStreaming: true,
      metadata: <String, dynamic>{'parentId': user.id},
    );
    await _appendDirectTurn(
      location,
      chatId: chatId,
      parent: parent,
      user: user,
      assistant: placeholder,
    );
    _requireIdle(chatId);
    await _startDirect(
      chatId: chatId,
      model: model,
      adapter: adapter,
      profile: profile,
      remoteModelId: route.remoteModelId,
      location: location,
      placeholder: placeholder,
      webSearch: false,
      prompt: <ChatMessage>[...before, user],
    );
    return SendTurnAccepted(
      chatId: chatId,
      userMessageId: user.id,
      assistantMessageId: placeholder.id,
    );
  }

  /// The connection a direct model belongs to, and the adapter that speaks
  /// its protocol.
  Future<(DirectConnectionProfile, DirectProviderAdapter)> _directConnection(
    String profileId,
  ) async {
    final profiles = await readSettled(
      _container,
      directConnectionProfilesProvider.future,
    );
    final profile = profiles
        .where((candidate) => candidate.id == profileId)
        .firstOrNull;
    if (profile == null || !profile.isUsable) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'that connection is missing or turned off',
      );
    }
    final adapter = _container
        .read(directProviderAdapterRegistryProvider)
        .lookup(profile.adapterKey);
    if (adapter == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'this computer cannot talk to that kind of connection',
      );
    }
    return (profile, adapter);
  }

  /// Registers the turn, announces it, and streams the answer in the
  /// background.
  Future<void> _startDirect({
    required String chatId,
    required String model,
    required DirectProviderAdapter adapter,
    required DirectConnectionProfile profile,
    required String remoteModelId,
    required ChatDatabaseLocation? location,
    required ChatMessage placeholder,
    required bool webSearch,
    required List<ChatMessage> prompt,
    List<String> toolIds = const <String>[],
  }) async {
    final resolvedChatId = chatId;
    final now = placeholder.timestamp;
    final turn = _ActiveTurn(
      chatId: resolvedChatId,
      messageId: placeholder.id,
      model: model,
    )..direct = true;
    _active[resolvedChatId] = turn;
    _events.publish(
      ConduitEvents.turnStarted,
      scope: resolvedChatId,
      payload: TurnStarted(
        chatId: resolvedChatId,
        messageId: placeholder.id,
        model: model,
      ).toJson(),
    );
    turn.ticker = Timer.periodic(
      TurnsService._deltaInterval,
      (_) => _emitDelta(turn),
    );

    // The system prompt is the account's when there is one; a direct turn
    // made while signed out simply has none.
    final api = _container.read(apiServiceProvider);
    final systemPrompt = api == null
        ? null
        : await _systemPromptFor(api, resolvedChatId);

    unawaited(
      _runDirect(
        turn,
        adapter: adapter,
        profile: profile,
        remoteModelId: remoteModelId,
        location: location,
        placeholder: placeholder,
        webSearch: webSearch,
        toolIds: toolIds,
        messages: <ChatMessage>[
          if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
            ChatMessage(
              id: 'system',
              role: 'system',
              content: systemPrompt,
              timestamp: now,
            ),
          ...prompt,
        ],
      ),
    );
  }

  /// The id Open WebUI knows [model] by, when it comes from a direct
  /// connection kept in the account; null for any other model.
  ///
  /// Decided by the core's registry of the models it minted, not by the
  /// id's shape: an id alone is not proof of where a model came from.
  Future<String?> _openWebUiWireModel(String model) async {
    if (DirectModelId.decode(model) == null) return null;
    final List<Model> models;
    try {
      models = await readSettled(_container, modelsProvider.future);
    } on Object {
      return null;
    }
    final match = models
        .where((candidate) => candidate.id == model)
        .firstOrNull;
    if (match == null) return null;
    final binding = _container.read(directModelRegistryProvider).resolve(match);
    return binding?.source == DirectModelSource.openWebUi
        ? binding!.openWebUiModelId
        : null;
  }

  /// Writes a new direct chat holding the question and the placeholder.
  Future<(ChatDatabaseLocation, String)> _createDirectChat({
    required String model,
    required String title,
    required List<ChatMessage> messages,
  }) async {
    final repository = _container.read(chatDatabaseRepositoryProvider);
    // Mirrored to Open WebUI only when there is an account to mirror it to;
    // otherwise it stays here rather than failing to start.
    final signedIn =
        _container.read(authStateManagerProvider).value?.isAuthenticated ==
        true;
    final preference =
        signedIn &&
            _container.read(directHistoryPolicyProvider) ==
                DirectHistoryPolicy.syncWithOpenWebUI
        ? DirectChatSyncPreference.syncWithOpenWebUiWhenAvailable
        : DirectChatSyncPreference.localOnly;
    final location = repository.chooseForNewDirectChat(preference);
    final synced = location.storage == ChatStorageKind.openWebUi;
    final id = synced
        ? 'local:${TurnsService._uuid.v4()}'
        : 'direct-local:${TurnsService._uuid.v4()}';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rows = ChatBlobMapper.blobToRows(
      chatId: id,
      blob: directNewChatBlob(title: title, modelId: model, messages: messages),
      title: title,
      createdAt: now,
      updatedAt: now,
    );
    await _container.read(chatLocksProvider).runExclusive(id, () async {
      await repository.persistNewDirectChat(
        location,
        rows,
        openWebUiContentHash: synced ? createChatContentHash(rows) : null,
      );
    });
    return (location, id);
  }

  /// Adds a question and its placeholder to an existing chat, hung off the
  /// last message of the branch on screen.
  Future<void> _appendDirectTurn(
    ChatDatabaseLocation location, {
    required String chatId,
    required ChatMessage? parent,
    required ChatMessage user,
    required ChatMessage assistant,
  }) async {
    final rows = <MessageRowData>[
      if (parent != null)
        directMessageRow(
          chatId: chatId,
          message: parent,
          parentId: message_tree.chatMessageParentId(parent),
          childrenIds: <String>{
            ...message_tree.chatMessageChildrenIds(parent),
            user.id,
          }.toList(growable: false),
          orderIndex: 0,
        ),
      directMessageRow(
        chatId: chatId,
        message: user,
        parentId: parent?.id,
        childrenIds: <String>[assistant.id],
        orderIndex: 0,
      ),
      directMessageRow(
        chatId: chatId,
        message: assistant,
        parentId: user.id,
        childrenIds: const <String>[],
        orderIndex: 1,
      ),
    ];
    await _container.read(chatLocksProvider).runExclusive(chatId, () async {
      await _container
          .read(chatDatabaseRepositoryProvider)
          .persistDirectMessages(
            location,
            chatId: chatId,
            messages: rows,
            currentMessageId: assistant.id,
            updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          );
    });
  }

  /// Streams the answer, then stores it -- including what arrived before a
  /// stop or a failure, which is still the user's answer.
  Future<void> _runDirect(
    _ActiveTurn turn, {
    required DirectProviderAdapter adapter,
    required DirectConnectionProfile profile,
    required String remoteModelId,
    required ChatDatabaseLocation? location,
    required ChatMessage placeholder,
    required bool webSearch,
    required List<String> toolIds,
    required List<ChatMessage> messages,
  }) async {
    final accumulator = DirectStreamingAccumulator();
    final limits = _container.read(directNormalizedStreamLimitsProvider);
    final secrets = directProfileSensitiveValues(profile);
    DirectMcpToolSession? tools;
    Timer? watchdog;
    try {
      final approvals = _DirectApprovals();
      tools = await _openMcpTools(toolIds);
      final run = adapter.startCompletion(
        profile,
        DirectCompletionRequest(
          remoteModelId: remoteModelId,
          messages: await buildDirectChatMessages(messages: messages),
          enableWebSearch: webSearch,
          tools: tools == null ? null : _toolRuntime(tools, approvals),
        ),
      );
      // Observed now: a run whose cleanup fails must not surface as an
      // uncaught error after the answer has already been stored.
      unawaited(run.done.then<void>((_) {}, onError: (Object _) {}));
      turn.cancel = () => run.cancel();

      // A provider that goes quiet is given up on -- but not while a tool
      // waits for the user's approval, which may take minutes and is not
      // the provider's silence.
      var lastEvent = DateTime.now();
      var timedOut = false;
      watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
        if (approvals.pending > 0) {
          lastEvent = DateTime.now();
          return;
        }
        if (DateTime.now().difference(lastEvent) > limits.idleTimeout) {
          timedOut = true;
          watchdog?.cancel();
          unawaited(run.cancel('idle').catchError((Object _) {}));
        }
      });

      await for (final event in run.events) {
        lastEvent = DateTime.now();
        if (turn.stopped) break;
        accumulator.apply(switch (event) {
          // The provider's words, minus anything that is a key.
          DirectStreamError() => DirectStreamError(
            sanitizeDirectProviderErrorMessage(
              event.message,
              sensitiveValues: secrets,
            ),
            statusCode: event.statusCode,
          ),
          _ => event,
        });
        if (event is DirectStreamDone && !accumulator.hasUsableOutput) {
          accumulator.apply(
            const DirectStreamError('The model returned an empty answer.'),
          );
        }
        turn.replace(accumulator.render(done: false));
        if (event is DirectStreamDone || event is DirectStreamError) break;
      }
      if (timedOut && accumulator.error == null) {
        accumulator.apply(
          const DirectStreamError('The provider stopped responding.'),
        );
      }
    } on Object catch (error) {
      if (!turn.stopped) {
        final normalized = normalizeDirectProviderError(error);
        accumulator.apply(
          DirectStreamError(
            sanitizeDirectProviderErrorMessage(
              normalized.message,
              sensitiveValues: secrets,
            ),
            statusCode: normalized.statusCode,
          ),
        );
      }
    }

    watchdog?.cancel();
    if (tools != null) unawaited(tools.close().catchError((Object _) {}));

    final failure = accumulator.error?.message;
    final completed = _completedDirectMessage(
      placeholder,
      accumulator,
      failure,
    );
    turn.replace(completed.content);
    if (failure != null) turn.fail(failure);

    if (location == null) {
      temporary.append(turn.chatId, completed);
    } else {
      try {
        final storedAs = await _storeDirectAnswer(
          location,
          turn.chatId,
          completed,
        );
        // Stored under the server's id already, if the remap beat its
        // event here.
        if (storedAs != turn.chatId) _followRemap(turn.chatId, storedAs);
      } on Object catch (error, stackTrace) {
        DebugLogger.error(
          'direct-answer-store-failed',
          scope: 'daemon/turns',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    _finish(turn.chatId);
  }

  /// Connects to the MCP servers chosen for this turn, if any.
  ///
  /// Chosen in the composer as `local_mcp:<server id>`, the id mobile uses.
  Future<DirectMcpToolSession?> _openMcpTools(List<String> toolIds) async {
    final chosen = <String>{
      for (final id in toolIds)
        if (id.startsWith(kDirectMcpToolIdPrefix))
          id.substring(kDirectMcpToolIdPrefix.length),
    };
    if (chosen.isEmpty) return null;
    final servers = await readSettled(
      _container,
      directMcpServersProvider.future,
    );
    final selected = <DirectMcpServer>[
      for (final server in servers)
        if (chosen.contains(server.id) && server.enabled) server,
    ];
    if (selected.length != chosen.length) {
      throw const DirectProviderException(
        'A selected MCP server is unavailable.',
      );
    }
    return _container.read(directMcpSessionBuilderProvider)(selected);
  }

  /// The tools the model may call, each call approved first.
  DirectToolRuntime _toolRuntime(
    DirectMcpToolSession session,
    _DirectApprovals approvals,
  ) => DirectToolRuntime(
    definitions: <DirectToolDefinition>[
      for (final definition in session.definitions)
        DirectToolDefinition(
          name: definition.modelName,
          serverId: definition.serverId,
          serverName: definition.serverName,
          remoteName: definition.remoteName,
          displayName: definition.displayName,
          description: definition.description,
          approvalFingerprint: definition.approvalFingerprint,
          inputSchema: definition.inputSchema,
        ),
    ],
    requestApproval: (callId, definition, arguments) =>
        _approve(callId, definition, arguments, approvals),
    execute: (name, arguments) async {
      final result = await session.execute(name, arguments);
      return DirectToolResult(text: result.text, isError: result.isError);
    },
  );

  /// Whether a tool call may run: already allowed for this session or
  /// always, or else asked in every window.
  DirectToolApprovalHandle _approve(
    String callId,
    DirectToolDefinition definition,
    Map<String, dynamic> arguments,
    _DirectApprovals approvals,
  ) {
    final fingerprint = definition.approvalFingerprint;
    final argumentsJson = jsonEncode(arguments);
    // What the user is asked to approve has to be readable in full.
    if (argumentsJson.length > kMaxDirectMcpApprovalArgumentCharacters) {
      throw const DirectProviderException(
        'The MCP tool arguments are too large to review safely.',
      );
    }
    Future<DirectToolApprovalDecision> decide() async {
      if (_sessionMcpApprovals[fingerprint] == definition.serverId) {
        return DirectToolApprovalDecision.allowSession;
      }
      final servers = await readSettled(
        _container,
        directMcpServersProvider.future,
      );
      final server = servers
          .where((candidate) => candidate.id == definition.serverId)
          .firstOrNull;
      if (server == null) return DirectToolApprovalDecision.deny;
      if (server.rememberedApprovals.any((a) => a.digest == fingerprint)) {
        return DirectToolApprovalDecision.allowAlways;
      }
      final ask = _uiRequests;
      if (ask is! UiRequestsService) return DirectToolApprovalDecision.deny;
      approvals.pending++;
      try {
        final choice = await ask.askMcpApproval(
          serverName: definition.serverName,
          toolName: definition.displayName,
          argumentsJson: argumentsJson,
          timeout: kDirectToolApprovalTimeout,
        );
        switch (choice) {
          case 'allow':
            return DirectToolApprovalDecision.allowOnce;
          case 'allowSession':
            _sessionMcpApprovals[fingerprint] = definition.serverId;
            return DirectToolApprovalDecision.allowSession;
          case 'allowAlways':
            await _container
                .read(directMcpServersProvider.notifier)
                .rememberApproval(
                  server,
                  DirectMcpRememberedApproval(
                    digest: fingerprint,
                    remoteToolName: definition.remoteName,
                    displayName: definition.displayName,
                    createdAt: DateTime.now().toUtc(),
                  ),
                );
            return DirectToolApprovalDecision.allowAlways;
          default:
            return DirectToolApprovalDecision.deny;
        }
      } finally {
        approvals.pending--;
      }
    }

    return DirectToolApprovalHandle(
      request: DirectToolApprovalRequest(
        id: 'mcp-approval-${TurnsService._uuid.v4()}',
        serverName: definition.serverName,
        toolName: definition.displayName,
        callId: callId,
        argumentsJson: argumentsJson,
      ),
      decision: decide(),
    );
  }

  static ChatMessage _completedDirectMessage(
    ChatMessage placeholder,
    DirectStreamingAccumulator accumulator,
    String? failure,
  ) {
    final metadata = <String, dynamic>{
      ...?placeholder.metadata,
      kDirectRawAssistantContentMetadataKey: accumulator.text,
      if (accumulator.reasoning.trim().isNotEmpty)
        kDirectRawAssistantReasoningMetadataKey: accumulator.reasoning,
      kDirectProviderMetadataKey: ?accumulator.providerMetadata,
    };
    return placeholder.copyWith(
      content: accumulator.render(done: true),
      output: <Map<String, dynamic>>[
        ...accumulator.toolOutput,
        ...?directProviderReplayOutput(
          assistantMessageId: placeholder.id,
          rawContent: accumulator.text,
          useIncompleteAnswerSentinel:
              accumulator.text.trim().isEmpty &&
              (accumulator.reasoning.trim().isNotEmpty ||
                  accumulator.toolOutput.isNotEmpty),
        ),
      ],
      sources: accumulator.sources,
      usage: accumulator.usage,
      metadata: metadata,
      error: failure == null ? null : ChatMessageError(content: failure),
      isStreaming: false,
    );
  }

  /// Writes the finished answer under the chat's current id.
  ///
  /// Current, not recorded: a `local:` chat can be given its server id by a
  /// sync that ran while the answer streamed, and the repository follows
  /// that remap for exactly this message.
  Future<String> _storeDirectAnswer(
    ChatDatabaseLocation location,
    String recordedChatId,
    ChatMessage answer,
  ) async {
    final repository = _container.read(chatDatabaseRepositoryProvider);
    final chatId =
        await repository.resolveCurrentChatIdForMessage(
          location,
          recordedChatId: recordedChatId,
          messageId: answer.id,
          expectedRole: 'assistant',
        ) ??
        recordedChatId;
    await _container.read(chatLocksProvider).runExclusive(chatId, () async {
      await repository.persistDirectMessages(
        location,
        chatId: chatId,
        messages: <MessageRowData>[
          directMessageRow(
            chatId: chatId,
            message: answer,
            parentId: answer.metadata?['parentId']?.toString(),
            childrenIds: const <String>[],
            orderIndex: 0,
          ),
        ],
        currentMessageId: answer.id,
        updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
    });
    if (location.storage == ChatStorageKind.openWebUi) {
      // Pushed now rather than on the next sync tick, so the answer is on
      // the server by the time anyone opens the chat there.
      try {
        await _container
            .read(syncEngineProvider.notifier)
            .drainNowForDatabase(location.database);
      } on Object catch (error) {
        DebugLogger.error(
          'direct-sync-drain-failed',
          scope: 'daemon/turns',
          error: error,
        );
      }
    }
    return chatId;
  }
}

/// How many of a turn's tool calls are waiting on the user.
final class _DirectApprovals {
  int pending = 0;
}
