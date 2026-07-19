import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/toggle_filter.dart';
import 'package:conduit/core/models/tool.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit/features/chat/services/file_attachment_service.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/navigation/views/folder_page.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  test('pasted attachments acknowledge before terminal uploads', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_folder_paste_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final first = File('${directory.path}/first.png');
    final second = File('${directory.path}/second.png');
    await first.writeAsBytes([1]);
    await second.writeAsBytes([2, 3]);
    final uploads = <String>[];
    final firstTerminal = Completer<void>();
    final secondTerminal = Completer<void>();
    addTearDown(() {
      if (!firstTerminal.isCompleted) firstTerminal.complete();
      if (!secondTerminal.isCompleted) secondTerminal.complete();
    });
    List<LocalAttachment>? added;
    final attachments = [
      LocalAttachment(file: first, displayName: 'first.png'),
      LocalAttachment(file: second, displayName: 'second.png'),
    ];

    await acceptFolderPastedAttachments(
      attachments: attachments,
      addFiles: (value) => added = value,
      upload: (attachment, fileSize) {
        uploads.add('${attachment.displayName}:$fileSize');
        return attachment.file.path == first.path
            ? firstTerminal.future
            : secondTerminal.future;
      },
      rollback: (_) async {
        throw StateError('successful preparation must not roll back');
      },
    ).timeout(const Duration(seconds: 1));

    check(added).identicalTo(attachments);
    check(uploads).deepEquals(['first.png:1', 'second.png:2']);
    check(firstTerminal.isCompleted).isFalse();
    check(secondTerminal.isCompleted).isFalse();
  });

  test('pasted size failure rolls back ownership and staged files', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_folder_paste_rollback_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final staged = File('${directory.path}/staged.png');
    await staged.writeAsBytes([1]);
    final missing = File('${directory.path}/missing.png');
    final attachments = <LocalAttachment>[
      LocalAttachment(file: staged, displayName: 'staged.png'),
      LocalAttachment(file: missing, displayName: 'missing.png'),
    ];
    final visible = <LocalAttachment>[];
    final rolledBack = <String>[];
    var uploadCalls = 0;

    await check(
      acceptFolderPastedAttachments(
        attachments: attachments,
        addFiles: visible.addAll,
        upload: (_, _) async => uploadCalls++,
        rollback: (attachment) async {
          visible.removeWhere(
            (current) => current.file.path == attachment.file.path,
          );
          rolledBack.add(attachment.displayName);
          if (await attachment.file.exists()) {
            await attachment.file.delete();
          }
        },
      ),
    ).throws<FileSystemException>();

    check(visible).isEmpty();
    check(rolledBack).deepEquals(['staged.png', 'missing.png']);
    check(uploadCalls).equals(0);
    check(await staged.exists()).isFalse();
  });

  test('oversized pasted image rolls back before upload preparation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_folder_paste_oversized_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final oversized = File('${directory.path}/oversized.png');
    final handle = await oversized.open(mode: FileMode.write);
    try {
      await handle.truncate(20 * 1024 * 1024 + 1);
    } finally {
      await handle.close();
    }
    final attachment = LocalAttachment(
      file: oversized,
      displayName: 'oversized.png',
    );
    final visible = <LocalAttachment>[];
    var uploadCalls = 0;

    await expectLater(
      acceptFolderPastedAttachments(
        attachments: <LocalAttachment>[attachment],
        addFiles: visible.addAll,
        upload: (_, _) async => uploadCalls++,
        rollback: (value) async {
          visible.removeWhere(
            (current) => current.file.path == value.file.path,
          );
          if (await value.file.exists()) await value.file.delete();
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    check(visible).isEmpty();
    check(uploadCalls).equals(0);
    check(await oversized.exists()).isFalse();
  });

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

  testWidgets('composer sends durably persist a folder-targeted local chat', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    // Real in-memory DB so the durable write path (rows + outbox ops) lands.
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final container = _createContainer(
      folders: const [Folder(id: 'work', name: 'Work')],
      isAuthenticated: true,
      database: db,
      selectedModel: const Model(
        id: 'model-1',
        name: 'Model 1',
        filters: [ToggleFilter(id: 'filter-a', name: 'Filter A')],
      ),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildHarnessFromContainer(container));
    await tester.pumpAndSettle();
    container.read(selectedFilterIdsProvider.notifier).set(const ['filter-a']);

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

    await tester.runAsync(() async {
      // A new `local:` chat with folderId == 'work' carrying the user text.
      final chats = await db.chatsDao.watchChatList().first;
      final localChats = chats.where((c) => c.id.startsWith('local:')).toList();
      expect(localChats, hasLength(1));
      final chatId = localChats.single.id;
      expect(localChats.single.folderId, 'work');

      final messages = await db.messagesDao.getForChat(chatId);
      final userRow = messages.firstWhere((m) => m.role == 'user');
      expect(userRow.content, 'Folder draft');

      // The outbox carries a createChat + requestCompletion op pair for it.
      final ops = await db.outboxDao.pendingForChat(chatId);
      final kinds = ops.map((o) => o.kind).toList();
      expect(kinds, contains(OutboxKind.createChat.name));
      expect(kinds, contains(OutboxKind.requestCompletion.name));
      // createChat is sequenced BEFORE requestCompletion (§B2.4).
      final createSeq = ops
          .firstWhere((o) => o.kind == OutboxKind.createChat.name)
          .seq;
      final completionSeq = ops
          .firstWhere((o) => o.kind == OutboxKind.requestCompletion.name)
          .seq;
      expect(createSeq, lessThan(completionSeq));
      final completion = ops.firstWhere(
        (o) => o.kind == OutboxKind.requestCompletion.name,
      );
      final payload = RequestCompletionPayload.fromJson(
        jsonDecode(completion.payload) as Map<String, dynamic>,
      );
      expect(payload.filterIds, const ['filter-a']);
    });

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
    // Folder summaries render from the local database now (CDT-RFC-001
    // Phase 1): seed the chats row instead of stubbing a server endpoint.
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.chatsDao.upsertEnvelopeStub(
      id: 'folder-chat-1',
      title: 'Folder Chat',
      createdAt: timestamp.millisecondsSinceEpoch ~/ 1000,
      updatedAt: timestamp.millisecondsSinceEpoch ~/ 1000,
      folderId: const Value('work'),
    );
    final container = _createContainer(
      api: _FakeFolderApiService(),
      folders: const [Folder(id: 'work', name: 'Work')],
      conversations: [conversation],
      isAuthenticated: true,
      database: db,
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

  testWidgets(
    'folder conversation open falls back to cached row on API error',
    (tester) async {
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
      final api = _FakeFolderApiService(
        getConversationError: StateError('offline'),
      );
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.chatsDao.upsertEnvelopeStub(
        id: 'folder-chat-1',
        title: 'Folder Chat',
        createdAt: timestamp.millisecondsSinceEpoch ~/ 1000,
        updatedAt: timestamp.millisecondsSinceEpoch ~/ 1000,
        folderId: const Value('work'),
      );
      final container = _createContainer(
        api: api,
        folders: const [Folder(id: 'work', name: 'Work')],
        conversations: [conversation],
        isAuthenticated: true,
        database: db,
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildHarnessFromContainer(container));
      await tester.pumpAndSettle();

      container.read(selectedFilterIdsProvider.notifier).set(const [
        'filter-a',
      ]);
      await tester.tap(
        find.byKey(const ValueKey<String>('folder-chat-folder-chat-1')),
      );
      await tester.pumpAndSettle();

      expect(api.requestedConversationIds, ['folder-chat-1']);
      expect(container.read(activeConversationProvider)?.id, 'folder-chat-1');
      expect(container.read(activeConversationProvider)?.title, 'Folder Chat');
      expect(container.read(selectedFilterIdsProvider), isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    },
  );
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
  AppDatabase? database,
}) {
  final resolvedSelectedModel =
      selectedModel ?? const Model(id: 'model-1', name: 'Model 1');
  final resolvedModels = availableModels ?? <Model>[resolvedSelectedModel];
  return ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWithValue(settings),
      apiServiceProvider.overrideWithValue(api),
      appDatabaseProvider.overrideWith((ref) => database),
      isAuthenticatedProvider2.overrideWithValue(isAuthenticated),
      if (isAuthenticated) authTokenProvider3.overrideWithValue('test-token'),
      reviewerModeProvider.overrideWithValue(reviewerMode),
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

class _FakeOptimizedStorageService extends Fake
    implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _FakeFolderApiService extends Fake implements ApiService {
  _FakeFolderApiService({this.getConversationError});

  String? lastUpdatedName;
  Map<String, dynamic>? lastUpdatedMeta;
  Map<String, dynamic>? lastUpdatedData;
  final Object? getConversationError;
  final List<String> requestedConversationIds = <String>[];

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
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async =>
      <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> getUserPermissions() async =>
      <String, dynamic>{};

  @override
  Future<Conversation> getConversation(String id) async {
    requestedConversationIds.add(id);
    final error = getConversationError;
    if (error != null) {
      throw error;
    }
    return Conversation(
      id: id,
      title: id,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
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
