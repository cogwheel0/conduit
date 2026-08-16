part of 'hermes_desktop_api_service.dart';

extension _HermesDesktopTurnRuntime on HermesDesktopApiService {
  Future<HermesResponseStream> _runtimeStreamDesktopResponse(
    HermesChatInput input, {
    String? sessionId,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
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
    await _applySessionOptions(binding, options);
    final attached = await _attachInput(binding.runtimeId, input);
    var text = attached.text;
    final stagedPaths = attached.paths;
    if (cancelToken?.isCancelled == true) {
      await _detachStaged(binding.runtimeId, stagedPaths);
      throw cancelToken!.cancelError!;
    }
    final controller = StreamController<HermesRunEvent>();
    var terminal = false;
    final seenEventIds = <String>{};
    final seenEventOrder = Queue<String>();
    var activeRuntimeId = binding.runtimeId;
    var promptAcknowledged = false;
    var disconnectReconciliationRunning = false;
    final eventsBeforePromptAcknowledgement = <HermesDesktopEvent>[];
    late final StreamSubscription<HermesDesktopEvent> subscription;
    late final StreamSubscription<void> disconnectSubscription;

    bool hasAuthoritativeState() {
      final state =
          _sessionTurnStates[binding.storedId] ??
          _sessionTurnStates[binding.runtimeId];
      return state != null &&
          state != HermesDesktopTurnState.unsupportedGateway;
    }

    void finish({String? error}) {
      if (terminal) return;
      terminal = true;
      _eventBuffer.deactivate(activeRuntimeId);
      if (promptAcknowledged && hasAuthoritativeState()) {
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
        eventsBeforePromptAcknowledgement.add(event);
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
                runtimeId: binding.runtimeId,
                requestId: requestId,
              ),
            );
          }
        case 'session.info':
          final running = payload['running'];
          if (running is! bool) {
            _applyAuthoritativeRunning(
              running,
              storedId: binding.storedId,
              runtimeId: binding.runtimeId,
            );
          } else if (!running && promptAcknowledged) {
            finish();
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
          finish();
          _emitTranscriptChange(storedId);
        } catch (error) {
          if (!terminal) finish(error: error.toString());
        } finally {
          disconnectReconciliationRunning = false;
        }
      }());
    });
    cancelToken?.whenCancel.then((_) async {
      if (terminal) return;
      try {
        await _rpc.request<Object?>(
          'session.interrupt',
          params: {'session_id': binding.runtimeId},
        );
      } catch (_) {}
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
      promptBaseline = freshSession
          ? const <String>{}
          : await _matchingPromptMarkers(storedId, text);
      if (cancelToken?.isCancelled == true) {
        await _detachStaged(binding.runtimeId, stagedPaths);
        throw cancelToken!.cancelError!;
      }
      eventsBeforePromptAcknowledgement.clear();
      if (freshSession) _freshSessionIds.remove(storedId);
      await _rpc.request<Object?>(
        'prompt.submit',
        params: {'session_id': binding.runtimeId, 'text': text},
      );
      if (cancelToken?.isCancelled == true) {
        promptAcknowledged = true;
        try {
          await _rpc.request<Object?>(
            'session.interrupt',
            params: {'session_id': binding.runtimeId},
          );
        } catch (_) {}
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
      for (final event in List<HermesDesktopEvent>.of(
        eventsBeforePromptAcknowledgement,
      )) {
        if (!terminal) handleEvent(event);
      }
      eventsBeforePromptAcknowledgement.clear();
    } catch (error) {
      DebugLogger.error(
        'prompt-submit-failed',
        scope: 'hermes/desktop/ws',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (error is HermesDesktopRpcException && error.deliveryAmbiguous) {
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
            for (final event in List<HermesDesktopEvent>.of(
              eventsBeforePromptAcknowledgement,
            )) {
              if (!terminal) handleEvent(event);
            }
            eventsBeforePromptAcknowledgement.clear();
            if (cancelToken?.isCancelled == true) {
              try {
                await _rpc.request<Object?>(
                  'session.interrupt',
                  params: {'session_id': binding.runtimeId},
                );
              } catch (_) {}
              finish();
              return HermesResponseStream(
                events: controller.stream,
                sessionId: storedId,
              );
            }
            if (reconciled.running != true) {
              finish();
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
    if (event.type.endsWith('.request')) {
      final request = payload['request_id'] ?? payload['id'];
      if (request != null) return '${event.type}:$request';
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

  Future<void> _persistPendingDecisionEvent(HermesDesktopEvent event) async {
    final storedId = _storedIdForRuntime(event.sessionId);
    final runtimeId = validateHermesOpaqueIdentifier(event.sessionId);
    final requestId = validateHermesOpaqueIdentifier(
      event.payload['request_id'] ?? event.payload['id'],
      sensitiveValues: config.sensitiveValues,
    );
    if (storedId == null || runtimeId == null || requestId == null) return;
    final kind = switch (event.type) {
      'approval.request' => HermesPendingDesktopDecisionKind.approval,
      'clarify.request' => HermesPendingDesktopDecisionKind.clarification,
      'sudo.request' => HermesPendingDesktopDecisionKind.sudo,
      'secret.request' => HermesPendingDesktopDecisionKind.secret,
      'mcp.setup.request' => HermesPendingDesktopDecisionKind.mcpSetup,
      _ => null,
    };
    if (kind == null) return;
    final prompt = switch (event.type) {
      'approval.request' =>
        event.payload['command'] ?? event.payload['description'],
      'clarify.request' => event.payload['question'],
      'secret.request' => event.payload['prompt'] ?? event.payload['env_var'],
      'mcp.setup.request' => event.payload['reason'] ?? event.payload['server'],
      _ => event.payload['prompt'],
    };
    await HermesPendingDecisionStore.upsert(
      origin: _origin,
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
    if (reasoning?.isEmpty != false) {
      final global = _object(
        await _rpc.request<Object?>(
          'config.get',
          params: const {'key': 'reasoning'},
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
        },
      );
    }
    for (final option in <(String, Object?)>[
      ('model', modelSwitch),
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
        },
      );
    }
    _appliedSessionOptions[binding.storedId] = fingerprint;
  }

  Future<({String? submit, String? display, String? prefill})> _dispatchSlash(
    String runtimeId,
    String command, {
    int aliasDepth = 0,
  }) async {
    if (aliasDepth > 8) throw StateError('Hermes slash alias loop detected.');
    Object? raw;
    try {
      raw = await _rpc.request<Object?>(
        'slash.exec',
        params: {
          'session_id': runtimeId,
          'command': command.replaceFirst(RegExp(r'^/+'), ''),
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

  Future<({String text, List<String> paths})> _attachInput(
    String runtimeId,
    HermesChatInput input,
  ) async {
    if (input is HermesTextChatInput) {
      return (text: input.text, paths: const <String>[]);
    }
    if (input is! HermesMultimodalChatInput) {
      return (text: input.toJson().toString(), paths: const <String>[]);
    }
    final text = StringBuffer();
    final paths = <String>[];
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
              },
            ),
          );
          final path = result['path']?.toString();
          if (path?.isNotEmpty == true) paths.add(path!);
        } else if (part is HermesInputFilePart) {
          _requireDesktopUploadContract();
          final result = _object(
            await _rpc.request<Object?>(
              part.isPdf ? 'pdf.attach' : 'file.attach',
              params: part.isPdf
                  ? {
                      'session_id': runtimeId,
                      'content_base64': part.base64Data,
                      'filename': part.filename,
                    }
                  : {
                      'session_id': runtimeId,
                      'name': part.filename,
                      'data_url': part.dataUrl,
                    },
            ),
          );
          if (result['attached'] != true) {
            throw StateError('Hermes did not accept ${part.filename}.');
          }
          if (part.isPdf) {
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
          if (!part.isPdf && refText != null && refText.isNotEmpty) {
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
    );
  }

  Future<void> _detachStaged(String runtimeId, Iterable<String> paths) async {
    for (final path in paths) {
      try {
        await _rpc.request<Object?>(
          'image.detach',
          params: {'session_id': runtimeId, 'path': path},
        );
      } catch (_) {}
    }
  }

  void _recordDesktopContract(Map<String, dynamic> info) {
    final raw = info['desktop_contract'];
    final value = raw is num
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
    await _rpc.request<Object?>(
      'session.interrupt',
      params: {'session_id': binding.runtimeId},
    );
  }

  Future<bool> _runtimeSteer(String storedId, String text) async {
    final binding = await _resume(storedId);
    final baseline = await _matchingPromptMarkers(storedId, text);
    late final Map<String, dynamic> result;
    try {
      result = _object(
        await _rpc.request<Object?>(
          'session.steer',
          params: {'session_id': binding.runtimeId, 'text': text},
        ),
      );
    } on HermesDesktopRpcException catch (error) {
      if (error.deliveryAmbiguous &&
          await _ambiguousPromptWasAccepted(storedId, text, baseline)) {
        return true;
      }
      if (!error.deliveryAmbiguous && error.code == 4010) {
        await queue(storedId, text);
        return false;
      }
      rethrow;
    }
    if (result['status'] == 'queued') return true;
    await queue(storedId, text);
    return false;
  }

  Future<void> _runtimeQueue(String storedId, String text) async {
    final binding = await _resume(storedId);
    final baseline = await _matchingPromptMarkers(storedId, text);
    try {
      await _rpc.request<Object?>(
        'prompt.submit',
        params: {'session_id': binding.runtimeId, 'text': text, 'queued': true},
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
    final rows = _objects(
      await _requestJson(
        'GET',
        '/api/sessions/${Uri.encodeComponent(storedId)}/messages',
        query: {
          'limit': 20,
          'offset': 0,
          'order': 'recent',
          'include_compacted': true,
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
    await _rpc.request<Object?>(
      'approval.respond',
      params: {'session_id': runId, 'request_id': approvalId, 'choice': choice},
    );
    await HermesPendingDecisionStore.resolve(
      origin: _origin,
      runtimeId: runId,
      requestId: approvalId,
    );
  }

  Future<void> _runtimeResolveApprovalForSession(
    String storedSessionId, {
    required String approvalId,
    required bool approved,
  }) async {
    final binding = await _resume(storedSessionId);
    await resolveApproval(
      binding.runtimeId,
      approvalId: approvalId,
      approved: approved,
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
      await _administration.respondToMcpSetup(
        runtimeId: runtimeId,
        requestId: requestId,
        approved: value == 'approve',
        server: mcpServer,
        action: mcpAction,
      );
      return;
    }
    final method = switch (kind) {
      HermesDecisionKind.clarification => 'clarify.respond',
      HermesDecisionKind.sudo => 'sudo.respond',
      HermesDecisionKind.secret => 'secret.respond',
      HermesDecisionKind.mcpSetup => throw StateError('unreachable'),
    };
    final valueKey = switch (kind) {
      HermesDecisionKind.clarification => 'answer',
      HermesDecisionKind.sudo => 'password',
      HermesDecisionKind.secret => 'value',
      HermesDecisionKind.mcpSetup => throw StateError('unreachable'),
    };
    await _rpc.request<Object?>(
      method,
      params: {
        'session_id': runtimeId,
        'request_id': requestId,
        valueKey: value,
      },
    );
    await HermesPendingDecisionStore.resolve(
      origin: _origin,
      runtimeId: runtimeId,
      requestId: requestId,
    );
  }
}
