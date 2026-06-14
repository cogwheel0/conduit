import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/auth/providers/unified_auth_providers.dart';
import '../database/database_provider.dart';
import '../providers/app_providers.dart';
import '../services/connectivity_service.dart';
import '../utils/debug_logger.dart';
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
  bool _startFired = false;

  @override
  void build() {
    // Everything below uses ref.listen/read (never watch) so the notifier is
    // not recreated and `_startFired` survives.

    // App start: fire once the first time (authenticated && db && client)
    // are all ready.
    ref.listen(isAuthenticatedProvider2, (previous, next) {
      if (previous != true && next) {
        _request('auth');
      }
      _maybeFireStart();
    });
    ref.listen(appDatabaseProvider, (_, _) => _maybeFireStart());
    ref.listen(syncApiClientProvider, (_, _) => _maybeFireStart());

    // Connectivity regained: pull AND drain the outbox (the drainer resets
    // backoff on pending ops then drains — A6/A7).
    ref.listen(isOnlineProvider, (previous, next) {
      if (previous == false && next) {
        _request('online');
        unawaited(ref.read(syncEngineProvider.notifier).drainNow());
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
      unawaited(ref.read(syncEngineProvider.notifier).drainOutbox());
    });

    // Foreground/background lifecycle + periodic timer.
    final observer = _SyncLifecycleObserver(
      onResumed: () {
        _request('foreground');
        _restartPeriodicTimer();
      },
      onPaused: _cancelPeriodicTimer,
    );
    _observer = observer;
    WidgetsBinding.instance.addObserver(observer);
    _restartPeriodicTimer();

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
    if (_startFired) return;
    final ready =
        ref.read(isAuthenticatedProvider2) &&
        ref.read(appDatabaseProvider) != null &&
        ref.read(syncApiClientProvider) != null;
    if (!ready) return;
    _startFired = true;
    _request('start');
  }

  void _restartPeriodicTimer() {
    _periodic?.cancel();
    _periodic = Timer.periodic(kPeriodicPullInterval, (_) {
      if (!ref.read(isOnlineProvider)) {
        DebugLogger.log('periodic-skipped-offline', scope: 'sync/triggers');
        return;
      }
      _request('periodic');
    });
  }

  void _cancelPeriodicTimer() {
    _periodic?.cancel();
    _periodic = null;
  }

  void _request(String reason) {
    DebugLogger.log(
      'trigger',
      scope: 'sync/triggers',
      data: {'reason': reason},
    );
    unawaited(
      ref.read(syncEngineProvider.notifier).requestPull(reason: reason),
    );
  }
}

class _SyncLifecycleObserver with WidgetsBindingObserver {
  _SyncLifecycleObserver({required this.onResumed, required this.onPaused});

  final void Function() onResumed;
  final void Function() onPaused;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onResumed();
        break;
      case AppLifecycleState.paused:
        onPaused();
        break;
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }
}
