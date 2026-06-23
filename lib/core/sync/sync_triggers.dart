import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/auth/providers/unified_auth_providers.dart';
import '../database/database_provider.dart';
import '../providers/app_providers.dart';
import '../services/connectivity_service.dart';
import '../utils/debug_logger.dart';
import 'pull_sync.dart';
import 'sync_api_client.dart';
import 'sync_engine.dart';

part 'sync_triggers.g.dart';

/// Periodic foreground pull interval (RFC §7.6).
const Duration kPeriodicPullInterval = Duration(minutes: 5);

/// Pull triggers ONLY (CDT-RFC-001 §7.6). Installed by being `ref.watch`ed
/// from the startup listener block in `app_startup_providers.dart`.
///
/// The pause checkpoint lives in the chat feature (inversion step E3) to
/// avoid a core/sync -> features/chat import. Manual pull-to-refresh,
/// post-mutation, and post-stream pulls are NOT wired here — they arrive via
/// the rewritten `refreshConversationsCache` (inversion C4) and the
/// streaming seam (E2), funneling into the same debounced `requestPull`.
@Riverpod(keepAlive: true)
class SyncTriggers extends _$SyncTriggers {
  Timer? _periodic;
  _SyncLifecycleObserver? _observer;
  bool _isForeground = false;
  bool _startFired = false;
  bool _startCheckQueued = false;
  Object? _startDatabase;
  Object? _startClient;

  @override
  void build() {
    // Everything below uses ref.listen/read (never watch) so the notifier is
    // not recreated and `_startFired` survives.

    // App start: fire once the first time (authenticated && db && client)
    // are all ready.
    ref.listen(isAuthenticatedProvider2, (previous, next) {
      if (previous != true && next) {
        _requestIfReady('auth');
      }
      _maybeFireStart();
    });
    ref.listen(appDatabaseProvider, (_, _) => _queueMaybeFireStart());
    ref.listen(syncApiClientProvider, (_, _) => _queueMaybeFireStart());

    // Connectivity regained: pull AND drain the outbox (the drainer resets
    // backoff on pending ops then drains — A6/A7).
    ref.listen(isOnlineProvider, (previous, next) {
      if (previous == false && next) {
        _request('online');
        _runEngineOperation(
          'drain-now',
          reason: 'online',
          run: (engine) => engine.drainNow(),
        );
      }
    });

    // Active-conversation change: drain the outbox so a completion deferred
    // because a different chat was foregrounded (request_completion_runner
    // Option B) runs live the moment the user opens its chat. Plain drain (no
    // backoff reset), single-flight in the engine; a no-op when the outbox is
    // empty. Only fires for a real chat (non-null, non-temporary).
    ref.listen(activeConversationProvider, (previous, next) {
      final id = next?.id;
      if (id == null || id.isEmpty || isTemporaryChat(id)) return;
      if (previous?.id == id) return;
      _runEngineOperation(
        'drain-outbox',
        reason: 'active-conversation',
        run: (engine) => engine.drainOutbox(),
      );
    });

    // Foreground/background lifecycle + periodic timer.
    final observer = _SyncLifecycleObserver(
      onResumed: () {
        _isForeground = true;
        _request('foreground');
        _restartPeriodicTimer();
      },
      onSuspended: _leaveForeground,
    );
    _observer = observer;
    WidgetsBinding.instance.addObserver(observer);

    // Flutter does NOT re-deliver the current lifecycle state to a freshly
    // added observer (flutter/flutter#73947). On a cold launch the app is
    // already resumed before this observer registers, so onResumed never fires
    // and the periodic timer would not start until a background/foreground
    // round-trip. Seed the initial foreground state and start the timer.
    // We do NOT call onResumed() here, since that would also fire a redundant
    // 'foreground' pull on top of the 'start' pull from _maybeFireStart().
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _isForeground = true;
      _restartPeriodicTimer();
    }

    ref.onDispose(() {
      _cancelPeriodicTimer();
      final installed = _observer;
      _observer = null;
      if (installed != null) {
        WidgetsBinding.instance.removeObserver(installed);
      }
    });

    _maybeFireStart();
  }

  void _maybeFireStart() {
    final db = ref.read(appDatabaseProvider);
    final client = ref.read(syncApiClientProvider);
    if (!ref.read(isAuthenticatedProvider2) || db == null || client == null) {
      return;
    }
    if (_startFired &&
        identical(db, _startDatabase) &&
        identical(client, _startClient)) {
      return;
    }
    if (_request('start')) {
      _startFired = true;
      _startDatabase = db;
      _startClient = client;
    }
  }

  void _queueMaybeFireStart() {
    if (_startCheckQueued) return;
    _startCheckQueued = true;
    scheduleMicrotask(() {
      _startCheckQueued = false;
      if (!ref.mounted) return;
      _maybeFireStart();
    });
  }

  void _requestIfReady(String reason) {
    if (ref.read(appDatabaseProvider) == null ||
        ref.read(syncApiClientProvider) == null) {
      DebugLogger.log(
        'trigger-skipped-not-ready',
        scope: 'sync/triggers',
        data: {'reason': reason},
      );
      return;
    }
    _request(reason);
  }

  void _restartPeriodicTimer() {
    _periodic?.cancel();
    _periodic = Timer.periodic(kPeriodicPullInterval, (_) {
      if (!_isForeground) {
        DebugLogger.log('periodic-skipped-background', scope: 'sync/triggers');
        return;
      }
      if (!ref.read(isOnlineProvider)) {
        DebugLogger.log('periodic-skipped-offline', scope: 'sync/triggers');
        return;
      }
      _request('periodic');
    });
  }

  void _leaveForeground() {
    _isForeground = false;
    _cancelPeriodicTimer();
  }

  void _cancelPeriodicTimer() {
    _periodic?.cancel();
    _periodic = null;
  }

  bool _request(String reason) {
    DebugLogger.log(
      'trigger',
      scope: 'sync/triggers',
      data: {'reason': reason},
    );
    return _requestPull(reason);
  }

  bool _requestPull(String reason) {
    Future<PullResult?> pull;
    try {
      pull = ref.read(syncEngineProvider.notifier).requestPull(reason: reason);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'engine-operation-failed',
        scope: 'sync/triggers/request-pull',
        error: error,
        stackTrace: stackTrace,
        data: {'operation': 'request-pull', 'reason': reason},
      );
      return false;
    }
    unawaited(
      pull.catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'engine-operation-failed',
          scope: 'sync/triggers/request-pull',
          error: error,
          stackTrace: stackTrace,
          data: {'operation': 'request-pull', 'reason': reason},
        );
        return null;
      }),
    );
    return true;
  }

  void _runEngineOperation(
    String operation, {
    required String reason,
    required Future<void> Function(SyncEngine engine) run,
  }) {
    Future<void> future;
    try {
      future = run(ref.read(syncEngineProvider.notifier));
    } catch (error, stackTrace) {
      DebugLogger.error(
        'engine-operation-failed',
        scope: 'sync/triggers/$operation',
        error: error,
        stackTrace: stackTrace,
        data: {'operation': operation, 'reason': reason},
      );
      return;
    }
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'engine-operation-failed',
          scope: 'sync/triggers/$operation',
          error: error,
          stackTrace: stackTrace,
          data: {'operation': operation, 'reason': reason},
        );
      }),
    );
  }
}

class _SyncLifecycleObserver with WidgetsBindingObserver {
  _SyncLifecycleObserver({required this.onResumed, required this.onSuspended});

  final void Function() onResumed;
  final void Function() onSuspended;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onResumed();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        onSuspended();
        break;
    }
  }
}
