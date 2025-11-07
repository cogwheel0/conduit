import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../persistence/persistence_providers.dart';
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
import '../utils/debug_logger.dart';
import '../models/socket_event.dart';
import '../services/worker_manager.dart';
import '../../shared/theme/tweakcn_themes.dart';
import '../../shared/theme/app_theme.dart';
import '../../features/tools/providers/tools_providers.dart';

part 'app_providers.g.dart';

// Storage providers
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  // Single, shared instance with explicit platform options
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      sharedPreferencesName: 'conduit_secure_prefs',
      preferencesKeyPrefix: 'conduit_',
      // Avoid auto-wipe on transient errors; we handle errors in code
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accountName: 'conduit_secure_storage',
      synchronizable: false,
    ),
  );
});

// Optimized storage service provider
final optimizedStorageServiceProvider = Provider<OptimizedStorageService>((
  ref,
) {
  return OptimizedStorageService(
    secureStorage: ref.watch(secureStorageProvider),
    boxes: ref.watch(hiveBoxesProvider),
    workerManager: ref.watch(workerManagerProvider),
  );
});

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

// Locale provider
@Riverpod(keepAlive: true)
class AppLocale extends _$AppLocale {
  late final OptimizedStorageService _storage;

  @override
  Locale? build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final code = _storage.getLocaleCode();
    if (code != null && code.isNotEmpty) {
      // Handle full locale codes with country/region (e.g., "zh_TW", "zh_CN")
      if (code.contains('_')) {
        final parts = code.split('_');
        return Locale(parts[0], parts[1]);
      }
      return Locale(code);
    }
    return null; // system default
  }

  Future<void> setLocale(Locale? locale) async {
    state = locale;
    // Store full locale code including country code for proper Traditional Chinese support
    final localeCode = locale == null 
        ? null 
        : locale.countryCode != null 
            ? '${locale.languageCode}_${locale.countryCode}'
            : locale.languageCode;
    await _storage.setLocaleCode(localeCode);
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

final backendConfigProvider = FutureProvider<BackendConfig?>((ref) async {
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
});

class SocketTransportAvailability {
  const SocketTransportAvailability({
    required this.allowPolling,
    required this.allowWebsocketOnly,
  });

  final bool allowPolling;
  final bool allowWebsocketOnly;
}

final socketTransportOptionsProvider = Provider<SocketTransportAvailability>((
  ref,
) {
  final backendConfigAsync = ref.watch(backendConfigProvider);
  final config = backendConfigAsync.maybeWhen(
    data: (value) => value,
    orElse: () => null,
  );

  if (config == null) {
    return const SocketTransportAvailability(
      allowPolling: true,
      allowWebsocketOnly: true,
    );
  }

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
        onAuthTokenInvalid: () {},
        onTokenInvalidated: () async {
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
        // This will be removed once migration is complete
        DebugLogger.auth('legacy-token-callback', scope: 'auth/api');
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

    ref.onDispose(() {
      _tokenSubscription?.close();
      _tokenSubscription = null;
      _disposeService();
    });

    return _service;
  }

  void _scheduleConnect(SocketService service) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 150));
      if (!ref.mounted) return;
      try {
        unawaited(service.connect());
      } catch (_) {}
    });
  }

  void _disposeService() {
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

@Riverpod(keepAlive: true)
class ConversationDeltaStream extends _$ConversationDeltaStream {
  StreamController<ConversationDelta>? _controller;
  ProviderSubscription<AsyncValue<SocketService?>>? _serviceSubscription;
  SocketEventSubscription? _socketSubscription;

  @override
  Stream<ConversationDelta> build(ConversationDeltaRequest request) {
    final controller = StreamController<ConversationDelta>.broadcast(
      sync: true,
      onCancel: _maybeTearDownSocket,
    );
    _controller = controller;

    final initialService = ref
        .watch(socketServiceManagerProvider)
        .maybeWhen(data: (service) => service, orElse: () => null);
    _bindSocket(initialService, request);

    _serviceSubscription = ref.listen<AsyncValue<SocketService?>>(
      socketServiceManagerProvider,
      (_, next) => _bindSocket(
        next.maybeWhen(data: (service) => service, orElse: () => null),
        request,
      ),
    );

    ref.onDispose(() {
      _serviceSubscription?.close();
      _serviceSubscription = null;
      _socketSubscription?.dispose();
      _socketSubscription = null;
      _controller?.close();
      _controller = null;
    });

    return controller.stream;
  }

  void _bindSocket(SocketService? service, ConversationDeltaRequest request) {
    _socketSubscription?.dispose();
    _socketSubscription = null;

    if (service == null) {
      return;
    }

    switch (request.source) {
      case ConversationDeltaSource.chat:
        _socketSubscription = service.addChatEventHandler(
          conversationId: request.conversationId,
          sessionId: request.sessionId,
          requireFocus: request.requireFocus,
          handler: (event, ack) {
            _controller?.add(
              ConversationDelta.fromSocketEvent(
                ConversationDeltaSource.chat,
                event,
                ack,
              ),
            );
          },
        );
        break;
      case ConversationDeltaSource.channel:
        _socketSubscription = service.addChannelEventHandler(
          conversationId: request.conversationId,
          sessionId: request.sessionId,
          requireFocus: request.requireFocus,
          handler: (event, ack) {
            _controller?.add(
              ConversationDelta.fromSocketEvent(
                ConversationDeltaSource.channel,
                event,
                ack,
              ),
            );
          },
        );
        break;
    }
  }

  void _maybeTearDownSocket() {
    if (_controller?.hasListener == true) {
      return;
    }
    _socketSubscription?.dispose();
    _socketSubscription = null;
  }
}

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
  final isAuthenticated = ref.watch(isAuthenticatedProvider2);

  if (api == null || !isAuthenticated) return null;

  try {
    return await api.getCurrentUser();
  } catch (e) {
    return null;
  }
}

// Helper provider to force refresh auth state - now using unified system
final refreshAuthStateProvider = Provider<void>((ref) {
  // This provider can be invalidated to force refresh the unified auth system
  Future.microtask(() => ref.read(authActionsProvider).refresh());
  return;
});

// Model providers
@Riverpod(keepAlive: true)
Future<List<Model>> models(Ref ref) async {
  // Reviewer mode returns mock models
  final reviewerMode = ref.watch(reviewerModeProvider);
  if (reviewerMode) {
    return [
      const Model(
        id: 'demo/gemma-2-mini',
        name: 'Gemma 2 Mini (Demo)',
        description: 'Demo model for reviewer mode',
        isMultimodal: true,
        supportsStreaming: true,
        supportedParameters: ['max_tokens', 'stream'],
      ),
      const Model(
        id: 'demo/llama-3-8b',
        name: 'Llama 3 8B (Demo)',
        description: 'Fast text model for demo',
        isMultimodal: false,
        supportsStreaming: true,
        supportedParameters: ['max_tokens', 'stream'],
      ),
    ];
  }
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    DebugLogger.log('fetch-start', scope: 'models');
    final models = await api.getModels();
    DebugLogger.log(
      'fetch-ok',
      scope: 'models',
      data: {'count': models.length},
    );
    return models;
  } catch (e) {
    DebugLogger.error('fetch-failed', scope: 'models', error: e);

    // If models endpoint returns 403, this should now clear auth token
    // and redirect user to login since it's marked as a core endpoint
    if (e.toString().contains('403')) {
      DebugLogger.warning('endpoint-403', scope: 'models');
    }

    return [];
  }
}

@Riverpod(keepAlive: true)
class SelectedModel extends _$SelectedModel {
  @override
  Model? build() => null;

  void set(Model? model) => state = model;

  void clear() => state = null;
}

// Track if the current model selection is manual (user-selected) or automatic (default)
@Riverpod(keepAlive: true)
class IsManualModelSelection extends _$IsManualModelSelection {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

// Listen for settings changes and reset manual selection when default model changes
// keepAlive to maintain listener throughout app lifecycle
final _settingsWatcherProvider = Provider<void>((ref) {
  ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
    if (previous?.defaultModel != next.defaultModel) {
      // Reset manual selection when default model changes
      ref.read(isManualModelSelectionProvider.notifier).set(false);
    }
  });
});

// Auto-apply model-specific tools when model changes or tools load
final modelToolsAutoSelectionProvider = Provider<void>((ref) {
  Future<void> applyTools(Model? model) async {
    if (model == null) {
      final current = ref.read(selectedToolIdsProvider);
      if (current.isNotEmpty) {
        ref.read(selectedToolIdsProvider.notifier).set([]);
      }
      return;
    }

    final modelToolIds = model.toolIds ?? [];
    if (modelToolIds.isEmpty) {
      final current = ref.read(selectedToolIdsProvider);
      if (current.isNotEmpty) {
        ref.read(selectedToolIdsProvider.notifier).set([]);
      }
      return;
    }

    void updateSelection(List<Tool> availableTools) {
      final validToolIds = modelToolIds
          .where((id) => availableTools.any((tool) => tool.id == id))
          .toList();

      final currentSelection = ref.read(selectedToolIdsProvider);
      if (validToolIds.isEmpty) {
        if (currentSelection.isNotEmpty) {
          ref.read(selectedToolIdsProvider.notifier).set([]);
        }
        return;
      }
      if (listEquals(currentSelection, validToolIds)) return;

      ref.read(selectedToolIdsProvider.notifier).set(validToolIds);
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

// Auto-apply default model from settings when it changes (and not manually overridden)
// keepAlive to maintain listener throughout app lifecycle
final defaultModelAutoSelectionProvider = Provider<void>((ref) {
  // Initialize the model tools auto-selection
  ref.watch(modelToolsAutoSelectionProvider);

  ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
    // Only react when default model value changes
    if (previous?.defaultModel == next.defaultModel) return;

    // Do not override manual selections
    if (ref.read(isManualModelSelectionProvider)) return;

    final desired = next.defaultModel;
    if (desired == null || desired.isEmpty) return;

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
  final notifier = ref.read(conversationsProvider.notifier);
  unawaited(notifier.refresh(includeFolders: includeFolders));
  if (includeFolders) {
    final foldersNotifier = ref.read(foldersProvider.notifier);
    unawaited(foldersNotifier.refresh());
  }
}

// Conversation providers - Now using correct OpenWebUI API with caching and
// immediate mutation helpers.
@Riverpod(keepAlive: true)
class Conversations extends _$Conversations {
  @override
  Future<List<Conversation>> build() async {
    final authed = ref.watch(isAuthenticatedProvider2);
    if (!authed) {
      DebugLogger.log('skip-unauthed', scope: 'conversations');
      _updateCacheTimestamp(null);
      _persistConversationsAsync(const <Conversation>[]);
      return const [];
    }

    if (ref.watch(reviewerModeProvider)) {
      return _demoConversations();
    }

    final storage = ref.read(optimizedStorageServiceProvider);
    try {
      final cached = await storage.getLocalConversations();
      if (cached.isNotEmpty) {
        final sortedCached = _sortByUpdatedAt(cached);
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
        DebugLogger.log(
          'cache-restored',
          scope: 'conversations/cache',
          data: {'count': sortedCached.length},
        );
        return sortedCached;
      }
      DebugLogger.log('cache-empty', scope: 'conversations/cache');
    } catch (error, stackTrace) {
      DebugLogger.error(
        'cache-load-failed',
        scope: 'conversations/cache',
        error: error,
        stackTrace: stackTrace,
      );
    }

    final fresh = await _loadRemoteConversations();
    _persistConversationsAsync(fresh);
    return fresh;
  }

  Future<void> refresh({bool includeFolders = false}) async {
    final authed = ref.read(isAuthenticatedProvider2);
    if (!authed) {
      _updateCacheTimestamp(null);
      state = AsyncData<List<Conversation>>(<Conversation>[]);
      _persistConversationsAsync(const <Conversation>[]);
      if (includeFolders) {
        unawaited(ref.read(foldersProvider.notifier).refresh());
      }
      return;
    }

    if (ref.read(reviewerModeProvider)) {
      state = AsyncData<List<Conversation>>(_demoConversations());
      if (includeFolders) {
        unawaited(ref.read(foldersProvider.notifier).refresh());
      }
      return;
    }

    final result = await AsyncValue.guard(_loadRemoteConversations);
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
          DebugLogger.log(
            'cache-saved',
            scope: 'conversations/cache',
            data: {'count': conversations.length},
          );
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

  Future<List<Conversation>> _loadRemoteConversations() async {
    final api = ref.watch(apiServiceProvider);
    if (api == null) {
      DebugLogger.warning('api-missing', scope: 'conversations');
      return const [];
    }

    try {
      DebugLogger.log('fetch-start', scope: 'conversations');
      final conversations = await api.getConversations();
      DebugLogger.log(
        'fetch-ok',
        scope: 'conversations',
        data: {'count': conversations.length},
      );

      try {
        final foldersData = await api.getFolders();
        DebugLogger.log(
          'folders-fetched',
          scope: 'conversations',
          data: {'count': foldersData.length},
        );

        final folders = foldersData
            .map((folderData) => Folder.fromJson(folderData))
            .toList();

        final conversationToFolder = <String, String>{};
        for (final folder in folders) {
          DebugLogger.log(
            'folder',
            scope: 'conversations/map',
            data: {
              'id': folder.id,
              'name': folder.name,
              'count': folder.conversationIds.length,
            },
          );
          for (final conversationId in folder.conversationIds) {
            conversationToFolder[conversationId] = folder.id;
            DebugLogger.log(
              'map',
              scope: 'conversations/map',
              data: {'conversationId': conversationId, 'folderId': folder.id},
            );
          }
        }

        final conversationMap = <String, Conversation>{};

        for (final conversation in conversations) {
          final explicitFolderId = conversation.folderId;
          final mappedFolderId = conversationToFolder[conversation.id];
          final folderIdToUse = explicitFolderId ?? mappedFolderId;
          if (folderIdToUse != null) {
            conversationMap[conversation.id] = conversation.copyWith(
              folderId: folderIdToUse,
            );
            DebugLogger.log(
              'update-folder',
              scope: 'conversations/map',
              data: {
                'conversationId': conversation.id,
                'folderId': folderIdToUse,
                'explicit': explicitFolderId != null,
              },
            );
          } else {
            conversationMap[conversation.id] = conversation;
          }
        }

        final existingIds = conversationMap.keys.toSet();
        final missingInBase = conversationToFolder.keys
            .where((id) => !existingIds.contains(id))
            .toList();
        if (missingInBase.isNotEmpty) {
          DebugLogger.warning(
            'missing-in-base',
            scope: 'conversations/map',
            data: {
              'count': missingInBase.length,
              'preview': missingInBase.take(5).toList(),
            },
          );
        } else {
          DebugLogger.log('folders-synced', scope: 'conversations/map');
        }

        for (final folder in folders) {
          final missingIds = folder.conversationIds
              .where((id) => !existingIds.contains(id))
              .toList();

          final hasKnownConversations = conversationMap.values.any(
            (conversation) => conversation.folderId == folder.id,
          );

          final shouldFetchFolder =
              missingIds.isNotEmpty ||
              (!hasKnownConversations && folder.conversationIds.isEmpty);

          List<Conversation> folderConvs = const [];
          if (shouldFetchFolder) {
            try {
              folderConvs = await api.getConversationsInFolder(folder.id);
              DebugLogger.log(
                'folder-sync',
                scope: 'conversations/map',
                data: {
                  'folderId': folder.id,
                  'fetched': folderConvs.length,
                  'missingIds': missingIds.length,
                },
              );
            } catch (e) {
              DebugLogger.error(
                'folder-fetch-failed',
                scope: 'conversations/map',
                error: e,
                data: {'folderId': folder.id},
              );
            }
          }

          final fetchedMap = {for (final c in folderConvs) c.id: c};

          for (final convId in missingIds) {
            final fetched = fetchedMap[convId];
            if (fetched != null) {
              final toAdd = fetched.folderId == null
                  ? fetched.copyWith(folderId: folder.id)
                  : fetched;
              conversationMap[toAdd.id] = toAdd;
              existingIds.add(toAdd.id);
              DebugLogger.log(
                'add-missing',
                scope: 'conversations/map',
                data: {'conversationId': toAdd.id, 'folderId': folder.id},
              );
            } else {
              final placeholder = Conversation(
                id: convId,
                title: 'Chat',
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
                messages: const [],
                folderId: folder.id,
              );
              conversationMap[convId] = placeholder;
              existingIds.add(convId);
              DebugLogger.log(
                'add-placeholder',
                scope: 'conversations/map',
                data: {'conversationId': convId, 'folderId': folder.id},
              );
            }
          }

          if (folderConvs.isNotEmpty && folder.conversationIds.isEmpty) {
            for (final conv in folderConvs) {
              final toAdd = conv.folderId == null
                  ? conv.copyWith(folderId: folder.id)
                  : conv;
              conversationMap[toAdd.id] = toAdd;
              existingIds.add(toAdd.id);
              DebugLogger.log(
                'add-folder-fetch',
                scope: 'conversations/map',
                data: {'conversationId': toAdd.id, 'folderId': folder.id},
              );
            }
          }
        }

        final sortedConversations = _sortByUpdatedAt(
          conversationMap.values.toList(),
        );
        DebugLogger.log(
          'sort',
          scope: 'conversations',
          data: {'source': 'folder-sync'},
        );
        _updateCacheTimestamp(DateTime.now());
        return sortedConversations;
      } catch (e) {
        DebugLogger.error(
          'folders-fetch-failed',
          scope: 'conversations',
          error: e,
        );
        final sorted = _sortByUpdatedAt(conversations.toList());
        DebugLogger.log(
          'sort',
          scope: 'conversations',
          data: {'source': 'fallback'},
        );
        _updateCacheTimestamp(DateTime.now());
        return sorted;
      }
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

  // Initialize the settings watcher (side-effect only)
  ref.read(_settingsWatcherProvider);
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

    // 1) Fast path: read stored default model ID directly and select optimistically
    try {
      final storedDefaultId = await SettingsService.getDefaultModel();
      if (storedDefaultId != null && storedDefaultId.isNotEmpty) {
        if (!ref.read(isManualModelSelectionProvider)) {
          final placeholder = Model(
            id: storedDefaultId,
            name: storedDefaultId,
            supportsStreaming: true,
          );
          ref.read(selectedModelProvider.notifier).set(placeholder);
        }
        // Reconcile against real models in background
        Future.microtask(() async {
          try {
            if (!ref.mounted) return;
            final models = await ref.read(modelsProvider.future);
            if (!ref.mounted) return;

            Model? resolved;
            try {
              resolved = models.firstWhere((m) => m.id == storedDefaultId);
            } catch (_) {
              final byName = models
                  .where((m) => m.name == storedDefaultId)
                  .toList();
              if (byName.length == 1) resolved = byName.first;
            }
            resolved ??= models.isNotEmpty ? models.first : null;

            if (!ref.mounted) return;
            if (resolved != null && !ref.read(isManualModelSelectionProvider)) {
              ref.read(selectedModelProvider.notifier).set(resolved);
              DebugLogger.log(
                'reconcile',
                scope: 'models/default',
                data: {'name': resolved.name, 'source': 'stored'},
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

    // 2) Fast server path: query server default ID without listing all models
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
        if (value is String) return value.toLowerCase() == 'true';
      }
      return false;
    },
    orElse: () => false,
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
        if (value is String) return value.toLowerCase() == 'true';
      }
      return false;
    },
    orElse: () => false,
  );
});

// Folders provider
@Riverpod(keepAlive: true)
class Folders extends _$Folders {
  @override
  Future<List<Folder>> build() async {
    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'folders');
      return const [];
    }
    final api = ref.watch(apiServiceProvider);
    if (api == null) {
      DebugLogger.warning('api-missing', scope: 'folders');
      return const [];
    }
    return _load(api);
  }

  Future<void> refresh() async {
    if (!ref.read(isAuthenticatedProvider2)) {
      state = const AsyncData<List<Folder>>([]);
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = const AsyncData<List<Folder>>([]);
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
    state = AsyncData<List<Folder>>(_sort(updated));
  }

  void updateFolder(String id, Folder Function(Folder folder) transform) {
    final current = state.asData?.value;
    if (current == null) return;
    final index = current.indexWhere((folder) => folder.id == id);
    if (index < 0) return;
    final updated = <Folder>[...current];
    updated[index] = transform(updated[index]);
    state = AsyncData<List<Folder>>(_sort(updated));
  }

  void removeFolder(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    final updated = current
        .where((folder) => folder.id != id)
        .toList(growable: true);
    state = AsyncData<List<Folder>>(_sort(updated));
  }

  Future<List<Folder>> _load(ApiService api) async {
    try {
      final foldersData = await api.getFolders();
      final folders = foldersData
          .map((folderData) => Folder.fromJson(folderData))
          .toList();
      DebugLogger.log(
        'fetch-ok',
        scope: 'folders',
        data: {'count': folders.length},
      );
      return _sort(folders);
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

  List<Folder> _sort(List<Folder> input) {
    final sorted = [...input];
    sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List<Folder>.unmodifiable(sorted);
  }
}

// Files provider
@Riverpod(keepAlive: true)
class UserFiles extends _$UserFiles {
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
    final current = state.asData?.value ?? const <FileInfo>[];
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
      final files = await api.getUserFiles();
      return _sort(files);
    } catch (e, stackTrace) {
      DebugLogger.error(
        'files-failed',
        scope: 'files',
        error: e,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  List<FileInfo> _sort(List<FileInfo> input) {
    final sorted = [...input];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<FileInfo>.unmodifiable(sorted);
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
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    final voices = await api.getAvailableServerVoices();
    return voices
        .map((v) => (v['name'] ?? v['id'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toList();
  } catch (e) {
    DebugLogger.error('voices-failed', scope: 'voices', error: e);
    return [];
  }
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
