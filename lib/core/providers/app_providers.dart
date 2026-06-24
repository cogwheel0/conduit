import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../services/api_service.dart';
import '../auth/auth_state_manager.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../services/attachment_upload_queue.dart';
import '../models/server_config.dart';
import '../models/user.dart';
import '../models/model.dart';
import '../models/conversation.dart';
import '../models/chat_message.dart';
import '../models/account_metadata.dart';
import '../models/backend_config.dart';
import '../models/folder.dart';
import '../models/file_info.dart';
import '../models/server_about_info.dart';
import '../models/server_memory.dart';
import '../models/server_user_settings.dart';
import '../models/tool.dart';
import '../models/user_settings.dart';
import '../models/knowledge_base.dart';
import '../services/settings_service.dart';
import '../services/optimized_storage_service.dart';
import '../services/socket_service.dart';
import '../services/connectivity_service.dart';
import '../persistence/preferences_store.dart';
import '../persistence/persistence_keys.dart';
import '../utils/debug_logger.dart';
import '../services/worker_manager.dart';
import '../../shared/theme/tweakcn_themes.dart';
import '../../shared/theme/app_theme.dart';
import '../../features/tools/providers/tools_providers.dart';
import '../models/socket_transport_availability.dart';
import 'storage_providers.dart';
import 'package:drift/drift.dart' show Value;
import '../database/database_provider.dart';
import '../database/local_conversation_loader.dart';
import '../database/mappers/conversation_assembler.dart';
import '../sync/chat_locks.dart';
import '../sync/sync_engine.dart';

export 'storage_providers.dart';

part 'app_providers.g.dart';

// Theme provider
@Riverpod(keepAlive: true)
class AppThemeMode extends _$AppThemeMode {
  late final OptimizedStorageService _storage;

  @override
  ThemeMode build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final storedMode = _storage.getThemeMode();
    if (storedMode != null) {
      return ThemeMode.values.firstWhere(
        (e) => e.toString() == storedMode,
        orElse: () => ThemeMode.system,
      );
    }
    return ThemeMode.system;
  }

  void setTheme(ThemeMode mode) {
    state = mode;
    _storage.setThemeMode(mode.toString());
  }
}

@Riverpod(keepAlive: true)
class AppThemePalette extends _$AppThemePalette {
  late final OptimizedStorageService _storage;

  @override
  TweakcnThemeDefinition build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final storedId = _storage.getThemePaletteId();
    return TweakcnThemes.byId(storedId);
  }

  Future<void> setPalette(String paletteId) async {
    final palette = TweakcnThemes.byId(paletteId);
    state = palette;
    await _storage.setThemePaletteId(palette.id);
  }
}

@Riverpod(keepAlive: true)
class AppLightTheme extends _$AppLightTheme {
  @override
  ThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.light(palette);
  }
}

@Riverpod(keepAlive: true)
class AppDarkTheme extends _$AppDarkTheme {
  @override
  ThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.dark(palette);
  }
}

@Riverpod(keepAlive: true)
class AppCupertinoLightTheme extends _$AppCupertinoLightTheme {
  @override
  CupertinoThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.cupertinoLight(palette);
  }
}

@Riverpod(keepAlive: true)
class AppCupertinoDarkTheme extends _$AppCupertinoDarkTheme {
  @override
  CupertinoThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.cupertinoDark(palette);
  }
}

// Locale provider
@Riverpod(keepAlive: true)
class AppLocale extends _$AppLocale {
  late final OptimizedStorageService _storage;

  @override
  Locale? build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final code = _storage.getLocaleCode();
    if (code != null && code.isNotEmpty) {
      final parsed = _parseLocaleCode(code);
      if (parsed != null) return parsed;
    }
    return null; // system default
  }

  Future<void> setLocale(Locale? locale) async {
    state = locale;
    await _storage.setLocaleCode(locale?.toLanguageTag());
  }

  Locale? _parseLocaleCode(String code) {
    final normalized = code.replaceAll('_', '-');
    final parts = normalized.split('-');
    if (parts.isEmpty || parts.first.isEmpty) return null;

    final language = parts.first;
    String? script;
    String? country;

    for (var i = 1; i < parts.length; i++) {
      final part = parts[i];
      if (part.length == 4) {
        script = '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}';
      } else if (part.length == 2 || part.length == 3) {
        country = part.toUpperCase();
      }
    }

    return Locale.fromSubtags(
      languageCode: language,
      scriptCode: script,
      countryCode: country,
    );
  }
}

// Server connection providers - optimized with caching
@Riverpod(keepAlive: true)
Future<List<ServerConfig>> serverConfigs(Ref ref) async {
  final storage = ref.watch(optimizedStorageServiceProvider);
  return storage.getServerConfigs();
}

@Riverpod(keepAlive: true)
Future<ServerConfig?> activeServer(Ref ref) async {
  final storage = ref.watch(optimizedStorageServiceProvider);
  final configs = await ref.watch(serverConfigsProvider.future);
  final activeId = await storage.getActiveServerId();

  if (configs.isEmpty) return null;

  ServerConfig? fallback;
  for (final config in configs) {
    if (activeId != null && config.id == activeId) {
      return config;
    }
    if (fallback == null && config.isActive) {
      fallback = config;
    }
  }
  fallback ??= configs.length == 1 ? configs.first : null;
  if (fallback == null) return null;

  await storage.setActiveServerId(fallback.id);
  return fallback.isActive ? fallback : fallback.copyWith(isActive: true);
}

final serverConnectionStateProvider = Provider<bool>((ref) {
  final activeServer = ref.watch(activeServerProvider);
  return activeServer.maybeWhen(
    data: (server) => server != null,
    orElse: () => false,
  );
});

@Riverpod(keepAlive: true)
class BackendConfigNotifier extends _$BackendConfigNotifier {
  late final OptimizedStorageService _storage;

  @override
  Future<BackendConfig?> build() async {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final cached = await _storage.getLocalBackendConfig();
    unawaited(_refreshBackendConfig());
    return cached;
  }

  Future<void> refresh() => _refreshBackendConfig();

  Future<void> _refreshBackendConfig() async {
    final fresh = await _loadBackendConfig(ref);
    if (fresh == null || !ref.mounted) {
      return;
    }

    state = AsyncData(fresh);
    await _storage.saveLocalBackendConfig(fresh);

    // Persist resolved transport options based on backend config
    if (!ref.mounted) return;
    final options = _resolveTransportAvailability(fresh);
    await _storage.saveLocalTransportOptions(options);
  }
}

Future<BackendConfig?> _loadBackendConfig(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return null;
  }

  final server = await ref.watch(activeServerProvider.future);
  if (server == null) {
    return null;
  }

  try {
    final config = await api.getBackendConfig();
    if (config != null) {
      final forcedMode = config.enforcedTransportMode;
      if (forcedMode != null) {
        final settings = ref.read(appSettingsProvider);
        if (settings.socketTransportMode != forcedMode) {
          Future.microtask(() {
            ref
                .read(appSettingsProvider.notifier)
                .setSocketTransportMode(forcedMode);
          });
        }
      }
    }
    return config;
  } catch (_) {
    return null;
  }
}

/// Provides resolved socket transport options based on backend configuration.
///
/// This is a synchronous provider that:
/// - Returns cached transport options when backend config is not yet loaded
/// - Derives transport options from backend config once available
/// - Does NOT perform side effects (persistence is handled by BackendConfigNotifier)
///
/// The persistence of resolved options happens asynchronously when the
/// backend config is refreshed, ensuring the sync provider remains pure.
final socketTransportOptionsProvider = Provider<SocketTransportAvailability>((
  ref,
) {
  final storage = ref.watch(optimizedStorageServiceProvider);
  // Watch async backend config for proper invalidation
  final backendConfigAsync = ref.watch(backendConfigProvider);
  final config = backendConfigAsync.maybeWhen(
    data: (value) => value,
    orElse: () => null,
  );

  if (config == null) {
    // Return cached value or defaults when config not available
    return storage.getLocalTransportOptionsSync() ??
        const SocketTransportAvailability(
          allowPolling: true,
          allowWebsocketOnly: true,
        );
  }

  // Determine transport availability from backend config
  return _resolveTransportAvailability(config);
});

// API Service provider with unified auth integration
final apiServiceProvider = Provider<ApiService?>((ref) {
  // If reviewer mode is enabled, skip creating ApiService
  final reviewerMode = ref.watch(reviewerModeProvider);
  if (reviewerMode) {
    return null;
  }
  final activeServer = ref.watch(activeServerProvider);
  final workerManager = ref.watch(workerManagerProvider);

  return activeServer.maybeWhen(
    data: (server) {
      if (server == null) return null;

      final apiService = ApiService(
        serverConfig: server,
        workerManager: workerManager,
        authToken: null, // Will be set by auth state manager
      );

      // Keep callbacks in sync so interceptor can notify auth manager
      apiService.setAuthCallbacks(
        onAuthTokenInvalid: () {
          // Called when auth errors occur (401/403)
          // Show connection issue page instead of logging out
          final authManager = ref.read(authStateManagerProvider.notifier);
          authManager.onAuthIssue();
        },
        onTokenInvalidated: () async {
          // Called for token expiry - attempt silent re-login
          final authManager = ref.read(authStateManagerProvider.notifier);
          await authManager.onTokenInvalidated();
        },
      );

      // Set up callback for unified auth state manager
      // (legacy properties kept during transition)
      apiService.onTokenInvalidated = () async {
        final authManager = ref.read(authStateManagerProvider.notifier);
        await authManager.onTokenInvalidated();
      };

      // Keep legacy callback for backward compatibility during transition
      apiService.onAuthTokenInvalid = () {
        // Show connection issue page instead of logging out
        final authManager = ref.read(authStateManagerProvider.notifier);
        authManager.onAuthIssue();
      };

      return apiService;
    },
    orElse: () => null,
  );
});

// Socket.IO service provider
@Riverpod(keepAlive: true)
class SocketServiceManager extends _$SocketServiceManager {
  SocketService? _service;
  ProviderSubscription<String?>? _tokenSubscription;
  ProviderSubscription<ConnectivityStatus>? _connectivitySubscription;
  int _connectToken = 0;

  /// The current live service, available even while [build] is re-running (the
  /// async provider is briefly `loading` on every rebuild). [socketServiceProvider]
  /// falls back to this so the socket doesn't momentarily read as `null` — which
  /// would otherwise drop consumers to HTTP-only sends mid-session. Null only
  /// when there is genuinely no service (reviewer mode / no active server /
  /// disposed).
  SocketService? get currentService => _service;

  @override
  FutureOr<SocketService?> build() async {
    final reviewerMode = ref.watch(reviewerModeProvider);
    if (reviewerMode) {
      _disposeService();
      return null;
    }

    final server = await ref.watch(activeServerProvider.future);
    if (server == null) {
      _disposeService();
      return null;
    }

    final transportMode = ref.watch(
      appSettingsProvider.select((settings) => settings.socketTransportMode),
    );
    final websocketOnly = transportMode == 'ws';
    final transportAvailability = ref.watch(socketTransportOptionsProvider);
    final allowWebsocketUpgrade = transportAvailability.allowWebsocketOnly;

    // Don't watch authTokenProvider3 here to avoid rebuilding on token changes
    // Token updates are handled via the subscription below
    final token = ref.read(authTokenProvider3);

    final requiresNewService =
        _service == null ||
        _service!.serverConfig.id != server.id ||
        _service!.websocketOnly != websocketOnly ||
        _service!.allowWebsocketUpgrade != allowWebsocketUpgrade;
    if (requiresNewService) {
      _disposeService();
      _service = SocketService(
        serverConfig: server,
        authToken: token,
        websocketOnly: websocketOnly,
        allowWebsocketUpgrade: allowWebsocketUpgrade,
      );
      _scheduleConnect(_service!);
    } else {
      _service!.updateAuthToken(token);
    }

    _tokenSubscription ??= ref.listen<String?>(authTokenProvider3, (
      previous,
      next,
    ) {
      _service?.updateAuthToken(next);
    });

    // Listen to connectivity changes to proactively manage socket connection.
    // When network goes offline, we can save resources by not attempting
    // reconnections. When network comes back, we force a reconnect.
    _connectivitySubscription ??= ref.listen<ConnectivityStatus>(
      connectivityStatusProvider,
      (previous, next) {
        final service = _service;
        if (service == null) return;

        if (next == ConnectivityStatus.offline) {
          // Network is offline - socket will handle its own disconnection
          // via the underlying transport. We just log it for debugging.
          DebugLogger.log(
            'Connectivity offline - socket may disconnect',
            scope: 'socket/provider',
          );
        } else if (previous == ConnectivityStatus.offline &&
            next == ConnectivityStatus.online) {
          // Network just came back online - force reconnect to restore socket
          DebugLogger.log(
            'Connectivity restored - forcing socket reconnect',
            scope: 'socket/provider',
          );
          unawaited(service.connect(force: true));
        }
      },
    );

    ref.onDispose(() {
      _tokenSubscription?.close();
      _tokenSubscription = null;
      _connectivitySubscription?.close();
      _connectivitySubscription = null;
      _disposeService();
    });

    return _service;
  }

  void _scheduleConnect(SocketService service) {
    final token = ++_connectToken;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!ref.mounted) return;
      if (_connectToken != token) return;
      if (!identical(_service, service)) return;
      try {
        unawaited(service.connect());
      } catch (_) {}
    });
  }

  void _disposeService() {
    _connectToken++;
    if (_service == null) return;
    try {
      _service!.dispose();
    } catch (_) {}
    _service = null;
  }
}

final socketServiceProvider = Provider<SocketService?>((ref) {
  final asyncService = ref.watch(socketServiceManagerProvider);
  // While the manager re-runs its async `build` (on any watched-dependency
  // change), it is briefly `loading`; don't collapse the live socket to `null`
  // then — that churns consumers and forces HTTP-only sends. Fall back to the
  // manager's current service during loading/error; it's only truly null when
  // there is no active server / reviewer mode / it was disposed.
  return asyncService.maybeWhen(
    data: (service) => service,
    orElse: () => ref.read(socketServiceManagerProvider.notifier).currentService,
  );
});

// Attachment upload queue provider
final attachmentUploadQueueProvider = Provider<AttachmentUploadQueue?>((ref) {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return null;

  final queue = AttachmentUploadQueue();
  // Re-runs when the API (and thus active server) changes, reloading the queue
  // from the active server's Drift table.
  queue.initialize(
    onUpload: (filePath, fileName, {cancelToken}) =>
        api.uploadFile(filePath, fileName, cancelToken: cancelToken),
    database: () => ref.read(appDatabaseProvider),
  );

  return queue;
});

// Auth providers
// Auth token integration with API service - using unified auth system
final apiTokenUpdaterProvider = Provider<void>((ref) {
  void syncToken(ApiService? api, String? token) {
    if (api == null) return;
    api.updateAuthToken(token != null && token.isNotEmpty ? token : null);
    final length = token?.length ?? 0;
    DebugLogger.auth(
      'token-updated',
      scope: 'auth/api',
      data: {'length': length},
    );
  }

  syncToken(ref.read(apiServiceProvider), ref.read(authTokenProvider3));

  ref.listen<ApiService?>(apiServiceProvider, (previous, next) {
    syncToken(next, ref.read(authTokenProvider3));
  });

  ref.listen<String?>(authTokenProvider3, (previous, next) {
    syncToken(ref.read(apiServiceProvider), next);
  });
});

@Riverpod(keepAlive: true)
Future<User?> currentUser(Ref ref) async {
  final api = ref.read(apiServiceProvider);
  final authState = ref.watch(authStateManagerProvider);
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

  // Next: try cached user from storage, then refresh in the background.
  final storage = ref.read(optimizedStorageServiceProvider);
  final cachedUser = await _getCachedUserWithAvatar(storage);
  if (cachedUser != null) {
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
  if (fresh != null) {
    ref.read(_lastUserRefreshProvider.notifier).set(DateTime.now());
  }
  return fresh;
}

Future<User?> _getCachedUserWithAvatar(OptimizedStorageService storage) async {
  final cachedUser = await storage.getLocalUser();
  if (cachedUser == null) return null;
  final cachedAvatar = await storage.getLocalUserAvatar();
  if (cachedAvatar == null ||
      cachedAvatar.isEmpty ||
      cachedUser.profileImage == cachedAvatar) {
    return cachedUser;
  }
  return cachedUser.copyWith(profileImage: cachedAvatar);
}

Future<User?> _refreshCurrentUser(Ref ref) async {
  final api = ref.read(apiServiceProvider);
  if (api == null) return null;

  try {
    final user = await api.getCurrentUser();
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.saveLocalUser(user);
    if (user.profileImage != null && user.profileImage!.isNotEmpty) {
      await storage.saveLocalUserAvatar(user.profileImage);
    }
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

// Model providers
@Riverpod(keepAlive: true)
class Models extends _$Models {
  @override
  Future<List<Model>> build() async {
    // Reviewer mode returns mock models
    if (ref.watch(reviewerModeProvider)) {
      return _demoModels();
    }

    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'models');
      _persistModelsAsync(const <Model>[]);
      return const [];
    }

    final storage = ref.watch(optimizedStorageServiceProvider);
    try {
      final cached = await storage.getLocalModels();
      if (cached.isNotEmpty) {
        final visibleCached = _visibleModels(cached);
        DebugLogger.log(
          'cache-restored',
          scope: 'models/cache',
          data: {
            'count': visibleCached.length,
            'hidden': cached.length - visibleCached.length,
          },
        );
        if (visibleCached.length != cached.length) {
          _persistModelsAsync(visibleCached);
        }
        Future.microtask(() async {
          try {
            await refresh();
          } catch (error, stackTrace) {
            DebugLogger.error(
              'warm-refresh-failed',
              scope: 'models/cache',
              error: error,
              stackTrace: stackTrace,
            );
          }
        });
        return visibleCached;
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'cache-load-failed',
        scope: 'models/cache',
        error: error,
        stackTrace: stackTrace,
      );
    }

    final api = ref.watch(apiServiceProvider);
    if (api == null) {
      DebugLogger.warning('api-missing', scope: 'models');
      _persistModelsAsync(const <Model>[]);
      return const [];
    }

    final fresh = await _load(api);
    return fresh;
  }

  Future<void> refresh() async {
    if (ref.read(reviewerModeProvider)) {
      state = AsyncData<List<Model>>(_demoModels());
      return;
    }
    if (!ref.read(isAuthenticatedProvider2)) {
      state = const AsyncData<List<Model>>(<Model>[]);
      _persistModelsAsync(const <Model>[]);
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = const AsyncData<List<Model>>(<Model>[]);
      _persistModelsAsync(const <Model>[]);
      return;
    }
    final result = await AsyncValue.guard(() => _load(api));
    if (!ref.mounted) return;
    state = result;

    // Update selected model with fresh data (e.g., filters) if it exists
    // in the new models list
    if (result.hasValue) {
      final freshModels = result.value!;
      final currentSelected = ref.read(selectedModelProvider);
      if (currentSelected != null) {
        if (currentSelected.isHidden) {
          return;
        }
        try {
          final freshModel = freshModels.firstWhere(
            (m) => m.id == currentSelected.id,
          );
          // Update selected model with fresh data (filters, etc.)
          if (freshModel != currentSelected) {
            ref.read(selectedModelProvider.notifier).set(freshModel);
            DebugLogger.log(
              'selected-model-refreshed',
              scope: 'models',
              data: {
                'id': freshModel.id,
                'filters': freshModel.filters?.length ?? 0,
              },
            );
          }
        } catch (_) {
          final replacement = freshModels.isNotEmpty ? freshModels.first : null;
          ref.read(isManualModelSelectionProvider.notifier).set(false);
          ref.read(selectedModelProvider.notifier).set(replacement);
          DebugLogger.warning(
            'selected-model-unavailable',
            scope: 'models',
            data: {'id': currentSelected.id, 'replacement': replacement?.id},
          );
        }
      }
    }
  }

  Future<List<Model>> _load(ApiService api) async {
    try {
      DebugLogger.log('fetch-start', scope: 'models');
      final models = await api.getModels();
      final visibleModels = _visibleModels(models);
      DebugLogger.log(
        'fetch-ok',
        scope: 'models',
        data: {
          'count': visibleModels.length,
          'hidden': models.length - visibleModels.length,
        },
      );
      _persistModelsAsync(visibleModels);
      return visibleModels;
    } catch (e, stackTrace) {
      DebugLogger.error(
        'fetch-failed',
        scope: 'models',
        error: e,
        stackTrace: stackTrace,
      );

      // If models endpoint returns 403, this should now clear auth token
      // and redirect user to login since it's marked as a core endpoint
      if (e.toString().contains('403')) {
        DebugLogger.warning('endpoint-403', scope: 'models');
      }

      return const [];
    }
  }

  List<Model> _visibleModels(List<Model> models) {
    if (models.isEmpty) return const <Model>[];
    return models.where((model) => !model.isHidden).toList();
  }

  void _persistModelsAsync(List<Model> models) {
    final storage = ref.read(optimizedStorageServiceProvider);
    unawaited(
      storage.saveLocalModels(models).onError((error, stack) {
        DebugLogger.error(
          'Failed to persist models to cache',
          scope: 'models/cache',
          error: error,
          stackTrace: stack,
        );
      }),
    );
  }

  List<Model> _demoModels() => const [
    Model(
      id: 'demo/gemma-2-mini',
      name: 'Gemma 2 Mini (Demo)',
      description: 'Demo model for reviewer mode',
      isMultimodal: true,
      supportsStreaming: true,
      supportedParameters: ['max_tokens', 'stream'],
    ),
    Model(
      id: 'demo/llama-3-8b',
      name: 'Llama 3 8B (Demo)',
      description: 'Fast text model for demo',
      isMultimodal: false,
      supportsStreaming: true,
      supportedParameters: ['max_tokens', 'stream'],
    ),
  ];
}

@Riverpod(keepAlive: true)
class SelectedModel extends _$SelectedModel {
  @override
  Model? build() => null;

  void set(Model? model, {bool allowHidden = false}) {
    if (model?.isHidden == true && !allowHidden) {
      state = null;
      return;
    }
    state = model;
  }

  void clear() => state = null;
}

/// Tracks a pending folder ID for the next new conversation.
///
/// When a user starts a new chat from within a folder context menu,
/// this provider holds the folder ID so that the conversation is
/// automatically placed in that folder upon creation.
@Riverpod(keepAlive: true)
class PendingFolderId extends _$PendingFolderId {
  @override
  String? build() => null;

  void set(String? folderId) => state = folderId;

  void clear() => state = null;
}

// Track if the current model selection is manual (user-selected) or automatic (default)
@Riverpod(keepAlive: true)
class IsManualModelSelection extends _$IsManualModelSelection {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

// Auto-apply model-specific tools when model changes or tools load
final modelToolsAutoSelectionProvider = Provider<void>((ref) {
  // Prevent disposal so listeners remain active throughout app lifecycle
  ref.keepAlive();

  Future<void> applyTools(Model? model) async {
    List<String> preserveDirectServerSelections(List<String> ids) {
      return ids.where((id) => id.startsWith('direct_server:')).toList();
    }

    // Skip if not authenticated - prevents API calls after logout
    final authState = ref.read(authStateManagerProvider).asData?.value;
    if (authState == null || !authState.isAuthenticated) {
      final current = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(current);
      if (!listEquals(current, preserved)) {
        ref.read(selectedToolIdsProvider.notifier).set(preserved);
      }
      return;
    }

    if (model == null) {
      final current = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(current);
      if (!listEquals(current, preserved)) {
        ref.read(selectedToolIdsProvider.notifier).set(preserved);
      }
      return;
    }

    final modelToolIds = model.toolIds ?? [];
    if (modelToolIds.isEmpty) {
      final current = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(current);
      if (!listEquals(current, preserved)) {
        ref.read(selectedToolIdsProvider.notifier).set(preserved);
      }
      return;
    }

    void updateSelection(List<Tool> availableTools) {
      final validToolIds = modelToolIds
          .where((id) => availableTools.any((tool) => tool.id == id))
          .toList();

      final currentSelection = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(currentSelection);
      final nextSelection = [...validToolIds, ...preserved];
      if (validToolIds.isEmpty) {
        if (!listEquals(currentSelection, preserved)) {
          ref.read(selectedToolIdsProvider.notifier).set(preserved);
        }
        return;
      }
      if (listEquals(currentSelection, nextSelection)) return;

      ref.read(selectedToolIdsProvider.notifier).set(nextSelection);
      DebugLogger.log(
        'auto-apply-tools',
        scope: 'models/tools',
        data: {'modelId': model.id, 'toolCount': validToolIds.length},
      );
    }

    final toolsAsync = ref.read(toolsListProvider);
    if (toolsAsync.hasValue) {
      updateSelection(toolsAsync.value ?? const <Tool>[]);
      return;
    }

    try {
      final availableTools = await ref.read(toolsListProvider.future);
      if (!ref.mounted) return;
      updateSelection(availableTools);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'auto-apply-tools-failed',
        scope: 'models/tools',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> scheduleApply(Model? model) async {
    await applyTools(model);
  }

  Future.microtask(() => scheduleApply(ref.read(selectedModelProvider)));

  ref.listen<Model?>(selectedModelProvider, (previous, next) {
    if (previous?.id == next?.id && previous != null) {
      return;
    }
    Future.microtask(() => scheduleApply(next));
  });

  ref.listen(toolsListProvider, (previous, next) {
    if (!next.hasValue) return;
    Future.microtask(() => scheduleApply(ref.read(selectedModelProvider)));
  });
});

// Auto-apply model-specific terminal defaults when model changes.
final modelTerminalAutoSelectionProvider = Provider<void>((ref) {
  ref.keepAlive();

  String? extractModelTerminalId(Model? model) {
    final info = model?.metadata?['info'];
    if (info is! Map) {
      return null;
    }

    final infoMeta = info['meta'];
    if (infoMeta is! Map) {
      return null;
    }

    final terminalId = infoMeta['terminalId']?.toString().trim();
    if (terminalId == null || terminalId.isEmpty) {
      return null;
    }

    return terminalId;
  }

  void applyTerminalSelection(Model? model) {
    final terminalId = extractModelTerminalId(model);
    if (terminalId == null) {
      return;
    }

    if (ref.read(selectedTerminalIdProvider) == terminalId) {
      return;
    }

    ref.read(selectedTerminalIdProvider.notifier).set(terminalId);
    DebugLogger.log(
      'auto-apply-terminal',
      scope: 'models/terminal',
      data: {'modelId': model?.id},
    );
  }

  Future.microtask(
    () => applyTerminalSelection(ref.read(selectedModelProvider)),
  );

  ref.listen<Model?>(selectedModelProvider, (previous, next) {
    Future.microtask(() => applyTerminalSelection(next));
  });
});

// Auto-clear invalid filter selections when model changes
// Filters are model-specific, so we need to validate selections against new model
final modelFiltersAutoSelectionProvider = Provider<void>((ref) {
  // Prevent disposal so listeners remain active throughout app lifecycle
  ref.keepAlive();

  void validateFilters(Model? model) {
    final currentFilterIds = ref.read(selectedFilterIdsProvider);
    if (currentFilterIds.isEmpty) return;

    // Get available filters from the model
    final availableFilters = model?.filters ?? const [];
    final validFilterIds = availableFilters.map((f) => f.id).toSet();

    // Filter out any selected IDs that aren't valid for this model
    final validSelection = currentFilterIds
        .where((id) => validFilterIds.contains(id))
        .toList();

    // Only update if something changed
    if (validSelection.length != currentFilterIds.length) {
      ref.read(selectedFilterIdsProvider.notifier).set(validSelection);
      DebugLogger.log(
        'filter-selection-validated',
        scope: 'models/filters',
        data: {
          'modelId': model?.id,
          'previousCount': currentFilterIds.length,
          'validCount': validSelection.length,
        },
      );
    }
  }

  // Validate on model change
  ref.listen<Model?>(selectedModelProvider, (previous, next) {
    if (previous?.id == next?.id && previous != null) {
      return;
    }
    Future.microtask(() => validateFilters(next));
  });
});

// Auto-apply default model from settings when it changes (and not manually overridden)
// keepAlive to maintain listener throughout app lifecycle
final defaultModelAutoSelectionProvider = Provider<void>((ref) {
  // Prevent disposal so listeners remain active throughout app lifecycle
  ref.keepAlive();

  // Initialize the model tools and filters auto-selection
  ref.watch(modelToolsAutoSelectionProvider);
  ref.watch(modelTerminalAutoSelectionProvider);
  ref.watch(modelFiltersAutoSelectionProvider);

  ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
    // Only react when default model value changes
    if (previous?.defaultModel == next.defaultModel) return;

    // Reset manual selection flag when default model setting changes
    ref.read(isManualModelSelectionProvider.notifier).set(false);

    final desired = next.defaultModel;

    // If auto-select (null), invalidate defaultModelProvider to re-fetch server default
    if (desired == null || desired.isEmpty) {
      DebugLogger.log('auto-select-enabled', scope: 'models/default');
      ref.invalidate(defaultModelProvider);
      // Trigger re-read to apply server default
      Future(() async {
        try {
          await ref.read(defaultModelProvider.future);
        } catch (e) {
          DebugLogger.error(
            'auto-select-failed',
            scope: 'models/default',
            error: e,
          );
        }
      });
      return;
    }

    // Resolve the desired model against available models (by ID only)
    Future(() async {
      try {
        // Prefer already-loaded models to avoid unnecessary fetches
        List<Model> models;
        final modelsAsync = ref.read(modelsProvider);
        if (modelsAsync.hasValue) {
          models = modelsAsync.value!;
        } else {
          models = await ref.read(modelsProvider.future);
        }
        Model? selected;
        try {
          selected = models.firstWhere((model) => model.id == desired);
        } catch (_) {
          selected = null;
        }

        final current = ref.read(selectedModelProvider);
        if (selected == null &&
            current != null &&
            !current.isHidden &&
            models.any((model) => model.id == current.id)) {
          selected = models.firstWhere((model) => model.id == current.id);
        }

        selected ??= models.isNotEmpty ? models.first : null;

        if (selected != null) {
          ref.read(selectedModelProvider.notifier).set(selected);
          DebugLogger.log(
            'auto-apply',
            scope: 'models/default',
            data: {'name': selected.name},
          );
        }
      } catch (e) {
        DebugLogger.error(
          'auto-select-failed',
          scope: 'models/default',
          error: e,
        );
      }
    });
  });
});

/// Requests a debounced pull cycle from the sync engine and invalidates the
/// folder summary caches after the pull has had a chance to write rows
/// (CDT-RFC-001 Phase 1: every refresh path converges on the engine; Drift
/// streams deliver the resulting UI updates).
void refreshConversationsCache(dynamic ref, {bool includeFolders = false}) {
  final folderConversationRefresh = ref.read(
    _folderConversationRefreshTickProvider.notifier,
  );
  unawaited(
    Future<void>(() async {
      await ref
          .read(syncEngineProvider.notifier)
          .requestPull(reason: 'cache-refresh');
      folderConversationRefresh.bumpIfMounted();
    }).catchError((Object error, StackTrace stackTrace) {
      DebugLogger.error(
        'refresh-cache-failed',
        scope: 'conversations',
        error: error,
        stackTrace: stackTrace,
      );
    }),
  );
}

typedef _UpdatedItem<T> = ({List<T> items, T item});
typedef _RemovedItems<T> = ({List<T> items, bool didRemove});

DateTime? _latestDateTime(DateTime? left, DateTime? right) {
  if (left == null) return right;
  if (right == null) return left;
  return right.isAfter(left) ? right : left;
}

List<T> _upsertItemById<T>(
  List<T> current,
  T item, {
  required String Function(T item) idOf,
}) {
  final updated = <T>[...current];
  final itemId = idOf(item);
  final index = updated.indexWhere((existing) => idOf(existing) == itemId);
  if (index >= 0) {
    updated[index] = item;
  } else {
    updated.add(item);
  }
  return updated;
}

_UpdatedItem<T>? _transformItemById<T>(
  List<T> current,
  String id,
  T Function(T item) transform, {
  required String Function(T item) idOf,
}) {
  final index = current.indexWhere((existing) => idOf(existing) == id);
  if (index < 0) {
    return null;
  }
  final updated = <T>[...current];
  final transformed = transform(updated[index]);
  updated[index] = transformed;
  return (items: updated, item: transformed);
}

_RemovedItems<T> _removeItemById<T>(
  List<T> current,
  String id, {
  required String Function(T item) idOf,
}) {
  final updated = <T>[...current];
  final index = updated.indexWhere((existing) => idOf(existing) == id);
  if (index >= 0) {
    updated.removeAt(index);
  }
  return (items: updated, didRemove: index >= 0);
}

/// Server-style epoch seconds for envelope writes derived from model
/// timestamps (which round-trip epoch seconds themselves).
int _epochSecondsOf(DateTime dateTime) =>
    dateTime.millisecondsSinceEpoch ~/ 1000;

// Conversation list provider — Drift-backed read path (CDT-RFC-001 Phase 1).
//
// The list renders from `ChatsDao.watchChatList()` (a narrow projection that
// never selects message bodies). Mutators keep their synchronous in-memory
// update for snappiness and write the same envelope change to the database in
// the same call, so the next stream emission always agrees with the
// optimistic state.
@Riverpod(keepAlive: true)
class Conversations extends _$Conversations {
  /// Every chat row is local now; pagination is permanently exhausted.
  bool hasMoreRegularChats() => false;
  bool isLoadingMoreRegularChats() => false;

  @override
  Future<List<Conversation>> build() async {
    final authed = ref.watch(isAuthenticatedProvider2);
    if (!authed) {
      DebugLogger.log('skip-unauthed', scope: 'conversations');
      return const [];
    }

    if (ref.watch(reviewerModeProvider)) {
      return _demoConversations();
    }

    final db = ref.watch(appDatabaseProvider);
    if (db == null) {
      return const [];
    }

    final completer = Completer<List<Conversation>>();
    // Cold-start instrumentation (CDT-RFC-001 §10 Budget 1): time from build()
    // start to the FIRST narrow-projection emission. Numeric-only data (no chat
    // content) so nothing untrusted is logged.
    final coldStart = Stopwatch()..start();
    final subscription = db.chatsDao.watchChatList().listen(
      (entries) {
        final conversations = List<Conversation>.unmodifiable(
          entries.map(conversationFromListEntry),
        );
        if (!completer.isCompleted) {
          coldStart.stop();
          DebugLogger.log(
            'cold-start-ms',
            scope: 'perf/list',
            data: {'ms': coldStart.elapsedMilliseconds, 'rows': entries.length},
          );
          completer.complete(conversations);
          return;
        }
        if (ref.mounted) {
          state = AsyncData<List<Conversation>>(conversations);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'watch-failed',
          scope: 'conversations',
          error: error,
          stackTrace: stackTrace,
        );
        if (!completer.isCompleted) {
          completer.complete(const <Conversation>[]);
        }
      },
    );
    ref.onDispose(subscription.cancel);
    return completer.future;
  }

  /// Refreshing is a pull request; the database stream delivers the result.
  /// Folders are part of every pull cycle, so [includeFolders] needs no extra
  /// work.
  Future<void> refresh({
    bool includeFolders = false,
    bool forceFresh = false,
  }) async {
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    await ref.read(syncEngineProvider.notifier).requestPull(reason: 'refresh');
    folderConversationRefresh.bumpIfMounted();
  }

  /// All chats are local rows; nothing to page in.
  Future<void> loadMore() async {}

  void removeConversation(String id) {
    final current = state.asData?.value;
    if (current != null) {
      final removal = _removeItemById(
        current,
        id,
        idOf: (conversation) => conversation.id,
      );
      if (removal.didRemove) {
        _replaceState(removal.items);
      }
    }
    // Caller already deleted the chat server-side; drop the local row.
    final db = ref.read(appDatabaseProvider);
    if (db == null || isTemporaryChat(id)) return;
    final locks = ref.read(chatLocksProvider);
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    unawaited(
      locks
          .runExclusive(id, () => db.chatsDao.hardDelete(id))
          .then((_) => folderConversationRefresh.bumpIfMounted())
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'row-delete-failed',
              scope: 'conversations',
              error: error,
              stackTrace: stackTrace,
              data: {'id': id},
            );
          }),
    );
  }

  void upsertConversation(
    Conversation conversation, {
    bool trustFolderConversation = false,
  }) {
    final current = state.asData?.value ?? const <Conversation>[];
    final existingIndex = current.indexWhere(
      (item) => item.id == conversation.id,
    );
    final existing = existingIndex >= 0 ? current[existingIndex] : null;
    final preparedConversation = existing == null
        ? conversation
        : conversation.copyWith(
            lastReadAt: _latestDateTime(
              existing.lastReadAt,
              conversation.lastReadAt,
            ),
          );
    _replaceState(
      _upsertItemById(current, preparedConversation, idOf: (item) => item.id),
    );
    _writeEnvelopeStub(preparedConversation);
  }

  void upsertConversations(
    Iterable<Conversation> conversations, {
    bool trustFolderConversations = false,
  }) {
    for (final conversation in conversations) {
      upsertConversation(conversation);
    }
  }

  void updateConversation(
    String id,
    Conversation Function(Conversation conversation) transform, {
    bool trustFolderConversation = false,
  }) {
    final current = state.asData?.value;
    final update = current == null
        ? null
        : _transformItemById(
            current,
            id,
            transform,
            idOf: (conversation) => conversation.id,
          );
    if (update == null) {
      // The chat list stream has not loaded yet, or this id is absent from the
      // loaded projection. Request a reconcile pull so the server-confirmed
      // envelope mutation is not lost (mirrors Folders.updateFolder).
      _requestConversationReconcilePull(
        action: current == null ? 'update-cold' : 'update-missing',
      );
      return;
    }
    _replaceState(update.items);
    _writeEnvelopeUpdate(update.item);
  }

  void _requestConversationReconcilePull({required String action}) {
    DebugLogger.log(
      'reconcile-after-remote-mutation',
      scope: 'conversations',
      data: {'action': action},
    );
    unawaited(
      ref
          .read(syncEngineProvider.notifier)
          .requestPull(reason: 'conversations-reconcile')
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'reconcile-pull-failed',
              scope: 'conversations',
              error: error,
              stackTrace: stackTrace,
              data: {'action': action},
            );
            return null;
          }),
    );
  }

  void markConversationRead(String id, DateTime readAt) {
    if (id.isEmpty) return;
    final current = state.asData?.value;
    if (current != null) {
      final update = _transformItemById(current, id, (conversation) {
        final existing = conversation.lastReadAt;
        if (existing != null && !readAt.isAfter(existing)) {
          return conversation;
        }
        return conversation.copyWith(lastReadAt: readAt);
      }, idOf: (conversation) => conversation.id);
      if (update != null) {
        _replaceState(update.items);
      }
    }
    final db = ref.read(appDatabaseProvider);
    if (db == null || isTemporaryChat(id)) return;
    // Pre-existing UI-only read marks come from the device clock; the DAO's
    // max() rule means the column is never lowered and the value never enters
    // watermark logic.
    unawaited(
      db.chatsDao.setLastReadAt(id, _epochSecondsOf(readAt)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DebugLogger.error(
          'read-mark-failed',
          scope: 'conversations',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
      }),
    );
  }

  /// Applies a server-confirmed conversation summary mutation.
  void updateConversationFromRemote(
    String id,
    Conversation Function(Conversation conversation) transform,
  ) {
    updateConversation(id, transform);
  }

  /// Rows are id-keyed in the database; the summary "trust" machinery is
  /// obsolete. Kept as a frozen no-op for callers.
  void trustConversation(String id) {}

  void _replaceState(List<Conversation> conversations) {
    state = AsyncData<List<Conversation>>(_sortByUpdatedAt(conversations));
  }

  void _writeEnvelopeStub(Conversation conversation) {
    final db = ref.read(appDatabaseProvider);
    if (db == null || isTemporaryChat(conversation.id)) return;
    final lastReadAt = conversation.lastReadAt;
    // ChatLocks discipline: every write touching one chat's rows serializes
    // through the per-chat mutex so a stale optimistic stub can never be
    // ordered after (and overwrite) a concurrent locked pull merge.
    final locks = ref.read(chatLocksProvider);
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    unawaited(
      locks
          .runExclusive(conversation.id, () {
            return db.chatsDao.upsertEnvelopeStub(
              id: conversation.id,
              title: conversation.title,
              createdAt: _epochSecondsOf(conversation.createdAt),
              updatedAt: _epochSecondsOf(conversation.updatedAt),
              pinned: conversation.pinned,
              archived: conversation.archived,
              folderId: Value(conversation.folderId),
              lastReadAt: lastReadAt == null
                  ? null
                  : _epochSecondsOf(lastReadAt),
            );
          })
          .then((_) => folderConversationRefresh.bumpIfMounted())
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'envelope-stub-failed',
              scope: 'conversations',
              error: error,
              stackTrace: stackTrace,
              data: {'id': conversation.id},
            );
          }),
    );
  }

  void _writeEnvelopeUpdate(Conversation conversation) {
    final db = ref.read(appDatabaseProvider);
    if (db == null || isTemporaryChat(conversation.id)) return;
    final locks = ref.read(chatLocksProvider);
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    unawaited(
      locks
          .runExclusive(conversation.id, () {
            return db.chatsDao.updateEnvelope(
              conversation.id,
              title: Value(conversation.title),
              folderId: Value(conversation.folderId),
              pinned: Value(conversation.pinned),
              archived: Value(conversation.archived),
              updatedAt: Value(_epochSecondsOf(conversation.updatedAt)),
            );
          })
          .then((_) => folderConversationRefresh.bumpIfMounted())
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'envelope-update-failed',
              scope: 'conversations',
              error: error,
              stackTrace: stackTrace,
              data: {'id': conversation.id},
            );
          }),
    );
  }

  List<Conversation> _sortByUpdatedAt(List<Conversation> conversations) {
    final sorted = [...conversations];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<Conversation>.unmodifiable(sorted);
  }

  List<Conversation> _demoConversations() => [
    Conversation(
      id: 'demo-conv-1',
      title: 'Welcome to Conduit (Demo)',
      createdAt: DateTime.now().subtract(const Duration(minutes: 15)),
      updatedAt: DateTime.now().subtract(const Duration(minutes: 10)),
      messages: [
        ChatMessage(
          id: 'demo-msg-1',
          role: 'assistant',
          content:
              '**Welcome to Conduit Demo Mode**\n\nThis is a demo for app review - responses are pre-written, not from real AI.\n\nTry these features:\n• Send messages\n• Attach images\n• Use voice input\n• Switch models (tap header)\n• Create new chats (menu)\n\nAll features work offline. No server needed.',
          timestamp: DateTime.now().subtract(const Duration(minutes: 10)),
          model: 'Gemma 2 Mini (Demo)',
          isStreaming: false,
        ),
      ],
    ),
  ];
}

final _folderConversationRefreshTickProvider =
    NotifierProvider<_FolderConversationRefreshTick, int>(
      _FolderConversationRefreshTick.new,
    );

class _FolderConversationRefreshTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;

  void bumpIfMounted() {
    if (!ref.mounted) return;
    bump();
  }
}

/// Loads folder conversation summaries from the local database
/// (CDT-RFC-001 Phase 1: per-folder server fetches are gone; pull sync keeps
/// the rows fresh and `_folderConversationRefreshTickProvider` invalidates
/// after pulls and mutations).
final folderConversationSummariesProvider =
    FutureProvider.family<List<Conversation>, String>((ref, folderId) async {
      ref.watch(_folderConversationRefreshTickProvider);

      if (!ref.watch(isAuthenticatedProvider2) ||
          ref.watch(reviewerModeProvider)) {
        return const <Conversation>[];
      }

      final db = ref.watch(appDatabaseProvider);
      if (db == null) {
        return const <Conversation>[];
      }

      final entries = await db.chatsDao.getChatsInFolder(folderId);
      return entries.map(conversationFromListEntry).toList(growable: false);
    });

/// Whether the current chat session is temporary (not persisted to server).
///
/// When true, conversations use `local:{socketId}` IDs and skip all
/// server persistence. Resets on app restart unless the user has
/// `temporaryChatByDefault` enabled in settings.
@riverpod
class TemporaryChatEnabled extends _$TemporaryChatEnabled {
  @override
  bool build() {
    // Use ref.read (not watch) so settings changes don't reset
    // the ephemeral toggle state mid-conversation.
    final settings = ref.read(appSettingsProvider);
    return settings.temporaryChatByDefault;
  }

  void set(bool value) => state = value;
}

/// Returns true if the given conversation ID represents a temporary chat.
bool isTemporaryChat(String? id) => id != null && id.startsWith('local:');

void markConversationRead(
  dynamic ref,
  String? conversationId, {
  DateTime? readAt,
}) {
  final id = conversationId?.trim();
  if (id == null || id.isEmpty || isTemporaryChat(id)) {
    return;
  }

  final timestamp = readAt ?? DateTime.now();
  try {
    ref
        .read(conversationsProvider.notifier)
        .markConversationRead(id, timestamp);
  } catch (_) {}

  try {
    final active = ref.read(activeConversationProvider);
    if (active?.id == id) {
      final current = active!.lastReadAt;
      if (current == null || timestamp.isAfter(current)) {
        ref
            .read(activeConversationProvider.notifier)
            .set(active.copyWith(lastReadAt: timestamp));
      }
    }
  } catch (_) {}

  try {
    ref.read(socketServiceProvider)?.emit('events:chat', {
      'chat_id': id,
      'data': {'type': 'last_read_at'},
    });
  } catch (_) {}
}

final activeConversationProvider =
    NotifierProvider<ActiveConversationNotifier, Conversation?>(
      ActiveConversationNotifier.new,
    );

@immutable
class ActiveConversationInPlaceRemap {
  const ActiveConversationInPlaceRemap({
    required this.fromId,
    required this.toId,
  });

  final String fromId;
  final String toId;

  bool matches(String? previousId, String? nextId) =>
      previousId == fromId && nextId == toId;
}

final activeConversationInPlaceRemapProvider =
    NotifierProvider<
      ActiveConversationInPlaceRemapNotifier,
      ActiveConversationInPlaceRemap?
    >(ActiveConversationInPlaceRemapNotifier.new);

class ActiveConversationInPlaceRemapNotifier
    extends Notifier<ActiveConversationInPlaceRemap?> {
  @override
  ActiveConversationInPlaceRemap? build() => null;

  void mark({required String fromId, required String toId}) {
    state = ActiveConversationInPlaceRemap(fromId: fromId, toId: toId);
  }
}

bool isActiveConversationInPlaceRemap(
  dynamic ref,
  String? previousId,
  String? nextId,
) {
  try {
    return ref
            .read(activeConversationInPlaceRemapProvider)
            ?.matches(previousId, nextId) ??
        false;
  } catch (_) {
    return false;
  }
}

class ActiveConversationNotifier extends Notifier<Conversation?> {
  @override
  Conversation? build() => null;

  void set(Conversation? conversation) => state = conversation;

  void remapIdInPlace({required String fromId, required String toId}) {
    final current = state;
    if (current == null || current.id != fromId) return;
    ref
        .read(activeConversationInPlaceRemapProvider.notifier)
        .mark(fromId: fromId, toId: toId);
    state = current.copyWith(id: toId);
  }

  void clear() => state = null;
}

// Provider to load full conversation with messages
@riverpod
Future<Conversation> loadConversation(Ref ref, String conversationId) async {
  // DB-first open (CDT-RFC-001 Phase 1): synced rows render without the
  // network; a background pull freshens them.
  final local = await loadLocalConversation(ref, conversationId);
  if (local != null) {
    DebugLogger.log(
      'load-local-ok',
      scope: 'conversation',
      data: {'id': conversationId, 'messages': local.messages.length},
    );
    schedulePullChatNow(ref, conversationId);
    return local;
  }

  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    throw Exception('No API service available');
  }

  DebugLogger.log(
    'load-start',
    scope: 'conversation',
    data: {'id': conversationId},
  );
  final fullConversation = await api.getConversation(conversationId);
  DebugLogger.log(
    'load-ok',
    scope: 'conversation',
    data: {'messages': fullConversation.messages.length},
  );
  // Materialize the local row so the next open is DB-first.
  schedulePullChatNow(ref, conversationId);

  return fullConversation;
}

// Provider to automatically load and set the default model from user settings or OpenWebUI
@Riverpod(keepAlive: true)
Future<Model?> defaultModel(Ref ref) async {
  DebugLogger.log('provider-called', scope: 'models/default');

  final storage = ref.read(optimizedStorageServiceProvider);
  // Read settings without subscribing to rebuilds to avoid watch/await hazards
  final reviewerMode = ref.read(reviewerModeProvider);
  if (reviewerMode) {
    DebugLogger.log('reviewer-mode', scope: 'models/default');
    // Check if a model is manually selected
    final currentSelected = ref.read(selectedModelProvider);
    final isManualSelection = ref.read(isManualModelSelectionProvider);

    if (currentSelected != null && isManualSelection) {
      DebugLogger.log(
        'manual',
        scope: 'models/default',
        data: {'name': currentSelected.name},
      );
      return currentSelected;
    }

    // Get demo models and select the first one
    final models = await ref.read(modelsProvider.future);
    if (!ref.mounted) return null;
    if (models.isNotEmpty) {
      final defaultModel = models.first;
      if (!ref.read(isManualModelSelectionProvider)) {
        ref.read(selectedModelProvider.notifier).set(defaultModel);
        DebugLogger.log(
          'auto-select',
          scope: 'models/default',
          data: {'name': defaultModel.name},
        );
      }
      return defaultModel;
    }
    DebugLogger.warning('no-demo-models', scope: 'models/default');
    return null;
  }

  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    DebugLogger.warning('no-api', scope: 'models/default');
    return null;
  }

  DebugLogger.log('api-available', scope: 'models/default');

  try {
    // Respect manual selection if present
    if (ref.read(isManualModelSelectionProvider)) {
      final current = ref.read(selectedModelProvider);
      if (current != null && !current.isHidden) return current;
      ref.read(isManualModelSelectionProvider.notifier).set(false);
      ref.read(selectedModelProvider.notifier).clear();
    }

    // 1) Priority: app-local default model preference.
    final settingsDefaultId = ref.read(appSettingsProvider).defaultModel;
    final storedDefaultId =
        settingsDefaultId ??
        await SettingsService.getDefaultModel().catchError((_) => null);
    if (!ref.mounted) return null;

    if (storedDefaultId != null && storedDefaultId.isNotEmpty) {
      final cachedMatch = await selectCachedModel(storage, storedDefaultId);
      if (!ref.mounted) return null;
      if (cachedMatch != null && !ref.read(isManualModelSelectionProvider)) {
        ref.read(selectedModelProvider.notifier).set(cachedMatch);
        unawaited(
          storage.saveLocalDefaultModel(cachedMatch).catchError((_) {}),
        );
        DebugLogger.log(
          'settings-default',
          scope: 'models/default',
          data: {'name': cachedMatch.name, 'source': 'settings'},
        );
        return cachedMatch;
      }
    }

    // 2) Fallback: cached resolved default model (offline/fast startup).
    try {
      final cached = await storage.getLocalDefaultModel();
      if (!ref.mounted) return null;
      if (cached != null && !ref.read(isManualModelSelectionProvider)) {
        final cachedMatch = await selectCachedModel(storage, cached.id);
        if (!ref.mounted) return null;
        if (cachedMatch == null) {
          await storage.saveLocalDefaultModel(null);
        } else {
          ref.read(selectedModelProvider.notifier).set(cachedMatch);
          DebugLogger.log(
            'cached-default',
            scope: 'models/default',
            data: {'name': cachedMatch.name},
          );
          return cachedMatch;
        }
      }
    } catch (_) {}

    // 3) Fallback: server-provided automatic resolution when no app-local
    // preference exists.
    try {
      final serverDefault = await api.getDefaultModel();
      if (!ref.mounted) return null;
      if (serverDefault != null && serverDefault.isNotEmpty) {
        final models = await api.getModels();
        if (!ref.mounted) return null;
        Model? resolved;
        try {
          resolved = models.firstWhere((m) => m.id == serverDefault);
        } catch (_) {
          final byName = models.where((m) => m.name == serverDefault).toList();
          if (byName.length == 1) resolved = byName.first;
        }
        resolved ??= models.isNotEmpty ? models.first : null;

        if (resolved != null && !ref.read(isManualModelSelectionProvider)) {
          ref.read(selectedModelProvider.notifier).set(resolved);
          unawaited(
            storage.saveLocalDefaultModel(resolved).onError((error, stack) {
              DebugLogger.error(
                'Failed to save default model to cache',
                scope: 'models/default',
                error: error,
                stackTrace: stack,
              );
            }),
          );
          DebugLogger.log(
            'server-default',
            scope: 'models/default',
            data: {'name': resolved.name},
          );
          return resolved;
        }
      }
    } catch (_) {}

    // 4) Fallback: fetch models and pick first available
    DebugLogger.log('fallback-path', scope: 'models/default');
    final models = await ref.read(modelsProvider.future);
    if (!ref.mounted) return null;
    DebugLogger.log(
      'models-loaded',
      scope: 'models/default',
      data: {'count': models.length},
    );
    if (models.isEmpty) {
      DebugLogger.warning('no-models', scope: 'models/default');
      return null;
    }
    final selectedModel = models.first;
    if (!ref.read(isManualModelSelectionProvider)) {
      ref.read(selectedModelProvider.notifier).set(selectedModel);
      unawaited(
        storage.saveLocalDefaultModel(selectedModel).onError((error, stack) {
          DebugLogger.error(
            'Failed to save default model to cache',
            scope: 'models/default',
            error: error,
            stackTrace: stack,
          );
        }),
      );
      DebugLogger.log(
        'fallback-selected',
        scope: 'models/default',
        data: {'name': selectedModel.name, 'id': selectedModel.id},
      );
    } else {
      DebugLogger.log('skip-manual-override', scope: 'models/default');
    }
    return selectedModel;
  } catch (e) {
    DebugLogger.error('set-default-failed', scope: 'models/default', error: e);
    return null;
  }
}

// Background model loading provider that doesn't block UI
// This just schedules the loading, doesn't wait for it
final backgroundModelLoadProvider = Provider<void>((ref) {
  // Ensure API token updater is initialized
  ref.watch(apiTokenUpdaterProvider);

  // Watch auth state to trigger model loading when authenticated
  final navState = ref.watch(authNavigationStateProvider);
  if (navState != AuthNavigationState.authenticated) {
    DebugLogger.log('skip-not-authed', scope: 'models/background');
    return;
  }

  // Use a flag to prevent multiple concurrent loads
  var isLoading = false;

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (isLoading) return;
    isLoading = true;

    // Schedule background loading without blocking startup frame
    Future.microtask(() async {
      // Reduced delay for faster startup model selection
      await Future.delayed(const Duration(milliseconds: 100));

      if (!ref.mounted) {
        DebugLogger.log('cancelled-unmounted', scope: 'models/background');
        return;
      }

      DebugLogger.log('bg-start', scope: 'models/background');
      try {
        final model = await ref.read(defaultModelProvider.future);
        if (!ref.mounted) {
          DebugLogger.log('complete-unmounted', scope: 'models/background');
          return;
        }
        DebugLogger.log(
          'bg-complete',
          scope: 'models/background',
          data: {'model': model?.name ?? 'null'},
        );
      } catch (e) {
        DebugLogger.error('bg-failed', scope: 'models/background', error: e);
      } finally {
        isLoading = false;
      }
    });
  });

  return;
});

// Search query provider
@Riverpod(keepAlive: true)
class SearchQuery extends _$SearchQuery {
  @override
  String build() => '';

  void set(String query) => state = query;
}

/// Offline full-text search over the synced Drift history (CDT-RFC-001 Phase 4).
///
/// Runs ranked FTS5 search via [SearchDao.search] and maps the hits to the same
/// list-summary [Conversation] shape the server search returns, so callers can
/// treat online and offline results identically. Returns `[]` when there is no
/// active database (no server / reviewer mode) or before the index is built
/// (the DAO short-circuits on the `fts_built` gate). Results are already bm25
/// ascending (most relevant first); order is preserved.
Future<List<Conversation>> _offlineSearch(Ref ref, String query) async {
  final db = ref.read(appDatabaseProvider);
  if (db == null) return const [];
  try {
    final hits = await db.searchDao.search(query, limit: 50);
    return hits.map(conversationFromSearchHit).toList(growable: false);
  } catch (e) {
    DebugLogger.error('offline-search-failed', scope: 'search', error: e);
    return const [];
  }
}

// Server-side search provider for chats, with an offline FTS5 fallback.
@riverpod
Future<List<Conversation>> serverSearch(Ref ref, String query) async {
  final trimmedQuery = query.trim();
  if (trimmedQuery.isEmpty) {
    // Return empty list for empty query instead of all conversations
    return [];
  }

  if (ref.watch(reviewerModeProvider)) {
    final conversations =
        ref.watch(conversationsProvider).asData?.value ??
        const <Conversation>[];
    final lowerQuery = trimmedQuery.toLowerCase();
    return conversations
        .where((conversation) {
          return conversation.title.toLowerCase().contains(lowerQuery) ||
              conversation.messages.any(
                (message) => message.content.toLowerCase().contains(lowerQuery),
              );
        })
        .toList(growable: false);
  }

  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    // Offline: serve ranked results straight from the local
    // FTS index over synced history (CDT-RFC-001 Phase 4 acceptance).
    DebugLogger.log('offline-search', scope: 'search');
    return _offlineSearch(ref, trimmedQuery);
  }

  try {
    DebugLogger.log(
      'server-search',
      scope: 'search',
      data: {'length': trimmedQuery.length},
    );

    // Use the new server-side search API
    final chatHits = await api.searchChats(
      query: trimmedQuery,
      archived: false, // Only search non-archived conversations
      limit: 50,
      sortBy: 'updated_at',
      sortOrder: 'desc',
    );
    // chatHits is already List<Conversation>
    final List<Conversation> conversations = List.of(chatHits);

    // Perform message-level search and merge chat hits
    try {
      final messageHits = await api.searchMessages(
        query: trimmedQuery,
        limit: 100,
      );

      // Build a set of conversation IDs already present from chat search
      final existingIds = conversations.map((c) => c.id).toSet();

      // Extract chat ids from message hits (supporting multiple key casings)
      final messageChatIds = <String>{};
      for (final hit in messageHits) {
        final chatId =
            (hit['chat_id'] ?? hit['chatId'] ?? hit['chatID']) as String?;
        if (chatId != null && chatId.isNotEmpty) {
          messageChatIds.add(chatId);
        }
      }

      // Determine which chat ids we still need to fetch
      final idsToFetch = messageChatIds
          .where((id) => !existingIds.contains(id))
          .toList();

      // Fetch conversations for those ids in parallel (cap to avoid overload)
      const maxFetch = 50;
      final fetchList = idsToFetch.take(maxFetch).toList();
      if (fetchList.isNotEmpty) {
        DebugLogger.log(
          'fetch-from-messages',
          scope: 'search',
          data: {'count': fetchList.length},
        );
        final fetched = await Future.wait(
          fetchList.map((id) async {
            try {
              return await api.getConversation(id);
            } catch (_) {
              return null;
            }
          }),
        );

        // Merge fetched conversations
        for (final conv in fetched) {
          if (conv != null && !existingIds.contains(conv.id)) {
            conversations.add(conv);
            existingIds.add(conv.id);
          }
        }

        // Optional: sort by updated date desc to keep results consistent
        conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      }
    } catch (e) {
      DebugLogger.error('message-search-failed', scope: 'search', error: e);
    }

    DebugLogger.log(
      'server-results',
      scope: 'search',
      data: {'count': conversations.length},
    );
    return conversations;
  } catch (e) {
    DebugLogger.error('server-search-failed', scope: 'search', error: e);

    // Fallback to the offline FTS index when the server search fails. This is a
    // ranked search across ALL synced history (not just the in-memory page),
    // matching the offline path (CDT-RFC-001 Phase 4).
    DebugLogger.log('fallback-offline', scope: 'search');
    return _offlineSearch(ref, trimmedQuery);
  }
}

final filteredConversationsProvider = Provider<List<Conversation>>((ref) {
  final conversations = ref.watch(conversationsProvider);
  final query = ref.watch(searchQueryProvider);

  // Use server-side search when there's a query
  if (query.trim().isNotEmpty) {
    final searchResults = ref.watch(serverSearchProvider(query));
    return searchResults.maybeWhen(
      data: (results) => results,
      loading: () {
        // While server search is loading, show local filtered results
        return conversations.maybeWhen(
          data: (convs) => convs.where((conv) {
            return !conv.archived &&
                (conv.title.toLowerCase().contains(query.toLowerCase()) ||
                    conv.messages.any(
                      (msg) => msg.content.toLowerCase().contains(
                        query.toLowerCase(),
                      ),
                    ));
          }).toList(),
          orElse: () => [],
        );
      },
      error: (_, stackTrace) {
        // On error, fallback to local search
        return conversations.maybeWhen(
          data: (convs) => convs.where((conv) {
            return !conv.archived &&
                (conv.title.toLowerCase().contains(query.toLowerCase()) ||
                    conv.messages.any(
                      (msg) => msg.content.toLowerCase().contains(
                        query.toLowerCase(),
                      ),
                    ));
          }).toList(),
          orElse: () => [],
        );
      },
      orElse: () => [],
    );
  }

  // When no search query, show all non-archived conversations
  return conversations.maybeWhen(
    data: (convs) {
      if (ref.watch(reviewerModeProvider)) {
        return convs; // Already filtered above for demo
      }
      // Filter out archived conversations (they should be in a separate view)
      final filtered = convs.where((conv) => !conv.archived).toList();

      // Sort: pinned conversations first, then by updated date
      filtered.sort((a, b) {
        // Pinned conversations come first
        if (a.pinned && !b.pinned) return -1;
        if (!a.pinned && b.pinned) return 1;

        // Within same pin status, sort by updated date (newest first)
        return b.updatedAt.compareTo(a.updatedAt);
      });

      return filtered;
    },
    orElse: () => [],
  );
});

// Provider for archived conversations
final archivedConversationsProvider = Provider<List<Conversation>>((ref) {
  final conversations = ref.watch(conversationsProvider);

  return conversations.maybeWhen(
    data: (convs) {
      if (ref.watch(reviewerModeProvider)) {
        return convs.where((c) => c.archived).toList();
      }
      // Only show archived conversations
      final archived = convs.where((conv) => conv.archived).toList();

      // Sort by updated date (newest first)
      archived.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      return archived;
    },
    orElse: () => [],
  );
});

// Reviewer mode provider (persisted)
@Riverpod(keepAlive: true)
class ReviewerMode extends _$ReviewerMode {
  late final OptimizedStorageService _storage;
  bool _initialized = false;

  @override
  bool build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    if (!_initialized) {
      _initialized = true;
      Future.microtask(_load);
    }
    return false;
  }

  Future<void> _load() async {
    final enabled = await _storage.getReviewerMode();
    if (!ref.mounted) {
      return;
    }
    state = enabled;
  }

  Future<void> setEnabled(bool enabled) async {
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
    if (listEquals(local, modelIds)) {
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
    await api.updateAccountPassword(
      password: password,
      newPassword: newPassword,
    );
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

/// Cached [PackageInfo] for About screens and native profile sheets.
final packageInfoProvider = FutureProvider<PackageInfo>((ref) async {
  return PackageInfo.fromPlatform();
});

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
  final backendConfig = ref
      .watch(backendConfigProvider)
      .maybeWhen(data: (config) => config, orElse: () => null);
  if (backendConfig?.enableWebSearch == false) {
    return false;
  }

  final selectedModel = ref.watch(selectedModelProvider);
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

final codeInterpreterAvailableProvider = Provider<bool>((ref) {
  final selectedModel = ref.watch(selectedModelProvider);
  if (!_modelSupportsFeature(selectedModel, 'code_interpreter')) {
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
      featureKey: 'code_interpreter',
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

// Folders provider — Drift-backed read path (CDT-RFC-001 Phase 1). Renders
// from `FoldersDao.watchFolders()`; server-confirmed mutations land in memory
// and in the database in the same call so the next emission agrees.
// `foldersFeatureEnabledProvider` is now set by the SyncEngine from
// PullResult.
@Riverpod(keepAlive: true)
class Folders extends _$Folders {
  @override
  Future<List<Folder>> build() async {
    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'folders');
      return const [];
    }

    final db = ref.watch(appDatabaseProvider);
    if (db == null) {
      return const [];
    }

    final completer = Completer<List<Folder>>();
    final subscription = db.foldersDao.watchFolders().listen(
      (rows) {
        final folders = _sort([for (final row in rows) folderFromRow(row)]);
        if (!completer.isCompleted) {
          completer.complete(folders);
          return;
        }
        if (ref.mounted) {
          state = AsyncData<List<Folder>>(folders);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'watch-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
        );
        if (!completer.isCompleted) {
          completer.complete(const <Folder>[]);
        }
      },
    );
    ref.onDispose(subscription.cancel);
    return completer.future;
  }

  Future<void> refresh({bool forceFresh = false}) async {
    await ref
        .read(syncEngineProvider.notifier)
        .requestPull(reason: 'folders-refresh');
  }

  Future<void> warmIfNeeded() async {
    await ref
        .read(syncEngineProvider.notifier)
        .requestPull(reason: 'folders-warm');
  }

  void upsertFolder(Folder folder) {
    _replaceState(
      _upsertItemById(
        state.asData?.value ?? const <Folder>[],
        folder,
        idOf: (item) => item.id,
      ),
    );
    _persistFolder(folder);
  }

  /// Applies a server-confirmed folder upsert.
  void upsertFolderFromRemote(Folder folder) => upsertFolder(folder);

  void updateFolder(String id, Folder Function(Folder folder) transform) {
    final current = state.asData?.value;
    final update = current == null
        ? null
        : _transformItemById(current, id, transform, idOf: (f) => f.id);
    if (update == null) {
      _persistFolderTransform(id, transform);
      _requestReconcilePull(
        action: current == null ? 'update-cold' : 'update-missing',
      );
      return;
    }
    _replaceState(update.items);
    _persistFolder(update.item);
  }

  /// Applies a server-confirmed folder update.
  void updateFolderFromRemote(
    String id,
    Folder Function(Folder folder) transform,
  ) {
    updateFolder(id, transform);
  }

  void removeFolder(String id) {
    final current = state.asData?.value;
    if (current != null) {
      final removal = _removeItemById(current, id, idOf: (f) => f.id);
      if (removal.didRemove) {
        _replaceState(removal.items);
      }
    }
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    unawaited(
      db.foldersDao.hardDelete(id).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DebugLogger.error(
          'row-delete-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
      }),
    );
  }

  /// Applies a server-confirmed folder deletion.
  void removeFolderFromRemote(String id) => removeFolder(id);

  void _persistFolder(Folder folder) {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    unawaited(
      db.foldersDao.upsertServerFolder(_rawFolder(folder)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DebugLogger.error(
          'row-upsert-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
          data: {'id': folder.id},
        );
      }),
    );
  }

  void _persistFolderTransform(
    String id,
    Folder Function(Folder folder) transform,
  ) {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    unawaited(
      (() async {
        final row = await db.foldersDao.getFolder(id);
        if (row == null) return;
        await db.foldersDao.upsertServerFolder(
          _rawFolder(transform(folderFromRow(row))),
        );
      })().catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'row-transform-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
      }),
    );
  }

  void _requestReconcilePull({required String action}) {
    DebugLogger.log(
      'reconcile-after-remote-mutation',
      scope: 'folders',
      data: {'action': action},
    );
    unawaited(
      ref
          .read(syncEngineProvider.notifier)
          .requestPull(reason: 'folders-reconcile')
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'reconcile-pull-failed',
              scope: 'folders',
              error: error,
              stackTrace: stackTrace,
              data: {'action': action},
            );
            return null;
          }),
    );
  }

  /// `FoldersDao.upsertServerFolder`-shaped raw map (timestamps as server
  /// epoch seconds; everything else rides in rawExtra verbatim).
  static Map<String, dynamic> _rawFolder(Folder folder) {
    final raw = folder.toJson();
    final createdAt = folder.createdAt;
    final updatedAt = folder.updatedAt;
    raw['created_at'] = createdAt == null ? 0 : _epochSecondsOf(createdAt);
    raw['updated_at'] = updatedAt == null ? 0 : _epochSecondsOf(updatedAt);
    return raw;
  }

  List<Folder> _sort(List<Folder> input) {
    final sorted = [...input];
    sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List<Folder>.unmodifiable(sorted);
  }

  void _replaceState(List<Folder> folders) {
    state = AsyncData<List<Folder>>(_sort(folders));
  }
}

// Files provider
@Riverpod(keepAlive: true)
class UserFiles extends _$UserFiles {
  int _loadGeneration = 0;

  @override
  Future<List<FileInfo>> build() async {
    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'files');
      return const [];
    }
    final api = ref.watch(apiServiceProvider);
    if (api == null) return const [];
    return _load(api);
  }

  Future<void> refresh() async {
    if (!ref.read(isAuthenticatedProvider2)) {
      state = const AsyncData<List<FileInfo>>([]);
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = const AsyncData<List<FileInfo>>([]);
      return;
    }
    final result = await AsyncValue.guard(() => _load(api));
    if (!ref.mounted) return;
    state = result;
  }

  void upsert(FileInfo file) {
    if (!state.hasValue) {
      return;
    }

    final current = state.requireValue;
    final updated = _upsertItemById(current, file, idOf: (item) => item.id);
    _replaceState(updated);
  }

  void remove(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    final removal = _removeItemById(current, id, idOf: (file) => file.id);
    _replaceState(removal.items);
  }

  Future<List<FileInfo>> _load(ApiService api) async {
    try {
      final loadGeneration = ++_loadGeneration;
      final firstPage = await api.getUserFilesPage(page: 1);
      final initialFiles = _sort(firstPage.items);

      final shouldLoadMore =
          firstPage.isPaginated &&
          firstPage.items.isNotEmpty &&
          (firstPage.total == null ||
              firstPage.items.length < firstPage.total!);

      if (shouldLoadMore) {
        unawaited(
          Future<void>.delayed(Duration.zero, () {
            return _loadRemainingPages(
              api,
              loadGeneration: loadGeneration,
              initialFiles: initialFiles,
              total: firstPage.total,
            );
          }),
        );
      }

      return initialFiles;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'files-failed',
        scope: 'files',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  List<FileInfo> _sort(List<FileInfo> input) {
    final sorted = [...input];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<FileInfo>.unmodifiable(sorted);
  }

  void _replaceState(List<FileInfo> files) {
    state = AsyncData<List<FileInfo>>(_sort(files));
  }

  Future<void> _loadRemainingPages(
    ApiService api, {
    required int loadGeneration,
    required List<FileInfo> initialFiles,
    required int? total,
  }) async {
    if (!_isCurrentLoad(loadGeneration)) {
      return;
    }

    var page = 2;
    var totalCount = total;
    var loadedFiles = initialFiles;

    try {
      while (true) {
        final pageResult = await api.getUserFilesPage(page: page);
        if (!_isCurrentLoad(loadGeneration)) {
          return;
        }
        if (pageResult.items.isEmpty) {
          return;
        }

        loadedFiles = _mergeFiles(loadedFiles, pageResult.items);
        totalCount ??= pageResult.total;

        final currentFiles = state.asData?.value ?? initialFiles;
        _replaceState(_mergeFiles(currentFiles, pageResult.items));

        if (!pageResult.isPaginated) {
          return;
        }
        if (totalCount != null && loadedFiles.length >= totalCount) {
          return;
        }

        page += 1;
      }
    } catch (error, stackTrace) {
      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }
      DebugLogger.error(
        'files-page-load-failed',
        scope: 'files',
        error: error,
        stackTrace: stackTrace,
        data: {'generation': loadGeneration, 'page': page},
      );
    }
  }

  bool _isCurrentLoad(int loadGeneration) =>
      ref.mounted && _loadGeneration == loadGeneration;

  List<FileInfo> _mergeFiles(
    List<FileInfo> current,
    Iterable<FileInfo> incoming,
  ) {
    final merged = <String, FileInfo>{
      for (final file in current) file.id: file,
    };
    for (final file in incoming) {
      merged[file.id] = file;
    }
    return merged.values.toList(growable: false);
  }
}

@riverpod
Future<List<FileInfo>> searchUserFiles(Ref ref, String query) async {
  if (!ref.watch(isAuthenticatedProvider2)) {
    return const [];
  }

  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return const [];
  }

  final trimmedQuery = query.trim();
  if (trimmedQuery.isEmpty) {
    return const [];
  }

  try {
    const pageSize = 100;
    final files = <FileInfo>[];
    var offset = 0;

    while (true) {
      final page = await api.searchFiles(
        query: trimmedQuery,
        limit: pageSize,
        offset: offset,
      );
      if (page.isEmpty) {
        break;
      }

      files.addAll(page);
      if (page.length < pageSize) {
        break;
      }

      offset += page.length;
    }

    final deduped = <String, FileInfo>{for (final file in files) file.id: file};
    final sorted = deduped.values.toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<FileInfo>.unmodifiable(sorted);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'files-search-failed',
      scope: 'files/search',
      error: error,
      stackTrace: stackTrace,
      data: {'query': trimmedQuery},
    );
    rethrow;
  }
}

// File content provider
@riverpod
Future<String> fileContent(Ref ref, String fileId) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'files/content');
    throw Exception('Not authenticated');
  }
  final api = ref.watch(apiServiceProvider);
  if (api == null) throw Exception('No API service available');

  try {
    return await api.getFileContent(fileId);
  } catch (e) {
    DebugLogger.error(
      'file-content-failed',
      scope: 'files',
      error: e,
      data: {'fileId': fileId},
    );
    throw Exception('Failed to load file content: $e');
  }
}

// Knowledge Base providers
@Riverpod(keepAlive: true)
class KnowledgeBases extends _$KnowledgeBases {
  @override
  Future<List<KnowledgeBase>> build() async {
    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'knowledge');
      return const [];
    }
    final api = ref.watch(apiServiceProvider);
    if (api == null) return const [];
    return _load(api);
  }

  Future<void> refresh() async {
    if (!ref.read(isAuthenticatedProvider2)) {
      state = const AsyncData<List<KnowledgeBase>>([]);
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = const AsyncData<List<KnowledgeBase>>([]);
      return;
    }
    final result = await AsyncValue.guard(() => _load(api));
    if (!ref.mounted) return;
    state = result;
  }

  void upsert(KnowledgeBase knowledgeBase) {
    final current = state.asData?.value ?? const <KnowledgeBase>[];
    final updated = _upsertItemById(
      current,
      knowledgeBase,
      idOf: (item) => item.id,
    );
    _replaceState(updated);
  }

  void remove(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    final removal = _removeItemById(
      current,
      id,
      idOf: (knowledgeBase) => knowledgeBase.id,
    );
    _replaceState(removal.items);
  }

  Future<List<KnowledgeBase>> _load(ApiService api) async {
    try {
      final knowledgeBases = await api.getKnowledgeBases();
      return _sort(knowledgeBases);
    } catch (e, stackTrace) {
      DebugLogger.error(
        'knowledge-bases-failed',
        scope: 'knowledge',
        error: e,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  List<KnowledgeBase> _sort(List<KnowledgeBase> input) {
    final sorted = [...input];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<KnowledgeBase>.unmodifiable(sorted);
  }

  void _replaceState(List<KnowledgeBase> knowledgeBases) {
    state = AsyncData<List<KnowledgeBase>>(_sort(knowledgeBases));
  }
}

@riverpod
Future<List<KnowledgeBaseItem>> knowledgeBaseItems(Ref ref, String kbId) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'knowledge/items');
    return [];
  }
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    return await api.getKnowledgeBaseItems(kbId);
  } catch (e) {
    DebugLogger.error('knowledge-items-failed', scope: 'knowledge', error: e);
    return [];
  }
}

// Audio providers
@Riverpod(keepAlive: true)
Future<List<String>> availableVoices(Ref ref) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'voices');
    return [];
  }
  final config = await ref.watch(backendConfigProvider.future);
  if (config == null) return [];

  return config.ttsVoices
      .map((voice) => voice.name.isNotEmpty ? voice.name : voice.id)
      .where((name) => name.isNotEmpty)
      .toList(growable: false);
}

// Image Generation providers
@Riverpod(keepAlive: true)
Future<List<Map<String, dynamic>>> imageModels(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    return await api.getImageModels();
  } catch (e) {
    DebugLogger.error('image-models-failed', scope: 'image-models', error: e);
    return [];
  }
}

/// Helper function to select cached model based on settings and available models.
/// Used by both chat page and defaultModel provider to ensure consistent behavior.
/// Returns a cached model if available, otherwise returns null.
Future<Model?> selectCachedModel(
  OptimizedStorageService storage,
  String? desiredModelId,
) async {
  try {
    final cachedModels = (await storage.getLocalModels())
        .where((model) => !model.isHidden)
        .toList();
    if (cachedModels.isEmpty) return null;

    Model? match;
    if (desiredModelId != null && desiredModelId.isNotEmpty) {
      try {
        match = cachedModels.firstWhere(
          (model) =>
              model.id == desiredModelId ||
              model.name.trim() == desiredModelId.trim(),
        );
      } catch (_) {
        match = null;
      }
    }

    return match ?? cachedModels.first;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'cache-select-failed',
      scope: 'models/cache',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

// ---------------------------------------------------------------------------
// Active chats tracking (mirrors OpenWebUI Sidebar.svelte activeChatIds)
// ---------------------------------------------------------------------------

/// Tracks the set of chat IDs that have an active background task running.
///
/// Updated via `chat:active` socket events emitted by the backend when a
/// chat processing task starts (`active: true`) or completes (`active: false`).
@Riverpod(keepAlive: true)
class ActiveChatIds extends _$ActiveChatIds {
  @override
  Set<String> build() => const <String>{};

  // Monotonic activation tokens so a delayed, conditional clear can detect that
  // a chat was (re)activated after the clear was scheduled and skip itself.
  int _seq = 0;
  final Map<String, int> _activationToken = {};

  /// Mark a chat as active (background task running).
  void setActive(String chatId) {
    _activationToken[chatId] = ++_seq;
    if (state.contains(chatId)) return;
    state = {...state, chatId};
  }

  /// Mark a chat as inactive (background task completed).
  void setInactive(String chatId) {
    _activationToken.remove(chatId);
    if (!state.contains(chatId)) return;
    state = {...state}..remove(chatId);
  }

  /// The current activation token for [chatId], or null if not active. Capture
  /// this before an async task-registry check, then pass it to
  /// [setInactiveIfUnchanged] so a racing [setActive] cannot be clobbered.
  int? activationToken(String chatId) => _activationToken[chatId];

  /// Clear [chatId] only if it has not been (re)activated since [token] was
  /// captured — guards an async optimistic clear against a racing setActive
  /// (e.g. a new stream starting for the same chat before the lookup resolves).
  void setInactiveIfUnchanged(String chatId, int? token) {
    if (_activationToken[chatId] != token) return;
    setInactive(chatId);
  }

  /// Bulk-initialize from a server response.
  void setAll(Set<String> chatIds) {
    _seq++;
    _activationToken
      ..clear()
      ..addEntries([for (final id in chatIds) MapEntry(id, _seq)]);
    state = chatIds;
  }
}

/// Keeps [activeChatIdsProvider] correct beyond the locally-streaming chat.
///
/// OpenWebUI's sidebar both bulk-fetches active chats on load and listens for
/// `chat:active` events for any chat. This provider mirrors that: it
/// bulk-fetches on cold open + socket reconnect (`setAll`) and registers a
/// GLOBAL `chat:active` handler so generations started by other sessions/
/// devices also light up the sidebar spinner.
@Riverpod(keepAlive: true)
class ActiveChatsSync extends _$ActiveChatsSync {
  SocketEventSubscription? _globalActiveSub;
  StreamSubscription<void>? _reconnectSub;
  SocketService? _boundSocket;
  bool _initialFetchDone = false;

  @override
  void build() {
    ref.onDispose(() {
      _globalActiveSub?.dispose();
      _globalActiveSub = null;
      _reconnectSub?.cancel();
      _reconnectSub = null;
    });

    _bindSocket(ref.read(socketServiceProvider));
    ref.listen<SocketService?>(socketServiceProvider, (prev, next) {
      _bindSocket(next);
    });

    // Cold-open population: refresh once the conversation list first resolves.
    ref.listen<AsyncValue<List<Conversation>>>(conversationsProvider, (
      prev,
      next,
    ) {
      final convos = next.asData?.value;
      if (convos == null || convos.isEmpty || _initialFetchDone) {
        return;
      }
      _initialFetchDone = true;
      unawaited(_refresh(convos.map((c) => c.id).toList()));
    }, fireImmediately: true);
  }

  void _bindSocket(SocketService? socket) {
    if (identical(socket, _boundSocket)) {
      return;
    }
    _boundSocket = socket;
    _globalActiveSub?.dispose();
    _globalActiveSub = null;
    _reconnectSub?.cancel();
    _reconnectSub = null;
    if (socket == null) {
      // Logout / session teardown: the socket the spinners were derived from is
      // gone. Drop the whole set so a stale `generating` indicator cannot
      // survive into the next session (the new socket re-arms the cold-open
      // fetch below to repopulate authoritative state).
      ref.read(activeChatIdsProvider.notifier).setAll(const <String>{});
      _initialFetchDone = false;
      return;
    }

    // A new socket means a (re)connection or a fresh session (e.g. after
    // logout/login). Re-arm the one-shot cold-open fetch so the conversations
    // listener bulk-fetches active chats again for the new session instead of
    // skipping it because the flag stayed true from the previous one.
    _initialFetchDone = false;

    // All selectors null => `_shouldDeliver` treats this as a wildcard handler.
    // requireFocus:false so background generations on other chats still update
    // the badge.
    _globalActiveSub = socket.addChatEventHandler(
      requireFocus: false,
      handler: (map, _) => _handleChatActiveEvent(map),
    );

    // Redis task state may have changed while disconnected: refresh on connect.
    _reconnectSub = socket.onReconnect.listen((_) {
      final convos = ref.read(conversationsProvider).asData?.value;
      if (convos == null || convos.isEmpty) {
        return;
      }
      unawaited(_refresh(convos.map((c) => c.id).toList()));
    });
  }

  void _handleChatActiveEvent(Map<String, dynamic> map) {
    final data = map['data'];
    if (data is! Map || data['type'] != 'chat:active') {
      return;
    }
    final payload = data['data'];
    final active = payload is Map ? payload['active'] : null;
    if (active is! bool) {
      return;
    }
    final chatId = _extractActiveChatId(map);
    if (chatId == null || chatId.isEmpty) {
      return;
    }
    final notifier = ref.read(activeChatIdsProvider.notifier);
    if (active) {
      notifier.setActive(chatId);
    } else {
      notifier.setInactive(chatId);
    }
  }

  String? _extractActiveChatId(Map<String, dynamic> map) {
    final direct = map['chat_id'] ?? map['chatId'];
    if (direct != null) {
      return direct.toString();
    }
    final data = map['data'];
    if (data is Map) {
      final outer = data['chat_id'] ?? data['chatId'];
      if (outer != null) {
        return outer.toString();
      }
      final inner = data['data'];
      if (inner is Map) {
        final nested = inner['chat_id'] ?? inner['chatId'];
        if (nested != null) {
          return nested.toString();
        }
      }
    }
    return null;
  }

  Future<void> _refresh(List<String> chatIds) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return;
    }
    final ids = chatIds
        .where((id) => id.isNotEmpty && !isTemporaryChat(id))
        .toList();
    if (ids.isEmpty) {
      return;
    }
    try {
      final active = await api.checkActiveChats(ids);
      ref.read(activeChatIdsProvider.notifier).setAll(active);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'active-chats refresh failed',
        scope: 'chat/active-sync',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

/// Resolves socket transport availability from backend configuration.
///
/// Used by both the sync [socketTransportOptionsProvider] and the
/// [BackendConfigNotifier] to ensure consistent resolution logic.
SocketTransportAvailability _resolveTransportAvailability(
  BackendConfig config,
) {
  if (config.websocketOnly) {
    return const SocketTransportAvailability(
      allowPolling: false,
      allowWebsocketOnly: true,
    );
  }

  if (config.pollingOnly) {
    return const SocketTransportAvailability(
      allowPolling: true,
      allowWebsocketOnly: false,
    );
  }

  return const SocketTransportAvailability(
    allowPolling: true,
    allowWebsocketOnly: true,
  );
}
