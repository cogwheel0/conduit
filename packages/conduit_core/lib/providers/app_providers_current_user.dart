part of 'app_providers.dart';

@Riverpod(keepAlive: true)
Future<User?> currentUser(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  final authState = ref.watch(authStateManagerProvider);
  ref.watch(openWebUiAuthSessionEpochProvider);
  ref.watch(openWebUiDatabaseAccessProvider);
  ref.watch(openWebUiCertifiedDatabaseServerProvider);
  ref.watch(activeServerProvider);
  final isAuthenticated = authState.maybeWhen(
    data: (state) => state.isAuthenticated,
    orElse: () => false,
  );

  if (api == null || !isAuthenticated) return null;

  // Fast path: use user already in auth state.
  final authUser = authState.maybeWhen(
    data: (state) => state.user,
    orElse: () => null,
  );
  if (authUser != null) return authUser;

  final cacheOwnership = captureOpenWebUiCacheOwnership(
    ref,
    api: api,
    requireAuthenticated: false,
  );
  if (cacheOwnership == null) return null;

  // Next: try cached user from storage, then refresh in the background.
  final storage = ref.read(optimizedStorageServiceProvider);
  final cachedUser = await _getCachedUserWithAvatar(storage);
  if (!openWebUiCacheOwnershipIsCurrent(ref, cacheOwnership)) return null;
  final token = cacheOwnership.authToken;
  final marker = ref
      .read(openWebUiAccountOwnerMarkerStoreProvider)
      .read(cacheOwnership.serverId);
  final cachedOwnerMatches =
      cachedUser != null &&
      token != null &&
      openWebUiAccountOwnerMarkerMatches(
        marker: marker,
        token: token,
        userId: cachedUser.id,
      );
  if (cachedOwnerMatches) {
    final lastRefresh = ref.read(_lastUserRefreshProvider);
    final now = DateTime.now();
    final shouldRefresh =
        lastRefresh == null ||
        now.difference(lastRefresh) > const Duration(minutes: 5);

    if (shouldRefresh) {
      Future.microtask(() async {
        final fresh = await _refreshCurrentUser(ref);
        if (fresh != null && ref.mounted) {
          ref.read(_lastUserRefreshProvider.notifier).set(now);
          ref.invalidate(currentUserProvider);
        }
      });
    }
    return cachedUser;
  }

  // Fallback: fetch fresh.
  final fresh = await _refreshCurrentUser(ref);
  if (fresh != null && ref.mounted) {
    ref.read(_lastUserRefreshProvider.notifier).set(DateTime.now());
  }
  return ref.mounted ? fresh : null;
}

Future<User?> _getCachedUserWithAvatar(OptimizedStorageService storage) =>
    storage.getLocalUserWithAvatar();

Future<User?> _refreshCurrentUser(Ref ref) async {
  // A warm refresh is queued in a microtask. Authentication/server changes can
  // invalidate the provider build before that task starts, so do not perform
  // even the first provider read through a retired Ref.
  if (!ref.mounted) return null;
  final api = ref.read(apiServiceProvider);
  if (api == null) return null;
  final ownership = captureOpenWebUiCacheOwnership(
    ref,
    api: api,
    requireAuthenticated: false,
  );
  if (ownership == null) return null;

  try {
    final user = await api.getCurrentUser();
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return null;
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.saveLocalUserWithAvatar(user, avatarUrl: user.profileImage);
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return null;
    return user;
  } catch (_) {
    return null;
  }
}

@Riverpod(keepAlive: true)
class _LastUserRefresh extends _$LastUserRefresh {
  @override
  DateTime? build() => null;

  void set(DateTime? timestamp) => state = timestamp;
}

// Helper provider to force refresh auth state - now using unified system
final refreshAuthStateProvider = Provider<void>((ref) {
  // This provider can be invalidated to force refresh the unified auth system
  Future.microtask(() => ref.read(authActionsProvider).refresh());
  return;
});
