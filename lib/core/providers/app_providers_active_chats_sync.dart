part of 'app_providers.dart';

/// Helper function to select cached model based on settings and available models.
/// Used by both chat page and defaultModel provider to ensure consistent behavior.
/// Returns a cached model if available, otherwise returns null.
Future<Model?> selectCachedModel(
  OptimizedStorageService storage,
  String? desiredModelId,
) async {
  try {
    final cachedModels = sanitizeRemoteHermesModels(
      sanitizeRemoteDirectModels(await storage.getLocalModels()),
    ).where((model) => !model.isHidden).toList();
    if (cachedModels.isEmpty) return null;

    Model? match;
    if (desiredModelId != null && desiredModelId.isNotEmpty) {
      try {
        match = cachedModels.firstWhere(
          (model) =>
              model.id == desiredModelId ||
              model.name.trim() == desiredModelId.trim(),
        );
      } catch (_) {
        match = null;
      }
    }

    return match ?? cachedModels.first;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'cache-select-failed',
      scope: 'models/cache',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

// ---------------------------------------------------------------------------
// Active chats tracking (mirrors OpenWebUI Sidebar.svelte activeChatIds)
// ---------------------------------------------------------------------------

/// Tracks the set of chat IDs that have an active background task running.
///
/// Updated via `chat:active` socket events emitted by the backend when a
/// chat processing task starts (`active: true`) or completes (`active: false`).
@Riverpod(keepAlive: true)
class ActiveChatIds extends _$ActiveChatIds {
  @override
  Set<String> build() => const <String>{};

  // Monotonic activation tokens so a delayed, conditional clear can detect that
  // a chat was (re)activated after the clear was scheduled and skip itself.
  int _seq = 0;
  final Map<String, int> _activationToken = {};

  /// Mark a chat as active (background task running).
  void setActive(String chatId) {
    _activationToken[chatId] = ++_seq;
    if (state.contains(chatId)) return;
    state = {...state, chatId};
  }

  /// Mark a chat as inactive (background task completed).
  void setInactive(String chatId) {
    _activationToken.remove(chatId);
    if (!state.contains(chatId)) return;
    state = {...state}..remove(chatId);
  }

  /// The current activation token for [chatId], or null if not active. Capture
  /// this before an async task-registry check, then pass it to
  /// [setInactiveIfUnchanged] so a racing [setActive] cannot be clobbered.
  int? activationToken(String chatId) => _activationToken[chatId];

  /// Clear [chatId] only if it has not been (re)activated since [token] was
  /// captured — guards an async optimistic clear against a racing setActive
  /// (e.g. a new stream starting for the same chat before the lookup resolves).
  void setInactiveIfUnchanged(String chatId, int? token) {
    if (_activationToken[chatId] != token) return;
    setInactive(chatId);
  }

  /// Bulk-initialize from a server response.
  void setAll(Set<String> chatIds) {
    _seq++;
    _activationToken
      ..clear()
      ..addEntries([for (final id in chatIds) MapEntry(id, _seq)]);
    state = chatIds;
  }
}

/// Keeps global chat task state and generated titles synchronized.
///
/// OpenWebUI's sidebar both bulk-fetches active chats on load and listens for
/// `chat:active` events for any chat. This provider mirrors that: it
/// bulk-fetches on cold open + socket reconnect (`setAll`) and registers a
/// GLOBAL chat handler so generations started by other sessions/devices light
/// up the sidebar spinner and `chat:title` events update durable list state.
@Riverpod(keepAlive: true)
class ActiveChatsSync extends _$ActiveChatsSync {
  SocketEventSubscription? _globalActiveSub;
  StreamSubscription<void>? _reconnectSub;
  SocketService? _boundSocket;
  ApiService? _boundApi;
  Object? _boundAuthSessionEpoch;
  int _bindingGeneration = 0;
  bool _initialFetchDone = false;

  @override
  void build() {
    ref.onDispose(() {
      _bindingGeneration++;
      _globalActiveSub?.dispose();
      _globalActiveSub = null;
      _reconnectSub?.cancel();
      _reconnectSub = null;
    });

    _boundApi = ref.read(apiServiceProvider);
    _boundAuthSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    _bindSocket(ref.read(socketServiceProvider));
    ref.listen<SocketService?>(socketServiceProvider, (prev, next) {
      _bindSocket(next);
    });
    ref.listen<ApiService?>(apiServiceProvider, (prev, next) {
      if (identical(prev, next)) return;
      _boundApi = next;
      _bindSocket(ref.read(socketServiceProvider), force: true);
      ref.read(activeChatIdsProvider.notifier).setAll(const <String>{});
    });
    ref.listen<Object>(openWebUiAuthSessionEpochProvider, (prev, next) {
      if (identical(prev, next)) return;
      _boundAuthSessionEpoch = next;
      _boundApi = ref.read(apiServiceProvider);
      _bindSocket(ref.read(socketServiceProvider), force: true);
      ref.read(activeChatIdsProvider.notifier).setAll(const <String>{});
    });

    // Cold-open population: refresh once the conversation list first resolves.
    ref.listen<AsyncValue<List<Conversation>>>(conversationsProvider, (
      prev,
      next,
    ) {
      final convos = next.asData?.value;
      if (convos == null || convos.isEmpty || _initialFetchDone) {
        return;
      }
      _initialFetchDone = true;
      unawaited(_refresh(convos.map((c) => c.id).toList()));
    }, fireImmediately: true);
  }

  void _bindSocket(SocketService? socket, {bool force = false}) {
    final api = _boundApi;
    if (socket != null &&
        (api == null || socket.serverConfig.id != api.serverConfig.id)) {
      // During an async server switch socketServiceProvider intentionally
      // exposes the retiring service as a connectivity fallback. Never bind
      // that A socket to B's API/global active-chat state.
      socket = null;
    }
    if (!force && identical(socket, _boundSocket)) {
      return;
    }
    final generation = ++_bindingGeneration;
    final authSessionEpoch = _boundAuthSessionEpoch;
    _boundSocket = socket;
    _globalActiveSub?.dispose();
    _globalActiveSub = null;
    _reconnectSub?.cancel();
    _reconnectSub = null;
    if (socket == null) {
      // Logout / session teardown: the socket the spinners were derived from is
      // gone. Drop the whole set so a stale `generating` indicator cannot
      // survive into the next session (the new socket re-arms the cold-open
      // fetch below to repopulate authoritative state).
      ref.read(activeChatIdsProvider.notifier).setAll(const <String>{});
      _initialFetchDone = false;
      return;
    }

    // A new socket means a (re)connection or a fresh session (e.g. after
    // logout/login). Re-arm the one-shot cold-open fetch so the conversations
    // listener bulk-fetches active chats again for the new session instead of
    // skipping it because the flag stayed true from the previous one.
    _initialFetchDone = false;

    // All selectors null => `_shouldDeliver` treats this as a wildcard handler.
    // requireFocus:false so background generations on other chats still update
    // the badge.
    _globalActiveSub = socket.addChatEventHandler(
      requireFocus: false,
      handler: (map, _) {
        if (generation != _bindingGeneration ||
            !identical(socket, _boundSocket) ||
            !identical(socket, ref.read(socketServiceProvider)) ||
            !identical(_boundApi, ref.read(apiServiceProvider)) ||
            !identical(
              authSessionEpoch,
              ref.read(openWebUiAuthSessionEpochProvider),
            )) {
          return;
        }
        _handleChatActiveEvent(map);
        _handleChatTitleEvent(map);
      },
    );

    // Redis task state may have changed while disconnected: refresh on connect.
    _reconnectSub = socket.onReconnect.listen((_) {
      if (generation != _bindingGeneration ||
          !identical(socket, _boundSocket) ||
          !identical(socket, ref.read(socketServiceProvider)) ||
          !identical(_boundApi, ref.read(apiServiceProvider)) ||
          !identical(
            authSessionEpoch,
            ref.read(openWebUiAuthSessionEpochProvider),
          )) {
        return;
      }
      final convos = ref.read(conversationsProvider).asData?.value;
      if (convos == null || convos.isEmpty) {
        return;
      }
      unawaited(_refresh(convos.map((c) => c.id).toList()));
    });
  }

  void _handleChatActiveEvent(Map<String, dynamic> map) {
    final data = map['data'];
    if (data is! Map || data['type'] != 'chat:active') {
      return;
    }
    final payload = data['data'];
    final active = payload is Map ? payload['active'] : null;
    if (active is! bool) {
      return;
    }
    final chatId = _extractChatEventId(map);
    if (chatId == null || chatId.isEmpty) {
      return;
    }
    final notifier = ref.read(activeChatIdsProvider.notifier);
    if (active) {
      notifier.setActive(chatId);
    } else {
      notifier.setInactive(chatId);
    }
  }

  void _handleChatTitleEvent(Map<String, dynamic> map) {
    final data = map['data'];
    if (data is! Map || data['type'] != 'chat:title') {
      return;
    }
    final payload = data['data'];
    final title = switch (payload) {
      String value => value.trim(),
      Map value when value['title'] is String =>
        (value['title'] as String).trim(),
      _ => '',
    };
    final chatId = _extractChatEventId(map);
    if (chatId == null || chatId.isEmpty || title.isEmpty) {
      return;
    }

    DebugLogger.log(
      'generated-title-received',
      scope: 'chat/global-sync',
      data: {'chatId': chatId},
    );

    ref
        .read(conversationsProvider.notifier)
        .applyServerGeneratedTitle(chatId, title);
  }

  String? _extractChatEventId(Map<String, dynamic> map) {
    final direct = map['chat_id'] ?? map['chatId'];
    if (direct != null) {
      return direct.toString();
    }
    final data = map['data'];
    if (data is Map) {
      final outer = data['chat_id'] ?? data['chatId'];
      if (outer != null) {
        return outer.toString();
      }
      final inner = data['data'];
      if (inner is Map) {
        final nested = inner['chat_id'] ?? inner['chatId'];
        if (nested != null) {
          return nested.toString();
        }
      }
    }
    return null;
  }

  Future<void> _refresh(List<String> chatIds) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return;
    }
    final ids = chatIds
        .where((id) => id.isNotEmpty && !isTemporaryChat(id))
        .toList();
    if (ids.isEmpty) {
      return;
    }
    final socket = _boundSocket;
    final generation = _bindingGeneration;
    final authSessionEpoch = _boundAuthSessionEpoch;
    try {
      final active = await api.checkActiveChats(ids);
      if (generation != _bindingGeneration ||
          !identical(api, ref.read(apiServiceProvider)) ||
          !identical(socket, _boundSocket) ||
          !identical(socket, ref.read(socketServiceProvider)) ||
          !identical(
            authSessionEpoch,
            ref.read(openWebUiAuthSessionEpochProvider),
          )) {
        return;
      }
      ref.read(activeChatIdsProvider.notifier).setAll(active);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'active-chats refresh failed',
        scope: 'chat/active-sync',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

/// Resolves socket transport availability from backend configuration.
///
/// Used by both the sync [socketTransportOptionsProvider] and the
/// [BackendConfigNotifier] to ensure consistent resolution logic.
SocketTransportAvailability _resolveTransportAvailability(
  BackendConfig config,
) {
  if (config.websocketOnly) {
    return const SocketTransportAvailability(
      allowPolling: false,
      allowWebsocketOnly: true,
    );
  }

  if (config.pollingOnly) {
    return const SocketTransportAvailability(
      allowPolling: true,
      allowWebsocketOnly: false,
    );
  }

  return const SocketTransportAvailability(
    allowPolling: true,
    allowWebsocketOnly: true,
  );
}
