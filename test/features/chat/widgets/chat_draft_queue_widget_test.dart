import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;

import 'package:conduit/core/services/media_upload_controller.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_draft_queue.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _chatId = 'chat-1';

class _ActiveChat extends ActiveConversationNotifier {
  _ActiveChat(this.initial);

  final Conversation initial;

  @override
  Conversation? build() => initial;
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];

  @override
  void setMessages(List<ChatMessage> messages) {
    state = List<ChatMessage>.from(messages);
  }

  @override
  void addMessages(List<ChatMessage> messages) {
    state = <ChatMessage>[...state, ...messages];
  }

  @override
  void updateMessageById(
    String messageId,
    ChatMessage Function(ChatMessage current) updater,
  ) {
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    final next = List<ChatMessage>.from(state);
    next[index] = updater(next[index]);
    state = next;
  }

  @override
  void finishStreaming() {
    if (state.isEmpty) return;
    state = <ChatMessage>[
      ...state.sublist(0, state.length - 1),
      state.last.copyWith(isStreaming: false),
    ];
  }
}

class _Settings extends AppSettingsNotifier {
  _Settings({required this.advanced});

  final bool advanced;

  @override
  AppSettings build() =>
      AppSettings(advancedFeaturesEnabled: advanced, sendOnEnter: true);

  void setAdvanced(bool value) =>
      state = state.copyWith(advancedFeaturesEnabled: value);
}

class _Engine extends SyncEngine {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {}
}

/// An Open WebUI server that answers nothing except the chat's task stop.
class _Api extends ApiService {
  _Api()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'server',
          url: 'https://server.example.test',
        ),
        workerManager: WorkerManager(),
      ) {
    dio.httpClientAdapter = _Silent();
    dio.interceptors.clear();
  }

  final List<String> stoppedChats = [];

  @override
  Future<void> stopTasksByChat(String chatId) async {
    stoppedChats.add(chatId);
  }

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async =>
      const <String, dynamic>{};
}

class _Silent implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async => ResponseBody.fromString(
    jsonEncode(const <String, dynamic>{}),
    404,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

List<ChatMessage> _runningTurn() => <ChatMessage>[
  ChatMessage(
    id: 'u0',
    role: 'user',
    content: 'earlier',
    timestamp: DateTime.utc(2026, 10, 6),
  ),
  ChatMessage(
    id: 'a0',
    role: 'assistant',
    content: 'partial',
    timestamp: DateTime.utc(2026, 10, 6, 0, 0, 1),
    model: 'model-1',
    isStreaming: true,
  ),
];

/// One prompt answered by two models, both ending the transcript. [running]
/// names the answers still streaming.
List<ChatMessage> _comparisonTurn({required Set<String> running}) =>
    <ChatMessage>[
      ChatMessage(
        id: 'cu',
        role: 'user',
        content: 'compare these',
        timestamp: DateTime.utc(2026, 10, 6),
      ),
      for (var slot = 0; slot < 2; slot++)
        ChatMessage(
          id: 'c$slot',
          role: 'assistant',
          content: 'answer $slot',
          timestamp: DateTime.utc(2026, 10, 6, 0, 0, 1 + slot),
          model: 'model-${slot + 1}',
          isStreaming: running.contains('c$slot'),
          metadata: <String, dynamic>{
            'parentId': 'cu',
            'modelIdx': slot,
          },
        ),
    ];

class _Rig {
  _Rig(this.tester, this.db, this.api, this.sent);

  final WidgetTester tester;
  final AppDatabase db;
  final _Api api;
  final List<String> sent;

  ProviderContainer get container =>
      ProviderScope.containerOf(tester.element(find.byType(ModernChatInput)));

  List<QueuedChatDraft> get drafts =>
      container.read(activeChatDraftQueueProvider)?.drafts ?? const [];

  Future<void> type(String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pump();
  }

  String get typed => tester.widget<TextField>(find.byType(TextField).first)
      .controller!
      .text;

  Future<List<String>> userTurns() async => [
    for (final row in await db.messagesDao.getForChat(_chatId))
      if (row.role == 'user') row.content,
  ];
}

/// Records which queued files the sheet asks to upload again.
class _RecordingUploads extends MediaUploadController {
  _RecordingUploads(super.ref);

  final List<(String, String)> retried = [];

  @override
  Future<void> retryQueuedAttachment({
    required String queueId,
    required String id,
  }) async {
    retried.add((queueId, id));
  }
}

Future<_Rig> _pump(
  WidgetTester tester, {
  bool advanced = true,
  bool streaming = true,
  List<ChatMessage>? turn,
  List<Override> overrides = const [],
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.runAsync(
    () => db
        .into(db.chats)
        .insert(
          ChatsCompanion.insert(
            id: _chatId,
            title: 'chat',
            createdAt: 1,
            updatedAt: 1,
            bodySynced: const Value(true),
          ),
        ),
  );
  final api = _Api();
  addTearDown(api.dispose);
  final sent = <String>[];
  final messages =
      turn ?? (streaming ? _runningTurn() : _runningTurn().sublist(0, 1));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        apiServiceProvider.overrideWithValue(api),
        activeConversationProvider.overrideWith(
          () => _ActiveChat(
            withChatStorageProvenance(
              Conversation(
                id: _chatId,
                title: 'chat',
                createdAt: DateTime.utc(2026, 10, 6),
                updatedAt: DateTime.utc(2026, 10, 6),
                messages: messages,
              ),
              ChatStorageKind.openWebUi,
            ),
          ),
        ),
        chatMessagesProvider.overrideWith(_Messages.new),
        selectedModelProvider.overrideWithValue(
          const Model(id: 'model-1', name: 'Model 1'),
        ),
        reviewerModeProvider.overrideWithValue(false),
        isOnlineProvider.overrideWithValue(true),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'user-1',
            username: 'user',
            email: 'user@example.test',
            role: 'user',
          ),
        ),
        appSettingsProvider.overrideWith(() => _Settings(advanced: advanced)),
        syncEngineProvider.overrideWith(_Engine.new),
        webSearchAvailableProvider.overrideWithValue(false),
        imageGenerationAvailableProvider.overrideWithValue(false),
        selectedFilterIdsProvider.overrideWithValue(const <String>[]),
        selectedTerminalIdProvider.overrideWithValue(null),
        ...overrides,
      ],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ModernChatInput(onSendMessage: sent.add),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final rig = _Rig(tester, db, api, sent);
  rig.container
      .read(chatMessagesProvider.notifier)
      .setMessages(messages);
  await tester.pump();
  return rig;
}

void main() {
  const queueLabel = 'Queue';
  final stop = find.byKey(const ValueKey('primary-btn-stop'));

  testWidgets('with Advanced off, Queue holds the typed message behind the '
      'response and leaves Stop and Send alone', (tester) async {
    final rig = await _pump(tester, advanced: false);

    await rig.type('next question');
    expect(find.text(queueLabel), findsOneWidget);
    expect(stop, findsOneWidget);

    await tester.tap(find.text(queueLabel));
    await tester.pump();

    expect(rig.sent, isEmpty);
    expect(rig.typed, isEmpty);
    expect(rig.drafts.map((d) => d.text), ['next question']);
    expect(find.byKey(const Key('chat-draft-queue-row')), findsOneWidget);
    expect(find.text('1 queued message'), findsOneWidget);
    // Stop is still Stop; it was never turned into a queue action.
    expect(stop, findsOneWidget);
    expect(find.text(queueLabel), findsNothing);
    // Nothing was sent to the server: the response is still running.
    expect(await tester.runAsync(rig.userTurns), isEmpty);
  });

  testWidgets('Enter queues instead of starting a second turn mid-response',
      (tester) async {
    final rig = await _pump(tester);

    await rig.type('by keyboard');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(rig.sent, isEmpty);
    expect(rig.drafts.map((d) => d.text), ['by keyboard']);
    expect(rig.typed, isEmpty);
  });

  testWidgets('without a running response Enter still sends, and no Queue shows',
      (tester) async {
    final rig = await _pump(tester, streaming: false);

    await rig.type('ordinary');
    expect(find.text(queueLabel), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(rig.sent, ['ordinary']);
    expect(rig.drafts, isEmpty);
  });

  testWidgets('the sheet edits and removes by draft, and send now stops the '
      'response and sends only that draft', (tester) async {
    final rig = await _pump(tester);
    for (final text in ['first', 'second', 'third']) {
      await rig.type(text);
      await tester.tap(find.text(queueLabel));
      await tester.pump();
    }
    final ids = {for (final d in rig.drafts) d.text: d.id};

    await tester.tap(find.byKey(const Key('chat-draft-queue-row')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('chat-draft-edit-action-${ids['second']}')));
    await tester.pump();
    await tester.enterText(
      find.byKey(Key('chat-draft-edit-${ids['second']}')),
      'second, edited',
    );
    await tester.tap(find.byKey(Key('chat-draft-save-${ids['second']}')));
    await tester.pump();
    expect(rig.drafts.map((d) => d.text), ['first', 'second, edited', 'third']);

    await tester.tap(find.byKey(Key('chat-draft-delete-${ids['third']}')));
    await tester.pump();
    expect(rig.drafts.map((d) => d.text), ['first', 'second, edited']);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(Key('chat-draft-send-now-${ids['first']}')));
      for (var i = 0; i < 200 && rig.drafts.length > 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    expect(rig.api.stoppedChats, [_chatId]);
    expect(await tester.runAsync(rig.userTurns), ['first']);
    expect(rig.drafts.map((d) => d.text), ['second, edited']);
    expect(rig.sent, isEmpty);
  });

  testWidgets('while one answer of a comparison still runs the composer keeps '
      'Stop and Queue, and the queue goes out when the last answer ends',
      (tester) async {
    // The second model has finished; the first is still answering.
    final rig = await _pump(
      tester,
      turn: _comparisonTurn(running: {'c0'}),
    );

    await rig.type('next question');
    expect(find.text(queueLabel), findsOneWidget);
    expect(stop, findsOneWidget);
    await tester.tap(find.text(queueLabel));
    await tester.pump();
    expect(rig.drafts.map((d) => d.text), ['next question']);

    // The queued draft stays in view and Stop stays, whatever Advanced says.
    (rig.container.read(appSettingsProvider.notifier) as _Settings)
        .setAdvanced(false);
    await tester.pump();
    expect(find.byKey(const Key('chat-draft-queue-row')), findsOneWidget);
    expect(stop, findsOneWidget);
    expect(await tester.runAsync(rig.userTurns), isEmpty);

    rig.container
        .read(chatMessagesProvider.notifier)
        .finishSlotMessage('c0');
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && rig.drafts.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    expect(await tester.runAsync(rig.userTurns), ['next question']);
    expect(rig.drafts, isEmpty);
    expect(rig.sent, isEmpty);
  });

  testWidgets('a draft with a file that is still uploading says so and cannot '
      'be sent now', (tester) async {
    final rig = await _pump(tester);
    // A picked file whose upload has not finished is still waiting.
    final directory = Directory.systemTemp.createTempSync('queue-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final picked = File('${directory.path}/slow.txt')..writeAsBytesSync([1]);
    rig.container
        .read(attachedFilesProvider.notifier)
        .addFiles([LocalAttachment(file: picked, displayName: 'slow.txt')]);
    await rig.type('with a file');
    await tester.tap(find.text(queueLabel));
    await tester.pump();
    final id = rig.drafts.single.id;

    await tester.tap(find.byKey(const Key('chat-draft-queue-row')));
    await tester.pumpAndSettle();

    expect(find.text('slow.txt'), findsOneWidget);
    expect(
      find.text('Waiting for a file to finish uploading'),
      findsOneWidget,
    );
    final sendNow = tester.widget<ConduitButton>(
      find.byKey(Key('chat-draft-send-now-$id')),
    );
    expect(sendNow.onPressed, isNull);
  });

  testWidgets('a failed file can be uploaded again from its own draft', (
    tester,
  ) async {
    late _RecordingUploads uploads;
    final rig = await _pump(
      tester,
      overrides: [
        mediaUploadControllerProvider.overrideWith(
          (ref) => uploads = _RecordingUploads(ref),
        ),
      ],
    );
    final directory = Directory.systemTemp.createTempSync('queue-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final picked = File('${directory.path}/shared.txt')..writeAsBytesSync([1]);
    rig.container
        .read(attachedFilesProvider.notifier)
        .addFiles([LocalAttachment(file: picked, displayName: 'shared.txt')]);
    await rig.type('with a file');
    await tester.tap(find.text(queueLabel));
    await tester.pump();
    final draft = rig.drafts.single;
    // Another queue's upload at the same path finished first, so this file
    // failed instead of waiting.
    final held = rig.container.read(queuedDraftAttachmentsProvider).single;
    rig.container
        .read(queuedDraftAttachmentsProvider.notifier)
        .replaceUpload(
          held.upload,
          FileUploadState(
            file: picked,
            fileName: 'shared.txt',
            fileSize: 1,
            progress: 0,
            status: FileUploadStatus.failed,
            error: 'failed',
            isImage: false,
          ),
        );
    await tester.tap(find.byKey(const Key('chat-draft-queue-row')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(Key('chat-draft-retry-file-${draft.id}-${held.id}')),
    );
    await tester.pump();

    expect(uploads.retried, [(held.queueId, held.id)]);
  });
}
