/// Switching between, adding and signing out of saved Open WebUI accounts.
///
/// [AuthStateManager] owns the session transitions themselves. This is the
/// layer a UI calls: it refuses to cut off a reply that is still being
/// written unless told to, picks which account takes over when the active
/// one is signed out of, and falls back to Hermes or Direct when no Open
/// WebUI account is left.
library;

import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        isChatStreamingProvider,
        localChatGenerationActiveProvider,
        stopGenerationProvider;
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
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

/// The account that was active when adding another one began, while that
/// flow is open; null otherwise.
///
/// Adding an account runs through sign-in screens the router normally keeps
/// a signed-in user away from. While the account named here is still the
/// active one, the router leaves the flow alone; once the new account is
/// active, ordinary routing takes over and lands it in chat.
final accountAdditionOriginProvider =
    NotifierProvider<AccountAdditionOrigin, String?>(AccountAdditionOrigin.new);

class AccountAdditionOrigin extends Notifier<String?> {
  /// How many additions have begun, so one that began later is told apart
  /// from the one before it.
  int _begun = 0;

  @override
  String? build() => null;

  void begin(String? activeAccountId) {
    _begun++;
    state = activeAccountId;
  }

  /// Ends the flow begun from [activeAccountId], unless another has begun.
  void end(String? activeAccountId) {
    if (state == activeAccountId) state = null;
  }

  /// Whether the addition in progress now still is, for work it started:
  /// false once it ends, and still false if another begins after it.
  bool Function() stillInProgress() {
    final begun = _begun;
    return () => ref.mounted && _begun == begun && state != null;
  }
}

/// Whether the active account is a sign-in started for an added account that
/// can be left: an addition is in progress, the account never signed in, and
/// another account is still signed in to go back to. Sign-in screens offer
/// Cancel instead of Back then. Never signed in is not enough on its own: an
/// account carried over from before accounts existed may not know its user.
final pendingSignInAbandonableProvider = FutureProvider<bool>((ref) async {
  if (ref.watch(accountAdditionOriginProvider) == null) return false;
  final entries = await ref.watch(openWebUiAccountsProvider.future);
  final active = entries.where((entry) => entry.isActive).firstOrNull;
  if (active == null || active.account.userId != null || active.hasSession) {
    return false;
  }
  return entries.any((entry) => !entry.isActive && entry.hasSession);
});

final openWebUiAccountsControllerProvider =
    Provider<OpenWebUiAccountsController>(OpenWebUiAccountsController.new);

class OpenWebUiAccountsController {
  OpenWebUiAccountsController(this._ref);

  final Ref _ref;

  /// The account change last started. Each starts once the one before it
  /// has finished: a switch landing while a sign-out waits on its server
  /// would leave the sign-out acting on an active account it read before.
  Future<void> _lastChange = Future<void>.value();

  Future<T> _afterLastChange<T>(Future<T> Function() change) {
    final result = _lastChange.then((_) => change());
    _lastChange = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  /// Makes [accountId] the active account.
  Future<OpenWebUiAccountChangeResult> switchTo(
    String accountId, {
    bool force = false,
  }) => _afterLastChange(() => _switchTo(accountId, force: force));

  Future<OpenWebUiAccountChangeResult> _switchTo(
    String accountId, {
    required bool force,
  }) async {
    if (await _activeAccountId() == accountId) {
      // Signed out, it goes to auth, which takes up a session it still has.
      final auth = _ref.read(authStateManagerProvider).asData?.value;
      if (auth == null || auth.isAuthenticated) {
        return OpenWebUiAccountChangeResult.alreadyActive;
      }
      final signedIn = await _ref
          .read(authStateManagerProvider.notifier)
          .switchToAccount(accountId);
      // Its session may have been taken up: the list shows it signed in.
      _ref.invalidate(openWebUiAccountsProvider);
      return signedIn
          ? OpenWebUiAccountChangeResult.done
          : OpenWebUiAccountChangeResult.needsSignIn;
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
  }) => _afterLastChange(() => _signOut(accountId, force: force));

  Future<OpenWebUiAccountChangeResult> _signOut(
    String accountId, {
    required bool force,
  }) async {
    final activeId = await _activeAccountId();
    final isActive = activeId == accountId;
    if (isActive && !_mayLeaveActiveAccount(force)) {
      return OpenWebUiAccountChangeResult.blockedByActiveReply;
    }
    // Picked even for an account that is not active: a sign-in can make it
    // active while its server is asked to end the session, and it is then
    // signed out of as the active account. For one that is not, picking is
    // best effort: removing it needs no other account's session.
    String? next;
    try {
      next = await _nextAccountAfter(accountId);
    } catch (error) {
      if (isActive) rethrow;
      DebugLogger.warning(
        'next-account-read-failed',
        scope: 'auth/accounts',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    final signedIn = await _ref
        .read(authStateManagerProvider.notifier)
        .signOutAccount(accountId, thenActivate: next);
    // Read again: the sign-out waited on the server, and what is active now
    // is what it left, or what a sign-in made active meanwhile.
    final String? now;
    try {
      now = await _activeAccountId();
    } catch (error, stackTrace) {
      // The sign-out is done; with the account now in use unknown, nothing
      // else changes on its behalf, the backend least of all.
      DebugLogger.error(
        'active-account-read-failed',
        scope: 'auth/accounts',
        error: error,
        stackTrace: stackTrace,
      );
      _ref.invalidate(openWebUiAccountsProvider);
      return signedIn
          ? OpenWebUiAccountChangeResult.done
          : OpenWebUiAccountChangeResult.needsSignIn;
    }
    if (now == activeId) {
      _ref.invalidate(openWebUiAccountsProvider);
      return OpenWebUiAccountChangeResult.done;
    }
    if (now == null) {
      await _fallBackWithoutOpenWebUi();
      _afterActiveAccountChanged(null);
    } else if (now == next) {
      await _ref.read(openWebUiAccountSummariesProvider.notifier).touch(next!);
      _afterActiveAccountChanged(next);
    } else {
      // Another account became active on its own; it is left alone.
      _ref.invalidate(openWebUiAccountsProvider);
    }
    return signedIn
        ? OpenWebUiAccountChangeResult.done
        : OpenWebUiAccountChangeResult.needsSignIn;
  }

  /// Leaves a sign-in started for an added account without finishing it.
  ///
  /// Only an account that never signed in -- no proven user, no session --
  /// is dropped, and only when another account can take over: the most
  /// recently used one that is still signed in. Returns whether it did.
  Future<bool> abandonPendingSignIn() =>
      _afterLastChange(_abandonPendingSignIn);

  Future<bool> _abandonPendingSignIn() async {
    // Only an addition's own sign-in is left: an account carried over from
    // before accounts existed can look the same, and leaving it would delete
    // its data.
    if (_ref.read(accountAdditionOriginProvider) == null) return false;
    // The cached list can trail a sign-in that just finished; auth cannot.
    if (_signedIn()) return false;
    final activeId = await _activeAccountId();
    if (activeId == null) return false;
    final entries = await _ref.read(openWebUiAccountsProvider.future);
    final active = entries.where((entry) => entry.id == activeId).firstOrNull;
    if (active == null || active.account.userId != null || active.hasSession) {
      return false;
    }
    final next = await _nextAccountAfter(activeId);
    if (next == null ||
        !entries.any((entry) => entry.id == next && entry.hasSession)) {
      return false;
    }
    // The sign-in can finish while the next account is chosen. Checked last,
    // with nothing awaited between this and the sign-out starting: an
    // account that signed in is never abandoned.
    if (await _activeAccountId() != activeId || _signedIn()) return false;
    await _ref
        .read(authStateManagerProvider.notifier)
        .signOutAccount(activeId, thenActivate: next);
    // Read again, as a sign-out does: a sign-in can make another account
    // active while the server is asked, and that one is left alone.
    if (await _activeAccountId() == next) {
      await _ref.read(openWebUiAccountSummariesProvider.notifier).touch(next);
      _afterActiveAccountChanged(next);
    } else {
      _ref.invalidate(openWebUiAccountsProvider);
    }
    return true;
  }

  bool _signedIn() =>
      _ref.read(authStateManagerProvider).asData?.value.isAuthenticated ??
      false;

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
    var fallback = PreferredBackend.hermes;
    if (!_ref.read(hermesConfigProvider).isUsable) {
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
      fallback = hasUsableDirect
          ? PreferredBackend.direct
          : PreferredBackend.unset;
    }
    // A sign-in can have made an account active while this waited; the app
    // stays on Open WebUI then, and when that cannot be read.
    try {
      if (await _activeAccountId() != null) return;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'active-account-read-failed',
        scope: 'auth/accounts',
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }
    await _ref.read(preferredBackendProvider.notifier).set(fallback);
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
  // A sign-in published while another was being reconciled. Checked once
  // that one is done: it would otherwise stay a duplicate for good.
  ({AuthState auth, String sessionAccountId})? deferred;
  // The sign-in being reconciled, and the last one whose merge failed. A
  // failed merge puts the session back, publishing it again; taken for a
  // new sign-in, it would be merged again, and fail again, without end.
  String? current;
  String? failed;
  String key(AuthState auth, String sessionAccountId) =>
      '$sessionAccountId\u0000${auth.token}';

  Future<void> reconcile(AuthState auth, String sessionAccountId) async {
    final user = auth.user!;
    final attempt = key(auth, sessionAccountId);
    var done = false;
    reconciling = true;
    current = attempt;
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
            expectedToken: auth.token,
          );
      if (!merged) {
        failed = attempt;
        return;
      }
      done = true;
      // An addition signed in as the user of the account it began from lands
      // back in that account. The sign-in is done, but with that account
      // active again the router took the addition for still running and
      // kept the finished sign-in on screen.
      ref.read(accountAdditionOriginProvider.notifier).end(existing.id);
      await ref
          .read(openWebUiAccountSummariesProvider.notifier)
          .touch(existing.id);
      ref.invalidate(openWebUiAccountsProvider);
      ref.read(hostActiveAccountChangedProvider)(existing.id);
    } catch (error, stackTrace) {
      failed = attempt;
      DebugLogger.error(
        'duplicate-account-merge-failed',
        scope: 'auth/accounts',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (done) failed = null;
      current = null;
      reconciling = false;
      final next = deferred;
      deferred = null;
      if (next != null && ref.mounted) {
        unawaited(reconcile(next.auth, next.sessionAccountId));
      }
    }
  }

  ref.listen<AsyncValue<AuthState>>(authStateManagerProvider, (
    previous,
    next,
  ) {
    final auth = next.asData?.value;
    if (auth == null || !auth.isAuthenticated || auth.user == null) return;
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
    final published = key(auth, sessionAccountId);
    if (published == current || published == failed) return;
    if (reconciling) {
      deferred = (auth: auth, sessionAccountId: sessionAccountId);
      return;
    }
    unawaited(reconcile(auth, sessionAccountId));
  });
});
