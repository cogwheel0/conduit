import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/auth/providers/unified_auth_providers.dart';
import '../database/database_provider.dart';
import '../models/conversation.dart';
import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';
import 'chat_locks.dart';
import 'id_remapper.dart';
import 'pull_sync.dart';
import 'sync_api_client.dart';

part 'sync_engine.g.dart';

/// Debounce window for [SyncEngine.requestPull] (RFC §7.6).
const Duration kSyncPullDebounce = Duration(milliseconds: 300);

enum SyncPhase { idle, running }

/// Engine status surfaced to the UI.
class SyncStatus {
  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.lastSuccessUpdatedAtWatermark,
    this.lastError,
  });

  final SyncPhase phase;

  /// Server epoch seconds of the last successful cycle's watermark.
  final int? lastSuccessUpdatedAtWatermark;
  final String? lastError;
}

/// §9.3 cleanup seam: deletes the legacy Hive conversation/folder caches once
/// the first full pull has committed. Overridable in tests.
@Riverpod(keepAlive: true)
Future<void> Function() legacyConversationCachePurger(Ref ref) {
  return () async {
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.deleteLegacyConversationCaches();
  };
}

/// Debounced, single-flight pull orchestrator (CDT-RFC-001 §7.6, Phase 1).
///
/// Inert (requestPull logs and returns null) while unauthenticated or while
/// no database/client exists (no active server, reviewer mode).
@Riverpod(keepAlive: true)
class SyncEngine extends _$SyncEngine {
  Timer? _debounce;
  bool _running = false;
  bool _rerunRequested = false;

  /// Owned per notifier instance (which follows db identity via [build]). Wired
  /// into [PullSync] so pull merges can complete the §7.3 createChat crash-heal
  /// instead of duplicating. Disposed with the notifier.
  IdRemapper? _remapper;

  /// Completer for the cycle callers are currently joining (debouncing or
  /// queued behind a running cycle).
  Completer<PullResult?>? _joinable;

  @override
  SyncStatus build() {
    // Engine identity follows these dependencies; any change recreates the
    // notifier (pending waiters are released with null).
    ref.watch(appDatabaseProvider);
    ref.watch(syncApiClientProvider);
    ref.watch(isAuthenticatedProvider2);
    ref.watch(chatLocksProvider);
    ref.onDispose(() {
      _debounce?.cancel();
      unawaited(_remapper?.dispose());
      _remapper = null;
      final joinable = _joinable;
      _joinable = null;
      if (joinable != null && !joinable.isCompleted) {
        joinable.complete(null);
      }
    });
    return const SyncStatus();
  }

  bool get _inert =>
      ref.read(appDatabaseProvider) == null ||
      ref.read(syncApiClientProvider) == null ||
      !ref.read(isAuthenticatedProvider2);

  /// Single debounced entry point (RFC §7.6). 300 ms debounce; single-flight:
  /// a call during a running cycle sets a rerun flag (storms collapse to <= 1
  /// queued cycle). The returned future completes when the cycle the caller
  /// joined finishes — pull-to-refresh spinners await it.
  Future<PullResult?> requestPull({required String reason}) {
    if (_inert) {
      DebugLogger.log('inert', scope: 'sync/engine', data: {'reason': reason});
      return Future.value(null);
    }
    DebugLogger.log('request', scope: 'sync/engine', data: {'reason': reason});

    final joinable = _joinable ??= Completer<PullResult?>();
    if (_running) {
      // Queued cycle starts as soon as the running one finishes.
      _rerunRequested = true;
    } else {
      _debounce?.cancel();
      _debounce = Timer(kSyncPullDebounce, _startCycle);
    }
    return joinable.future;
  }

  /// Immediate, not debounced; serialization comes from [ChatLocks].
  Future<Conversation?> pullChatNow(String chatId) async {
    if (_inert) {
      DebugLogger.log(
        'inert',
        scope: 'sync/engine',
        data: {'reason': 'pullChatNow', 'chatId': chatId},
      );
      return null;
    }
    final pull = _buildPullSync();
    if (pull == null) return null;
    return pull.pullChat(chatId);
  }

  PullSync? _buildPullSync() {
    final db = ref.read(appDatabaseProvider);
    final client = ref.read(syncApiClientProvider);
    if (db == null || client == null) return null;
    return PullSync(
      client: client,
      db: db,
      locks: ref.read(chatLocksProvider),
      remapper: _remapper ??= IdRemapper(db),
    );
  }

  Future<void> _startCycle() async {
    final joined = _joinable;
    _joinable = null;
    if (joined == null || _running) return;
    _running = true;

    PullResult? result;
    String? lastError;
    try {
      if (ref.mounted) {
        state = SyncStatus(
          phase: SyncPhase.running,
          lastSuccessUpdatedAtWatermark: state.lastSuccessUpdatedAtWatermark,
          lastError: state.lastError,
        );
      }
      result = await _runOnce();
    } catch (error, stackTrace) {
      lastError = error.toString();
      DebugLogger.error(
        'cycle-failed',
        scope: 'sync/engine',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _running = false;
      if (ref.mounted) {
        state = SyncStatus(
          phase: SyncPhase.idle,
          lastSuccessUpdatedAtWatermark: (result?.success ?? false)
              ? await _readWatermark()
              : state.lastSuccessUpdatedAtWatermark,
          lastError:
              lastError ??
              ((result != null && !result.success)
                  ? 'pull failed (${result.failedFetches} fetch failures)'
                  : null),
        );
      }
      if (!joined.isCompleted) {
        joined.complete(result);
      }
      if (_rerunRequested && ref.mounted) {
        _rerunRequested = false;
        if (_joinable != null) {
          unawaited(_startCycle());
        }
      }
    }
  }

  Future<PullResult?> _runOnce() async {
    final db = ref.read(appDatabaseProvider);
    final pull = _buildPullSync();
    if (db == null || pull == null || !ref.read(isAuthenticatedProvider2)) {
      DebugLogger.log(
        'inert',
        scope: 'sync/engine',
        data: {'reason': 'dependencies-changed-mid-cycle'},
      );
      return null;
    }

    final previousWatermark = await db.syncMetaDao.getPullWatermark();
    final result = await pull.run();

    final foldersEnabled = result.foldersFeatureEnabled;
    if (foldersEnabled != null && ref.mounted) {
      ref
          .read(foldersFeatureEnabledProvider.notifier)
          .setEnabled(foldersEnabled);
    }

    // §9.3 cleanup: the legacy Hive cache is disposable; delete it exactly
    // once after the first successful full pull.
    if (result.success && previousWatermark == 0 && ref.mounted) {
      final purged = await db.syncMetaDao.getValue('hive_cache_purged');
      if (purged != '1') {
        try {
          await ref.read(legacyConversationCachePurgerProvider)();
          await db.syncMetaDao.setValue('hive_cache_purged', '1');
          DebugLogger.log('hive-cache-purged', scope: 'sync/engine');
        } catch (error, stackTrace) {
          DebugLogger.error(
            'hive-cache-purge-failed',
            scope: 'sync/engine',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    }
    return result;
  }

  Future<int?> _readWatermark() async {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return null;
    return db.syncMetaDao.getPullWatermark();
  }
}
