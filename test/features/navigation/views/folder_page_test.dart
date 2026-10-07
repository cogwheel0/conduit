import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart'
    show WorkspacePagedResponse;
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:dio/dio.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart' show isOnlineProvider;
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit/features/chat/services/file_attachment_service.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/chat/widgets/model_selector_sheet.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/navigation/views/folder_page.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/navigation/widgets/folder_project_settings_sheet.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter/services.dart' show MethodChannel;
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
    final appBar = tester.widget<AppBar>(find.byType(AppBar).first);
    expect(appBar.centerTitle, isFalse);
    expect(
      find.descendant(
        of: find.byWidget(appBar.title!),
        matching: find.byKey(
          const ValueKey<String>('folder-page-model-selector'),
        ),
      ),
      findsOneWidget,
    );
    final selector = find.byKey(
      const ValueKey<String>('folder-page-model-selector'),
    );
    expect(
      tester.getCenter(selector).dx,
      lessThan(tester.getSize(find.byType(Scaffold).first).width / 2),
    );
    expect(
      find.descendant(
        of: find.byWidget(appBar.leading!),
        matching: find.byKey(
          const ValueKey<String>('folder-page-drawer-button'),
        ),
      ),
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

  group('folder Share settings', () {
    Future<void> openFolderMenu(
      WidgetTester tester, {
      required Folder folder,
    }) async {
      final container = _createContainer(
        folders: [folder],
        extraOverrides: [
          workspaceCapabilitiesProvider.overrideWith(
            (ref) async => WorkspaceCapabilities.all,
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_buildHarnessFromContainer(container));
      await tester.pumpAndSettle();
      final overflow = find.byKey(
        const ValueKey<String>('folder-page-overflow-button'),
      );
      if (overflow.evaluate().isNotEmpty) {
        await tester.tap(overflow);
        await tester.pumpAndSettle();
      }
    }

    testWidgets('is in the owner menu with Advanced off, beside Edit Folder', (
      tester,
    ) async {
      await openFolderMenu(
        tester,
        folder: const Folder(id: 'work', name: 'Work'),
      );

      expect(find.text('Share settings'), findsOneWidget);
      expect(find.text('Edit Folder'), findsOneWidget);
    });

    testWidgets('a write recipient gets Share settings and no owner actions', (
      tester,
    ) async {
      await openFolderMenu(
        tester,
        folder: const Folder(
          id: 'work',
          name: 'Work',
          shared: true,
          permission: 'write',
        ),
      );

      expect(find.text('Share settings'), findsOneWidget);
      expect(find.text('Edit Folder'), findsNothing);
      expect(find.text('System Prompt'), findsNothing);
    });

    testWidgets('a read recipient has no menu at all', (tester) async {
      await openFolderMenu(
        tester,
        folder: const Folder(
          id: 'work',
          name: 'Work',
          shared: true,
          permission: 'read',
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('folder-page-overflow-button')),
        findsNothing,
      );
      expect(find.text('Share settings'), findsNothing);
    });
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
      extraOverrides: [
        // The composer's interpreter offer asks the server, which this fake
        // does not stand in for; only the context menu is under test.
        codeInterpreterOfferProvider.overrideWithValue(null),
      ],
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

  testWidgets('folder conversation open uses the shared full loader', (
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
    final conversation = withChatStorageProvenance(
      Conversation(
        id: 'folder-chat-1',
        title: 'Folder Chat',
        createdAt: timestamp,
        updatedAt: timestamp,
        folderId: 'work',
      ),
      ChatStorageKind.directLocal,
    );
    final full = withChatStorageProvenance(
      conversation.copyWith(
        messages: [
          ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: 'Loaded through the shared provider',
            timestamp: timestamp,
          ),
        ],
      ),
      ChatStorageKind.directLocal,
    );
    final scopedId = conversationScopedId(conversation);
    var loadCalls = 0;
    final container = _createContainer(
      folders: const [Folder(id: 'work', name: 'Work')],
      conversations: [conversation],
      extraOverrides: [
        folderConversationSummariesProvider('work')
            .overrideWith((ref) async => [conversation]),
        loadConversationProvider(scopedId).overrideWith((ref) async {
          loadCalls += 1;
          return full;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildHarnessFromContainer(container));
    await tester.pumpAndSettle();

    container.read(selectedFilterIdsProvider.notifier).set(const ['filter-a']);
    await tester.tap(
      find.byKey(const ValueKey<String>('folder-chat-folder-chat-1')),
    );
    await tester.pumpAndSettle();

    expect(loadCalls, 1);
    expect(container.read(activeConversationProvider)?.id, 'folder-chat-1');
    expect(
      container.read(activeConversationProvider)?.messages.single.content,
      'Loaded through the shared provider',
    );
    expect(container.read(selectedFilterIdsProvider), isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });

  testWidgets('chat page mount defers the initial transcript reset', (
    tester,
  ) async {
    final timestamp = DateTime(2026, 1, 1);
    final message = ChatMessage(
      id: 'assistant-1',
      role: 'assistant',
      content: 'Hi',
      timestamp: timestamp,
    );
    final active = Conversation(
      id: 'folder-chat-1',
      title: 'Folder Chat',
      createdAt: timestamp,
      updatedAt: timestamp,
      folderId: 'work',
      messages: [message],
    );
    final container = _createContainer(
      activeConversation: active,
      initialMessages: [message],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChatPage(),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(container.read(chatTranscriptPagingProvider).loadedCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets(
    'same-route router refresh does not cancel delayed folder navigation',
    (tester) async {
      final originalErrorWidgetBuilder = ErrorWidget.builder;
      final originalFlutterErrorOnError = FlutterError.onError;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        ErrorWidget.builder = originalErrorWidgetBuilder;
        FlutterError.onError = originalFlutterErrorOnError;
      });

      final timestamp = DateTime(2026, 1, 1);
      final conversation = withChatStorageProvenance(
        Conversation(
          id: 'same-route-refresh-chat',
          title: 'Same Route Refresh Chat',
          createdAt: timestamp,
          updatedAt: timestamp,
          folderId: 'work',
        ),
        ChatStorageKind.directLocal,
      );
      final full = withChatStorageProvenance(
        conversation.copyWith(
          messages: [
            ChatMessage(
              id: 'assistant-same-route',
              role: 'assistant',
              content: 'Loaded after a same-route router refresh',
              timestamp: timestamp,
            ),
          ],
        ),
        ChatStorageKind.directLocal,
      );
      final loadGate = Completer<Conversation>();
      final scopedId = conversationScopedId(conversation);
      final routerRefresh = ChangeNotifier();
      addTearDown(routerRefresh.dispose);
      final container = _createContainer(
        folders: const [Folder(id: 'work', name: 'Work')],
        conversations: [conversation],
        extraOverrides: [
          folderConversationSummariesProvider('work')
              .overrideWith((ref) async => [conversation]),
          loadConversationProvider(scopedId)
              .overrideWith((ref) => loadGate.future),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _buildHarnessFromContainer(
          container,
          routerRefreshListenable: routerRefresh,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const ValueKey<String>('folder-chat-same-route-refresh-chat'),
        ),
      );
      await tester.pump();
      final routeRevision = NavigationService.currentRouteRevision;

      routerRefresh.notifyListeners();
      await tester.pump();
      expect(NavigationService.currentRoute, '/folder/work');
      expect(NavigationService.currentRouteRevision, routeRevision);

      loadGate.complete(full);
      await tester.pumpAndSettle();

      expect(NavigationService.currentRoute, '/chat');
      expect(container.read(activeConversationProvider)?.id, conversation.id);

      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    },
  );

  testWidgets('delayed folder selection does not navigate after route ABA', (
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
    final conversation = withChatStorageProvenance(
      Conversation(
        id: 'delayed-folder-chat',
        title: 'Delayed Folder Chat',
        createdAt: timestamp,
        updatedAt: timestamp,
        folderId: 'work',
      ),
      ChatStorageKind.directLocal,
    );
    final full = withChatStorageProvenance(
      conversation.copyWith(
        messages: [
          ChatMessage(
            id: 'assistant-delayed',
            role: 'assistant',
            content: 'Loaded after leaving and returning',
            timestamp: timestamp,
          ),
        ],
      ),
      ChatStorageKind.directLocal,
    );
    final loadGate = Completer<Conversation>();
    final scopedId = conversationScopedId(conversation);
    var loadCalls = 0;
    final container = _createContainer(
      folders: const [
        Folder(id: 'work', name: 'Work'),
        Folder(id: 'other', name: 'Other'),
      ],
      conversations: [conversation],
      extraOverrides: [
        folderConversationSummariesProvider('work')
            .overrideWith((ref) async => [conversation]),
        folderConversationSummariesProvider('other')
            .overrideWith((ref) async => const <Conversation>[]),
        loadConversationProvider(scopedId).overrideWith((ref) {
          loadCalls += 1;
          return loadGate.future;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildHarnessFromContainer(container));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('folder-chat-delayed-folder-chat')),
    );
    await tester.pump();
    expect(loadCalls, 1);

    NavigationService.router.go('/folder/other');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(NavigationService.currentRoute, '/folder/other');

    NavigationService.router.go('/folder/work');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(NavigationService.currentRoute, '/folder/work');

    loadGate.complete(full);
    await tester.pumpAndSettle();

    expect(NavigationService.currentRoute, '/folder/work');
    expect(container.read(activeConversationProvider)?.id, conversation.id);
    expect(
      container.read(activeConversationProvider)?.messages.single.content,
      'Loaded after leaving and returning',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });

  group('project settings', () {
    const modelA = Model(id: 'm-a', name: 'Model A');
    const modelB = Model(id: 'm-b', name: 'Model B');
    const readOnlyMessage =
        "This shared folder is read-only, so its project settings can't be changed.";
    const ownerChangedMessage =
        'The signed-in account changed, so nothing was saved. Reopen project '
        'settings to continue.';

    late AppDatabase db;
    late _ProjectApi api;
    late ProviderContainer container;

    Map<String, dynamic> project({
      String? permission,
      Map<String, dynamic>? data,
    }) => {
      'id': 'work',
      'name': 'Work',
      'created_at': 1,
      'updated_at': 2,
      'meta': {'icon': 'briefcase'},
      'data':
          data ??
          {
            'system_prompt': 'Be brief',
            'files': [
              {'type': 'collection', 'id': 'kb-1', 'name': 'Docs'},
            ],
            'model_ids': ['retired', 'm-a'],
            'custom': {'k': 1},
          },
      if (permission != null) ...{
        'shared': true,
        'owner_name': 'Alex',
        'permission': permission,
      },
    };

    /// Real database work completes outside the test's fake clock.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
    }

    /// Shows the folder page for [raw], with [raw] also in the database the
    /// editor writes to.
    Future<void> open(
      WidgetTester tester,
      Map<String, dynamic> raw, {
      bool native = false,
      bool liveFolders = false,
      String role = 'admin',
      Map<String, dynamic>? detail,
      Map<String, int> fileStatus = const <String, int>{},
      List<FileInfo> files = const <FileInfo>[],
      WorkspaceKnowledge Function()? knowledge,
      List<Override> overrides = const <Override>[],
    }) async {
      final originalErrorWidgetBuilder = ErrorWidget.builder;
      final originalFlutterErrorOnError = FlutterError.onError;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        ErrorWidget.builder = originalErrorWidgetBuilder;
        FlutterError.onError = originalFlutterErrorOnError;
      });
      if (native) {
        // The presenter iOS 26 devices use: CNBottomSheet supplies Flutter's
        // own Material, not the material_ui one these controls look up.
        PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
        PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
        PlatformUiCapabilities.debugNativeIOS26Override = true;
        addTearDown(PlatformUiCapabilities.resetDebugOverrides);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
        tester.view.viewPadding = const FakeViewPadding(top: 62, bottom: 34);
      } else {
        // Tall enough that the sheet's lazy list builds every row, so a test
        // does not depend on where it happens to be scrolled.
        tester.view.physicalSize = const Size(800, 4000);
        tester.view.devicePixelRatio = 1;
      }
      addTearDown(tester.view.reset);
      db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      api = _ProjectApi(detail, fileStatus);
      addTearDown(api.dispose);
      await tester.runAsync(() => db.foldersDao.replaceServerFolders([raw]));
      container = _createContainer(
        api: api,
        isAuthenticated: true,
        database: db,
        folders: [Folder.fromJson(raw)],
        selectedModel: modelA,
        availableModels: const [modelA, modelB],
        extraOverrides: [
          currentUserProvider2.overrideWithValue(
            User(
              id: 'me',
              username: 'me',
              email: 'me@example.test',
              role: role,
            ),
          ),
          activeServerProvider.overrideWith((ref) async => api.serverConfig),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(_epochProvider),
          ),
          syncEngineProvider.overrideWith(_NoDrainEngine.new),
          workspaceKnowledgeProvider.overrideWith(
            knowledge ?? _TestKnowledge.new,
          ),
          userFilesProvider.overrideWith(() => _TestUserFiles(files)),
          ...overrides,
        ],
        liveFolders: liveFolders,
      );
      addTearDown(container.dispose);
      // The app has resolved its active server long before a menu can be
      // opened; an account is only captured against a resolved server.
      container.listen(activeServerProvider, (_, _) {});
      await tester.runAsync(() => container.read(activeServerProvider.future));
      if (native) {
        // The sheet alone runs on the native presenter. A plain page hosts it,
        // as the platform views of the folder page's own native toolbar do not
        // exist under test.
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(TweakcnThemes.t3Chat),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => Center(
                    child: TextButton(
                      onPressed: () => showFolderProjectSettings(
                        context,
                        ref,
                        Folder.fromJson(raw),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      } else {
        await tester.pumpWidget(_buildHarnessFromContainer(container));
      }
      await tester.pumpAndSettle();
      if (liveFolders) await settle(tester);
    }

    Finder overflow() =>
        find.byKey(const ValueKey<String>('folder-page-overflow-button'));
    Finder key(String id) => find.byKey(ValueKey<String>(id));

    Future<void> openSheet(WidgetTester tester, {bool native = false}) async {
      if (native) {
        await tester.tap(find.text('open'));
      } else {
        await tester.tap(overflow());
        await tester.pumpAndSettle();
        await tester.tap(find.text('Project settings'));
      }
      await settle(tester);
    }

    Future<Map<String, dynamic>> storedData(WidgetTester tester) async {
      final row = await tester.runAsync(() => db.foldersDao.getFolder('work'));
      return (jsonDecode(row!.rawExtra) as Map<String, dynamic>)['data']
          as Map<String, dynamic>;
    }

    Future<List<Map<String, dynamic>>> queued(WidgetTester tester) async {
      final ops = await tester.runAsync(
        () => db.outboxDao.pendingForChat('work'),
      );
      return [
        for (final op in ops!) jsonDecode(op.payload) as Map<String, dynamic>,
      ];
    }

    Future<void> chooseOption(
      WidgetTester tester, {
      required String opener,
      required String option,
    }) async {
      await tester.ensureVisible(key(opener));
      await tester.tap(key(opener));
      await settle(tester);
      expect(key('folder-project-option-$option'), findsOneWidget);
      await tester.tap(key('folder-project-option-$option'));
      await tester.pump();
      expect(
        tester
            .widget<CheckboxListTile>(key('folder-project-option-$option'))
            .value,
        isTrue,
      );
      await tester.tap(key('folder-project-picker-add'));
      await tester.pumpAndSettle();
    }

    // What the folder menu offers with Advanced off: the owner's own actions
    // stay owner-only, and the project editor goes to anyone who can write.
    final menuCases = <({String name, String? permission, List<String> items})>[
      (
        name: 'an owner',
        permission: null,
        items: ['Edit Folder', 'System Prompt', 'Project settings'],
      ),
      (name: 'a write grant', permission: 'write', items: ['Project settings']),
      (name: 'a read grant', permission: 'read', items: []),
    ];
    for (final menuCase in menuCases) {
      testWidgets('the folder menu for ${menuCase.name}', (tester) async {
        await open(tester, project(permission: menuCase.permission));

        if (menuCase.items.isEmpty) {
          expect(overflow(), findsNothing);
          return;
        }
        await tester.tap(overflow());
        await tester.pumpAndSettle();
        expect([
          for (final label in [
            'Edit Folder',
            'System Prompt',
            'Project settings',
          ])
            if (find.text(label).evaluate().isNotEmpty) label,
        ], menuCase.items);
      });
    }

    testWidgets(
      'a recipient with a write grant edits the default models and saves only them',
      (tester) async {
        await open(tester, project(permission: 'write'));
        await openSheet(tester);

        // A saved model the server no longer offers is shown, not dropped.
        expect(
          find.descendant(
            of: key('folder-project-model-0'),
            matching: find.text('retired'),
          ),
          findsOneWidget,
        );
        expect(key('folder-project-model-0-unavailable'), findsOneWidget);
        expect(
          find.descendant(
            of: key('folder-project-model-1'),
            matching: find.text('Model A'),
          ),
          findsOneWidget,
        );
        expect(key('folder-project-model-1-unavailable'), findsNothing);

        await chooseOption(
          tester,
          opener: 'folder-project-add-model',
          option: 'm-b',
        );
        await tester.tap(key('folder-project-model-2-up'));
        await tester.pump();
        await tester.ensureVisible(key('folder-project-save'));
        await tester.tap(key('folder-project-save'));
        await settle(tester);

        final data = await storedData(tester);
        expect(data['model_ids'], ['retired', 'm-b', 'm-a']);
        expect(data['system_prompt'], 'Be brief');
        expect(data['files'], [
          {'type': 'collection', 'id': 'kb-1', 'name': 'Docs'},
        ]);
        expect(data['custom'], {'k': 1});
        // The queued request carries the one edited key, nothing else.
        expect((await queued(tester)).single['data'], {
          'model_ids': ['retired', 'm-b', 'm-a'],
        });
        expect(api.updateCalls, 0);
        expect(key('folder-project-save'), findsNothing);
      },
    );

    testWidgets('editing knowledge and the prompt saves exactly those keys', (
      tester,
    ) async {
      await open(
        tester,
        project(),
        files: [
          FileInfo(
            id: 'file-9',
            filename: 'notes.pdf',
            originalFilename: 'notes.pdf',
            size: 10,
            mimeType: 'application/pdf',
            createdAt: DateTime.utc(2026, 7, 13),
            updatedAt: DateTime.utc(2026, 7, 13),
          ),
        ],
      );
      await openSheet(tester);

      await tester.enterText(
        find.descendant(
          of: key('folder-project-system-prompt'),
          matching: find.byType(EditableText),
        ),
        'Answer in French',
      );
      await tester.tap(key('folder-project-knowledge-0-remove'));
      await tester.pump();
      await chooseOption(
        tester,
        opener: 'folder-project-add-knowledge',
        option: 'file-9',
      );
      await tester.ensureVisible(key('folder-project-save'));
      await tester.tap(key('folder-project-save'));
      await settle(tester);

      final data = await storedData(tester);
      expect(data['model_ids'], ['retired', 'm-a']);
      expect(data['custom'], {'k': 1});
      expect((await queued(tester)).single['data'], {
        'files': [
          {'type': 'file', 'id': 'file-9', 'name': 'notes.pdf'},
        ],
        'system_prompt': 'Answer in French',
      });
    });

    group('the knowledge picker', () {
      const docs = WorkspaceKnowledgeSummary(
        id: 'kb-1',
        name: 'Docs',
        userId: 'owner',
      );
      const alpha = WorkspaceKnowledgeSummary(
        id: 'kb-2',
        name: 'Alpha',
        userId: 'owner',
      );
      const bravo = WorkspaceKnowledgeSummary(
        id: 'kb-3',
        name: 'Bravo',
        userId: 'owner',
      );
      const charlie = WorkspaceKnowledgeSummary(
        id: 'kb-4',
        name: 'Charlie',
        userId: 'owner',
      );
      const delta = WorkspaceKnowledgeSummary(
        id: 'kb-5',
        name: 'Delta',
        userId: 'owner',
      );
      const notesFile = 'file-9';
      const addKnowledge = 'folder-project-add-knowledge';

      // The folder already holds Docs, so the server's first page of two
      // offers one more, and Workspace's own list is left filtered to Alpha.
      Future<void> openWithServerKnowledge(WidgetTester tester) async {
        await open(
          tester,
          project(),
          files: [
            FileInfo(
              id: notesFile,
              filename: 'notes.pdf',
              originalFilename: 'notes.pdf',
              size: 10,
              mimeType: 'application/pdf',
              createdAt: DateTime.utc(2026, 7, 13),
              updatedAt: DateTime.utc(2026, 7, 13),
            ),
          ],
          knowledge: _FilteredKnowledge.new,
        );
        api.knowledge = const [docs, alpha, bravo, charlie, delta];
        await openSheet(tester);
      }

      /// A held request never settles, and its spinner never stops animating.
      Future<void> pumpHeld(WidgetTester tester) async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      Future<void> openPicker(WidgetTester tester) async {
        await tester.ensureVisible(key(addKnowledge));
        await tester.tap(key(addKnowledge));
        await settle(tester);
      }

      Future<void> search(WidgetTester tester, String text) async {
        await tester.enterText(
          find.descendant(
            of: find.byType(ConduitGlassSearchField),
            matching: find.byType(EditableText),
          ),
          text,
        );
        await tester.pump(const Duration(milliseconds: 400));
        await settle(tester);
      }

      Future<void> pick(WidgetTester tester, String id) async {
        await tester.ensureVisible(key('folder-project-option-$id'));
        await tester.tap(key('folder-project-option-$id'));
        await tester.pump();
      }

      Future<void> tapAndSettle(WidgetTester tester, String id) async {
        await tester.ensureVisible(key(id));
        await tester.tap(key(id));
        await settle(tester);
      }

      List<(String, int)> asked() => [
        for (final request in api.knowledgeRequests)
          (request.query ?? '', request.page),
      ];

      testWidgets("offers knowledge beyond the first page that Workspace's "
          'filtered list never held, and saves what is picked from any page', (
        tester,
      ) async {
        await openWithServerKnowledge(tester);

        await openPicker(tester);
        expect(key('folder-project-option-kb-2'), findsOneWidget);
        // Docs is already the folder's; Bravo and the rest are further on.
        expect(key('folder-project-option-kb-1'), findsNothing);
        expect(key('folder-project-option-kb-3'), findsNothing);
        expect(key('folder-project-option-$notesFile'), findsOneWidget);
        expect(asked(), [('', 1)]);

        await tapAndSettle(tester, 'folder-project-picker-more');
        expect(key('folder-project-option-kb-3'), findsOneWidget);
        expect(key('folder-project-option-kb-4'), findsOneWidget);
        await tapAndSettle(tester, 'folder-project-picker-more');
        expect(key('folder-project-option-kb-5'), findsOneWidget);
        expect(key('folder-project-picker-more'), findsNothing);
        expect(asked(), [('', 1), ('', 2), ('', 3)]);

        await pick(tester, 'kb-5');
        await pick(tester, 'kb-2');
        await tester.tap(key('folder-project-picker-add'));
        await tester.pumpAndSettle();

        // What the server lists is not called unavailable because Workspace's
        // own list, filtered, does not carry it.
        expect(key('folder-project-knowledge-1'), findsOneWidget);
        expect(key('folder-project-knowledge-1-unavailable'), findsNothing);
        expect(key('folder-project-knowledge-2-unavailable'), findsNothing);
        await tester.ensureVisible(key('folder-project-save'));
        await tester.tap(key('folder-project-save'));
        await settle(tester);

        expect((await storedData(tester))['files'], [
          {'type': 'collection', 'id': 'kb-1', 'name': 'Docs'},
          {'type': 'collection', 'id': 'kb-5', 'name': 'Delta'},
          {'type': 'collection', 'id': 'kb-2', 'name': 'Alpha'},
        ]);
        // The picker asked on its own terms and left Workspace's list alone.
        expect(
          api.knowledgeRequests.every(
            (r) => (r.view ?? '').isEmpty && (r.source ?? '').isEmpty,
          ),
          isTrue,
        );
        final workspace = container.read(workspaceKnowledgeProvider).value!;
        expect(workspace.query, 'alpha');
        expect(workspace.view, 'created');
        expect(workspace.items.map((item) => item.id), ['kb-2']);
      });

      testWidgets('searches the server, and a choice survives the list it '
          'was made in being replaced', (tester) async {
        await openWithServerKnowledge(tester);
        await openPicker(tester);

        await search(tester, 'charl');
        expect(asked(), [('', 1), ('charl', 1)]);
        expect(key('folder-project-option-kb-4'), findsOneWidget);
        expect(key('folder-project-option-kb-2'), findsNothing);
        await pick(tester, 'kb-4');

        await search(tester, '');
        expect(asked().last, ('', 1));
        expect(key('folder-project-option-kb-2'), findsOneWidget);
        expect(key('folder-project-option-kb-4'), findsNothing);
        await pick(tester, 'kb-2');
        await tester.tap(key('folder-project-picker-add'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(key('folder-project-save'));
        await tester.tap(key('folder-project-save'));
        await settle(tester);

        expect((await storedData(tester))['files'], [
          {'type': 'collection', 'id': 'kb-1', 'name': 'Docs'},
          {'type': 'collection', 'id': 'kb-4', 'name': 'Charlie'},
          {'type': 'collection', 'id': 'kb-2', 'name': 'Alpha'},
        ]);
        expect(
          api.knowledgeRequests.every(
            (r) => (r.view ?? '').isEmpty && (r.source ?? '').isEmpty,
          ),
          isTrue,
        );
      });

      testWidgets('a page that fails is said so and retried, never read as '
          'the end of the list', (tester) async {
        await openWithServerKnowledge(tester);
        api.knowledgeFailures.add('|1');

        await openPicker(tester);
        expect(find.text('Workspace could not be loaded.'), findsOneWidget);
        expect(find.text('Nothing left to add.'), findsNothing);
        // The files that did load are still offered beside the failure.
        expect(key('folder-project-option-$notesFile'), findsOneWidget);
        await tapAndSettle(tester, 'folder-project-picker-retry');
        expect(find.text('Workspace could not be loaded.'), findsNothing);
        expect(key('folder-project-option-kb-2'), findsOneWidget);

        api.knowledgeFailures.add('|2');
        await tapAndSettle(tester, 'folder-project-picker-more');
        expect(find.text('Workspace could not be loaded.'), findsOneWidget);
        expect(find.text('Nothing left to add.'), findsNothing);
        expect(key('folder-project-option-kb-2'), findsOneWidget);
        expect(key('folder-project-option-kb-3'), findsNothing);
        await tapAndSettle(tester, 'folder-project-picker-retry');
        expect(find.text('Workspace could not be loaded.'), findsNothing);
        expect(key('folder-project-option-kb-3'), findsOneWidget);
        expect(asked(), [('', 1), ('', 1), ('', 2), ('', 2)]);
      });

      testWidgets('a sign-in change while a page is held publishes nothing '
          'from it', (tester) async {
        await openWithServerKnowledge(tester);
        api.knowledgeHolds['|1'] = Completer<void>();

        await tester.ensureVisible(key(addKnowledge));
        await tester.tap(key(addKnowledge));
        await pumpHeld(tester);
        expect(asked(), [('', 1)]);
        container.read(_epochProvider.notifier).rotate();
        api.knowledgeHolds['|1']!.complete();
        await settle(tester);

        expect(key('folder-project-option-kb-2'), findsNothing);
        expect(find.text(ownerChangedMessage), findsOneWidget);
        expect(
          tester
              .widget<ConduitButton>(key('folder-project-picker-add'))
              .onPressed,
          isNull,
        );
        expect(key('folder-project-picker-retry'), findsNothing);
        expect(await queued(tester), isEmpty);
      });

      testWidgets('a page held past closing the picker, or the sheet, is '
          'dropped', (tester) async {
        await openWithServerKnowledge(tester);
        api.knowledgeHolds['|1'] = Completer<void>();

        await tester.ensureVisible(key(addKnowledge));
        await tester.tap(key(addKnowledge));
        await pumpHeld(tester);
        final stale = api.knowledgeHolds['|1']!;
        await tester.tap(key('folder-project-picker-cancel'));
        await tester.pump();

        // The next picker is answered at once; the old page lands after it,
        // carrying knowledge the new list never held.
        api.knowledgeHolds.remove('|1');
        await openPicker(tester);
        expect(key('folder-project-option-kb-2'), findsOneWidget);
        api.knowledge = const [
          WorkspaceKnowledgeSummary(id: 'kb-9', name: 'Stale', userId: 'owner'),
        ];
        stale.complete();
        await settle(tester);
        expect(key('folder-project-option-kb-9'), findsNothing);
        expect(key('folder-project-option-kb-2'), findsOneWidget);

        // Held again, then the whole sheet is dismissed with the picker open.
        api.knowledgeHolds['|1'] = Completer<void>();
        await tester.tap(key('folder-project-picker-cancel'));
        await tester.pump();
        await tester.ensureVisible(key(addKnowledge));
        await tester.tap(key(addKnowledge));
        await pumpHeld(tester);
        await tester.tapAt(const Offset(10, 10));
        await settle(tester);
        expect(key('folder-project-picker-list'), findsNothing);
        api.knowledgeHolds['|1']!.complete();
        await settle(tester);

        expect(tester.takeException(), isNull);
        expect(key('folder-project-form'), findsNothing);
      });

      testWidgets('an older search answered after a newer one is dropped', (
        tester,
      ) async {
        await openWithServerKnowledge(tester);
        await openPicker(tester);
        api.knowledgeHolds['charl|1'] = Completer<void>();

        await tester.enterText(
          find.descendant(
            of: find.byType(ConduitGlassSearchField),
            matching: find.byType(EditableText),
          ),
          'charl',
        );
        await tester.pump(const Duration(milliseconds: 400));
        await pumpHeld(tester);
        await search(tester, 'brav');
        expect(key('folder-project-option-kb-3'), findsOneWidget);

        api.knowledgeHolds['charl|1']!.complete();
        await settle(tester);
        expect(asked(), [('', 1), ('charl', 1), ('brav', 1)]);
        expect(key('folder-project-option-kb-3'), findsOneWidget);
        expect(key('folder-project-option-kb-4'), findsNothing);
      });
    });

    testWidgets('entering the folder starts the draft on its saved model, '
        'with Advanced off', (tester) async {
      await open(
        tester,
        project(
          data: {
            'model_ids': ['retired', 'm-b'],
          },
        ),
        liveFolders: true,
      );
      await settle(tester);
      await settle(tester);

      expect(container.read(selectedModelProvider)?.id, 'm-b');
      expect(container.read(pendingFolderIdProvider), 'work');
      expect(find.text('Model B'), findsOneWidget);
    });

    testWidgets('a folder whose saved models are all gone says so once', (
      tester,
    ) async {
      await open(
        tester,
        project(
          data: {
            'model_ids': ['retired'],
          },
        ),
        liveFolders: true,
        overrides: [
          // The user's own default, which the draft falls back to.
          defaultModelProvider.overrideWith((ref) async {
            ref.read(selectedModelProvider.notifier).set(modelA);
            return modelA;
          }),
        ],
      );
      await settle(tester);
      await settle(tester);

      expect(container.read(selectedModelProvider)?.id, 'm-a');
      expect(
        find.text(
          "This folder's default model isn't available, so your default "
          'model is used.',
        ),
        findsOneWidget,
      );
      expect(container.read(folderDraftModelNoticeProvider), isNull);
    });

    group('a folder that saves two models', () {
      Finder sendButton() => find.byKey(const ValueKey('primary-btn-send'));

      Future<void> enterDraft(WidgetTester tester, String text) async {
        await tester.enterText(find.byType(TextField).first, text);
        await tester.pump();
      }

      Future<void> openComparing(
        WidgetTester tester, {
        List<Override> overrides = const <Override>[],
      }) async {
        overrides = [isOnlineProvider.overrideWithValue(true), ...overrides];
        await open(
          tester,
          project(
            data: {
              'model_ids': ['m-a', 'm-b'],
            },
          ),
          liveFolders: true,
          overrides: overrides,
        );
        await settle(tester);
        await settle(tester);
      }

      Future<List<String>> chatIds(WidgetTester tester) async {
        final chats = await tester.runAsync(
          () => db.chatsDao.watchChatList().first,
        );
        return [
          for (final chat in chats!)
            if (chat.id.startsWith('local:')) chat.id,
        ];
      }

      testWidgets('starts the draft comparing both and names them, with '
          'Advanced off', (tester) async {
        await openComparing(tester);

        expect(
          container
              .read(folderDraftComparisonModelsProvider)
              ?.map((model) => model.id),
          ['m-a', 'm-b'],
        );
        expect(find.text('Model A + Model B'), findsOneWidget);
        expect(container.read(selectedModelProvider)?.id, 'm-a');
        expect(container.read(pendingFolderIdProvider), 'work');
        expect(container.read(folderDraftComparisonNoticeProvider), isNull);
      });

      testWidgets('three saved models cannot be one comparison, so the draft '
          'starts on the first and says so once', (tester) async {
        await open(
          tester,
          project(
            data: {
              'model_ids': ['m-a', 'm-b', 'm-a'],
            },
          ),
          liveFolders: true,
          overrides: [isOnlineProvider.overrideWithValue(true)],
        );
        await settle(tester);
        await settle(tester);

        expect(container.read(folderDraftComparisonModelsProvider), isNull);
        expect(container.read(selectedModelProvider)?.id, 'm-a');
        expect(find.text('Model A'), findsOneWidget);
        expect(
          find.text(
            "This project's saved models can't all be used, so the chat "
            'starts with fewer of them. A comparison uses exactly two.',
          ),
          findsOneWidget,
        );
        expect(container.read(folderDraftComparisonNoticeProvider), isNull);
      });

      testWidgets('Send admits one comparison in the folder and opens the '
          'chat', (tester) async {
        await openComparing(tester);

        await enterDraft(tester, 'Compare these two');
        await tester.tap(sendButton());
        await settle(tester);

        final ids = await chatIds(tester);
        expect(ids, hasLength(1));
        final rows = await tester.runAsync(
          () => db.messagesDao.getForChat(ids.single),
        );
        expect(rows!.where((row) => row.role == 'user'), hasLength(1));
        expect(
          rows
              .where((row) => row.role == 'assistant')
              .map((row) => row.model)
              .toList(),
          ['m-a', 'm-b'],
        );
        final ops = await tester.runAsync(
          () => db.outboxDao.pendingForChat(ids.single),
        );
        final completions = [
          for (final op in ops!)
            if (op.kind == OutboxKind.requestCompletion.name) op,
        ];
        expect(completions, hasLength(1));
        final payload = RequestCompletionPayload.fromJson(
          jsonDecode(completions.single.payload) as Map<String, dynamic>,
        );
        expect(payload.comparison?.slots.map((slot) => slot.model), [
          'm-a',
          'm-b',
        ]);
        final chat = await tester.runAsync(() => db.chatsDao.getChat(ids.single));
        expect(chat?.folderId, 'work');
        expect(
          NavigationService.router.routerDelegate.currentConfiguration.uri.path,
          '/chat',
        );
      });

      group('while the account settings hold the admission', () {
        Future<void> sendHeld(WidgetTester tester) async {
          await openComparing(tester);
          api.holdSettings = Completer<void>();
          await enterDraft(tester, 'Compare these two');
          await tester.tap(sendButton());
          await tester.pump();
          await tester.runAsync(
            () => api.settingsEntered.future.timeout(
              const Duration(seconds: 10),
            ),
          );
          // Nothing is written and the page has not moved while it waits.
          expect(await chatIds(tester), isEmpty);
          expect(NavigationService.currentRoute, '/folder/work');
        }

        Future<void> release(WidgetTester tester) async {
          api.holdSettings!.complete();
          await settle(tester);
        }

        Future<void> expectTurnAdmittedInWorkOnce(WidgetTester tester) async {
          final ids = await chatIds(tester);
          expect(ids, hasLength(1));
          final chat = await tester.runAsync(
            () => db.chatsDao.getChat(ids.single),
          );
          expect(chat?.folderId, 'work');
          final rows = await tester.runAsync(
            () => db.messagesDao.getForChat(ids.single),
          );
          expect(rows!.where((row) => row.role == 'user'), hasLength(1));
          expect(rows.where((row) => row.role == 'assistant'), hasLength(2));
          final ops = await tester.runAsync(
            () => db.outboxDao.pendingForChat(ids.single),
          );
          expect(
            ops!.where((op) => op.kind == OutboxKind.requestCompletion.name),
            hasLength(1),
          );
        }

        testWidgets('open the chat once, only after the turn is committed', (
          tester,
        ) async {
          await sendHeld(tester);
          final revision = NavigationService.currentRouteRevision;

          await release(tester);

          await expectTurnAdmittedInWorkOnce(tester);
          expect(NavigationService.currentRoute, '/chat');
          expect(NavigationService.currentRouteRevision, revision + 1);
        });

        testWidgets('a project started meanwhile keeps its own draft while '
            'this turn stays in the project that sent it', (tester) async {
          await sendHeld(tester);
          container.read(pendingFolderIdProvider.notifier).set('other');

          await release(tester);

          await expectTurnAdmittedInWorkOnce(tester);
          expect(container.read(pendingFolderIdProvider), 'other');
          expect(container.read(activeConversationProvider), isNull);
          expect(NavigationService.currentRoute, '/folder/work');
        });

        testWidgets('a page left for another destination does not pull the '
            'user back to the chat', (tester) async {
          await sendHeld(tester);
          NavigationService.router.go('/elsewhere');
          await tester.pumpAndSettle();

          await release(tester);

          await expectTurnAdmittedInWorkOnce(tester);
          expect(NavigationService.currentRoute, '/elsewhere');
        });

        testWidgets('a page kept behind another route does not take the user '
            'to the chat either', (tester) async {
          await sendHeld(tester);
          unawaited(NavigationService.router.push<void>('/elsewhere'));
          await tester.pumpAndSettle();
          // Still mounted, only no longer the route on top.
          expect(find.byType(FolderPage, skipOffstage: false), findsOneWidget);

          await release(tester);

          await expectTurnAdmittedInWorkOnce(tester);
          expect(NavigationService.currentRoute, isNot('/chat'));
        });
      });

      testWidgets('a comparison the server settings refuse keeps the draft '
          'and the page', (tester) async {
        // An image the chosen models cannot read refuses the whole comparison.
        await openComparing(
          tester,
          overrides: [attachedFilesProvider.overrideWith(_Tray.new)],
        );
        (container.read(attachedFilesProvider.notifier) as _Tray).put(
          FileUploadState(
            file: File('/tmp/picture.png'),
            fileName: 'picture.png',
            fileSize: 1,
            progress: 1,
            status: FileUploadStatus.completed,
            fileId: 'data:image/png;base64,AAAA',
            isImage: false,
          ),
        );
        await tester.pump();

        await enterDraft(tester, 'Compare this picture');
        await tester.tap(sendButton());
        await settle(tester);

        expect(await chatIds(tester), isEmpty);
        expect(
          NavigationService.router.routerDelegate.currentConfiguration.uri.path,
          '/folder/work',
        );
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'Compare this picture',
        );
        // Still a comparison draft: nothing was changed by the refusal.
        expect(container.read(folderDraftComparisonModelsProvider), isNotNull);
      });

      testWidgets('picking a model in the picker, even the first one, sends to '
          'that one model', (tester) async {
        // The picker's model icons use the image cache's temporary directory.
        const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          pathProvider,
          (call) async => Directory.systemTemp.path,
        );
        addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
        await openComparing(tester);

        await tester.tap(
          find.byKey(const ValueKey<String>('folder-page-model-selector')),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        // The sheet slides in; pumpAndSettle never settles under it.
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
        await tester.tap(
          find.descendant(
            of: find.byType(ModelSelectorSheet),
            matching: find.text('Model A'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(container.read(folderDraftComparisonModelsProvider), isNull);
        expect(find.text('Model A'), findsOneWidget);

        await enterDraft(tester, 'Just this one');
        await tester.tap(sendButton());
        await settle(tester);

        final ids = await chatIds(tester);
        final rows = await tester.runAsync(
          () => db.messagesDao.getForChat(ids.single),
        );
        expect(rows!.where((row) => row.role == 'assistant'), hasLength(1));
      });
    });

    testWidgets('Cancel sends nothing', (tester) async {
      await open(tester, project(permission: 'write'));
      await openSheet(tester);

      await tester.tap(key('folder-project-model-1-remove'));
      await tester.pump();
      await tester.ensureVisible(key('folder-project-cancel'));
      await tester.tap(key('folder-project-cancel'));
      await settle(tester);

      expect(key('folder-project-save'), findsNothing);
      expect(await queued(tester), isEmpty);
      final row = await tester.runAsync(() => db.foldersDao.getFolder('work'));
      expect(row!.dirty, isFalse);
      expect((await storedData(tester))['model_ids'], ['retired', 'm-a']);
      expect(api.updateCalls, 0);
    });

    testWidgets(
      'the form follows the server unless this device has unsent edits',
      (tester) async {
        await open(
          tester,
          project(),
          liveFolders: true,
          detail: project(
            data: {
              'model_ids': ['m-from-server'],
            },
          ),
        );
        await openSheet(tester);
        expect(
          find.descendant(
            of: key('folder-project-model-0'),
            matching: find.text('m-from-server'),
          ),
          findsOneWidget,
        );

        // An edit made offline and not pushed yet is what the form shows.
        await tester.tap(key('folder-project-cancel'));
        await settle(tester);
        await tester.runAsync(
          () => db.foldersDao.patchFolderDataWithOutbox(
            id: 'work',
            dataPatch: {
              'model_ids': ['m-offline'],
            },
          ),
        );
        // The page lists the folder from the database, so it shows the edit.
        await settle(tester);
        await openSheet(tester);
        expect(
          find.descendant(
            of: key('folder-project-model-0'),
            matching: find.text('m-offline'),
          ),
          findsOneWidget,
        );
        expect(find.text('m-from-server'), findsNothing);
      },
    );

    testWidgets('a collection the server no longer lists is shown and kept', (
      tester,
    ) async {
      await open(
        tester,
        project(
          data: {
            'files': [
              {'type': 'collection', 'id': 'kb-gone', 'name': 'Old docs'},
            ],
          },
        ),
      );
      await openSheet(tester);

      expect(key('folder-project-knowledge-0-unavailable'), findsOneWidget);
      await chooseOption(
        tester,
        opener: 'folder-project-add-model',
        option: 'm-a',
      );
      await tester.ensureVisible(key('folder-project-save'));
      await tester.tap(key('folder-project-save'));
      await settle(tester);

      final data = await storedData(tester);
      expect(data['files'], [
        {'type': 'collection', 'id': 'kb-gone', 'name': 'Old docs'},
      ]);
      expect(data['model_ids'], ['m-a']);
    });

    testWidgets('a deleted individual file is shown and kept; one the server '
        'cannot vouch for either way is not called deleted', (tester) async {
      await open(
        tester,
        project(
          data: {
            'files': [
              {'type': 'file', 'id': 'file-gone', 'name': 'Old notes.txt'},
              {'type': 'file', 'id': 'file-shared', 'name': 'Shared.pdf'},
              {'type': 'file', 'id': 'file-flaky', 'name': 'Flaky.pdf'},
              {'type': 'file', 'id': 'file-gone', 'name': 'Old notes.txt'},
            ],
          },
        ),
        fileStatus: {'file-gone': 404, 'file-flaky': 500},
      );
      await openSheet(tester);

      expect(key('folder-project-knowledge-0-unavailable'), findsOneWidget);
      // The shared file is in nobody's first page of files, and is valid.
      expect(key('folder-project-knowledge-1-unavailable'), findsNothing);
      // A failed lookup is unknown, not deletion.
      expect(key('folder-project-knowledge-2-unavailable'), findsNothing);
      expect(key('folder-project-knowledge-3-unavailable'), findsOneWidget);
      // Each file is asked about once.
      expect(api.fileLookups.toSet(), {
        'file-gone',
        'file-shared',
        'file-flaky',
      });
      expect(api.fileLookups, hasLength(3));

      await chooseOption(
        tester,
        opener: 'folder-project-add-model',
        option: 'm-a',
      );
      await tester.ensureVisible(key('folder-project-save'));
      await tester.tap(key('folder-project-save'));
      await settle(tester);

      final data = await storedData(tester);
      expect(data['files'], [
        {'type': 'file', 'id': 'file-gone', 'name': 'Old notes.txt'},
        {'type': 'file', 'id': 'file-shared', 'name': 'Shared.pdf'},
        {'type': 'file', 'id': 'file-flaky', 'name': 'Flaky.pdf'},
        {'type': 'file', 'id': 'file-gone', 'name': 'Old notes.txt'},
      ]);
      expect(data['model_ids'], ['m-a']);
    });

    testWidgets('a recipient the server says cannot write is refused even '
        'though the cached grant was write', (tester) async {
      // GET /folders/{id}: write_access and access_grants, none of the shared
      // listing's own shared / permission.
      final fresh = project()
        ..['write_access'] = false
        ..['user_id'] = 'someone-else'
        ..['access_grants'] = [
          {
            'principal_type': 'user',
            'principal_id': 'me',
            'permission': 'read',
          },
        ];
      await open(
        tester,
        project(permission: 'write'),
        role: 'user',
        detail: fresh,
      );
      await openSheet(tester);
      await tester.tap(key('folder-project-model-1-remove'));
      await tester.pump();
      await tester.ensureVisible(key('folder-project-save'));
      await tester.tap(key('folder-project-save'));
      await settle(tester);

      expect(find.text(readOnlyMessage), findsOneWidget);
      expect(await queued(tester), isEmpty);
      expect((await storedData(tester))['model_ids'], ['retired', 'm-a']);
      // The edit is still in the open form.
      expect(key('folder-project-model-1'), findsNothing);
      expect(key('folder-project-save'), findsOneWidget);
    });

    testWidgets('a grant lowered while the editor was open is not written', (
      tester,
    ) async {
      await open(tester, project(permission: 'write'));
      await openSheet(tester);
      await tester.tap(key('folder-project-model-1-remove'));
      await tester.pump();

      // A pull lowers the grant to read before Save.
      await tester.runAsync(
        () => db.foldersDao.replaceServerFolders([project(permission: 'read')]),
      );
      await tester.ensureVisible(key('folder-project-save'));
      await tester.tap(key('folder-project-save'));
      await settle(tester);

      expect(find.text(readOnlyMessage), findsOneWidget);
      expect(await queued(tester), isEmpty);
      // The sheet stays open with the edit still in it.
      expect(key('folder-project-model-1'), findsNothing);
      expect(key('folder-project-save'), findsOneWidget);
    });

    testWidgets('another account signing in while it is open writes nothing', (
      tester,
    ) async {
      await open(tester, project(permission: 'write'));
      await openSheet(tester);
      await tester.tap(key('folder-project-model-1-remove'));
      await tester.pump();

      container.read(_epochProvider.notifier).rotate();
      await tester.ensureVisible(key('folder-project-save'));
      await tester.tap(key('folder-project-save'));
      await settle(tester);

      expect(find.text(ownerChangedMessage), findsOneWidget);
      expect(await queued(tester), isEmpty);
      expect((await storedData(tester))['model_ids'], ['retired', 'm-a']);
    });

    testWidgets(
      'on the native iOS 26 sheet it edits and saves from a phone with the keyboard up',
      (tester) async {
        await open(tester, project(permission: 'write'), native: true);
        await openSheet(tester, native: true);

        // Entering text, scrolling to Save and saving all happen with the
        // software keyboard covering the bottom of the view.
        tester.view.viewInsets = const FakeViewPadding(bottom: 336);
        tester.view.padding = const FakeViewPadding(top: 62);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: key('folder-project-system-prompt'),
            matching: find.byType(EditableText),
          ),
          'Answer in French',
        );
        await tester.pump();
        await tester.scrollUntilVisible(
          key('folder-project-add-model'),
          120,
          scrollable: find
              .descendant(
                of: key('folder-project-form'),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await chooseOption(
          tester,
          opener: 'folder-project-add-model',
          option: 'm-b',
        );
        // The form list is lazy and the picker shared its scroll position.
        await tester.scrollUntilVisible(
          key('folder-project-model-2'),
          120,
          scrollable: find
              .descendant(
                of: key('folder-project-form'),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(key('folder-project-model-2'), findsOneWidget);
        await tester.ensureVisible(key('folder-project-save'));
        await tester.pumpAndSettle();
        expect(
          tester.getBottomLeft(key('folder-project-save')).dy,
          lessThanOrEqualTo(844 - 336),
        );
        expect(
          tester.getBottomLeft(key('folder-project-cancel')).dy,
          lessThanOrEqualTo(844 - 336),
        );

        tester.view.viewInsets = FakeViewPadding.zero;
        tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
        await tester.pumpAndSettle();
        await tester.tap(key('folder-project-save'));
        await settle(tester);

        expect(tester.takeException(), isNull);
        expect(
          key('folder-project-failure').evaluate().isEmpty
              ? null
              : tester.widget<Text>(key('folder-project-failure')).data,
          isNull,
        );
        expect(key('folder-project-save'), findsNothing);
        final data = await storedData(tester);
        expect(data['model_ids'], ['retired', 'm-a', 'm-b']);
        expect(data['system_prompt'], 'Answer in French');
        expect(data['custom'], {'k': 1});
      },
    );
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
  AppDatabase? database,
  // Read the folder list from [database], as the app does, instead of the
  // fixed [folders].
  bool liveFolders = false,
  List<Override> extraOverrides = const <Override>[],
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
      if (!liveFolders)
        foldersProvider.overrideWith(() => _TestFolders(folders)),
      toolsListProvider.overrideWith(_TestToolsList.new),
      ...extraOverrides,
    ],
  );
}

Widget _buildHarnessFromContainer(
  ProviderContainer container, {
  Listenable? routerRefreshListenable,
}) {
  final router = GoRouter(
    initialLocation: '/folder/work',
    refreshListenable: routerRefreshListenable,
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
      GoRoute(
        path: '/elsewhere',
        builder: (context, state) => const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
  NavigationService.attachRouter(router);

  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
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

/// The composer's tray, holding a file that was picked and uploaded elsewhere.
class _Tray extends AttachedFilesNotifier {
  void put(FileUploadState file) => state = [...state, file];
}

class _Epoch extends Notifier<Object> {
  @override
  Object build() => Object();

  /// A new sign-in session: another account, or a sign-out and back in.
  void rotate() => state = Object();
}

final _epochProvider = NotifierProvider<_Epoch, Object>(_Epoch.new);

class _NoDrainEngine extends SyncEngine {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {}
}

class _TestKnowledge extends WorkspaceKnowledge {
  @override
  Future<WorkspaceCollectionState<WorkspaceKnowledgeSummary>> build() async =>
      const WorkspaceCollectionState(
        items: [
          WorkspaceKnowledgeSummary(id: 'kb-1', name: 'Docs', userId: 'owner'),
        ],
        total: 1,
      );
}

/// The Workspace screen's list as someone left it: searched and filtered, so
/// it holds one match and says there is nothing more.
class _FilteredKnowledge extends WorkspaceKnowledge {
  @override
  Future<WorkspaceCollectionState<WorkspaceKnowledgeSummary>> build() async =>
      const WorkspaceCollectionState(
        query: 'alpha',
        view: 'created',
        items: [
          WorkspaceKnowledgeSummary(id: 'kb-2', name: 'Alpha', userId: 'owner'),
        ],
        total: 1,
      );
}

class _TestUserFiles extends UserFiles {
  _TestUserFiles(this.files);

  final List<FileInfo> files;

  @override
  Future<List<FileInfo>> build() async => files;
}

class _QuietAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{}',
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// A real [ApiService], so the account the editor captures is a real one, with
/// the folder read answered locally and nothing else leaving the test.
class _ProjectApi extends ApiService {
  _ProjectApi(this.detail, this.fileStatus)
    : super(
        serverConfig: const ServerConfig(
          id: 'srv',
          name: 'Server',
          url: 'https://srv.example.test',
        ),
        workerManager: WorkerManager(),
        authToken: 'test-token',
      ) {
    dio.httpClientAdapter = _QuietAdapter();
  }

  final Map<String, dynamic>? detail;

  /// The status the server answers a file lookup with; 200 unless listed.
  final Map<String, int> fileStatus;
  final fileLookups = <String>[];
  int updateCalls = 0;

  /// Every knowledge base the server lists, in its order. A query keeps those
  /// whose name contains it, and pages are [knowledgePageSize] long.
  List<WorkspaceKnowledgeSummary> knowledge = const [];
  int knowledgePageSize = 2;
  final knowledgeRequests =
      <({String? query, String? view, String? source, int page})>[];

  /// Requests, keyed `query|page`, answered only once their completer
  /// completes; the answer is computed then, from [knowledge] as it is by
  /// that time.
  final knowledgeHolds = <String, Completer<void>>{};

  /// Requests, keyed `query|page`, that fail once.
  final knowledgeFailures = <String>{};

  @override
  Future<WorkspacePagedResponse<WorkspaceKnowledgeSummary>>
  getWorkspaceKnowledge({
    String? query,
    String? viewOption,
    String? source,
    int page = 1,
  }) async {
    knowledgeRequests.add((
      query: query,
      view: viewOption,
      source: source,
      page: page,
    ));
    final key = '${query ?? ''}|$page';
    await knowledgeHolds[key]?.future;
    if (knowledgeFailures.remove(key)) throw StateError('knowledge $key');
    final needle = (query ?? '').trim().toLowerCase();
    final matching = [
      for (final item in knowledge)
        if (needle.isEmpty || item.name.toLowerCase().contains(needle)) item,
    ];
    return WorkspacePagedResponse(
      items: matching
          .skip((page - 1) * knowledgePageSize)
          .take(knowledgePageSize)
          .toList(),
      total: matching.length,
    );
  }

  @override
  Future<Map<String, dynamic>> getFileInfo(
    String fileId, {
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    fileLookups.add(fileId);
    final status = fileStatus[fileId] ?? 200;
    if (status == 200) return <String, dynamic>{'id': fileId};
    final request = RequestOptions(path: '/api/v1/files/$fileId');
    throw DioException(
      requestOptions: request,
      response: Response<Object?>(
        requestOptions: request,
        statusCode: status,
        data: <String, dynamic>{'detail': 'File not found'},
      ),
    );
  }

  @override
  Future<Map<String, dynamic>?> getFolderById(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async => detail;

  /// When set, the settings are answered only once this completes, and
  /// [settingsEntered] marks the wait: an admission suspended mid-flight.
  Completer<void>? holdSettings;
  final settingsEntered = Completer<void>();

  /// Admitting a turn reads the account's settings from the server.
  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async {
    final hold = holdSettings;
    if (hold != null) {
      if (!settingsEntered.isCompleted) settingsEntered.complete();
      await hold.future;
    }
    return const <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>?> updateFolder(
    String id, {
    String? name,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) async {
    updateCalls++;
    return null;
  }
}

class _FakeFolderApiService extends Fake implements ApiService {
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
  Future<Map<String, dynamic>?> getFolderById(
    String id, {
    Object? authSnapshot,
  }) async {
    if (id != 'work') {
      return null;
    }
    return Map<String, dynamic>.from(_folder);
  }

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async =>
      <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> getUserPermissions({
    Object? authSnapshot,
  }) async => <String, dynamic>{};

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
