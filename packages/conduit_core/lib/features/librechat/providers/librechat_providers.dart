import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:synchronized/synchronized.dart';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_manager.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_server_info.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_registry_store.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_stream_client.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Preference that turns the LibreChat backend off (or back on).
const String kLibreChatBackendEnabledPreference = 'librechat_backend_enabled_v1';

/// Whether LibreChat can be added and used. On, labelled Beta while it is
/// new; [kLibreChatBackendEnabledPreference] set to false turns it off.
final libreChatBackendEnabledProvider = Provider<bool>(
  (ref) => PreferencesStore.getBool(kLibreChatBackendEnabledPreference) ?? true,
);

/// The HTTP adapter LibreChat clients use; null for the platform's own.
/// Tests put a fake server here.
final libreChatHttpAdapterProvider = Provider<HttpClientAdapter?>(
  (ref) => null,
);

final libreChatRegistryStoreProvider = Provider<LibreChatRegistryStore>(
  (ref) => LibreChatRegistryStore(ref.watch(secureStorageProvider)),
);

/// The saved LibreChat accounts.
final libreChatRegistryProvider =
    AsyncNotifierProvider<LibreChatRegistryController, LibreChatRegistry>(
      LibreChatRegistryController.new,
    );

class LibreChatRegistryController extends AsyncNotifier<LibreChatRegistry> {
  LibreChatRegistryStore get _store => ref.read(libreChatRegistryStoreProvider);

  /// A full sign-out is clearing the accounts; see [blockForAppDataClear].
  bool _appDataClearBlocked = false;

  bool get isBlockedForAppDataClear => _appDataClearBlocked;

  @override
  Future<LibreChatRegistry> build() {
    final store = ref.watch(libreChatRegistryStoreProvider);
    if (_appDataClearBlocked) return Future.value(const LibreChatRegistry());
    if (PreferencesStore.getBool(PreferenceKeys.libreChatClearPending) ??
        false) {
      return _finishInterruptedClear(store);
    }
    return store.read();
  }

  /// A full sign-out could not forget the accounts: none of what it left
  /// opens, and it is forgotten again now. Failing that, the next start
  /// tries again.
  Future<LibreChatRegistry> _finishInterruptedClear(
    LibreChatRegistryStore store,
  ) async {
    try {
      await store.deleteAll();
    } catch (error) {
      DebugLogger.warning(
        'clear-retry-failed',
        scope: 'librechat/registry',
        data: {'error': error.runtimeType.toString()},
      );
      // What is left must not come back through a new account's save,
      // which adds to the stored registry: no account changes until a later
      // start has cleared it.
      _appDataClearBlocked = true;
      return const LibreChatRegistry();
    }
    try {
      await PreferencesStore.putChecked(
        PreferenceKeys.libreChatClearPending,
        null,
      );
    } catch (error) {
      DebugLogger.warning(
        'clear-pending-unmark-failed',
        scope: 'librechat/registry',
        data: {'error': error.runtimeType.toString()},
      );
      // The next start clears the store again, so an account added now
      // would be lost then: none is, until a start gets this far.
      _appDataClearBlocked = true;
    }
    return const LibreChatRegistry();
  }

  Future<LibreChatRegistry> _update(
    LibreChatRegistry Function(LibreChatRegistry current) change,
  ) async {
    if (_appDataClearBlocked) {
      throw StateError('LibreChat accounts are being cleared.');
    }
    final next = await _store.update(change);
    if (!_appDataClearBlocked) state = AsyncData(next);
    return next;
  }

  /// Before a full sign-out clears storage: no account is in use, so no
  /// session keeps serving requests or renews into the storage being
  /// cleared, and no change is saved, until [finishAppDataClear] or
  /// [resumeAfterAppDataClearAbort]. Waits for a change already saving.
  Future<void> blockForAppDataClear() async {
    _appDataClearBlocked = true;
    state = const AsyncData(LibreChatRegistry());
    await Future.wait<Object?>([_store.read(), _store.blockSessionWrites()]);
  }

  /// The clear did not happen: the accounts come back from storage.
  void resumeAfterAppDataClearAbort() {
    if (!_appDataClearBlocked) return;
    _appDataClearBlocked = false;
    _store.allowSessionWrites();
    ref.invalidateSelf();
  }

  /// The accounts were forgotten: new ones may be added again.
  void finishAppDataClear() => resumeAfterAppDataClearAbort();

  /// Saves [account], replacing the one with its id, and makes it the
  /// LibreChat account in use when [activate].
  Future<void> save(LibreChatAccount account, {bool activate = false}) =>
      _update((current) => current.upsert(account, activate: activate));

  /// Makes [accountId] the LibreChat account in use. Taking up another
  /// account counts as using it: a sign-out of the account in charge hands
  /// the Chats tab to the one used last.
  Future<void> setActive(String? accountId) => _update((current) {
    final account = accountId == null || accountId == current.activeId
        ? null
        : current.byId(accountId);
    if (account == null) return current.withActive(accountId);
    return current.upsert(
      account.copyWith(lastUsedAt: DateTime.now().toUtc()),
      activate: true,
    );
  });

  Future<void> remove(String accountId) =>
      _update((current) => current.remove(accountId));

  /// Forgets every LibreChat account and session.
  Future<void> clear() async {
    await _store.deleteAll();
    state = const AsyncData(LibreChatRegistry());
  }
}

/// Records that a full sign-out could not forget the LibreChat accounts, so
/// the next start does before any opens. Written past the clear's write
/// barrier; best effort, as the sign-out has nothing left to undo.
Future<void> markLibreChatClearPending() async {
  try {
    await PreferencesStore.putChecked(
      PreferenceKeys.libreChatClearPending,
      true,
      bypassAppDataClearBarrier: true,
    );
  } catch (error) {
    DebugLogger.warning(
      'clear-pending-record-failed',
      scope: 'librechat/registry',
      data: {'error': error.runtimeType.toString()},
    );
  }
}

/// The LibreChat account in use, whether or not LibreChat is primary.
final activeLibreChatAccountProvider = Provider<LibreChatAccount?>(
  (ref) => ref.watch(libreChatRegistryProvider).asData?.value.active,
);

/// Where the active LibreChat account's session stands.
sealed class LibreChatSessionState {
  const LibreChatSessionState();
}

/// No LibreChat account is in use.
final class LibreChatNoAccount extends LibreChatSessionState {
  const LibreChatNoAccount();
}

/// [account] is signed in; requests go through [handle].
final class LibreChatSignedInState extends LibreChatSessionState {
  const LibreChatSignedInState(this.account, this.handle);

  final LibreChatAccount account;
  final LibreChatSessionHandle handle;
}

/// [account]'s session ended (expired, revoked, or never saved): it needs
/// signing in again. Its local history stays.
final class LibreChatNeedsSignIn extends LibreChatSessionState {
  const LibreChatNeedsSignIn(this.account);

  final LibreChatAccount account;
}

/// The session of the active LibreChat account.
final libreChatSessionProvider =
    AsyncNotifierProvider<LibreChatSessionController, LibreChatSessionState>(
      LibreChatSessionController.new,
    );

class LibreChatSessionController extends AsyncNotifier<LibreChatSessionState> {
  @override
  Future<LibreChatSessionState> build() async {
    final account = ref.watch(activeLibreChatAccountProvider);
    if (account == null) {
      // A registry still loading has not said there is no account. Read as
      // none, a slow start would send a returning user to set up or sign
      // in before their saved session had loaded.
      final registry = await ref.watch(libreChatRegistryProvider.future);
      if (registry.active == null) return const LibreChatNoAccount();
      // The account it names reaches the watch above, which builds this
      // again with it; until then the session stays loading.
      return Completer<LibreChatSessionState>().future;
    }
    final store = ref.read(libreChatRegistryStoreProvider).sessionStore(
      account.id,
    );
    final saved = await store.read();
    if (saved == null) return LibreChatNeedsSignIn(account);
    if (saved.user.id != account.userId) {
      // A session that belongs to someone else never opens this account.
      DebugLogger.warning('session-user-mismatch', scope: 'librechat/session');
      await store.clear();
      return LibreChatNeedsSignIn(account);
    }
    final auth = LibreChatAuthService(
      account.server,
      adapter: ref.read(libreChatHttpAdapterProvider),
    );
    final handle = LibreChatSessionHandle(
      session: saved,
      store: store,
      renew: auth.renew,
    );
    final ended = handle.changes.where((session) => session == null).listen((
      _,
    ) {
      if (ref.mounted) state = AsyncData(LibreChatNeedsSignIn(account));
    });
    ref.onDispose(() {
      unawaited(ended.cancel());
      unawaited(handle.dispose());
      auth.close();
    });
    return LibreChatSignedInState(account, handle);
  }
}

/// The signed-in session handle, or null when LibreChat is not signed in.
final libreChatSessionHandleProvider = Provider<LibreChatSessionHandle?>((
  ref,
) {
  final state = ref.watch(libreChatSessionProvider).asData?.value;
  return state is LibreChatSignedInState ? state.handle : null;
});

/// The HTTP client of the signed-in LibreChat account.
final libreChatHttpClientProvider = Provider<LibreChatHttpClient?>((ref) {
  final state = ref.watch(libreChatSessionProvider).asData?.value;
  if (state is! LibreChatSignedInState) return null;
  final client = LibreChatHttpClient(
    server: state.account.server,
    session: state.handle,
    adapter: ref.watch(libreChatHttpAdapterProvider),
  );
  ref.onDispose(client.close);
  return client;
});

final libreChatApiServiceProvider = Provider<LibreChatApiService?>((ref) {
  final client = ref.watch(libreChatHttpClientProvider);
  return client == null ? null : LibreChatApiService(client);
});

final libreChatStreamClientProvider = Provider<LibreChatStreamClient?>((ref) {
  final client = ref.watch(libreChatHttpClientProvider);
  return client == null ? null : LibreChatStreamClient(client);
});

/// What the signed-in user may do on their LibreChat server.
final libreChatCapabilitiesProvider = FutureProvider<LibreChatCapabilities>((
  ref,
) async {
  final api = ref.watch(libreChatApiServiceProvider);
  final state = ref.watch(libreChatSessionProvider).asData?.value;
  if (api == null || state is! LibreChatSignedInState) {
    return LibreChatCapabilities.minimal;
  }
  final sessionRole = state.handle.current?.user.role;
  final role = sessionRole ?? state.account.role ?? 'USER';
  // A renewal can bring another role, and with it other permissions.
  final roleChanges = state.handle.changes
      .where((session) => session != null && session.user.role != sessionRole)
      .listen((_) => ref.invalidateSelf());
  ref.onDispose(roleChanges.cancel);
  // A role that cannot be read fails the lot, to be asked again, rather than
  // reading as one that grants everything.
  final results = await Future.wait<Object?>([
    api.startupConfig(),
    api.rolePermissions(role),
    api.endpoints(),
    api.searchEnabled().catchError((Object _) => false),
  ]);
  return LibreChatCapabilities.from(
    startupConfig: results[0]! as Map<String, dynamic>,
    permissions: results[1]! as Map<String, dynamic>,
    endpoints: results[2]! as Map<String, dynamic>,
    serverSearch: results[3]! as bool,
  );
});

/// The file a LibreChat account's local database lives in:
/// `librechat_<base64url of the account id>`, apart from the `server_*`
/// files Open WebUI accounts use, so neither side's sweeps touch the other.
String libreChatDatabaseFileName(String accountId) =>
    'librechat_${base64Url.encode(utf8.encode(accountId)).replaceAll('=', '')}';

/// A [libreChatDatabaseFileName] file or one of its SQLite siblings.
final RegExp _libreChatDatabaseFile = RegExp(
  r'^(librechat_[A-Za-z0-9_-]+)\.sqlite(-journal|-wal|-shm)?$',
);

/// The LibreChat database files a sign-out could not delete, which stay
/// closed until they are; see [DatabaseManager.recordPendingWipe].
const String kLibreChatPendingDatabaseWipePreference =
    'librechat_pending_database_wipe_v1';

/// Owns the LibreChat account databases. Separate from Open WebUI's manager,
/// which keeps one database open at a time and would close a LibreChat one
/// whenever an Open WebUI provider opened its own.
final libreChatDatabaseManagerProvider = Provider<DatabaseManager>((ref) {
  final manager = DatabaseManager(
    opener: () => ref.read(databaseOpenerProvider),
    databaseFileName: libreChatDatabaseFileName,
    databaseFilePattern: _libreChatDatabaseFile,
    pendingWipeKey: kLibreChatPendingDatabaseWipePreference,
  );
  // Every LibreChat database opens through this manager, so starting here
  // finishes deleting what an earlier sign-out left before any of them can.
  if (PreferencesStore.containsKey(kLibreChatPendingDatabaseWipePreference)) {
    manager.resumePendingWipe();
    unawaited(
      manager.finishPendingWipe().catchError((Object error) {
        // The record stays, so the next start tries again.
        DebugLogger.warning(
          'pending-wipe-failed',
          scope: 'librechat/accounts',
          data: {'error': error.runtimeType.toString()},
        );
      }),
    );
  }
  ref.onDispose(() => unawaited(manager.closeActive()));
  return manager;
});

/// The signed-in LibreChat account's local database, or null.
///
/// An account id is derived from its server and user, so an account's file
/// can only ever hold that user's chats; the session's user was checked
/// against the account before it was signed in.
///
/// Switching A -> B -> A quickly can ask for A while its first connection is
/// still closing; it is null until that has finished, then opens.
final libreChatDatabaseProvider = Provider<AppDatabase?>((ref) {
  final state = ref.watch(libreChatSessionProvider).asData?.value;
  if (state is! LibreChatSignedInState) return null;
  final manager = ref.watch(libreChatDatabaseManagerProvider);
  switch (manager.openForServerIdIfReady(state.account.id)) {
    case DatabaseOpenReady(:final database):
      return database;
    case DatabaseOpenDeferred(:final retryAfter):
      void retry() {
        if (ref.mounted) ref.invalidateSelf();
      }
      unawaited(
        retryAfter.then<void>(
          (_) => retry(),
          onError: (Object _, StackTrace _) => retry(),
        ),
      );
      return null;
  }
});

/// Adds, signs out of and forgets LibreChat accounts.
final libreChatAccountsProvider = Provider<LibreChatAccounts>(
  LibreChatAccounts.new,
);

final class LibreChatAccounts {
  LibreChatAccounts(this._ref);

  final Ref _ref;

  /// The sign-ins saved for each account in this run. A sign-out that waits
  /// on the server compares these rather than the stored session, which a
  /// renewal rotates without signing anyone in.
  final Map<String, int> _signIns = {};

  /// A sign-in's save and a sign-out's local forgetting run one at a time,
  /// so a sign-in that lands while a sign-out forgets the account is either
  /// before it (and the sign-out stands down) or after it (and saves the
  /// account anew) -- never undone halfway.
  final Lock _accountChanges = Lock();

  LibreChatRegistryStore get _store => _ref.read(libreChatRegistryStoreProvider);

  /// Saves the account [session] signed in to on [server] with its session,
  /// and makes it the LibreChat account in use when [activate]. Sign-in
  /// screens save without activating and switch through
  /// `PrimaryAccountSwitcher`, which asks before stopping a reply.
  Future<LibreChatAccount> saveSignedIn({
    required LibreChatServer server,
    required LibreChatSession session,
    LibreChatServerInfo? info,
    bool activate = true,
  }) async {
    final registryController = _ref.read(libreChatRegistryProvider.notifier);
    if (registryController.isBlockedForAppDataClear) {
      throw StateError('LibreChat accounts are being cleared.');
    }
    final store = _store;
    final clears = store.clears;
    final registry = await _ref.read(libreChatRegistryProvider.future);
    final id = LibreChatAccount.idFor(server.baseUrl, session.user.id);
    final existing = registry.byId(id);
    final account =
        (existing?.copyWith(server: server).withUser(session.user) ??
                LibreChatAccount.forUser(server, session.user))
            .copyWith(
              serverTitle: info?.appTitle,
              lastUsedAt: DateTime.now().toUtc(),
            );
    await _accountChanges.synchronized(() async {
      // Every account was signed out of while this waited: the sign-in is
      // from before that, and is not saved into the storage cleared since.
      if (store.clears != clears) {
        throw StateError('LibreChat accounts were cleared meanwhile.');
      }
      // A session this replaces may still be saving a renewal or a cookie:
      // what it is writing lands first, and nothing it writes later
      // overwrites this one.
      await store.retireSessionStores(account.id);
      try {
        // That can wait on a session still ending, across a full sign-out:
        // asked again, so the sign-in is not saved into what it cleared.
        if (store.clears != clears) {
          throw StateError('LibreChat accounts were cleared meanwhile.');
        }
        await store.sessionStore(account.id).write(session);
        _signIns.update(account.id, (count) => count + 1, ifAbsent: () => 1);
        await _ref
            .read(libreChatRegistryProvider.notifier)
            .save(account, activate: activate);
      } catch (_) {
        // The session in use was cut off from its store above: it reloads,
        // onto one it can write to again.
        _ref.invalidate(libreChatSessionProvider);
        rethrow;
      }
    });
    // A session saved again for the account in use must reload -- in use
    // now: one switched to while this waited has read no session yet.
    final activeNow = _ref.read(libreChatRegistryProvider).value?.activeId;
    if (activate || activeNow == account.id) {
      _ref.invalidate(libreChatSessionProvider);
    }
    return account;
  }

  /// Signs [accountId] out: ends its session on the server (best effort),
  /// deletes its local database and forgets it.
  Future<void> signOut(String accountId) async {
    final signIns = _signIns[accountId];
    final registry = await _ref.read(libreChatRegistryProvider.future);
    final account = registry.byId(accountId);
    final store = _store.sessionStore(accountId);
    final session = await store.read();
    if (account != null && session != null) {
      final auth = LibreChatAuthService(
        account.server,
        adapter: _ref.read(libreChatHttpAdapterProvider),
      );
      try {
        await auth.signOut(session);
      } finally {
        auth.close();
      }
    }
    await _accountChanges.synchronized(() async {
      // Signed in to again while the server was told: that sign-in, and the
      // chats it brings, stay. A renewal meanwhile is no sign-in, though it
      // stores a new session too. Asked here, where no sign-in can land
      // until this one is done.
      if (_signIns[accountId] != signIns) return;
      // The session in use ends first: a renewal or cookie it is still
      // saving lands before the clear, and none it makes later reaches the
      // store.
      final live = _ref.read(libreChatSessionProvider).asData?.value;
      if (live is LibreChatSignedInState && live.account.id == accountId) {
        await live.handle.end();
      }
      // So does one switched away from, which can still be saving: what it
      // is writing lands first, and nothing it writes later is kept.
      await _store.retireSessionStores(accountId);
      // Through a store handed out now: the one read above is retired.
      await _store.sessionStore(accountId).clear();
      await _ref.read(libreChatRegistryProvider.notifier).remove(accountId);
      try {
        await _ref.read(libreChatDatabaseManagerProvider).deleteFor(accountId);
      } catch (error) {
        DebugLogger.warning(
          'database-delete-failed',
          scope: 'librechat/accounts',
          data: {'error': error.runtimeType.toString()},
        );
        await _holdLeftoverDatabases(
          keepSavedAccounts: true,
          fallback: {libreChatDatabaseFileName(accountId)},
        );
      }
    });
  }

  /// Keeps the databases on disk that no saved account owns closed until
  /// they are deleted, in this run or the next: a sign-out that could not
  /// delete one would otherwise leave it with nothing to retry, and open it
  /// again for the same account. With [keepSavedAccounts], the databases of
  /// accounts still saved are left alone. [fallback] when the files cannot be
  /// listed; null for every LibreChat database.
  Future<void> _holdLeftoverDatabases({
    required bool keepSavedAccounts,
    required Set<String>? fallback,
  }) async {
    final manager = _ref.read(libreChatDatabaseManagerProvider);
    Set<String>? leftover = fallback;
    try {
      final registry = keepSavedAccounts
          ? await _store.read()
          : const LibreChatRegistry();
      final kept = {
        for (final account in registry.accounts)
          libreChatDatabaseFileName(account.id),
      };
      leftover = (await manager.serverDatabaseFileNames()).difference(kept);
    } catch (_) {}
    if (leftover != null && leftover.isEmpty) return;
    try {
      // Added to, not replacing, what an earlier sign-out left pending.
      await manager.addPendingWipe(leftover);
    } catch (error) {
      // Held for this run all the same; only the next start cannot know.
      DebugLogger.warning(
        'pending-wipe-record-failed',
        scope: 'librechat/accounts',
        data: {'error': error.runtimeType.toString()},
      );
    }
  }

  /// Every saved account with its session, read before a full sign-out
  /// clears the storage they live in.
  ///
  /// Best effort, as the server sign-outs it feeds are: an account or
  /// session that cannot be read is left out (or given no session), and the
  /// local clear goes ahead regardless.
  Future<List<(LibreChatAccount, LibreChatSession?)>> sessionsForSignOut()
  async {
    final LibreChatRegistry registry;
    try {
      registry = await _ref.read(libreChatRegistryProvider.future);
    } catch (error) {
      DebugLogger.warning(
        'sign-out-registry-unreadable',
        scope: 'librechat/accounts',
        data: {'error': error.runtimeType.toString()},
      );
      return const [];
    }
    final sessions = <(LibreChatAccount, LibreChatSession?)>[];
    for (final account in registry.accounts) {
      LibreChatSession? session;
      try {
        session = await _store.sessionStore(account.id).read();
      } catch (error) {
        DebugLogger.warning(
          'sign-out-session-unreadable',
          scope: 'librechat/accounts',
          data: {'error': error.runtimeType.toString()},
        );
      }
      sessions.add((account, session));
    }
    return sessions;
  }

  /// After a full sign-out cleared local data: deletes every LibreChat
  /// database, [accounts]' and any no saved account names any more, and
  /// forgets the registry, then ends [accounts]' sessions on their servers
  /// without waiting. Databases that cannot be deleted stay closed until
  /// they are, in this run or the next.
  Future<void> forgetAfterSignOut(
    List<(LibreChatAccount, LibreChatSession?)> accounts,
  ) async {
    final manager = _ref.read(libreChatDatabaseManagerProvider);
    var databasesDeleted = true;
    try {
      await manager.deleteAllServerDatabases();
    } catch (error) {
      databasesDeleted = false;
      DebugLogger.warning(
        'database-delete-failed',
        scope: 'librechat/accounts',
        data: {'error': error.runtimeType.toString()},
      );
    }
    try {
      await _ref.read(libreChatRegistryProvider.notifier).clear();
    } finally {
      // The servers are told whatever the local clear did: the retry a
      // failed clear leaves for the next start only forgets what is stored
      // here, and could not end these sessions.
      for (final (account, session) in accounts) {
        if (session == null) continue;
        final auth = LibreChatAuthService(
          account.server,
          adapter: _ref.read(libreChatHttpAdapterProvider),
        );
        unawaited(auth.signOut(session).whenComplete(auth.close));
      }
      if (!databasesDeleted) {
        await _holdLeftoverDatabases(keepSavedAccounts: false, fallback: null);
      }
    }
  }

  /// Signs out of every LibreChat account, for "sign out of all".
  Future<void> signOutAll() async {
    final registry = await _ref.read(libreChatRegistryProvider.future);
    for (final account in registry.accounts) {
      try {
        await signOut(account.id);
      } on LibreChatApiException {
        // Each account's local state goes regardless; keep going.
      }
    }
    await _ref.read(libreChatRegistryProvider.notifier).clear();
  }
}
