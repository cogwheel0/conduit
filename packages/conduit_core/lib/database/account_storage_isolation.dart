/// Keeps one account's local database out of another account's hands.
///
/// The on-disk schema is keyed by *server*, not by account, so two accounts
/// on the same server would otherwise share a database. Until an
/// account-scoped migration exists the rule is fail-closed: every terminal
/// auth transition deletes the active server database before another account
/// may open it, and `appDatabaseProvider` yields null until this notifier has
/// certified the current identity against an on-disk owner marker.
///
/// Extracted from the mobile app's startup flow. It is not startup
/// plumbing -- it decides whether there is a local database at all, which the
/// sidecar needs just as much: without it the daemon has no conversation
/// list, no offline history and no sync, because every one of those reads
/// `appDatabaseProvider`.
library;

import 'dart:async';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/openwebui_account_owner_marker.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:riverpod/riverpod.dart';

typedef _OpenWebUiAccountIdentity = ({String token, String? userId});

/// Whether [conversation] lives in the Open WebUI database.
///
/// Moved here from the mobile chat layer along with the isolation notifier
/// that is its only caller. Every symbol it needs -- the storage kind, the
/// direct transport marker, the Hermes test -- was already in the core, so it
/// travelled rather than becoming a seam.
bool conversationUsesOpenWebUiStorage(Conversation? conversation) {
  if (conversation == null) return false;
  final storage = chatStorageKindOf(conversation);
  if (storage == ChatStorageKind.openWebUi) return true;
  if (storage == ChatStorageKind.directLocal) return false;
  final backend = conversation.metadata['backend'];
  if (backend == kDirectTransport || isNativeHermesConversation(conversation)) {
    return false;
  }
  return true;
}

/// Clean-up a host performs when the signed-in account changes.
///
/// The core clears everything it owns -- conversations, folders, the active
/// conversation, the active-chat set. A host may have more: the mobile app
/// holds an in-flight message list in a notifier the core cannot name. Rather
/// than reach into it, the host registers a callback here.
final hostAccountBoundaryResetsProvider = Provider<List<void Function()>>(
  (ref) => const <void Function()>[],
);

/// Asks the host to catch up after a new account is certified.
///
/// Mobile routes this through `syncTriggers`, which also watches lifecycle
/// and connectivity; the sidecar calls the sync engine directly. Neither
/// belongs in here.
final hostPostCertificationSyncProvider = Provider<void Function()>(
  (ref) => () {},
);

typedef OpenWebUiAccountCacheClear = Future<void> Function();
typedef OpenWebUiCertifiedUserPersist = Future<void> Function(User user);
typedef OpenWebUiPostCertificationSyncKickoff = void Function();

final openWebUiPostCertificationSyncKickoffProvider =
    Provider<OpenWebUiPostCertificationSyncKickoff>((ref) {
      return () {
        try {
          ref.read(hostPostCertificationSyncProvider)();
        } catch (error, stackTrace) {
          DebugLogger.error(
            'post-certification-sync-kickoff-failed',
            scope: 'auth/storage-isolation',
            error: error,
            stackTrace: stackTrace,
          );
        }
      };
    });

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

  /// Completes when the current account-storage isolation operation settles.
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
    ref.read(openWebUiPostCertificationSyncKickoffProvider)();
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
        // Keep the notifier instance alive across the auth boundary. Its
        // active-conversation listener is installed once in build();
        // invalidating a listened Notifier rebuilds the same instance and
        // leaves that listener detached behind its initialization guard.
        for (final reset in ref.read(hostAccountBoundaryResetsProvider)) {
          reset();
        }
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
