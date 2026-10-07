/// Switching between, adding and signing out of saved Open WebUI accounts.
///
/// [AuthStateManager] owns the session transitions themselves. This is the
/// layer a UI calls: it refuses to cut off a reply that is still being
/// written unless told to, picks which account takes over when the active
/// one is signed out of, and falls back to Hermes or Direct when no Open
/// WebUI account is left.
library;

import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        isChatStreamingProvider,
        localChatGenerationActiveProvider,
        stopGenerationProvider;
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

enum OpenWebUiAccountChangeResult {
  /// The change happened and the account now active is signed in.
  done,

  /// The change happened; the account now active needs a sign-in.
  needsSignIn,

  /// Nothing to do: the account was already active.
  alreadyActive,

  /// A reply is still being written. Ask, then call again with `force`.
  blockedByActiveReply,
}

/// Whether a reply is still being written that leaving the active account
/// would cut off. The host may widen it (background streams it tracks).
final accountChangeReplyGuardProvider = Provider<bool Function()>((ref) {
  return () {
    try {
      return ref.read(isChatStreamingProvider) ||
          ref.read(localChatGenerationActiveProvider);
    } catch (_) {
      return false;
    }
  };
});

/// Stops the replies [accountChangeReplyGuardProvider] reported, once the
/// user has agreed to leave the account anyway.
final accountChangeStopRepliesProvider = Provider<void Function()>((ref) {
  return () => ref.read(stopGenerationProvider)();
});

/// Called after the active Open WebUI account changed, with the new one (or
/// null). The host clears what the core cannot name: posted notifications,
/// home-screen widgets.
final hostActiveAccountChangedProvider = Provider<void Function(String?)>(
  (ref) => (_) {},
);

final openWebUiAccountsControllerProvider =
    Provider<OpenWebUiAccountsController>(OpenWebUiAccountsController.new);

final class OpenWebUiAccountsController {
  OpenWebUiAccountsController(this._ref);

  final Ref _ref;

  /// Makes [accountId] the active account.
  Future<OpenWebUiAccountChangeResult> switchTo(
    String accountId, {
    bool force = false,
  }) async {
    if (await _activeAccountId() == accountId) {
      return OpenWebUiAccountChangeResult.alreadyActive;
    }
    if (!_mayLeaveActiveAccount(force)) {
      return OpenWebUiAccountChangeResult.blockedByActiveReply;
    }
    final signedIn = await _ref
        .read(authStateManagerProvider.notifier)
        .switchToAccount(accountId);
    await _ref
        .read(openWebUiAccountSummariesProvider.notifier)
        .touch(accountId);
    _afterActiveAccountChanged(accountId);
    return signedIn
        ? OpenWebUiAccountChangeResult.done
        : OpenWebUiAccountChangeResult.needsSignIn;
  }

  /// Signs out of [accountId] and removes it, with its local data.
  ///
  /// When it is the active account the most recently used remaining one
  /// takes over, preferring one that is still signed in. With none left the
  /// app carries on with Hermes or Direct when either is usable, and goes
  /// back to choosing a backend otherwise.
  Future<OpenWebUiAccountChangeResult> signOut(
    String accountId, {
    bool force = false,
  }) async {
    final activeId = await _activeAccountId();
    final isActive = activeId == accountId;
    if (isActive && !_mayLeaveActiveAccount(force)) {
      return OpenWebUiAccountChangeResult.blockedByActiveReply;
    }
    final next = isActive ? await _nextAccountAfter(accountId) : null;
    final signedIn = await _ref
        .read(authStateManagerProvider.notifier)
        .signOutAccount(accountId, thenActivate: next);
    if (next != null) {
      await _ref.read(openWebUiAccountSummariesProvider.notifier).touch(next);
    }
    if (isActive) {
      if (next == null) await _fallBackWithoutOpenWebUi();
      _afterActiveAccountChanged(next);
    } else {
      _ref.invalidate(openWebUiAccountsProvider);
    }
    if (!isActive) return OpenWebUiAccountChangeResult.done;
    return signedIn
        ? OpenWebUiAccountChangeResult.done
        : OpenWebUiAccountChangeResult.needsSignIn;
  }

  /// Starts signing in to another account on the saved server [serverId].
  ///
  /// A new account is added with the server's current route and made active,
  /// signed out, so the sign-in screen opens for it. The account that was
  /// active stays signed in, in the vault. Returns the new account's id.
  Future<String?> beginAddAccount(String serverId, {bool force = false}) async {
    if (!_mayLeaveActiveAccount(force)) return null;
    final storage = _ref.read(optimizedStorageServiceProvider);
    final registry = await storage.getOpenWebUiRegistryStrict();
    final template = registry
        .accountsOn(serverId)
        .map((account) => registry.project(account.id))
        .whereType<ServerConfig>()
        .firstOrNull;
    if (template == null) return null;
    final accountId = const Uuid().v4();
    await _ref
        .read(authStateManagerProvider.notifier)
        .selectUnauthenticatedServerConfig(
          template.copyWith(
            id: accountId,
            isActive: true,
            lastConnected: null,
            customHeaders: {
              for (final entry in template.customHeaders.entries)
                if (!isCapturedSessionHeader(entry.key)) entry.key: entry.value,
            },
          ),
        );
    _afterActiveAccountChanged(accountId);
    return accountId;
  }

  Future<String?> _activeAccountId() =>
      _ref.read(optimizedStorageServiceProvider).getEffectiveActiveServerId();

  bool _mayLeaveActiveAccount(bool force) {
    if (force) {
      try {
        _ref.read(accountChangeStopRepliesProvider)();
      } catch (error, stackTrace) {
        DebugLogger.error(
          'account-change-stop-replies-failed',
          scope: 'auth/accounts',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return true;
    }
    return !_ref.read(accountChangeReplyGuardProvider)();
  }

  Future<String?> _nextAccountAfter(String accountId) async {
    final entries = await _ref.read(openWebUiAccountsProvider.future);
    final candidates = entries.where((entry) => entry.id != accountId).toList()
      ..sort((a, b) {
        if (a.hasSession != b.hasSession) return a.hasSession ? -1 : 1;
        final aUsed = a.summary.lastUsedAt;
        final bUsed = b.summary.lastUsedAt;
        if (aUsed == null || bUsed == null) {
          return (bUsed == null ? 0 : 1) - (aUsed == null ? 0 : 1);
        }
        return bUsed.compareTo(aUsed);
      });
    return candidates.firstOrNull?.id;
  }

  Future<void> _fallBackWithoutOpenWebUi() async {
    final preferred = _ref.read(preferredBackendProvider.notifier);
    if (_ref.read(hermesConfigProvider).isUsable) {
      await preferred.set(PreferredBackend.hermes);
      return;
    }
    // The synchronous view can still be loading with no value, which would
    // send a user who has usable Direct profiles back to backend selection.
    var hasUsableDirect = false;
    try {
      final direct = await _ref.read(
        effectiveDirectConnectionProfilesFutureProvider.future,
      );
      hasUsableDirect = direct.any((profile) => profile.isUsable);
    } catch (error) {
      DebugLogger.warning(
        'direct-profiles-unavailable',
        scope: 'auth/accounts',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    await preferred.set(
      hasUsableDirect ? PreferredBackend.direct : PreferredBackend.unset,
    );
  }

  void _afterActiveAccountChanged(String? accountId) {
    _ref.invalidate(openWebUiAccountsProvider);
    try {
      _ref.read(hostActiveAccountChangedProvider)(accountId);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'host-account-change-hook-failed',
        scope: 'auth/accounts',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

/// Folds a sign-in into the existing account of the same user.
///
/// Signing in on an added account as someone who already has an account on
/// that server would otherwise leave two accounts for one person, with the
/// local data in the older one. The host keeps this mounted for the life of
/// the app.
final openWebUiDuplicateAccountReconcilerProvider = Provider<void>((ref) {
  var reconciling = false;
  ref.listen<AsyncValue<AuthState>>(authStateManagerProvider, (
    previous,
    next,
  ) async {
    final auth = next.asData?.value;
    final user = auth?.user;
    if (reconciling || auth == null || !auth.isAuthenticated || user == null) {
      return;
    }
    final before = previous?.asData?.value;
    if (before != null &&
        before.isAuthenticated &&
        before.token == auth.token) {
      return;
    }
    // Read synchronously, at publication: the active account is then the one
    // this session belongs to. Anything read after an await may already be
    // the next account of a switch in progress.
    final sessionAccountId = PreferencesStore.getString(
      PreferenceKeys.activeServerId,
    );
    if (sessionAccountId == null || sessionAccountId.isEmpty) return;
    reconciling = true;
    try {
      final storage = ref.read(optimizedStorageServiceProvider);
      final registry = await storage.getOpenWebUiRegistryStrict();
      final active = registry.account(sessionAccountId);
      if (active == null) return;
      final existing = registry
          .accountsOn(active.serverId)
          .where(
            (account) => account.id != active.id && account.userId == user.id,
          )
          .firstOrNull;
      if (existing == null) return;
      final current = ref.read(authStateManagerProvider).asData?.value;
      if (current?.token != auth.token) return;
      DebugLogger.log('duplicate-account-merged', scope: 'auth/accounts');
      final merged = await ref
          .read(authStateManagerProvider.notifier)
          .mergeActiveAccountInto(
            existing.id,
            expectedSourceAccountId: sessionAccountId,
          );
      if (!merged) return;
      await ref
          .read(openWebUiAccountSummariesProvider.notifier)
          .touch(existing.id);
      ref.invalidate(openWebUiAccountsProvider);
      ref.read(hostActiveAccountChangedProvider)(existing.id);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'duplicate-account-merge-failed',
        scope: 'auth/accounts',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      reconciling = false;
    }
  });
});
