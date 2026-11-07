part of 'hermes_desktop_api_service.dart';

/// The longest spoken context Hermes keeps with a voice-live turn.
const int _kMaxHermesVoiceContext = 6000;

/// `prompt.submit`'s parameters for [text] in session [runtimeId]. A turn a
/// voice-live call handed over carries [voiceContext], the recent spoken
/// conversation, which only the model reads; the session stores `text`.
/// Context past the bound keeps its newest part.
@visibleForTesting
Map<String, Object?> hermesPromptSubmitParams({
  required String runtimeId,
  required String text,
  String? voiceContext,
}) => {
  'session_id': runtimeId,
  'text': text,
  if (voiceContext != null) ...{
    'surface': 'voice-live',
    'voice_context': voiceContext.length > _kMaxHermesVoiceContext
        ? voiceContext.substring(voiceContext.length - _kMaxHermesVoiceContext)
        : voiceContext,
  },
};

extension _HermesDesktopTurnRuntime on HermesDesktopApiService {
  Future<HermesResponseStream> _runtimeStreamDesktopResponse(
    HermesChatInput input, {
    String? sessionId,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
    String? voiceContext,
  }) async {
    final storedId =
        sessionId ??
        await createDesktopSession(options: options, cancelToken: cancelToken);
    var binding = await _resume(storedId);
    final freshSession = _freshSessionIds.contains(storedId);
    final sessionState =
        _sessionTurnStates[binding.storedId] ??
        _sessionTurnStates[binding.runtimeId];
    if (!freshSession &&
        (sessionState == null ||
            sessionState == HermesDesktopTurnState.unsupportedGateway)) {
      throw StateError(
        'This Hermes Desktop Gateway is too old for safe chat recovery. '
        'Upgrade Hermes and try again.',
      );
    }
    if (!_sessionProfiles.containsKey(binding.storedId)) {
      await _applySessionOptions(binding, options);
    }
    final attached = await _attachInput(binding.runtimeId, input);
    var text = attached.text;
    final stagedPaths = attached.paths;
    if (cancelToken?.isCancelled == true) {
      await _detachStaged(binding.runtimeId, stagedPaths);
      throw cancelToken!.cancelError!;
    }
    // A session authority admits a prompt once per submission id: a submit
    // sent again after a lost answer is the same prompt, not a second one.
    final canonical = _canonical;
    final submissionId = canonical ? const Uuid().v4() : null;
    // The admission Hermes gave the prompt (canonical wire): its own events
    // carry it, so another prompt's turn on the session is told apart.
    String? admissionId;
    final controller = StreamController<HermesRunEvent>();
    var terminal = false;
    final seenEventIds = <String>{};
    final seenEventOrder = Queue<String>();
    var activeRuntimeId = binding.runtimeId;
    var promptAcknowledged = false;
    // Set once the gateway shows this turn running. Until then an idle
    // `session.info` is left over from before the prompt (session setup, a
    // late MCP refresh) and must not end the turn before it starts.
    var turnStarted = false;
    // Set when Hermes admitted the prompt into the session owner's queue
    // instead of running it here: only the owner's message.start and
    // message.complete are relayed, so message.complete ends the turn.
    var forwarded = false;
    final segments = HermesDeltaSegments();
    var disconnectReconciliationRunning = false;
    final eventsBeforePromptAcknowledgement = Queue<HermesDesktopEvent>();
    late final StreamSubscription<HermesDesktopEvent> subscription;
    late final StreamSubscription<void> disconnectSubscription;

    bool hasAuthoritativeState() {
      final state =
          _sessionTurnStates[binding.storedId] ??
          _sessionTurnStates[binding.runtimeId];
      return state != null &&
          state != HermesDesktopTurnState.unsupportedGateway;
    }

    void finish({String? error, bool authoritativeIdle = false}) {
      if (terminal) return;
      terminal = true;
      _eventBuffer.deactivate(activeRuntimeId);
      if (authoritativeIdle && promptAcknowledged && hasAuthoritativeState()) {
        _applyAuthoritativeRunning(
          false,
          storedId: binding.storedId,
          runtimeId: binding.runtimeId,
        );
      }
      if (error != null) controller.add(HermesRunError(error));
      controller.add(const HermesRunDone());
      unawaited(subscription.cancel());
      unawaited(disconnectSubscription.cancel());
      unawaited(controller.close());
    }

    void handleEvent(HermesDesktopEvent event) {
      if (event.sessionId != null && event.sessionId != binding.runtimeId) {
        return;
      }
      if (!promptAcknowledged) {
        eventsBeforePromptAcknowledgement.addLast(event);
        if (eventsBeforePromptAcknowledgement.length > 4096) {
          eventsBeforePromptAcknowledgement.removeFirst();
        }
        return;
      }
      // Another prompt's turn on this session (one queued ahead, another
      // device's): its reply is not this one, and it neither starts nor
      // ends this turn. Its approvals and questions still need an answer.
      final foreign =
          admissionId != null &&
          event.admissionId != null &&
          event.admissionId != admissionId;
      if (foreign &&
          !event.type.endsWith('.request') &&
          !event.type.endsWith('.expire')) {
        return;
      }
      final payload = event.payload;
      final eventId = _eventIdentity(event);
      if (eventId != null) {
        if (!seenEventIds.add(eventId)) return;
        seenEventOrder.addLast(eventId);
        if (seenEventOrder.length > 4096) {
          seenEventIds.remove(seenEventOrder.removeFirst());
        }
      }
      String value(String key) => payload[key]?.toString() ?? '';
      String firstValue(Iterable<String> keys) => keys
          .map(value)
          .firstWhere((candidate) => candidate.isNotEmpty, orElse: () => '');
      // Only the reply's own events show that the submitted turn is running.
      // A late tool, subagent or request event can belong to earlier work, and
      // must not let an idle session.info end this turn.
      if (event.type.startsWith('message.') ||
          (event.type == 'session.info' && payload['running'] == true)) {
        turnStarted = true;
      }
      if (event.type == 'message.delta') {
        final text = value('delta').isNotEmpty ? value('delta') : value('text');
        final fresh = segments.unseen(
          turnId: payload['turn_id'],
          segment: payload['segment'],
          offset: payload['offset'],
          text: text,
        );
        if (fresh == null) return;
        if (fresh.length != text.length) {
          controller.add(HermesTokenDelta(fresh));
          return;
        }
      }
      if (_projectHermesTurnEvent(
        event,
        add: controller.add,
        value: value,
        firstValue: firstValue,
      )) {
        return;
      }
      switch (event.type) {
        case 'message.complete':
          final content = value('content').isNotEmpty
              ? value('content')
              : value('text');
          if (content.isNotEmpty) controller.add(HermesFinalOutput(content));
          if (value('status').toLowerCase() == 'error' ||
              value('error').isNotEmpty) {
            finish(
              error: value('error').isEmpty
                  ? 'Hermes failed to complete the response.'
                  : value('error'),
            );
          } else if (forwarded) {
            // The owner wrote the reply to the stored transcript; read it.
            finish(authoritativeIdle: true);
            _emitTranscriptChange(storedId);
          }
        case 'approval.request':
          final requestId = validateHermesOpaqueIdentifier(
            payload['request_id'] ?? payload['id'],
          );
          if (requestId != null) {
            final prompt = value('command').isNotEmpty
                ? value('command')
                : value('description');
            unawaited(
              _rememberPendingDecision(
                binding,
                requestId: requestId,
                kind: HermesPendingDesktopDecisionKind.approval,
                prompt: prompt,
                choices: _desktopDecisionChoices(payload['choices']),
              ),
            );
            controller.add(
              HermesApprovalRequested(
                approvalId: requestId,
                summary: prompt,
                choices: _desktopDecisionChoices(payload['choices']),
                raw: payload,
              ),
            );
          }
        case 'clarify.request':
        case 'sudo.request':
        case 'secret.request':
        case 'mcp.setup.request':
          final requestId = validateHermesOpaqueIdentifier(
            payload['request_id'] ?? payload['id'],
          );
          if (requestId != null) {
            final kind = switch (event.type) {
              'sudo.request' => HermesDecisionKind.sudo,
              'secret.request' => HermesDecisionKind.secret,
              'mcp.setup.request' => HermesDecisionKind.mcpSetup,
              _ => HermesDecisionKind.clarification,
            };
            final prompt = switch (event.type) {
              'clarify.request' => value('question'),
              'secret.request' =>
                value('prompt').isEmpty ? value('env_var') : value('prompt'),
              'mcp.setup.request' =>
                value('reason').isEmpty ? value('server') : value('reason'),
              _ => value('prompt'),
            };
            unawaited(
              _rememberPendingDecision(
                binding,
                requestId: requestId,
                kind: switch (kind) {
                  HermesDecisionKind.clarification =>
                    HermesPendingDesktopDecisionKind.clarification,
                  HermesDecisionKind.sudo =>
                    HermesPendingDesktopDecisionKind.sudo,
                  HermesDecisionKind.secret =>
                    HermesPendingDesktopDecisionKind.secret,
                  HermesDecisionKind.mcpSetup =>
                    HermesPendingDesktopDecisionKind.mcpSetup,
                },
                prompt: prompt,
                mcpServer: kind == HermesDecisionKind.mcpSetup
                    ? value('server')
                    : null,
                mcpAction: kind == HermesDecisionKind.mcpSetup
                    ? value('action')
                    : null,
                choices: kind == HermesDecisionKind.clarification
                    ? _desktopDecisionChoices(payload['choices'])
                    : const <String>[],
                multiSelect:
                    kind == HermesDecisionKind.clarification &&
                    payload['multi_select'] == true,
              ),
            );
            controller.add(
              HermesDecisionRequested(
                kind: kind,
                requestId: requestId,
                prompt: prompt,
                raw: payload,
              ),
            );
          }
        case 'approval.responded':
        case 'approval.expire':
        case 'clarify.expire':
        case 'sudo.expire':
        case 'secret.expire':
        case 'mcp.setup.expire':
          final requestId = validateHermesOpaqueIdentifier(
            payload['request_id'] ?? payload['id'],
          );
          if (requestId != null) {
            unawaited(
              HermesPendingDecisionStore.resolve(
                origin: _origin,
                connectionId: config.connectionId,
                runtimeId: binding.runtimeId,
                requestId: requestId,
              ),
            );
          }
        case 'session.info':
          // A partial info without `running` says nothing about the turn.
          if (payload['running'] == false &&
              promptAcknowledged &&
              turnStarted) {
            finish(authoritativeIdle: true);
          }
        case 'error':
          if (promptAcknowledged) {
            finish(
              error: value('message').isEmpty
                  ? 'Hermes failed.'
                  : value('message'),
            );
          }
      }
    }

    _eventBuffer.activate(activeRuntimeId);
    subscription = _rpc.events.listen(handleEvent);
    disconnectSubscription = _rpc.disconnects.listen((_) {
      if (terminal || !promptAcknowledged || disconnectReconciliationRunning) {
        return;
      }
      disconnectReconciliationRunning = true;
      unawaited(() async {
        try {
          final reconciled = await _resumeSnapshot(storedId, refresh: true);
          if (terminal) return;
          binding = reconciled.binding;
          if (reconciled.binding.runtimeId != activeRuntimeId) {
            _eventBuffer.deactivate(activeRuntimeId);
            activeRuntimeId = reconciled.binding.runtimeId;
            for (final event in _eventBuffer.activate(activeRuntimeId)) {
              if (!terminal) handleEvent(event);
            }
            _emitTranscriptChange(storedId);
          }
          if (reconciled.running == true) return;
          finish(authoritativeIdle: true);
          _emitTranscriptChange(storedId);
        } catch (error) {
          if (!terminal) finish(error: error.toString());
        } finally {
          disconnectReconciliationRunning = false;
        }
      }());
    });
    Future<void> interruptTurn() async {
      try {
        if (canonical) {
          await _canonicalInterrupt(binding, admissionId: admissionId);
        } else {
          await _rpc.request<Object?>(
            'session.interrupt',
            params: {
              'session_id': binding.runtimeId,
              ..._sessionScope(binding.storedId),
            },
          );
        }
      } catch (_) {}
    }

    Future<Object?> submitPrompt() => _rpc.request<Object?>(
      'prompt.submit',
      params: {
        ...hermesPromptSubmitParams(
          runtimeId: binding.runtimeId,
          text: text,
          voiceContext: voiceContext,
        ),
        'submission_id': ?submissionId,
        if (attached.attachments.isNotEmpty)
          'attachments': attached.attachments,
        ..._sessionScope(binding.storedId),
      },
    );

    void adoptAdmission(Object? submitted) {
      if (!canonical || submitted is! Map) return;
      admissionId = validateHermesOpaqueIdentifier(submitted['admission_id']);
    }

    void replayEventsBeforeAcknowledgement() {
      for (final event in List<HermesDesktopEvent>.of(
        eventsBeforePromptAcknowledgement,
      )) {
        if (!terminal) handleEvent(event);
      }
      eventsBeforePromptAcknowledgement.clear();
    }

    cancelToken?.whenCancel.then((_) async {
      if (terminal) return;
      await interruptTurn();
      if (!promptAcknowledged) {
        await _detachStaged(binding.runtimeId, stagedPaths);
      }
      finish();
    });

    controller.add(HermesResponseCreated(binding.runtimeId));
    Set<String> promptBaseline = const {};
    try {
      if (text.trimLeft().startsWith('/')) {
        final slash = await _dispatchSlash(binding.runtimeId, text.trim());
        if (slash.display != null && slash.display!.isNotEmpty) {
          controller.add(HermesFinalOutput(slash.display!));
        }
        if (slash.prefill != null && slash.prefill!.isNotEmpty) {
          controller.add(HermesComposerPrefill(slash.prefill!));
        }
        if (slash.submit == null) {
          await _detachStaged(binding.runtimeId, stagedPaths);
          finish();
          return HermesResponseStream(
            events: controller.stream,
            sessionId: storedId,
          );
        }
        text = slash.submit!;
      }
      if (cancelToken?.isCancelled == true) {
        await _detachStaged(binding.runtimeId, stagedPaths);
        throw cancelToken!.cancelError!;
      }
      // A lost submit is recovered by its submission id on the canonical
      // wire; elsewhere by finding the prompt in the transcript.
      promptBaseline = freshSession || canonical
          ? const <String>{}
          : await _matchingPromptMarkers(storedId, text);
      if (cancelToken?.isCancelled == true) {
        await _detachStaged(binding.runtimeId, stagedPaths);
        throw cancelToken!.cancelError!;
      }
      eventsBeforePromptAcknowledgement.clear();
      if (freshSession) _freshSessionIds.remove(storedId);
      final submitted = await submitPrompt();
      forwarded = submitted is Map && submitted['forwarded'] == true;
      adoptAdmission(submitted);
      if (cancelToken?.isCancelled == true) {
        promptAcknowledged = true;
        await interruptTurn();
        finish();
        return HermesResponseStream(
          events: controller.stream,
          sessionId: storedId,
        );
      }
      promptAcknowledged = true;
      if (hasAuthoritativeState()) {
        _applyAuthoritativeRunning(
          true,
          storedId: binding.storedId,
          runtimeId: binding.runtimeId,
        );
      }
      replayEventsBeforeAcknowledgement();
    } catch (error) {
      DebugLogger.error(
        'prompt-submit-failed',
        scope: 'hermes/desktop/ws',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (canonical &&
          error is HermesDesktopRpcException &&
          error.deliveryAmbiguous) {
        try {
          // Sent again under the same submission id, the prompt is admitted
          // once: Hermes answers with the admission the lost submit made.
          binding = (await _resumeSnapshot(storedId, refresh: true)).binding;
          final submitted = await submitPrompt();
          adoptAdmission(submitted);
          promptAcknowledged = true;
          if (cancelToken?.isCancelled == true) {
            await interruptTurn();
            finish();
          } else if (submitted is Map && submitted['status'] == 'terminal') {
            // It ran while the socket was down: its reply is stored.
            finish(authoritativeIdle: true);
            _emitTranscriptChange(storedId);
          } else {
            if (hasAuthoritativeState()) {
              _applyAuthoritativeRunning(
                true,
                storedId: binding.storedId,
                runtimeId: binding.runtimeId,
              );
            }
            replayEventsBeforeAcknowledgement();
          }
          return HermesResponseStream(
            events: controller.stream,
            sessionId: storedId,
          );
        } catch (reconcileError) {
          DebugLogger.error(
            'prompt-submit-reconcile-failed',
            scope: 'hermes/desktop/ws',
            data: {'errorType': reconcileError.runtimeType.toString()},
          );
        }
      } else if (error is HermesDesktopRpcException &&
          error.deliveryAmbiguous) {
        try {
          final reconciled = await _resumeSnapshot(storedId, refresh: true);
          binding = reconciled.binding;
          if (reconciled.binding.runtimeId != activeRuntimeId) {
            _eventBuffer.deactivate(activeRuntimeId);
            activeRuntimeId = reconciled.binding.runtimeId;
            for (final event in _eventBuffer.activate(activeRuntimeId)) {
              if (!terminal) handleEvent(event);
            }
          }
          final accepted =
              reconciled.running == true ||
              await _transcriptContainsNewPrompt(
                storedId,
                text,
                promptBaseline,
              );
          if (accepted) {
            promptAcknowledged = true;
            replayEventsBeforeAcknowledgement();
            if (cancelToken?.isCancelled == true) {
              await interruptTurn();
              finish();
              return HermesResponseStream(
                events: controller.stream,
                sessionId: storedId,
              );
            }
            if (reconciled.running != true) {
              finish(authoritativeIdle: true);
              _emitTranscriptChange(storedId);
            } else {
              _applyAuthoritativeRunning(
                true,
                storedId: binding.storedId,
                runtimeId: binding.runtimeId,
              );
            }
            return HermesResponseStream(
              events: controller.stream,
              sessionId: storedId,
            );
          }
        } catch (reconcileError) {
          DebugLogger.error(
            'prompt-submit-reconcile-failed',
            scope: 'hermes/desktop/ws',
            data: {'errorType': reconcileError.runtimeType.toString()},
          );
        }
      }
      await _detachStaged(binding.runtimeId, stagedPaths);
      if (freshSession) _freshSessionIds.add(storedId);
      finish(error: error.toString());
    }
    return HermesResponseStream(events: controller.stream, sessionId: storedId);
  }

  String? _eventIdentity(HermesDesktopEvent event) {
    final payload = event.payload;
    final explicit =
        payload['event_id'] ?? payload['sequence_id'] ?? payload['sequence'];
    if (explicit != null) return '${event.type}:$explicit';
    // A decision is one card however often it is shown (live, then again
    // from a snapshot).
    if (event.type.endsWith('.request')) {
      final request = payload['request_id'] ?? payload['id'];
      // A connection card offered again is a new offer of the same card.
      final offer = payload['offer'];
      if (request != null) {
        return '${event.type}:$request${offer is int ? '#$offer' : ''}';
      }
    }
    // A session authority numbers every event of a session's stream.
    if (event.seq != null && event.replayEpoch != null) {
      return 'seq:${event.replayEpoch}:${event.seq}';
    }
    if (event.type == 'message.complete') {
      final message = payload['message_id'] ?? payload['id'];
      if (message != null) return '${event.type}:$message';
    }
    return null;
  }

  String? _storedIdForRuntime(String? runtimeId) {
    if (runtimeId == null) return null;
    for (final entry in _bindings.entries) {
      if (entry.value.runtimeId == runtimeId) return entry.value.storedId;
    }
    return null;
  }

  /// Saves the decision [event] asks for; resolves to whether that changed
  /// what is saved (a replay of one already saved changes nothing).
  Future<bool> _persistPendingDecisionEvent(HermesDesktopEvent event) async {
    final storedId = _storedIdForRuntime(event.sessionId);
    final runtimeId = validateHermesOpaqueIdentifier(event.sessionId);
    final requestId = validateHermesOpaqueIdentifier(
      event.payload['request_id'] ?? event.payload['id'],
      sensitiveValues: config.sensitiveValues,
    );
    if (storedId == null || runtimeId == null || requestId == null) return false;
    final kind = switch (event.type) {
      'approval.request' => HermesPendingDesktopDecisionKind.approval,
      'clarify.request' => HermesPendingDesktopDecisionKind.clarification,
      'sudo.request' => HermesPendingDesktopDecisionKind.sudo,
      'secret.request' => HermesPendingDesktopDecisionKind.secret,
      'mcp.setup.request' => HermesPendingDesktopDecisionKind.mcpSetup,
      _ => null,
    };
    if (kind == null) return false;
    final prompt = switch (event.type) {
      'approval.request' =>
        event.payload['command'] ?? event.payload['description'],
      'clarify.request' => event.payload['question'],
      'secret.request' => event.payload['prompt'] ?? event.payload['env_var'],
      'mcp.setup.request' => event.payload['reason'] ?? event.payload['server'],
      _ => event.payload['prompt'],
    };
    return HermesPendingDecisionStore.upsert(
      origin: _origin,
      connectionId: config.connectionId,
      storedSessionId: storedId,
      runtimeId: runtimeId,
      requestId: requestId,
      kind: kind,
      prompt: prompt?.toString(),
      mcpServer: event.payload['server']?.toString(),
      mcpAction: event.payload['action']?.toString(),
      choices: _desktopDecisionChoices(event.payload['choices']),
      multiSelect: event.payload['multi_select'] == true,
      sensitiveValues: config.sensitiveValues,
      profile: _sessionProfiles[storedId],
    );
  }

  Future<void> _rememberPendingDecision(
    HermesSessionBinding binding, {
    required String requestId,
    required HermesPendingDesktopDecisionKind kind,
    String? prompt,
    String? mcpServer,
    String? mcpAction,
    Iterable<Object?> choices = const <Object?>[],
    bool multiSelect = false,
  }) => HermesPendingDecisionStore.upsert(
    origin: _origin,
    connectionId: config.connectionId,
    storedSessionId: binding.storedId,
    runtimeId: binding.runtimeId,
    requestId: requestId,
    kind: kind,
    prompt: prompt,
    mcpServer: mcpServer,
    mcpAction: mcpAction,
    choices: choices,
    multiSelect: multiSelect,
    sensitiveValues: config.sensitiveValues,
    profile: _sessionProfiles[binding.storedId],
  );

  Future<void> _applySessionOptions(
    HermesSessionBinding binding,
    HermesDesktopSessionOptions options,
  ) async {
    final selection = hermesDesktopSessionModelSelection(
      options.model,
      options.provider,
    );
    final reasoning = options.reasoningEffort?.trim();
    final fingerprint = options.fingerprint;
    if (_appliedSessionOptions[binding.storedId] == fingerprint) return;
    final modelSwitch = selection.model == null
        ? null
        : '${selection.model}${selection.provider == null ? '' : ' --provider ${selection.provider}'} --session';
    // Session options resolve and PERSIST profile config. A bot chat lives in
    // another profile, so these must never fall back to the connection's.
    final scope = _sessionScope(binding.storedId);
    if (reasoning?.isEmpty != false) {
      final global = _object(
        await _rpc.request<Object?>(
          'config.get',
          params: {'key': 'reasoning', ...scope},
        ),
      )['value']?.toString().trim();
      if (global == null || global.isEmpty) {
        throw const FormatException(
          'Hermes did not return its configured reasoning effort.',
        );
      }
      await _rpc.request<Object?>(
        'config.set',
        params: {
          'session_id': binding.runtimeId,
          'key': 'reasoning',
          'value': global,
          'scope': 'global',
          ...scope,
        },
      );
    }
    if (_canonical && selection.model != null) {
      // A session authority switches a session's model as a fenced edit;
      // it refuses `config.set model`.
      await _canonicalMutate(binding, 'model', {
        'model': selection.model,
        'provider': ?selection.provider,
      });
    }
    for (final option in <(String, Object?)>[
      if (!_canonical) ('model', modelSwitch),
      ('reasoning', reasoning?.isEmpty == true ? null : reasoning),
      (
        'fast',
        options.fast == null ? null : (options.fast! ? 'fast' : 'normal'),
      ),
    ]) {
      if (option.$2 == null) continue;
      await _rpc.request<Object?>(
        'config.set',
        params: {
          'session_id': binding.runtimeId,
          'key': option.$1,
          'value': option.$2,
          ...scope,
        },
      );
    }
    _appliedSessionOptions[binding.storedId] = fingerprint;
  }

  /// Profile scope for a helper that only carries a runtime id. Resolves the
  /// stored id first so a bot chat never travels under the connection profile.
  Map<String, dynamic> _runtimeScope(String runtimeId) =>
      _sessionScope(_storedIdForRuntime(runtimeId) ?? runtimeId);

  Future<({String? submit, String? display, String? prefill})> _dispatchSlash(
    String runtimeId,
    String command, {
    int aliasDepth = 0,
  }) async {
    if (aliasDepth > 8) throw StateError('Hermes slash alias loop detected.');
    final edit = _canonical ? hermesCanonicalSlashMutation(command) : null;
    if (edit != null) {
      final storedId = _storedIdForRuntime(runtimeId) ?? runtimeId;
      final receipt = await _canonicalMutate(
        await _resume(storedId),
        edit.operation,
        edit.payload,
      );
      return (
        submit: null,
        display: hermesCanonicalMutationSummary(edit.operation, receipt),
        prefill: null,
      );
    }
    Object? raw;
    try {
      raw = await _rpc.request<Object?>(
        'slash.exec',
        params: {
          'session_id': runtimeId,
          'command': command.replaceFirst(RegExp(r'^/+'), ''),
          ..._runtimeScope(runtimeId),
        },
      );
    } on HermesDesktopRpcException catch (error) {
      if (!hermesSlashNeedsCommandDispatch(error)) rethrow;
      final parts = command.replaceFirst(RegExp(r'^/+'), '').split(' ');
      raw = await _rpc.request<Object?>(
        'command.dispatch',
        params: {
          'session_id': runtimeId,
          'name': parts.first,
          'arg': parts.skip(1).join(' '),
          ..._runtimeScope(runtimeId),
        },
      );
    }
    final result = _object(raw);
    final type = result['type']?.toString();
    final message = result['message']?.toString();
    switch (type) {
      case 'send':
      case 'skill':
        return (
          submit: message?.isNotEmpty == true ? message : command,
          display: result['display']?.toString(),
          prefill: null,
        );
      case 'alias':
        final target = result['target']?.toString();
        if (target == null || target.isEmpty) {
          return (submit: null, display: null, prefill: null);
        }
        return _dispatchSlash(
          runtimeId,
          hermesExpandedAliasCommand(target, command),
          aliasDepth: aliasDepth + 1,
        );
      case 'prefill':
        return (
          submit: null,
          display: result['notice']?.toString(),
          prefill: message ?? result['text']?.toString(),
        );
      default:
        return (
          submit: null,
          display:
              result['output']?.toString() ??
              result['display']?.toString() ??
              '/${command.replaceFirst(RegExp(r'^/+'), '')}: no output',
          prefill: null,
        );
    }
  }

  /// Stages [input]'s images and files for the next prompt. Returns its
  /// text, the staged image paths (released again if the prompt is not
  /// sent), and the images a session authority's `prompt.submit` must name:
  /// there, staging alone attaches nothing.
  Future<
    ({
      String text,
      List<String> paths,
      List<Map<String, String>> attachments,
    })
  >
  _attachInput(String runtimeId, HermesChatInput input) async {
    if (input is HermesTextChatInput) {
      return (
        text: input.text,
        paths: const <String>[],
        attachments: const <Map<String, String>>[],
      );
    }
    if (input is! HermesMultimodalChatInput) {
      return (
        text: input.toJson().toString(),
        paths: const <String>[],
        attachments: const <Map<String, String>>[],
      );
    }
    final text = StringBuffer();
    final paths = <String>[];
    final attachments = <Map<String, String>>[];
    try {
      for (final part in input.parts) {
        if (part is HermesInputTextPart) {
          if (text.isNotEmpty) text.writeln();
          text.write(part.text);
        } else if (part is HermesInputImagePart) {
          _requireDesktopUploadContract();
          final comma = part.imageUrl.indexOf(',');
          if (!part.imageUrl.startsWith('data:image/') || comma < 0) {
            throw const HermesChatInputException(
              'Desktop Gateway image uploads require local image data.',
            );
          }
          final result = _object(
            await _rpc.request<Object?>(
              'image.attach_bytes',
              params: {
                'session_id': runtimeId,
                'content_base64': part.imageUrl.substring(comma + 1),
                ..._runtimeScope(runtimeId),
              },
            ),
          );
          final path = result['path']?.toString();
          if (path?.isNotEmpty == true) paths.add(path!);
          final mime = result['mime']?.toString();
          if (_canonical && path?.isNotEmpty == true && mime != null) {
            attachments.add({'path': path!, 'mime': mime});
          }
        } else if (part is HermesInputFilePart) {
          _requireDesktopUploadContract();
          // A session authority stages a PDF like any file, by reference;
          // `pdf.attach` only knows the dashboard's own sessions.
          final pdfPages = part.isPdf && !_canonical;
          final result = _object(
            await _rpc.request<Object?>(
              pdfPages ? 'pdf.attach' : 'file.attach',
              params: pdfPages
                  ? {
                      'session_id': runtimeId,
                      'content_base64': part.base64Data,
                      'filename': part.filename,
                      ..._runtimeScope(runtimeId),
                    }
                  : {
                      'session_id': runtimeId,
                      'name': part.filename,
                      'data_url': part.dataUrl,
                      ..._runtimeScope(runtimeId),
                    },
            ),
          );
          if (result['attached'] != true) {
            throw StateError('Hermes did not accept ${part.filename}.');
          }
          if (pdfPages) {
            for (final page in _objects(result['pages'])) {
              final path = page['path']?.toString();
              if (path?.isNotEmpty == true) paths.add(path!);
            }
            final pdfText = result['text']?.toString();
            if (pdfText != null && pdfText.trim().isNotEmpty) {
              if (text.isNotEmpty) text.writeln();
              text.write(String.fromCharCodes(pdfText.runes.take(2048)));
            }
          }
          final refText = result['ref_text']?.toString();
          if (!pdfPages && refText != null && refText.isNotEmpty) {
            if (text.isNotEmpty) text.writeln();
            text.write(refText);
          }
        }
      }
    } catch (_) {
      await _detachStaged(runtimeId, paths);
      rethrow;
    }
    return (
      text: text.toString().trim().isEmpty
          ? '[User attached a file]'
          : text.toString(),
      paths: paths,
      attachments: attachments,
    );
  }

  Future<void> _detachStaged(String runtimeId, Iterable<String> paths) async {
    // A session authority attaches only what a submit names: an unsent
    // staged image is attached to nothing, and it has no `image.detach`.
    if (_canonical) return;
    for (final path in paths) {
      try {
        await _rpc.request<Object?>(
          'image.detach',
          params: {
            'session_id': runtimeId,
            'path': path,
            ..._runtimeScope(runtimeId),
          },
        );
      } catch (_) {}
    }
  }

  void _recordDesktopContract(Map<String, dynamic> info) {
    final raw = info['desktop_contract'];
    // A session authority names its protocol instead, and stages uploads
    // the way contract 2 did.
    final value = info['desktop_protocol'] == kHermesCanonicalGatewayProtocol
        ? 2
        : raw is num
        ? raw.toInt()
        : int.tryParse(raw?.toString() ?? '');
    if (value != null && value > _desktopContract) {
      _desktopContract = value;
      _emitDesktopContract(value);
    }
  }

  void _requireDesktopUploadContract() {
    if (_desktopContract < 2) {
      throw StateError(
        'Upgrade Hermes Desktop Gateway to use remote attachments.',
      );
    }
  }

  Future<void> _runtimeInterrupt(String storedId) async {
    final binding = await _resume(storedId);
    if (_canonical) return _canonicalInterrupt(binding);
    await _rpc.request<Object?>(
      'session.interrupt',
      params: {
        'session_id': binding.runtimeId,
        ..._sessionScope(binding.storedId),
      },
    );
  }

  Future<bool> _runtimeSteer(String storedId, String text) async {
    final binding = await _resume(storedId);
    final canonical = _canonical;
    final baseline = await _matchingPromptMarkers(storedId, text);
    late final Map<String, dynamic> result;
    try {
      result = _object(
        await _rpc.request<Object?>(
          'session.steer',
          params: {
            'session_id': binding.runtimeId,
            'text': text,
            if (canonical)
              'execution_generation': (await _canonicalFences(
                binding,
              )).generation,
            ..._sessionScope(binding.storedId),
          },
        ),
      );
    } on HermesDesktopRpcException catch (error) {
      if (error.deliveryAmbiguous &&
          await _ambiguousPromptWasAccepted(storedId, text, baseline)) {
        return true;
      }
      // Refusals that say the steer never reached the turn (no turn ready
      // for it, a turn already over, an agent that cannot be steered).
      if (!error.deliveryAmbiguous &&
          (error.code == 4010 ||
              (canonical &&
                  _kHermesCanonicalUndeliveredSteer.contains(error.reason)))) {
        await queue(storedId, text);
        return false;
      }
      rethrow;
    }
    final status = result['status'];
    if (status == 'queued') return true;
    if (canonical) {
      if (status == 'redirected') return true;
      // A plain rejection may follow delivery (an acknowledgement that
      // timed out), so only one Hermes says no agent saw is sent again.
      if (result['delivered'] != false) return false;
    }
    await queue(storedId, text);
    return false;
  }

  Future<void> _runtimeQueue(String storedId, String text) async {
    final binding = await _resume(storedId);
    if (_canonical) {
      // Sent again under the same submission id after a lost answer, the
      // prompt is still queued once.
      final submissionId = const Uuid().v4();
      Future<void> submit(HermesSessionBinding binding) =>
          _rpc.request<Object?>(
            'prompt.submit',
            params: {
              'session_id': binding.runtimeId,
              'text': text,
              'queued': true,
              'submission_id': submissionId,
              ..._sessionScope(binding.storedId),
            },
          );
      try {
        await submit(binding);
      } on HermesDesktopRpcException catch (error) {
        if (!error.deliveryAmbiguous) rethrow;
        await submit((await _resumeSnapshot(storedId, refresh: true)).binding);
      }
      return;
    }
    final baseline = await _matchingPromptMarkers(storedId, text);
    try {
      await _rpc.request<Object?>(
        'prompt.submit',
        params: {
          'session_id': binding.runtimeId,
          'text': text,
          'queued': true,
          ..._sessionScope(binding.storedId),
        },
      );
    } on HermesDesktopRpcException catch (error) {
      if (!error.deliveryAmbiguous ||
          !await _ambiguousPromptWasAccepted(storedId, text, baseline)) {
        rethrow;
      }
    }
  }

  Future<bool> _ambiguousPromptWasAccepted(
    String storedId,
    String text,
    Set<String> baseline,
  ) async {
    await _resumeSnapshot(storedId, refresh: true);
    return _transcriptContainsNewPrompt(storedId, text, baseline);
  }

  Future<Set<String>> _matchingPromptMarkers(
    String storedId,
    String text,
  ) async {
    final rows = _sessionProfiles.containsKey(storedId)
        ? _objects(
            await _rpc.request<Object?>(
              'session.history',
              params: {
                'session_id': (await _resume(storedId)).runtimeId,
                ..._sessionScope(storedId),
              },
            ),
            'messages',
          )
        : _objects(
            await _requestJson(
              'GET',
              '/api/sessions/${Uri.encodeComponent(storedId)}/messages',
              query: {
                'limit': 20,
                'offset': 0,
                'order': 'latest',
                'include_compacted': true,
                ..._sessionScope(storedId),
              },
            ),
            'messages',
          );
    return {
      for (final row in rows)
        if (row['role'] == 'user' &&
            row['content']?.toString().trim() == text.trim())
          if (row['id'] != null || row['message_id'] != null)
            '${row['id'] ?? row['message_id']}'
          else
            jsonEncode(row),
    };
  }

  Future<bool> _transcriptContainsNewPrompt(
    String storedId,
    String text,
    Set<String> baseline,
  ) async => hermesTranscriptHasNewPrompt(
    baseline,
    await _matchingPromptMarkers(storedId, text),
  );

  Future<void> _runtimeResolveApproval(
    String runId, {
    required String approvalId,
    required bool approved,
  }) async {
    await _runtimeResolveApprovalChoice(
      runId,
      approvalId: approvalId,
      choice: approved ? 'once' : 'deny',
    );
  }

  Future<void> _runtimeResolveApprovalChoice(
    String runId, {
    required String approvalId,
    required String choice,
  }) async {
    if (!const {'once', 'session', 'always', 'deny'}.contains(choice)) {
      throw ArgumentError.value(choice, 'choice');
    }
    await _ensureConnected();
    // [approvalId] is the server request's id; `expired` means another
    // surface or the deadline settled it first, which closes the card too.
    await _answerServerRequest(runId, approvalId, {'choice': choice});
    await HermesPendingDecisionStore.resolve(
      origin: _origin,
      connectionId: config.connectionId,
      runtimeId: runId,
      requestId: approvalId,
    );
  }

  Future<void> _runtimeResolveApprovalChoiceForSession(
    String storedSessionId, {
    required String approvalId,
    required String choice,
  }) async {
    final binding = await _resume(storedSessionId);
    await _runtimeResolveApprovalChoice(
      binding.runtimeId,
      approvalId: approvalId,
      choice: choice,
    );
  }

  Future<void> _runtimeRespondToDecision({
    required String runtimeId,
    String? storedSessionId,
    required String requestId,
    required HermesDecisionKind kind,
    required String value,
    String? mcpServer,
    String? mcpAction,
  }) async {
    if (storedSessionId != null) {
      runtimeId = (await _resume(storedSessionId)).runtimeId;
    }
    await _ensureConnected();
    if (kind == HermesDecisionKind.mcpSetup) {
      await _administration.respondToConnection(
        runtimeId: runtimeId,
        cardId: requestId,
        approved: value == 'approve',
      );
    } else if (kind == HermesDecisionKind.clarification) {
      await _lockClarifyAnswer(
        runtimeId,
        cardId: requestId,
        answer: value,
        storedSessionId: storedSessionId,
      );
    } else {
      await _answerServerRequest(runtimeId, requestId, {'value': value});
    }
    await HermesPendingDecisionStore.resolve(
      origin: _origin,
      connectionId: config.connectionId,
      runtimeId: runtimeId,
      requestId: requestId,
    );
  }

  /// Answers the open server request [requestId] by RPC. It works from any
  /// socket, including one opened after the request was sent.
  Future<void> _answerServerRequest(
    String runtimeId,
    String requestId,
    Map<String, Object?> result,
  ) => _rpc.request<Object?>(
    'request.answer',
    params: {'id': requestId, 'result': result, ..._runtimeScope(runtimeId)},
  );

  /// Locks one clarify question's [answer]; the last question's lock answers
  /// the whole request. Then shows the next question the lock's `remaining`
  /// names (another surface may have answered some), which after a restart
  /// only a fresh resume snapshot still lists.
  Future<void> _lockClarifyAnswer(
    String runtimeId, {
    required String cardId,
    required String answer,
    String? storedSessionId,
  }) async {
    final card = parseHermesClarifyCardId(cardId);
    if (card == null) {
      throw StateError('Hermes returned an invalid question.');
    }
    final result = _object(
      await _rpc.request<Object?>(
        'clarify.lock',
        params: {
          'request_id': card.requestId,
          'question_id': card.questionId,
          'answer': answer,
          ..._runtimeScope(runtimeId),
        },
      ),
    );
    final remaining = result['remaining'];
    if (result['status'] != 'ok' || remaining is! List || remaining.isEmpty) {
      return;
    }
    if (!_rpc.showNextClarifyQuestion(
      cardId,
      remaining: remaining.map((questionId) => '$questionId'),
    )) {
      final storedId = storedSessionId ?? _storedIdForRuntime(runtimeId);
      if (storedId != null) await _resume(storedId, refresh: true);
    }
  }
}
