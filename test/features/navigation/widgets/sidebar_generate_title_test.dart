import 'dart:async';

import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sidebar_page_test_support.dart';

/// Serves one chat and a title for it, and records what was asked and saved.
final class _TitlingApi extends SidebarTestSidebarApiService {
  _TitlingApi({
    this.title = 'Quines explained',
    this.renameWhileWriting,
    this.chatExists = true,
  });

  final String? title;

  /// The title the user gives the chat elsewhere while the title is written.
  final String? renameWhileWriting;
  final bool chatExists;

  /// The chat's title on the server.
  String serverTitle = 'Chat server';

  /// Completes the title request when set, so a test can act meanwhile.
  Completer<void>? holdTitle;

  static final _snapshots = ApiService(
    serverConfig: const ServerConfig(id: 's', name: 'S', url: 'http://s'),
    workerManager: WorkerManager(),
  );

  @override
  ApiAuthSnapshot captureAuthSnapshot() => _snapshots.captureAuthSnapshot();
  final titleRequests = <({String model, List<Map<String, dynamic>> messages})>[];
  final savedTitles = <({String id, String? title})>[];

  @override
  Future<Map<String, dynamic>?> getChatRaw(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async => !chatExists ? null : {
    'id': id,
    'title': serverTitle,
    'chat': {
      'models': ['chat-model'],
      'history': {
        'currentId': 'a1',
        'messages': {
          'u1': {
            'id': 'u1',
            'parentId': null,
            'role': 'user',
            'content': 'What is a quine?',
          },
          'a1': {
            'id': 'a1',
            'parentId': 'u1',
            'role': 'assistant',
            'model': 'answer-model',
            'content': 'A program that prints itself.',
          },
        },
      },
    },
  };

  @override
  Future<String?> generateChatTitle({
    required String model,
    required List<Map<String, dynamic>> messages,
    String? chatId,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    titleRequests.add((model: model, messages: messages));
    await holdTitle?.future;
    serverTitle = renameWhileWriting ?? serverTitle;
    return title;
  }

  @override
  Future<Conversation> getConversation(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async => Conversation(
    id: id,
    title: serverTitle,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1, 10),
    messages: const [],
  );

  @override
  Future<void> updateConversation(
    String id, {
    String? title,
    String? systemPrompt,
    List<String>? models,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    savedTitles.add((id: id, title: title));
  }
}

void main() {
  final l10n = AppLocalizationsEn();

  Conversation chat(String id) => Conversation(
    id: id,
    title: 'Chat $id',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1, 10),
    messages: const [],
  );

  ConduitContextMenu menuOf(WidgetTester tester, Conversation conversation) {
    final tile = find.byKey(
      ValueKey<String>('drawer-chat-${conversationScopedId(conversation)}'),
    );
    return tester.widget<ConduitContextMenu>(
      find.ancestor(of: tile, matching: find.byType(ConduitContextMenu)).first,
    );
  }

  testWidgets('an Open WebUI chat offers Generate Title next to Rename', (
    tester,
  ) async {
    final server = chat('server');
    final onDevice = withChatStorageProvenance(
      chat('on-device'),
      ChatStorageKind.directLocal,
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [server, onDevice],
      ),
    );
    await tester.pumpAndSettle();

    final labels = [
      for (final action in menuOf(tester, server).actions) action.label,
    ];
    expect(labels, contains(l10n.generateTitle));
    expect(
      labels.indexOf(l10n.generateTitle),
      labels.indexOf(l10n.rename) + 1,
    );
    expect(
      [for (final action in menuOf(tester, onDevice).actions) action.label],
      isNot(contains(l10n.generateTitle)),
    );
  });

  testWidgets('Generate Title saves the title the server makes', (
    tester,
  ) async {
    final server = chat('server');
    final api = _TitlingApi();

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [server],
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();

    final generate = menuOf(
      tester,
      server,
    ).actions.singleWhere((action) => action.label == l10n.generateTitle);
    await generate.onSelected();
    await tester.pumpAndSettle();

    expect(api.titleRequests.single.model, 'answer-model');
    expect(api.titleRequests.single.messages, [
      {'role': 'user', 'content': 'What is a quine?'},
      {'role': 'assistant', 'content': 'A program that prints itself.'},
    ]);
    expect(api.savedTitles.single, (id: 'server', title: 'Quines explained'));
  });

  testWidgets('a title the list already shows is saved when the server has another', (
    tester,
  ) async {
    // The chat list's copy can lag the server's title.
    final server = chat('server');
    final api = _TitlingApi(title: 'Chat server')
      ..serverTitle = 'Older title';

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [server],
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();

    final generate = menuOf(
      tester,
      server,
    ).actions.singleWhere((action) => action.label == l10n.generateTitle);
    await generate.onSelected();
    await tester.pumpAndSettle();

    expect(api.savedTitles.single, (id: 'server', title: 'Chat server'));
  });

  testWidgets('a save of the chat under way finishes before the title is saved', (
    tester,
  ) async {
    // A full save sends the title it read; landing after this one, it would
    // put the old title back.
    final server = chat('server');
    final api = _TitlingApi();

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [server],
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ConduitContextMenu).first),
    );
    final saving = Completer<void>();
    final save = container
        .read(chatLocksProvider)
        .runExclusive('server', () => saving.future);

    final generate = menuOf(
      tester,
      server,
    ).actions.singleWhere((action) => action.label == l10n.generateTitle);
    final generated = generate.onSelected();
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(api.titleRequests, hasLength(1));
    expect(api.savedTitles, isEmpty);

    saving.complete();
    await save;
    await generated;
    await tester.pumpAndSettle();

    expect(api.savedTitles.single, (id: 'server', title: 'Quines explained'));
  });

  testWidgets('a rename made while the title was written is kept', (
    tester,
  ) async {
    final server = chat('server');
    final api = _TitlingApi(renameWhileWriting: 'Renamed meanwhile');

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [server],
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();

    final generate = menuOf(
      tester,
      server,
    ).actions.singleWhere((action) => action.label == l10n.generateTitle);
    await generate.onSelected();
    await tester.pumpAndSettle();

    expect(api.titleRequests, hasLength(1));
    expect(api.savedTitles, isEmpty);
  });

  testWidgets('a second tap waits for the first', (tester) async {
    final server = chat('server');
    final api = _TitlingApi()..holdTitle = Completer<void>();

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [server],
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();

    final generate = menuOf(
      tester,
      server,
    ).actions.singleWhere((action) => action.label == l10n.generateTitle);
    final first = generate.onSelected();
    await tester.pump();
    await generate.onSelected();
    api.holdTitle!.complete();
    await first;
    await tester.pumpAndSettle();

    expect(api.titleRequests, hasLength(1));
    expect(api.savedTitles, hasLength(1));
  });

  testWidgets('a chat the server does not hold says it failed', (
    tester,
  ) async {
    final server = chat('server');
    final api = _TitlingApi(chatExists: false);

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [server],
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();

    final generate = menuOf(
      tester,
      server,
    ).actions.singleWhere((action) => action.label == l10n.generateTitle);
    final done = generate.onSelected();
    await tester.pumpAndSettle();

    expect(find.text(l10n.generateTitleFailed), findsOneWidget);
    expect(api.titleRequests, isEmpty);
    await tester.tap(find.text(l10n.ok));
    await tester.pumpAndSettle();
    await done;
  });

  testWidgets('no title from the server is said, and nothing is saved', (
    tester,
  ) async {
    final server = chat('server');
    final api = _TitlingApi(title: null);

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [server],
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();

    final generate = menuOf(
      tester,
      server,
    ).actions.singleWhere((action) => action.label == l10n.generateTitle);
    // The explanation waits for the user to close it.
    final done = generate.onSelected();
    await tester.pumpAndSettle();

    expect(find.text(l10n.generateTitleNone), findsOneWidget);
    expect(api.savedTitles, isEmpty);

    await tester.tap(find.text(l10n.ok));
    await tester.pumpAndSettle();
    await done;
  });
}
