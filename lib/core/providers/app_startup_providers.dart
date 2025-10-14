import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/app_providers.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../services/navigation_service.dart';
import '../models/conversation.dart';
import '../services/background_streaming_handler.dart';
import '../services/persistent_streaming_service.dart';
import '../services/socket_service.dart';
import '../../features/onboarding/views/onboarding_sheet.dart';
import '../../shared/theme/theme_extensions.dart';
import '../services/connectivity_service.dart';
import '../utils/debug_logger.dart';
import '../models/server_config.dart';

part 'app_startup_providers.g.dart';

enum _ConversationWarmupStatus { idle, warming, complete }

final _conversationWarmupStatusProvider =
    NotifierProvider<
      _ConversationWarmupStatusNotifier,
      _ConversationWarmupStatus
    >(_ConversationWarmupStatusNotifier.new);

final _conversationWarmupLastAttemptProvider =
    NotifierProvider<_ConversationWarmupLastAttemptNotifier, DateTime?>(
      _ConversationWarmupLastAttemptNotifier.new,
    );

class _ConversationWarmupStatusNotifier
    extends Notifier<_ConversationWarmupStatus> {
  @override
  _ConversationWarmupStatus build() => _ConversationWarmupStatus.idle;

  void set(_ConversationWarmupStatus status) => state = status;
}

class _ConversationWarmupLastAttemptNotifier extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;

  void set(DateTime? value) => state = value;
}

void _scheduleConversationWarmup(Ref ref, {bool force = false}) {
  final navState = ref.read(authNavigationStateProvider);
  if (navState != AuthNavigationState.authenticated) {
    ref
        .read(_conversationWarmupStatusProvider.notifier)
        .set(_ConversationWarmupStatus.idle);
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

  // If network latency is high, delay warmup further to reduce contention
  final latency = connectivity.lastLatencyMs;
  final extraDelay = latency > 800
      ? 400
      : latency > 400
      ? 200
      : 0;

  final statusController = ref.read(_conversationWarmupStatusProvider.notifier);
  final status = ref.read(_conversationWarmupStatusProvider);

  if (!force) {
    if (status == _ConversationWarmupStatus.warming ||
        status == _ConversationWarmupStatus.complete) {
      return;
    }
  } else if (status == _ConversationWarmupStatus.warming) {
    return;
  }

  final now = DateTime.now();
  final lastAttempt = ref.read(_conversationWarmupLastAttemptProvider);
  if (!force &&
      lastAttempt != null &&
      now.difference(lastAttempt) < const Duration(seconds: 30)) {
    return;
  }
  ref.read(_conversationWarmupLastAttemptProvider.notifier).set(now);

  statusController.set(_ConversationWarmupStatus.warming);

  Future.microtask(() async {
    if (extraDelay > 0) {
      await Future.delayed(Duration(milliseconds: extraDelay));
    }
    try {
      if (!ref.read(connectivityServiceProvider).isAppForeground) {
        statusController.set(_ConversationWarmupStatus.idle);
        return;
      }

      final existing = ref.read(conversationsProvider);
      // If conversations are already loaded (either from cache or previous fetch),
      // mark warmup as complete without refetching. This prevents showing the
      // loading indicator when cached data is available.
      if (existing.hasValue) {
        statusController.set(_ConversationWarmupStatus.complete);
        return;
      }
      // Only refresh cache if there's an error, not when loading
      if (existing.hasError) {
        refreshConversationsCache(ref);
      }
      // If already loading, wait for it to complete instead of triggering a new fetch
      if (existing.isLoading) {
        try {
          final conversations = await ref.read(conversationsProvider.future);
          statusController.set(_ConversationWarmupStatus.complete);
          DebugLogger.info(
            'Background chats warmup completed (awaited existing load): ${conversations.length} conversations',
          );
        } catch (_) {
          // If the existing load fails, we'll retry on next warmup attempt
          statusController.set(_ConversationWarmupStatus.idle);
        }
        return;
      }
      // Only trigger a fresh fetch if we have no data and aren't already loading
      final conversations = await ref.read(conversationsProvider.future);
      statusController.set(_ConversationWarmupStatus.complete);
      DebugLogger.info(
        'Background chats warmup fetched ${conversations.length} conversations',
      );
    } catch (error) {
      DebugLogger.warning('Background chats warmup failed: $error');
      statusController.set(_ConversationWarmupStatus.idle);
    }
  });
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

  void _activate() {
    final ref = this.ref;

    ref.onDispose(() {
      _socketSubscription?.close();
      _socketSubscription = null;
    });

    void keepAlive<T>(ProviderListenable<T> provider) {
      ref.listen<T>(provider, (previous, value) {});
    }

    // Ensure token integration listeners are active
    keepAlive(authApiIntegrationProvider);
    keepAlive(apiTokenUpdaterProvider);
    keepAlive(silentLoginCoordinatorProvider);

    // Kick background model loading flow (non-blocking)
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (!ref.mounted) return;
      ref.read(backgroundModelLoadProvider);
    });

    // If authenticated, keep socket service alive and connected
    final navState = ref.read(authNavigationStateProvider);
    if (navState == AuthNavigationState.authenticated) {
      _ensureSocketAttached();
    }

    // Ensure resume-triggered foreground refresh is active
    Future<void>.delayed(const Duration(milliseconds: 48), () {
      if (!ref.mounted) return;
      keepAlive(foregroundRefreshProvider);
    });

    // Keep Socket.IO connection alive in background within platform limits
    Future<void>.delayed(const Duration(milliseconds: 96), () {
      if (!ref.mounted) return;
      keepAlive(socketPersistenceProvider);
    });

    // Ensure persistent streaming uses the shared connectivity service
    final connectivityService = ref.read(connectivityServiceProvider);
    Future<void>.delayed(const Duration(milliseconds: 160), () {
      if (!ref.mounted) return;
      PersistentStreamingService().attachConnectivityService(
        connectivityService,
      );
    });

    // Warm the conversations list in the background as soon as possible,
    // but avoid doing so on poor connectivity to reduce startup load.
    // Apply a small randomized delay to smooth load spikes across app wakes.
    Future.microtask(() async {
      final online = ref.read(isOnlineProvider);
      if (!online) return;
      // Slightly increase jitter to reduce contention on startup
      final jitter = Duration(
        milliseconds: 150 + (DateTime.now().millisecond % 200),
      );
      // Defer until after first frame to keep first paint smooth
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future.delayed(jitter);
        _scheduleConversationWarmup(ref);
      });
    });

    // One-time, post-frame system UI polish: set status bar icon brightness to
    // match theme after the first frame. Avoids flicker at startup.
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

    // Watch for auth transitions to trigger warmup and other background work
    ref.listen<AuthNavigationState>(authNavigationStateProvider, (prev, next) {
      if (next == AuthNavigationState.authenticated) {
        // Schedule microtask so we don't perform side-effects inside build
        Future.microtask(() async {
          try {
            final api = ref.read(apiServiceProvider);
            if (api == null) {
              DebugLogger.warning('API service not available for startup flow');
              return;
            }

            _ensureSocketAttached();

            // Ensure API has the latest token immediately
            final authToken = ref.read(authTokenProvider3);
            if (authToken != null && authToken.isNotEmpty) {
              api.updateAuthToken(authToken);
              DebugLogger.auth('StartupFlow: Applied auth token to API');
            }

            // Preload default model in background (best-effort) with an adaptive
            // delay based on network latency to avoid hammering poor networks.
            final latency = ref.read(connectivityServiceProvider).lastLatencyMs;
            final delayMs = latency < 0
                ? 300
                : latency > 800
                ? 600
                : 200 + (latency ~/ 2);
            Future.delayed(Duration(milliseconds: delayMs), () async {
              try {
                await ref.read(defaultModelProvider.future);
              } catch (e) {
                DebugLogger.warning(
                  'model-preload-failed',
                  scope: 'startup',
                  data: {'error': e},
                );
              }
            });

            // Kick background chat warmup now that we're authenticated
            _scheduleConversationWarmup(ref, force: true);

            // Show onboarding once when user reaches chat and hasn't seen it yet
            await _maybeShowOnboarding(ref);
          } catch (e) {
            DebugLogger.error(
              'startup-flow-failed',
              scope: 'startup',
              error: e,
            );
          }
        });
      } else {
        // Reset warmup state when leaving authenticated flow
        ref
            .read(_conversationWarmupStatusProvider.notifier)
            .set(_ConversationWarmupStatus.idle);
      }
    });

    // Retry warmup when connectivity is restored
    ref.listen<bool>(isOnlineProvider, (prev, next) {
      if (next == true) {
        _scheduleConversationWarmup(ref);
      }
    });

    // When conversations reload (e.g., manual refresh), ensure warmup runs again
    // However, we should NOT reset to idle if conversations transition to loading
    // while showing cached data - we only want to reset if explicitly invalidated
    ref.listen<AsyncValue<List<Conversation>>>(conversationsProvider, (
      previous,
      next,
    ) {
      // Only reset warmup status if transitioning from a ready state to loading
      // AND there's no cached data available (previous was null or error)
      final wasReady = previous?.hasValue == true;
      final isNowLoading = next.isLoading;
      final hasNoCachedData = previous?.hasValue != true;

      if (wasReady && isNowLoading && hasNoCachedData) {
        ref
            .read(_conversationWarmupStatusProvider.notifier)
            .set(_ConversationWarmupStatus.idle);
        Future.microtask(() => _scheduleConversationWarmup(ref, force: true));
      }
    });
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
          _ref
              .read(_conversationWarmupStatusProvider.notifier)
              .set(_ConversationWarmupStatus.idle);
        } catch (_) {}
        _scheduleConversationWarmup(_ref, force: true);
      });
    }
  }
}

/// Attempts to keep the realtime socket connection alive while the app is
/// backgrounded, similar to how PersistentStreamingService works for streams.
///
/// Notes:
/// - iOS: limited to short background task windows; we send periodic keepAlive.
/// - Android: uses existing foreground service notification.
final socketPersistenceProvider = Provider<void>((ref) {
  final observer = _SocketPersistenceObserver(ref);
  WidgetsBinding.instance.addObserver(observer);
  // React to active conversation changes while backgrounded
  final sub = ref.listen<Conversation?>(
    activeConversationProvider,
    (prev, next) => observer.onActiveConversationChanged(),
  );
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
  ref.onDispose(sub.close);
});

class _SocketPersistenceObserver extends WidgetsBindingObserver {
  final Ref _ref;
  _SocketPersistenceObserver(this._ref);

  static const String _socketId = 'socket-keepalive';
  Timer? _heartbeat;
  bool _bgActive = false;
  bool _isBackgrounded = false;

  bool _shouldKeepAlive() {
    final authed =
        _ref.read(authNavigationStateProvider) ==
        AuthNavigationState.authenticated;
    final hasConversation = _ref.read(activeConversationProvider) != null;
    return authed && hasConversation;
  }

  void _startBackground() {
    if (_bgActive) return;
    if (!_shouldKeepAlive()) return;
    try {
      BackgroundStreamingHandler.instance.startBackgroundExecution([_socketId]);
      // Periodic keep-alive (primarily useful on iOS)
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) async {
        try {
          await BackgroundStreamingHandler.instance.keepAlive();
        } catch (_) {}
      });
      _bgActive = true;
    } catch (_) {}
  }

  void _stopBackground() {
    if (!_bgActive) return;
    try {
      BackgroundStreamingHandler.instance.stopBackgroundExecution([_socketId]);
    } catch (_) {}
    _heartbeat?.cancel();
    _heartbeat = null;
    _bgActive = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        _isBackgrounded = true;
        _startBackground();
        break;
      case AppLifecycleState.resumed:
        _isBackgrounded = false;
        _stopBackground();
        break;
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _isBackgrounded = false;
        _stopBackground();
        break;
    }
  }

  // Called when active conversation changes; only acts during background
  void onActiveConversationChanged() {
    if (!_isBackgrounded) return;
    if (_shouldKeepAlive()) {
      _startBackground();
    } else {
      _stopBackground();
    }
  }
}

Future<void> _maybeShowOnboarding(Ref ref) async {
  try {
    final storage = ref.read(optimizedStorageServiceProvider);
    final seen = await storage.getOnboardingSeen();
    if (seen) return;

    // Small delay to allow initial navigation/frame to settle
    await Future.delayed(const Duration(milliseconds: 300));

    // Only surface onboarding on the chat route to avoid interrupting flows
    if (NavigationService.currentRoute != Routes.chat) return;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final navContext = NavigationService.navigatorKey.currentContext;
      if (navContext == null) return;

      // Show onboarding sheet
      showModalBottomSheet(
        context: navContext,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => Container(
          decoration: BoxDecoration(
            color: context.conduitTheme.surfaceBackground,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppBorderRadius.modal),
            ),
            boxShadow: ConduitShadows.modal(context),
          ),
          child: const OnboardingSheet(),
        ),
      );

      await storage.setOnboardingSeen(true);
    });
  } catch (e) {
    // Best-effort only; never fail app startup due to onboarding
    DebugLogger.warning('StartupFlow: onboarding display failed: $e');
  }
}
