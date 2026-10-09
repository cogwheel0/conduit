part of 'app_providers.dart';

// Reviewer mode provider (persisted)
@Riverpod(keepAlive: true)
class ReviewerMode extends _$ReviewerMode {
  // Notifier instances survive invalidation, so build() can run more than once.
  late OptimizedStorageService _storage;
  int _loadGeneration = 0;

  @override
  bool build() {
    final storage = ref.watch(optimizedStorageServiceProvider);
    _storage = storage;
    final generation = ++_loadGeneration;
    Future.microtask(() => _load(storage, generation));
    return false;
  }

  Future<void> _load(OptimizedStorageService storage, int generation) async {
    final enabled = await storage.getReviewerMode();
    if (!ref.mounted || generation != _loadGeneration) {
      return;
    }
    state = enabled;
  }

  Future<void> setEnabled(bool enabled) async {
    _loadGeneration++;
    state = enabled;
    await _storage.setReviewerMode(enabled);
  }

  Future<void> toggle() => setEnabled(!state);
}

// User Settings providers
@Riverpod(keepAlive: true)
Future<UserSettings> userSettings(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    // Return default settings if no API
    return const UserSettings();
  }

  try {
    final settingsData = await api.getUserSettings();
    return UserSettings.fromJson(settingsData);
  } catch (e) {
    DebugLogger.error('user-settings-failed', scope: 'settings', error: e);
    // Return default settings on error
    return const UserSettings();
  }
}

final rawUserSettingsProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return const <String, dynamic>{};
  }

  try {
    return await api.getUserSettings();
  } catch (e) {
    DebugLogger.error('raw-user-settings-failed', scope: 'settings', error: e);
    return const <String, dynamic>{};
  }
});

@Riverpod(keepAlive: true)
class PersonalizationSettings extends _$PersonalizationSettings {
  int _pinnedModelsWriteGeneration = 0;
  String? _settingsServerId;
  ServerUserSettings? _settingsSnapshot;
  // Server is mirrored into local notification prefs once per server (on first
  // load / server switch). Re-applying on every settings reload could clobber a
  // just-made local toggle whose write-through hasn't reached the server yet.
  String? _notificationPrefsAppliedServerId;

  @override
  Future<ServerUserSettings> build() async {
    ref.watch(activeServerProvider.select((s) => s.asData?.value?.id));
    final apiAlive = ref.watch(apiServiceProvider.select((a) => a != null));
    if (!apiAlive) {
      return _localPinnedModelSettings();
    }
    return _loadSettings();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_loadSettings);
  }

  Future<ServerUserSettings> setSystemPrompt(String? systemPrompt) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final serverId = api.serverConfig.id;
    final updated = await api.updateUserSystemPrompt(systemPrompt);
    if (!ref.mounted) {
      return updated;
    }
    if (!_isCurrentServer(serverId)) {
      return _currentSettingsForActiveServerOrDefault();
    }

    _settingsServerId = serverId;
    _settingsSnapshot = updated;
    state = AsyncData(updated);
    ref.invalidate(rawUserSettingsProvider);
    ref.invalidate(userSettingsProvider);
    return updated;
  }

  Future<ServerUserSettings> setMemoryEnabled(bool enabled) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final serverId = api.serverConfig.id;
    final updated = await api.updateUserMemoryEnabled(enabled);
    if (!ref.mounted) {
      return updated;
    }
    if (!_isCurrentServer(serverId)) {
      return _currentSettingsForActiveServerOrDefault();
    }

    _settingsServerId = serverId;
    _settingsSnapshot = updated;
    state = AsyncData(updated);
    ref.invalidate(rawUserSettingsProvider);
    ref.invalidate(userSettingsProvider);
    return updated;
  }

  Future<ServerUserSettings> setReasoningEffort(String? effort) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final serverId = api.serverConfig.id;
    final updated = await api.updateUserReasoningEffort(effort);
    if (!ref.mounted) return updated;
    if (!_isCurrentServer(serverId)) {
      return _currentSettingsForActiveServerOrDefault();
    }

    _settingsServerId = serverId;
    _settingsSnapshot = updated;
    state = AsyncData(updated);
    ref.invalidate(rawUserSettingsProvider);
    ref.invalidate(userSettingsProvider);
    return updated;
  }

  Future<ServerUserSettings> setPinnedModels(List<String> modelIds) async {
    final sanitized = SettingsService.sanitizePinnedModels(modelIds);
    final api = ref.read(apiServiceProvider);
    final serverId = api?.serverConfig.id;
    final current =
        _currentSettingsForServer(serverId) ?? const ServerUserSettings();
    final optimistic = current.copyWith(pinnedModelIds: sanitized);
    final writeGeneration = ++_pinnedModelsWriteGeneration;

    _settingsServerId = serverId;
    _settingsSnapshot = optimistic;
    state = AsyncData(optimistic);
    await ref.read(appSettingsProvider.notifier).setPinnedModels(sanitized);

    if (api == null) {
      return optimistic;
    }

    try {
      final updated = await api.updateUserPinnedModels(sanitized);
      if (!ref.mounted) {
        return updated;
      }
      if (!_isCurrentServer(serverId)) {
        return _currentSettingsForActiveServerOrDefault();
      }
      if (writeGeneration != _pinnedModelsWriteGeneration) {
        return state.asData?.value ?? updated;
      }

      _settingsServerId = serverId;
      _settingsSnapshot = updated;
      state = AsyncData(updated);
      _cachePinnedModelsLocally(updated.pinnedModelIds, accountId: serverId);
      ref.invalidate(rawUserSettingsProvider);
      ref.invalidate(userSettingsProvider);
      return updated;
    } catch (error, stackTrace) {
      if (!_isCurrentServer(serverId)) {
        return _currentSettingsForActiveServerOrDefault();
      }
      if (writeGeneration != _pinnedModelsWriteGeneration) {
        return state.asData?.value ?? optimistic;
      }
      DebugLogger.error(
        'server-pinned-models-update-failed',
        scope: 'settings',
        error: error,
        stackTrace: stackTrace,
      );
      return optimistic;
    }
  }

  Future<ServerUserSettings> togglePinnedModel(String modelId) {
    final trimmed = modelId.trim();
    if (trimmed.isEmpty) {
      return Future.value(state.asData?.value ?? const ServerUserSettings());
    }

    final api = ref.read(apiServiceProvider);
    final currentSettings = _currentSettingsForServer(api?.serverConfig.id);
    if (api != null && currentSettings == null) {
      return Future.value(_currentSettingsForActiveServerOrDefault());
    }

    final currentPinned = currentSettings?.pinnedModelIds;
    final existing = api == null
        ? currentPinned ?? ref.read(appSettingsProvider).pinnedModels
        : currentPinned ?? const <String>[];
    final updated = existing.contains(trimmed)
        ? existing.where((id) => id != trimmed).toList(growable: false)
        : SettingsService.sanitizePinnedModels([...existing, trimmed]);
    return setPinnedModels(updated);
  }

  Future<ServerUserSettings> _loadSettings() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      _settingsServerId = null;
      final localSettings = _localPinnedModelSettings();
      _settingsSnapshot = localSettings;
      return localSettings;
    }
    final serverId = api.serverConfig.id;
    final readGeneration = _pinnedModelsWriteGeneration;
    final settings = await api.getServerUserSettingsModel();
    if (!ref.mounted) {
      return settings;
    }
    if (!_isCurrentServer(serverId)) {
      return _currentSettingsForActiveServerOrDefault();
    }
    // Server is authoritative for the Open WebUI-aligned notification prefs;
    // mirror them into local settings for cross-device parity (no-ops nulls).
    // Only once per server so a fresh local toggle isn't overwritten by a
    // settings reload that raced the write-through.
    if (_notificationPrefsAppliedServerId != serverId) {
      // Lock the flag only after a successful mirror so a failed apply retries
      // on a later reload instead of staying out of sync for the session.
      unawaited(
        ref
            .read(appSettingsProvider.notifier)
            .applyServerNotificationPrefs(
              accountId: serverId,
              enabled: settings.notificationEnabled,
              sound: settings.notificationSound,
              soundAlways: settings.notificationSoundAlways,
            )
            .then(
              (_) => _notificationPrefsAppliedServerId = serverId,
              onError: (Object e, StackTrace st) {
                DebugLogger.error(
                  'failed to mirror server notification prefs',
                  error: e,
                  stackTrace: st,
                  scope: 'notifications/settings',
                );
              },
            ),
      );
    }
    if (readGeneration != _pinnedModelsWriteGeneration) {
      final merged = _settingsWithCurrentPinnedModels(settings, serverId);
      _settingsServerId = serverId;
      _settingsSnapshot = merged;
      return merged;
    }

    _settingsServerId = serverId;
    _settingsSnapshot = settings;
    _cachePinnedModelsLocally(settings.pinnedModelIds, accountId: serverId);
    return settings;
  }

  ServerUserSettings _settingsWithCurrentPinnedModels(
    ServerUserSettings settings,
    String? serverId,
  ) {
    final currentPinned = _currentSettingsForServer(serverId)?.pinnedModelIds;
    return settings.copyWith(
      pinnedModelIds: SettingsService.sanitizePinnedModels(
        currentPinned ?? const <String>[],
      ),
    );
  }

  ServerUserSettings? _currentSettingsForServer(String? serverId) {
    if (serverId != _settingsServerId) {
      return null;
    }
    final current = state.asData?.value;
    return current ?? _settingsSnapshot;
  }

  bool _isCurrentServer(String? serverId) {
    return serverId == _currentApiServerId();
  }

  String? _currentApiServerId() {
    return ref.read(apiServiceProvider)?.serverConfig.id;
  }

  ServerUserSettings _currentSettingsForActiveServerOrDefault() {
    return _currentSettingsForServer(_currentApiServerId()) ??
        const ServerUserSettings();
  }

  bool get canTogglePinnedModels {
    final api = ref.read(apiServiceProvider);
    return api == null ||
        _currentSettingsForServer(api.serverConfig.id) != null;
  }

  ServerUserSettings _localPinnedModelSettings() {
    return ServerUserSettings(
      pinnedModelIds: ref.read(appSettingsProvider).pinnedModels,
    );
  }

  /// Keeps [modelIds], the pins [accountId]'s server answered with, as that
  /// account's local copy.
  void _cachePinnedModelsLocally(
    List<String> modelIds, {
    required String? accountId,
  }) {
    final local = ref.read(appSettingsProvider).pinnedModels;
    if (const ListEquality<Object?>().equals(local, modelIds)) {
      return;
    }

    unawaited(
      Future<void>.microtask(() async {
        // A switch since would file them under the next account: a write
        // lands under the account stored as active when it starts. With none
        // stored it lands device-wide, which the account in use reads until
        // its own copy is made.
        if (!ref.mounted) return;
        final landsUnder =
            currentPreferenceAccountId() ??
            ref.read(activeServerProvider).asData?.value?.id;
        if (landsUnder != accountId) return;
        await ref.read(appSettingsProvider.notifier).setPinnedModels(modelIds);
      }),
    );
  }
}

final effectivePinnedModelIdsProvider = Provider<List<String>>((ref) {
  final localPinnedModelIds = ref.watch(
    appSettingsProvider.select((settings) => settings.pinnedModels),
  );
  final apiAlive = ref.watch(apiServiceProvider.select((api) => api != null));
  if (!apiAlive) {
    return localPinnedModelIds;
  }

  final serverSettings = ref.watch(personalizationSettingsProvider);
  return serverSettings.maybeWhen(
    data: (settings) => settings.pinnedModelIds,
    orElse: () => localPinnedModelIds,
  );
});

final canTogglePinnedModelsProvider = Provider<bool>((ref) {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return true;
  }

  ref.watch(personalizationSettingsProvider);
  return ref
      .read(personalizationSettingsProvider.notifier)
      .canTogglePinnedModels;
});

/// Thrown when the signed-in account is not allowed to use server memories.
final class MemoriesNotPermittedException implements Exception {
  const MemoriesNotPermittedException();

  @override
  String toString() =>
      'MemoriesNotPermittedException: memories are disabled '
      'for this account';
}

/// Thrown when the account a memory form or sheet was opened for is no longer
/// the signed-in one. Nothing was sent; the form can keep its input.
final class MemoryOwnerChangedException extends StateError {
  MemoryOwnerChangedException()
    : super('The account changed since this memory form was opened');
}

/// The account a memory form or native sheet was opened for.
///
/// The notifier outlives account switches and rebuilds for the next account, so
/// holding it says nothing about whose memories a later Save would change.
/// Pass the owner back to a mutation and it is rejected, before any request,
/// once the API, auth session or server no longer match.
@immutable
final class MemoryOwner {
  const MemoryOwner._(this._api, this._auth, this._ownership);

  final ApiService _api;
  final ApiAuthSnapshot _auth;
  final OpenWebUiCacheOwnershipSnapshot _ownership;
}

/// The API, auth and ownership state one memory operation was admitted under.
typedef _MemoryOperation = ({
  ApiService api,
  ApiAuthSnapshot auth,
  OpenWebUiCacheOwnershipSnapshot ownership,
});

@Riverpod(keepAlive: true)
class UserMemories extends _$UserMemories {
  @override
  Future<List<ServerMemory>> build() async {
    ref.watch(activeServerProvider.select((s) => s.asData?.value?.id));
    // A same-server account switch keeps the same ApiService, so the auth
    // session is what retires one account's memories for the next.
    ref.watch(openWebUiAuthSessionEpochProvider);
    final apiAlive = ref.watch(apiServiceProvider.select((a) => a != null));
    final api = ref.read(apiServiceProvider);
    if (!apiAlive || api == null) {
      return const <ServerMemory>[];
    }
    final ownership = _captureOwnership(api);
    if (ownership == null) {
      return const <ServerMemory>[];
    }
    final memories = await _loadMemories(api, ownership);
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) {
      return const <ServerMemory>[];
    }
    return memories;
  }

  Future<void> refresh() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = const AsyncData(<ServerMemory>[]);
      return;
    }
    final ownership = _captureOwnership(api);
    if (ownership == null) {
      return;
    }

    state = const AsyncLoading();
    final result = await AsyncValue.guard(() => _loadMemories(api, ownership));
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) {
      return;
    }
    state = result;
  }

  /// The account that is signed in now, for a form or sheet to hold until it
  /// saves. Null when no account can own memories at the moment.
  MemoryOwner? captureOwner() {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return null;
    }
    final ownership = _captureOwnership(api);
    if (ownership == null) {
      return null;
    }
    return MemoryOwner._(api, api.captureAuthSnapshot(), ownership);
  }

  /// Whether [owner] is still the signed-in account.
  bool isCurrentOwner(MemoryOwner owner) =>
      openWebUiCacheOwnershipIsCurrent(ref, owner._ownership);

  /// Adds a memory. Entered memories are classified [type] (`user`, matching
  /// the web client) because the server would otherwise store them as context.
  ///
  /// With an [owner], throws [MemoryOwnerChangedException] instead of sending
  /// anything when that account is no longer the signed-in one.
  Future<ServerMemory> add(
    String content, {
    String type = ServerMemory.userType,
    String? path,
    MemoryOwner? owner,
  }) async {
    final operation = await _beginOperation(owner);
    final memory = await operation.api.createMemory(
      content: content,
      type: type,
      path: path,
      authSnapshot: operation.auth,
    );
    if (!openWebUiCacheOwnershipIsCurrent(ref, operation.ownership)) {
      return memory;
    }

    _replaceState([..._currentMemories(), memory]);
    return memory;
  }

  /// Updates a memory's content. [type] and [path] are sent only when given, so
  /// a content-only edit keeps whatever classification the server holds. An
  /// [owner] fences the update as in [add].
  Future<ServerMemory> updateItem(
    String memoryId,
    String content, {
    String? type,
    String? path,
    MemoryOwner? owner,
  }) async {
    final operation = await _beginOperation(owner);
    final updated = await operation.api.updateMemory(
      memoryId: memoryId,
      content: content,
      type: type,
      path: path,
      authSnapshot: operation.auth,
    );
    if (!openWebUiCacheOwnershipIsCurrent(ref, operation.ownership)) {
      return updated;
    }

    final current = _currentMemories();
    final next = _transformItemById(
      current,
      memoryId,
      (_) => updated,
      idOf: (memory) => memory.id,
    );
    _replaceState(next?.items ?? current);
    return updated;
  }

  Future<void> deleteItem(String memoryId, {MemoryOwner? owner}) async {
    final operation = await _beginOperation(owner);
    await operation.api.deleteMemory(memoryId, authSnapshot: operation.auth);
    if (!openWebUiCacheOwnershipIsCurrent(ref, operation.ownership)) {
      return;
    }

    _replaceState(
      _removeItemById(
        _currentMemories(),
        memoryId,
        idOf: (memory) => memory.id,
      ).items,
    );
  }

  Future<void> clearAll({MemoryOwner? owner}) async {
    final operation = await _beginOperation(owner);
    await operation.api.clearAllMemories(authSnapshot: operation.auth);
    if (!openWebUiCacheOwnershipIsCurrent(ref, operation.ownership)) {
      return;
    }

    state = const AsyncData(<ServerMemory>[]);
  }

  OpenWebUiCacheOwnershipSnapshot? _captureOwnership(ApiService api) {
    return captureOpenWebUiCacheOwnership(
      ref,
      api: api,
      requireAuthenticated: false,
    );
  }

  /// Admits a mutation for the account that asked for it, then confirms that
  /// account may use memories. That is the form's [owner] when it has one,
  /// otherwise whoever is signed in now. The returned auth snapshot keeps the
  /// request itself bound to that account.
  Future<_MemoryOperation> _beginOperation(MemoryOwner? owner) async {
    final ApiService api;
    final OpenWebUiCacheOwnershipSnapshot ownership;
    final ApiAuthSnapshot auth;
    if (owner != null) {
      if (!openWebUiCacheOwnershipIsCurrent(ref, owner._ownership)) {
        throw MemoryOwnerChangedException();
      }
      api = owner._api;
      ownership = owner._ownership;
      auth = owner._auth;
    } else {
      final current = ref.read(apiServiceProvider);
      if (current == null) {
        throw StateError('No API service available');
      }
      final captured = _captureOwnership(current);
      if (captured == null) {
        throw StateError('Memory ownership is unavailable');
      }
      api = current;
      ownership = captured;
      auth = current.captureAuthSnapshot();
    }

    // Asked directly rather than through memoriesPermittedProvider: awaiting
    // that provider across an account switch can leave the caller waiting on
    // a build that was already replaced.
    final permitted = await _fetchMemoriesPermitted(
      ref,
      api,
      ref.read(currentUserProvider2),
      ownership,
    );
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) {
      throw owner != null
          ? MemoryOwnerChangedException()
          : StateError('Memory ownership changed before the request');
    }
    if (!permitted) {
      throw const MemoriesNotPermittedException();
    }
    return (api: api, auth: auth, ownership: ownership);
  }

  Future<List<ServerMemory>> _loadMemories(
    ApiService api,
    OpenWebUiCacheOwnershipSnapshot ownership,
  ) async {
    final auth = api.captureAuthSnapshot();
    final permitted = await _fetchMemoriesPermitted(
      ref,
      api,
      ref.read(currentUserProvider2),
      ownership,
    );
    if (!permitted || !openWebUiCacheOwnershipIsCurrent(ref, ownership)) {
      return const <ServerMemory>[];
    }
    return _sortedMemories(await api.getMemories(authSnapshot: auth));
  }

  List<ServerMemory> _currentMemories() =>
      state.asData?.value ?? const <ServerMemory>[];

  void _replaceState(List<ServerMemory> memories) {
    state = AsyncData<List<ServerMemory>>(_sortedMemories(memories));
  }

  List<ServerMemory> _sortedMemories(List<ServerMemory> memories) {
    final sorted = [...memories];
    sorted.sort(
      (left, right) => right.updatedAtEpoch.compareTo(left.updatedAtEpoch),
    );
    return sorted;
  }
}

@Riverpod(keepAlive: true)
class AccountProfile extends _$AccountProfile {
  @override
  Future<AccountMetadata?> build() async {
    final api = ref.watch(apiServiceProvider);
    if (api == null) {
      return null;
    }
    return api.getAccountMetadata();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_loadProfile);
  }

  Future<AccountMetadata> save({
    required String name,
    required String profileImageUrl,
    String? bio,
    String? gender,
    String? dateOfBirth,
    String? timezone,
  }) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final updated = await api.updateAccountMetadata(
      name: name,
      profileImageUrl: profileImageUrl,
      bio: bio,
      gender: gender,
      dateOfBirth: dateOfBirth,
      timezone: timezone,
    );
    if (!ref.mounted) {
      return updated;
    }

    state = AsyncData(updated);
    await ref.read(authActionsProvider).refresh();
    ref.invalidate(currentUserProvider);
    return updated;
  }

  Future<void> updatePassword({
    required String password,
    required String newPassword,
  }) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }
    final authenticationEpoch = api.authenticationEpoch;
    await api.updateAccountPassword(
      password: password,
      newPassword: newPassword,
    );
    if (!ref.mounted ||
        !identical(api, ref.read(apiServiceProvider)) ||
        api.authenticationEpoch != authenticationEpoch) {
      return;
    }
    await ref.read(authStateManagerProvider.notifier).logout();
  }

  Future<AccountMetadata?> _loadProfile() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return null;
    }
    return api.getAccountMetadata();
  }
}

@Riverpod(keepAlive: true)
Future<ServerAboutInfo?> serverAboutInfo(Ref ref) async {
  ref.watch(activeServerProvider.select((s) => s.asData?.value?.id));
  final apiAlive = ref.watch(apiServiceProvider.select((a) => a != null));
  final api = ref.read(apiServiceProvider);
  if (!apiAlive || api == null) {
    return null;
  }
  return api.getServerAboutInfo();
}
