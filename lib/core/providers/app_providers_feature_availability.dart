part of 'app_providers.dart';

// Conversation Suggestions provider
@Riverpod(keepAlive: true)
Future<List<String>> conversationSuggestions(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    return await api.getSuggestions();
  } catch (e) {
    DebugLogger.error('suggestions-failed', scope: 'suggestions', error: e);
    return [];
  }
}

// Server features and permissions
@Riverpod(keepAlive: true)
Future<Map<String, dynamic>> userPermissions(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return {};

  try {
    return await api.getUserPermissions();
  } catch (e) {
    DebugLogger.error('permissions-failed', scope: 'permissions', error: e);
    return {};
  }
}

bool _coerceFeatureFlag(dynamic value, {required bool fallback}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
        return false;
    }
  }
  return fallback;
}

bool _userCanUseFeature({
  required User? user,
  required Map<String, dynamic> permissions,
  required String featureKey,
}) {
  if (user?.role == 'admin') {
    return true;
  }

  final features = permissions['features'];
  if (features is Map) {
    return _coerceFeatureFlag(features[featureKey], fallback: true);
  }

  return true;
}

bool _modelSupportsFeature(Model? model, String featureKey) {
  final metadata = model?.metadata;
  final info = metadata?['info'];
  final infoMeta = info is Map ? info['meta'] : null;
  final rootMeta = metadata?['meta'];

  for (final capabilities in <dynamic>[
    if (infoMeta is Map) infoMeta['capabilities'],
    if (rootMeta is Map) rootMeta['capabilities'],
    model?.capabilities,
  ]) {
    if (capabilities is Map && capabilities.containsKey(featureKey)) {
      return _coerceFeatureFlag(capabilities[featureKey], fallback: true);
    }
  }

  return true;
}

final imageGenerationAvailableProvider = Provider<bool>((ref) {
  final selectedModel = ref.watch(selectedModelProvider);
  final directBinding = selectedModel == null
      ? null
      : ref.watch(directModelRegistryProvider).resolve(selectedModel);
  if (selectedModel != null && hasReservedDirectIdentity(selectedModel)) {
    return directBinding?.source == DirectModelSource.device &&
        selectedModel.capabilities?['openrouter'] == true &&
        selectedModel.capabilities?['image_generation'] == true;
  }

  final perms = ref.watch(userPermissionsProvider);
  return perms.maybeWhen(
    data: (data) {
      final features = data['features'];
      if (features is Map<String, dynamic>) {
        final value = features['image_generation'];
        if (value is bool) return value;
        if (value is String) return value.toLowerCase() != 'false';
      }
      // No explicit permission — default to available. Open WebUI defaults
      // image_generation to true and the server will ignore the flag if the
      // feature is not configured.
      return true;
    },
    // Permissions unavailable (loading, error, older server) — assume available.
    orElse: () => true,
  );
});

final webSearchAvailableProvider = Provider<bool>((ref) {
  final selectedModel = ref.watch(selectedModelProvider);
  final directBinding = selectedModel == null
      ? null
      : ref.watch(directModelRegistryProvider).resolve(selectedModel);
  if (selectedModel != null && hasReservedDirectIdentity(selectedModel)) {
    // Device-owned direct models must never fall through to OpenWebUI
    // permissions. Only locally minted provider capabilities can enable a
    // Conduit-managed search path.
    final isTrustedOllamaCloud =
        directBinding?.adapterKey == kOllamaAdapterKey &&
        selectedModel.capabilities?['ollama_cloud'] == true;
    final isTrustedOpenRouter =
        directBinding?.adapterKey == kOpenAiCompatibleAdapterKey &&
        selectedModel.capabilities?['openrouter'] == true;
    return directBinding?.source == DirectModelSource.device &&
        (isTrustedOllamaCloud || isTrustedOpenRouter) &&
        selectedModel.capabilities?['web_search'] == true;
  }

  final backendConfig = ref
      .watch(backendConfigProvider)
      .maybeWhen(data: (config) => config, orElse: () => null);
  if (backendConfig?.enableWebSearch == false) {
    return false;
  }

  if (!_modelSupportsFeature(selectedModel, 'web_search')) {
    return false;
  }

  final user = ref
      .watch(currentUserProvider)
      .maybeWhen(data: (value) => value, orElse: () => null);
  final perms = ref.watch(userPermissionsProvider);
  return perms.maybeWhen(
    data: (data) => _userCanUseFeature(
      user: user,
      permissions: data,
      featureKey: 'web_search',
    ),
    // Permissions unavailable (loading, error, older server) — assume available.
    orElse: () => true,
  );
});

/// Tracks whether the folders feature is enabled on the server.
/// When the server returns 403 for folders endpoint, this becomes false.
final foldersFeatureEnabledProvider =
    NotifierProvider<FoldersFeatureEnabledNotifier, bool>(
      FoldersFeatureEnabledNotifier.new,
    );

class FoldersFeatureEnabledNotifier extends Notifier<bool> {
  _FeatureAvailabilityScope? _scope;

  @override
  bool build() {
    _scope = _featureAvailabilityScope(ref);
    return _FeatureAvailabilityCache.read('folders', scope: _scope) ?? true;
  }

  void setEnabled(bool enabled) {
    state = enabled;
    _FeatureAvailabilityCache.write('folders', enabled, scope: _scope);
  }
}

/// Tracks whether the notes feature is enabled on the server.
/// Set to false when the server returns 401 or 403 for the notes endpoint.
final notesFeatureEnabledProvider =
    NotifierProvider<NotesFeatureEnabledNotifier, bool>(
      NotesFeatureEnabledNotifier.new,
    );

class NotesFeatureEnabledNotifier extends Notifier<bool> {
  _FeatureAvailabilityScope? _scope;

  @override
  bool build() {
    _scope = _featureAvailabilityScope(ref);
    return _FeatureAvailabilityCache.read('notes', scope: _scope) ?? true;
  }

  void setEnabled(bool enabled) {
    state = enabled;
    _FeatureAvailabilityCache.write('notes', enabled, scope: _scope);
  }
}

/// Tracks whether the Channels feature is enabled on the server.
/// Set to false when the server returns 401 or 403 for the channels endpoint.
final channelsFeatureEnabledProvider =
    NotifierProvider<ChannelsFeatureEnabledNotifier, bool>(
      ChannelsFeatureEnabledNotifier.new,
    );

class ChannelsFeatureEnabledNotifier extends Notifier<bool> {
  _FeatureAvailabilityScope? _scope;

  @override
  bool build() {
    _scope = _featureAvailabilityScope(ref);
    return _FeatureAvailabilityCache.read('channels', scope: _scope) ?? true;
  }

  void setEnabled(bool enabled) {
    state = enabled;
    _FeatureAvailabilityCache.write('channels', enabled, scope: _scope);
  }
}

/// Tracks whether the Terminal feature has any available servers on the active
/// server, cached per server/user. The terminal tab's visibility is otherwise
/// derived live from [terminalAvailableServersProvider]; this cache lets the tab
/// reflect the last-known state when offline (loading/error) instead of
/// optimistically defaulting to visible — matching notes/channels behavior so a
/// server with terminal disabled doesn't surface the tab offline. The live
/// derivation lives in `terminalTabVisibleProvider` (terminal feature), which
/// writes back here via [setEnabled] whenever the server list resolves.
final terminalFeatureEnabledProvider =
    NotifierProvider<TerminalFeatureEnabledNotifier, bool>(
      TerminalFeatureEnabledNotifier.new,
    );

class TerminalFeatureEnabledNotifier extends Notifier<bool> {
  _FeatureAvailabilityScope? _scope;

  @override
  bool build() {
    _scope = _featureAvailabilityScope(ref);
    return _FeatureAvailabilityCache.read('terminal', scope: _scope) ?? true;
  }

  void setEnabled(bool enabled) {
    state = enabled;
    _FeatureAvailabilityCache.write('terminal', enabled, scope: _scope);
  }
}

_FeatureAvailabilityScope? _featureAvailabilityScope(Ref ref) {
  final activeServerId = ref.watch(
    activeServerProvider.select((value) => value.asData?.value?.id),
  );
  final serverId = activeServerId ?? _FeatureAvailabilityCache.activeServerId();
  if (serverId == null) return null;

  final userId = ref.watch(currentUserProvider2.select((user) => user?.id));
  final tokenUserId = _featureAvailabilityTokenUserId(
    ref.watch(authTokenProvider3),
  );
  if (userId != null && userId.isNotEmpty) {
    return _FeatureAvailabilityScope(
      serverId: serverId,
      userId: userId,
      fallbackUserId: tokenUserId,
    );
  }

  if (tokenUserId == null) return null;
  return _FeatureAvailabilityScope(serverId: serverId, userId: tokenUserId);
}

String? _featureAvailabilityTokenUserId(String? token) {
  final trimmed = token?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final digest = sha256.convert(utf8.encode(trimmed)).toString();
  return '__token_${digest.substring(0, 24)}';
}

final class _FeatureAvailabilityScope {
  const _FeatureAvailabilityScope({
    required this.serverId,
    required this.userId,
    this.fallbackUserId,
  });

  final String serverId;
  final String userId;
  final String? fallbackUserId;

  String get cacheKey => '$serverId::$userId';

  String? get fallbackCacheKey {
    final fallback = fallbackUserId;
    if (fallback == null || fallback == userId) return null;
    return '$serverId::$fallback';
  }
}

final class _FeatureAvailabilityCache {
  const _FeatureAvailabilityCache._();

  // The nested flag map is stored in shared_preferences as a JSON string. It's
  // read per-feature per-build, so keep the decoded map cached and only re-parse
  // when the underlying string actually changes (e.g. a write here, or an
  // external clear). Keyed by the raw string so a clearAll invalidates it.
  //
  // INVARIANT: [_cachedMap] is treated as READ-ONLY. Reads return it directly
  // (no copy); writes build a fresh deep copy, mutate that, then replace the
  // cache — so a reader can never observe (or corrupt) a half-mutated map and
  // there is no shared-nested-map hazard.
  static String? _cachedRaw;
  static Map<String, dynamic> _cachedMap = const <String, dynamic>{};

  static bool? read(String featureKey, {_FeatureAvailabilityScope? scope}) {
    if (!PreferencesStore.isReady) return null;
    final resolvedScope = scope;
    if (resolvedScope == null) return null;

    final flags = _flags();
    final value = _readFeature(flags, resolvedScope.cacheKey, featureKey);
    if (value != null) return value;

    final fallbackCacheKey = resolvedScope.fallbackCacheKey;
    if (fallbackCacheKey == null) return null;
    final fallbackValue = _readFeature(flags, fallbackCacheKey, featureKey);
    if (fallbackValue == null) return null;
    // Backfill the primary scope so the next read hits directly.
    _writeFeature({resolvedScope.cacheKey}, featureKey, fallbackValue);
    return fallbackValue;
  }

  static void write(
    String featureKey,
    bool enabled, {
    _FeatureAvailabilityScope? scope,
  }) {
    if (!PreferencesStore.isReady) return;
    final resolvedScope = scope;
    if (resolvedScope == null) return;
    _writeFeature(
      {resolvedScope.cacheKey, ?resolvedScope.fallbackCacheKey},
      featureKey,
      enabled,
    );
  }

  static String? activeServerId() {
    if (!PreferencesStore.isReady) return null;
    final value = PreferencesStore.getString(PreferenceKeys.activeServerId);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Read-only decoded flag map (cached by raw string). Callers MUST NOT mutate
  /// the returned map or its nested maps.
  static Map<String, dynamic> _flags() {
    final raw = PreferencesStore.getString(
      PreferenceKeys.serverFeatureAvailability,
    );
    if (raw == null || raw.isEmpty) {
      _cachedRaw = raw;
      _cachedMap = const <String, dynamic>{};
      return _cachedMap;
    }
    if (raw != _cachedRaw) {
      try {
        final decoded = jsonDecode(raw);
        _cachedMap = decoded is Map
            ? decoded.map((key, value) => MapEntry(key.toString(), value))
            : const <String, dynamic>{};
      } catch (_) {
        _cachedMap = const <String, dynamic>{};
      }
      _cachedRaw = raw;
    }
    return _cachedMap;
  }

  static bool? _readFeature(
    Map<String, dynamic> flags,
    String cacheKey,
    String featureKey,
  ) {
    final server = flags[cacheKey];
    if (server is! Map) return null;
    final value = server[featureKey];
    return value is bool ? value : null;
  }

  /// Sets [featureKey] = [enabled] for each of [cacheKeys] and persists. Builds
  /// ONE deep copy of the cached map, mutates it, then replaces the cache — no
  /// redundant per-key reads and no shared-nested-map aliasing.
  static void _writeFeature(
    Set<String> cacheKeys,
    String featureKey,
    bool enabled,
  ) {
    final flags = _deepCopyFlags(_flags());
    for (final cacheKey in cacheKeys) {
      final existing = flags[cacheKey];
      final serverFlags = existing is Map
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};
      serverFlags[featureKey] = enabled;
      flags[cacheKey] = serverFlags;
    }

    final encoded = jsonEncode(flags);
    _cachedRaw = encoded;
    _cachedMap = flags;
    unawaited(
      PreferencesStore.put(
        PreferenceKeys.serverFeatureAvailability,
        encoded,
      ).catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'feature-cache-write-failed',
          scope: 'features/cache',
          error: error,
          stackTrace: stackTrace,
          data: {'feature': featureKey},
        );
      }),
    );
  }

  static Map<String, dynamic> _deepCopyFlags(Map<String, dynamic> source) {
    return source.map(
      (key, value) => MapEntry(
        key,
        value is Map ? Map<String, dynamic>.from(value) : value,
      ),
    );
  }
}
