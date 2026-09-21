part of 'app_providers.dart';

/// Immutable ownership fence for async OpenWebUI API results that may update
/// server-scoped state or cache rows after an await.
///
/// ApiService identity alone is insufficient: it can remain stable across a
/// same-server account transition. The auth epoch, token, active server,
/// database certification phase, and raw storage owner close that ABA window.
@immutable
final class OpenWebUiCacheOwnershipSnapshot {
  const OpenWebUiCacheOwnershipSnapshot({
    required this.api,
    required this.serverId,
    required this.activeServerId,
    required this.authSessionEpoch,
    required this.authToken,
    required this.authenticated,
    required this.databaseAccessPhase,
    required this.certifiedDatabaseServerId,
    required this.rawActiveServerId,
  });

  final ApiService api;
  final String serverId;
  final String? activeServerId;
  final Object authSessionEpoch;
  final String? authToken;
  final bool authenticated;
  final OpenWebUiDatabaseAccessPhase databaseAccessPhase;
  final String? certifiedDatabaseServerId;
  final String? rawActiveServerId;
}

OpenWebUiCacheOwnershipSnapshot? captureOpenWebUiCacheOwnership(
  Ref ref, {
  required ApiService api,
  bool requireAuthenticated = true,
}) {
  if (!ref.mounted) return null;
  final serverId = api.serverConfig.id;
  // Keep the last resolved owner through an AsyncLoading/AsyncError refresh.
  // Treating every transient refresh as "no server" can retire otherwise
  // valid same-server cache/API work while the server is being revalidated.
  final activeServerId = ref.read(activeServerProvider).value?.id;
  final rawActiveServerId = PreferencesStore.getString(
    PreferenceKeys.activeServerId,
  );
  final authenticated = ref.read(isAuthenticatedProvider2);
  final authToken = ref.read(authTokenProvider3);
  if (!identical(ref.read(apiServiceProvider), api) ||
      (activeServerId != null && activeServerId != serverId) ||
      (rawActiveServerId != null && rawActiveServerId != serverId) ||
      (requireAuthenticated &&
          (!authenticated || authToken == null || authToken.isEmpty))) {
    return null;
  }
  return OpenWebUiCacheOwnershipSnapshot(
    api: api,
    serverId: serverId,
    activeServerId: activeServerId,
    authSessionEpoch: ref.read(openWebUiAuthSessionEpochProvider),
    authToken: authToken,
    authenticated: authenticated,
    databaseAccessPhase: ref.read(openWebUiDatabaseAccessProvider),
    certifiedDatabaseServerId: ref.read(
      openWebUiCertifiedDatabaseServerProvider,
    ),
    rawActiveServerId: rawActiveServerId,
  );
}

bool openWebUiCacheOwnershipIsCurrent(
  Ref ref,
  OpenWebUiCacheOwnershipSnapshot snapshot,
) {
  if (!ref.mounted ||
      !identical(ref.read(apiServiceProvider), snapshot.api) ||
      ref.read(activeServerProvider).value?.id != snapshot.activeServerId ||
      !identical(
        ref.read(openWebUiAuthSessionEpochProvider),
        snapshot.authSessionEpoch,
      ) ||
      ref.read(authTokenProvider3) != snapshot.authToken ||
      ref.read(isAuthenticatedProvider2) != snapshot.authenticated ||
      ref.read(openWebUiDatabaseAccessProvider) !=
          snapshot.databaseAccessPhase ||
      ref.read(openWebUiCertifiedDatabaseServerProvider) !=
          snapshot.certifiedDatabaseServerId ||
      PreferencesStore.getString(PreferenceKeys.activeServerId) !=
          snapshot.rawActiveServerId) {
    return false;
  }
  return (snapshot.activeServerId == null ||
          snapshot.activeServerId == snapshot.serverId) &&
      (snapshot.rawActiveServerId == null ||
          snapshot.rawActiveServerId == snapshot.serverId);
}

/// Ownership token for an asynchronous OpenWebUI conversation read.
///
/// Conversation bodies can come from either the server database or the API.
/// Both objects may outlive the account that started a read, so object identity
/// alone is not an adequate fence. This token also captures the authentication
/// epoch and the database/server certification boundary used by account
/// isolation.
@immutable
final class OpenWebUiConversationReadSnapshot {
  const OpenWebUiConversationReadSnapshot._({
    required this.database,
    required this.api,
    required this.authSessionEpoch,
    required this.databaseAccessPhase,
    required this.certifiedDatabaseServerId,
    required this.activeServerId,
    required this.rawActiveServerId,
    required this.managedDatabaseServerId,
    required this.apiServerId,
  });

  final AppDatabase? database;
  final ApiService? api;
  final Object authSessionEpoch;
  final OpenWebUiDatabaseAccessPhase databaseAccessPhase;
  final String? certifiedDatabaseServerId;
  final String? activeServerId;
  final String? rawActiveServerId;
  final String? managedDatabaseServerId;
  final String? apiServerId;
}

/// Logical account/server owner for a user-initiated conversation selection.
///
/// Exact database and API identities belong to [OpenWebUiConversationReadSnapshot]
/// and may legitimately change while the same account finishes opening. This
/// owner survives that replacement while still canceling on logout, account
/// changes, or server changes.
@immutable
final class OpenWebUiConversationSelectionOwner {
  const OpenWebUiConversationSelectionOwner._({
    required this.serverId,
    required this.userId,
    required this.authToken,
    required this.authSessionEpoch,
  });

  final String serverId;
  final String? userId;
  final String authToken;
  final Object authSessionEpoch;
}

enum OpenWebUiConversationOwnershipFailureReason {
  unavailable,
  changedWhileLoading,
  changedWhileFetching,
}

final class OpenWebUiConversationOwnershipException extends StateError {
  OpenWebUiConversationOwnershipException(this.reason)
    : super(switch (reason) {
        OpenWebUiConversationOwnershipFailureReason.unavailable =>
          'OpenWebUI conversation ownership is unavailable',
        OpenWebUiConversationOwnershipFailureReason.changedWhileLoading =>
          'OpenWebUI conversation ownership changed while loading',
        OpenWebUiConversationOwnershipFailureReason.changedWhileFetching =>
          'OpenWebUI conversation ownership changed while fetching',
      });

  final OpenWebUiConversationOwnershipFailureReason reason;
}

typedef _OpenWebUiConversationReadContext = ({
  AppDatabase? database,
  ApiService? api,
  Object authSessionEpoch,
  OpenWebUiDatabaseAccessPhase databaseAccessPhase,
  String? certifiedDatabaseServerId,
  String? activeServerId,
  String? rawActiveServerId,
  String? managedDatabaseServerId,
  String? apiServerId,
});

bool _openWebUiConversationReaderIsMounted(dynamic ref) {
  try {
    final mounted = ref.mounted;
    return mounted is! bool || mounted;
  } catch (_) {
    // ProviderContainer intentionally has no mounted property. Its reads below
    // still fail after disposal, which is handled by the context reader.
    return true;
  }
}

_OpenWebUiConversationReadContext? _readOpenWebUiConversationContext(
  dynamic ref,
) {
  if (!_openWebUiConversationReaderIsMounted(ref)) return null;

  // The database and API are independent read sources. In particular, the
  // account database may be unavailable while it is opening (or a narrow test
  // may deliberately omit it), but that must not erase an otherwise exact API
  // ownership token. Read optional context components independently and keep
  // the mandatory auth/database-isolation fence fail-closed.
  AppDatabase? database;
  try {
    database = ref.read(appDatabaseProvider) as AppDatabase?;
  } catch (_) {}

  ApiService? api;
  try {
    api = ref.read(apiServiceProvider) as ApiService?;
  } catch (_) {}
  if (database == null && api == null) return null;

  late final Object authSessionEpoch;
  late final OpenWebUiDatabaseAccessPhase databaseAccessPhase;
  String? certifiedDatabaseServerId;
  try {
    authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider) as Object;
    databaseAccessPhase = ref.read(
      openWebUiDatabaseAccessProvider,
    ) as OpenWebUiDatabaseAccessPhase;
    certifiedDatabaseServerId =
        ref.read(openWebUiCertifiedDatabaseServerProvider) as String?;
  } catch (_) {
    return null;
  }

  String? managedDatabaseServerId;
  if (database != null) {
    try {
      managedDatabaseServerId = ref
          .read(databaseManagerProvider)
          .serverIdForDatabase(database);
    } catch (_) {
      // Provider overrides commonly use unmanaged in-memory databases. Exact
      // database identity remains their ownership boundary.
    }
  }

  String? apiServerId;
  if (api != null) {
    try {
      apiServerId = api.serverConfig.id;
    } catch (_) {
      // Lightweight ApiService fakes may not implement serverConfig. Real
      // services always do, and the remaining captured identities still
      // provide a deterministic test seam.
    }
  }

  String? rawActiveServerId;
  try {
    rawActiveServerId = PreferencesStore.isReady
        ? PreferencesStore.getString(PreferenceKeys.activeServerId)
        : null;
  } catch (_) {
    // A narrow test or early bootstrap can expose a synchronously torn-down
    // preferences seam. Provider/database/auth identity still forms the
    // ownership fence; absence of this optional corroborating id is safer
    // than making every otherwise coherent read unavailable.
    rawActiveServerId = null;
  }

  String? activeServerId;
  try {
    final activeServer = ref.read(activeServerProvider);
    activeServerId = activeServer is AsyncData<ServerConfig?>
        ? activeServer.value?.id
        : null;
  } catch (_) {
    // During server bootstrap the independently captured API/database identity
    // remains authoritative. A later active-server publication changes this
    // tuple and invalidates the snapshot before its result can be published.
  }

  return (
    database: database,
    api: api,
    authSessionEpoch: authSessionEpoch,
    databaseAccessPhase: databaseAccessPhase,
    certifiedDatabaseServerId: certifiedDatabaseServerId,
    activeServerId: activeServerId,
    rawActiveServerId: rawActiveServerId,
    managedDatabaseServerId: managedDatabaseServerId,
    apiServerId: apiServerId,
  );
}

String? _readOpenWebUiLogicalServerId(dynamic ref) {
  if (!_openWebUiConversationReaderIsMounted(ref)) return null;

  late final OpenWebUiDatabaseAccessPhase accessPhase;
  try {
    accessPhase = ref.read(
      openWebUiDatabaseAccessProvider,
    ) as OpenWebUiDatabaseAccessPhase;
  } catch (_) {
    return null;
  }

  final primaryIds = <String>{};
  try {
    final activeServer = ref.read(activeServerProvider);
    if (activeServer is AsyncData<ServerConfig?>) {
      final id = activeServer.value?.id;
      if (id != null && id.isNotEmpty) primaryIds.add(id);
    }
  } catch (_) {}
  try {
    if (PreferencesStore.isReady) {
      final id = PreferencesStore.getString(PreferenceKeys.activeServerId);
      if (id != null && id.isNotEmpty) primaryIds.add(id);
    }
  } catch (_) {}
  try {
    final api = ref.read(apiServiceProvider) as ApiService?;
    final id = api?.serverConfig.id;
    if (id != null && id.isNotEmpty) primaryIds.add(id);
  } catch (_) {}
  if (primaryIds.length > 1) return null;

  final storageIds = <String>{};
  try {
    final certified =
        ref.read(openWebUiCertifiedDatabaseServerProvider) as String?;
    if (certified != null && certified.isNotEmpty) storageIds.add(certified);
  } catch (_) {}
  try {
    final database = ref.read(appDatabaseProvider) as AppDatabase?;
    if (database != null) {
      final managed = ref
          .read(databaseManagerProvider)
          .serverIdForDatabase(database);
      if (managed != null && managed.isNotEmpty) storageIds.add(managed);
    }
  } catch (_) {}
  if (storageIds.length > 1) return null;

  final primary = primaryIds.isEmpty ? null : primaryIds.first;
  final storage = storageIds.isEmpty ? null : storageIds.first;
  if (accessPhase == OpenWebUiDatabaseAccessPhase.open &&
      primary != null &&
      storage != null &&
      primary != storage) {
    return null;
  }
  return primary ?? storage;
}

OpenWebUiConversationSelectionOwner? captureOpenWebUiConversationSelectionOwner(
  dynamic ref,
) {
  if (!_openWebUiConversationReaderIsMounted(ref)) return null;
  try {
    final authenticated = ref.read(isAuthenticatedProvider2) as bool;
    final authToken = ref.read(authTokenProvider3) as String?;
    final userId = (ref.read(currentUserProvider2) as User?)?.id.trim();
    final serverId = _readOpenWebUiLogicalServerId(ref);
    if (!authenticated ||
        authToken == null ||
        authToken.isEmpty ||
        serverId == null) {
      return null;
    }
    return OpenWebUiConversationSelectionOwner._(
      serverId: serverId,
      userId: userId == null || userId.isEmpty ? null : userId,
      authToken: authToken,
      authSessionEpoch: ref.read(openWebUiAuthSessionEpochProvider) as Object,
    );
  } catch (_) {
    return null;
  }
}

bool openWebUiConversationSelectionOwnerIsCurrent(
  dynamic ref,
  OpenWebUiConversationSelectionOwner owner,
) {
  final current = captureOpenWebUiConversationSelectionOwner(ref);
  if (current == null ||
      current.serverId != owner.serverId ||
      !identical(current.authSessionEpoch, owner.authSessionEpoch)) {
    return false;
  }
  final ownerUserId = owner.userId;
  final currentUserId = current.userId;
  if (ownerUserId != null && currentUserId != null) {
    return ownerUserId == currentUserId;
  }
  return owner.authToken == current.authToken;
}

/// Captures the single ownership token shared by all OpenWebUI conversation
/// read and publication paths.
///
/// [database] and [api], when supplied, must still be the current provider
/// instances. At least one current OpenWebUI data source must exist.
OpenWebUiConversationReadSnapshot? captureOpenWebUiConversationRead(
  dynamic ref, {
  AppDatabase? database,
  ApiService? api,
}) {
  final context = _readOpenWebUiConversationContext(ref);
  if (context == null ||
      (database != null && !identical(database, context.database)) ||
      (api != null && !identical(api, context.api)) ||
      (context.database == null && context.api == null) ||
      context.databaseAccessPhase == OpenWebUiDatabaseAccessPhase.purging ||
      context.databaseAccessPhase == OpenWebUiDatabaseAccessPhase.closed) {
    return null;
  }

  final databaseServerId = context.managedDatabaseServerId;
  if (databaseServerId != null) {
    if (context.databaseAccessPhase != OpenWebUiDatabaseAccessPhase.open ||
        context.certifiedDatabaseServerId != databaseServerId ||
        context.activeServerId != databaseServerId ||
        (context.rawActiveServerId != null &&
            context.rawActiveServerId != databaseServerId) ||
        (context.api != null && context.apiServerId != databaseServerId)) {
      return null;
    }
  }

  final apiServerId = context.apiServerId;
  if (apiServerId != null &&
      ((context.activeServerId != null &&
              context.activeServerId != apiServerId) ||
          (context.rawActiveServerId != null &&
              context.rawActiveServerId != apiServerId) ||
          (context.databaseAccessPhase == OpenWebUiDatabaseAccessPhase.open &&
              context.certifiedDatabaseServerId != null &&
              context.certifiedDatabaseServerId != apiServerId))) {
    return null;
  }

  return OpenWebUiConversationReadSnapshot._(
    database: context.database,
    api: context.api,
    authSessionEpoch: context.authSessionEpoch,
    databaseAccessPhase: context.databaseAccessPhase,
    certifiedDatabaseServerId: context.certifiedDatabaseServerId,
    activeServerId: context.activeServerId,
    rawActiveServerId: context.rawActiveServerId,
    managedDatabaseServerId: context.managedDatabaseServerId,
    apiServerId: context.apiServerId,
  );
}

/// Whether [snapshot] still owns the exact OpenWebUI account/server context.
bool openWebUiConversationReadIsCurrent(
  dynamic ref,
  OpenWebUiConversationReadSnapshot snapshot,
) {
  final context = _readOpenWebUiConversationContext(ref);
  return context != null &&
      identical(context.database, snapshot.database) &&
      identical(context.api, snapshot.api) &&
      identical(context.authSessionEpoch, snapshot.authSessionEpoch) &&
      context.databaseAccessPhase == snapshot.databaseAccessPhase &&
      context.certifiedDatabaseServerId == snapshot.certifiedDatabaseServerId &&
      context.activeServerId == snapshot.activeServerId &&
      context.rawActiveServerId == snapshot.rawActiveServerId &&
      context.managedDatabaseServerId == snapshot.managedDatabaseServerId &&
      context.apiServerId == snapshot.apiServerId;
}

/// Whether account-scoped OpenWebUI storage is safe for active chat content.
bool openWebUiAccountStorageIsCertified(dynamic ref) {
  try {
    if (ref.read(openWebUiDatabaseAccessProvider) !=
        OpenWebUiDatabaseAccessPhase.open) {
      return false;
    }
    final certifiedServerId = ref.read(
      openWebUiCertifiedDatabaseServerProvider,
    );
    final activeServer = ref.read(activeServerProvider);
    if (activeServer is AsyncData<ServerConfig?>) {
      final activeServerId = activeServer.value?.id;
      if (activeServerId != null) return activeServerId == certifiedServerId;
    }

    // Narrow tests override an unmanaged in-memory database without an active
    // server. Production databases always have a manager owner and therefore
    // require the certified logical server above.
    final database = ref.read(appDatabaseProvider) as AppDatabase?;
    if (database == null) return false;
    final managedServerId = ref
        .read(databaseManagerProvider)
        .serverIdForDatabase(database);
    return managedServerId == null;
  } catch (_) {
    return false;
  }
}

bool openWebUiConversationReadIsCertifiedForPublication(
  dynamic ref,
  OpenWebUiConversationReadSnapshot snapshot,
) {
  return snapshot.databaseAccessPhase == OpenWebUiDatabaseAccessPhase.open &&
      openWebUiConversationReadIsCurrent(ref, snapshot) &&
      openWebUiAccountStorageIsCertified(ref);
}
