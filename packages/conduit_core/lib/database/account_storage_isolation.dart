/// Keeps one account's local database out of another account's hands.
///
/// Each saved account has its own database, keyed by its account id (the id
/// its `ServerConfig` projection carries). `appDatabaseProvider` yields null
/// until this notifier has certified the current identity against that
/// account's on-disk owner marker, and the rule stays fail-closed: a database
/// whose marker names another user is deleted before anyone may open it.
///
/// What no longer happens is deleting a database just because its session
/// ended. Switching accounts, a token expiring or signing in again leaves the
/// database closed but intact, so the same user gets their offline history
/// and queued sends back; signing out of an account purges it explicitly
/// through [OpenWebUiAccountStorageIsolation.purgeAccount].
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
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
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

typedef OpenWebUiAccountUserBind =
    Future<void> Function(String accountId, String userId);

/// Records in the registry which user a certified account belongs to, so a
/// later sign-in as the same user on the same server can be recognized.
final openWebUiAccountUserBindProvider = Provider<OpenWebUiAccountUserBind>(
  (ref) => ref.watch(optimizedStorageServiceProvider).bindAccountUser,
);

typedef OpenWebUiSavedAccountIds = Future<Set<String>> Function();

/// The ids of the accounts storage keeps. Strict: a failed read throws.
final openWebUiSavedAccountIdsProvider = Provider<OpenWebUiSavedAccountIds>(
  (ref) => () async {
    final registry = await ref
        .read(optimizedStorageServiceProvider)
        .getOpenWebUiRegistryStrict();
    return {for (final account in registry.accounts) account.id};
  },
);

typedef OpenWebUiActiveAccountRecord = Future<void> Function(String accountId);

/// Keeps a certified account's id as the active one when storage counts it
/// active without one kept (see
/// [OptimizedStorageService.recordEffectiveActiveAccount]).
final openWebUiActiveAccountRecordProvider =
    Provider<OpenWebUiActiveAccountRecord>(
      (ref) =>
          ref.watch(optimizedStorageServiceProvider).recordEffectiveActiveAccount,
    );

typedef OpenWebUiAccountPrivateDataClear =
    Future<void> Function(String accountId);

/// Removes what an account keeps outside its database: its transport
/// options, feature flags and preferences scoped to it. Run when signing out
/// of that account, never while it is active.
final openWebUiAccountPrivateDataClearProvider =
    Provider<OpenWebUiAccountPrivateDataClear>(
      (ref) => (accountId) async {
        // Its summary goes through the notifier first: a summary written for
        // another account meanwhile saves the notifier's whole list, which
        // would otherwise still hold this one and bring it back.
        await ref
            .read(openWebUiAccountSummariesProvider.notifier)
            .forget(accountId);
        await clearOpenWebUiAccountPreferences(accountId);
      },
    );

/// Fail-closed ownership barrier for the account-scoped OpenWebUI databases.
///
/// A database opens only for the identity its owner marker names, or for the
/// same user with a token the server accepted in this process. Anything else
/// deletes it first. Direct-local storage is independent and remains visible
/// throughout.
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
    // Outside the build: it reads storage, and purges through this notifier.
    Future<void>.microtask(_resumePendingPurges);
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

  bool _ownerMarkerCarriesOver(
    String serverId,
    _OpenWebUiAccountIdentity identity,
  ) {
    try {
      return openWebUiAccountOwnerMarkerCarriesOver(
        marker: ref.read(openWebUiAccountOwnerMarkerStoreProvider).read(serverId),
        token: identity.token,
        userId: identity.userId,
        ledger: ref.read(openWebUiValidatedIdentityLedgerProvider),
      );
    } catch (_) {
      return false;
    }
  }

  String? _settledActiveServerId() {
    try {
      final id = ref.read(activeServerProvider).asData?.value?.id;
      return id == null || id.isEmpty ? null : id;
    } catch (_) {
      return null;
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
    _closeAtAccountBoundary(
      reason: departedCertifiedSession
          ? 'authenticated-session-ended'
          : 'terminal-unauthenticated',
    );
  }

  /// Announces that the active account is about to change.
  ///
  /// Call before the active id moves. The current account's database closes
  /// without being deleted, and the next identity to authenticate is judged
  /// against the *next* account's owner marker exactly as a cold start would
  /// judge it. Unannounced changes of the active server while a database is
  /// open still purge the target first; see [_onActiveServer].
  void beginAccountSwitch() {
    if (_disposed) return;
    if (_purgeRunning) {
      // A purge of the account being left may still be deleting its files.
      // Let it finish, but not decide anything about the next account: its
      // completion would otherwise read the new active id and purge that.
      _purgeGeneration++;
      _purgeRunning = false;
    }
    _closeAtAccountBoundary(reason: 'account-switch');
  }

  /// Closes the account database at an account boundary, keeping it on disk.
  void _closeAtAccountBoundary({required String reason}) {
    _certificationGeneration++;
    _initialAuthDecisionComplete = false;
    _certifiedIdentity = null;
    _pendingIdentity = null;
    _cleanServerId = null;
    // A purge still deleting files keeps them closed, and decides what comes
    // next when it finishes; reopening for bootstrap now would let a re-login
    // open the database it is deleting.
    _purgeRequired = _purgeRunning;
    final access = ref.read(openWebUiDatabaseAccessProvider.notifier);
    if (_purgeRunning) {
      access.beginPurge();
    } else {
      access.reenterBootstrap();
    }
    ref.read(openWebUiCertifiedDatabaseServerProvider.notifier).clear();
    _clearOpenWebUiVisibleState();
    ref.invalidate(appDatabaseProvider);
    ref.invalidate(chatDatabaseRepositoryProvider);
    DebugLogger.log(
      'account-database-closed',
      scope: 'auth/storage-isolation',
      data: {'reason': reason},
    );
  }

  /// Deletes [accountId]'s local data: its database, owner marker, Hermes
  /// session trust and account-scoped settings.
  ///
  /// For signing out of an account, after storage has removed it. Only
  /// [accountId]'s files are touched, never whichever account the providers
  /// currently name. If its database is still open, it is closed first and
  /// kept closed until its files are gone.
  Future<void> purgeAccount(String accountId) async {
    if (_disposed) return;
    final stillOpen =
        ref.read(openWebUiCertifiedDatabaseServerProvider) == accountId;
    if (stillOpen) {
      if (_purgeRunning) {
        // Whatever that purge was for, this account's files are going now;
        // its completion must not go on to certify or purge anything else.
        _purgeGeneration++;
        _purgeRunning = false;
      }
      _closeAtAccountBoundary(reason: 'account-signed-out');
      ref.read(openWebUiDatabaseAccessProvider.notifier).beginPurge();
    }
    final certificationGeneration = _certificationGeneration;
    // Recorded first: the account is already gone from the list the user
    // could sign out of it again from, so a step that fails is left for the
    // next start. Each step is tried even when one before it fails.
    await _recordPendingPurge(accountId);
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> attempt(Future<void> Function() step) async {
      try {
        await step();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    try {
      await attempt(() async {
        final ownerMarker = ref
            .read(openWebUiAccountOwnerMarkerStoreProvider)
            .read(accountId);
        final ownerUserId = ownerMarker?.userId.trim();
        if (ownerMarker != null &&
            ownerUserId != null &&
            ownerUserId.isNotEmpty) {
          await HermesMixedSessionBindingTrustStore.forgetStorageAccount(
            HermesMixedSessionBindingTrustStore.durableStorageAccountIdentity(
              serverId: accountId,
              userId: ownerUserId,
              tokenFingerprint: ownerMarker.tokenFingerprint,
            ),
          );
        }
      });
      await attempt(() => ref.read(openWebUiDatabasePurgeProvider)(accountId));
      await attempt(() => _removeOwnerMarker(accountId));
      await attempt(
        () => ref.read(openWebUiAccountPrivateDataClearProvider)(accountId),
      );
      if (firstError != null) {
        Error.throwWithStackTrace(firstError!, firstStackTrace!);
      }
      await _forgetPendingPurge(accountId);
      DebugLogger.log(
        'account-database-purged',
        scope: 'auth/storage-isolation',
      );
    } finally {
      // Back to judging the next identity as a cold start would, unless a
      // boundary or another account's certification has decided since.
      if (stillOpen &&
          !_disposed &&
          _certificationGeneration == certificationGeneration &&
          ref.read(openWebUiDatabaseAccessProvider) ==
              OpenWebUiDatabaseAccessPhase.purging) {
        ref.read(openWebUiDatabaseAccessProvider.notifier).reenterBootstrap();
      }
    }
  }

  /// Finishes the purges an earlier run recorded and did not finish, of
  /// accounts storage no longer keeps. One still kept was never removed, and
  /// keeps its data.
  Future<void> _resumePendingPurges() async {
    if (_disposed || !PreferencesStore.isReady) return;
    final pending = PreferencesStore.getStringList(
      PreferenceKeys.pendingAccountPurges,
    );
    if (pending == null || pending.isEmpty) return;
    try {
      final saved = await ref.read(openWebUiSavedAccountIdsProvider)();
      for (final accountId in pending) {
        if (_disposed) return;
        if (saved.contains(accountId)) {
          await _forgetPendingPurge(accountId);
        } else {
          await purgeAccount(accountId);
        }
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'pending-account-purge-failed',
        scope: 'auth/storage-isolation',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _recordPendingPurge(String accountId) async {
    try {
      final pending =
          PreferencesStore.getStringList(PreferenceKeys.pendingAccountPurges) ??
          const <String>[];
      if (pending.contains(accountId)) return;
      await PreferencesStore.putChecked(PreferenceKeys.pendingAccountPurges, [
        ...pending,
        accountId,
      ]);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'pending-account-purge-record-failed',
        scope: 'auth/storage-isolation',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _forgetPendingPurge(String accountId) async {
    try {
      final pending = PreferencesStore.getStringList(
        PreferenceKeys.pendingAccountPurges,
      );
      if (pending == null || !pending.contains(accountId)) return;
      final rest = [...pending]..remove(accountId);
      await PreferencesStore.putChecked(
        PreferenceKeys.pendingAccountPurges,
        rest.isEmpty ? null : rest,
      );
    } catch (error, stackTrace) {
      // Finished already: a later start purges a gone account once more.
      DebugLogger.error(
        'pending-account-purge-forget-failed',
        scope: 'auth/storage-isolation',
        error: error,
        stackTrace: stackTrace,
      );
    }
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
      // first, or still be re-resolving after an account switch. Defer the
      // decision; the server listener re-enters this exact marker-validation
      // branch once the identity is addressable by a settled selection.
      final settledServerId = _settledActiveServerId();
      if (serverId == null || settledServerId == null) return;
      _initialAuthDecisionComplete = true;
      if (_ownerMarkerMatches(settledServerId, identity)) {
        // The marker is independent of the account database and was flushed
        // before that database was opened by the previous process.
        _scheduleCertification(markerAlreadyDurable: true);
      } else if (_ownerMarkerCarriesOver(settledServerId, identity)) {
        // Same user, with a token the server accepted in this process: a
        // re-login after expiry, or a sign-in that landed in this account.
        // The database is theirs; certification rewrites the marker for the
        // new token before opening it.
        _scheduleCertification();
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

    if (!_purgeRunning && !_purgeRequired) {
      // Another identity arrived without the boundary being announced: a
      // sign-in that added an account, or one that changed who holds this
      // one. Treat it as the boundary it is -- close what was open, keeping
      // it -- and judge the new identity by its own account's marker, which
      // deletes that account's database only if it belongs to someone else.
      _closeAtAccountBoundary(reason: 'account-session-change');
      _onAuthenticated(identity);
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

  /// The account whose database is in question: the settled selection, else
  /// what storage durably selected. The API client comes last because, while
  /// the selection re-resolves, it is rebuilt from the *previous* server --
  /// and the account just left must never be mistaken for the one to purge.
  String? _currentServerId() {
    try {
      final active = ref.read(activeServerProvider).asData?.value?.id;
      if (active != null && active.isNotEmpty) return active;
    } catch (_) {}
    final stored = PreferencesStore.getString(PreferenceKeys.activeServerId);
    if (stored != null && stored.isNotEmpty) return stored;
    try {
      final apiId = ref.read(apiServiceProvider)?.serverConfig.id;
      if (apiId != null && apiId.isNotEmpty) return apiId;
    } catch (_) {}
    return null;
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
        // The cache clear acts on whichever account is active when it runs,
        // not on [serverId]. A switch since this purge began made another
        // account active; clearing now would empty that account's cache. The
        // database and marker below are this account's and still go.
        if (generation == _purgeGeneration) {
          await ref.read(openWebUiAccountCacheClearProvider)();
        }
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
    final certifiedUserId = identity.userId;
    if (certifiedUserId != null) {
      unawaited(_bindAccountUser(serverId, certifiedUserId));
    }
    final authenticated = ref.read(authStateManagerProvider).asData?.value;
    final certifiedUser = authenticated?.user;
    if (certifiedUser != null &&
        authenticated?.token == identity.token &&
        certifiedUser.id == identity.userId) {
      // Recorded here, where the account and its user are known to belong
      // together, rather than from a later read of whichever is active.
      // Neither is awaited, so a failure is caught on its own future (a
      // sign-out under way refuses preference writes, for one) as well as
      // when it is thrown synchronously.
      void logSummaryFailure(Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'certified-account-summary-failed',
          scope: 'auth/storage-isolation',
          error: error,
          stackTrace: stackTrace,
        );
      }

      try {
        unawaited(
          ref
              .read(openWebUiAccountSummariesProvider.notifier)
              .recordUser(serverId, certifiedUser)
              .catchError(logSummaryFailure),
        );
        // The account's id is kept first: its settings are read under it
        // from now on, the copy they start from included.
        Future<void> recordActive() async {
          try {
            await ref.read(openWebUiActiveAccountRecordProvider)(serverId);
          } catch (error, stackTrace) {
            logSummaryFailure(error, stackTrace);
          }
        }

        unawaited(
          recordActive()
              .then((_) => migrateDeviceSettingsIntoAccount(serverId))
              .catchError(logSummaryFailure),
        );
      } catch (error, stackTrace) {
        logSummaryFailure(error, stackTrace);
      }
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

  Future<void> _bindAccountUser(String accountId, String userId) async {
    try {
      await ref.read(openWebUiAccountUserBindProvider)(accountId, userId);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'account-user-bind-failed',
        scope: 'auth/storage-isolation',
        error: error,
        stackTrace: stackTrace,
      );
    }
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
