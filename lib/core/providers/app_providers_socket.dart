part of 'app_providers.dart';

typedef SocketServiceFactory = SocketService Function({
  required ServerConfig serverConfig,
  required String authToken,
  required bool websocketOnly,
  required bool allowWebsocketUpgrade,
});

final socketServiceFactoryProvider = Provider<SocketServiceFactory>((ref) {
  return ({
    required serverConfig,
    required authToken,
    required websocketOnly,
    required allowWebsocketUpgrade,
  }) => SocketService(
    lifecycle: ref.read(appLifecycleProvider),
    serverConfig: serverConfig,
    authToken: authToken,
    websocketOnly: websocketOnly,
    allowWebsocketUpgrade: allowWebsocketUpgrade,
  );
});

@Riverpod(keepAlive: true)
class SocketServiceManager extends _$SocketServiceManager {
  SocketService? _service;
  ProviderSubscription<ConnectivityStatus>? _connectivitySubscription;
  String? _serviceToken;
  int _connectToken = 0;
  int _buildGeneration = 0;

  /// The current live service, available even while [build] is re-running (the
  /// async provider is briefly `loading` on every rebuild). [socketServiceProvider]
  /// falls back to this so the socket doesn't momentarily read as `null` — which
  /// would otherwise drop consumers to HTTP-only sends mid-session. Null only
  /// when there is genuinely no service (reviewer mode / no active server /
  /// disposed).
  SocketService? get currentService => _service;

  @override
  FutureOr<SocketService?> build() async {
    final buildGeneration = ++_buildGeneration;
    _registerDisposeHook(buildGeneration);
    final reviewerMode = ref.watch(reviewerModeProvider);
    final authenticated = ref.watch(isAuthenticatedProvider2);
    final token = ref.watch(authTokenProvider3);
    final authSessionEpoch = ref.watch(openWebUiAuthSessionEpochProvider);
    if (reviewerMode || !authenticated || token == null || token.isEmpty) {
      _disposeService();
      return null;
    }

    // A token transition may represent another user on the same server. Drop
    // the old socket synchronously, before the first await, so the provider's
    // loading fallback can never expose the prior session or its room handlers.
    if (_service != null && _serviceToken != token) {
      _disposeService();
    }

    final activeServerSnapshot = ref.watch(activeServerProvider);
    final immediatelyKnownServer = activeServerSnapshot.asData?.value;
    if (_service != null &&
        (immediatelyKnownServer == null ||
            _service!.serverConfig.id != immediatelyKnownServer.id)) {
      // A live socket is safe to expose during an ordinary rebuild only while
      // the active server is still provably the same. Server selection enters
      // loading before its replacement resolves, so fail closed instead of
      // letting socketServiceProvider's loading fallback expose the old host.
      _disposeService();
    }

    final server = await ref.watch(activeServerProvider.future);
    if (!_buildStillOwnsContext(
      buildGeneration: buildGeneration,
      token: token,
      authSessionEpoch: authSessionEpoch,
      server: server,
    )) {
      // AsyncNotifier ignores an obsolete build's returned state, but the
      // continuation can still execute side effects. Never let that stale
      // continuation dispose or replace the socket installed by a newer auth or
      // server generation.
      return null;
    }
    if (server == null) {
      _disposeService();
      return null;
    }

    final transportMode = ref.watch(
      appSettingsProvider.select((settings) => settings.socketTransportMode),
    );
    final websocketOnly = transportMode == 'ws';
    final transportAvailability = ref.watch(socketTransportOptionsProvider);
    final allowWebsocketUpgrade = transportAvailability.allowWebsocketOnly;

    final requiresNewService =
        _service == null ||
        _serviceToken != token ||
        _service!.serverConfig.id != server.id ||
        _service!.websocketOnly != websocketOnly ||
        _service!.allowWebsocketUpgrade != allowWebsocketUpgrade;
    if (requiresNewService) {
      _disposeService();
      _service = ref.read(socketServiceFactoryProvider)(
        serverConfig: server,
        authToken: token,
        websocketOnly: websocketOnly,
        allowWebsocketUpgrade: allowWebsocketUpgrade,
      );
      _serviceToken = token;
      _scheduleConnect(_service!);
    }

    // Listen to connectivity changes to proactively manage socket connection.
    // When network goes offline, we can save resources by not attempting
    // reconnections. When network comes back, we force a reconnect.
    _connectivitySubscription ??= ref.listen<ConnectivityStatus>(
      connectivityStatusProvider,
      (previous, next) {
        final service = _service;
        if (service == null) return;

        if (next == ConnectivityStatus.offline) {
          service.updateNetworkAvailability(false);
          DebugLogger.log(
            'Connectivity offline - socket transport suspended',
            scope: 'socket/provider',
          );
        } else if (previous == ConnectivityStatus.offline &&
            next == ConnectivityStatus.online) {
          // Network just came back online - force reconnect to restore socket
          DebugLogger.log(
            'Connectivity restored - forcing socket reconnect',
            scope: 'socket/provider',
          );
          service.updateNetworkAvailability(true);
        }
      },
      fireImmediately: true,
    );

    return _service;
  }

  void _registerDisposeHook(int buildGeneration) {
    ref.onDispose(() {
      if (buildGeneration != _buildGeneration) return;

      // Fence every continuation before releasing the currently-owned service.
      _buildGeneration++;
      _connectivitySubscription?.close();
      _connectivitySubscription = null;

      // Riverpod runs onDispose both before a rebuild and when the provider is
      // destroyed. Let a replacement build retain a same-context socket, but
      // release it once the notifier is genuinely unmounted.
      scheduleMicrotask(() {
        if (!ref.mounted) {
          _disposeService();
        }
      });
    });
  }

  bool _buildStillOwnsContext({
    required int buildGeneration,
    required String token,
    required Object authSessionEpoch,
    required ServerConfig? server,
  }) {
    if (!ref.mounted || buildGeneration != _buildGeneration) return false;
    if (ref.read(reviewerModeProvider) ||
        !ref.read(isAuthenticatedProvider2) ||
        ref.read(authTokenProvider3) != token ||
        !identical(
          ref.read(openWebUiAuthSessionEpochProvider),
          authSessionEpoch,
        )) {
      return false;
    }
    final currentServer = ref.read(activeServerProvider).asData;
    return currentServer != null && currentServer.value == server;
  }

  void _scheduleConnect(SocketService service) {
    final token = ++_connectToken;
    ref.read(postFrameSchedulerProvider).runAfterCurrentFrame(() {
      if (!ref.mounted) return;
      if (_connectToken != token) return;
      if (!identical(_service, service)) return;
      service.connectBestEffort(reason: 'provider-post-frame');
    });
  }

  void _disposeService() {
    _connectToken++;
    _serviceToken = null;
    if (_service == null) return;
    try {
      _service!.dispose();
    } catch (_) {}
    _service = null;
  }
}

final socketServiceProvider = Provider<SocketService?>((ref) {
  final asyncService = ref.watch(socketServiceManagerProvider);
  // While the manager re-runs its async `build` (on any watched-dependency
  // change), it is briefly `loading`; don't collapse the live socket to `null`
  // then — that churns consumers and forces HTTP-only sends. Fall back to the
  // manager's current service during loading/error; it's only truly null when
  // there is no active server / reviewer mode / it was disposed.
  return asyncService.maybeWhen(
    data: (service) => service,
    orElse: () =>
        ref.read(socketServiceManagerProvider.notifier).currentService,
  );
});

// Attachment upload queue — one instance per active server.
//
// Constructs the queue and kicks off its (async) initialization against the
// active server's API + Drift table. Consumers `await queue.ready` before
// enqueueing so an upload never races the load; `ready` is owned by the queue
// instance, so — unlike a `FutureProvider.future` — awaiting it cannot hang if
// this provider rebuilds mid-initialization. The provider is also gated on the
// authenticated state: logout flips `isAuthenticatedProvider2` false before its
// first await, disposing the previous queue immediately even though the active
// server (and ApiService object) is deliberately preserved. On server switch or
// logout, `ref.onDispose` cancels in-flight uploads and closes the stream so
// awaiting upload completers resolve via `onDone`. Null while unauthenticated,
// in reviewer mode, when there is no active server, or until that server's
// durable database is available.
final attachmentUploadQueueProvider = Provider<AttachmentUploadQueue?>((ref) {
  if (!ref.watch(isAuthenticatedProvider2)) return null;
  final api = ref.watch(apiServiceProvider);
  if (api == null) return null;
  // Database opening can be temporarily deferred on iOS (for example while
  // protected data is unavailable). Stay null and rebuild reactively instead
  // of publishing an apparently-ready queue that skipped durable rows forever.
  final database = ref.watch(appDatabaseProvider);
  if (database == null) return null;

  final queue = AttachmentUploadQueue();
  ref.onDispose(queue.dispose);
  // Readiness is exposed via `queue.ready`, awaited by callers. Attach an
  // immediate error-consuming branch so a Drift load failure cannot surface as
  // an uncaught fire-and-forget error; `queue.ready` retains the ORIGINAL
  // future and still rejects, aborting the upload before enqueue.
  final initialization = queue.initialize(
    onUpload: (filePath, fileName, {cancelToken}) =>
        api.uploadFile(filePath, fileName, cancelToken: cancelToken),
    database: () => database,
  );
  unawaited(initialization.catchError((Object _, StackTrace _) {}));
  return queue;
});

// Auth providers
// Auth token integration with API service - using unified auth system
final apiTokenUpdaterProvider = Provider<void>((ref) {
  void syncToken(ApiService? api, String? token) {
    if (api == null) return;
    api.updateAuthToken(token != null && token.isNotEmpty ? token : null);
    final length = token?.length ?? 0;
    DebugLogger.auth(
      'token-updated',
      scope: 'auth/api',
      data: {'length': length},
    );
  }

  syncToken(ref.read(apiServiceProvider), ref.read(authTokenProvider3));

  ref.listen<ApiService?>(apiServiceProvider, (previous, next) {
    syncToken(next, ref.read(authTokenProvider3));
  });

  ref.listen<String?>(authTokenProvider3, (previous, next) {
    syncToken(ref.read(apiServiceProvider), next);
  });
});
