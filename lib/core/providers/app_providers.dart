import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../models/backend_config.dart';
import '../models/folder.dart';
import '../models/user_settings.dart';
import '../models/file_info.dart';
import '../models/tool.dart';
import '../models/knowledge_base.dart';
import '../services/settings_service.dart';
import '../services/optimized_storage_service.dart';
import '../services/socket_service.dart';
import '../services/connectivity_service.dart';
import '../utils/debug_logger.dart';
import '../services/worker_manager.dart';
import '../../shared/theme/tweakcn_themes.dart';
import '../../shared/theme/app_theme.dart';
import '../../features/tools/providers/tools_providers.dart';
import '../models/socket_transport_availability.dart';
import 'storage_providers.dart';

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

  if (activeId == null || configs.isEmpty) return null;

  for (final config in configs) {
    if (config.id == activeId) {
      return config;
    }
  }

  return null;
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
  return asyncService.maybeWhen(data: (service) => service, orElse: () => null);
});

// Attachment upload queue provider
final attachmentUploadQueueProvider = Provider<AttachmentUploadQueue?>((ref) {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return null;

  final queue = AttachmentUploadQueue();
  // Initialize once; subsequent calls are no-ops due to singleton
  queue.initialize(
    onUpload: (filePath, fileName) => api.uploadFile(filePath, fileName),
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
        DebugLogger.log(
          'cache-restored',
          scope: 'models/cache',
          data: {'count': cached.length},
        );
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
        return cached;
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
          // Model no longer available - keep current selection
        }
      }
    }
  }

  Future<List<Model>> _load(ApiService api) async {
    try {
      DebugLogger.log('fetch-start', scope: 'models');
      final models = await api.getModels();
      DebugLogger.log(
        'fetch-ok',
        scope: 'models',
        data: {'count': models.length},
      );
      _persistModelsAsync(models);
      return models;
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

  void set(Model? model) => state = model;

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

        // Fallback: keep current selection or pick first available
        selected ??=
            ref.read(selectedModelProvider) ??
            (models.isNotEmpty ? models.first : null);

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

// Cache timestamp for conversations to prevent rapid re-fetches
@Riverpod(keepAlive: true)
class _ConversationsCacheTimestamp extends _$ConversationsCacheTimestamp {
  @override
  DateTime? build() => null;

  void set(DateTime? timestamp) => state = timestamp;
}

/// Clears the in-memory timestamp cache and triggers a refresh of the
/// conversations provider. Optionally refreshes the folders provider so folder
/// metadata stays in sync.
void refreshConversationsCache(dynamic ref, {bool includeFolders = false}) {
  ref.read(_conversationsCacheTimestampProvider.notifier).set(null);
  ref.read(_folderConversationRefreshTickProvider.notifier).bump();
  final notifier = ref.read(conversationsProvider.notifier);
  unawaited(
    notifier.refresh(includeFolders: includeFolders).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      DebugLogger.error(
        'refresh-cache-failed',
        scope: 'conversations',
        error: error,
        stackTrace: stackTrace,
      );
    }),
  );
  if (includeFolders) {
    final foldersNotifier = ref.read(foldersProvider.notifier);
    unawaited(
      foldersNotifier.refresh().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DebugLogger.error(
          'refresh-folders-cache-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }
}

// Conversation providers - Now using correct OpenWebUI API with caching and
// immediate mutation helpers.
@Riverpod(keepAlive: true)
class Conversations extends _$Conversations {
  static const int _regularPageSize = 50;

  int _currentRegularPage = 0;
  bool _allRegularChatsLoaded = false;
  bool _isLoadingMoreRegularChats = false;

  bool get hasMoreRegularChats => !_allRegularChatsLoaded;
  bool get isLoadingMoreRegularChats => _isLoadingMoreRegularChats;

  @override
  Future<List<Conversation>> build() async {
    final authed = ref.watch(isAuthenticatedProvider2);
    if (!authed) {
      DebugLogger.log('skip-unauthed', scope: 'conversations');
      _resetPaginationState(allLoaded: true);
      _updateCacheTimestamp(null);
      _persistConversationsAsync(const <Conversation>[]);
      return const [];
    }

    if (ref.watch(reviewerModeProvider)) {
      _resetPaginationState(currentPage: 1, allLoaded: true);
      return _demoConversations();
    }

    final storage = ref.read(optimizedStorageServiceProvider);
    try {
      final cached = await storage.getLocalConversations();
      if (cached.isNotEmpty) {
        final sortedCached = _sortByUpdatedAt(cached);
        final preparedCache = _prepareCachedSidebarFeed(sortedCached);
        Future.microtask(() async {
          try {
            await refresh(includeFolders: true);
          } catch (error, stackTrace) {
            DebugLogger.error(
              'warm-refresh-failed',
              scope: 'conversations/cache',
              error: error,
              stackTrace: stackTrace,
            );
          }
        });
        return preparedCache;
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'cache-load-failed',
        scope: 'conversations/cache',
        error: error,
        stackTrace: stackTrace,
      );
    }

    final fresh = await _loadRemoteConversations(page: 1);
    _persistConversationsAsync(fresh);
    return fresh;
  }

  Future<void> refresh({bool includeFolders = false}) async {
    final authed = ref.read(isAuthenticatedProvider2);
    if (!authed) {
      _resetPaginationState(allLoaded: true);
      _updateCacheTimestamp(null);
      state = AsyncData<List<Conversation>>(<Conversation>[]);
      _persistConversationsAsync(const <Conversation>[]);
      if (includeFolders) {
        unawaited(ref.read(foldersProvider.notifier).refresh());
      }
      return;
    }

    if (ref.read(reviewerModeProvider)) {
      _resetPaginationState(currentPage: 1, allLoaded: true);
      state = AsyncData<List<Conversation>>(_demoConversations());
      if (includeFolders) {
        unawaited(ref.read(foldersProvider.notifier).refresh());
      }
      return;
    }

    final result = await AsyncValue.guard(
      () => _loadRemoteConversations(page: 1),
    );
    if (!ref.mounted) return;
    result.when(
      data: (conversations) {
        state = AsyncData<List<Conversation>>(conversations);
        _persistConversationsAsync(conversations);
      },
      error: (error, stackTrace) {
        DebugLogger.error(
          'refresh-failed',
          scope: 'conversations',
          error: error,
          stackTrace: stackTrace,
          data: {'preservedData': state.asData != null},
        );
      },
      loading: () {},
    );
    if (includeFolders) {
      unawaited(ref.read(foldersProvider.notifier).refresh());
    }
  }

  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (current == null ||
        _isLoadingMoreRegularChats ||
        _allRegularChatsLoaded) {
      return;
    }
    if (!ref.read(isAuthenticatedProvider2) || ref.read(reviewerModeProvider)) {
      return;
    }

    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return;
    }

    final nextPage = (_currentRegularPage == 0 ? 1 : _currentRegularPage + 1);
    _isLoadingMoreRegularChats = true;

    try {
      final nextConversations = await api.getConversationPage(
        page: nextPage,
        includeFolders: true,
      );
      if (!ref.mounted) {
        return;
      }

      _currentRegularPage = nextPage;
      if (nextConversations.isEmpty) {
        _allRegularChatsLoaded = true;
        return;
      }

      _allRegularChatsLoaded = nextConversations.length < _regularPageSize;

      final merged = _mergeConversationLists(current, nextConversations);
      _updateCacheTimestamp(DateTime.now());
      state = AsyncData<List<Conversation>>(merged);
      _persistConversationsAsync(merged);

      DebugLogger.log(
        'page-loaded',
        scope: 'conversations',
        data: {
          'page': nextPage,
          'count': nextConversations.length,
          'total': merged.length,
          'hasMore': !_allRegularChatsLoaded,
        },
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'load-more-failed',
        scope: 'conversations',
        error: error,
        stackTrace: stackTrace,
        data: {'page': nextPage},
      );
      rethrow;
    } finally {
      _isLoadingMoreRegularChats = false;
    }
  }

  void removeConversation(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    final updated = current
        .where((conversation) => conversation.id != id)
        .toList(growable: true);
    _replaceState(updated);
  }

  void upsertConversation(Conversation conversation) {
    final current = state.asData?.value ?? const <Conversation>[];
    final updated = <Conversation>[...current];
    final index = updated.indexWhere(
      (element) => element.id == conversation.id,
    );
    if (index >= 0) {
      updated[index] = conversation;
    } else {
      updated.add(conversation);
    }
    _replaceState(updated);
  }

  void upsertConversations(Iterable<Conversation> conversations) {
    final current = state.asData?.value ?? const <Conversation>[];
    final merged = _mergeConversationLists(current, conversations);
    _replaceState(merged);
  }

  void updateConversation(
    String id,
    Conversation Function(Conversation conversation) transform,
  ) {
    final current = state.asData?.value;
    if (current == null) return;
    final index = current.indexWhere((conversation) => conversation.id == id);
    if (index < 0) return;
    final updated = <Conversation>[...current];
    updated[index] = transform(updated[index]);
    _replaceState(updated);
  }

  void _replaceState(List<Conversation> conversations) {
    final sorted = _sortByUpdatedAt(conversations);
    state = AsyncData<List<Conversation>>(sorted);
    _persistConversationsAsync(sorted);
  }

  void _persistConversationsAsync(List<Conversation> conversations) {
    final storage = ref.read(optimizedStorageServiceProvider);
    unawaited(
      Future<void>(() async {
        try {
          await storage.saveLocalConversations(conversations);
        } catch (error, stackTrace) {
          DebugLogger.error(
            'cache-save-failed',
            scope: 'conversations/cache',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }),
    );
  }

  void _resetPaginationState({
    int currentPage = 0,
    bool allLoaded = false,
  }) {
    _currentRegularPage = currentPage;
    _allRegularChatsLoaded = allLoaded;
    _isLoadingMoreRegularChats = false;
  }

  List<Conversation> _prepareCachedSidebarFeed(List<Conversation> conversations) {
    final pinned = <Conversation>[];
    final archived = <Conversation>[];
    final foldered = <Conversation>[];
    final regular = <Conversation>[];

    for (final conversation in conversations) {
      if (conversation.archived) {
        archived.add(conversation);
      } else if (conversation.pinned) {
        pinned.add(conversation);
      } else if (_isFolderConversation(conversation)) {
        foldered.add(conversation);
      } else {
        regular.add(conversation);
      }
    }

    final visibleRegular = regular.take(_regularPageSize).toList(growable: false);
    _resetPaginationState(
      currentPage: visibleRegular.isEmpty ? 0 : 1,
      allLoaded: regular.length < _regularPageSize,
    );
    return _sortByUpdatedAt([
      ...pinned,
      ...archived,
      ...foldered,
      ...visibleRegular,
    ]);
  }

  List<Conversation> _mergeConversationLists(
    List<Conversation> current,
    Iterable<Conversation> incoming,
  ) {
    final merged = <String, Conversation>{};
    for (final conversation in current) {
      _upsertConversationMap(merged, conversation);
    }
    for (final conversation in incoming) {
      _upsertConversationMap(merged, conversation);
    }
    return _sortByUpdatedAt(merged.values.toList(growable: false));
  }

  bool _isFolderConversation(Conversation conversation) {
    final folderId = conversation.folderId;
    return folderId != null &&
        folderId.isNotEmpty &&
        !conversation.pinned &&
        !conversation.archived;
  }

  void _upsertConversationMap(
    Map<String, Conversation> conversationMap,
    Conversation conversation,
  ) {
    final existing = conversationMap[conversation.id];
    conversationMap[conversation.id] = existing == null
        ? conversation
        : _mergeConversationSummary(existing, conversation);
  }

  Conversation _mergeConversationSummary(
    Conversation existing,
    Conversation incoming,
  ) {
    final incomingHasResolvedTitle =
        incoming.title.isNotEmpty && incoming.title != 'Chat';
    final existingLooksLikePlaceholder =
        existing.title == 'Chat' && existing.messages.isEmpty;
    final preferIncomingSummary =
        existingLooksLikePlaceholder && incomingHasResolvedTitle;

    return existing.copyWith(
      title: preferIncomingSummary
          ? incoming.title
          : (incomingHasResolvedTitle ? incoming.title : existing.title),
      createdAt: preferIncomingSummary
          ? incoming.createdAt
          : (existing.createdAt.isBefore(incoming.createdAt)
                ? existing.createdAt
                : incoming.createdAt),
      updatedAt: preferIncomingSummary
          ? incoming.updatedAt
          : (incoming.updatedAt.isAfter(existing.updatedAt)
                ? incoming.updatedAt
                : existing.updatedAt),
      model: incoming.model ?? existing.model,
      systemPrompt: incoming.systemPrompt ?? existing.systemPrompt,
      messages: incoming.messages.isNotEmpty
          ? incoming.messages
          : existing.messages,
      metadata: incoming.metadata.isNotEmpty
          ? incoming.metadata
          : existing.metadata,
      pinned: existing.pinned || incoming.pinned,
      archived: existing.archived || incoming.archived,
      shareId: incoming.shareId ?? existing.shareId,
      folderId: incoming.folderId ?? existing.folderId,
      tags: incoming.tags.isNotEmpty ? incoming.tags : existing.tags,
    );
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

  Future<List<Conversation>> _loadRemoteConversations({int page = 1}) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      DebugLogger.warning('api-missing', scope: 'conversations');
      return const [];
    }

    try {
      DebugLogger.log(
        'fetch-start',
        scope: 'conversations',
        data: {'page': page},
      );
      final regularFuture = api.getConversationPage(
        page: page,
        includeFolders: true,
      );
      final pinnedFuture = api.getPinnedChats();
      final archivedFuture = api.getArchivedChats();
      final results = await Future.wait<dynamic>([
        regularFuture,
        pinnedFuture,
        archivedFuture,
      ]);
      final regularConversations = results[0] as List<Conversation>;
      final pinnedConversations = results[1] as List<Conversation>;
      final archivedConversations = results[2] as List<Conversation>;

      _currentRegularPage = page;
      _allRegularChatsLoaded = regularConversations.length < _regularPageSize;
      _isLoadingMoreRegularChats = false;

      DebugLogger.log(
        'fetch-ok',
        scope: 'conversations',
        data: {
          'page': page,
          'regular': regularConversations.length,
          'pinned': pinnedConversations.length,
          'archived': archivedConversations.length,
          'hasMore': !_allRegularChatsLoaded,
        },
      );
      final preservedFolderConversations = (state.asData?.value ?? const [])
          .where(_isFolderConversation)
          .toList(growable: false);
      final sortedConversations = _mergeConversationLists(
        [
          ...preservedFolderConversations,
          ...pinnedConversations,
          ...archivedConversations,
        ],
        regularConversations,
      );
      _updateCacheTimestamp(DateTime.now());
      return sortedConversations;
    } catch (e, stackTrace) {
      DebugLogger.error(
        'fetch-failed',
        scope: 'conversations',
        error: e,
        stackTrace: stackTrace,
      );
      if (e.toString().contains('403')) {
        DebugLogger.warning('endpoint-403', scope: 'conversations');
      }
      return const [];
    }
  }

  List<Conversation> _sortByUpdatedAt(List<Conversation> conversations) {
    final sorted = [...conversations];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<Conversation>.unmodifiable(sorted);
  }

  void _updateCacheTimestamp(DateTime? timestamp) {
    ref.read(_conversationsCacheTimestampProvider.notifier).set(timestamp);
  }
}

final _folderConversationRefreshTickProvider =
    NotifierProvider<_FolderConversationRefreshTick, int>(
      _FolderConversationRefreshTick.new,
    );

class _FolderConversationRefreshTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Loads folder conversation summaries on demand, mirroring OpenWebUI's
/// expanded-folder fetch behavior.
final folderConversationSummariesProvider =
    FutureProvider.family<List<Conversation>, String>((ref, folderId) async {
      ref.watch(_folderConversationRefreshTickProvider);

      if (!ref.watch(isAuthenticatedProvider2) ||
          ref.watch(reviewerModeProvider)) {
        return const <Conversation>[];
      }

      final api = ref.watch(apiServiceProvider);
      if (api == null) {
        return const <Conversation>[];
      }

      try {
        final conversations = await api.getFolderConversationSummaries(folderId);
        final normalized = conversations
            .map(
              (conversation) => conversation.folderId == null
                  ? conversation.copyWith(folderId: folderId)
                  : conversation,
            )
            .toList(growable: false);
        ref.read(conversationsProvider.notifier).upsertConversations(normalized);
        return normalized;
      } catch (error, stackTrace) {
        DebugLogger.error(
          'folder-conversations-failed',
          scope: 'folders/conversations',
          error: error,
          stackTrace: stackTrace,
          data: {'folderId': folderId},
        );
        return const <Conversation>[];
      }
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

final activeConversationProvider =
    NotifierProvider<ActiveConversationNotifier, Conversation?>(
      ActiveConversationNotifier.new,
    );

class ActiveConversationNotifier extends Notifier<Conversation?> {
  @override
  Conversation? build() => null;

  void set(Conversation? conversation) => state = conversation;

  void clear() => state = null;
}

// Provider to load full conversation with messages
@riverpod
Future<Conversation> loadConversation(Ref ref, String conversationId) async {
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
      if (current != null) return current;
    }

    // 1) Priority: user's configured default from app settings
    // This ensures new chats use the user's preference (fixes #296)
    final settingsDefaultId = ref.read(appSettingsProvider).defaultModel;
    final storedDefaultId =
        settingsDefaultId ??
        await SettingsService.getDefaultModel().catchError((_) => null);

    if (storedDefaultId != null && storedDefaultId.isNotEmpty) {
      // Try cached models first for speed
      final cachedMatch = await selectCachedModel(storage, storedDefaultId);
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

    // 2) Fallback: cached resolved default model (for offline/fast startup)
    try {
      final cached = await storage.getLocalDefaultModel();
      if (cached != null && !ref.read(isManualModelSelectionProvider)) {
        ref.read(selectedModelProvider.notifier).set(cached);
        DebugLogger.log(
          'cached-default',
          scope: 'models/default',
          data: {'name': cached.name},
        );
        return cached;
      }
    } catch (_) {}

    // 3) Fast server path: query server default ID without listing all models
    try {
      final serverDefault = await api.getDefaultModel();
      if (serverDefault != null && serverDefault.isNotEmpty) {
        if (!ref.read(isManualModelSelectionProvider)) {
          final placeholder = Model(
            id: serverDefault,
            name: serverDefault,
            supportsStreaming: true,
          );
          ref.read(selectedModelProvider.notifier).set(placeholder);
          unawaited(
            storage.saveLocalDefaultModel(placeholder).onError((error, stack) {
              DebugLogger.error(
                'Failed to save placeholder model to cache',
                scope: 'models/default',
                error: error,
                stackTrace: stack,
              );
            }),
          );
        }
        // Reconcile against real models in background
        Future.microtask(() async {
          try {
            if (!ref.mounted) return;
            final models = await ref.read(modelsProvider.future);
            if (!ref.mounted) return;

            Model? resolved;
            try {
              resolved = models.firstWhere((m) => m.id == serverDefault);
            } catch (_) {
              final byName = models
                  .where((m) => m.name == serverDefault)
                  .toList();
              if (byName.length == 1) resolved = byName.first;
            }
            resolved ??= models.isNotEmpty ? models.first : null;

            if (!ref.mounted) return;
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
                'reconcile',
                scope: 'models/default',
                data: {'name': resolved.name, 'source': 'server'},
              );
            }
          } catch (e) {
            DebugLogger.error(
              'reconcile-failed',
              scope: 'models/default',
              error: e,
            );
          }
        });
        return ref.read(selectedModelProvider);
      }
    } catch (_) {}

    // 3) Fallback: fetch models and pick first available
    DebugLogger.log('fallback-path', scope: 'models/default');
    final models = await ref.read(modelsProvider.future);
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

// Server-side search provider for chats
@riverpod
Future<List<Conversation>> serverSearch(Ref ref, String query) async {
  if (query.trim().isEmpty) {
    // Return empty list for empty query instead of all conversations
    return [];
  }

  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    final trimmedQuery = query.trim();
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

    // Fallback to local search if server search fails
    final allConversations = await ref.read(conversationsProvider.future);
    DebugLogger.log('fallback-local', scope: 'search');
    return allConversations.where((conv) {
      return !conv.archived &&
          (conv.title.toLowerCase().contains(query.toLowerCase()) ||
              conv.messages.any(
                (msg) =>
                    msg.content.toLowerCase().contains(query.toLowerCase()),
              ));
    }).toList();
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
  final perms = ref.watch(userPermissionsProvider);
  return perms.maybeWhen(
    data: (data) {
      final features = data['features'];
      if (features is Map<String, dynamic>) {
        final value = features['web_search'];
        if (value is bool) return value;
        if (value is String) return value.toLowerCase() != 'false';
      }
      // No explicit permission — default to available. Open WebUI defaults
      // web_search to true and the server will ignore the flag if the feature
      // is not configured.
      return true;
    },
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
  @override
  bool build() => true;

  void setEnabled(bool enabled) {
    state = enabled;
  }
}

/// Tracks whether the notes feature is enabled on the server.
/// Set to false when the server returns 401 or 403 for the notes endpoint.
final notesFeatureEnabledProvider =
    NotifierProvider<NotesFeatureEnabledNotifier, bool>(
      NotesFeatureEnabledNotifier.new,
    );

class NotesFeatureEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void setEnabled(bool enabled) {
    state = enabled;
  }
}

/// Tracks whether the Channels feature is enabled on the server.
/// Set to false when the server returns 401 or 403 for the channels endpoint.
final channelsFeatureEnabledProvider =
    NotifierProvider<ChannelsFeatureEnabledNotifier, bool>(
      ChannelsFeatureEnabledNotifier.new,
    );

class ChannelsFeatureEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void setEnabled(bool enabled) {
    state = enabled;
  }
}

// Folders provider
@Riverpod(keepAlive: true)
class Folders extends _$Folders {
  @override
  Future<List<Folder>> build() async {
    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'folders');
      _persistFoldersAsync(const []);
      return const [];
    }

    final storage = ref.watch(optimizedStorageServiceProvider);
    final cached = await storage.getLocalFolders();
    if (cached.isNotEmpty) {
      Future.microtask(() async {
        try {
          await refresh();
        } catch (error, stackTrace) {
          DebugLogger.error(
            'warm-refresh-failed',
            scope: 'folders/cache',
            error: error,
            stackTrace: stackTrace,
          );
        }
      });
      return _sort(cached);
    }

    final api = ref.watch(apiServiceProvider);
    if (api == null) {
      DebugLogger.warning('api-missing', scope: 'folders');
      return const [];
    }
    final fresh = await _load(api);
    return fresh;
  }

  Future<void> refresh() async {
    if (!ref.read(isAuthenticatedProvider2)) {
      state = const AsyncData<List<Folder>>([]);
      _persistFoldersAsync(const []);
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = const AsyncData<List<Folder>>([]);
      _persistFoldersAsync(const []);
      return;
    }
    final result = await AsyncValue.guard(() => _load(api));
    if (!ref.mounted) return;
    state = result;
  }

  void upsertFolder(Folder folder) {
    final current = state.asData?.value ?? const <Folder>[];
    final updated = <Folder>[...current];
    final index = updated.indexWhere((existing) => existing.id == folder.id);
    if (index >= 0) {
      updated[index] = folder;
    } else {
      updated.add(folder);
    }
    final sorted = _sort(updated);
    state = AsyncData<List<Folder>>(sorted);
    _persistFoldersAsync(sorted);
  }

  void updateFolder(String id, Folder Function(Folder folder) transform) {
    final current = state.asData?.value;
    if (current == null) return;
    final index = current.indexWhere((folder) => folder.id == id);
    if (index < 0) return;
    final updated = <Folder>[...current];
    updated[index] = transform(updated[index]);
    final sorted = _sort(updated);
    state = AsyncData<List<Folder>>(sorted);
    _persistFoldersAsync(sorted);
  }

  void removeFolder(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    final updated = current
        .where((folder) => folder.id != id)
        .toList(growable: true);
    final sorted = _sort(updated);
    state = AsyncData<List<Folder>>(sorted);
    _persistFoldersAsync(sorted);
  }

  Future<List<Folder>> _load(ApiService api) async {
    try {
      final (foldersData, featureEnabled) = await api.getFolders();

      // Update the folders feature enabled state
      ref
          .read(foldersFeatureEnabledProvider.notifier)
          .setEnabled(featureEnabled);

      final folders = foldersData
          .map((folderData) => Folder.fromJson(folderData))
          .toList();
      DebugLogger.log(
        'fetch-ok',
        scope: 'folders',
        data: {'count': folders.length, 'enabled': featureEnabled},
      );
      final sorted = _sort(folders);
      _persistFoldersAsync(sorted);
      return sorted;
    } catch (e, stackTrace) {
      DebugLogger.error(
        'fetch-failed',
        scope: 'folders',
        error: e,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  void _persistFoldersAsync(List<Folder> folders) {
    final storage = ref.read(optimizedStorageServiceProvider);
    unawaited(storage.saveLocalFolders(folders));
  }

  List<Folder> _sort(List<Folder> input) {
    final sorted = [...input];
    sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List<Folder>.unmodifiable(sorted);
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
    final updated = <FileInfo>[...current];
    final index = updated.indexWhere((existing) => existing.id == file.id);
    if (index >= 0) {
      updated[index] = file;
    } else {
      updated.add(file);
    }
    state = AsyncData<List<FileInfo>>(_sort(updated));
  }

  void remove(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    final updated = current
        .where((file) => file.id != id)
        .toList(growable: true);
    state = AsyncData<List<FileInfo>>(_sort(updated));
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
        state = AsyncData<List<FileInfo>>(
          _sort(_mergeFiles(currentFiles, pageResult.items)),
        );

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
    final updated = <KnowledgeBase>[...current];
    final index = updated.indexWhere(
      (existing) => existing.id == knowledgeBase.id,
    );
    if (index >= 0) {
      updated[index] = knowledgeBase;
    } else {
      updated.add(knowledgeBase);
    }
    state = AsyncData<List<KnowledgeBase>>(_sort(updated));
  }

  void remove(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    final updated = current
        .where((knowledgeBase) => knowledgeBase.id != id)
        .toList(growable: true);
    state = AsyncData<List<KnowledgeBase>>(_sort(updated));
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
    final cachedModels = await storage.getLocalModels();
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

  /// Mark a chat as active (background task running).
  void setActive(String chatId) {
    state = {...state, chatId};
  }

  /// Mark a chat as inactive (background task completed).
  void setInactive(String chatId) {
    final next = {...state}..remove(chatId);
    state = next;
  }

  /// Bulk-initialize from a server response.
  void setAll(Set<String> chatIds) {
    state = chatIds;
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
