import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/storage_service.dart';
// (removed duplicate) import '../services/optimized_storage_service.dart';
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
import '../models/knowledge_base.dart';
import '../services/settings_service.dart';
import '../services/optimized_storage_service.dart';
import '../utils/debug_logger.dart';

// Storage providers
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError();
});

final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage();
});

final storageServiceProvider = Provider<StorageService>((ref) {
  return StorageService(
    secureStorage: ref.watch(secureStorageProvider),
    prefs: ref.watch(sharedPreferencesProvider),
  );
});

// Optimized storage service provider
final optimizedStorageServiceProvider = Provider<OptimizedStorageService>((
  ref,
) {
  return OptimizedStorageService(
    secureStorage: ref.watch(secureStorageProvider),
    prefs: ref.watch(sharedPreferencesProvider),
  );
});

// Theme provider
final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((
  ref,
) {
  final storage = ref.watch(optimizedStorageServiceProvider);
  return ThemeModeNotifier(storage);
});

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  final OptimizedStorageService _storage;

  ThemeModeNotifier(this._storage) : super(ThemeMode.system) {
    _loadTheme();
  }

  void _loadTheme() {
    final mode = _storage.getThemeMode();
    if (mode != null) {
      state = ThemeMode.values.firstWhere(
        (e) => e.toString() == mode,
        orElse: () => ThemeMode.system,
      );
    }
  }

  void setTheme(ThemeMode mode) {
    state = mode;
    _storage.setThemeMode(mode.toString());
  }
}

// Locale provider
final localeProvider = StateNotifierProvider<LocaleNotifier, Locale?>((ref) {
  final storage = ref.watch(optimizedStorageServiceProvider);
  return LocaleNotifier(storage);
});

class LocaleNotifier extends StateNotifier<Locale?> {
  final OptimizedStorageService _storage;

  LocaleNotifier(this._storage) : super(null) {
    _loadLocale();
  }

  void _loadLocale() {
    final code = _storage.getLocaleCode();
    if (code != null && code.isNotEmpty) {
      state = Locale(code);
    } else {
      state = null; // system
    }
  }

  Future<void> setLocale(Locale? locale) async {
    state = locale;
    await _storage.setLocaleCode(locale?.languageCode);
  }
}

// TTS Language provider
final ttsLanguageProvider = StateNotifierProvider<TTSLanguageNotifier, String?>(
  (ref) {
    final storage = ref.watch(optimizedStorageServiceProvider);
    return TTSLanguageNotifier(storage);
  },
);

class TTSLanguageNotifier extends StateNotifier<String?> {
  final OptimizedStorageService _storage;

  TTSLanguageNotifier(this._storage) : super(null) {
    _loadTTSLanguage();
  }

  void _loadTTSLanguage() {
    final languageCode = _storage.getTTSLanguage();
    state = languageCode; // null means system default
  }

  Future<void> setTTSLanguage(String? languageCode) async {
    state = languageCode;
    await _storage.setTTSLanguage(languageCode);
  }
}

// Server connection providers - optimized with caching
final serverConfigsProvider = FutureProvider<List<ServerConfig>>((ref) async {
  final storage = ref.watch(optimizedStorageServiceProvider);
  return storage.getServerConfigs();
});

final activeServerProvider = FutureProvider<ServerConfig?>((ref) async {
  final storage = ref.watch(optimizedStorageServiceProvider);
  final configs = await ref.watch(serverConfigsProvider.future);
  final activeId = await storage.getActiveServerId();

  if (activeId == null || configs.isEmpty) return null;

  return configs.firstWhere(
    (config) => config.id == activeId,
    orElse: () => configs.first,
  );
});

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
        foundation.debugPrint(
          'DEBUG: Legacy auth invalidation callback triggered',
        );
      };

      // Initialize with any existing token immediately
      final token = ref.read(authTokenProvider3);
      if (token != null && token.isNotEmpty) {
        apiService.updateAuthToken(token);
      }

      return apiService;
    },
    orElse: () => null,
  );
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
  // Listen to unified auth token changes and update API service
  ref.listen(authTokenProvider3, (previous, next) {
    final api = ref.read(apiServiceProvider);
    if (api != null && next != null && next.isNotEmpty) {
      api.updateAuthToken(next);
      foundation.debugPrint(
        'DEBUG: Updated API service with unified auth token',
      );
    }
  });
});

final currentUserProvider = FutureProvider<User?>((ref) async {
  final api = ref.read(apiServiceProvider);
  final isAuthenticated = ref.watch(isAuthenticatedProvider2);

  if (api == null || !isAuthenticated) return null;

  try {
    return await api.getCurrentUser();
  } catch (e) {
    return null;
  }
});

// Helper provider to force refresh auth state - now using unified system
final refreshAuthStateProvider = Provider<void>((ref) {
  // This provider can be invalidated to force refresh the unified auth system
  Future.microtask(() => ref.read(authActionsProvider).refresh());
  return;
});

// Model providers
final modelsProvider = FutureProvider<List<Model>>((ref) async {
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
    DebugLogger.log('Fetching models from server');
    final models = await api.getModels();
    DebugLogger.log('Successfully fetched ${models.length} models');
    return models;
  } catch (e) {
    foundation.debugPrint('ERROR: Failed to fetch models: $e');

    // If models endpoint returns 403, this should now clear auth token
    // and redirect user to login since it's marked as a core endpoint
    if (e.toString().contains('403')) {
      DebugLogger.warning(
        'Models endpoint returned 403 - authentication may be invalid',
      );
    }

    return [];
  }
});

final selectedModelProvider = StateProvider<Model?>((ref) => null);

// Track if the current model selection is manual (user-selected) or automatic (default)
final isManualModelSelectionProvider = StateProvider<bool>((ref) => false);

// Listen for settings changes and reset manual selection when default model changes
final _settingsWatcherProvider = Provider<void>((ref) {
  ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
    if (previous?.defaultModel != next.defaultModel) {
      // Reset manual selection when default model changes
      ref.read(isManualModelSelectionProvider.notifier).state = false;
    }
  });
});

// Auto-apply default model from settings when it changes (and not manually overridden)
final defaultModelAutoSelectionProvider = Provider<void>((ref) {
  ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
    // Only react when default model value changes
    if (previous?.defaultModel == next.defaultModel) return;

    // Do not override manual selections
    if (ref.read(isManualModelSelectionProvider)) return;

    final desired = next.defaultModel;
    if (desired == null || desired.isEmpty) return;

    // Resolve the desired model against available models
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
          selected = models.firstWhere(
            (model) =>
                model.id == desired ||
                model.name == desired ||
                model.id.contains(desired) ||
                model.name.contains(desired),
          );
        } catch (_) {}

        // Fallback: keep current selection or pick first available
        selected ??=
            ref.read(selectedModelProvider) ??
            (models.isNotEmpty ? models.first : null);

        if (selected != null) {
          ref.read(selectedModelProvider.notifier).state = selected;
          foundation.debugPrint(
            'DEBUG: Auto-applied default model from settings: ${selected.name}',
          );
        }
      } catch (e) {
        foundation.debugPrint(
          'DEBUG: defaultModel auto-selection listener failed: $e',
        );
      }
    });
  });
});

// Cache timestamp for conversations to prevent rapid re-fetches
final _conversationsCacheTimestamp = StateProvider<DateTime?>((ref) => null);

// Conversation providers - Now using correct OpenWebUI API with caching
final conversationsProvider = FutureProvider<List<Conversation>>((ref) async {
  // Check if we have a recent cache (within 5 seconds)
  final lastFetch = ref.read(_conversationsCacheTimestamp);
  if (lastFetch != null && DateTime.now().difference(lastFetch).inSeconds < 5) {
    DebugLogger.log(
      'Using cached conversations (fetched ${DateTime.now().difference(lastFetch).inSeconds}s ago)',
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
    DebugLogger.log('No API service available');
    return [];
  }

  try {
    DebugLogger.log('Fetching conversations from OpenWebUI API...');
    final conversations = await api
        .getConversations(); // Fetch all conversations
    DebugLogger.log(
      'Successfully fetched ${conversations.length} conversations',
    );

    // Also fetch folder information and update conversations with folder IDs
    try {
      final foldersData = await api.getFolders();
      DebugLogger.log(
        'Fetched ${foldersData.length} folders for conversation mapping',
      );

      // Parse folder data into Folder objects
      final folders = foldersData
          .map((folderData) => Folder.fromJson(folderData))
          .toList();

      // Create a map of conversation ID to folder ID
      final conversationToFolder = <String, String>{};
      for (final folder in folders) {
        foundation.debugPrint(
          'DEBUG: Folder "${folder.name}" (${folder.id}) has ${folder.conversationIds.length} conversations',
        );
        for (final conversationId in folder.conversationIds) {
          conversationToFolder[conversationId] = folder.id;
          foundation.debugPrint(
            'DEBUG: Mapping conversation $conversationId to folder ${folder.id}',
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
          final _idPreview = conversation.id.length > 8
              ? conversation.id.substring(0, 8)
              : conversation.id;
          foundation.debugPrint(
            'DEBUG: Updated conversation $_idPreview with folderId: $folderIdToUse (explicit: ${explicitFolderId != null})',
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
        foundation.debugPrint(
          'DEBUG: ${missingInBase.length} conversations referenced by folders are missing from base list',
        );
        final preview = missingInBase.take(10).toList();
        foundation.debugPrint(
          'DEBUG: Missing IDs sample: $preview${missingInBase.length > 10 ? ' ...' : ''}',
        );
      } else {
        foundation.debugPrint(
          'DEBUG: All folder-referenced conversations are present in base list',
        );
      }

      // Attempt to fetch missing conversations per-folder to construct accurate entries
      // If per-folder fetch fails, fall back to creating minimal placeholder entries
      final apiSvc = ref.read(apiServiceProvider);
      for (final folder in folders) {
        // Collect IDs in this folder that are missing
        final missingIds = folder.conversationIds
            .where((id) => !existingIds.contains(id))
            .toList();
        if (missingIds.isEmpty) continue;

        List<Conversation> folderConvs = const [];
        try {
          if (apiSvc != null) {
            folderConvs = await apiSvc.getConversationsInFolder(folder.id);
          }
        } catch (e) {
          foundation.debugPrint(
            'DEBUG: getConversationsInFolder failed for ${folder.id}: $e',
          );
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
            final _idPreview = toAdd.id.length > 8
                ? toAdd.id.substring(0, 8)
                : toAdd.id;
            foundation.debugPrint(
              'DEBUG: Added missing conversation from folder fetch: $_idPreview -> folder ${folder.id}',
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
            final _idPreview = convId.length > 8
                ? convId.substring(0, 8)
                : convId;
            foundation.debugPrint(
              'DEBUG: Added placeholder conversation for missing ID: $_idPreview -> folder ${folder.id}',
            );
          }
        }
      }

      // Convert map back to list - this ensures no duplicates by ID
      final sortedConversations = conversationMap.values.toList();

      // Sort conversations by updatedAt in descending order (most recent first)
      sortedConversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      foundation.debugPrint(
        'DEBUG: Sorted conversations by updatedAt (most recent first)',
      );

      // Update cache timestamp
      ref.read(_conversationsCacheTimestamp.notifier).state = DateTime.now();

      return sortedConversations;
    } catch (e) {
      foundation.debugPrint('DEBUG: Failed to fetch folder information: $e');
      // Sort conversations even when folder fetch fails
      conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      foundation.debugPrint(
        'DEBUG: Sorted conversations by updatedAt (fallback case)',
      );

      // Update cache timestamp
      ref.read(_conversationsCacheTimestamp.notifier).state = DateTime.now();

      return conversations; // Return original conversations if folder fetch fails
    }
  } catch (e, stackTrace) {
    foundation.debugPrint('DEBUG: Error fetching conversations: $e');
    foundation.debugPrint('DEBUG: Stack trace: $stackTrace');

    // If conversations endpoint returns 403, this should now clear auth token
    // and redirect user to login since it's marked as a core endpoint
    if (e.toString().contains('403')) {
      foundation.debugPrint(
        'DEBUG: Conversations endpoint returned 403 - authentication may be invalid',
      );
    }

    // Return empty list instead of re-throwing to allow app to continue functioning
    return [];
  }
});

final activeConversationProvider = StateProvider<Conversation?>((ref) => null);

// Provider to load full conversation with messages
final loadConversationProvider = FutureProvider.family<Conversation, String>((
  ref,
  conversationId,
) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    throw Exception('No API service available');
  }

  foundation.debugPrint('DEBUG: Loading full conversation: $conversationId');
  final fullConversation = await api.getConversation(conversationId);
  foundation.debugPrint(
    'DEBUG: Loaded conversation with ${fullConversation.messages.length} messages',
  );

  return fullConversation;
});

// Provider to automatically load and set the default model from user settings or OpenWebUI
final defaultModelProvider = FutureProvider<Model?>((ref) async {
  // Initialize the settings watcher (side-effect only)
  ref.read(_settingsWatcherProvider);
  // Read settings without subscribing to rebuilds to avoid watch/await hazards
  final reviewerMode = ref.read(reviewerModeProvider);
  if (reviewerMode) {
    // Check if a model is manually selected
    final currentSelected = ref.read(selectedModelProvider);
    final isManualSelection = ref.read(isManualModelSelectionProvider);

    if (currentSelected != null && isManualSelection) {
      foundation.debugPrint(
        'DEBUG: Manual model selected in reviewer mode: ${currentSelected.name}',
      );
      return currentSelected;
    }

    // Get demo models and select the first one
    final models = await ref.read(modelsProvider.future);
    if (models.isNotEmpty) {
      final defaultModel = models.first;
      if (!ref.read(isManualModelSelectionProvider)) {
        ref.read(selectedModelProvider.notifier).state = defaultModel;
        foundation.debugPrint(
          'DEBUG: Auto-selected demo model: ${defaultModel.name}',
        );
      }
      return defaultModel;
    }
    return null;
  }

  final api = ref.read(apiServiceProvider);
  if (api == null) return null;

  try {
    // Get all available models first
    final models = await ref.read(modelsProvider.future);
    if (models.isEmpty) {
      foundation.debugPrint('DEBUG: No models available');
      return null;
    }

    Model? selectedModel;

    // First check user's preferred default model
    final userSettings = ref.read(appSettingsProvider);
    final userDefaultModelId = userSettings.defaultModel;

    if (userDefaultModelId != null && userDefaultModelId.isNotEmpty) {
      try {
        selectedModel = models.firstWhere(
          (model) =>
              model.id == userDefaultModelId ||
              model.name == userDefaultModelId ||
              model.id.contains(userDefaultModelId) ||
              model.name.contains(userDefaultModelId),
        );
        foundation.debugPrint(
          'DEBUG: Found user default model: ${selectedModel.name}',
        );
      } catch (e) {
        foundation.debugPrint(
          'DEBUG: User default model "$userDefaultModelId" not found in available models',
        );
        selectedModel = null; // Will fall back to server default or first model
      }
    }

    // If no user default or user default not found, try server's default model
    if (selectedModel == null) {
      try {
        final defaultModelId = await api.getDefaultModel();

        if (defaultModelId != null && defaultModelId.isNotEmpty) {
          // Find the model that matches the default model ID
          try {
            selectedModel = models.firstWhere(
              (model) =>
                  model.id == defaultModelId ||
                  model.name == defaultModelId ||
                  model.id.contains(defaultModelId) ||
                  model.name.contains(defaultModelId),
            );
            foundation.debugPrint(
              'DEBUG: Found server default model: ${selectedModel.name}',
            );
          } catch (e) {
            foundation.debugPrint(
              'DEBUG: Server default model "$defaultModelId" not found in available models',
            );
            selectedModel = models.first;
          }
        } else {
          // No server default, use first available model
          selectedModel = models.first;
          foundation.debugPrint(
            'DEBUG: No server default model, using first available: ${selectedModel.name}',
          );
        }
      } catch (apiError) {
        foundation.debugPrint(
          'DEBUG: Failed to get default model from server: $apiError',
        );
        // Use first available model as fallback
        selectedModel = models.first;
        foundation.debugPrint(
          'DEBUG: Using first available model as fallback: ${selectedModel.name}',
        );
      }
    }

    // Update selection immediately inside provider context
    if (!ref.read(isManualModelSelectionProvider)) {
      ref.read(selectedModelProvider.notifier).state = selectedModel;
      foundation.debugPrint('DEBUG: Set default model: ${selectedModel.name}');
    }

    return selectedModel;
  } catch (e) {
    foundation.debugPrint('DEBUG: Error setting default model: $e');

    // Final fallback: try to select any available model
    try {
      final models = await ref.read(modelsProvider.future);
      if (models.isNotEmpty) {
        final fallbackModel = models.first;
        if (!ref.read(isManualModelSelectionProvider)) {
          ref.read(selectedModelProvider.notifier).state = fallbackModel;
          foundation.debugPrint(
            'DEBUG: Fallback to first available model: ${fallbackModel.name}',
          );
        }
        return fallbackModel;
      }
    } catch (fallbackError) {
      foundation.debugPrint(
        'DEBUG: Error in fallback model selection: $fallbackError',
      );
    }

    return null;
  }
});

// Background model loading provider that doesn't block UI
// This just schedules the loading, doesn't wait for it
final backgroundModelLoadProvider = Provider<void>((ref) {
  // Ensure API token updater is initialized
  ref.watch(apiTokenUpdaterProvider);

  // Schedule background loading without blocking
  Future.microtask(() async {
    // Wait a bit to ensure auth is complete
    await Future.delayed(const Duration(milliseconds: 1500));

    foundation.debugPrint('DEBUG: Starting background model loading');

    // Load default model in background
    try {
      await ref.read(defaultModelProvider.future);
      foundation.debugPrint('DEBUG: Background model loading completed');
    } catch (e) {
      // Ignore errors in background loading
      foundation.debugPrint('DEBUG: Background model loading failed: $e');
    }
  });

  // Return immediately, don't block the UI
  return;
});

// Search query provider
final searchQueryProvider = StateProvider<String>((ref) => '');

// Server-side search provider for chats
final serverSearchProvider = FutureProvider.family<List<Conversation>, String>((
  ref,
  query,
) async {
  if (query.trim().isEmpty) {
    // Return empty list for empty query instead of all conversations
    return [];
  }

  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    foundation.debugPrint('DEBUG: Performing server-side search for: "$query"');

    // Use the new server-side search API
    final chatHits = await api.searchChats(
      query: query.trim(),
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
        query: query.trim(),
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
        foundation.debugPrint(
          'DEBUG: Fetching ${fetchList.length} conversations from message hits',
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
      foundation.debugPrint('DEBUG: Message-level search failed: $e');
    }

    foundation.debugPrint(
      'DEBUG: Server search returned ${conversations.length} results',
    );
    return conversations;
  } catch (e) {
    foundation.debugPrint('DEBUG: Server search failed, fallback to local: $e');

    // Fallback to local search if server search fails
    final allConversations = await ref.read(conversationsProvider.future);
    return allConversations.where((conv) {
      return !conv.archived &&
          (conv.title.toLowerCase().contains(query.toLowerCase()) ||
              conv.messages.any(
                (msg) =>
                    msg.content.toLowerCase().contains(query.toLowerCase()),
              ));
    }).toList();
  }
});

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
final reviewerModeProvider = StateNotifierProvider<ReviewerModeNotifier, bool>(
  (ref) => ReviewerModeNotifier(ref.watch(optimizedStorageServiceProvider)),
);

class ReviewerModeNotifier extends StateNotifier<bool> {
  final OptimizedStorageService _storage;
  ReviewerModeNotifier(this._storage) : super(false) {
    _load();
  }
  Future<void> _load() async {
    final enabled = await _storage.getReviewerMode();
    state = enabled;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await _storage.setReviewerMode(enabled);
  }

  Future<void> toggle() => setEnabled(!state);
}

// User Settings providers
final userSettingsProvider = FutureProvider<UserSettings>((ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    // Return default settings if no API
    return const UserSettings();
  }

  try {
    final settingsData = await api.getUserSettings();
    return UserSettings.fromJson(settingsData);
  } catch (e) {
    foundation.debugPrint('DEBUG: Error fetching user settings: $e');
    // Return default settings on error
    return const UserSettings();
  }
});

// Conversation Suggestions provider
final conversationSuggestionsProvider = FutureProvider<List<String>>((
  ref,
) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    return await api.getSuggestions();
  } catch (e) {
    foundation.debugPrint('DEBUG: Error fetching suggestions: $e');
    return [];
  }
});

// Server features and permissions
final userPermissionsProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return {};

  try {
    return await api.getUserPermissions();
  } catch (e) {
    foundation.debugPrint('DEBUG: Error fetching user permissions: $e');
    return {};
  }
});

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
final foldersProvider = FutureProvider<List<Folder>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    foundation.debugPrint('DEBUG: No API service available for folders');
    return [];
  }

  try {
    foundation.debugPrint('DEBUG: Fetching folders from API...');
    final foldersData = await api.getFolders();
    foundation.debugPrint('DEBUG: Raw folders data received successfully');
    final folders = foldersData
        .map((folderData) => Folder.fromJson(folderData))
        .toList();
    foundation.debugPrint('DEBUG: Parsed ${folders.length} folders');
    return folders;
  } catch (e) {
    foundation.debugPrint('DEBUG: Error fetching folders: $e');
    return [];
  }
});

// Files provider
final userFilesProvider = FutureProvider<List<FileInfo>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    final filesData = await api.getUserFiles();
    return filesData.map((fileData) => FileInfo.fromJson(fileData)).toList();
  } catch (e) {
    foundation.debugPrint('DEBUG: Error fetching files: $e');
    return [];
  }
});

// File content provider
final fileContentProvider = FutureProvider.family<String, String>((
  ref,
  fileId,
) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) throw Exception('No API service available');

  try {
    return await api.getFileContent(fileId);
  } catch (e) {
    foundation.debugPrint('DEBUG: Error fetching file content: $e');
    throw Exception('Failed to load file content: $e');
  }
});

// Knowledge Base providers
final knowledgeBasesProvider = FutureProvider<List<KnowledgeBase>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    final kbData = await api.getKnowledgeBases();
    return kbData.map((data) => KnowledgeBase.fromJson(data)).toList();
  } catch (e) {
    foundation.debugPrint('DEBUG: Error fetching knowledge bases: $e');
    return [];
  }
});

final knowledgeBaseItemsProvider =
    FutureProvider.family<List<KnowledgeBaseItem>, String>((ref, kbId) async {
      final api = ref.watch(apiServiceProvider);
      if (api == null) return [];

      try {
        final itemsData = await api.getKnowledgeBaseItems(kbId);
        return itemsData
            .map((data) => KnowledgeBaseItem.fromJson(data))
            .toList();
      } catch (e) {
        foundation.debugPrint('DEBUG: Error fetching knowledge base items: $e');
        return [];
      }
    });

// Audio providers
final availableVoicesProvider = FutureProvider<List<String>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    return await api.getAvailableVoices();
  } catch (e) {
    foundation.debugPrint('DEBUG: Error fetching voices: $e');
    return [];
  }
});

// Image Generation providers
final imageModelsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    return await api.getImageModels();
  } catch (e) {
    foundation.debugPrint('DEBUG: Error fetching image models: $e');
    return [];
  }
});
