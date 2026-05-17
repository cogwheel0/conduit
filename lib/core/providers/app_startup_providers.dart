import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/app_providers.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../services/navigation_service.dart';
import '../services/app_intents_service.dart';
import '../services/home_widget_service.dart';
import '../services/api_service.dart';
import '../models/conversation.dart';
import '../services/background_streaming_handler.dart';
import '../services/socket_service.dart';
import '../services/connectivity_service.dart';
import '../utils/debug_logger.dart';
import '../models/server_config.dart';

part 'app_startup_providers.g.dart';

enum _ConversationWarmupStatus { idle, warming, complete }

final _conversationWarmupControllerProvider =
    NotifierProvider<_ConversationWarmupController, _ConversationWarmupState>(
      _ConversationWarmupController.new,
    );

class _ConversationWarmupState {
  const _ConversationWarmupState({
    this.status = _ConversationWarmupStatus.idle,
    this.lastAttempt,
    this.queuedForcedRefresh = false,
  });

  final _ConversationWarmupStatus status;
  final DateTime? lastAttempt;
  final bool queuedForcedRefresh;

  _ConversationWarmupState copyWith({
    _ConversationWarmupStatus? status,
    DateTime? lastAttempt,
    bool? queuedForcedRefresh,
  }) {
    return _ConversationWarmupState(
      status: status ?? this.status,
      lastAttempt: lastAttempt ?? this.lastAttempt,
      queuedForcedRefresh: queuedForcedRefresh ?? this.queuedForcedRefresh,
    );
  }
}

class _ConversationWarmupController extends Notifier<_ConversationWarmupState> {
  @override
  _ConversationWarmupState build() => const _ConversationWarmupState();

  void setStatus(_ConversationWarmupStatus status) {
    if (state.status == status) {
      return;
    }
    state = state.copyWith(status: status);
  }

  void beginAttempt(DateTime attemptedAt) {
    state = state.copyWith(
      status: _ConversationWarmupStatus.warming,
      lastAttempt: attemptedAt,
    );
  }

  void queueForcedRefresh() {
    if (state.queuedForcedRefresh) {
      return;
    }
    state = state.copyWith(queuedForcedRefresh: true);
  }

  void clearQueuedForcedRefresh() {
    if (!state.queuedForcedRefresh) {
      return;
    }
    state = state.copyWith(queuedForcedRefresh: false);
  }

  bool takeQueuedForcedRefresh() {
    final queued = state.queuedForcedRefresh;
    clearQueuedForcedRefresh();
    return queued;
  }
}

class _QueuedLatestRunner {
  bool _inFlight = false;
  bool _queued = false;

  void clearQueued() => _queued = false;

  void schedule({
    required Future<void> Function() run,
    required void Function(Object error, StackTrace stackTrace) onError,
  }) {
    _queued = true;
    if (_inFlight) {
      return;
    }

    Future.microtask(() async {
      if (_inFlight) {
        return;
      }
      _inFlight = true;
      try {
        while (_queued) {
          _queued = false;
          try {
            await run();
          } catch (error, stackTrace) {
            onError(error, stackTrace);
          }
        }
      } finally {
        _inFlight = false;
      }
    });
  }
}

Future<bool> _warmFoldersIfNeeded(Ref ref) async {
  try {
    await ref.read(foldersProvider.notifier).warmIfNeeded();
    return ref.read(foldersProvider).hasValue;
  } catch (error) {
    DebugLogger.warning(
      'folders-warmup-failed',
      scope: 'startup',
      data: {'error': error.toString()},
    );
    return false;
  }
}

Duration _conversationWarmupDelay(ConnectivityService connectivity) {
  final latency = connectivity.lastLatencyMs;
  final extraDelayMs = latency > 800
      ? 400
      : latency > 400
      ? 200
      : 0;
  return Duration(milliseconds: extraDelayMs);
}

typedef _ConversationWarmupOutcome = ({
  String? completedLog,
  _ConversationWarmupStatus status,
});

Future<_ConversationWarmupOutcome> _runConversationWarmup(
  Ref ref, {
  required bool force,
  required bool refreshConversations,
}) async {
  if (!ref.read(connectivityServiceProvider).isAppForeground) {
    return (completedLog: null, status: _ConversationWarmupStatus.idle);
  }

  final existing = ref.read(conversationsProvider);
  if (existing.hasValue) {
    final foldersReadyFuture = _warmFoldersIfNeeded(ref);
    if (force && refreshConversations) {
      await ref.read(conversationsProvider.notifier).refresh(forceFresh: true);
      final foldersReady = await foldersReadyFuture;
      final refreshed = ref.read(conversationsProvider);
      if (!foldersReady || !refreshed.hasValue) {
        return (completedLog: null, status: _ConversationWarmupStatus.idle);
      }
      final conversations = refreshed.asData?.value ?? const <Conversation>[];
      return (
        completedLog:
            'Background chats warmup refreshed ${conversations.length} conversations',
        status: _ConversationWarmupStatus.complete,
      );
    }

    final foldersReady = await foldersReadyFuture;
    return (
      completedLog: null,
      status: foldersReady
          ? _ConversationWarmupStatus.complete
          : _ConversationWarmupStatus.idle,
    );
  }

  if (existing.hasError && refreshConversations) {
    refreshConversationsCache(ref, includeFolders: true);
  }

  final foldersReadyFuture = _warmFoldersIfNeeded(ref);
  final conversations = await ref.read(conversationsProvider.future);
  final foldersReady = await foldersReadyFuture;
  if (!foldersReady) {
    return (completedLog: null, status: _ConversationWarmupStatus.idle);
  }
  return (
    completedLog:
        'Background chats warmup fetched ${conversations.length} conversations',
    status: _ConversationWarmupStatus.complete,
  );
}

void _resetConversationWarmup(Ref ref) {
  ref
      .read(_conversationWarmupControllerProvider.notifier)
      .setStatus(_ConversationWarmupStatus.idle);
}

void _scheduleForcedConversationWarmup(
  Ref ref, {
  bool refreshConversations = true,
}) {
  Future.microtask(() {
    if (!ref.mounted) return;
    _scheduleConversationWarmup(
      ref,
      force: true,
      refreshConversations: refreshConversations,
    );
  });
}

void _scheduleConversationWarmup(
  Ref ref, {
  bool force = false,
  bool refreshConversations = true,
}) {
  final navState = ref.read(authNavigationStateProvider);
  final warmupController = ref.read(
    _conversationWarmupControllerProvider.notifier,
  );
  if (navState != AuthNavigationState.authenticated) {
    _resetConversationWarmup(ref);
    return;
  }

  final connectivity = ref.read(connectivityServiceProvider);
  if (!connectivity.isAppForeground) {
    return;
  }

  final isOnline = ref.read(isOnlineProvider);
  if (!isOnline) {
    return;
  }
  final delay = _conversationWarmupDelay(connectivity);
  final warmupState = ref.read(_conversationWarmupControllerProvider);

  if (!force) {
    if (warmupState.status == _ConversationWarmupStatus.warming ||
        warmupState.status == _ConversationWarmupStatus.complete) {
      return;
    }
  } else if (warmupState.status == _ConversationWarmupStatus.warming) {
    if (refreshConversations) {
      warmupController.queueForcedRefresh();
    }
    return;
  }

  final now = DateTime.now();
  if (!force &&
      warmupState.lastAttempt != null &&
      now.difference(warmupState.lastAttempt!) < const Duration(seconds: 30)) {
    return;
  }
  warmupController.beginAttempt(now);

  Future.microtask(() async {
    if (delay > Duration.zero) {
      await Future.delayed(delay);
    }
    try {
      final outcome = await _runConversationWarmup(
        ref,
        force: force,
        refreshConversations: refreshConversations,
      );
      warmupController.setStatus(outcome.status);
      if (outcome.completedLog != null) {
        DebugLogger.info(outcome.completedLog!);
      }
    } catch (error) {
      DebugLogger.warning('Background chats warmup failed: $error');
      _resetConversationWarmup(ref);
    } finally {
      if (ref.mounted && warmupController.takeQueuedForcedRefresh()) {
        _scheduleForcedConversationWarmup(ref);
      }
    }
  });
}

/// Initialize background streaming handler with error callbacks.
///
/// This registers callbacks for platform events (service failures, time limits, etc.)
Future<void> _initializeBackgroundStreaming(Ref ref) async {
  try {
    await BackgroundStreamingHandler.instance.initialize(
      serviceFailedCallback: (error, errorType, streamIds) {
        if (!ref.mounted) return;
        DebugLogger.error(
          'background-service-failed',
          scope: 'startup',
          error: error,
          data: {'type': errorType, 'streams': streamIds.length},
        );
        // Clear any streaming state in chat providers for failed streams
        // The UI will show the partially completed message
      },
      timeLimitApproachingCallback: (remainingMinutes) {
        if (!ref.mounted) return;
        DebugLogger.warning(
          'background-time-limit',
          scope: 'startup',
          data: {'remainingMinutes': remainingMinutes},
        );
        // Could show a notification to the user here
      },
      microphonePermissionFallbackCallback: () {
        if (!ref.mounted) return;
        DebugLogger.warning('background-mic-fallback', scope: 'startup');
        // Microphone permission not granted, falling back to data sync only
      },
      streamsSuspendingCallback: (streamIds) {
        if (!ref.mounted) return;
        DebugLogger.stream(
          'streams-suspending',
          scope: 'startup',
          data: {'count': streamIds.length},
        );
      },
      backgroundTaskExpiringCallback: () {
        if (!ref.mounted) return;
        DebugLogger.stream('background-task-expiring', scope: 'startup');
      },
      backgroundTaskExtendedCallback: (streamIds, estimatedSeconds) {
        if (!ref.mounted) return;
        DebugLogger.stream(
          'background-task-extended',
          scope: 'startup',
          data: {'count': streamIds.length, 'seconds': estimatedSeconds},
        );
      },
      backgroundKeepAliveCallback: () {
        // Keep-alive signal received from platform
      },
    );

    if (!ref.mounted) return;

    // Check background refresh status on iOS and log warning if disabled
    final bgRefreshEnabled = await BackgroundStreamingHandler.instance
        .checkBackgroundRefreshStatus();

    if (!ref.mounted) return;

    if (!bgRefreshEnabled) {
      DebugLogger.warning(
        'background-refresh-disabled',
        scope: 'startup',
        data: {
          'message':
              'Background App Refresh is disabled. Background streaming may be limited.',
        },
      );
    }

    // Check notification permission on Android 13+ and log warning if denied
    // Without notification permission, foreground service runs silently without user awareness
    final notificationPermission = await BackgroundStreamingHandler.instance
        .checkNotificationPermission();

    if (!ref.mounted) return;

    if (!notificationPermission) {
      DebugLogger.warning(
        'notification-permission-denied',
        scope: 'startup',
        data: {
          'message':
              'Notification permission denied. Background streaming notifications will not be shown.',
        },
      );
    }
  } catch (e) {
    if (!ref.mounted) return;
    DebugLogger.error('background-init-failed', scope: 'startup', error: e);
  }
}

/// App-level startup/background task flow orchestrator.
///
/// Moves background initialization out of widgets and into a Riverpod controller,
/// keeping UI lean and business logic centralized while avoiding side effects
/// during provider build.
@Riverpod(keepAlive: true)
class AppStartupFlow extends _$AppStartupFlow {
  bool _started = false;
  ProviderSubscription<SocketService?>? _socketSubscription;
  ProviderSubscription<void>? _defaultModelAutoSelectionSubscription;
  Timer? _defaultModelPreloadTimer;
  final _postAuthStartupRunner = _QueuedLatestRunner();

  bool _hasAuthenticatedSession() =>
      ref.mounted &&
      ref.read(authNavigationStateProvider) ==
          AuthNavigationState.authenticated;

  void _cancelDefaultModelPreload() {
    _defaultModelPreloadTimer?.cancel();
    _defaultModelPreloadTimer = null;
  }

  void _keepAlive<T>(ProviderListenable<T> provider) {
    ref.listen<T>(provider, (previous, value) {});
  }

  void _keepDefaultModelAutoSelectionAlive() {
    _defaultModelAutoSelectionSubscription ??= ref.listen<void>(
      defaultModelAutoSelectionProvider,
      (previous, value) {},
    );
  }

  void _disposeStartupResources() {
    _socketSubscription?.close();
    _socketSubscription = null;
    _defaultModelAutoSelectionSubscription?.close();
    _defaultModelAutoSelectionSubscription = null;
    _cancelDefaultModelPreload();
  }

  void _clearQueuedAuthenticatedStartupWork() {
    _postAuthStartupRunner.clearQueued();
    _cancelDefaultModelPreload();
    ref
        .read(_conversationWarmupControllerProvider.notifier)
        .clearQueuedForcedRefresh();
  }

  void _applyCurrentAuthTokenToApi(ApiService api) {
    final authToken = ref.read(authTokenProvider3);
    if (authToken == null || authToken.isEmpty) {
      return;
    }
    api.updateAuthToken(authToken);
    DebugLogger.auth('StartupFlow: Applied auth token to API');
  }

  Duration _defaultModelPreloadDelay() {
    final latency = ref.read(connectivityServiceProvider).lastLatencyMs;
    final delayMs = latency < 0
        ? 300
        : latency > 800
        ? 600
        : 200 + (latency ~/ 2);
    return Duration(milliseconds: delayMs);
  }

  void _scheduleDefaultModelPreload({
    bool keepDefaultModelAutoSelectionAlive = true,
  }) {
    _cancelDefaultModelPreload();
    _defaultModelPreloadTimer = Timer(_defaultModelPreloadDelay(), () async {
      _defaultModelPreloadTimer = null;
      if (!_hasAuthenticatedSession()) {
        return;
      }
      try {
        await ref.read(defaultModelProvider.future);
      } catch (e) {
        DebugLogger.warning(
          'model-preload-failed',
          scope: 'startup',
          data: {'error': e},
        );
      } finally {
        if (_hasAuthenticatedSession() && keepDefaultModelAutoSelectionAlive) {
          _keepDefaultModelAutoSelectionAlive();
        }
      }
    });
  }

  void _scheduleAfterDelay(Duration delay, VoidCallback action) {
    Future<void>.delayed(delay, () {
      if (!ref.mounted) {
        return;
      }
      action();
    });
  }

  void _scheduleDeferredKeepAlive<T>(
    Duration delay,
    ProviderListenable<T> provider,
  ) {
    _scheduleAfterDelay(delay, () => _keepAlive(provider));
  }

  void _scheduleInitialConversationWarmup() {
    Future.microtask(() {
      if (!ref.read(isOnlineProvider)) {
        return;
      }

      final jitter = Duration(
        milliseconds: 150 + (DateTime.now().millisecond % 200),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!ref.mounted) {
          return;
        }
        await Future.delayed(jitter);
        if (!ref.mounted) {
          return;
        }
        _scheduleConversationWarmup(ref);
      });
    });
  }

  void _scheduleSystemUiPolish() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final context = NavigationService.context;
        final view = context != null ? View.maybeOf(context) : null;
        final dispatcher = WidgetsBinding.instance.platformDispatcher;
        final platformBrightness =
            view?.platformDispatcher.platformBrightness ??
            dispatcher.platformBrightness;
        final isDark = platformBrightness == Brightness.dark;
        SystemChrome.setSystemUIOverlayStyle(
          SystemUiOverlayStyle(
            statusBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
            systemNavigationBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
          ),
        );
      } catch (_) {}
    });
  }

  void _keepStartupProvidersAlive() {
    _keepAlive(authApiIntegrationProvider);
    _keepAlive(apiTokenUpdaterProvider);
    _keepAlive(silentLoginCoordinatorProvider);
    _keepAlive(appIntentCoordinatorProvider);
    _keepAlive(homeWidgetCoordinatorProvider);
  }

  void _scheduleStartupTasks() {
    _scheduleAfterDelay(const Duration(milliseconds: 120), () {
      ref.read(backgroundModelLoadProvider);
    });
    _scheduleDeferredKeepAlive(
      const Duration(milliseconds: 48),
      foregroundRefreshProvider,
    );
    _scheduleDeferredKeepAlive(
      const Duration(milliseconds: 96),
      socketPersistenceProvider,
    );
    _scheduleAfterDelay(const Duration(milliseconds: 64), () {
      _initializeBackgroundStreaming(ref);
    });
    _scheduleInitialConversationWarmup();
    _scheduleSystemUiPolish();
  }

  void _logStartupFlowFailure(Object error, StackTrace stackTrace) {
    DebugLogger.error(
      'startup-flow-failed',
      scope: 'startup',
      error: error,
      stackTrace: stackTrace,
    );
  }

  @override
  FutureOr<void> build() {}

  void start() {
    if (_started) return;
    _started = true;
    state = const AsyncValue<void>.data(null);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!ref.mounted) return;
      _activate();
    });
  }

  @visibleForTesting
  void scheduleConversationWarmup({
    bool force = false,
    bool refreshConversations = true,
  }) {
    _scheduleConversationWarmup(
      ref,
      force: force,
      refreshConversations: refreshConversations,
    );
  }

  Future<ApiService?> _waitForApiService({
    Duration timeout = const Duration(seconds: 1),
  }) async {
    if (!_hasAuthenticatedSession()) {
      return null;
    }

    final currentApi = ref.read(apiServiceProvider);
    if (currentApi != null) {
      return currentApi;
    }

    final completer = Completer<ApiService?>();
    ProviderSubscription<ApiService?>? apiSubscription;
    ProviderSubscription<AuthNavigationState>? authSubscription;
    Timer? timeoutTimer;

    void complete(ApiService? api) {
      if (completer.isCompleted) {
        return;
      }
      timeoutTimer?.cancel();
      apiSubscription?.close();
      authSubscription?.close();
      completer.complete(api);
    }

    apiSubscription = ref.listen<ApiService?>(apiServiceProvider, (
      previous,
      next,
    ) {
      if (next != null) {
        complete(next);
      }
    }, fireImmediately: true);
    if (!completer.isCompleted) {
      authSubscription = ref.listen<AuthNavigationState>(
        authNavigationStateProvider,
        (previous, next) {
          if (next != AuthNavigationState.authenticated) {
            complete(null);
          }
        },
      );
    }
    if (!completer.isCompleted) {
      timeoutTimer = Timer(timeout, () {
        if (!_hasAuthenticatedSession()) {
          complete(null);
          return;
        }
        complete(ref.read(apiServiceProvider));
      });
    }

    return completer.future;
  }

  Future<void> _runPostAuthenticationStartup({
    Duration apiWaitTimeout = const Duration(seconds: 1),
    bool keepDefaultModelAutoSelectionAlive = true,
  }) async {
    final api = await _waitForApiService(timeout: apiWaitTimeout);
    if (!_hasAuthenticatedSession()) {
      return;
    }
    if (api == null) {
      DebugLogger.warning(
        'API service not available for startup flow',
        scope: 'startup',
      );
      return;
    }

    _ensureSocketAttached();
    _applyCurrentAuthTokenToApi(api);
    _scheduleDefaultModelPreload(
      keepDefaultModelAutoSelectionAlive: keepDefaultModelAutoSelectionAlive,
    );

    // Kick background chat warmup now that we're authenticated
    _scheduleConversationWarmup(ref, force: true);
  }

  void _requestPostAuthenticationStartup({
    Duration apiWaitTimeout = const Duration(seconds: 1),
  }) {
    _postAuthStartupRunner.schedule(
      run: () => _runPostAuthenticationStartup(apiWaitTimeout: apiWaitTimeout),
      onError: _logStartupFlowFailure,
    );
  }

  void _installStartupListeners({
    Duration apiWaitTimeout = const Duration(seconds: 1),
  }) {
    // Retry authenticated startup work if the API becomes available after the
    // initial startup/auth transition request.
    ref.listen<ApiService?>(apiServiceProvider, (previous, next) {
      if (next != null && _hasAuthenticatedSession()) {
        _requestPostAuthenticationStartup(apiWaitTimeout: apiWaitTimeout);
      }
    });

    // Watch for auth transitions to trigger warmup and other background work.
    ref.listen<AuthNavigationState>(authNavigationStateProvider, (prev, next) {
      if (next == AuthNavigationState.authenticated) {
        _requestPostAuthenticationStartup(apiWaitTimeout: apiWaitTimeout);
      } else {
        _clearQueuedAuthenticatedStartupWork();
        _resetConversationWarmup(ref);
      }
    });

    // Retry warmup when connectivity is restored.
    ref.listen<bool>(isOnlineProvider, (prev, next) {
      if (next == true) {
        _scheduleConversationWarmup(ref);
      }
    });

    // When conversations reload (e.g., manual refresh), ensure warmup runs again.
    ref.listen<AsyncValue<List<Conversation>>>(conversationsProvider, (
      previous,
      next,
    ) {
      final wasReady = previous?.hasValue == true || previous?.hasError == true;
      if (wasReady && next.isLoading) {
        _resetConversationWarmup(ref);
        _scheduleForcedConversationWarmup(ref);
      }
    });
  }

  @visibleForTesting
  Future<void> runPostAuthenticationStartup({
    Duration apiWaitTimeout = const Duration(seconds: 1),
  }) {
    return _runPostAuthenticationStartup(
      apiWaitTimeout: apiWaitTimeout,
      keepDefaultModelAutoSelectionAlive: false,
    );
  }

  @visibleForTesting
  void activateForTesting({
    Duration apiWaitTimeout = const Duration(seconds: 1),
  }) {
    _started = true;
    state = const AsyncValue<void>.data(null);
    _activate(apiWaitTimeout: apiWaitTimeout);
  }

  void _activate({Duration apiWaitTimeout = const Duration(seconds: 1)}) {
    ref.onDispose(_disposeStartupResources);
    _keepStartupProvidersAlive();
    _scheduleStartupTasks();

    // If the session is already authenticated before startup flow attaches,
    // run the same post-auth startup path the auth transition listener uses.
    if (_hasAuthenticatedSession()) {
      _requestPostAuthenticationStartup(apiWaitTimeout: apiWaitTimeout);
    }

    _installStartupListeners(apiWaitTimeout: apiWaitTimeout);
  }

  void _ensureSocketAttached() {
    _socketSubscription ??= ref.listen<SocketService?>(
      socketServiceProvider,
      (previous, value) {},
    );
  }
}

// Tracks whether we've already attempted a silent login for the current app session.
final _silentLoginAttemptedProvider =
    NotifierProvider<_SilentLoginAttemptedNotifier, bool>(
      _SilentLoginAttemptedNotifier.new,
    );

class _SilentLoginAttemptedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void markAttempted() => state = true;
}

/// Coordinates a one-time silent login attempt when:
/// - There is an active server
/// - The auth navigation state requires login
/// - Saved credentials are present
final silentLoginCoordinatorProvider = Provider<void>((ref) {
  Future<void> attempt() async {
    final attempted = ref.read(_silentLoginAttemptedProvider);
    if (attempted) return;

    final authState = ref.read(authNavigationStateProvider);
    if (authState != AuthNavigationState.needsLogin) return;

    final activeServerAsync = ref.read(activeServerProvider);
    final hasActiveServer = activeServerAsync.maybeWhen(
      data: (server) => server != null,
      orElse: () => false,
    );
    if (!hasActiveServer) return;

    // Perform the attempt in a microtask to avoid side-effects in build
    Future.microtask(() async {
      try {
        final hasCreds = await ref.read(hasSavedCredentialsProvider2.future);
        if (hasCreds) {
          ref.read(_silentLoginAttemptedProvider.notifier).markAttempted();
          await ref.read(authActionsProvider).silentLogin();
        }
      } catch (_) {
        // Ignore silent login errors; app will proceed to manual login
      }
    });
  }

  void check() => attempt();

  // Initial check
  check();

  // React to changes in server or auth state
  ref.listen<AuthNavigationState>(authNavigationStateProvider, (prev, next) {
    check();
  });
  ref.listen<AsyncValue<ServerConfig?>>(activeServerProvider, (prev, next) {
    check();
  });
});

/// Listens to app lifecycle and refreshes server state when app returns to foreground.
///
/// Rationale: Socket.IO does not replay historical events. If the app was suspended,
/// we may miss updates. On resume, invalidate conversations to reconcile state.
final foregroundRefreshProvider = Provider<void>((ref) {
  final observer = _ForegroundRefreshObserver(ref);
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
});

class _ForegroundRefreshObserver extends WidgetsBindingObserver {
  final Ref _ref;
  _ForegroundRefreshObserver(this._ref);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Schedule to avoid side-effects during build frames
      Future.microtask(() {
        try {
          refreshConversationsCache(_ref);
          _resetConversationWarmup(_ref);
        } catch (_) {}
        // Resume already kicked off a forced conversations refresh above; only
        // finish the warmup work that should run alongside it.
        _scheduleForcedConversationWarmup(_ref, refreshConversations: false);
      });
    }
  }
}

/// Reconciles realtime socket state after the app returns from background.
///
/// Notes:
/// - Idle socket persistence intentionally does not use native background
///   execution. iOS and Android both treat that as expensive background work.
/// - Missed socket events are reconciled by refreshing foreground state on
///   resume.
final socketPersistenceProvider = Provider<void>((ref) {
  final observer = _SocketPersistenceObserver();
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
});

class _SocketPersistenceObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.resumed:
        // Reconcile background state on resume to detect orphaned services
        // or stale Flutter state from native service crashes
        _reconcileOnResume();
        break;
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        break;
    }
  }

  void _reconcileOnResume() {
    // Fire-and-forget reconciliation with error handling
    BackgroundStreamingHandler.instance.reconcileState().catchError((Object e) {
      DebugLogger.error(
        'socket-reconcile-failed',
        scope: 'background',
        error: e,
      );
      return false; // Return false to satisfy Future<bool> type
    });
  }
}
