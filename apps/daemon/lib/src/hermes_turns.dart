part of 'turns_service.dart';

/// Hermes Agent turns, in a chat that is a Hermes session.
///
/// Sessions live on the Hermes server; a new chat makes one first, so its
/// id -- `local:hermes_<session>` -- is final from the start and never
/// remapped. The run itself is the core's run transport, the one mobile
/// uses: the Responses API server's runs, or the desktop gateway's turns.
/// The daemon's part is what mobile's chat notifier does around it --
/// keeping the transcript, relaying the answer as `turn.*` events, and
/// asking the user when the agent wants approval to act.
extension _HermesTurns on TurnsService {
  /// The model [modelId] names, when it is the core's own Hermes model.
  ///
  /// Decided by the core's registry of the models it minted, never by the
  /// id: `hermes:agent:` is a string any server could put on a model.
  Future<bool> _isHermes(String modelId) async {
    try {
      final models = await readSettled(_container, modelsProvider.future);
      final model = models.where((m) => m.id == modelId).firstOrNull;
      return model != null && isHermesModel(model);
    } on Object {
      return false;
    }
  }

  Future<SendTurnAccepted> _sendHermes(
    SendTurn request, {
    required String model,
    required String text,
  }) async {
    final hermes = _hermes;
    if (hermes == null) {
      throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      );
    }
    final config = _container.read(hermesConfigProvider.notifier);
    if (_container.read(hermesConfigProvider).mode ==
        HermesBackendMode.responsesApi) {
      // The long-term memory key, made before the first turn as mobile
      // does. Made after reading the service would rebuild it underneath.
      await config.ensureSessionKey();
    }
    final service = _container.read(hermesApiServiceProvider);
    if (service == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'Hermes is not configured',
      );
    }
    // Said as what it is: without this the request failed further in, and
    // the window could only call it a connection problem.
    if (hermesAwaitsSignIn(_container.read(hermesConfigProvider))) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        args: <String, String>{'backend': 'hermes'},
        debugMessage: 'sign in to Hermes first',
      );
    }

    String sessionId;
    if (request.chatId case final chatId?) {
      sessionId =
          validateHermesOpaqueIdentifier(hermesSessionOf(chatId)) ??
          (throw const RpcError(
            code: ConduitErrorCodes.invalidParams,
            debugMessage: 'that chat is not a Hermes session',
          ));
      _requireIdle(chatId);
    } else {
      final title = text.split('\n').first;
      sessionId = await service.createSession(
        title: title.length > 60 ? '${title.substring(0, 60)}…' : title,
      );
      hermes.announceSessions();
    }
    final chatId = hermesChatId(sessionId);
    final history = await hermes.transcript(sessionId);

    final now = DateTime.now();
    final userMessage = ChatMessage(
      id: TurnsService._uuid.v4(),
      role: 'user',
      content: text,
      timestamp: now,
    );
    final assistantId = TurnsService._uuid.v4();
    hermes.append(sessionId, userMessage);

    final turn = _ActiveTurn(
      chatId: chatId,
      messageId: assistantId,
      model: model,
    )..direct = true;
    _active[chatId] = turn;
    _events.publish(
      ConduitEvents.turnStarted,
      scope: chatId,
      payload: TurnStarted(
        chatId: chatId,
        messageId: assistantId,
        model: model,
      ).toJson(),
    );
    turn.ticker = Timer.periodic(
      TurnsService._deltaInterval,
      (_) => _emitDelta(turn),
    );

    unawaited(
      _runHermes(
        turn,
        service: service,
        sessionId: sessionId,
        text: text,
        history: history,
      ),
    );
    return SendTurnAccepted(
      chatId: chatId,
      userMessageId: userMessage.id,
      assistantMessageId: assistantId,
    );
  }

  Future<void> _runHermes(
    _ActiveTurn turn, {
    required HermesBackendService service,
    required String sessionId,
    required String text,
    required List<ChatMessage> history,
  }) async {
    final hermes = _hermes!;
    final cancelToken = CancelToken();
    turn.cancel = () async {
      if (!cancelToken.isCancelled) cancelToken.cancel('stopped');
      if (service is HermesDesktopApiService) {
        await service.interrupt(sessionId).catchError((Object _) {});
      }
    };
    final registry = _container.read(hermesRunRegistryProvider);
    final HermesRunKey runKey = (
      ownerConversationId: turn.chatId,
      assistantMessageId: turn.messageId,
      backendIdentity: null,
    );
    var message = ChatMessage(
      id: turn.messageId,
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
      model: turn.model,
      isStreaming: true,
    );
    final done = Completer<void>();
    final asked = <String>{};

    void update(ChatMessage Function(ChatMessage) updater) {
      message = updater(message.copyWith(content: turn.text));
      if (message.content != turn.text) turn.replace(message.content);
      if (message.error?.content case final error?) turn.fail(error);
      final approval = message.metadata?[kHermesApprovalMeta];
      if (approval is Map &&
          approval['state'] == 'pending' &&
          approval['approvalId'] is String &&
          asked.add(approval['approvalId'] as String)) {
        unawaited(
          _answerHermesApproval(
            service,
            approval.cast<String, dynamic>(),
            sessionId: sessionId,
          ),
        );
      }
    }

    void finished() {
      if (!done.isCompleted) done.complete();
    }

    try {
      if (service is HermesApiService) {
        // The runs endpoint replays the conversation it is given; the
        // session keeps the server's own record of it.
        await dispatchHermesRun(
          service: service,
          registry: registry,
          assistantMessageId: turn.messageId,
          runKey: runKey,
          input: text,
          sessionId: sessionId,
          conversationHistory: <Map<String, dynamic>>[
            for (final previous in history)
              if (previous.content.trim().isNotEmpty &&
                  (previous.role == 'user' || previous.role == 'assistant'))
                <String, dynamic>{
                  'role': previous.role,
                  'content': previous.content,
                },
          ],
          cancelToken: cancelToken,
          appendContent: turn.append,
          replaceContent: turn.replace,
          appendStatus: (_) {},
          updateMessage: update,
          finishStreaming: finished,
          completeStreamingUi: finished,
        );
      } else if (service is HermesDesktopTurnService) {
        await dispatchHermesTurn(
          startTurn: (token) => service.streamDesktopResponse(
            HermesChatInput.text(text),
            sessionId: sessionId,
            options: const HermesDesktopSessionOptions(),
            cancelToken: token,
          ),
          sensitiveValues: service.config.sensitiveValues,
          registry: registry,
          assistantMessageId: turn.messageId,
          runKey: runKey,
          cancelToken: cancelToken,
          appendContent: turn.append,
          replaceContent: turn.replace,
          appendStatus: (_) {},
          updateMessage: update,
          finishStreaming: finished,
          completeStreamingUi: finished,
        );
      } else {
        throw StateError('this Hermes server cannot take turns');
      }
      await done.future;
    } on Object catch (error) {
      if (!turn.stopped) turn.fail('$error');
    }

    turn.flush();
    hermes.append(
      sessionId,
      message.copyWith(content: turn.text, isStreaming: false),
    );
    hermes.announceSessions();
    _finish(turn.chatId);
  }

  /// Asks the user whether the agent may go on, and tells Hermes.
  Future<void> _answerHermesApproval(
    HermesBackendService service,
    Map<String, dynamic> approval, {
    required String sessionId,
  }) async {
    final ask = _uiRequests;
    final approvalId = approval['approvalId'] as String;
    final runId = approval['runId'] as String?;
    final choices = <String>[
      for (final choice in (approval['choices'] as List?) ?? const <Object?>[])
        '$choice',
    ];
    final choice = ask is UiRequestsService
        ? await ask.askHermesApproval(
            summary: approval['summary']?.toString() ?? '',
            choices: choices.isEmpty ? const <String>['once', 'deny'] : choices,
          )
        : 'deny';
    try {
      if (service is HermesDesktopApiService) {
        await service.resolveApprovalChoiceForSession(
          sessionId,
          approvalId: approvalId,
          choice: choice,
        );
      } else if (runId != null) {
        await service.resolveApproval(
          runId,
          approvalId: approvalId,
          approved: choice != 'deny',
        );
      }
    } on Object catch (error) {
      DebugLogger.error(
        'hermes-approval-failed',
        scope: 'daemon/turns',
        error: error,
      );
    }
  }
}
