import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/models/chat_context_attachment.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit_core/features/chat/services/chat_draft_queue.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart'
    show kDirectTransport;
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart'
    show kHermesTransport;
import 'package:conduit_core/models/chat_comparison.dart'
    show kMessageModelIdxMetadataKey;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/id_remapper.dart' show RemapEvent;
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

class _SeededActive extends ActiveConversationNotifier {
  _SeededActive(this.initial);

  final Conversation? initial;

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

class _Holder<T> extends Notifier<T> {
  _Holder(this.initial);

  final T initial;

  @override
  T build() => initial;

  void use(T value) => state = value;
}

/// The composer's tray, holding files that were picked and uploaded elsewhere.
class _Tray extends AttachedFilesNotifier {
  void put(List<FileUploadState> files) => state = [...state, ...files];
}

/// The server. Only the calls the queue's own paths reach can be held or
/// refused: reading the account's settings while a turn is admitted, and
/// stopping the chat's tasks.
class _Api extends ApiService {
  _Api(String id)
    : super(
        serverConfig: ServerConfig(
          id: id,
          name: id,
          url: 'https://$id.example.test',
        ),
        workerManager: WorkerManager(),
      );

  final List<String> stoppedChats = [];
  final List<String> stoppedTasks = [];
  Object? stopError;

  /// Refusals for one chat's stop only, whatever [stopError] says.
  final Map<String, Object> stopErrorsByChat = {};
  Completer<void>? stopGate;
  Completer<void>? settingsGate;

  /// What the server's task registry lists for the chat. A title or tag task
  /// shows up here after the answer itself is done.
  List<String> chatTaskIds = const [];

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async {
    await settingsGate?.future;
    return const <String, dynamic>{};
  }

  @override
  Future<void> stopTasksByChat(String chatId) async {
    stoppedChats.add(chatId);
    await stopGate?.future;
    final error = stopErrorsByChat[chatId] ?? stopError;
    if (error != null) throw error;
  }

  @override
  Future<void> stopTask(String taskId) async {
    stoppedTasks.add(taskId);
  }

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) async => chatTaskIds;
}

/// The outbox drain and the remap announcements, which belong to the sync
/// engine rather than to the queue.
class _Engine extends SyncEngine {
  final remaps = StreamController<RemapEvent>.broadcast(sync: true);
  Object? drainError;
  int drains = 0;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Stream<RemapEvent> get remapEvents => remaps.stream;

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {
    drains += 1;
    final error = drainError;
    if (error != null) throw error;
  }
}

class _Picked extends SelectedModel {
  _Picked(this.initial);

  final Model initial;

  @override
  Model? build() => initial;

  void use(Model model) => state = model;
}

class _Settings extends AppSettingsNotifier {
  _Settings(this.advanced);

  final bool advanced;

  @override
  AppSettings build() => AppSettings(advancedFeaturesEnabled: advanced);

  void setAdvanced(bool value) =>
      state = state.copyWith(advancedFeaturesEnabled: value);
}

Conversation _conversation(String id, List<ChatMessage> messages) =>
    withChatStorageProvenance(
      Conversation(
        id: id,
        title: id,
        createdAt: DateTime.utc(2026, 10, 6),
        updatedAt: DateTime.utc(2026, 10, 6),
        messages: messages,
      ),
      ChatStorageKind.openWebUi,
    );

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

/// One prompt answered by two models: both answers end the transcript, each
/// with its own server task. [running] names the answers still streaming.
List<ChatMessage> _comparisonTurn({Set<String> running = const {'c0', 'c1'}}) =>
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
            kMessageModelIdxMetadataKey: slot,
            'taskId': 'task-$slot',
          },
        ),
    ];

FileUploadState _file(
  String name, {
  FileUploadStatus status = FileUploadStatus.completed,
}) => FileUploadState(
  file: File('/queue-test/$name'),
  fileName: name,
  fileSize: 1,
  progress: status == FileUploadStatus.completed ? 1 : 0.4,
  status: status,
  fileId: status == FileUploadStatus.completed ? 'id-$name' : null,
  isImage: false,
);

/// An ordinary message sent from the composer, which a Stop leaves free.
final _sendOrdinaryMessage = Provider<Future<void> Function(String)>(
  (ref) =>
      (text) => durableSend(ref, text, null),
);

Future<void> _seedChat(AppDatabase db, String chatId) => db
    .into(db.chats)
    .insert(
      ChatsCompanion.insert(
        id: chatId,
        title: chatId,
        createdAt: 1,
        updatedAt: 1,
        bodySynced: const Value(true),
      ),
    );

/// One signed-in session viewing a chat whose response is still running.
class _Session {
  _Session._(this.container, this.db, this.api, this.engine, this._wires);

  final ProviderContainer container;
  final AppDatabase db;
  final _Api api;
  final _Engine engine;
  final ({
    NotifierProvider<_Holder<ApiService>, ApiService> api,
    NotifierProvider<_Holder<Object>, Object> epoch,
  })
  _wires;

  static const chatId = 'chat-1';

  static Future<_Session> start({
    bool advanced = true,
    bool online = true,
    Model? model,
  }) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedChat(db, chatId);
    final api = _Api('server-a');
    final engine = _Engine();
    final wires = (
      api: NotifierProvider<_Holder<ApiService>, ApiService>(
        () => _Holder<ApiService>(api),
      ),
      epoch: NotifierProvider<_Holder<Object>, Object>(
        () => _Holder<Object>(Object()),
      ),
    );
    final messages = _runningTurn();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        activeConversationProvider.overrideWith(
          () => _SeededActive(_conversation(chatId, messages)),
        ),
        chatMessagesProvider.overrideWith(_Messages.new),
        apiServiceProvider.overrideWith((ref) => ref.watch(wires.api)),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(wires.epoch),
        ),
        selectedModelProvider.overrideWith(
          () => _Picked(model ?? const Model(id: 'model-1', name: 'Model 1')),
        ),
        reviewerModeProvider.overrideWithValue(false),
        // Admission reads the signed-in account's settings from the server.
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'user-1',
            username: 'user',
            email: 'user@example.test',
            role: 'user',
          ),
        ),
        socketServiceProvider.overrideWithValue(null),
        isOnlineProvider.overrideWithValue(online),
        appSettingsProvider.overrideWith(() => _Settings(advanced)),
        webSearchAvailableProvider.overrideWithValue(false),
        imageGenerationAvailableProvider.overrideWithValue(false),
        selectedFilterIdsProvider.overrideWithValue(const <String>[]),
        selectedTerminalIdProvider.overrideWithValue(null),
        syncEngineProvider.overrideWith(() => engine),
        attachedFilesProvider.overrideWith(_Tray.new),
      ],
    );
    addTearDown(container.dispose);
    container.read(chatMessagesProvider.notifier).setMessages(messages);
    // The queue is a long-lived owner; the app reads it from the composer.
    container.listen(chatDraftQueueProvider, (_, _) {});
    return _Session._(container, db, api, engine, wires);
  }

  ChatDraftQueueController get queue =>
      container.read(chatDraftQueueProvider.notifier);

  ChatDraftQueue? get active => container.read(activeChatDraftQueueProvider);

  List<QueuedDraftAttachment> get parked =>
      container.read(queuedDraftAttachmentsProvider);

  List<FileUploadState> get tray => container.read(attachedFilesProvider);

  void attach(Iterable<FileUploadState> files) =>
      (container.read(attachedFilesProvider.notifier) as _Tray).put(
        files.toList(),
      );

  /// The response the user is waiting on ends.
  void finishResponse() =>
      container.read(chatMessagesProvider.notifier).finishStreaming();

  /// The answers whose live transport was released, in release order.
  final List<String> releasedTransports = [];

  /// Shows a comparison turn. Every answer in [running] holds a live transport
  /// that reports here when the notifier lets it go.
  void showComparison({Set<String> running = const {'c0', 'c1'}}) {
    switchTo(chatId, messages: _comparisonTurn(running: running));
    final notifier = container.read(chatMessagesProvider.notifier);
    for (final id in running) {
      notifier.registerSlotTransport(id, [() => releasedTransports.add(id)]);
    }
  }

  /// One answer of the comparison ends on its own `done` signal.
  void finishAnswer(String id) =>
      container.read(chatMessagesProvider.notifier).finishSlotMessage(id);

  bool answerStreaming(String id) => container
      .read(chatMessagesProvider)
      .firstWhere((message) => message.id == id)
      .isStreaming;

  void switchTo(String id, {List<ChatMessage>? messages}) {
    final shown = messages ?? _runningTurn();
    container.read(chatMessagesProvider.notifier).setMessages(shown);
    container
        .read(activeConversationProvider.notifier)
        .set(_conversation(id, shown));
  }

  void signInElsewhere(_Api api) {
    container.read(_wires.api.notifier).use(api);
    container.read(_wires.epoch.notifier).use(Object());
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    check(condition()).isTrue();
  }

  /// Gives anything that was going to happen the chance to.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

  Future<List<MessageRow>> sentUserRows([String chat = chatId]) async =>
      (await db.messagesDao.getForChat(
        chat,
      )).where((row) => row.role == 'user').toList();

  Future<List<OutboxOp>> completions([String chat = chatId]) async =>
      (await db.outboxDao.pendingForChat(
        chat,
      )).where((op) => op.kind == 'requestCompletion').toList();

  List<String> userFileIds(MessageRow row) =>
      ((jsonDecode(row.payload) as Map)['files'] as List)
          .map((file) => (file as Map)['id'] as String)
          .toList();
}

void main() {
  group('queueing a draft', () {
    test('captures the composer and leaves it empty, files still uploading',
        () async {
      final s = await _Session.start();
      final uploading = _file('b.txt', status: FileUploadStatus.uploading);
      s.attach([_file('a.txt'), uploading]);
      s.container
          .read(contextAttachmentsProvider.notifier)
          .addWeb(
            displayName: 'Page',
            content: 'page text',
            url: 'https://example.test/page',
          );

      final draft = s.queue.enqueue('  first  ');

      check(draft).isNotNull();
      check(draft!.text).equals('first');
      check(s.parked.map((held) => held.upload.file.path))
          .deepEquals(['/queue-test/a.txt', '/queue-test/b.txt']);
      check(s.parked.map((held) => held.id))
          .deepEquals(draft.attachmentIds);
      check(draft.contextAttachments.single.type)
          .equals(ChatContextAttachmentType.web);
      check(s.active!.drafts.map((d) => d.id)).deepEquals([draft.id]);
      // The composer is empty, and the in-flight upload is still the exact
      // object its owner reports into, now held by the draft.
      check(s.tray).isEmpty();
      check(s.container.read(contextAttachmentsProvider)).isEmpty();
      check(s.parked.last.upload).identicalTo(uploading);
    });

    test('is refused, and the composer left alone, when no response runs',
        () async {
      final s = await _Session.start();
      s.finishResponse();
      s.attach([_file('a.txt')]);

      check(s.queue.enqueue('late')).isNull();

      check(s.active).isNull();
      check(s.tray.map((f) => f.fileName)).deepEquals(['a.txt']);
    });

    test('is offered only while a response runs on a stored Open WebUI chat, '
        'with Advanced off', () async {
      final s = await _Session.start(advanced: false);
      bool offered() => s.container.read(chatDraftQueueOfferProvider);

      check(offered()).isTrue();

      s.finishResponse();
      check(offered()).isFalse();

      final running = _runningTurn();
      s.container.read(chatMessagesProvider.notifier).setMessages(running);
      check(offered()).isTrue();

      s.container.read(temporaryChatEnabledProvider.notifier).set(true);
      check(offered()).isFalse();
      s.container.read(temporaryChatEnabledProvider.notifier).set(false);
      check(offered()).isTrue();

      (s.container.read(selectedModelProvider.notifier) as _Picked)
          .use(hermesSyntheticModel());
      check(offered()).isFalse();
    });

    test('is hidden from another sign-in on the same chat', () async {
      final s = await _Session.start();
      s.queue.enqueue('mine');
      check(s.active).isNotNull();

      s.signInElsewhere(_Api('server-a'));

      check(s.active).isNull();
      check(s.container.read(chatDraftQueueProvider)).length.equals(1);
    });
  });

  group('draining one frozen batch', () {
    test('combines every draft into one user turn with ordered files, once',
        () async {
      final s = await _Session.start();
      s.attach([_file('a.txt')]);
      s.queue.enqueue('first');
      s.attach([_file('b.txt'), _file('c.txt')]);
      s.queue.enqueue('second');
      s.container
          .read(selectedToolIdsProvider.notifier)
          .set(const ['tool-1']);

      s.finishResponse();
      await s.until(() => s.active == null);
      await s.settle();

      final rows = await s.sentUserRows();
      check(rows).length.equals(1);
      check(rows.single.content).equals('first\n\nsecond');
      check(s.userFileIds(rows.single))
          .deepEquals(['id-a.txt', 'id-b.txt', 'id-c.txt']);
      // One completion operation, and it is for the assistant row of that turn.
      final ops = await s.completions();
      check(ops).length.equals(1);
      final assistant = (await s.db.messagesDao.getForChat(
        _Session.chatId,
      )).singleWhere((row) => row.role == 'assistant');
      check((jsonDecode(ops.single.payload) as Map)['assistantMessageId'])
          .equals(assistant.id);
      check(s.parked).isEmpty();
      check(s.engine.drains).equals(1);
    });

    test('carries each draft\'s context attachments into the one turn',
        () async {
      final s = await _Session.start();
      s.container
          .read(contextAttachmentsProvider.notifier)
          .addWeb(displayName: 'One', content: 'one', url: 'https://one.test');
      s.queue.enqueue('first');
      s.container
          .read(contextAttachmentsProvider.notifier)
          .addWeb(displayName: 'Two', content: 'two', url: 'https://two.test');
      s.queue.enqueue('second');

      s.finishResponse();
      await s.until(() => s.active == null);

      final files = (jsonDecode((await s.sentUserRows()).single.payload)
              as Map)['files']
          as List;
      check(files.map((f) => (f as Map)['name'])).deepEquals(
        ['https://one.test', 'https://two.test'],
      );
    });

    test('waits while any file is uploading, then sends the whole queue',
        () async {
      final s = await _Session.start();
      s.queue.enqueue('text only');
      s.attach([_file('slow.txt', status: FileUploadStatus.uploading)]);
      s.queue.enqueue('with a file');

      s.finishResponse();
      await s.settle();
      check(await s.sentUserRows()).isEmpty();
      check(s.active!.drafts).length.equals(2);

      // The upload finishes: its owner replaces the state it captured.
      s.container
          .read(queuedDraftAttachmentsProvider.notifier)
          .replaceUpload(s.parked.single.upload, _file('slow.txt'));
      await s.until(() => s.active == null);

      final rows = await s.sentUserRows();
      check(rows.single.content).equals('text only\n\nwith a file');
      check(s.userFileIds(rows.single)).deepEquals(['id-slow.txt']);
    });

    test('a failed file holds the whole queue until the user removes it',
        () async {
      final s = await _Session.start();
      s.attach([_file('bad.txt', status: FileUploadStatus.failed)]);
      final broken = s.queue.enqueue('has a bad file')!;
      s.queue.enqueue('fine');

      s.finishResponse();
      await s.settle();
      check(await s.sentUserRows()).isEmpty();
      check(s.active!.drafts).length.equals(2);

      check(s.queue.removeDraftAttachment(broken.id, broken.attachmentIds.single))
          .isTrue();
      await s.until(() => s.active == null);

      check((await s.sentUserRows()).single.content)
          .equals('has a bad file\n\nfine');
      check(s.parked).isEmpty();
    });

    test('a draft queued while the batch is admitted waits for the next turn',
        () async {
      final s = await _Session.start();
      s.api.settingsGate = Completer<void>();
      s.queue.enqueue('frozen');

      s.finishResponse();
      await s.until(() => s.active?.phase == ChatDraftQueuePhase.admitting);
      // Admission has put its optimistic turn on screen, so a response is
      // running again and the user can queue behind it.
      check(s.queue.enqueue('later')).isNotNull();
      s.api.settingsGate!.complete();
      await s.until(
        () => s.active?.phase == ChatDraftQueuePhase.idle &&
            s.active!.drafts.length == 1,
      );
      await s.settle();

      final rows = await s.sentUserRows();
      check(rows.single.content).equals('frozen');
      check(s.active!.drafts.single.text).equals('later');
      check(await s.completions()).length.equals(1);
    });

    test('a send refused before it commits keeps every draft and shows nothing',
        () async {
      final s = await _Session.start();
      await s.db.customStatement(
        "CREATE TRIGGER refuse_outbox BEFORE INSERT ON outbox_ops "
        "BEGIN SELECT RAISE(ABORT, 'outbox unavailable'); END",
      );
      s.queue.enqueue('first');
      s.queue.enqueue('second');

      s.finishResponse();
      await s.until(() => s.active?.admissionFailed == true);

      check(s.active!.drafts.map((d) => d.text))
          .deepEquals(['first', 'second']);
      check(s.active!.phase).equals(ChatDraftQueuePhase.idle);
      // The transaction rolled back: no row, no operation, and no optimistic
      // turn left on screen for the retry to duplicate.
      check(await s.sentUserRows()).isEmpty();
      check(await s.completions()).isEmpty();
      check(s.container.read(chatMessagesProvider).map((m) => m.id))
          .deepEquals(['u0', 'a0']);
      // Nothing sends it again by itself.
      await s.settle();
      check(await s.sentUserRows()).isEmpty();

      await s.db.customStatement('DROP TRIGGER refuse_outbox');
      s.container
          .read(chatMessagesProvider.notifier)
          .setMessages(_runningTurn());
      s.finishResponse();
      s.queue.retryAdmission();
      await s.until(() => s.active == null);

      check((await s.sentUserRows()).single.content).equals('first\n\nsecond');
    });

    test('a drain that fails after the commit never puts the drafts back',
        () async {
      final s = await _Session.start();
      s.engine.drainError = StateError('drain failed');
      s.queue.enqueue('first');
      s.queue.enqueue('second');

      s.finishResponse();
      await s.until(() => s.engine.drains == 1);
      await s.until(() => s.active == null);
      await s.settle();

      check(s.container.read(chatDraftQueueProvider)).isEmpty();
      check((await s.sentUserRows()).single.content).equals('first\n\nsecond');
      check(await s.completions()).length.equals(1);
      check(s.engine.drains).equals(1);
      // The admitted turn stays on screen; it is not treated as one that was
      // refused and handed back to the queue.
      final shown = s.container.read(chatMessagesProvider);
      check(shown.map((m) => m.role))
          .deepEquals(['user', 'assistant', 'user', 'assistant']);
      check(shown[2].content).equals('first\n\nsecond');
    });

    test('is admitted for the outbox while offline, which replays it',
        () async {
      final s = await _Session.start(online: false);
      s.queue.enqueue('first');
      s.queue.enqueue('second');

      s.finishResponse();
      await s.until(() => s.active == null);

      check((await s.sentUserRows()).single.content).equals('first\n\nsecond');
      check(await s.completions()).length.equals(1);
    });

    test('several signals for the same finished response admit it once',
        () async {
      final s = await _Session.start();
      s.queue.enqueue('first');
      s.queue.enqueue('second');

      final shown = s.container.read(activeConversationProvider)!;
      s.finishResponse();
      s.container.read(isLoadingConversationProvider.notifier).set(true);
      s.container.read(isLoadingConversationProvider.notifier).set(false);
      s.container.read(activeConversationProvider.notifier).set(shown);
      s.container
          .read(queuedDraftAttachmentsProvider.notifier)
          .adopt(const []);
      s.container.read(activeConversationProvider.notifier).set(shown);

      await s.until(() => s.active == null);
      await s.settle();

      check(await s.sentUserRows()).length.equals(1);
      check(await s.completions()).length.equals(1);
    });
  });

  group('who may drain', () {
    test('another account or a chat that is not on screen never drains it',
        () async {
      final s = await _Session.start();
      s.queue.enqueue('mine');
      final accountA = s.container.read(apiServiceProvider)!;
      final epochA = s.container.read(openWebUiAuthSessionEpochProvider);

      // Someone else signs in; the response ends while they are there.
      s.signInElsewhere(_Api('server-b'));
      s.finishResponse();
      await s.settle();
      check(await s.sentUserRows()).isEmpty();

      // Back in the same session, but looking at another chat.
      s.container.read(s._wires.api.notifier).use(accountA);
      s.container.read(s._wires.epoch.notifier).use(epochA);
      await _seedChat(s.db, 'chat-2');
      s.switchTo('chat-2', messages: const []);
      await s.settle();
      check(await s.sentUserRows()).isEmpty();
      check(await s.sentUserRows('chat-2')).isEmpty();
      check(s.container.read(chatDraftQueueProvider)).length.equals(1);

      // Reopening the original conversation under the same session resumes.
      s.switchTo(_Session.chatId, messages: const []);
      await s.until(() => s.active == null);

      check((await s.sentUserRows()).single.content).equals('mine');
      check(await s.sentUserRows('chat-2')).isEmpty();
    });

    test('a queue follows its chat through a local-to-server remap, only its own',
        () async {
      final s = await _Session.start();
      await _seedChat(s.db, 'local:a');
      await _seedChat(s.db, 'local:b');
      await _seedChat(s.db, 'server-a');
      s.switchTo('local:a');
      s.queue.enqueue('for a');
      s.switchTo('local:b');
      s.queue.enqueue('for b');
      s.switchTo('local:a');

      // A chat still being created sends inline, with nothing to certify an
      // admission, so its drafts wait for the server id however long that takes.
      s.finishResponse();
      await s.settle();
      check(await s.sentUserRows('local:a')).isEmpty();
      check(s.active!.drafts).length.equals(1);

      s.engine.remaps.add(
        const RemapEvent(
          fromId: 'local:a',
          toId: 'server-a',
          entityKind: 'chat',
        ),
      );
      s.container
          .read(activeConversationProvider.notifier)
          .remapIdInPlace(fromId: 'local:a', toId: 'server-a');
      check(
        s.container.read(chatDraftQueueProvider).map((q) => q.chatId).toList(),
      ).deepEquals(['server-a', 'local:b']);

      await s.until(() => s.active == null);

      check((await s.sentUserRows('server-a')).single.content)
          .equals('for a');
      check(await s.sentUserRows('local:b')).isEmpty();
      check(s.container.read(chatDraftQueueProvider)).length.equals(1);
    });

    test('a remap announced under another sign-in does not move the queue',
        () async {
      final s = await _Session.start();
      await _seedChat(s.db, 'local:a');
      s.switchTo('local:a');
      s.queue.enqueue('for a');

      s.signInElsewhere(_Api('server-b'));
      s.engine.remaps.add(
        const RemapEvent(
          fromId: 'local:a',
          toId: 'server-a',
          entityKind: 'chat',
        ),
      );

      check(s.container.read(chatDraftQueueProvider).single.chatId)
          .equals('local:a');
    });

    test('a file at the same path under another sign-in is not the old '
        'queue\'s file, and sending leaves the old queue\'s alone', () async {
      final s = await _Session.start();
      s.attach([_file('same.csv')]);
      s.queue.enqueue('old account');

      s.signInElsewhere(_Api('server-b'));
      s.attach([
        FileUploadState(
          file: File('/queue-test/same.csv'),
          fileName: 'same.csv',
          fileSize: 1,
          progress: 1,
          status: FileUploadStatus.completed,
          fileId: 'new-account-file',
          isImage: false,
        ),
      ]);
      s.queue.enqueue('new account');
      s.finishResponse();
      await s.until(() => s.active == null);

      final rows = await s.sentUserRows();
      check(rows.single.content).equals('new account');
      check(s.userFileIds(rows.single)).deepEquals(['new-account-file']);
      // The old account's draft and its file are still waiting for it.
      check(s.container.read(chatDraftQueueProvider).single.drafts.single.text)
          .equals('old account');
      check(s.parked).length.equals(1);
    });
  });

  group('managing queued drafts', () {
    test('edit and remove act on the draft that was chosen', () async {
      final s = await _Session.start();
      // Both drafts hold a file at the same path.
      s.attach([_file('a.txt')]);
      final first = s.queue.enqueue('first')!;
      s.attach([_file('a.txt')]);
      final second = s.queue.enqueue('second')!;

      check(s.queue.editDraft(second.id, ' second, edited ')).isTrue();
      check(s.queue.editDraft(first.id, '   ')).isFalse();
      check(s.active!.drafts.map((d) => d.text))
          .deepEquals(['first', 'second, edited']);

      check(s.queue.removeDraft(first.id)).isTrue();
      check(s.active!.drafts.map((d) => d.id)).deepEquals([second.id]);
      // The removed draft took only its own file with it.
      check(s.parked).length.equals(1);

      check(s.queue.removeDraft(second.id)).isTrue();
      check(s.parked).isEmpty();
    });

    test('a removed draft can be put back where it was, with its files',
        () async {
      final s = await _Session.start();
      final first = s.queue.enqueue('first')!;
      s.attach([_file('a.txt')]);
      final second = s.queue.enqueue('second')!;
      s.queue.enqueue('third');
      final before = s.active!;
      final files = s.parked
          .where((held) => second.attachmentIds.contains(held.id))
          .toList();

      check(s.queue.removeDraft(second.id)).isTrue();
      check(s.parked).isEmpty();
      check(
        s.queue.restoreDraft(before, second, 1, attachments: files),
      ).isTrue();

      check(s.active!.drafts.map((d) => d.text))
          .deepEquals(['first', 'second', 'third']);
      check(s.parked.map((held) => held.id)).deepEquals(second.attachmentIds);
      check(s.parked.single.queueId).equals(s.active!.id);
      // Putting it back twice does not queue it twice.
      check(
        s.queue.restoreDraft(before, second, 1, attachments: files),
      ).isFalse();
      check(s.active!.drafts.map((d) => d.id).first).equals(first.id);
    });

    test('drafts removed one after another go back between the neighbours '
        'they were removed from, in whatever order they are put back',
        () async {
      for (final undo in const [
        ['a', 'b'],
        ['b', 'a'],
      ]) {
        final s = await _Session.start();
        final drafts = {
          for (final text in ['a', 'b', 'c']) text: s.queue.enqueue(text)!,
        };
        final seen = [for (final d in s.active!.drafts) d.id];
        final froms = <String, ChatDraftQueue>{};
        for (final text in ['a', 'b']) {
          froms[text] = s.active!;
          // The index each had when it left: both were first by then.
          check(s.active!.drafts.first.id).equals(drafts[text]!.id);
          check(s.queue.removeDraft(drafts[text]!.id)).isTrue();
        }

        for (final text in undo) {
          check(
            s.queue.restoreDraft(
              froms[text]!,
              drafts[text]!,
              0,
              seenOrder: seen,
            ),
          ).isTrue();
        }
        check(
          s.active!.drafts.map((d) => d.text),
        ).deepEquals(['a', 'b', 'c']);
      }
    });

    test('the place to put a draft back follows its nearest neighbour still '
        'queued', () {
      int place(List<String> ids, String id, {int fallback = 0}) =>
          chatDraftRestoreIndex(
            ids,
            seenOrder: const ['a', 'b', 'c', 'd'],
            draftId: id,
            fallback: fallback,
          );
      check(place(['c', 'd'], 'a')).equals(0);
      check(place(['a', 'c', 'd'], 'b')).equals(1);
      // b's preceding neighbour is gone, so it goes before c.
      check(place(['c', 'd'], 'b')).equals(0);
      check(place(['a', 'x', 'c'], 'b')).equals(1);
      check(place(['x', 'a'], 'd')).equals(2);
      // No neighbour left: the index it had.
      check(place(['x', 'y'], 'b', fallback: 1)).equals(1);
      check(place(['x'], 'b', fallback: 5)).equals(1);
      check(
        chatDraftRestoreIndex(
          ['x', 'y'],
          seenOrder: const [],
          draftId: 'b',
          fallback: 1,
        ),
      ).equals(1);
    });

    test('the last removed draft comes back in a queue of its own', () async {
      final s = await _Session.start();
      final only = s.queue.enqueue('only')!;
      final before = s.active!;

      check(s.queue.removeDraft(only.id)).isTrue();
      check(s.active).isNull();
      check(s.queue.restoreDraft(before, only, 0)).isTrue();

      check(s.active!.id).equals(before.id);
      check(s.active!.drafts.single.text).equals('only');
    });

    test('a draft whose file had not finished uploading is not put back',
        () async {
      final s = await _Session.start();
      s.attach([_file('a.txt', status: FileUploadStatus.uploading)]);
      final draft = s.queue.enqueue('with upload')!;
      final before = s.active!;
      final files = List.of(s.parked);

      check(s.queue.removeDraft(draft.id)).isTrue();
      check(
        s.queue.restoreDraft(before, draft, 0, attachments: files),
      ).isFalse();
      check(s.active).isNull();
      check(s.parked).isEmpty();
    });

    test('a draft is never put back under another chat or account', () async {
      final s = await _Session.start();
      final draft = s.queue.enqueue('mine')!;
      final before = s.active!;
      check(s.queue.removeDraft(draft.id)).isTrue();

      s.signInElsewhere(_Api('server-b'));
      check(s.queue.restoreDraft(before, draft, 0)).isFalse();
      check(s.container.read(chatDraftQueueProvider)).isEmpty();
    });

    test('a draft being sent can be neither edited nor removed', () async {
      final s = await _Session.start();
      s.api.settingsGate = Completer<void>();
      final draft = s.queue.enqueue('frozen')!;

      s.finishResponse();
      await s.until(() => s.active?.phase == ChatDraftQueuePhase.admitting);

      check(s.queue.editDraft(draft.id, 'changed')).isFalse();
      check(s.queue.removeDraft(draft.id)).isFalse();
      s.api.settingsGate!.complete();
      await s.until(() => s.active == null);

      check((await s.sentUserRows()).single.content).equals('frozen');
    });
  });

  group('a draft the queue refused', () {
    /// A queue of two drafts, the first with a file, whose admission the
    /// database refused; the cause is gone by the time this returns.
    Future<(_Session, QueuedChatDraft)> refused() async {
      final s = await _Session.start();
      await s.db.customStatement(
        "CREATE TRIGGER refuse_outbox BEFORE INSERT ON outbox_ops "
        "BEGIN SELECT RAISE(ABORT, 'outbox unavailable'); END",
      );
      s.attach([_file('a.csv')]);
      final first = s.queue.enqueue('first')!;
      s.queue.enqueue('second');
      s.finishResponse();
      await s.until(() => s.active?.admissionFailed == true);
      await s.db.customStatement('DROP TRIGGER refuse_outbox');
      return (s, first);
    }

    test('is sent again after an edit, with its text and files kept',
        () async {
      final (s, first) = await refused();
      check(await s.sentUserRows()).isEmpty();

      check(s.queue.editDraft(first.id, 'first, edited')).isTrue();
      await s.until(() => s.active == null);
      await s.settle();

      final rows = await s.sentUserRows();
      check(rows.single.content).equals('first, edited\n\nsecond');
      check(s.userFileIds(rows.single)).deepEquals(['id-a.csv']);
      check(await s.completions()).length.equals(1);
    });

    test('is sent again, without the removed draft, after a removal',
        () async {
      final (s, first) = await refused();
      // The second draft holds no file, so removing it releases nothing.
      final second = s.active!.drafts.last;
      check(second.attachmentIds).isEmpty();

      check(s.queue.removeDraft(second.id)).isTrue();
      await s.until(() => s.active == null);
      await s.settle();

      final rows = await s.sentUserRows();
      check(rows.single.content).equals(first.text);
      check(s.userFileIds(rows.single)).deepEquals(['id-a.csv']);
      check(s.parked).isEmpty();
      check(await s.completions()).length.equals(1);
    });

    test('is sent without a file the queue no longer holds once it is '
        'removed', () async {
      final s = await _Session.start();
      s.attach([_file('gone.csv')]);
      final first = s.queue.enqueue('first')!;
      s.queue.enqueue('second');
      // The file's upload is dropped elsewhere, so the draft can never be ready.
      s.container
          .read(queuedDraftAttachmentsProvider.notifier)
          .release(s.active!.id, first.attachmentIds);
      s.finishResponse();
      await s.settle();
      check(await s.sentUserRows()).isEmpty();

      check(
        s.queue.removeDraftAttachment(first.id, first.attachmentIds.single),
      ).isTrue();
      await s.until(() => s.active == null);
      await s.settle();

      final rows = await s.sentUserRows();
      check(rows.single.content).equals('first\n\nsecond');
      check(s.userFileIds(rows.single)).isEmpty();
    });

    test('an edit does not send over a Stop the server still refuses',
        () async {
      final s = await _Session.start();
      s.api.stopError = StateError('stop refused');
      final first = s.queue.enqueue('first')!;
      check(await s.queue.sendNow(first.id))
          .equals(ChatDraftSendNowOutcome.stopFailed);
      check(s.active!.admissionFailed).isTrue();

      check(s.queue.editDraft(first.id, 'first, edited')).isTrue();
      await s.until(() => s.api.stoppedChats.length == 2);
      await s.settle();

      // The edit looked at the queue again, asked the server again, and was
      // refused again: nothing was sent and the retry is offered once more.
      check(await s.sentUserRows()).isEmpty();
      check(s.active!.admissionFailed).isTrue();
      check(s.active!.drafts.single.text).equals('first, edited');

      s.api.stopError = null;
      s.queue.retryAdmission();
      await s.until(() => s.active == null);
      await s.settle();
      check((await s.sentUserRows()).single.content).equals('first, edited');
      check(await s.completions()).length.equals(1);
    });
  });

  group('send now', () {
    test('sending one draft leaves the file a later draft holds at that path',
        () async {
      final s = await _Session.start();
      s.attach([_file('same.csv')]);
      final first = s.queue.enqueue('first')!;
      s.attach([_file('same.csv')]);
      s.queue.enqueue('second');

      check(await s.queue.sendNow(first.id))
          .equals(ChatDraftSendNowOutcome.admitted);
      check(s.parked).length.equals(1);

      s.finishResponse();
      await s.until(() => s.active == null);

      final rows = await s.sentUserRows();
      check(rows.map((row) => row.content)).deepEquals(['first', 'second']);
      check(s.userFileIds(rows.first)).deepEquals(['id-same.csv']);
      check(s.userFileIds(rows.last)).deepEquals(['id-same.csv']);
    });

    test('stops the response, waits for the server, and sends only that draft',
        () async {
      final s = await _Session.start();
      s.api.stopGate = Completer<void>();
      final first = s.queue.enqueue('first')!;
      s.queue.enqueue('second');

      final outcome = s.queue.sendNow(first.id);
      await s.until(() => s.api.stoppedChats.isNotEmpty);
      // The server has not answered yet: nothing is admitted, and stopping the
      // response did not release the rest of the queue as a batch.
      await s.settle();
      check(await s.sentUserRows()).isEmpty();
      check(s.active!.phase).equals(ChatDraftQueuePhase.stopping);

      s.api.stopGate!.complete();
      check(await outcome).equals(ChatDraftSendNowOutcome.admitted);

      check(s.api.stoppedChats).deepEquals([_Session.chatId]);
      check((await s.sentUserRows()).single.content).equals('first');
      check(s.active!.drafts.map((d) => d.text)).deepEquals(['second']);
      check(await s.completions()).length.equals(1);
    });

    test('sends nothing when the server refuses the stop', () async {
      final s = await _Session.start();
      s.api.stopError = StateError('stop refused');
      final first = s.queue.enqueue('first')!;

      final outcome = await s.queue.sendNow(first.id);

      check(outcome).equals(ChatDraftSendNowOutcome.stopFailed);
      // The response is already off the screen, yet the queue does not send the
      // draft behind the server's back: it waits for the user to retry.
      await s.settle();
      check(await s.sentUserRows()).isEmpty();
      check(s.active!.drafts.map((d) => d.id)).deepEquals([first.id]);
      check(s.active!.phase).equals(ChatDraftQueuePhase.idle);
      check(s.active!.admissionFailed).isTrue();
    });

    test('sends nothing when the chat changes while the response stops',
        () async {
      final s = await _Session.start();
      s.api.stopGate = Completer<void>();
      final first = s.queue.enqueue('first')!;
      await _seedChat(s.db, 'chat-2');

      final outcome = s.queue.sendNow(first.id);
      await s.until(() => s.api.stoppedChats.isNotEmpty);
      s.switchTo('chat-2', messages: const []);
      s.api.stopGate!.complete();

      check(await outcome).equals(ChatDraftSendNowOutcome.changed);
      check(await s.sentUserRows()).isEmpty();
      check(await s.sentUserRows('chat-2')).isEmpty();
      check(s.container.read(chatDraftQueueProvider).single.drafts)
          .length
          .equals(1);
    });

    test('the awaitable stop leaves a Hermes or Direct response alone',
        () async {
      final s = await _Session.start();
      final stop = Provider<Future<bool> Function()>(
        (ref) => () => stopOpenWebUiMainResponse(ref),
      );
      for (final transport in [kHermesTransport, kDirectTransport]) {
        final running = _runningTurn();
        running[1] = running[1].copyWith(
          metadata: <String, dynamic>{'transport': transport},
        );
        s.container.read(chatMessagesProvider.notifier).setMessages(running);

        check(await s.container.read(stop)()).isFalse();

        check(s.container.read(chatMessagesProvider).last.isStreaming)
            .isTrue();
      }
      check(s.api.stoppedChats).isEmpty();
    });

    test('refuses a draft whose file is still uploading', () async {
      final s = await _Session.start();
      s.attach([_file('slow.txt', status: FileUploadStatus.uploading)]);
      final draft = s.queue.enqueue('with a file')!;

      check(await s.queue.sendNow(draft.id))
          .equals(ChatDraftSendNowOutcome.blockedByUpload);
      check(s.api.stoppedChats).isEmpty();
    });
  });

  group('a Stop the server has not accepted', () {
    /// The chat the Stop was asked on becomes its server chat, as the sync
    /// engine announces it and the screen then shows it.
    void remapStoppedChat(_Session s) {
      s.engine.remaps.add(
        const RemapEvent(
          fromId: 'local:a',
          toId: 'server-a',
          entityKind: 'chat',
        ),
      );
      s.container
          .read(activeConversationProvider.notifier)
          .remapIdInPlace(fromId: 'local:a', toId: 'server-a');
    }

    test('follows its chat through a remap and is asked again for the server '
        'chat before anything is sent', () async {
      final s = await _Session.start();
      await _seedChat(s.db, 'local:a');
      await _seedChat(s.db, 'server-a');
      s.switchTo('local:a');
      s.api.stopGate = Completer<void>();
      addTearDown(() {
        if (!s.api.stopGate!.isCompleted) s.api.stopGate!.complete();
      });
      s.queue.enqueue('after the stopped turn');
      s.container.read(stopGenerationProvider)();
      await s.until(() => s.api.stoppedChats.isNotEmpty);

      remapStoppedChat(s);
      await s.settle();

      // The server has not answered the Stop, so the chat's new id is not
      // sent to either.
      check(await s.sentUserRows('server-a')).isEmpty();
      check(await s.completions('server-a')).isEmpty();
      check(s.active!.drafts.single.text).equals('after the stopped turn');

      s.api.stopGate!.complete();
      await s.until(() => s.active == null);
      await s.settle();

      // What the server accepted was the Stop for the old id, so the server's
      // chat is asked for itself, once, and the turn goes out once.
      check(s.api.stoppedChats).deepEquals(['local:a', 'server-a']);
      check((await s.sentUserRows('server-a')).single.content)
          .equals('after the stopped turn');
      check(await s.completions('server-a')).length.equals(1);
      check(await s.sentUserRows('local:a')).isEmpty();
    });

    test('an answer for the old id does not release a queue that nothing is '
        'sending yet', () async {
      final s = await _Session.start();
      await _seedChat(s.db, 'local:a');
      await _seedChat(s.db, 'server-a');
      s.switchTo('local:a');
      s.api.stopGate = Completer<void>();
      addTearDown(() {
        if (!s.api.stopGate!.isCompleted) s.api.stopGate!.complete();
      });
      // The draft's file is still uploading, so nothing drains the queue.
      s.attach([_file('slow.txt', status: FileUploadStatus.uploading)]);
      s.queue.enqueue('with a file');
      s.container.read(stopGenerationProvider)();
      await s.until(() => s.api.stoppedChats.isNotEmpty);

      remapStoppedChat(s);
      s.api.stopGate!.complete();
      // Nobody is waiting on the Stop, yet it is asked again for the server
      // chat rather than counted as done.
      await s.until(() => s.api.stoppedChats.length == 2);
      check(s.api.stoppedChats).deepEquals(['local:a', 'server-a']);

      s.container
          .read(queuedDraftAttachmentsProvider.notifier)
          .replaceUpload(s.parked.single.upload, _file('slow.txt'));
      await s.until(() => s.active == null);
      await s.settle();

      check(s.api.stoppedChats).deepEquals(['local:a', 'server-a']);
      check((await s.sentUserRows('server-a')).single.content)
          .equals('with a file');
      check(await s.completions('server-a')).length.equals(1);
    });

    test('a Stop refused before a remap is retried for the server chat',
        () async {
      final s = await _Session.start();
      await _seedChat(s.db, 'local:a');
      await _seedChat(s.db, 'server-a');
      s.switchTo('local:a');
      s.api.stopError = StateError('stop refused');
      s.queue.enqueue('after the stopped turn');
      s.container.read(stopGenerationProvider)();
      await s.until(() => s.api.stoppedChats.isNotEmpty);

      remapStoppedChat(s);
      await s.until(() => s.active?.admissionFailed == true);
      await s.settle();
      check(s.api.stoppedChats).deepEquals(['local:a', 'server-a']);
      check(await s.sentUserRows('server-a')).isEmpty();

      s.api.stopError = null;
      s.queue.retryAdmission();
      await s.until(() => s.active == null);
      await s.settle();

      check(s.api.stoppedChats)
          .deepEquals(['local:a', 'server-a', 'server-a']);
      check((await s.sentUserRows('server-a')).single.content)
          .equals('after the stopped turn');
      check(await s.completions('server-a')).length.equals(1);
    });

    test('a remap announced under another sign-in leaves the Stop where it '
        'was', () async {
      final s = await _Session.start();
      await _seedChat(s.db, 'local:a');
      await _seedChat(s.db, 'server-a');
      s.switchTo('local:a');
      s.api.stopGate = Completer<void>();
      addTearDown(() {
        if (!s.api.stopGate!.isCompleted) s.api.stopGate!.complete();
      });
      s.queue.enqueue('mine');
      s.container.read(stopGenerationProvider)();
      await s.until(() => s.api.stoppedChats.isNotEmpty);
      final accountA = s.container.read(apiServiceProvider)!;
      final epochA = s.container.read(openWebUiAuthSessionEpochProvider);

      s.signInElsewhere(_Api('server-b'));
      s.engine.remaps.add(
        const RemapEvent(
          fromId: 'local:a',
          toId: 'server-a',
          entityKind: 'chat',
        ),
      );
      s.container.read(s._wires.api.notifier).use(accountA);
      s.container.read(s._wires.epoch.notifier).use(epochA);
      await s.settle();

      // The queue did not move, and nothing was sent for either id.
      check(s.active!.chatId).equals('local:a');
      check(await s.sentUserRows('server-a')).isEmpty();
      check(await s.sentUserRows('local:a')).isEmpty();

      // The server answers while the chat still has only its old id: the
      // foreign remap did not ask it about the server chat.
      s.api.stopGate!.complete();
      await s.settle();
      check(s.api.stoppedChats).deepEquals(['local:a']);

      // Under its own account the remap moves the queue, and it goes out once.
      remapStoppedChat(s);
      await s.until(() => s.active == null);
      await s.settle();
      check(s.active).isNull();
      check((await s.sentUserRows('server-a')).single.content).equals('mine');
      check(await s.completions('server-a')).length.equals(1);
    });

    test('an answer for the old id and a refusal for the server chat sends '
        'nothing until the server chat is accepted', () async {
      final s = await _Session.start();
      await _seedChat(s.db, 'local:a');
      await _seedChat(s.db, 'server-a');
      s.switchTo('local:a');
      s.api.stopGate = Completer<void>();
      addTearDown(() {
        if (!s.api.stopGate!.isCompleted) s.api.stopGate!.complete();
      });
      s.queue.enqueue('after the stopped turn');
      s.container.read(stopGenerationProvider)();
      await s.until(() => s.api.stoppedChats.isNotEmpty);

      remapStoppedChat(s);
      s.api.stopErrorsByChat['server-a'] = StateError('stop refused');
      s.api.stopGate!.complete();
      await s.until(() => s.active?.admissionFailed == true);
      await s.settle();

      check(await s.sentUserRows('server-a')).isEmpty();
      check(await s.completions('server-a')).isEmpty();
      check(s.active!.drafts.single.text).equals('after the stopped turn');

      s.api.stopErrorsByChat.clear();
      s.queue.retryAdmission();
      await s.until(() => s.active == null);
      await s.settle();

      check((await s.sentUserRows('server-a')).single.content)
          .equals('after the stopped turn');
      check(await s.completions('server-a')).length.equals(1);
    });

    test('holds the queue until the server accepts it, then sends once',
        () async {
      final s = await _Session.start();
      s.api.stopGate = Completer<void>();
      s.queue.enqueue('first');
      s.queue.enqueue('second');

      s.container.read(stopGenerationProvider)();
      await s.until(() => s.api.stoppedChats.isNotEmpty);
      // The answer is off the screen, yet the server has not answered the stop.
      check(s.container.read(chatMainAnswerActiveProvider)).isFalse();
      await s.settle();
      check(await s.sentUserRows()).isEmpty();
      check(s.active!.drafts).length.equals(2);

      s.api.stopGate!.complete();
      await s.until(() => s.active == null);
      await s.settle();

      check((await s.sentUserRows()).single.content).equals('first\n\nsecond');
      check(await s.completions()).length.equals(1);
      check(s.api.stoppedChats).deepEquals([_Session.chatId]);
    });

    for (final selected in const [false, true]) {
      test('a reply sent while ${selected ? 'send now' : 'the compact Stop'} '
          'waits on the server keeps the queue behind it until it finishes',
          () async {
        final s = await _Session.start();
        s.api.stopGate = Completer<void>();
        addTearDown(() {
          if (!s.api.stopGate!.isCompleted) s.api.stopGate!.complete();
        });
        s.attach([_file('kept.csv')]);
        final first = s.queue.enqueue('queued first')!;
        final second = s.queue.enqueue('queued second')!;
        final sendNow = selected ? s.queue.sendNow(first.id) : null;
        if (!selected) s.container.read(stopGenerationProvider)();
        await s.until(
          () =>
              s.api.stoppedChats.isNotEmpty &&
              s.active?.phase ==
                  (selected
                      ? ChatDraftQueuePhase.stopping
                      : ChatDraftQueuePhase.admitting),
        );
        // The Stop settled the answer on screen, so the composer is free and
        // the user sends another message while the server is still answering.
        check(s.container.read(chatMainAnswerActiveProvider)).isFalse();
        await s.container.read(_sendOrdinaryMessage)('newer reply');
        final live = s.container.read(chatMessagesProvider).last;
        s.container
            .read(chatMessagesProvider.notifier)
            .updateMessageById(
              live.id,
              (message) => message.copyWith(content: 'newer partial'),
            );
        check(s.container.read(chatMainAnswerActiveProvider)).isTrue();

        s.api.stopGate!.complete();
        if (sendNow != null) {
          check(await sendNow).equals(ChatDraftSendNowOutcome.changed);
        }
        await s.settle();

        // The newer answer is still the one running: nothing was sent over it,
        // and the drafts wait whole, editable, and without a Retry.
        check((await s.sentUserRows()).map((row) => row.content))
            .deepEquals(['newer reply']);
        check(await s.completions()).length.equals(1);
        final shown = s.container.read(chatMessagesProvider).last;
        check(shown.id).equals(live.id);
        check(shown.content).equals('newer partial');
        check(shown.isStreaming).isTrue();
        check(s.active!.drafts.map((d) => d.id))
            .deepEquals([first.id, second.id]);
        check(s.active!.phase).equals(ChatDraftQueuePhase.idle);
        check(s.active!.frozenDraftIds).isEmpty();
        check(s.active!.admissionFailed).isFalse();
        check(s.parked).length.equals(1);

        s.finishResponse();
        await s.until(() => s.active == null);
        await s.settle();

        final rows = await s.sentUserRows();
        check(rows.map((row) => row.content))
            .deepEquals(['newer reply', 'queued first\n\nqueued second']);
        check(s.userFileIds(rows.last)).deepEquals(['id-kept.csv']);
        check(s.parked).isEmpty();
        check(await s.completions()).length.equals(2);
        check(s.api.stoppedChats).deepEquals([_Session.chatId]);
      });
    }

    test('a refused Stop keeps the drafts until the user retries, and the '
        'retry asks the server again', () async {
      final s = await _Session.start();
      s.api.stopError = StateError('stop refused');
      s.queue.enqueue('first');
      s.queue.enqueue('second');

      s.container.read(stopGenerationProvider)();
      await s.until(() => s.active?.admissionFailed == true);
      await s.settle();

      check(await s.sentUserRows()).isEmpty();
      check(s.active!.phase).equals(ChatDraftQueuePhase.idle);
      check(s.active!.drafts).length.equals(2);

      s.api.stopError = null;
      s.queue.retryAdmission();
      await s.until(() => s.active == null);
      await s.settle();

      check(s.api.stoppedChats).deepEquals([_Session.chatId, _Session.chatId]);
      check((await s.sentUserRows()).single.content).equals('first\n\nsecond');
      check(await s.completions()).length.equals(1);
    });

    test('send now retried after a refusal asks the server again instead of '
        'finding nothing to stop', () async {
      final s = await _Session.start();
      s.api.stopError = StateError('stop refused');
      final first = s.queue.enqueue('first')!;
      final second = s.queue.enqueue('second')!;

      check(await s.queue.sendNow(first.id))
          .equals(ChatDraftSendNowOutcome.stopFailed);
      // The answer is settled on screen now, but the server never accepted.
      check(s.container.read(chatMainAnswerActiveProvider)).isFalse();
      check(await s.queue.sendNow(first.id))
          .equals(ChatDraftSendNowOutcome.stopFailed);
      check(s.api.stoppedChats).length.equals(2);
      check(await s.sentUserRows()).isEmpty();

      s.api.stopError = null;
      check(await s.queue.sendNow(first.id))
          .equals(ChatDraftSendNowOutcome.admitted);

      check(s.api.stoppedChats).length.equals(3);
      check((await s.sentUserRows()).single.content).equals('first');
      check(await s.completions()).length.equals(1);
      check(s.active!.drafts.map((d) => d.id)).deepEquals([second.id]);
    });

    test('never holds another chat or another sign-in, and still holds its '
        'own', () async {
      final s = await _Session.start();
      s.api.stopGate = Completer<void>();
      s.queue.enqueue('mine');
      s.container.read(stopGenerationProvider)();
      await s.until(() => s.api.stoppedChats.isNotEmpty);
      final accountA = s.container.read(apiServiceProvider)!;
      final epochA = s.container.read(openWebUiAuthSessionEpochProvider);

      // Another chat of the same account is not waiting on this stop.
      await _seedChat(s.db, 'chat-2');
      s.switchTo('chat-2');
      s.queue.enqueue('elsewhere');
      s.finishResponse();
      await s.until(() => s.active == null);
      await s.settle();
      check((await s.sentUserRows('chat-2')).single.content)
          .equals('elsewhere');
      check(await s.sentUserRows()).isEmpty();

      // Nor is another sign-in viewing this chat.
      s.signInElsewhere(_Api('server-b'));
      s.switchTo(_Session.chatId);
      s.queue.enqueue('theirs');
      s.finishResponse();
      await s.until(() => s.active == null);
      await s.settle();
      check((await s.sentUserRows()).single.content).equals('theirs');

      // Back under the account that stopped it, the draft still waits for it.
      s.container.read(s._wires.api.notifier).use(accountA);
      s.container.read(s._wires.epoch.notifier).use(epochA);
      s.switchTo(_Session.chatId, messages: _comparisonTurn(running: const {}));
      await s.settle();
      check((await s.sentUserRows()).map((row) => row.content))
          .deepEquals(['theirs']);
      check(s.active!.drafts.map((d) => d.text)).deepEquals(['mine']);

      s.api.stopGate!.complete();
      await s.until(() => s.active == null);
      await s.settle();
      check((await s.sentUserRows()).map((row) => row.content))
          .deepEquals(['theirs', 'mine']);
    });
  });

  group('a model comparison turn', () {
    test('reports the turn as running from its start until its last answer '
        'ends, and again across a chat change', () async {
      final s = await _Session.start();
      s.finishResponse();
      final seen = <bool>[];
      s.container.listen<bool>(
        chatMainAnswerActiveProvider,
        (_, running) => seen.add(running),
        fireImmediately: true,
      );

      // Admission puts the user row and both placeholders in at once.
      s.container.read(chatMessagesProvider.notifier).addMessages(
        _comparisonTurn(),
      );
      await s.container.pump();
      // One answer ending leaves the turn running, so nothing is announced.
      s.finishAnswer('c0');
      await s.container.pump();
      s.finishAnswer('c1');
      await s.container.pump();
      // A running comparison that is left behind for another chat.
      s.showComparison();
      await s.container.pump();
      s.switchTo('chat-2', messages: const []);
      await s.container.pump();

      check(seen).deepEquals([false, true, false, true, false]);
    });

    for (final order in const [
      ['c0', 'c1'],
      ['c1', 'c0'],
    ]) {
      test('holds the queue until the last answer is done, ${order.first} '
          'first', () async {
        final s = await _Session.start();
        s.showComparison();
        s.queue.enqueue('first');
        s.queue.enqueue('second');

        s.finishAnswer(order.first);
        await s.settle();
        check(await s.sentUserRows()).isEmpty();
        check(s.active!.drafts).length.equals(2);
        // The turn is still running, so a third message queues rather than
        // starting another.
        check(s.container.read(chatDraftQueueOfferProvider)).isTrue();
        check(s.queue.enqueue('third')).isNotNull();

        s.finishAnswer(order.last);
        await s.until(() => s.active == null);
        await s.settle();

        final rows = await s.sentUserRows();
        check(rows).length.equals(1);
        check(rows.single.content).equals('first\n\nsecond\n\nthird');
        check(await s.completions()).length.equals(1);
      });
    }

    test('does not wait for title or tag work the server still lists',
        () async {
      final s = await _Session.start();
      s.api.chatTaskIds = const ['title-task', 'tags-task'];
      s.container.read(activeChatIdsProvider.notifier).setActive(
        _Session.chatId,
      );
      s.showComparison();
      s.queue.enqueue('first');
      s.queue.enqueue('second');

      s.finishAnswer('c0');
      s.finishAnswer('c1');
      await s.until(() => s.active == null);
      await s.settle();

      check((await s.sentUserRows()).single.content)
          .equals('first\n\nsecond');
      check(await s.completions()).length.equals(1);
      // The server's own bookkeeping for the chat was still running throughout.
      check(s.container.read(activeChatIdsProvider))
          .contains(_Session.chatId);
    });

    for (final running in const [
      {'c0', 'c1'},
      {'c0'},
      {'c1'},
    ]) {
      test('send now stops every answer still running ($running) and sends '
          'only that draft', () async {
        final s = await _Session.start();
        s.showComparison(running: running);
        final first = s.queue.enqueue('first')!;
        final second = s.queue.enqueue('second')!;

        check(await s.queue.sendNow(first.id))
            .equals(ChatDraftSendNowOutcome.admitted);

        // The server's stop is for the whole chat, so no sibling task is left.
        check(s.api.stoppedChats).deepEquals([_Session.chatId]);
        check(s.answerStreaming('c0')).isFalse();
        check(s.answerStreaming('c1')).isFalse();
        check(s.releasedTransports).unorderedEquals(running);
        check((await s.sentUserRows()).single.content).equals('first');
        // The other draft is still the same draft, still this queue's.
        check(s.active!.drafts.map((d) => d.id)).deepEquals([second.id]);

        // It goes out once, on its own, when the turn just sent is answered.
        s.finishResponse();
        await s.until(() => s.active == null);
        await s.settle();
        check((await s.sentUserRows()).map((row) => row.content))
            .deepEquals(['first', 'second']);
        check(await s.completions()).length.equals(2);
      });
    }

    test('the compact Stop ends every answer with Advanced off, and the queue '
        'then sends its drafts once as one turn', () async {
      final s = await _Session.start();
      s.showComparison();
      s.queue.enqueue('first');
      s.queue.enqueue('second');
      (s.container.read(appSettingsProvider.notifier) as _Settings)
          .setAdvanced(false);

      s.container.read(stopGenerationProvider)();
      await s.until(() => s.active == null);
      await s.settle();

      check(s.api.stoppedChats).deepEquals([_Session.chatId]);
      check(s.answerStreaming('c0')).isFalse();
      check(s.answerStreaming('c1')).isFalse();
      check(s.releasedTransports).unorderedEquals(['c0', 'c1']);
      check((await s.sentUserRows()).single.content)
          .equals('first\n\nsecond');
      check(await s.completions()).length.equals(1);
    });

    test('never sends the queue into a new chat, another sign-in, or another '
        'chat, and sends it once back where it was queued', () async {
      final s = await _Session.start();
      s.showComparison();
      s.queue.enqueue('mine');
      final accountA = s.container.read(apiServiceProvider)!;
      final epochA = s.container.read(openWebUiAuthSessionEpochProvider);

      // A new chat takes the screen, so the comparison is no longer shown.
      s.container.read(activeConversationProvider.notifier).set(null);
      s.container.read(chatMessagesProvider.notifier).setMessages(const []);
      await s.settle();
      check((await s.db.select(s.db.chats).get())).length.equals(1);
      check(await s.completions()).isEmpty();

      // The same chat, finished, but opened by someone else.
      s.signInElsewhere(_Api('server-b'));
      s.switchTo(_Session.chatId, messages: _comparisonTurn(running: const {}));
      await s.settle();
      check(await s.sentUserRows()).isEmpty();
      check(s.container.read(chatDraftQueueProvider)).length.equals(1);

      s.container.read(s._wires.api.notifier).use(accountA);
      s.container.read(s._wires.epoch.notifier).use(epochA);
      await s.until(() => s.active == null);
      await s.settle();

      check((await s.sentUserRows()).single.content).equals('mine');
      check(await s.completions()).length.equals(1);
    });
  });
}
