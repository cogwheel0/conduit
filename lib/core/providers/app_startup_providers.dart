import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../database/local_conversation_loader.dart';
import '../database/database_provider.dart';
import '../auth/auth_state_manager.dart';
import '../auth/openwebui_account_owner_marker.dart';
import '../../features/hermes/services/hermes_session_provenance.dart';
import '../providers/app_providers.dart';
import '../sync/sync_triggers.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../services/navigation_service.dart';
import '../services/app_intents_service.dart';
import '../services/carplay_service.dart';
import '../services/home_widget_service.dart';
import '../services/api_service.dart';
import '../models/conversation.dart';
import '../models/user.dart';
import '../services/background_streaming_handler.dart';
import '../services/socket_service.dart';
import '../services/connectivity_service.dart';
import '../services/share_receiver_service.dart';
import '../utils/debug_logger.dart';
import '../utils/system_ui_style.dart';
import '../models/server_config.dart';
import '../persistence/persistence_keys.dart';
import '../persistence/preferences_store.dart';
import '../../features/tools/providers/tools_providers.dart';
import '../../features/chat/providers/chat_providers.dart';
import '../../features/chat/providers/remap_route_sync_provider.dart';
import '../../features/direct_connections/direct_connections.dart';
import '../../features/hermes/models/hermes_model.dart';
import '../../features/notifications/providers/notification_socket_listener.dart';
import '../../features/notifications/services/local_notification_service.dart';

part 'app_startup_providers.g.dart';

/// Clears keepAlive user-scoped providers after auth leaves the authenticated
/// state. This lives outside [AuthStateManager] because many of these providers
/// depend on auth state, and invalidating them from inside the auth notifier
/// trips Riverpod's circular dependency guard.
final userScopedProviderCleanupProvider = Provider<void>((ref) {
  ref.watch(openWebUiAccountStorageIsolationProvider);

  ref.listen<String?>(authTokenProvider3, (previous, next) {
    if (previous != null && next == null) {
      _cleanupUserScopedProvidersAfterSignOut(ref);
    }
  });

  ref.listen<AuthNavigationState>(authNavigationStateProvider, (
    previous,
    next,
  ) {
    if (previous != AuthNavigationState.authenticated ||
        next == AuthNavigationState.authenticated) {
      return;
    }

    _cleanupUserScopedProvidersAfterSignOut(ref);
  });
});

typedef _OpenWebUiAccountIdentity = ({String token, String? userId});
typedef OpenWebUiAccountCacheClear = Future<void> Function();
typedef OpenWebUiCertifiedUserPersist = Future<void> Function(User user);

final openWebUiAccountCacheClearProvider = Provider<OpenWebUiAccountCacheClear>(
  (ref) {
    final storage = ref.watch(optimizedStorageServiceProvider);
    return storage.clearUserScopedAuthData;
  },
);

final openWebUiCertifiedUserPersistProvider =
    Provider<OpenWebUiCertifiedUserPersist>((ref) {
      final storage = ref.watch(optimizedStorageServiceProvider);
      return (user) =>
          storage.saveLocalUserWithAvatar(user, avatarUrl: user.profileImage);
    });

/// Fail-closed ownership barrier for the server-scoped OpenWebUI database.
///
/// The current on-disk schema is keyed by server, not account. Until a future
/// account-scoped migration exists, every terminal auth transition deletes the
/// active server database before another account may open it. Direct-local
/// storage is independent and remains visible throughout.
final openWebUiAccountStorageIsolationProvider =
    NotifierProvider<OpenWebUiAccountStorageIsolation, void>(
      OpenWebUiAccountStorageIsolation.new,
    );

class OpenWebUiAccountStorageIsolation extends Notifier<void> {
  _OpenWebUiAccountIdentity? _certifiedIdentity;
  _OpenWebUiAccountIdentity? _pendingIdentity;
  bool _initialAuthDecisionComplete = false;
  bool _purgeRequired = false;
  bool _purgeRunning = false;
  bool _disposed = false;
  String? _cleanServerId;
  int _purgeGeneration = 0;
  int _certificationGeneration = 0;
  Future<void> _markerMutation = Future<void>.value();
  Future<void> _settled = Future<void>.value();

  @override
  void build() {
    ref.onDispose(() => _disposed = true);
    ref.listen<bool>(openWebUiCachedAccountOwnerMismatchProvider, (
      _,
      mismatch,
    ) {
      if (mismatch) _onCachedAccountOwnerMismatch();
    }, fireImmediately: true);
    ref.listen<AsyncValue<AuthState>>(
      authStateManagerProvider,
      (_, next) => _onAuthState(next),
      fireImmediately: true,
    );
    ref.listen<AsyncValue<ServerConfig?>>(
      activeServerProvider,
      (_, next) => _onActiveServer(next),
    );
  }

  @visibleForTesting
  Future<void> get settled => _settled;

  _OpenWebUiAccountIdentity? _identityFrom(AsyncValue<AuthState> value) {
    final auth = value.asData?.value;
    final token = auth?.token;
    if (auth == null ||
        !auth.isAuthenticated ||
        token == null ||
        token.isEmpty) {
      return null;
    }
    final userId = auth.user?.id.trim();
    return (
      token: token,
      userId: userId == null || userId.isEmpty ? null : userId,
    );
  }

  bool _sameAccount(
    _OpenWebUiAccountIdentity left,
    _OpenWebUiAccountIdentity right,
  ) {
    final leftUser = left.userId;
    final rightUser = right.userId;
    if (leftUser != null && rightUser != null) return leftUser == rightUser;
    return left.token == right.token;
  }

  bool _sameIdentity(
    _OpenWebUiAccountIdentity left,
    _OpenWebUiAccountIdentity right,
  ) => left.token == right.token && left.userId == right.userId;

  bool _ownerMarkerMatches(
    String serverId,
    _OpenWebUiAccountIdentity identity,
  ) {
    try {
      final marker = ref
          .read(openWebUiAccountOwnerMarkerStoreProvider)
          .read(serverId);
      return openWebUiAccountOwnerMarkerMatches(
        marker: marker,
        token: identity.token,
        userId: identity.userId,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'account-owner-marker-read-failed',
        scope: 'auth/storage-isolation',
        error: error,
        stackTrace: stackTrace,
        data: {'serverId': serverId},
      );
      return false;
    }
  }

  Future<void> _serializeMarkerMutation(Future<void> Function() mutation) {
    final operation = _markerMutation.then((_) => mutation());
    _markerMutation = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _writeOwnerMarker(
    String serverId,
    OpenWebUiAccountOwnerMarker marker,
  ) => _serializeMarkerMutation(
    () => ref
        .read(openWebUiAccountOwnerMarkerStoreProvider)
        .write(serverId, marker),
  );

  Future<void> _removeOwnerMarker(String serverId) => _serializeMarkerMutation(
    () => ref.read(openWebUiAccountOwnerMarkerStoreProvider).remove(serverId),
  );

  void _onCachedAccountOwnerMismatch() {
    if (_disposed) return;
    _initialAuthDecisionComplete = true;
    _certifiedIdentity = null;
    _pendingIdentity = null;
    _purgeRequired = true;
    _beginIsolation(reason: 'cached-account-owner-mismatch');
  }

  bool _isTerminalAccountDeparture(AuthState? auth) {
    if (auth == null || (auth.token?.isNotEmpty ?? false)) return false;
    return auth.status == AuthStatus.unauthenticated ||
        auth.status == AuthStatus.tokenExpired ||
        auth.status == AuthStatus.credentialError ||
        auth.status == AuthStatus.error;
  }

  void _onAuthState(AsyncValue<AuthState> next) {
    if (_disposed) return;
    final identity = _identityFrom(next);
    if (identity != null) {
      _onAuthenticated(identity);
      return;
    }

    final auth = next.asData?.value;
    if (!_isTerminalAccountDeparture(auth)) {
      // Loading/revalidation and connection errors can temporarily report
      // unauthenticated navigation while retaining the same token/account.
      // Epoch guards isolate async callbacks, but the certified cache remains.
      return;
    }
    final departedCertifiedSession = _certifiedIdentity != null;

    _initialAuthDecisionComplete = true;
    _certifiedIdentity = null;
    _pendingIdentity = null;
    _purgeRequired = true;
    _beginIsolation(
      reason: departedCertifiedSession
          ? 'authenticated-session-ended'
          : 'terminal-unauthenticated',
    );
  }

  void _onAuthenticated(_OpenWebUiAccountIdentity identity) {
    final certified = _certifiedIdentity;
    if (certified != null && _sameAccount(certified, identity)) {
      // Benign token refresh for the same confirmed account. Streaming/socket
      // owners still roll their auth epoch, but the account cache remains valid.
      _certifiedIdentity = identity;
      _settled = _refreshCertifiedOwnerMarker(identity);
      return;
    }

    _pendingIdentity = identity;
    final serverId = _currentServerId();
    final phase = ref.read(openWebUiDatabaseAccessProvider);

    if (!_initialAuthDecisionComplete &&
        certified == null &&
        !_purgeRequired &&
        phase == OpenWebUiDatabaseAccessPhase.bootstrap) {
      // activeServerProvider can still be resolving even though auth restored
      // first. Defer the cold-start decision; the server listener re-enters
      // this exact marker-validation branch once the identity is addressable.
      if (serverId == null) return;
      _initialAuthDecisionComplete = true;
      if (_ownerMarkerMatches(serverId, identity)) {
        // The marker is independent of the account database and was flushed
        // before that database was opened by the previous process.
        _scheduleCertification(markerAlreadyDurable: true);
      } else {
        // Legacy/missing/mismatched markers never self-certify from the cached
        // user stored inside the database they are supposed to protect.
        _purgeRequired = true;
        _beginIsolation(reason: 'cold-start-owner-marker-mismatch');
      }
      return;
    }

    _initialAuthDecisionComplete = true;
    if (!_purgeRunning &&
        !_purgeRequired &&
        serverId != null &&
        _cleanServerId == serverId) {
      _scheduleCertification();
      return;
    }

    _purgeRequired = true;
    _beginIsolation(reason: 'account-session-change');
  }

  void _onActiveServer(AsyncValue<ServerConfig?> next) {
    if (_disposed || next.isLoading || !next.hasValue) return;
    final nextServerId = next.asData?.value?.id;
    final certifiedServerId = ref.read(
      openWebUiCertifiedDatabaseServerProvider,
    );
    final phase = ref.read(openWebUiDatabaseAccessProvider);
    if (phase == OpenWebUiDatabaseAccessPhase.open &&
        certifiedServerId != null &&
        nextServerId != certifiedServerId) {
      _pendingIdentity = _identityFrom(ref.read(authStateManagerProvider));
      _certifiedIdentity = null;
      _purgeRequired = true;
      _beginIsolation(reason: 'certified-server-changed');
      return;
    }
    final pendingIdentity = _pendingIdentity;
    if (!_initialAuthDecisionComplete && pendingIdentity != null) {
      _onAuthenticated(pendingIdentity);
      return;
    }
    if (_pendingIdentity != null && !_purgeRequired && !_purgeRunning) {
      if (nextServerId != null && _cleanServerId == nextServerId) {
        _scheduleCertification();
      } else {
        // A completed purge certifies only the server it actually cleaned.
        // If the selection changed while owner-marker work was in flight, the
        // target server's previous account database is still untrusted.
        _purgeRequired = true;
        _beginIsolation(reason: 'pending-certification-server-not-clean');
      }
      return;
    }
    if (_purgeRequired && !_purgeRunning) {
      _ensurePurge(reason: 'active-server-resolved');
    }
  }

  void _beginIsolation({required String reason}) {
    _certificationGeneration++;
    ref.read(openWebUiDatabaseAccessProvider.notifier).beginPurge();
    ref.read(openWebUiCertifiedDatabaseServerProvider.notifier).clear();
    _clearOpenWebUiVisibleState();
    _ensurePurge(reason: reason);
  }

  String? _currentServerId() {
    try {
      final active = ref.read(activeServerProvider).asData?.value?.id;
      if (active != null && active.isNotEmpty) return active;
    } catch (_) {}
    try {
      final apiId = ref.read(apiServiceProvider)?.serverConfig.id;
      if (apiId != null && apiId.isNotEmpty) return apiId;
    } catch (_) {}
    final stored = PreferencesStore.getString(PreferenceKeys.activeServerId);
    return stored == null || stored.isEmpty ? null : stored;
  }

  void _ensurePurge({required String reason}) {
    if (_disposed || _purgeRunning || !_purgeRequired) return;
    final serverId = _currentServerId();
    if (serverId == null) {
      DebugLogger.warning(
        'purge-waiting-for-server',
        scope: 'auth/storage-isolation',
        data: {'reason': reason},
      );
      return;
    }

    _purgeRunning = true;
    final generation = ++_purgeGeneration;
    _settled = _runPurge(
      serverId: serverId,
      generation: generation,
      reason: reason,
    );
  }

  Future<void> _runPurge({
    required String serverId,
    required int generation,
    required String reason,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    final revokedStorageAccountIdentities = <String>{};
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final ownerMarker = ref
            .read(openWebUiAccountOwnerMarkerStoreProvider)
            .read(serverId);
        final ownerUserId = ownerMarker?.userId.trim();
        if (ownerMarker != null &&
            ownerUserId != null &&
            ownerUserId.isNotEmpty) {
          final storageAccountIdentity =
              HermesMixedSessionBindingTrustStore.durableStorageAccountIdentity(
                serverId: serverId,
                userId: ownerUserId,
                tokenFingerprint: ownerMarker.tokenFingerprint,
              );
          // If later cleanup fails, retry it without turning an already
          // committed trust revocation into another fallible preference write.
          // A changed owner is still revoked independently in this generation.
          if (!revokedStorageAccountIdentities.contains(
            storageAccountIdentity,
          )) {
            await HermesMixedSessionBindingTrustStore.forgetStorageAccount(
              storageAccountIdentity,
            );
            revokedStorageAccountIdentities.add(storageAccountIdentity);
          }
        }
        await ref.read(openWebUiAccountCacheClearProvider)();
        await ref.read(openWebUiDatabasePurgeProvider)(serverId);
        await _removeOwnerMarker(serverId);
        lastError = null;
        break;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        if (attempt < 3) {
          await Future<void>.delayed(Duration(milliseconds: 50 * attempt));
        }
      }
    }

    if (_disposed || generation != _purgeGeneration) return;
    _purgeRunning = false;
    if (lastError != null) {
      DebugLogger.error(
        'account-database-purge-failed',
        scope: 'auth/storage-isolation',
        error: lastError,
        stackTrace: lastStackTrace,
        data: {'serverId': serverId, 'reason': reason},
      );
      // Fail closed. A later server/auth transition may retry.
      ref.read(openWebUiDatabaseAccessProvider.notifier).close();
      return;
    }

    _cleanServerId = serverId;
    _purgeRequired = false;
    ref.invalidate(appDatabaseProvider);
    ref.invalidate(chatDatabaseRepositoryProvider);
    ref.invalidate(conversationsProvider);
    ref.invalidate(foldersProvider);

    final currentServerId = _currentServerId();
    if (currentServerId != null && currentServerId != serverId) {
      // The user changed server while A was being removed. Purge that target's
      // prior account cache as well before certifying the pending login.
      _purgeRequired = true;
      _ensurePurge(reason: 'server-changed-during-purge');
      return;
    }

    final currentIdentity = _identityFrom(ref.read(authStateManagerProvider));
    if (currentIdentity == null || _pendingIdentity == null) {
      ref.read(openWebUiDatabaseAccessProvider.notifier).close();
      return;
    }
    _pendingIdentity = currentIdentity;
    final certificationGeneration = ++_certificationGeneration;
    await _certifyPendingIdentity(
      generation: certificationGeneration,
      markerAlreadyDurable: false,
    );
  }

  void _scheduleCertification({bool markerAlreadyDurable = false}) {
    final generation = ++_certificationGeneration;
    _settled = _certifyPendingIdentity(
      generation: generation,
      markerAlreadyDurable: markerAlreadyDurable,
    );
  }

  Future<void> _refreshCertifiedOwnerMarker(
    _OpenWebUiAccountIdentity identity,
  ) async {
    final serverId = _currentServerId();
    final marker = openWebUiAccountOwnerMarker(
      token: identity.token,
      userId: identity.userId,
    );
    if (serverId == null || marker == null) return;
    try {
      await _writeOwnerMarker(serverId, marker);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'account-owner-marker-refresh-failed',
        scope: 'auth/storage-isolation',
        error: error,
        stackTrace: stackTrace,
        data: {'serverId': serverId},
      );
    }
  }

  Future<void> _certifyPendingIdentity({
    required int generation,
    required bool markerAlreadyDurable,
  }) async {
    final identity = _pendingIdentity;
    if (identity == null || _disposed) return;
    final current = _identityFrom(ref.read(authStateManagerProvider));
    if (current == null || !_sameIdentity(current, identity)) return;
    final serverId = _currentServerId();
    if (serverId == null) return;

    final marker = openWebUiAccountOwnerMarker(
      token: identity.token,
      userId: identity.userId,
    );
    if (marker == null) {
      ref.read(openWebUiDatabaseAccessProvider.notifier).close();
      return;
    }
    if (markerAlreadyDurable) {
      if (!_ownerMarkerMatches(serverId, identity)) {
        _purgeRequired = true;
        _beginIsolation(reason: 'owner-marker-changed-before-open');
        return;
      }
    } else {
      try {
        await _writeOwnerMarker(serverId, marker);
      } catch (error, stackTrace) {
        if (_disposed || generation != _certificationGeneration) return;
        DebugLogger.error(
          'account-owner-marker-write-failed',
          scope: 'auth/storage-isolation',
          error: error,
          stackTrace: stackTrace,
          data: {'serverId': serverId},
        );
        _purgeRequired = true;
        ref.read(openWebUiDatabaseAccessProvider.notifier).close();
        return;
      }
    }

    if (_disposed || generation != _certificationGeneration) return;
    final latest = _identityFrom(ref.read(authStateManagerProvider));
    final pending = _pendingIdentity;
    if (latest == null ||
        !_sameIdentity(latest, identity) ||
        pending == null ||
        !_sameIdentity(pending, identity) ||
        _currentServerId() != serverId ||
        _purgeRequired) {
      return;
    }

    _certifiedIdentity = latest;
    _pendingIdentity = null;
    _cleanServerId = null;
    _purgeRequired = false;
    ref.read(openWebUiCertifiedDatabaseServerProvider.notifier).set(serverId);
    ref.read(openWebUiDatabaseAccessProvider.notifier).open();
    ref.invalidate(appDatabaseProvider);
    ref.invalidate(chatDatabaseRepositoryProvider);
    ref.invalidate(conversationsProvider);
    ref.invalidate(foldersProvider);
    ref.invalidate(modelsProvider);
    ref.invalidate(currentUserProvider);
    ref.read(openWebUiCachedAccountOwnerMismatchProvider.notifier).set(false);
    final authenticated = ref.read(authStateManagerProvider).asData?.value;
    final certifiedUser = authenticated?.user;
    if (certifiedUser != null &&
        authenticated?.token == identity.token &&
        certifiedUser.id == identity.userId) {
      try {
        // A fresh account may have published while the database gate was
        // closed for purge, making AuthStateManager's earlier cache write a
        // no-op. Persist once more only after this marker is durable and the
        // freshly-owned database is open.
        await ref.read(openWebUiCertifiedUserPersistProvider)(certifiedUser);
      } catch (error, stackTrace) {
        DebugLogger.error(
          'certified-user-persist-failed',
          scope: 'auth/storage-isolation',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    DebugLogger.log(
      'account-database-certified',
      scope: 'auth/storage-isolation',
    );
  }

  void _clearOpenWebUiVisibleState() {
    var clearAccountChatState = true;
    try {
      final active = ref.read(activeConversationProvider);
      clearAccountChatState =
          active == null || conversationUsesOpenWebUiStorage(active);
      if (clearAccountChatState && active != null) {
        ref.read(activeConversationProvider.notifier).set(null);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'visible-state-active-conversation-clear-failed',
        scope: 'auth/storage-isolation',
        error: error,
        stackTrace: stackTrace,
      );
    }
    try {
      if (clearAccountChatState) {
        ref.invalidate(activeConversationInPlaceRemapProvider);
        ref.invalidate(chatMessagesProvider);
      }
      ref.invalidate(conversationsProvider);
      ref.invalidate(foldersProvider);
      ref.read(activeChatIdsProvider.notifier).setAll(const <String>{});
    } catch (error, stackTrace) {
      DebugLogger.error(
        'visible-state-provider-reset-failed',
        scope: 'auth/storage-isolation',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

Future<void> _cleanupUserScopedProvidersAfterSignOut(Ref ref) async {
  const attempts = 40;
  for (var attempt = 0; attempt < attempts; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!ref.mounted) {
      return;
    }
    if (ref.read(authNavigationStateProvider) ==
        AuthNavigationState.authenticated) {
      return;
    }
    if (ref.read(authTokenProvider3) == null &&
        !ref.read(isAuthLoadingProvider2)) {
      break;
    }
    if (attempt == attempts - 1) {
      return;
    }
  }

  if (!ref.mounted) {
    return;
  }
  try {
    final active = ref.read(activeConversationProvider);
    final preserveLocalConversation =
        active != null && !conversationUsesOpenWebUiStorage(active);
    final selectedModel = ref.read(selectedModelProvider);
    final preserveLocalModel =
        selectedModel != null &&
        (isLocallyMintedDirectModel(selectedModel) ||
            isHermesModel(selectedModel));
    ref.invalidate(conversationsProvider);
    if (!preserveLocalConversation) {
      ref.invalidate(activeConversationProvider);
    }
    ref.invalidate(foldersProvider);
    ref.invalidate(modelsProvider);
    if (!preserveLocalModel) {
      ref.invalidate(selectedModelProvider);
    }
    ref.invalidate(currentUserProvider);
    ref.invalidate(userSettingsProvider);
    ref.invalidate(rawUserSettingsProvider);
    ref.invalidate(personalizationSettingsProvider);
    ref.invalidate(userMemoriesProvider);
    ref.invalidate(accountProfileProvider);
    ref.invalidate(serverAboutInfoProvider);
    ref.invalidate(userPermissionsProvider);
    ref.invalidate(toolsListProvider);
    ref.invalidate(selectedToolIdsProvider);
    ref.invalidate(selectedTerminalIdProvider);
    ref.invalidate(selectedFilterIdsProvider);
    ref.invalidate(knowledgeBasesProvider);
    ref.invalidate(availableVoicesProvider);
    ref.invalidate(imageModelsProvider);
    ref.invalidate(defaultModelProvider);
    ref.invalidate(backendConfigProvider);
    ref.invalidate(socketServiceManagerProvider);
    // Clear posted notifications and drop the listener's dedup memory so a
    // notification can't deep-link into the previous session/server.
    unawaited(
      ref.read(localNotificationServiceProvider).cancelAll().catchError((
        Object e,
        StackTrace st,
      ) {
        DebugLogger.error(
          'failed to clear notifications on sign-out',
          scope: 'notifications/system',
          error: e,
          stackTrace: st,
        );
      }),
    );
    ref.invalidate(notificationRouterProvider);
    ref.invalidate(notificationSocketListenerProvider);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'user-scoped-provider-cleanup-failed',
      scope: 'startup',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

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

class _QueuedStartupTask {
  const _QueuedStartupTask({
    required this.label,
    required this.readyAt,
    required this.run,
  });

  final String label;
  final DateTime readyAt;
  final FutureOr<void> Function() run;
}

typedef _PostFrameScheduler = void Function(FrameCallback callback);

class _FrameBudgetedStartupQueue {
  _FrameBudgetedStartupQueue({
    _PostFrameScheduler? addPostFrameCallback,
    VoidCallback? ensureVisualUpdate,
  }) : _addPostFrameCallback =
           addPostFrameCallback ??
           SchedulerBinding.instance.addPostFrameCallback,
       _ensureVisualUpdate =
           ensureVisualUpdate ?? SchedulerBinding.instance.ensureVisualUpdate;

  bool _disposed = false;
  bool _frameScheduled = false;
  bool _running = false;
  Timer? _waitTimer;
  final List<_QueuedStartupTask> _tasks = <_QueuedStartupTask>[];
  final _PostFrameScheduler _addPostFrameCallback;
  final VoidCallback _ensureVisualUpdate;

  void schedule({
    required String label,
    required Duration delay,
    required FutureOr<void> Function() run,
    required void Function(Object error, StackTrace stackTrace) onError,
  }) {
    if (_disposed) {
      return;
    }

    _tasks.add(
      _QueuedStartupTask(
        label: label,
        readyAt: DateTime.now().add(delay),
        run: run,
      ),
    );
    _tasks.sort((a, b) => a.readyAt.compareTo(b.readyAt));
    _pump(onError);
  }

  void dispose() {
    _disposed = true;
    _waitTimer?.cancel();
    _tasks.clear();
  }

  void _pump(void Function(Object error, StackTrace stackTrace) onError) {
    if (_disposed || _running || _frameScheduled || _tasks.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final nextReadyAt = _tasks.first.readyAt;
    if (nextReadyAt.isAfter(now)) {
      _waitTimer?.cancel();
      _waitTimer = Timer(nextReadyAt.difference(now), () => _pump(onError));
      return;
    }

    _frameScheduled = true;
    _addPostFrameCallback((_) {
      _frameScheduled = false;
      if (_disposed || _running || _tasks.isEmpty) {
        return;
      }

      final readyIndex = _tasks.indexWhere(
        (task) => !task.readyAt.isAfter(DateTime.now()),
      );
      if (readyIndex == -1) {
        _pump(onError);
        return;
      }

      final task = _tasks.removeAt(readyIndex);
      _running = true;
      Future<void>.microtask(() async {
        try {
          await task.run();
        } catch (error, stackTrace) {
          onError(error, stackTrace);
          DebugLogger.warning(
            'startup-queue-task-failed',
            scope: 'startup',
            data: {'task': task.label, 'error': error.toString()},
          );
        } finally {
          _running = false;
          _pump(onError);
        }
      });
    });
    _ensureVisualUpdate();
  }
}

@visibleForTesting
void debugScheduleReadyStartupQueueTaskForTesting({
  required VoidCallback onEnsureVisualUpdate,
  required void Function(FrameCallback callback) onAddPostFrameCallback,
  required FutureOr<void> Function() run,
}) {
  final queue = _FrameBudgetedStartupQueue(
    addPostFrameCallback: onAddPostFrameCallback,
    ensureVisualUpdate: onEnsureVisualUpdate,
  );
  queue.schedule(
    label: 'debug-startup-task',
    delay: Duration.zero,
    run: run,
    onError: (error, stackTrace) {},
  );
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
  ProviderSubscription<void>? _directCompletionRelaySubscription;
  Timer? _defaultModelPreloadTimer;
  final _postAuthStartupRunner = _QueuedLatestRunner();
  final _startupTaskQueue = _FrameBudgetedStartupQueue();

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

  void _keepDirectCompletionRelayAlive() {
    if (!_hasAuthenticatedSession()) return;
    _directCompletionRelaySubscription ??= ref.listen<void>(
      openWebUiDirectCompletionSocketRelayProvider,
      (previous, value) {},
      fireImmediately: true,
    );
  }

  void _stopDirectCompletionRelay() {
    _directCompletionRelaySubscription?.close();
    _directCompletionRelaySubscription = null;
    // This relay is an always-alive provider so closing its only listener does
    // not by itself run the Socket.IO handler's teardown. Explicitly revoke
    // the cached provider state at the auth boundary.
    if (ref.mounted) {
      ref.invalidate(openWebUiDirectCompletionSocketRelayProvider);
    }
  }

  void _disposeStartupResources() {
    _socketSubscription?.close();
    _socketSubscription = null;
    _defaultModelAutoSelectionSubscription?.close();
    _defaultModelAutoSelectionSubscription = null;
    _stopDirectCompletionRelay();
    _cancelDefaultModelPreload();
    _startupTaskQueue.dispose();
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

  void _scheduleAfterDelay(
    Duration delay,
    FutureOr<void> Function() action, {
    required String label,
  }) {
    _startupTaskQueue.schedule(
      label: label,
      delay: delay,
      run: () async {
        if (!ref.mounted) {
          return;
        }
        await action();
      },
      onError: _logStartupFlowFailure,
    );
  }

  void _scheduleDeferredKeepAlive<T>(
    Duration delay,
    ProviderListenable<T> provider, {
    required String label,
  }) {
    _scheduleAfterDelay(delay, () => _keepAlive(provider), label: label);
  }

  void _scheduleInitialConversationWarmup() {
    if (!ref.read(isOnlineProvider)) {
      return;
    }

    final jitter = Duration(
      milliseconds: 150 + (DateTime.now().millisecond % 200),
    );
    _scheduleAfterDelay(jitter, () {
      if (!ref.read(isOnlineProvider)) {
        return;
      }
      _scheduleConversationWarmup(ref);
    }, label: 'conversation-warmup');
  }

  void _scheduleSystemUiPolish() {
    _scheduleAfterDelay(Duration.zero, () {
      try {
        final context = NavigationService.context;
        final view = context != null ? View.maybeOf(context) : null;
        final dispatcher = WidgetsBinding.instance.platformDispatcher;
        final platformBrightness =
            view?.platformDispatcher.platformBrightness ??
            dispatcher.platformBrightness;
        final themeMode = ref.read(appThemeModeProvider);
        final brightness = switch (themeMode) {
          ThemeMode.light => Brightness.light,
          ThemeMode.dark => Brightness.dark,
          ThemeMode.system => platformBrightness,
        };
        SystemChrome.setSystemUIOverlayStyle(
          systemUiOverlayStyleForBrightness(brightness),
        );
      } catch (_) {}
    }, label: 'system-ui-polish');
  }

  void _scheduleStartupProviderKeepAlives() {
    _scheduleDeferredKeepAlive(
      Duration.zero,
      authApiIntegrationProvider,
      label: 'auth-api-integration',
    );
    _scheduleDeferredKeepAlive(
      const Duration(milliseconds: 16),
      apiTokenUpdaterProvider,
      label: 'api-token-updater',
    );
    _scheduleDeferredKeepAlive(
      const Duration(milliseconds: 32),
      silentLoginCoordinatorProvider,
      label: 'silent-login',
    );
    _scheduleDeferredKeepAlive(
      const Duration(milliseconds: 48),
      appIntentCoordinatorProvider,
      label: 'app-intents',
    );
    _scheduleDeferredKeepAlive(
      const Duration(milliseconds: 56),
      carPlayCoordinatorProvider,
      label: 'carplay',
    );
    _scheduleDeferredKeepAlive(
      const Duration(milliseconds: 64),
      homeWidgetCoordinatorProvider,
      label: 'home-widget',
    );
    _scheduleAfterDelay(
      const Duration(milliseconds: 80),
      () => ref.read(shareReceiverInitializerProvider),
      label: 'share-receiver',
    );
  }

  void _scheduleStartupTasks() {
    _scheduleStartupProviderKeepAlives();
    _scheduleAfterDelay(
      const Duration(milliseconds: 120),
      () => ref.read(backgroundModelLoadProvider),
      label: 'background-model-load',
    );
    _scheduleDeferredKeepAlive(
      const Duration(milliseconds: 48),
      foregroundRefreshProvider,
      label: 'foreground-refresh',
    );
    _scheduleDeferredKeepAlive(
      const Duration(milliseconds: 96),
      socketPersistenceProvider,
      label: 'socket-persistence',
    );
    _scheduleAfterDelay(
      const Duration(milliseconds: 64),
      () => _initializeBackgroundStreaming(ref),
      label: 'background-streaming',
    );
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
    _warmApiConnection(api);
    // Activate the active-chats sync (global chat:active handler + initial bulk
    // fetch) so the sidebar generating spinner is correct app-wide, including
    // for generations started by other sessions. keepAlive keeps it running.
    ref.read(activeChatsSyncProvider);
    // Match Open WebUI's layout-scoped direct-completion RPC handler. It must
    // be listening before a completion POST can ask this client to contact the
    // saved provider and relay its stream through the server.
    _keepDirectCompletionRelayAlive();
    // Activate the notification listener (global chat/channel handlers feeding
    // the NotificationRouter). The router gates on the master toggle, so this is
    // safe to run unconditionally. Then drain any cold-launch notification tap.
    ref.read(notificationSocketListenerProvider);
    unawaited(
      ref.read(notificationSocketListenerProvider.notifier).handleLaunchTap(),
    );
    _scheduleDefaultModelPreload(
      keepDefaultModelAutoSelectionAlive: keepDefaultModelAutoSelectionAlive,
    );

    // Kick background chat warmup now that we're authenticated
    _scheduleConversationWarmup(ref, force: true);
  }

  /// Warm the API client's connection pool as soon as we're authenticated, so
  /// the first chat completion doesn't race a cold TLS/HTTP handshake and
  /// transiently fail (which would otherwise queue a retry). Fire-and-forget on
  /// the SAME Dio the completion uses; `checkHealth()` swallows its own errors.
  void _warmApiConnection(ApiService api) {
    unawaited(api.checkHealth());
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
    // Install the sync engine's pull triggers (CDT-RFC-001 §7.6): app start,
    // auth, foreground, connectivity-regained, and the periodic timer.
    _keepAlive(syncTriggersProvider);

    // Install the remap-route consumer (Wiring C): swaps the active-chat /
    // pending-folder id in place when a local id is remapped to a server id.
    _keepAlive(remapRouteSyncProvider);

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
        _stopDirectCompletionRelay();
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
          unawaited(_refreshActiveConversationOnResume(_ref));
        } catch (_) {}
        // Resume already kicked off a forced conversations refresh above; only
        // finish the warmup work that should run alongside it.
        _scheduleForcedConversationWarmup(_ref, refreshConversations: false);
      });
    } else if (state == AppLifecycleState.paused) {
      // D-07 pause checkpoint: echo an in-flight streaming turn to the local
      // database so a background kill cannot lose it.
      try {
        unawaited(
          _ref
              .read(chatMessagesProvider.notifier)
              .persistPauseCheckpoint()
              .catchError((Object error, StackTrace stackTrace) {
                DebugLogger.error(
                  'pause-checkpoint-failed',
                  scope: 'chat/pause-checkpoint',
                  error: error,
                  stackTrace: stackTrace,
                );
              }),
        );
      } catch (error, stackTrace) {
        DebugLogger.error(
          'pause-checkpoint-unavailable',
          scope: 'chat/pause-checkpoint',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }
}

Future<void> _refreshActiveConversationOnResume(Ref ref) async {
  String? conversationId;
  try {
    if (!ref.mounted) {
      return;
    }

    final active = ref.read(activeConversationProvider);
    if (active == null ||
        isTemporaryChat(active.id) ||
        isDirectLocalConversation(active) ||
        isNativeHermesConversation(active) ||
        ref.read(shouldProtectLocalStreamingStateProvider)) {
      return;
    }

    conversationId = active.id;
    final owner = captureOpenWebUiCompletionOwner(ref, chatId: conversationId);
    // Pull through the sync engine: persists via upsertServerChat under the
    // chat lock, then returns the assembled conversation (CDT-RFC-001
    // Phase 1). Falls back to a direct fetch when the engine is
    // inert/unavailable (no database, reviewer mode).
    final refreshed = await pullChatOrFetch(ref, conversationId);
    if (refreshed == null) {
      return;
    }
    if (!ref.mounted) {
      return;
    }
    if (activeOpenWebUiChatIdForMutation(ref, owner) != conversationId) {
      return;
    }

    final currentActive = ref.read(activeConversationProvider);
    if (currentActive == null ||
        currentActive.id != conversationId ||
        ref.read(shouldProtectLocalStreamingStateProvider)) {
      return;
    }

    ref.read(activeConversationProvider.notifier).set(refreshed);
    try {
      ref
          .read(conversationsProvider.notifier)
          .upsertConversation(
            refreshed.copyWith(messages: const []),
            trustFolderConversation:
                refreshed.folderId != null && refreshed.folderId!.isNotEmpty,
          );
    } catch (_) {}
  } catch (error, stackTrace) {
    DebugLogger.error(
      'resume-active-conversation-refresh-failed',
      scope: 'startup',
      error: error,
      stackTrace: stackTrace,
      data: {'conversationId': conversationId ?? '<unknown>'},
    );
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
