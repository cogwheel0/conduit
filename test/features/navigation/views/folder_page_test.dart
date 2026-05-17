import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/tool.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/navigation/views/folder_page.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/services/tasks/outbound_task.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit/shared/services/tasks/task_queue.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('shows the chat-style top bar, folder header, and composer', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    await tester.pumpWidget(
      _buildHarness(
        folders: const [
          Folder(id: 'work', name: 'Work', meta: {'icon': 'briefcase'}),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Work'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('folder-page-drawer-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('folder-page-model-selector')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('folder-page-new-chat-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('folder-page-temp-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('folder-page-overflow-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('folder-page-header')),
      findsOneWidget,
    );
    expect(find.byType(ModernChatInput), findsOneWidget);
    expect(
      tester.widget<ModernChatInput>(find.byType(ModernChatInput)).placeholder,
      'Message Work',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });

  testWidgets('edit folder menu action loads and saves folder updates', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    final api = _FakeFolderApiService();

    await tester.pumpWidget(
      _buildHarness(
        api: api,
        folders: const [Folder(id: 'work', name: 'Work')],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('folder-page-overflow-button')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit Folder'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('folder-edit-name-field')),
      findsOneWidget,
    );
    expect(find.text('Server Work'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('folder-edit-name-field')),
      'Renamed Work',
    );
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(api.lastUpdatedName, 'Renamed Work');
    expect(api.lastUpdatedMeta?['icon'], 'briefcase');
    expect(api.lastUpdatedData, isNull);
    expect(find.text('Renamed Work'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });

  testWidgets('system prompt menu action loads and saves prompt updates', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    final api = _FakeFolderApiService();

    await tester.pumpWidget(
      _buildHarness(
        api: api,
        folders: const [Folder(id: 'work', name: 'Work')],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('folder-page-overflow-button')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('System Prompt'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('folder-system-prompt-field')),
      findsOneWidget,
    );
    expect(find.text('Be helpful'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('folder-system-prompt-field')),
      'Be concise',
    );
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(api.lastUpdatedName, isNull);
    expect(api.lastUpdatedMeta, isNull);
    expect(api.lastUpdatedData?['system_prompt'], 'Be concise');

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });

  testWidgets('new chat button clears folder context for a global chat', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    final container = _createContainer(
      folders: const [Folder(id: 'work', name: 'Work')],
      settings: const AppSettings(temporaryChatByDefault: true),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildHarnessFromContainer(container));
    await tester.pumpAndSettle();

    expect(container.read(pendingFolderIdProvider), 'work');

    await tester.tap(
      find.byKey(const ValueKey<String>('folder-page-new-chat-button')),
    );
    await tester.pumpAndSettle();

    expect(container.read(pendingFolderIdProvider), isNull);
    expect(container.read(temporaryChatEnabledProvider), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });

  testWidgets('opening a folder page primes a fresh folder draft', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    const currentModel = Model(id: 'custom-model', name: 'Custom Model');
    const defaultModel = Model(id: 'default-model', name: 'Default Model');
    final existingConversation = Conversation(
      id: 'conversation-1',
      title: 'Existing',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
      model: currentModel.id,
    );
    final seededMessages = <ChatMessage>[
      ChatMessage(
        id: 'message-1',
        role: 'user',
        content: 'hello',
        timestamp: DateTime(2024),
      ),
    ];
    final container = _createContainer(
      folders: const [Folder(id: 'work', name: 'Work')],
      settings: const AppSettings(temporaryChatByDefault: true),
      reviewerMode: true,
      selectedModel: currentModel,
      availableModels: const [defaultModel, currentModel],
      activeConversation: existingConversation,
      initialMessages: seededMessages,
    );
    addTearDown(container.dispose);
    container.read(temporaryChatEnabledProvider.notifier).set(false);
    container
        .read(contextAttachmentsProvider.notifier)
        .addWeb(
          displayName: 'Example',
          content: 'content',
          url: 'https://example.com',
        );

    await tester.pumpWidget(_buildHarnessFromContainer(container));
    await tester.pumpAndSettle();

    expect(container.read(pendingFolderIdProvider), 'work');
    expect(container.read(activeConversationProvider), isNull);
    expect(container.read(chatMessagesProvider), isEmpty);
    expect(container.read(contextAttachmentsProvider), isEmpty);
    expect(container.read(temporaryChatEnabledProvider), isTrue);
    expect(container.read(selectedModelProvider)?.id, defaultModel.id);

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });

  testWidgets('composer sends keep the folder target in the queued task', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    final recordingTaskQueue = _RecordingTaskQueueNotifier();
    final container = _createContainer(
      folders: const [Folder(id: 'work', name: 'Work')],
      taskQueueNotifier: recordingTaskQueue,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildHarnessFromContainer(container));
    await tester.pumpAndSettle();

    final composer = tester.widget<ModernChatInput>(
      find.byType(ModernChatInput),
    );
    await tester.runAsync(() async {
      final result = composer.onSendMessage('Folder draft');
      if (result is Future) {
        await result;
      }
    });
    await tester.pumpAndSettle();

    expect(recordingTaskQueue.lastConversationId, isNull);
    expect(recordingTaskQueue.lastPendingFolderId, 'work');
    expect(recordingTaskQueue.lastText, 'Folder draft');

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });

  testWidgets('folder conversation rows reuse the shared chat context menu', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    final timestamp = DateTime(2026, 1, 1);
    final conversation = Conversation(
      id: 'folder-chat-1',
      title: 'Folder Chat',
      createdAt: timestamp,
      updatedAt: timestamp,
      folderId: 'work',
    );
    final container = _createContainer(
      api: _FakeFolderApiService(conversationSummaries: [conversation]),
      folders: const [Folder(id: 'work', name: 'Work')],
      conversations: [conversation],
      isAuthenticated: true,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildHarnessFromContainer(container));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('folder-chat-folder-chat-1')),
      findsOneWidget,
    );

    final menu = tester
        .widgetList<ConduitContextMenu>(find.byType(ConduitContextMenu))
        .singleWhere((menu) {
          final labels = menu.actions.map((action) => action.label);
          return labels.contains('Pin') && labels.contains('Rename');
        });
    expect(menu.actions.map((action) => action.label), contains('Pin'));
    expect(menu.actions.map((action) => action.label), contains('Rename'));

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });
}

Widget _buildHarness({
  ApiService? api,
  List<Conversation> conversations = const <Conversation>[],
  List<Folder> folders = const <Folder>[],
  AppSettings settings = const AppSettings(),
}) {
  final container = _createContainer(
    api: api,
    conversations: conversations,
    folders: folders,
    settings: settings,
  );
  addTearDown(container.dispose);
  return _buildHarnessFromContainer(container);
}

ProviderContainer _createContainer({
  ApiService? api,
  List<Conversation> conversations = const <Conversation>[],
  List<Folder> folders = const <Folder>[],
  AppSettings settings = const AppSettings(),
  bool isAuthenticated = false,
  bool reviewerMode = false,
  Model? selectedModel,
  List<Model>? availableModels,
  Conversation? activeConversation,
  List<ChatMessage> initialMessages = const <ChatMessage>[],
  TaskQueueNotifier? taskQueueNotifier,
}) {
  final resolvedSelectedModel =
      selectedModel ?? const Model(id: 'model-1', name: 'Model 1');
  final resolvedModels = availableModels ?? <Model>[resolvedSelectedModel];
  return ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWithValue(settings),
      apiServiceProvider.overrideWithValue(api),
      isAuthenticatedProvider2.overrideWithValue(isAuthenticated),
      if (isAuthenticated) authTokenProvider3.overrideWithValue('test-token'),
      reviewerModeProvider.overrideWithValue(reviewerMode),
      if (taskQueueNotifier != null)
        taskQueueProvider.overrideWith(() => taskQueueNotifier),
      selectedModelProvider.overrideWith(
        () => _SeededSelectedModelNotifier(resolvedSelectedModel),
      ),
      activeConversationProvider.overrideWith(
        () => _SeededActiveConversationNotifier(activeConversation),
      ),
      chatMessagesProvider.overrideWith(
        () => _SeededChatMessagesNotifier(initialMessages),
      ),
      optimizedStorageServiceProvider.overrideWithValue(
        _FakeOptimizedStorageService(),
      ),
      isChatStreamingProvider.overrideWith((ref) => false),
      conversationsProvider.overrideWith(
        () => _TestConversations(conversations),
      ),
      modelsProvider.overrideWith(() => _TestModels(resolvedModels)),
      foldersProvider.overrideWith(() => _TestFolders(folders)),
      toolsListProvider.overrideWith(_TestToolsList.new),
    ],
  );
}

Widget _buildHarnessFromContainer(ProviderContainer container) {
  final router = GoRouter(
    initialLocation: '/folder/work',
    routes: [
      GoRoute(
        path: '/folder/:id',
        name: RouteNames.folder,
        builder: (context, state) {
          final folderId = state.pathParameters['id']!;
          return FolderPage(folderId: folderId);
        },
      ),
      GoRoute(
        path: '/chat',
        name: RouteNames.chat,
        builder: (context, state) => const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
  NavigationService.attachRouter(router);

  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

class _TestConversations extends Conversations {
  _TestConversations(this.conversations);

  final List<Conversation> conversations;

  @override
  Future<List<Conversation>> build() async => conversations;
}

class _TestModels extends Models {
  _TestModels([this.models = const [Model(id: 'model-1', name: 'Model 1')]]);

  final List<Model> models;

  @override
  Future<List<Model>> build() async => models;
}

class _SeededSelectedModelNotifier extends SelectedModel {
  _SeededSelectedModelNotifier(this.initialModel);

  final Model? initialModel;

  @override
  Model? build() => initialModel;
}

class _TestFolders extends Folders {
  _TestFolders(this.folders);

  final List<Folder> folders;

  @override
  Future<List<Folder>> build() async => folders;
}

class _TestToolsList extends ToolsList {
  @override
  Future<List<Tool>> build() async => const <Tool>[];
}

class _SeededActiveConversationNotifier extends ActiveConversationNotifier {
  _SeededActiveConversationNotifier(this.initialConversation);

  final Conversation? initialConversation;

  @override
  Conversation? build() => initialConversation;
}

class _SeededChatMessagesNotifier extends ChatMessagesNotifier {
  _SeededChatMessagesNotifier(this.initialMessages);

  final List<ChatMessage> initialMessages;

  @override
  List<ChatMessage> build() => List<ChatMessage>.from(initialMessages);
}

class _RecordingTaskQueueNotifier extends TaskQueueNotifier {
  String? lastConversationId;
  String? lastPendingFolderId;
  String? lastText;

  @override
  List<OutboundTask> build() => const <OutboundTask>[];

  @override
  Future<String> enqueueSendText({
    required String? conversationId,
    String? pendingFolderId,
    required String text,
    List<String>? attachments,
    List<String>? toolIds,
    String? idempotencyKey,
  }) async {
    lastConversationId = conversationId;
    lastPendingFolderId = pendingFolderId;
    lastText = text;
    return 'recorded-send-task';
  }
}

class _FakeOptimizedStorageService extends Fake
    implements OptimizedStorageService {
  @override
  Future<void> saveLocalFolders(List<Folder> folders) async {}

  @override
  Future<void> saveLocalConversations(List<Conversation> conversations) async {}

  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _FakeFolderApiService extends Fake implements ApiService {
  _FakeFolderApiService({this.conversationSummaries = const <Conversation>[]});

  final List<Conversation> conversationSummaries;
  String? lastUpdatedName;
  Map<String, dynamic>? lastUpdatedMeta;
  Map<String, dynamic>? lastUpdatedData;

  Map<String, dynamic> _folder = <String, dynamic>{
    'id': 'work',
    'name': 'Server Work',
    'meta': <String, dynamic>{'icon': 'briefcase'},
    'data': <String, dynamic>{'system_prompt': 'Be helpful'},
    'items': <String, dynamic>{'chats': <String>[]},
  };

  @override
  Future<Map<String, dynamic>?> getFolderById(String id) async {
    if (id != 'work') {
      return null;
    }
    return Map<String, dynamic>.from(_folder);
  }

  @override
  Future<Map<String, dynamic>> getUserSettings() async => <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> getUserPermissions() async =>
      <String, dynamic>{};

  @override
  Future<List<Conversation>> getFolderConversationSummaries(
    String folderId,
  ) async {
    return conversationSummaries
        .where((conversation) => conversation.folderId == folderId)
        .toList(growable: false);
  }

  @override
  Future<Map<String, dynamic>?> updateFolder(
    String id, {
    String? name,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    String? parentId,
  }) async {
    lastUpdatedName = name;
    lastUpdatedMeta = meta == null ? null : Map<String, dynamic>.from(meta);
    lastUpdatedData = data == null ? null : Map<String, dynamic>.from(data);

    final updatedFolder = Map<String, dynamic>.from(_folder);
    if (name != null) {
      updatedFolder['name'] = name;
    }
    if (meta != null) {
      updatedFolder['meta'] = Map<String, dynamic>.from(meta);
    }
    if (data != null) {
      updatedFolder['data'] = Map<String, dynamic>.from(data);
    }
    if (parentId != null) {
      updatedFolder['parent_id'] = parentId;
    }
    _folder = updatedFolder;

    return Map<String, dynamic>.from(_folder);
  }
}
