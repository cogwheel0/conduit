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
      _cachePinnedModelsLocally(updated.pinnedModelIds);
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
    _cachePinnedModelsLocally(settings.pinnedModelIds);
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

  void _cachePinnedModelsLocally(List<String> modelIds) {
    final local = ref.read(appSettingsProvider).pinnedModels;
    if (const ListEquality<Object?>().equals(local, modelIds)) {
      return;
    }

    unawaited(
      Future<void>.microtask(() async {
        if (!ref.mounted) {
          return;
        }
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

@Riverpod(keepAlive: true)
class UserMemories extends _$UserMemories {
  @override
  Future<List<ServerMemory>> build() async {
    ref.watch(activeServerProvider.select((s) => s.asData?.value?.id));
    final apiAlive = ref.watch(apiServiceProvider.select((a) => a != null));
    final api = ref.read(apiServiceProvider);
    if (!apiAlive || api == null) {
      return const <ServerMemory>[];
    }
    return _sortedMemories(await api.getMemories());
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_loadMemories);
  }

  Future<ServerMemory> add(String content) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final memory = await api.createMemory(content: content);
    if (!ref.mounted) {
      return memory;
    }

    _replaceState([..._currentMemories(), memory]);
    return memory;
  }

  Future<ServerMemory> updateItem(String memoryId, String content) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final updated = await api.updateMemory(
      memoryId: memoryId,
      content: content,
    );
    if (!ref.mounted) {
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

  Future<void> deleteItem(String memoryId) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    await api.deleteMemory(memoryId);
    if (!ref.mounted) {
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

  Future<void> clearAll() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    await api.clearAllMemories();
    if (!ref.mounted) {
      return;
    }

    state = const AsyncData(<ServerMemory>[]);
  }

  Future<List<ServerMemory>> _loadMemories() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return const <ServerMemory>[];
    }
    return _sortedMemories(await api.getMemories());
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
