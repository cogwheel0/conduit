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
import '../../shared/theme/color_palettes.dart';
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
  AppColorPalette build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final storedId = _storage.getThemePaletteId();
    return AppColorPalettes.byId(storedId);
  }

  Future<void> setPalette(String paletteId) async {
    final palette = AppColorPalettes.byId(paletteId);
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
      return Locale(code);
    }
    return null; // system default
  }

  Future<void> setLocale(Locale? locale) async {
    state = locale;
    await _storage.setLocaleCode(locale?.languageCode);
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

// API Service provider with unified auth integration
final apiServiceProvider = Provider<ApiService?>((ref) {
  // If reviewer mode is enabled, skip creating ApiService
  final reviewerMode = ref.watch(reviewerModeProvider);
  if (reviewerMode) {
    return null;
  }
  final activeServer = ref.watch(activeServerProvider);

  return activeServer.maybeWhen(
    data: (server) {
      if (server == null) return null;

      final apiService = ApiService(
        serverConfig: server,
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

    // Don't watch authTokenProvider3 here to avoid rebuilding on token changes
    // Token updates are handled via the subscription below
    final token = ref.read(authTokenProvider3);

    final requiresNewService =
        _service == null ||
        _service!.serverConfig.id != server.id ||
        _service!.websocketOnly != websocketOnly;
    if (requiresNewService) {
      _disposeService();
      _service = SocketService(
        serverConfig: server,
        authToken: token,
        websocketOnly: websocketOnly,
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

enum SocketConnectionState { disconnected, connecting, connected }

@Riverpod(keepAlive: true)
class SocketConnectionStream extends _$SocketConnectionStream {
  StreamController<SocketConnectionState>? _controller;
  ProviderSubscription<AsyncValue<SocketService?>>? _serviceSubscription;
  VoidCallback? _cancelConnectListener;
  VoidCallback? _cancelDisconnectListener;
  SocketConnectionState _latestState = SocketConnectionState.connecting;

  @override
  Stream<SocketConnectionState> build() {
    final controller = StreamController<SocketConnectionState>.broadcast(
      sync: true,
    );
    controller
      ..onListen = _primeState
      ..onCancel = _maybeNotifyDisconnected;
    _controller = controller;

    final initialService = ref
        .watch(socketServiceManagerProvider)
        .maybeWhen(data: (service) => service, orElse: () => null);
    _handleServiceChange(initialService);

    _serviceSubscription = ref.listen<AsyncValue<SocketService?>>(
      socketServiceManagerProvider,
      (_, next) => _handleServiceChange(
        next.maybeWhen(data: (service) => service, orElse: () => null),
      ),
    );

    ref.onDispose(() {
      _serviceSubscription?.close();
      _serviceSubscription = null;
      _unbindSocket();
      _controller?.close();
      _controller = null;
    });

    return controller.stream;
  }

  /// Publishes a disconnected state when the final listener cancels.
  void _maybeNotifyDisconnected() {
    try {
      _controller?.add(SocketConnectionState.disconnected);
      _latestState = SocketConnectionState.disconnected;
    } catch (_) {}
  }

  /// Replays the cached state to new listeners.
  void _primeState() {
    try {
      _controller?.add(_latestState);
    } catch (_) {}
  }

  void _handleServiceChange(SocketService? service) {
    if (service == null) {
      _unbindSocket();
      _emit(SocketConnectionState.connecting);
      return;
    }

    _emit(
      service.isConnected
          ? SocketConnectionState.connected
          : SocketConnectionState.connecting,
    );
    _bindSocket(service);
  }

  void _bindSocket(SocketService service) {
    _unbindSocket();

    void handleConnect(dynamic _) {
      _emit(SocketConnectionState.connected);
    }

    void handleDisconnect(dynamic _) {
      _emit(SocketConnectionState.disconnected);
    }

    service.socket?.on('connect', handleConnect);
    service.socket?.on('disconnect', handleDisconnect);

    _cancelConnectListener = () {
      service.socket?.off('connect', handleConnect);
    };
    _cancelDisconnectListener = () {
      service.socket?.off('disconnect', handleDisconnect);
    };
  }

  void _emit(SocketConnectionState next) {
    if (_latestState == next) {
      return;
    }
    _latestState = next;
    try {
      _controller?.add(next);
    } catch (_) {}
  }

  void _unbindSocket() {
    _cancelConnectListener?.call();
    _cancelDisconnectListener?.call();
    _cancelConnectListener = null;
    _cancelDisconnectListener = null;
  }
}

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

/// Clears the in-memory timestamp cache and invalidates the conversations
/// provider so the next read forces a refetch. Optionally invalidates the
/// folders provider when folder metadata must stay in sync with conversations.
void refreshConversationsCache(dynamic ref, {bool includeFolders = false}) {
  ref.read(_conversationsCacheTimestampProvider.notifier).set(null);
  ref.invalidate(conversationsProvider);
  if (includeFolders) {
    ref.invalidate(foldersProvider);
  }
}

// Conversation providers - Now using correct OpenWebUI API with caching
// keepAlive to maintain cache during authenticated session
@Riverpod(keepAlive: true)
Future<List<Conversation>> conversations(Ref ref) async {
  // Do not fetch protected data until authenticated. Use watch so we refetch
  // when the auth state transitions in either direction.
  final authed = ref.watch(isAuthenticatedProvider2);
  if (!authed) {
    DebugLogger.log('skip-unauthed', scope: 'conversations');
    return [];
  }
  // Check if we have a recent cache (within 5 seconds)
  final lastFetch = ref.read(_conversationsCacheTimestampProvider);
  if (lastFetch != null && DateTime.now().difference(lastFetch).inSeconds < 5) {
    DebugLogger.log(
      'cache-hit',
      scope: 'conversations',
      data: {'ageSecs': DateTime.now().difference(lastFetch).inSeconds},
    );
    // Note: Can't read our own provider here, would cause a cycle
    // The caching is handled by Riverpod's built-in mechanism
  }
  final reviewerMode = ref.watch(reviewerModeProvider);
  if (reviewerMode) {
    // Provide a simple local demo conversation list
    return [
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
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    DebugLogger.warning('api-missing', scope: 'conversations');
    return [];
  }

  // On initial load, check if we have cached conversations and return them immediately
  // to avoid showing a loading indicator. Fresh data will be fetched in background.
  final storage = ref.watch(optimizedStorageServiceProvider);
  final cachedConversations = await storage.getLocalConversations();
  final hasCache = cachedConversations.isNotEmpty;

  if (hasCache && lastFetch == null) {
    // First load with cache available - return cached data immediately
    // and schedule a background fetch to update it
    DebugLogger.log(
      'cache-warmstart',
      scope: 'conversations',
      data: {'count': cachedConversations.length},
    );

    // Schedule background fetch to update cache
    Future.microtask(() async {
      try {
        DebugLogger.log('bg-fetch-start', scope: 'conversations');
        final fresh = await api.getConversations();
        if (!ref.mounted) return;

        // Update cache timestamp to prevent rapid refetches
        ref
            .read(_conversationsCacheTimestampProvider.notifier)
            .set(DateTime.now());

        // Save to local cache for next startup
        await storage.saveLocalConversations(fresh);

        // Invalidate provider to trigger UI update with fresh data
        ref.invalidate(conversationsProvider);

        DebugLogger.log(
          'bg-fetch-complete',
          scope: 'conversations',
          data: {'count': fresh.length},
        );
      } catch (e) {
        DebugLogger.error('bg-fetch-failed', scope: 'conversations', error: e);
      }
    });

    return cachedConversations;
  }

  try {
    DebugLogger.log('fetch-start', scope: 'conversations');
    final conversations = await api
        .getConversations(); // Fetch all conversations
    DebugLogger.log(
      'fetch-ok',
      scope: 'conversations',
      data: {'count': conversations.length},
    );

    // Also fetch folder information and update conversations with folder IDs
    try {
      final foldersData = await api.getFolders();
      DebugLogger.log(
        'folders-fetched',
        scope: 'conversations',
        data: {'count': foldersData.length},
      );

      // Parse folder data into Folder objects
      final folders = foldersData
          .map((folderData) => Folder.fromJson(folderData))
          .toList();

      // Create a map of conversation ID to folder ID
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

      // Update conversations with folder IDs, preferring explicit folder_id from chat if present
      // Use a map to ensure uniqueness by ID throughout the merge process
      final conversationMap = <String, Conversation>{};

      for (final conversation in conversations) {
        // Prefer server-provided folderId on the chat itself
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

      // Merge conversations that are in folders but missing from the main list
      // Build a set of existing IDs from the fetched list
      final existingIds = conversationMap.keys.toSet();

      // Diagnostics: count how many folder-mapped IDs are missing from the main list
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

      // Attempt to fetch missing conversations per-folder to construct accurate entries
      // If per-folder fetch fails, fall back to creating minimal placeholder entries
      final apiSvc = ref.read(apiServiceProvider);
      for (final folder in folders) {
        // Collect IDs in this folder that are missing
        final missingIds = folder.conversationIds
            .where((id) => !existingIds.contains(id))
            .toList();

        final hasKnownConversations = conversationMap.values.any(
          (conversation) => conversation.folderId == folder.id,
        );

        final shouldFetchFolder =
            apiSvc != null &&
            (missingIds.isNotEmpty ||
                (!hasKnownConversations && folder.conversationIds.isEmpty));

        List<Conversation> folderConvs = const [];
        if (shouldFetchFolder) {
          try {
            folderConvs = await apiSvc.getConversationsInFolder(folder.id);
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

        // Index fetched folder conversations for quick lookup
        final fetchedMap = {for (final c in folderConvs) c.id: c};

        for (final convId in missingIds) {
          final fetched = fetchedMap[convId];
          if (fetched != null) {
            final toAdd = fetched.folderId == null
                ? fetched.copyWith(folderId: folder.id)
                : fetched;
            // Use map to prevent duplicates - this will overwrite if ID already exists
            conversationMap[toAdd.id] = toAdd;
            existingIds.add(toAdd.id);
            DebugLogger.log(
              'add-missing',
              scope: 'conversations/map',
              data: {'conversationId': toAdd.id, 'folderId': folder.id},
            );
          } else {
            // Create a minimal placeholder if not returned by folder API
            final placeholder = Conversation(
              id: convId,
              title: 'Chat',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              messages: const [],
              folderId: folder.id,
            );
            // Use map to prevent duplicates
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

      // Convert map back to list - this ensures no duplicates by ID
      final sortedConversations = conversationMap.values.toList();

      // Sort conversations by updatedAt in descending order (most recent first)
      sortedConversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      DebugLogger.log(
        'sort',
        scope: 'conversations',
        data: {'source': 'folder-sync'},
      );

      // Update cache timestamp
      ref
          .read(_conversationsCacheTimestampProvider.notifier)
          .set(DateTime.now());

      // Save to local cache for next startup
      await storage.saveLocalConversations(sortedConversations);

      return sortedConversations;
    } catch (e) {
      DebugLogger.error(
        'folders-fetch-failed',
        scope: 'conversations',
        error: e,
      );
      // Sort conversations even when folder fetch fails
      conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      DebugLogger.log(
        'sort',
        scope: 'conversations',
        data: {'source': 'fallback'},
      );

      // Update cache timestamp
      ref
          .read(_conversationsCacheTimestampProvider.notifier)
          .set(DateTime.now());

      // Save to local cache for next startup
      await storage.saveLocalConversations(conversations);

      return conversations; // Return original conversations if folder fetch fails
    }
  } catch (e, stackTrace) {
    DebugLogger.error(
      'fetch-failed',
      scope: 'conversations',
      error: e,
      stackTrace: stackTrace,
    );

    // If conversations endpoint returns 403, this should now clear auth token
    // and redirect user to login since it's marked as a core endpoint
    if (e.toString().contains('403')) {
      DebugLogger.warning('endpoint-403', scope: 'conversations');
    }

    // Return empty list instead of re-throwing to allow app to continue functioning
    return [];
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
Future<List<Folder>> folders(Ref ref) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'folders');
    return [];
  }
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    DebugLogger.warning('api-missing', scope: 'folders');
    return [];
  }

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
    return folders;
  } catch (e) {
    DebugLogger.error('fetch-failed', scope: 'folders', error: e);
    return [];
  }
}

// Files provider
@Riverpod(keepAlive: true)
Future<List<FileInfo>> userFiles(Ref ref) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'files');
    return [];
  }
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    final filesData = await api.getUserFiles();
    return filesData.map((fileData) => FileInfo.fromJson(fileData)).toList();
  } catch (e) {
    DebugLogger.error('files-failed', scope: 'files', error: e);
    return [];
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
Future<List<KnowledgeBase>> knowledgeBases(Ref ref) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'knowledge');
    return [];
  }
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    final kbData = await api.getKnowledgeBases();
    return kbData.map((data) => KnowledgeBase.fromJson(data)).toList();
  } catch (e) {
    DebugLogger.error('knowledge-bases-failed', scope: 'knowledge', error: e);
    return [];
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
    final itemsData = await api.getKnowledgeBaseItems(kbId);
    return itemsData.map((data) => KnowledgeBaseItem.fromJson(data)).toList();
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
    return await api.getAvailableVoices();
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
