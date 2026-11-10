part of 'hermes_desktop_api_service.dart';

extension _HermesDesktopLiveRuntime on HermesDesktopApiService {
  Future<void> _ensureConnected() async {
    if (_closed) throw StateError('Hermes service is closed.');
    if (_rpc.isReady) return;
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  /// Connects, waiting out a gateway that is starting or draining: its
  /// listener refuses everything until it is ready, so the attempt is
  /// repeated a few times before Conduit reports it.
  Future<void> _connect() async {
    _emitTurnState(HermesDesktopTurnState.reconnecting);
    for (var attempt = 0; ; attempt++) {
      try {
        return await _connectOnce();
      } catch (error) {
        if (_closed || !hermesDesktopGatewayNotReady(error)) rethrow;
        if (attempt >= gatewayStartRetryDelays.length) {
          throw const HermesDesktopGatewayStartingException();
        }
        DebugLogger.warning(
          'gateway-not-ready',
          scope: 'hermes/desktop/ws',
          data: {'attempt': attempt + 1},
        );
        await Future<void>.delayed(gatewayStartRetryDelays[attempt]);
        if (_closed) throw StateError('Hermes service is closed.');
      }
    }
  }

  Future<void> _connectOnce() async {
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
    await _rpc.connect(
      wsUri,
      headers: config.accessHeaders,
      httpClient: hermesTlsHttpClient(config),
    );
    if (_closed) {
      await _rpc.disconnect();
      return;
    }
    _stateSubscription ??= _rpc.events.listen((event) {
      if (_rpc.sessionAuthority) _observeCanonicalEvent(event);
      final startedBuffering = _eventBuffer.add(event);
      // Buffered: no turn shows this session's events, so a restored chat
      // re-reads its cards once the saved decisions changed. Only a change
      // counts: reading the chat resumes it, which replays its open requests,
      // and a replay that changed nothing must not read it again.
      final sessionId = event.sessionId;
      final buffered = sessionId != null && _eventBuffer.hasPending(sessionId);
      void refreshRestoredCards(bool changed) {
        final storedId = _storedIdForRuntime(sessionId);
        if (changed && buffered && storedId != null) {
          _emitTranscriptChange(storedId);
        }
      }

      // Partial infos (a forwarded owner's relay, a service-tier change)
      // carry no `running` and say nothing about the turn.
      if (event.type == 'session.info' && event.payload['running'] is bool) {
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
        unawaited(
          _persistPendingDecisionEvent(
            event,
          ).then(refreshRestoredCards, onError: (Object _) {}),
        );
      }
      if (event.type == 'connection.update') {
        _administration.openApprovedConnectionLink(event.payload);
      }
      // The agent's task list: a full snapshot either way.
      if (event.type == 'todo.updated' ||
          (event.type == 'tool.complete' && event.payload['todos'] is List)) {
        _adoptTodoState(event.sessionId, event.payload);
      }
      if (event.type == 'session.info') {
        _adoptWorkingDirectory(event.sessionId, event.payload['cwd']);
      }
      _observeBackgroundWorkEvent(event);
      if (event.type == 'approval.responded' ||
          event.type == 'approval.expire' ||
          event.type == 'clarify.expire' ||
          event.type == 'sudo.expire' ||
          event.type == 'secret.expire' ||
          event.type == 'mcp.setup.expire') {
        unawaited(
          _resolvePendingDecisionEvent(
            event,
          ).then(refreshRestoredCards, onError: (Object _) {}),
        );
      }
      if (startedBuffering &&
          (event.type == 'message.complete' ||
              (event.type == 'session.info' &&
                  event.payload['running'] == false))) {
        final storedId = _storedIdForRuntime(event.sessionId);
        if (storedId != null) _emitTranscriptChange(storedId);
      }
    });
    _emitTurnState(HermesDesktopTurnState.idle);
  }

  /// Removes the saved decision [event] closes; resolves to whether one
  /// was saved.
  Future<bool> _resolvePendingDecisionEvent(HermesDesktopEvent event) async {
    final runtimeId = validateHermesOpaqueIdentifier(event.sessionId);
    final requestId = validateHermesOpaqueIdentifier(
      event.payload['request_id'] ?? event.payload['id'],
      sensitiveValues: config.sensitiveValues,
    );
    if (runtimeId == null || requestId == null) return false;
    // A resume saves what the buffer holds: a closed request leaves it too.
    _eventBuffer.dropRequest(runtimeId, requestId);
    return HermesPendingDecisionStore.resolve(
      origin: _origin,
      connectionId: config.connectionId,
      runtimeId: runtimeId,
      requestId: requestId,
    );
  }

  void _runtimeDidChangeAppLifecycleState(AppLifecyclePhase state) {
    switch (state) {
      case AppLifecyclePhase.paused:
      case AppLifecyclePhase.hidden:
      case AppLifecyclePhase.detached:
        // The OS may keep the socket alive. Reconcile on return instead of
        // closing a valid transport merely because the app backgrounded.
        _reconciliationStale = true;
      case AppLifecyclePhase.resumed:
        _foregroundReconciliation ??= _reconcileForeground().whenComplete(
          () => _foregroundReconciliation = null,
        );
      case AppLifecyclePhase.inactive:
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

  /// The profile that owns [storedId] — a Bot Mode chat's own profile, or the
  /// connection's configured one.
  ///
  /// Always explicit, never empty. The RPC transport injects the connection
  /// profile as a default, so omitting this does not mean "let the server
  /// decide": it means a request about a BOT session travels naming the
  /// CONNECTION's profile, and any handler that reads it resolves against the
  /// wrong profile's config and state.
  Map<String, dynamic> _sessionScope(String storedId) => {
    'profile': _sessionProfiles[storedId] ?? config.desktopProfile,
  };

  /// Attaches [storedId] on this socket and reads its state. With [byTitle]
  /// a session authority looks [storedId] up as a title (a bot's Bot Chat);
  /// earlier gateways resolve titles from `session_id` itself.
  Future<({HermesSessionBinding binding, bool? running})> _resumeSnapshot(
    String storedId, {
    bool refresh = false,
    bool byTitle = false,
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
    // A prompt settled from here on is stale in the snapshot asked for now.
    final settleMark = _rpc.canonicalSettleMark;
    final result = _object(
      await _rpc.request<Object?>(
        'session.resume',
        params: {
          if (byTitle && _canonical)
            'title': storedId
          else
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
    _adoptWorkingDirectory(stored, info['cwd']);
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
      connectionId: config.connectionId,
      fromStoredSessionId: storedId,
      toStoredSessionId: stored,
      runtimeId: runtime,
    );
    for (final event in _eventBuffer.pending(runtime)) {
      await _persistPendingDecisionEvent(event);
    }
    // Questions asked while no socket of ours was attached. Replayed as
    // events: the events listener persists them, and an open turn shows
    // them once it adopts this runtime id.
    if (_canonical) {
      _adoptCanonicalSnapshot(runtime, result, settledSince: settleMark);
      await _settleUnlistedCanonicalDecisions(
        binding,
        result['prompts'],
        openRequests: result['open_requests'],
        settledSince: settleMark,
      );
    }
    _adoptTodoState(stored, result['todo_state']);
    _rpc.replayOpenRequests(
      result['open_requests'],
      settledSince: settleMark,
    );
    _rpc.replayPendingConnection(result['pending_connection'], runtime);
    return (binding: binding, running: running is bool ? running : null);
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
    final trimmedTitle = title?.trim();
    final Map<String, Object?> params;
    String? createKey;
    if (_canonical) {
      // A session authority treats a titled create as "open the session
      // with this title, or make it": only a bot's Bot Chat wants that.
      // Other chats are titled by Hermes from their first prompt.
      final canonicalTitle = hidden && trimmedTitle?.isNotEmpty == true
          ? trimmedTitle
          : null;
      final identity = hermesCanonicalCreateParams(
        requestId: '',
        model: normalized.model,
        provider: normalized.provider,
        reasoning: normalized.reasoningEffort,
        fast: normalized.fast,
        profile: profile,
        hidden: hidden,
        title: canonicalTitle,
      );
      createKey = jsonEncode(identity);
      params = {
        ...identity,
        // Claimed by one create only: another chat's create with the same
        // options gets its own id, and so its own session.
        'request_id':
            _canonicalCreateIds.remove(createKey) ?? const Uuid().v4(),
      };
    } else {
      params = {
        'source': 'mobile',
        'close_on_disconnect': false,
        'model': ?normalized.model,
        'provider': ?normalized.provider,
        'reasoning_effort': ?normalized.reasoningEffort,
        'fast': ?normalized.fast,
        'profile': ?profile,
        if (hidden) 'hidden': true,
        if (trimmedTitle != null && trimmedTitle.isNotEmpty)
          'title': trimmedTitle,
      };
    }
    final Map<String, dynamic> result;
    try {
      result = _object(
        await _rpc.request<Object?>('session.create', params: params),
      );
    } on HermesDesktopRpcException catch (error) {
      // A create whose answer was lost may have made the session: the same
      // request id makes the next attempt answer with that session.
      if (createKey != null && error.deliveryAmbiguous) {
        if (_canonicalCreateIds.length >= 16) {
          _canonicalCreateIds.remove(_canonicalCreateIds.keys.first);
        }
        _canonicalCreateIds[createKey] = '${params['request_id']}';
      }
      rethrow;
    }
    if (createKey != null) _canonicalCreateIds.remove(createKey);
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
    _recordAppliedModel(stored, selection);
    final info = _object(result['info']);
    _recordDesktopContract(info);
    _adoptWorkingDirectory(stored, info['cwd']);
    if (_canonical) _adoptCanonicalSnapshot(runtime, result);
    final running = result['running'] ?? info['running'];
    if (running is bool) {
      _applyAuthoritativeRunning(running, storedId: stored, runtimeId: runtime);
    } else {
      _freshSessionIds.add(stored);
      _applyAuthoritativeRunning(null, storedId: stored, runtimeId: runtime);
    }
    return stored;
  }

  Future<List<Map<String, dynamic>>> _runtimeListSessions() async {
    try {
      return _objects(
        await _requestJson(
          'GET',
          '/api/sessions',
          query: {'limit': 100, 'offset': 0, 'order': 'recent'},
          readErrorDetail: true,
        ),
        'sessions',
      );
    } on HermesDesktopHttpException catch (error) {
      // Hermes 0.22+ browses read-only: a profile whose gateway never ran
      // has no session store yet, which is an empty list, not a failure.
      if (_hermesSessionStoreNotInitialized(error)) return const [];
      rethrow;
    }
  }

  bool _hermesSessionStoreNotInitialized(HermesDesktopHttpException error) =>
      error.status == 503 &&
      (error.detail?.startsWith('Session store is not initialized') ?? false);

  /// [current] reads what Hermes stores now; otherwise a read shorter than
  /// the last one gives way to it (a read can miss rows a turn is still
  /// writing).
  Future<List<Map<String, dynamic>>> _runtimeGetSessionMessages(
    String id, {
    CancelToken? cancelToken,
    bool current = false,
  }) async {
    // Hermes persists session.create lazily; resume fails until the first prompt.
    if (_freshSessionIds.contains(id) &&
        _bindings.containsKey(id) &&
        _rpc.isReady &&
        _bindingSocketGenerations[id] == _rpc.socketGeneration) {
      return const [];
    }
    // The REST transcript does not need a runtime binding, so a session that
    // the gateway refuses to resume (too large, wrong profile, transient
    // failure) can still be read. Hermes Desktop makes the same split: it
    // loads the transcript independently and treats resume as non-fatal for
    // display. Sending a prompt still resumes and surfaces that error itself.
    HermesSessionBinding? binding;
    try {
      binding = await _resume(id, refresh: true);
    } on HermesDesktopRpcException catch (error) {
      final isBotChat = _sessionProfiles.containsKey(id);
      // Timeouts and disconnects are transport failures, not gateway replies;
      // bot chats read history through the socket and need the runtime ID.
      if (error.deliveryAmbiguous || isBotChat) rethrow;
      DebugLogger.warning(
        'session-resume-failed-loading-rest',
        scope: 'hermes/desktop',
        data: {
          'code': error.code,
          'message': validateHermesBoundedString(
            error.message,
            maxCharacters: 200,
          ),
        },
      );
    }
    final runtimeId = binding?.runtimeId;
    final storedId = binding?.storedId ?? id;
    final hadBufferedEvent =
        runtimeId != null && _eventBuffer.take(runtimeId).isNotEmpty;
    final isBotChat = _sessionProfiles.containsKey(storedId);

    Future<List<Map<String, dynamic>>> load() async {
      if (isBotChat && runtimeId != null) {
        if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
        final history = await _rpc.request<Object?>(
          'session.history',
          params: {'session_id': runtimeId, ..._sessionScope(storedId)},
        );
        final rows = history is Map ? history['messages'] : null;
        // A read for changing the history must hold every row, as the
        // paged read does.
        if (current && rows is List && rows.length > 10000) {
          throw StateError(
            'This Hermes chat is too long to change from here: it has more '
            'than 10000 messages.',
          );
        }
        final messages = _objects(history, 'messages');
        if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
        return messages;
      }
      return loadHermesDesktopTranscriptPages(
        (offset, limit) async => _objects(
          await _requestJson(
            'GET',
            '/api/sessions/${Uri.encodeComponent(storedId)}/messages',
            query: {
              'limit': limit,
              'offset': offset,
              'order': 'oldest',
              'include_compacted': true,
              ..._sessionScope(storedId),
            },
            cancelToken: cancelToken,
          ),
          'messages',
        ),
        complete: current,
      );
    }

    var forceReload = hadBufferedEvent;
    var messages = const <Map<String, dynamic>>[];
    for (var attempt = 0; attempt < 3; attempt++) {
      messages = await load();
      final arrivedDuringLoad =
          runtimeId != null && _eventBuffer.take(runtimeId).isNotEmpty;
      if (!forceReload && !arrivedDuringLoad) break;
      forceReload = false;
      if (attempt == 2) _emitTranscriptChange(id);
    }
    // A failed resume left the connection state at "synchronizing"; the
    // transcript is loaded, and no turn is known to be running.
    if (binding == null) _emitTurnState(HermesDesktopTurnState.idle);
    final usable = current
        ? messages
        : preferLastUsableHermesTranscript(
            _lastTranscripts[id] ?? const [],
            messages,
          );
    _lastTranscripts[id] = usable;
    return usable;
  }

  Future<List<HermesPendingDesktopDecision>> _runtimePendingDecisionsForSession(
    String storedId,
  ) async {
    // Restore the session's owning profile BEFORE resuming: after a restart
    // the in-memory map is empty, and an unrestored bot chat would resume and
    // answer under the connection profile.
    await _restorePersistedSessionProfile(storedId);
    final binding = await _resume(storedId);
    await _restorePersistedSessionProfile(binding.storedId);
    return HermesPendingDecisionStore.forSession(
      origin: _origin,
      connectionId: config.connectionId,
      storedSessionId: binding.storedId,
    );
  }

  /// Re-seeds `_sessionProfiles` from a durable pending decision, so a bot
  /// chat restored across a restart keeps its profile scope.
  Future<void> _restorePersistedSessionProfile(String storedId) async {
    if (_sessionProfiles.containsKey(storedId)) return;
    for (final decision in await HermesPendingDecisionStore.forSession(
      origin: _origin,
      connectionId: config.connectionId,
      storedSessionId: storedId,
    )) {
      final profile = decision.profile;
      if (profile != null) {
        _sessionProfiles[storedId] = profile;
        return;
      }
    }
  }

  Future<void> _runtimeRenameSession(String id, String title) async {
    final binding = await _resume(id);
    if (_canonical) {
      await _canonicalMutate(binding, 'rename', {
        'title': title,
      }, fenceGeneration: false);
      return;
    }
    await _rpc.request<Object?>(
      'session.title',
      params: {
        'session_id': binding.runtimeId,
        'title': title,
        ..._sessionScope(binding.storedId),
      },
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
        if (_canonical) {
          // A session authority has no close: this socket leaves the
          // session's events, and the delete below ends it.
          await _canonicalDetach(binding);
        } else {
          await _rpc.request<Object?>(
            'session.close',
            params: {
              'session_id': binding.runtimeId,
              ..._sessionScope(binding.storedId),
            },
          );
        }
      } catch (error) {
        DebugLogger.warning(
          'session-close-before-delete-failed',
          scope: 'hermes/desktop/sessions',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
      // This socket left the session, or may have (a detach whose answer was
      // lost): should the delete below fail, the chat's next use resumes
      // (and attaches) it again.
      final closed = binding;
      _bindingSocketGenerations.removeWhere(
        (alias, _) => identical(_bindings[alias], closed),
      );
    }
    await _deleteStoredSession(
      binding?.storedId ?? id,
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
      _canonicalSessions.remove(binding.runtimeId);
    }
    _lastTranscripts.remove(id);
    _sessionProfiles.remove(id);
    _canonicalSessions.remove(id);
    _forgetWorkingDirectory([binding?.storedId, binding?.runtimeId, id]);
    await HermesPendingDecisionStore.clearSession(
      origin: _origin,
      connectionId: config.connectionId,
      storedSessionId: binding?.storedId ?? id,
    );
  }

  /// Deletes a stored session over REST, fenced (see [_fencedSessionWrite]).
  Future<void> _deleteStoredSession(
    String storedId, {
    CancelToken? cancelToken,
  }) => _fencedSessionWrite(storedId, 'DELETE', cancelToken: cancelToken);

  /// Sets a stored session's sidebar flags over REST, fenced like a delete.
  /// The dashboard reads a PATCH's fences and profile from its body.
  Future<void> _runtimeSetSessionFlags(
    String id, {
    bool? pinned,
    bool? archived,
    bool? hidden,
  }) async {
    final flags = <String, Object?>{
      'pinned': ?pinned,
      'archived': ?archived,
      'hidden': ?hidden,
    };
    if (flags.isEmpty) return;
    await _fencedSessionWrite(
      _bindings[id]?.storedId ?? id,
      'PATCH',
      body: flags,
    );
  }

  /// Archived chats, newest first, page by page: archiving is how older
  /// chats are tidied away, so they can be many more than one page.
  Future<List<Map<String, dynamic>>> _runtimeListArchivedSessions() async {
    const pageSize = 100;
    // Paged until a short page: every archived chat can be reached. The
    // bound only stops a server that never ends a listing.
    const maxPages = 200;
    final sessions = <Map<String, dynamic>>[];
    for (var page = 0; page < maxPages; page++) {
      final List<Map<String, dynamic>> rows;
      try {
        rows = _objects(
          await _requestJson(
            'GET',
            '/api/sessions',
            query: {
              'limit': pageSize,
              'offset': page * pageSize,
              'order': 'recent',
              'archived': 'only',
            },
            readErrorDetail: true,
          ),
          'sessions',
        );
      } on HermesDesktopHttpException catch (error) {
        if (_hermesSessionStoreNotInitialized(error)) return sessions;
        rethrow;
      }
      sessions.addAll(rows.take(pageSize));
      if (rows.length < pageSize) break;
    }
    return sessions;
  }

  Future<Map<String, dynamic>?> _runtimeGetSession(String id) async {
    final storedId = _bindings[id]?.storedId ?? id;
    try {
      final data = await _requestJson(
        'GET',
        '/api/sessions/${Uri.encodeComponent(storedId)}',
        query: _sessionScope(storedId),
      );
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (error) {
      if (_hermesDesktopHttpStatus(error) == 404) return null;
      rethrow;
    }
  }

  /// A session edit over REST ([method] `DELETE` or `PATCH` with [body]).
  /// Hermes 0.22.3+ fences session edits: the edit must name the revision
  /// and generation its `mutation-snapshot` reports, under a request id a
  /// retry can repeat, or it is refused with 409 `client_upgrade_required`.
  /// An older dashboard has no snapshot route (404) and takes the plain
  /// edit. A session that no longer exists has nothing to edit.
  Future<void> _fencedSessionWrite(
    String storedId,
    String method, {
    Map<String, Object?>? body,
    CancelToken? cancelToken,
  }) async {
    final path = '/api/sessions/${Uri.encodeComponent(storedId)}';
    final scope = _sessionScope(storedId);
    Map<String, dynamic>? snapshot;
    try {
      snapshot = _object(
        await _requestJson(
          'GET',
          '$path/mutation-snapshot',
          query: scope,
          cancelToken: cancelToken,
        ),
      );
    } catch (error) {
      if (_hermesDesktopHttpStatus(error) != 404) rethrow;
    }
    if (snapshot != null && snapshot['exists'] == false) return;
    final revision = snapshot?['runtime_revision'];
    final generation = snapshot?['runtime_generation'];
    final fences = <String, Object?>{
      if (snapshot != null) ...{
        'request_id': const Uuid().v4(),
        if (revision is int) 'expected_revision': revision,
        if (generation is int) 'expected_generation': generation,
      },
    };
    if (body == null) {
      await _requestJson(
        method,
        path,
        query: {...scope, ...fences},
        cancelToken: cancelToken,
      );
      return;
    }
    await _requestJson(
      method,
      path,
      query: scope,
      body: {...body, ...scope, ...fences},
      cancelToken: cancelToken,
    );
  }

  bool _runtimeSessionIdsReferToSameBinding(String left, String right) =>
      left == right ||
      (_bindings[left] != null && identical(_bindings[left], _bindings[right]));

  /// Branches session [id]: all of it, or, from a message, the legacy
  /// wire's first [count] user and assistant rows with text, or a session
  /// authority's rows through [throughRowId].
  Future<String> _runtimeForkSession(
    String id, {
    int? count,
    int? throughRowId,
  }) async {
    final binding = await _resume(id);
    final Map<String, dynamic> result;
    if (_canonical) {
      // A session authority branches as an edit of the parent, and attaches
      // the branch to this socket; its id names it on both sides.
      final receipt = await _canonicalMutate(binding, 'branch', {
        'through_message_id': ?throughRowId,
      });
      final branch = receipt['branched_session_id'];
      result = {'session_id': branch, 'stored_session_id': branch};
    } else {
      result = _object(
        await _rpc.request<Object?>(
          'session.branch',
          params: {
            'session_id': binding.runtimeId,
            'count': ?count,
            ..._sessionScope(binding.storedId),
          },
        ),
      );
    }
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
    // The branch's receipt names only its id: its state, fences and this
    // socket's subscription come from its own snapshot.
    if (_canonical) await _resumeSnapshot(stored, refresh: true);
    return stored;
  }

  /// Drops session [id]'s last user turn and everything after it. False
  /// when there was no turn to drop.
  /// [binding]'s fences as the session is now. With [lastRowId], the
  /// transcript is read after them and must still end at that row: a turn
  /// stored since then throws, and one stored after the read moves the
  /// fences, which refuses an edit sent at them.
  Future<({int revision, int generation})> _canonicalFencesThrough(
    HermesSessionBinding binding, {
    int? lastRowId,
  }) async {
    final fences = await _canonicalFences(binding, refresh: true);
    final revision = fences.revision;
    final generation = fences.generation;
    if (revision == null || generation == null) {
      throw StateError('Hermes did not report the chat\'s state.');
    }
    if (lastRowId != null) {
      final transcript = await _runtimeGetSessionMessages(
        binding.storedId,
        current: true,
      );
      _lastTranscripts.remove(binding.storedId);
      int? last;
      for (final row in transcript.reversed) {
        last = hermesTranscriptRowId(row);
        if (last != null) break;
      }
      if (last != lastRowId) {
        throw StateError('The Hermes chat changed. Try again.');
      }
    }
    return (revision: revision, generation: generation);
  }

  /// The row id of the last turn a user started in session [storedId], as
  /// the session stores it now.
  Future<int?> _lastUserRowId(String storedId) async {
    final transcript = await _runtimeGetSessionMessages(
      storedId,
      current: true,
    );
    _lastTranscripts.remove(storedId);
    for (final row in transcript.reversed) {
      if (hermesTranscriptUserContent(row) != null) {
        return hermesTranscriptRowId(row);
      }
    }
    return null;
  }

  Future<bool> _runtimeUndoLastTurn(String id, {int? rowId}) async {
    final binding = await _resume(id);
    _lastTranscripts
      ..remove(id)
      ..remove(binding.storedId);
    if (!_canonical) {
      // The legacy undo names no turn: it drops whichever user turn is last
      // when it runs, in a session every client attached to it shares.
      // [rowId] must still be that turn just before the undo is sent, and
      // gone after it: a turn stored in between was dropped instead.
      if (rowId != null && await _lastUserRowId(binding.storedId) != rowId) {
        throw StateError('The Hermes chat changed. Try again.');
      }
      final result = _object(
        await _rpc.request<Object?>(
          'session.undo',
          params: {
            'session_id': binding.runtimeId,
            ..._sessionScope(binding.storedId),
          },
        ),
      );
      final removed = result['removed'];
      if (removed is! int || removed <= 0) return false;
      if (rowId == null) return true;
      final List<Map<String, dynamic>> after;
      try {
        after = await _runtimeGetSessionMessages(
          binding.storedId,
          current: true,
        );
      } catch (_) {
        // Most likely the checked turn went. Reported as not undone, it
        // would be undone again, and the turn before it dropped too.
        return true;
      } finally {
        _lastTranscripts.remove(binding.storedId);
      }
      if (after.any((row) => hermesTranscriptRowId(row) == rowId)) {
        throw StateError('Hermes undid a turn sent after the checked one.');
      }
      return true;
    }
    // A session authority has no undo: it rewinds to [rowId], else to the
    // last turn a user started, a row of their own (not a marker Hermes
    // added). The rewind is fenced at the session as it is now, and the
    // transcript is read after the fences: a turn added since refuses it
    // rather than being rewound too.
    final fences = await _canonicalFences(binding, refresh: true);
    final revision = fences.revision;
    final generation = fences.generation;
    if (revision == null || generation == null) {
      throw StateError('Hermes did not report the chat\'s state.');
    }
    final transcript = await _runtimeGetSessionMessages(
      binding.storedId,
      current: true,
    );
    _lastTranscripts.remove(binding.storedId);
    int? target = rowId;
    if (target != null) {
      // [rowId] was chosen from an earlier read: gone since, or followed by
      // a user turn stored since, it is no longer the turn to undo.
      final index = transcript.indexWhere(
        (row) => hermesTranscriptRowId(row) == target,
      );
      if (index < 0 ||
          transcript
              .skip(index + 1)
              .any((row) => hermesTranscriptUserContent(row) != null)) {
        throw StateError('The Hermes chat changed. Try again.');
      }
    } else {
      for (final row in transcript.reversed) {
        final kind = row['display_kind'];
        if ((kind == null || kind == '' || kind == 'steer') &&
            hermesTranscriptUserContent(row) != null) {
          target = hermesTranscriptRowId(row);
          if (target != null) break;
        }
      }
    }
    if (target == null) return false;
    final receipt = await _canonicalMutate(
      binding,
      'rewind',
      {'target_message_id': target},
      pinned: (revision: revision, generation: generation),
    );
    final rewound = receipt['rewound_count'];
    return rewound is! int || rewound > 0;
  }
}
