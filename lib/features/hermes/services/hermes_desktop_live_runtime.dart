part of 'hermes_desktop_api_service.dart';

extension _HermesDesktopLiveRuntime on HermesDesktopApiService {
  Future<void> _ensureConnected() async {
    if (_closed) throw StateError('Hermes service is closed.');
    if (_rpc.isReady) return;
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<void> _connect() async {
    _emitTurnState(HermesDesktopTurnState.reconnecting);
    final status = await statusProbe(refresh: true);
    if (_closed) throw StateError('Hermes service is closed.');
    final query = <String, String>{};
    if (status['auth_required'] == true) {
      final ticketData = await _requestJson('POST', '/api/auth/ws-ticket');
      if (_closed) throw StateError('Hermes service is closed.');
      final ticket = ticketData is Map
          ? ticketData['ticket']?.toString()
          : null;
      if (ticket == null || ticket.isEmpty) {
        throw StateError('Hermes did not issue a WebSocket ticket.');
      }
      query['ticket'] = ticket;
    } else {
      final token = config.desktopCredentials?.legacyToken;
      if (token == null || token.isEmpty) {
        throw StateError('Hermes requires a legacy session token.');
      }
      query['token'] = token;
    }
    final httpUri = _uri('/api/ws').replace(queryParameters: query);
    final wsUri = httpUri.replace(
      scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
    );
    await _rpc.connect(wsUri, headers: config.accessHeaders);
    if (_closed) {
      await _rpc.disconnect();
      return;
    }
    _stateSubscription ??= _rpc.events.listen((event) {
      final startedBuffering = _eventBuffer.add(event);
      if (event.type == 'session.info') {
        // Update BOTH keys. `session.create` can omit `running`, which parks
        // the stored id at unsupportedGateway; a runtime-only update never
        // clears that, so the second turn onward fails the safety gate with
        // "Hermes run failed." until a resume repairs the state.
        _applyAuthoritativeRunning(
          event.payload['running'],
          storedId: _storedIdForRuntime(event.sessionId),
          runtimeId: event.sessionId,
        );
      }
      if (event.type == 'approval.request' ||
          event.type == 'clarify.request' ||
          event.type == 'sudo.request' ||
          event.type == 'secret.request' ||
          event.type == 'mcp.setup.request') {
        unawaited(_persistPendingDecisionEvent(event));
      }
      if (event.type == 'approval.responded' ||
          event.type == 'approval.expire' ||
          event.type == 'clarify.expire' ||
          event.type == 'sudo.expire' ||
          event.type == 'secret.expire' ||
          event.type == 'mcp.setup.expire') {
        unawaited(_resolvePendingDecisionEvent(event));
      }
      if (startedBuffering &&
          (event.type == 'message.complete' ||
              event.type.endsWith('.request') ||
              (event.type == 'session.info' &&
                  event.payload['running'] == false))) {
        final storedId = _storedIdForRuntime(event.sessionId);
        if (storedId != null) _emitTranscriptChange(storedId);
      }
    });
    _emitTurnState(HermesDesktopTurnState.idle);
  }

  Future<void> _resolvePendingDecisionEvent(HermesDesktopEvent event) async {
    final runtimeId = validateHermesOpaqueIdentifier(event.sessionId);
    final requestId = validateHermesOpaqueIdentifier(
      event.payload['request_id'] ?? event.payload['id'],
      sensitiveValues: config.sensitiveValues,
    );
    if (runtimeId == null || requestId == null) return;
    await HermesPendingDecisionStore.resolve(
      origin: _origin,
      runtimeId: runtimeId,
      requestId: requestId,
    );
  }

  void _runtimeDidChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // The OS may keep the socket alive. Reconcile on return instead of
        // closing a valid transport merely because the app backgrounded.
        _reconciliationStale = true;
      case AppLifecycleState.resumed:
        _foregroundReconciliation ??= _reconcileForeground().whenComplete(
          () => _foregroundReconciliation = null,
        );
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _reconcileForeground() async {
    if (!_reconciliationStale || _closed) return;
    _emitTurnState(HermesDesktopTurnState.synchronizing);
    final storedIds = _bindings.keys.toList(growable: false);
    try {
      await statusProbe(refresh: true);
      if (_closed) return;
      if (_rpc.isReady) {
        if (storedIds.isEmpty) {
          await _rpc.request<Object?>(
            'model.options',
            timeout: const Duration(seconds: 10),
          );
        } else {
          for (final storedId in storedIds) {
            await _resume(storedId, refresh: true);
            _emitTranscriptChange(storedId);
          }
        }
      } else {
        _bindings.clear();
        _bindingSocketGenerations.clear();
        _freshSessionIds.clear();
        await _ensureConnected();
        for (final storedId in storedIds) {
          await _resume(storedId);
          _emitTranscriptChange(storedId);
        }
      }
      _reconciliationStale = false;
    } catch (_) {
      await _rpc.disconnect();
      _bindings.clear();
      _bindingSocketGenerations.clear();
      _freshSessionIds.clear();
      _emitTurnState(HermesDesktopTurnState.reconnecting);
    }
  }

  void _applyAuthoritativeRunning(
    Object? running, {
    String? storedId,
    String? runtimeId,
  }) {
    final state = running is! bool
        ? HermesDesktopTurnState.unsupportedGateway
        : running
        ? HermesDesktopTurnState.running
        : HermesDesktopTurnState.idle;
    if (running is! bool) {
      _authoritativeRunning = false;
    } else {
      _authoritativeRunning = true;
    }
    for (final id in <String?>{storedId, runtimeId}) {
      if (id == null || id.isEmpty) continue;
      _sessionTurnStates[id] = state;
      _emitSessionTurnState(id);
    }
    _emitTurnState(state);
  }

  Map<String, dynamic> _object(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  List<Map<String, dynamic>> _objects(Object? value, [String? envelope]) {
    final source = envelope != null && value is Map ? value[envelope] : value;
    if (source is! List) return const [];
    return source
        .whereType<Map>()
        .take(10000)
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<HermesSessionBinding> _resume(
    String storedId, {
    bool refresh = false,
  }) async => (await _resumeSnapshot(storedId, refresh: refresh)).binding;

  /// Profile scope for a session owned by another profile (a Bot Mode chat).
  /// Empty for ordinary sessions, which inherit the connection's profile.
  Map<String, dynamic> _sessionScope(String storedId) {
    final profile = _sessionProfiles[storedId];
    return profile == null ? const {} : {'profile': profile};
  }

  Future<({HermesSessionBinding binding, bool? running})> _resumeSnapshot(
    String storedId, {
    bool refresh = false,
  }) async {
    final existing = _bindings[storedId];
    if (!refresh &&
        existing != null &&
        _rpc.isReady &&
        _bindingSocketGenerations[storedId] == _rpc.socketGeneration) {
      return (binding: existing, running: null);
    }
    await _ensureConnected();
    _emitTurnState(HermesDesktopTurnState.synchronizing);
    final result = _object(
      await _rpc.request<Object?>(
        'session.resume',
        params: {
          'session_id': storedId,
          'omit_messages': true,
          ..._sessionScope(storedId),
        },
      ),
    );
    final runtime = validateHermesOpaqueIdentifier(result['session_id']);
    final stored = validateHermesOpaqueIdentifier(
      result['stored_session_id'] ?? result['session_key'] ?? storedId,
    );
    if (runtime == null || stored == null) {
      throw const FormatException('Hermes returned invalid session IDs.');
    }
    final info = _object(result['info']);
    final running = result['running'] ?? info['running'];
    _recordDesktopContract(info);
    final binding = HermesSessionBinding(storedId: stored, runtimeId: runtime);
    final profile = _sessionProfiles[storedId];
    if (profile != null) _sessionProfiles[stored] = profile;
    _bindings[storedId] = binding;
    _bindings[stored] = binding;
    _bindingSocketGenerations[storedId] = _rpc.socketGeneration;
    _bindingSocketGenerations[stored] = _rpc.socketGeneration;
    _applyAuthoritativeRunning(running, storedId: storedId, runtimeId: runtime);
    if (stored != storedId) {
      _sessionTurnStates[stored] = turnStateFor(storedId);
      _emitSessionTurnState(stored);
    }
    await HermesPendingDecisionStore.rebindSession(
      origin: _origin,
      fromStoredSessionId: storedId,
      toStoredSessionId: stored,
      runtimeId: runtime,
    );
    for (final event in _eventBuffer.pending(runtime)) {
      await _persistPendingDecisionEvent(event);
    }
    await _restorePendingFromResume(result, binding);
    return (binding: binding, running: running is bool ? running : null);
  }

  Future<void> _restorePendingFromResume(
    Map<String, dynamic> result,
    HermesSessionBinding binding,
  ) async {
    final approval = _object(result['pending_approval']);
    final approvalId = validateHermesOpaqueIdentifier(
      approval['request_id'],
      sensitiveValues: config.sensitiveValues,
    );
    if (approvalId != null) {
      final command = approval['command']?.toString() ?? '';
      final description = approval['description']?.toString() ?? '';
      await HermesPendingDecisionStore.upsert(
        origin: _origin,
        storedSessionId: binding.storedId,
        runtimeId: binding.runtimeId,
        requestId: approvalId,
        kind: HermesPendingDesktopDecisionKind.approval,
        prompt: command.isNotEmpty ? command : description,
        choices: _desktopDecisionChoices(approval['choices']),
        sensitiveValues: config.sensitiveValues,
      );
    }
    final clarify = _object(result['pending_clarify']);
    final clarifyId = validateHermesOpaqueIdentifier(
      clarify['request_id'],
      sensitiveValues: config.sensitiveValues,
    );
    if (clarifyId != null) {
      await HermesPendingDecisionStore.upsert(
        origin: _origin,
        storedSessionId: binding.storedId,
        runtimeId: binding.runtimeId,
        requestId: clarifyId,
        kind: HermesPendingDesktopDecisionKind.clarification,
        prompt: clarify['question']?.toString(),
        choices: _desktopDecisionChoices(clarify['choices']),
        multiSelect: clarify['multi_select'] == true,
        sensitiveValues: config.sensitiveValues,
      );
    }
  }

  Future<String> _runtimeCreateSession({
    String? title,
    CancelToken? cancelToken,
  }) => createDesktopSession(
    title: title,
    options: const HermesDesktopSessionOptions(),
    cancelToken: cancelToken,
  );

  Future<String> _runtimeCreateDesktopSession({
    String? title,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
    String? profile,
    bool hidden = false,
  }) async {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final selection = hermesDesktopSessionModelSelection(
      options.model,
      options.provider,
    );
    final reasoning = options.reasoningEffort?.trim();
    final normalized = HermesDesktopSessionOptions(
      model: selection.model,
      provider: selection.provider,
      reasoningEffort: reasoning?.isEmpty == true ? null : reasoning,
      fast: options.fast,
    );
    await _ensureConnected();
    final result = _object(
      await _rpc.request<Object?>(
        'session.create',
        params: {
          'source': 'mobile',
          'close_on_disconnect': false,
          'model': ?normalized.model,
          'provider': ?normalized.provider,
          'reasoning_effort': ?normalized.reasoningEffort,
          'fast': ?normalized.fast,
          'profile': ?profile,
          if (hidden) 'hidden': true,
          if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
        },
      ),
    );
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final runtime = validateHermesOpaqueIdentifier(result['session_id']);
    final stored = validateHermesOpaqueIdentifier(result['stored_session_id']);
    if (runtime == null || stored == null) {
      throw const FormatException('Hermes returned invalid session IDs.');
    }
    _bindings[stored] = HermesSessionBinding(
      storedId: stored,
      runtimeId: runtime,
    );
    _bindingSocketGenerations[stored] = _rpc.socketGeneration;
    _appliedSessionOptions[stored] = normalized.fingerprint;
    final info = _object(result['info']);
    _recordDesktopContract(info);
    final running = result['running'] ?? info['running'];
    if (running is bool) {
      _applyAuthoritativeRunning(running, storedId: stored, runtimeId: runtime);
    } else {
      _freshSessionIds.add(stored);
      _applyAuthoritativeRunning(null, storedId: stored, runtimeId: runtime);
    }
    return stored;
  }

  Future<List<Map<String, dynamic>>> _runtimeListSessions() async => _objects(
    await _requestJson(
      'GET',
      '/api/sessions',
      query: {'limit': 100, 'offset': 0, 'order': 'recent'},
    ),
    'sessions',
  );

  Future<List<Map<String, dynamic>>> _runtimeGetSessionMessages(
    String id, {
    CancelToken? cancelToken,
  }) async {
    final binding = await _resume(id, refresh: true);
    final hadBufferedEvent = _eventBuffer.take(binding.runtimeId).isNotEmpty;

    Future<List<Map<String, dynamic>>> load() =>
        loadHermesDesktopTranscriptPages(
          (offset, limit) async => _objects(
            await _requestJson(
              'GET',
              '/api/sessions/${Uri.encodeComponent(binding.storedId)}/messages',
              query: {
                'limit': limit,
                'offset': offset,
                'order': 'oldest',
                'include_compacted': true,
                ..._sessionScope(binding.storedId),
              },
              cancelToken: cancelToken,
            ),
            'messages',
          ),
        );

    var forceReload = hadBufferedEvent;
    var messages = const <Map<String, dynamic>>[];
    for (var attempt = 0; attempt < 3; attempt++) {
      messages = await load();
      final arrivedDuringLoad = _eventBuffer.take(binding.runtimeId).isNotEmpty;
      if (!forceReload && !arrivedDuringLoad) break;
      forceReload = false;
      if (attempt == 2) _emitTranscriptChange(id);
    }
    final usable = preferLastUsableHermesTranscript(
      _lastTranscripts[id] ?? const [],
      messages,
    );
    _lastTranscripts[id] = usable;
    return usable;
  }

  Future<List<HermesPendingDesktopDecision>> _runtimePendingDecisionsForSession(
    String storedId,
  ) async {
    final binding = await _resume(storedId);
    return HermesPendingDecisionStore.forSession(
      origin: _origin,
      storedSessionId: binding.storedId,
    );
  }

  Future<void> _runtimeRenameSession(String id, String title) async {
    final binding = await _resume(id);
    await _rpc.request<Object?>(
      'session.title',
      params: {'session_id': binding.runtimeId, 'title': title},
    );
  }

  Future<void> _runtimeDeleteSession(
    String id, {
    CancelToken? cancelToken,
  }) async {
    var binding = _bindings[id];
    if (binding != null) {
      try {
        binding = await _resume(id);
        await _rpc.request<Object?>(
          'session.close',
          params: {
            'session_id': binding.runtimeId,
            ..._sessionScope(binding.storedId),
          },
        );
      } catch (error) {
        DebugLogger.warning(
          'session-close-before-delete-failed',
          scope: 'hermes/desktop/sessions',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    }
    await _requestJson(
      'DELETE',
      '/api/sessions/${Uri.encodeComponent(binding?.storedId ?? id)}',
      query: _sessionScope(binding?.storedId ?? id),
      cancelToken: cancelToken,
    );
    if (binding != null) {
      _bindings.removeWhere((_, candidate) => identical(candidate, binding));
      _freshSessionIds.remove(binding.storedId);
      _bindingSocketGenerations.removeWhere(
        (alias, _) => !_bindings.containsKey(alias),
      );
      _lastTranscripts.remove(binding.storedId);
      _sessionProfiles.remove(binding.storedId);
    }
    _lastTranscripts.remove(id);
    _sessionProfiles.remove(id);
    await HermesPendingDecisionStore.clearSession(
      origin: _origin,
      storedSessionId: binding?.storedId ?? id,
    );
  }

  bool _runtimeSessionIdsReferToSameBinding(String left, String right) =>
      left == right ||
      (_bindings[left] != null && identical(_bindings[left], _bindings[right]));

  Future<String> _runtimeForkSession(String id) async {
    final binding = await _resume(id);
    final result = _object(
      await _rpc.request<Object?>(
        'session.branch',
        params: {
          'session_id': binding.runtimeId,
          ..._sessionScope(binding.storedId),
        },
      ),
    );
    final runtime = validateHermesOpaqueIdentifier(result['session_id']);
    final stored = validateHermesOpaqueIdentifier(result['stored_session_id']);
    if (runtime == null || stored == null) {
      throw const FormatException('Hermes returned invalid branch IDs.');
    }
    _bindings[stored] = HermesSessionBinding(
      storedId: stored,
      runtimeId: runtime,
    );
    _bindingSocketGenerations[stored] = _rpc.socketGeneration;
    // A branch of a bot's chat lives in that bot's profile too; without this
    // every later call for the fork would target the configured profile.
    final profile = _sessionProfiles[binding.storedId];
    if (profile != null) _sessionProfiles[stored] = profile;
    return stored;
  }
}
