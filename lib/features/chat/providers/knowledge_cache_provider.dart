import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/knowledge_base.dart';
import '../../../core/models/knowledge_base_file.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/cache_manager.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debug_logger.dart';

/// Cache keys for knowledge base data inside one account/server scope.
const String _basesKey = 'knowledge_bases';
String _filesKey(String baseId) => 'knowledge_files:$baseId';

/// TTL for knowledge cache entries.
const Duration _knowledgeCacheTtl = Duration(minutes: 10);

/// Centralized cache manager for knowledge base data.
///
/// Uses the shared [CacheManager] pattern for TTL and LRU eviction.
class KnowledgeCacheManager {
  static const int _maxRetainedScopes = 8;
  static final KnowledgeCacheManager _instance =
      KnowledgeCacheManager._internal();
  factory KnowledgeCacheManager() => _instance;
  KnowledgeCacheManager._internal();

  final Map<_KnowledgeCacheScope, CacheManager> _scopedCaches = {};

  CacheManager? _touchExistingCache(_KnowledgeCacheScope scope) {
    final cache = _scopedCaches.remove(scope);
    if (cache != null) {
      _scopedCaches[scope] = cache;
    }
    return cache;
  }

  CacheManager _cacheFor(_KnowledgeCacheScope scope) {
    final existing = _touchExistingCache(scope);
    if (existing != null) return existing;
    while (_scopedCaches.length >= _maxRetainedScopes) {
      final oldestScope = _scopedCaches.keys.first;
      _scopedCaches.remove(oldestScope)?.clear();
    }
    final cache = CacheManager(defaultTtl: _knowledgeCacheTtl, maxEntries: 64);
    _scopedCaches[scope] = cache;
    return cache;
  }

  /// Returns cached knowledge bases, or null if not cached.
  List<KnowledgeBase>? _getCachedBases(_KnowledgeCacheScope scope) {
    final cache = _touchExistingCache(scope);
    if (cache == null) return null;
    final (hit: hit, value: bases) = cache.lookup<List<KnowledgeBase>>(
      _basesKey,
    );
    if (hit) {
      DebugLogger.log('cache-hit', scope: 'knowledge/bases');
    }
    return hit ? bases : null;
  }

  /// Caches knowledge bases.
  void _cacheBases(_KnowledgeCacheScope scope, List<KnowledgeBase> bases) {
    _cacheFor(scope).write<List<KnowledgeBase>>(_basesKey, bases);
    DebugLogger.log(
      'cache-write',
      scope: 'knowledge/bases',
      data: {'count': bases.length},
    );
  }

  /// Returns cached files for a knowledge base, or null if not cached.
  List<KnowledgeBaseFile>? _getCachedFiles(
    _KnowledgeCacheScope scope,
    String baseId,
  ) {
    final cache = _touchExistingCache(scope);
    if (cache == null) return null;
    final (hit: hit, value: files) = cache.lookup<List<KnowledgeBaseFile>>(
      _filesKey(baseId),
    );
    if (hit) {
      DebugLogger.log(
        'cache-hit',
        scope: 'knowledge/files',
        data: {'baseId': baseId},
      );
    }
    return hit ? files : null;
  }

  /// Caches files for a knowledge base.
  void _cacheFiles(
    _KnowledgeCacheScope scope,
    String baseId,
    List<KnowledgeBaseFile> files,
  ) {
    _cacheFor(scope).write<List<KnowledgeBaseFile>>(_filesKey(baseId), files);
    DebugLogger.log(
      'cache-write',
      scope: 'knowledge/files',
      data: {'baseId': baseId, 'count': files.length},
    );
  }

  /// Clears knowledge entries for one account/server owner.
  void _clearScope(_KnowledgeCacheScope scope) {
    _scopedCaches.remove(scope)?.clear();
    DebugLogger.log('cache-clear', scope: 'knowledge');
  }

  /// Clears all account/server scopes, used at an authentication boundary.
  void clear() {
    for (final cache in _scopedCaches.values) {
      cache.clear();
    }
    _scopedCaches.clear();
    DebugLogger.log('cache-clear-all', scope: 'knowledge');
  }

  /// Returns cache statistics for debugging.
  Map<String, dynamic> stats() => {
    'scopes': _scopedCaches.length,
    'entries': _scopedCaches.values.fold<int>(
      0,
      (total, cache) => total + (cache.stats()['size'] as int? ?? 0),
    ),
  };
}

final class _KnowledgeCacheScope {
  const _KnowledgeCacheScope({
    required this.serverId,
    required this.authSessionEpoch,
  });

  final String serverId;
  final Object authSessionEpoch;

  @override
  bool operator ==(Object other) =>
      other is _KnowledgeCacheScope &&
      other.serverId == serverId &&
      identical(other.authSessionEpoch, authSessionEpoch);

  @override
  int get hashCode => Object.hash(serverId, identityHashCode(authSessionEpoch));
}

/// State for the knowledge cache provider.
class KnowledgeCacheState {
  const KnowledgeCacheState({
    this.bases = const <KnowledgeBase>[],
    this.files = const <String, List<KnowledgeBaseFile>>{},
    this.isLoading = false,
  });

  final List<KnowledgeBase> bases;
  final Map<String, List<KnowledgeBaseFile>> files;
  final bool isLoading;

  KnowledgeCacheState copyWith({
    List<KnowledgeBase>? bases,
    Map<String, List<KnowledgeBaseFile>>? files,
    bool? isLoading,
  }) {
    return KnowledgeCacheState(
      bases: bases ?? this.bases,
      files: files ?? this.files,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

/// Notifier that wraps [KnowledgeCacheManager] with Riverpod reactivity.
class KnowledgeCacheNotifier extends Notifier<KnowledgeCacheState> {
  final _cacheManager = KnowledgeCacheManager();
  ApiService? _ownerApi;
  _KnowledgeCacheScope? _scope;
  int _ownerGeneration = 0;
  int _basesRequestGeneration = 0;
  int _fileRequestEpoch = 0;
  final Map<String, int> _fileRequestGenerations = {};
  Future<void>? _basesInFlight;
  Object? _basesInFlightToken;
  final Map<String, Future<void>> _filesInFlight = {};
  final Map<String, Object> _filesInFlightTokens = {};

  @override
  KnowledgeCacheState build() {
    final api = ref.watch(apiServiceProvider);
    final authSessionEpoch = ref.watch(openWebUiAuthSessionEpochProvider);
    _ownerApi = api;
    _scope = api == null
        ? null
        : _KnowledgeCacheScope(
            serverId: api.serverConfig.id,
            authSessionEpoch: authSessionEpoch,
          );
    _ownerGeneration += 1;
    _basesRequestGeneration += 1;
    _fileRequestEpoch += 1;
    _fileRequestGenerations.clear();
    _basesInFlight = null;
    _basesInFlightToken = null;
    _filesInFlight.clear();
    _filesInFlightTokens.clear();

    // Initialize from cache if available
    final scope = _scope;
    final cachedBases = scope == null
        ? null
        : _cacheManager._getCachedBases(scope);
    if (cachedBases != null && cachedBases.isNotEmpty) {
      return KnowledgeCacheState(bases: cachedBases);
    }
    return const KnowledgeCacheState();
  }

  bool _owns({
    required ApiService api,
    required _KnowledgeCacheScope scope,
    required int ownerGeneration,
  }) =>
      ref.mounted &&
      ownerGeneration == _ownerGeneration &&
      identical(_ownerApi, api) &&
      _scope == scope &&
      identical(ref.read(apiServiceProvider), api) &&
      identical(
        ref.read(openWebUiAuthSessionEpochProvider),
        scope.authSessionEpoch,
      );

  Future<void> ensureBases() {
    // Check if already loaded in state
    if (state.bases.isNotEmpty) return Future<void>.value();

    final existingRequest = _basesInFlight;
    if (existingRequest != null) return existingRequest;

    // Check cache
    final api = _ownerApi;
    final scope = _scope;
    if (api == null || scope == null) return Future<void>.value();

    final cached = _cacheManager._getCachedBases(scope);
    if (cached != null && cached.isNotEmpty) {
      state = state.copyWith(bases: cached);
      return Future<void>.value();
    }

    final ownerGeneration = _ownerGeneration;
    final requestGeneration = ++_basesRequestGeneration;
    final requestToken = Object();
    _basesInFlightToken = requestToken;
    state = state.copyWith(isLoading: true);
    final request = _loadBases(
      api: api,
      scope: scope,
      ownerGeneration: ownerGeneration,
      requestGeneration: requestGeneration,
      requestToken: requestToken,
    );
    _basesInFlight = request;
    return request;
  }

  Future<void> _loadBases({
    required ApiService api,
    required _KnowledgeCacheScope scope,
    required int ownerGeneration,
    required int requestGeneration,
    required Object requestToken,
  }) async {
    try {
      final bases = await api.getKnowledgeBases();
      if (!_owns(api: api, scope: scope, ownerGeneration: ownerGeneration) ||
          requestGeneration != _basesRequestGeneration) {
        return;
      }
      _cacheManager._cacheBases(scope, bases);
      state = state.copyWith(bases: bases, isLoading: false);
    } catch (_) {
      if (_owns(api: api, scope: scope, ownerGeneration: ownerGeneration) &&
          requestGeneration == _basesRequestGeneration) {
        state = state.copyWith(isLoading: false);
      }
    } finally {
      if (identical(_basesInFlightToken, requestToken)) {
        _basesInFlight = null;
        _basesInFlightToken = null;
      }
    }
  }

  Future<void> fetchFilesForBase(String baseId) {
    if (state.files.containsKey(baseId)) return Future<void>.value();

    final existingRequest = _filesInFlight[baseId];
    if (existingRequest != null) return existingRequest;

    final api = _ownerApi;
    final scope = _scope;
    if (api == null || scope == null) return Future<void>.value();

    final cached = _cacheManager._getCachedFiles(scope, baseId);
    if (cached != null) {
      final next = Map<String, List<KnowledgeBaseFile>>.from(state.files);
      next[baseId] = cached;
      state = state.copyWith(files: next);
      return Future<void>.value();
    }

    final ownerGeneration = _ownerGeneration;
    final requestEpoch = _fileRequestEpoch;
    final requestGeneration = (_fileRequestGenerations[baseId] ?? 0) + 1;
    _fileRequestGenerations[baseId] = requestGeneration;
    final requestToken = Object();
    _filesInFlightTokens[baseId] = requestToken;
    final request = _loadFilesForBase(
      baseId: baseId,
      api: api,
      scope: scope,
      ownerGeneration: ownerGeneration,
      requestEpoch: requestEpoch,
      requestGeneration: requestGeneration,
      requestToken: requestToken,
    );
    _filesInFlight[baseId] = request;
    return request;
  }

  Future<void> _loadFilesForBase({
    required String baseId,
    required ApiService api,
    required _KnowledgeCacheScope scope,
    required int ownerGeneration,
    required int requestEpoch,
    required int requestGeneration,
    required Object requestToken,
  }) async {
    try {
      final files = await api.getAllKnowledgeBaseFiles(baseId);
      if (!_owns(api: api, scope: scope, ownerGeneration: ownerGeneration) ||
          requestEpoch != _fileRequestEpoch ||
          _fileRequestGenerations[baseId] != requestGeneration) {
        return;
      }
      _cacheManager._cacheFiles(scope, baseId, files);
      final next = Map<String, List<KnowledgeBaseFile>>.from(state.files);
      next[baseId] = files;
      state = state.copyWith(files: next);
    } catch (error, stackTrace) {
      if (!_owns(api: api, scope: scope, ownerGeneration: ownerGeneration) ||
          requestEpoch != _fileRequestEpoch ||
          _fileRequestGenerations[baseId] != requestGeneration) {
        return;
      }
      DebugLogger.error(
        'files-load-failed',
        scope: 'knowledge/files',
        error: error,
        stackTrace: stackTrace,
        data: {'baseId': baseId},
      );
      final next = Map<String, List<KnowledgeBaseFile>>.from(state.files);
      next[baseId] = const <KnowledgeBaseFile>[];
      state = state.copyWith(files: next);
    } finally {
      if (identical(_filesInFlightTokens[baseId], requestToken)) {
        _filesInFlight.remove(baseId);
        _filesInFlightTokens.remove(baseId);
      }
    }
  }

  /// Clears both in-memory state and cache for the current owner.
  void clearCache() {
    final scope = _scope;
    if (scope != null) {
      _cacheManager._clearScope(scope);
    }
    _resetRequestFences();
  }

  void _resetRequestFences() {
    _basesRequestGeneration += 1;
    _fileRequestEpoch += 1;
    _fileRequestGenerations.clear();
    _basesInFlight = null;
    _basesInFlightToken = null;
    _filesInFlight.clear();
    _filesInFlightTokens.clear();
    state = const KnowledgeCacheState();
  }

  /// Clears every account/server scope at a sign-out boundary.
  void clearAllCaches() {
    _cacheManager.clear();
    _resetRequestFences();
  }
}

final knowledgeCacheProvider =
    NotifierProvider<KnowledgeCacheNotifier, KnowledgeCacheState>(
      KnowledgeCacheNotifier.new,
    );
