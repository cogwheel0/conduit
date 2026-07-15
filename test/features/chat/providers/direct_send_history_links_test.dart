import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_manager.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/auth/api_auth_interceptor.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/direct_replay_output.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_adapter_helpers.dart';
import 'package:conduit/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit/features/direct_connections/services/direct_run_registry.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../support/gated_close_database.dart';

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _DatabaseState extends Notifier<AppDatabase?> {
  _DatabaseState(this.initial);

  final AppDatabase? initial;

  @override
  AppDatabase? build() => initial;

  void set(AppDatabase database) => state = database;
}

final class _ApiState extends Notifier<ApiService?> {
  _ApiState(this.initial);

  final ApiService? initial;

  @override
  ApiService? build() => initial;

  void set(ApiService service) => state = service;
}

final class _EpochState extends Notifier<Object> {
  _EpochState(this.initial);

  final Object initial;

  @override
  Object build() => initial;

  void rotate() => state = Object();
}

final class _SwitchableRemapSyncEngine extends SyncEngine {
  final Completer<void> _aCancellationGate = Completer<void>();
  late final StreamController<RemapEvent> _a = StreamController<RemapEvent>(
    sync: true,
  )..onCancel = () => _aCancellationGate.future;
  final StreamController<RemapEvent> _b =
      StreamController<RemapEvent>.broadcast(sync: true);
  bool useA = true;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Stream<RemapEvent> get remapEvents => useA ? _a.stream : _b.stream;

  void emitA(RemapEvent event) => _a.add(event);

  Future<void> disposeStreams() async {
    if (!_aCancellationGate.isCompleted) _aCancellationGate.complete();
    // The hostile single-subscription stream has no listener after dispatch.
    // Closing marks it closed synchronously, but its orphaned done future is
    // not a meaningful fixture-cleanup contract.
    unawaited(_a.close().catchError((_) {}));
    await _b.close();
  }
}

final class _Profiles extends DirectConnectionProfilesController {
  _Profiles(this.profile);

  final DirectConnectionProfile profile;

  @override
  Future<List<DirectConnectionProfile>> build() async => [profile];
}

final class _GatedProfiles extends DirectConnectionProfilesController {
  _GatedProfiles(this.profile);

  final DirectConnectionProfile profile;
  final Completer<void> started = Completer<void>();
  final Completer<List<DirectConnectionProfile>> gate =
      Completer<List<DirectConnectionProfile>>();

  @override
  Future<List<DirectConnectionProfile>> build() {
    if (!started.isCompleted) started.complete();
    return gate.future;
  }
}

final class _Adapter implements DirectProviderAdapter {
  var startCalls = 0;

  @override
  String get key => 'test-adapter';

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => [DirectRemoteModel(id: 'model')];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    startCalls++;
    return DirectCompletionRun(
      id: 'run',
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      events: Stream<DirectStreamEvent>.fromIterable(const [
        DirectReasoningDelta('Review the prior context.'),
        DirectContentDelta('Follow-up answer'),
        DirectStreamDone(),
      ]),
      cancelToken: CancelToken(),
      done: Future<void>.value(),
    );
  }
}

final class _GatedRun {
  _GatedRun({
    required String id,
    required String profileId,
    required String remoteModelId,
    this.hostileCancellation = false,
  }) {
    _events.onListen = () => _wasListened = true;
    if (hostileCancellation) {
      _events.onCancel = () => _cancellationGate.future;
    }
    run = DirectCompletionRun(
      id: id,
      profileId: profileId,
      remoteModelId: remoteModelId,
      events: _events.stream,
      cancelToken: CancelToken(),
      done: _done.future,
    );
  }

  final StreamController<DirectStreamEvent> _events =
      StreamController<DirectStreamEvent>(sync: true);
  final Completer<void> _done = Completer<void>();
  final Completer<void> _cancellationGate = Completer<void>();
  final bool hostileCancellation;
  bool _wasListened = false;
  late final DirectCompletionRun run;

  void add(DirectStreamEvent event) => _events.add(event);

  void addError(Object error, [StackTrace? stackTrace]) {
    _events.addError(error, stackTrace);
  }

  Future<void> close() async {
    if (!_cancellationGate.isCompleted) _cancellationGate.complete();
    if (!_wasListened) {
      if (!_done.isCompleted) _done.complete();
      unawaited(_events.close());
      return;
    }
    await _events.close();
    if (!_done.isCompleted) _done.complete();
  }
}

final class _GatedAdapter implements DirectProviderAdapter {
  _GatedAdapter({
    this.onStart,
    this.hostileCancellation = false,
    this.startError,
    this.startErrorStack,
  });

  final void Function()? onStart;
  final bool hostileCancellation;
  final Object? startError;
  final StackTrace? startErrorStack;
  final StreamController<_GatedRun> _started =
      StreamController<_GatedRun>.broadcast(sync: true);
  var _nextId = 0;

  @override
  String get key => 'test-adapter';

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => [DirectRemoteModel(id: 'model')];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    final error = startError;
    if (error != null) {
      final stackTrace = startErrorStack;
      if (stackTrace != null) Error.throwWithStackTrace(error, stackTrace);
      throw error;
    }
    final controlled = _GatedRun(
      id: 'gated-${++_nextId}',
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      hostileCancellation: hostileCancellation,
    );
    onStart?.call();
    _started.add(controlled);
    return controlled.run;
  }

  Future<_GatedRun> nextRun() => _started.stream.first;

  Future<void> dispose() => _started.close();
}

final class _EarlyRejectingDoneAdapter implements DirectProviderAdapter {
  final StreamController<DirectStreamEvent> events =
      StreamController<DirectStreamEvent>(sync: true);
  final Completer<void> started = Completer<void>();

  @override
  String get key => 'early-rejecting-done-adapter';

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => <DirectRemoteModel>[DirectRemoteModel(id: 'model')];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    if (!started.isCompleted) started.complete();
    return DirectCompletionRun(
      id: 'early-rejecting-done-run',
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      events: events.stream,
      cancelToken: CancelToken(),
      done: Future<void>.error(StateError('early cleanup rejection')),
    );
  }
}

final class _DeferredAttachmentApi extends ApiService {
  _DeferredAttachmentApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  final firstInfoStarted = Completer<void>();
  final firstInfoGate = Completer<void>();
  final firstInfoCancelled = Completer<void>();
  var getFileInfoCalls = 0;
  CancelToken? firstInfoCancelToken;

  @override
  Future<Map<String, dynamic>> getFileInfo(
    String fileId, {
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    getFileInfoCalls++;
    if (getFileInfoCalls == 1) {
      firstInfoCancelToken = cancelToken;
      firstInfoStarted.complete();
      await Future.any<void>(<Future<void>>[
        firstInfoGate.future,
        if (cancelToken != null)
          cancelToken.whenCancel.then<void>((_) {
            if (!firstInfoCancelled.isCompleted) {
              firstInfoCancelled.complete();
            }
          }),
      ]);
      final cancellation = cancelToken?.cancelError;
      if (cancellation != null) throw cancellation;
    }
    return const {
      'meta': {'content_type': 'image/png'},
    };
  }

  @override
  Future<String> getFileContent(
    String fileId, {
    int? maxBytes,
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async => 'AQID';
}

final class _ProvenanceApi extends ApiService {
  _ProvenanceApi({
    required this.label,
    this.gateFirstInfo = false,
    this.contentType,
  }) : super(
         serverConfig: ServerConfig(
           id: 'server-$label',
           name: 'Server $label',
           url: 'https://$label.example.test',
         ),
         workerManager: WorkerManager(),
       );

  final String label;
  final bool gateFirstInfo;
  final String? contentType;
  final Completer<void> firstInfoStarted = Completer<void>();
  final Completer<void> firstInfoGate = Completer<void>();
  var infoCalls = 0;
  var contentCalls = 0;

  @override
  Future<Map<String, dynamic>> getFileInfo(
    String fileId, {
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    infoCalls++;
    if (gateFirstInfo && infoCalls == 1) {
      firstInfoStarted.complete();
      await firstInfoGate.future;
    }
    return {
      'meta': {'content_type': contentType ?? 'image/png;source=$label'},
    };
  }

  @override
  Future<String> getFileContent(
    String fileId, {
    int? maxBytes,
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    contentCalls++;
    return base64Encode(utf8.encode('image-$label'));
  }
}

final class _AuthorizationRecordingFileAdapter implements HttpClientAdapter {
  final List<String?> authorizationHeaders = <String?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    authorizationHeaders.add(options.headers['Authorization']?.toString());
    return ResponseBody(
      Stream<Uint8List>.value(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(const {
              'meta': {'content_type': 'image/png'},
            }),
          ),
        ),
      ),
      200,
      headers: const {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _RequestRecordingAdapter implements DirectProviderAdapter {
  DirectCompletionRequest? request;

  @override
  String get key => 'recording-adapter';

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => [DirectRemoteModel(id: 'model', isMultimodal: true)];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    this.request = request;
    return DirectCompletionRun(
      id: 'recorded-run',
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      events: Stream<DirectStreamEvent>.fromIterable(const [
        DirectContentDelta('answer'),
        DirectStreamDone(),
      ]),
      cancelToken: CancelToken(),
      done: Future<void>.value(),
    );
  }
}

final class _ThrowAfterCompletionPersistRepository
    extends ChatDatabaseRepository {
  _ThrowAfterCompletionPersistRepository(AppDatabase database)
    : super(openWebUiDatabase: null, directLocalDatabase: database);

  var persistCalls = 0;

  @override
  Future<void> persistDirectMessages(
    ChatDatabaseLocation location, {
    required String chatId,
    required List<MessageRowData> messages,
    String? currentMessageId,
    int? updatedAt,
  }) async {
    await super.persistDirectMessages(
      location,
      chatId: chatId,
      messages: messages,
      currentMessageId: currentMessageId,
      updatedAt: updatedAt,
    );
    persistCalls++;
    if (persistCalls >= 2) {
      throw StateError('completion persistence failed after commit');
    }
  }
}

final class _GatedCompletionPersistRepository extends ChatDatabaseRepository {
  _GatedCompletionPersistRepository({
    required super.openWebUiDatabase,
    required super.directLocalDatabase,
    required this.finalContent,
  });

  final String finalContent;
  final Completer<void> completionPersistStarted = Completer<void>();
  final Completer<void> completionPersistGate = Completer<void>();

  @override
  Future<void> persistDirectMessages(
    ChatDatabaseLocation location, {
    required String chatId,
    required List<MessageRowData> messages,
    String? currentMessageId,
    int? updatedAt,
  }) async {
    if (messages.any(
      (message) =>
          message.role == 'assistant' && message.content == finalContent,
    )) {
      if (!completionPersistStarted.isCompleted) {
        completionPersistStarted.complete();
      }
      await completionPersistGate.future;
    }
    await super.persistDirectMessages(
      location,
      chatId: chatId,
      messages: messages,
      currentMessageId: currentMessageId,
      updatedAt: updatedAt,
    );
  }
}

final class _RotateAuthAfterTurnStartCommitRepository
    extends ChatDatabaseRepository {
  _RotateAuthAfterTurnStartCommitRepository({
    required super.openWebUiDatabase,
    required super.directLocalDatabase,
    required this.userContent,
    required this.rotateAuthSession,
  });

  final String userContent;
  final void Function() rotateAuthSession;
  var rotated = false;

  @override
  Future<void> persistDirectMessages(
    ChatDatabaseLocation location, {
    required String chatId,
    required List<MessageRowData> messages,
    String? currentMessageId,
    int? updatedAt,
  }) async {
    await super.persistDirectMessages(
      location,
      chatId: chatId,
      messages: messages,
      currentMessageId: currentMessageId,
      updatedAt: updatedAt,
    );
    if (!rotated &&
        messages.any(
          (message) => message.role == 'user' && message.content == userContent,
        ) &&
        messages.any((message) => message.role == 'assistant')) {
      rotated = true;
      rotateAuthSession();
    }
  }
}

final class _FailFinalPersistOnce {
  _FailFinalPersistOnce(this.finalContent);

  final String finalContent;
  var shouldFail = true;
  var failures = 0;
  var attempts = 0;
}

final class _FailFinalPersistOnceRepository extends ChatDatabaseRepository {
  _FailFinalPersistOnceRepository({
    required super.openWebUiDatabase,
    required super.directLocalDatabase,
    required this.control,
  });

  final _FailFinalPersistOnce control;

  @override
  Future<void> persistDirectMessages(
    ChatDatabaseLocation location, {
    required String chatId,
    required List<MessageRowData> messages,
    String? currentMessageId,
    int? updatedAt,
  }) async {
    final isTarget = messages.any(
      (message) =>
          message.role == 'assistant' &&
          message.content == control.finalContent,
    );
    if (isTarget) control.attempts++;
    if (isTarget && control.shouldFail) {
      control.shouldFail = false;
      control.failures++;
      throw StateError('injected failure before completion commit');
    }
    await super.persistDirectMessages(
      location,
      chatId: chatId,
      messages: messages,
      currentMessageId: currentMessageId,
      updatedAt: updatedAt,
    );
  }
}

enum _OwnerLossMutation { tombstoneChat, deletePlaceholder }

final class _OwnerInvalidatingRepository extends ChatDatabaseRepository {
  _OwnerInvalidatingRepository({
    required AppDatabase database,
    required this.mutation,
  }) : super(openWebUiDatabase: null, directLocalDatabase: database);

  final _OwnerLossMutation mutation;
  String? invalidatedMessageId;

  @override
  Future<String?> resolveCurrentChatIdForMessage(
    ChatDatabaseLocation location, {
    required String recordedChatId,
    required String messageId,
    required String expectedRole,
  }) async {
    if (expectedRole == 'assistant' && invalidatedMessageId == null) {
      invalidatedMessageId = messageId;
      switch (mutation) {
        case _OwnerLossMutation.tombstoneChat:
          await location.database.chatsDao.tombstoneWithOutbox(recordedChatId);
          break;
        case _OwnerLossMutation.deletePlaceholder:
          await location.database.customStatement(
            'DELETE FROM messages WHERE chat_id = ? AND id = ?',
            [recordedChatId, messageId],
          );
          break;
      }
    }
    return super.resolveCurrentChatIdForMessage(
      location,
      recordedChatId: recordedChatId,
      messageId: messageId,
      expectedRole: expectedRole,
    );
  }
}

Future<void> _waitForDatabaseClosed(AppDatabase database) async {
  await _waitUntil(() async {
    try {
      await database.customSelect('SELECT 1').get();
      return false;
    } catch (_) {
      return true;
    }
  });
}

Future<void> _waitUntil(Future<bool> Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<Conversation> _seedDirectConversation({
  required AppDatabase db,
  required String chatId,
  required String modelId,
  required String suffix,
}) async {
  final now = DateTime.utc(2026, 7, 11);
  final user = ChatMessage(
    id: 'user-$suffix',
    role: 'user',
    content: 'Question $suffix',
    timestamp: now,
    metadata: {
      'parentId': null,
      'childrenIds': <String>['assistant-$suffix'],
    },
  );
  final assistant = ChatMessage(
    id: 'assistant-$suffix',
    role: 'assistant',
    content: 'Answer $suffix',
    timestamp: now,
    model: modelId,
    metadata: {
      'parentId': user.id,
      'childrenIds': const <String>[],
      'transport': 'direct',
    },
  );
  final rows = ChatBlobMapper.blobToRows(
    chatId: chatId,
    blob: {
      'title': 'Chat $suffix',
      'models': [modelId],
      'history': {
        'currentId': assistant.id,
        'messages': {
          user.id: {
            'id': user.id,
            'parentId': null,
            'childrenIds': [assistant.id],
            'role': 'user',
            'content': user.content,
            'timestamp': 1,
          },
          assistant.id: {
            'id': assistant.id,
            'parentId': user.id,
            'childrenIds': <String>[],
            'role': 'assistant',
            'content': assistant.content,
            'model': modelId,
            'timestamp': 2,
          },
        },
      },
    },
    title: 'Chat $suffix',
    createdAt: 1,
    updatedAt: 2,
  );
  await db.chatsDao.upsertLocalOnlyChat(rows: rows);
  return withChatStorageProvenance(
    Conversation(
      id: chatId,
      title: 'Chat $suffix',
      createdAt: now,
      updatedAt: now,
      model: modelId,
      messages: [user, assistant],
    ),
    ChatStorageKind.directLocal,
  );
}

Future<
  ({
    ProviderContainer container,
    AppDatabase db,
    _GatedAdapter adapter,
    Conversation chat,
  })
>
_createGatedDirectHarness(
  String suffix, {
  void Function(ProviderContainer container)? onStart,
  NotifierProvider<_EpochState, Object>? authEpochState,
  DirectNormalizedStreamLimits? streamLimits,
  bool hostileCancellation = false,
  String profileBaseUrl = 'http://localhost:11434',
  String? profileApiKey,
  Map<String, String> profileHeaders = const {},
  String? profileMtlsCertificateChainPem,
  String? profileMtlsCertificateLabel,
  String? profileMtlsPrivateKeyPem,
  String? profileMtlsPrivateKeyLabel,
  String? profileMtlsPrivateKeyPassword,
  Object? startError,
  StackTrace? startErrorStack,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final profile = DirectConnectionProfile(
    id: 'profile',
    name: 'Provider',
    adapterKey: 'test-adapter',
    baseUrl: profileBaseUrl,
    apiKey: profileApiKey,
    customHeaders: profileHeaders,
    mtlsCertificateChainPem: profileMtlsCertificateChainPem,
    mtlsCertificateLabel: profileMtlsCertificateLabel,
    mtlsPrivateKeyPem: profileMtlsPrivateKeyPem,
    mtlsPrivateKeyLabel: profileMtlsPrivateKeyLabel,
    mtlsPrivateKeyPassword: profileMtlsPrivateKeyPassword,
  );
  final modelRegistry = DirectModelRegistry();
  final model = modelRegistry.replaceProfileModels(profile, [
    DirectRemoteModel(id: 'model'),
  ]).single;
  late ProviderContainer container;
  final adapter = _GatedAdapter(
    onStart: onStart == null ? null : () => onStart(container),
    hostileCancellation: hostileCancellation,
    startError: startError,
    startErrorStack: startErrorStack,
  );
  addTearDown(adapter.dispose);
  final chat = await _seedDirectConversation(
    db: db,
    chatId: 'direct-local:$suffix',
    modelId: model.id,
    suffix: suffix,
  );
  container = ProviderContainer(
    overrides: [
      activeConversationProvider.overrideWith(_ActiveConversation.new),
      selectedModelProvider.overrideWithValue(model),
      reviewerModeProvider.overrideWithValue(false),
      isAuthenticatedProvider2.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(null),
      socketServiceProvider.overrideWithValue(null),
      appDatabaseProvider.overrideWithValue(null),
      directLocalDatabaseProvider.overrideWithValue(db),
      directModelRegistryProvider.overrideWithValue(modelRegistry),
      directConnectionProfilesProvider.overrideWith(() => _Profiles(profile)),
      if (streamLimits != null)
        directNormalizedStreamLimitsProvider.overrideWithValue(streamLimits),
      directProviderAdapterRegistryProvider.overrideWithValue(
        DirectProviderAdapterRegistry([adapter]),
      ),
      if (authEpochState != null)
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(authEpochState),
        ),
    ],
  );
  addTearDown(container.dispose);
  container.read(activeConversationProvider.notifier).set(chat);
  container.read(chatMessagesProvider.notifier).setMessages(chat.messages);
  return (container: container, db: db, adapter: adapter, chat: chat);
}

Future<
  ({
    ProviderContainer container,
    AppDatabase db,
    _Adapter adapter,
    DirectRunRegistry runRegistry,
    _OwnerInvalidatingRepository repository,
    Conversation chat,
  })
>
_createInvalidatedOwnerRefreshHarness(
  String suffix,
  _OwnerLossMutation mutation,
) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final profile = DirectConnectionProfile(
    id: 'profile',
    name: 'Provider',
    adapterKey: 'test-adapter',
    baseUrl: 'http://localhost:11434',
  );
  final modelRegistry = DirectModelRegistry();
  final model = modelRegistry.replaceProfileModels(profile, [
    DirectRemoteModel(id: 'model'),
  ]).single;
  final adapter = _Adapter();
  final runRegistry = DirectRunRegistry();
  final repository = _OwnerInvalidatingRepository(
    database: db,
    mutation: mutation,
  );
  final chat = await _seedDirectConversation(
    db: db,
    chatId: 'direct-local:$suffix',
    modelId: model.id,
    suffix: suffix,
  );
  final container = ProviderContainer(
    overrides: [
      activeConversationProvider.overrideWith(_ActiveConversation.new),
      selectedModelProvider.overrideWithValue(model),
      reviewerModeProvider.overrideWithValue(false),
      isAuthenticatedProvider2.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(null),
      socketServiceProvider.overrideWithValue(null),
      appDatabaseProvider.overrideWithValue(null),
      directLocalDatabaseProvider.overrideWithValue(db),
      chatDatabaseRepositoryProvider.overrideWithValue(repository),
      directModelRegistryProvider.overrideWithValue(modelRegistry),
      directRunRegistryProvider.overrideWithValue(runRegistry),
      directConnectionProfilesProvider.overrideWith(() => _Profiles(profile)),
      directProviderAdapterRegistryProvider.overrideWithValue(
        DirectProviderAdapterRegistry([adapter]),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(activeConversationProvider.notifier).set(chat);
  container.read(chatMessagesProvider.notifier).setMessages(chat.messages);
  return (
    container: container,
    db: db,
    adapter: adapter,
    runRegistry: runRegistry,
    repository: repository,
    chat: chat,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'OpenWebUI image resolution accepts case-insensitive MIME types',
    () async {
      final api = _ProvenanceApi(label: 'upper', contentType: 'Image/PNG');

      final resolved = await resolveDirectImageFromOpenWebUiForTest(
        api,
        'server-image',
      );

      expect(resolved, startsWith('data:image/png;base64,'));
      expect(api.infoCalls, 1);
      expect(api.contentCalls, 1);
    },
  );

  test(
    'direct follow-up settles reasoning and preserves linked history on reload',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final registry = DirectModelRegistry();
      final model = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model', isMultimodal: true),
      ]).single;
      final now = DateTime.utc(2026, 7, 11);
      final firstUser = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'First question',
        timestamp: now,
        metadata: const {
          'parentId': null,
          'childrenIds': <String>['assistant-1'],
        },
      );
      final firstAssistant = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'First answer',
        timestamp: now,
        model: model.id,
        metadata: const {
          'parentId': 'user-1',
          'childrenIds': <String>[],
          'transport': 'direct',
        },
      );
      const chatId = 'direct-local:history';
      final rows = ChatBlobMapper.blobToRows(
        chatId: chatId,
        blob: {
          'title': 'History',
          'models': [model.id],
          'history': {
            'currentId': firstAssistant.id,
            'messages': {
              firstUser.id: {
                'id': firstUser.id,
                'parentId': null,
                'childrenIds': [firstAssistant.id],
                'role': 'user',
                'content': firstUser.content,
                'timestamp': 1,
              },
              firstAssistant.id: {
                'id': firstAssistant.id,
                'parentId': firstUser.id,
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': firstAssistant.content,
                'model': model.id,
                'timestamp': 2,
              },
            },
          },
        },
        title: 'History',
        createdAt: 1,
        updatedAt: 2,
      );
      await db.chatsDao.upsertLocalOnlyChat(rows: rows);
      final active = withChatStorageProvenance(
        Conversation(
          id: chatId,
          title: 'History',
          createdAt: now,
          updatedAt: now,
          model: model.id,
          messages: [firstUser, firstAssistant],
        ),
        ChatStorageKind.directLocal,
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseProvider.overrideWithValue(db),
          directModelRegistryProvider.overrideWithValue(registry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([_Adapter()]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(active);
      container
          .read(chatMessagesProvider.notifier)
          .setMessages(active.messages);

      const image = 'data:image/png;base64,AQID';
      await sendMessageWithContainer(container, 'Follow-up', const [image]);

      final completedAssistant = container
          .read(chatMessagesProvider)
          .lastWhere((message) => message.role == 'assistant');
      expect(completedAssistant.isStreaming, isFalse);
      expect(completedAssistant.content, contains('done="true"'));
      expect(completedAssistant.content, isNot(contains('done="false"')));

      final messageRows = await db.messagesDao.getForChat(chatId);
      final secondUser = messageRows.singleWhere(
        (row) => row.role == 'user' && row.id != firstUser.id,
      );
      final persistedParent = messageRows.singleWhere(
        (row) => row.id == firstAssistant.id,
      );
      final parentPayload =
          jsonDecode(persistedParent.payload) as Map<String, dynamic>;
      expect(parentPayload['childrenIds'], contains(secondUser.id));

      final inMemoryParent = container
          .read(chatMessagesProvider)
          .singleWhere((message) => message.id == firstAssistant.id);
      expect(inMemoryParent.metadata?['childrenIds'], contains(secondUser.id));

      final reloaded = await container
          .read(chatDatabaseRepositoryProvider)
          .loadConversation(chatId, preferred: ChatStorageKind.directLocal);
      expect(reloaded, isNotNull);
      final reloadedUser = reloaded!.conversation.messages.singleWhere(
        (message) => message.id == secondUser.id,
      );
      expect(reloadedUser.files, const [
        {'type': 'image', 'url': image},
      ]);
      final reloadedAssistant = reloaded.conversation.messages.singleWhere(
        (message) => message.id == completedAssistant.id,
      );
      expect(reloadedAssistant.isStreaming, isFalse);
      expect(reloadedAssistant.content, contains('done="true"'));
      expect(reloadedAssistant.content, isNot(contains('done="false"')));
    },
  );

  test(
    'navigation during direct attachment preflight completes in its owner chat',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final registry = DirectModelRegistry();
      final model = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model', isMultimodal: true),
      ]).single;
      final adapter = _Adapter();
      final api = _DeferredAttachmentApi();
      final chatA = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:chat-a',
        modelId: model.id,
        suffix: 'a',
      );
      final chatB = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:chat-b',
        modelId: model.id,
        suffix: 'b',
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(api),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseProvider.overrideWithValue(db),
          directModelRegistryProvider.overrideWithValue(registry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      container.read(activeConversationProvider.notifier).set(chatA);
      container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);

      final send = sendMessageWithContainer(
        container,
        'Chat A follow-up',
        const ['server-image'],
      );
      await api.firstInfoStarted.future.timeout(const Duration(seconds: 1));
      container.read(activeConversationProvider.notifier).set(chatB);
      await Future<void>.delayed(Duration.zero);
      api.firstInfoGate.complete();
      await send.timeout(const Duration(seconds: 1));

      final chatAMessages = await db.messagesDao.getForChat(chatA.id);
      final chatBMessages = await db.messagesDao.getForChat(chatB.id);
      expect(
        chatAMessages.where((row) => row.content == 'Chat A follow-up'),
        hasLength(1),
      );
      expect(
        chatAMessages.where(
          (row) =>
              row.role == 'assistant' &&
              row.content.contains('Follow-up answer'),
        ),
        hasLength(1),
      );
      expect(
        chatBMessages.where((row) => row.content == 'Chat A follow-up'),
        isEmpty,
      );
      expect(adapter.startCalls, 1);
      expect(container.read(activeConversationProvider)?.id, chatB.id);
      expect(
        container.read(chatMessagesProvider).map((message) => message.id),
        chatB.messages.map((message) => message.id),
      );
    },
  );

  test(
    'Stop interrupts a never-settling direct attachment preflight and releases its lease',
    () async {
      final manager = DatabaseManager(
        openDatabase: (_) =>
            GatedCloseDatabase(NativeDatabase.memory(), failClose: false),
      );
      final db =
          manager.openForServerId('direct-stop-preflight')
              as GatedCloseDatabase;
      final databaseCloseGate = Completer<void>();
      final api = _DeferredAttachmentApi();
      addTearDown(() async {
        if (!api.firstInfoGate.isCompleted) api.firstInfoGate.complete();
        if (!databaseCloseGate.isCompleted) databaseCloseGate.complete();
        await manager.closeActive();
      });
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(
        profile,
        <DirectRemoteModel>[DirectRemoteModel(id: 'model', isMultimodal: true)],
      ).single;
      final adapter = _Adapter();
      final chat = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:stalled-attachment',
        modelId: model.id,
        suffix: 'stalled-attachment',
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(api),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseManagerProvider.overrideWithValue(manager),
          directLocalDatabaseProvider.overrideWithValue(db),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry(<DirectProviderAdapter>[adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(chat);
      container.read(chatMessagesProvider.notifier).setMessages(chat.messages);

      final send = sendMessageWithContainer(
        container,
        'Stop this attachment lookup',
        const <String>['server-image'],
      );
      await api.firstInfoStarted.future.timeout(const Duration(seconds: 1));
      db.closeGate = databaseCloseGate;
      container.read(stopGenerationProvider)();
      final close = manager.closeActive();

      await send.timeout(const Duration(seconds: 1));
      await api.firstInfoCancelled.future.timeout(const Duration(seconds: 1));
      await db.closeStarted.future.timeout(const Duration(seconds: 1));
      expect(api.firstInfoGate.isCompleted, isFalse);
      expect(api.firstInfoCancelToken?.isCancelled, isTrue);
      expect(adapter.startCalls, 0);
      expect(container.read(chatMessagesProvider).last.isStreaming, isFalse);

      databaseCloseGate.complete();
      await close.timeout(const Duration(seconds: 1));
      api.firstInfoGate.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('direct send cannot retarget after route resolution await', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final profile = DirectConnectionProfile(
      id: 'profile',
      name: 'Provider',
      adapterKey: 'test-adapter',
      baseUrl: 'http://localhost:11434',
    );
    final registry = DirectModelRegistry();
    final model = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model'),
    ]).single;
    final profiles = _GatedProfiles(profile);
    final adapter = _Adapter();
    final chatA = await _seedDirectConversation(
      db: db,
      chatId: 'direct-local:route-a',
      modelId: model.id,
      suffix: 'route-a',
    );
    final chatB = await _seedDirectConversation(
      db: db,
      chatId: 'direct-local:route-b',
      modelId: model.id,
      suffix: 'route-b',
    );
    final container = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        selectedModelProvider.overrideWithValue(model),
        reviewerModeProvider.overrideWithValue(false),
        isAuthenticatedProvider2.overrideWithValue(false),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        appDatabaseProvider.overrideWithValue(null),
        directLocalDatabaseProvider.overrideWithValue(db),
        directModelRegistryProvider.overrideWithValue(registry),
        directConnectionProfilesProvider.overrideWith(() => profiles),
        directProviderAdapterRegistryProvider.overrideWithValue(
          DirectProviderAdapterRegistry([adapter]),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeConversationProvider.notifier).set(chatA);
    container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);

    final send = sendMessageWithContainer(container, 'Must stay in A', null);
    await profiles.started.future.timeout(const Duration(seconds: 1));
    container.read(activeConversationProvider.notifier).set(chatB);
    container.read(chatMessagesProvider.notifier).setMessages(chatB.messages);
    final visibleB = container.read(chatMessagesProvider);
    profiles.gate.complete([profile]);

    await expectLater(send, throwsA(isA<StateError>()));
    expect(identical(container.read(chatMessagesProvider), visibleB), isTrue);
    expect(adapter.startCalls, 0);
    expect(
      (await db.messagesDao.getForChat(
        chatA.id,
      )).where((row) => row.content == 'Must stay in A'),
      isEmpty,
    );
    expect(
      (await db.messagesDao.getForChat(
        chatB.id,
      )).where((row) => row.content == 'Must stay in A'),
      isEmpty,
    );
  });

  test('direct send rejects a binding revoked while profiles load', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final profile = DirectConnectionProfile(
      id: 'profile',
      name: 'Provider',
      adapterKey: 'test-adapter',
      baseUrl: 'http://localhost:11434',
    );
    final modelRegistry = DirectModelRegistry();
    final model = modelRegistry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model'),
    ]).single;
    final profiles = _GatedProfiles(profile);
    final adapter = _Adapter();
    final runRegistry = DirectRunRegistry();
    final chat = await _seedDirectConversation(
      db: db,
      chatId: 'direct-local:revoked-route',
      modelId: model.id,
      suffix: 'revoked-route',
    );
    final container = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        selectedModelProvider.overrideWithValue(model),
        reviewerModeProvider.overrideWithValue(false),
        isAuthenticatedProvider2.overrideWithValue(false),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        appDatabaseProvider.overrideWithValue(null),
        directLocalDatabaseProvider.overrideWithValue(db),
        directModelRegistryProvider.overrideWithValue(modelRegistry),
        directRunRegistryProvider.overrideWithValue(runRegistry),
        directConnectionProfilesProvider.overrideWith(() => profiles),
        directProviderAdapterRegistryProvider.overrideWithValue(
          DirectProviderAdapterRegistry([adapter]),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeConversationProvider.notifier).set(chat);
    container.read(chatMessagesProvider.notifier).setMessages(chat.messages);
    final visibleBeforeSend = container.read(chatMessagesProvider);

    final send = sendMessageWithContainer(
      container,
      'Do not use the revoked route',
      null,
    );
    await profiles.started.future.timeout(const Duration(seconds: 1));
    modelRegistry.removeProfile(profile.id);
    expect(modelRegistry.resolve(model), isNull);
    profiles.gate.complete([profile]);

    await expectLater(send, throwsA(isA<Exception>()));
    // Direct reservations are created only after the optimistic turn is
    // installed. Preserving the exact list proves route preparation stopped
    // before both reservation and provider dispatch.
    expect(
      identical(container.read(chatMessagesProvider), visibleBeforeSend),
      isTrue,
    );
    expect(runRegistry.cancelProfile(profile.id), isEmpty);
    expect(adapter.startCalls, 0);
  });

  test(
    'tombstoned durable owner blocks provider start and settles its placeholder',
    () async {
      final harness = await _createInvalidatedOwnerRefreshHarness(
        'owner-refresh-tombstone',
        _OwnerLossMutation.tombstoneChat,
      );
      final send = sendMessageWithContainer(
        harness.container,
        'Do not start after deletion',
        null,
      );

      await expectLater(
        send.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Direct conversation owner is no longer available.',
          ),
        ),
      );
      final assistantId = harness.repository.invalidatedMessageId!;
      final ownerKey = (
        ownerConversationId: directRunOwnerScopeForTest(
          harness.container,
          harness.chat,
        ),
        assistantMessageId: assistantId,
      );
      expect(harness.adapter.startCalls, 0);
      expect(harness.runRegistry.hasLiveIntent(ownerKey), isFalse);
      final failed = harness.container
          .read(chatMessagesProvider)
          .singleWhere((message) => message.id == assistantId);
      expect(failed.isStreaming, isFalse);
      expect(
        failed.error?.content,
        'This conversation is no longer available.',
      );
    },
  );

  test(
    'deleted durable placeholder blocks provider start without resurrection',
    () async {
      final harness = await _createInvalidatedOwnerRefreshHarness(
        'owner-refresh-placeholder',
        _OwnerLossMutation.deletePlaceholder,
      );
      final send = sendMessageWithContainer(
        harness.container,
        'Do not resurrect this placeholder',
        null,
      );

      await expectLater(
        send.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Direct conversation owner is no longer available.',
          ),
        ),
      );
      final assistantId = harness.repository.invalidatedMessageId!;
      final ownerKey = (
        ownerConversationId: directRunOwnerScopeForTest(
          harness.container,
          harness.chat,
        ),
        assistantMessageId: assistantId,
      );
      expect(harness.adapter.startCalls, 0);
      expect(harness.runRegistry.hasLiveIntent(ownerKey), isFalse);
      await _waitUntil(
        () async => harness.container
            .read(chatMessagesProvider)
            .every((message) => message.id != assistantId),
      );
      final visible = harness.container.read(chatMessagesProvider);
      expect(visible.where((message) => message.id == assistantId), isEmpty);
      expect(
        visible.where(
          (message) => message.role == 'assistant' && message.isStreaming,
        ),
        isEmpty,
      );
    },
  );

  test(
    'direct attachment bytes and metadata stay bound to source server A',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final directLocal = AppDatabase(NativeDatabase.memory());
      addTearDown(directLocal.close);
      final apiA = _ProvenanceApi(label: 'a', gateFirstInfo: true);
      final apiB = _ProvenanceApi(label: 'b');
      final apiState = NotifierProvider<_ApiState, ApiService?>(
        () => _ApiState(apiA),
      );
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'recording-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final registry = DirectModelRegistry();
      final model = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model', isMultimodal: true),
      ]).single;
      final adapter = _RequestRecordingAdapter();
      final chatA = withChatStorageProvenance(
        await _seedDirectConversation(
          db: db,
          chatId: 'source-a',
          modelId: model.id,
          suffix: 'source-a',
        ),
        ChatStorageKind.openWebUi,
      );
      final chatB = withChatStorageProvenance(
        Conversation(
          id: 'source-b',
          title: 'B',
          createdAt: DateTime.utc(2026, 7, 13),
          updatedAt: DateTime.utc(2026, 7, 13),
          messages: [
            ChatMessage(
              id: 'b',
              role: 'assistant',
              content: 'B sentinel',
              timestamp: DateTime.utc(2026, 7, 13),
            ),
          ],
        ),
        ChatStorageKind.openWebUi,
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWith((ref) => ref.watch(apiState)),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(db),
          directLocalDatabaseProvider.overrideWithValue(directLocal),
          directModelRegistryProvider.overrideWithValue(registry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      container.read(activeConversationProvider.notifier).set(chatA);
      container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);

      final send = sendMessageWithContainer(
        container,
        'Use source image',
        const ['same-file-id'],
      );
      await apiA.firstInfoStarted.future.timeout(const Duration(seconds: 1));
      container.read(apiState.notifier).set(apiB);
      container.read(activeConversationProvider.notifier).set(chatB);
      container.read(chatMessagesProvider.notifier).setMessages(chatB.messages);
      final bBefore = jsonEncode(
        container.read(chatMessagesProvider).map((m) => m.toJson()).toList(),
      );
      apiA.firstInfoGate.complete();
      await send.timeout(const Duration(seconds: 2));

      expect(apiB.infoCalls, 0);
      expect(apiB.contentCalls, 0);
      expect(apiA.infoCalls, greaterThanOrEqualTo(2));
      expect(apiA.contentCalls, greaterThanOrEqualTo(2));
      expect(
        jsonEncode(
          container.read(chatMessagesProvider).map((m) => m.toJson()).toList(),
        ),
        bBefore,
      );
      final imageParts = adapter.request!.messages
          .expand((message) => message.parts)
          .whereType<DirectImagePart>()
          .toList();
      expect(imageParts, hasLength(1));
      expect(
        utf8.decode(base64Decode(imageParts.single.base64Data!)),
        'image-a',
      );
      final userRow = (await db.messagesDao.getForChat(
        chatA.id,
      )).singleWhere((row) => row.content == 'Use source image');
      final userPayload = jsonDecode(userRow.payload) as Map<String, dynamic>;
      final files = (userPayload['files'] as List).cast<Map>();
      expect(files.single['content_type'], 'image/png;source=a');
    },
  );

  test(
    'OpenWebUI auth epoch change aborts gated direct attachment preflight',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      final directLocal = AppDatabase(NativeDatabase.memory());
      addTearDown(directLocal.close);
      final databaseState = NotifierProvider<_DatabaseState, AppDatabase?>(
        () => _DatabaseState(db),
      );
      final api = _ProvenanceApi(label: 'shared', gateFirstInfo: true);
      final epochState = NotifierProvider<_EpochState, Object>(
        () => _EpochState(Object()),
      );
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'recording-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model', isMultimodal: true),
      ]).single;
      final adapter = _RequestRecordingAdapter();
      final chatA = withChatStorageProvenance(
        await _seedDirectConversation(
          db: db,
          chatId: 'same-chat',
          modelId: model.id,
          suffix: 'auth-a',
        ),
        ChatStorageKind.openWebUi,
      );
      final chatB = withChatStorageProvenance(
        await _seedDirectConversation(
          db: dbB,
          chatId: chatA.id,
          modelId: model.id,
          suffix: 'auth-b',
        ),
        ChatStorageKind.openWebUi,
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(api),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWith((ref) => ref.watch(databaseState)),
          directLocalDatabaseProvider.overrideWithValue(directLocal),
          chatDatabaseRepositoryProvider.overrideWith((ref) {
            return ChatDatabaseRepository(
              openWebUiDatabase: ref.watch(appDatabaseProvider),
              directLocalDatabase: ref.watch(directLocalDatabaseProvider),
            );
          }),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(epochState),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      container.read(activeConversationProvider.notifier).set(chatA);
      container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);
      final ownerScopeA = directRunOwnerScopeForTest(container, chatA);

      final send = sendMessageWithContainer(
        container,
        'Do not leak this image',
        const ['same-file-id'],
      );
      await api.firstInfoStarted.future.timeout(const Duration(seconds: 1));

      container.read(epochState.notifier).rotate();
      container.read(databaseState.notifier).set(dbB);
      container.read(activeConversationProvider.notifier).set(chatB);
      container.read(chatMessagesProvider.notifier).setMessages(chatB.messages);
      await _waitUntil(() async {
        final visible = container.read(chatMessagesProvider);
        return visible.length == 2 &&
            visible.first.id == 'user-auth-b' &&
            visible.first.timestamp.year == 1970;
      });
      final bBefore = jsonEncode(
        container.read(chatMessagesProvider).map((m) => m.toJson()).toList(),
      );
      expect(directRunOwnerScopeForTest(container, chatB), isNot(ownerScopeA));
      api.firstInfoGate.complete();

      await send.timeout(const Duration(seconds: 1));

      expect(api.infoCalls, 1);
      expect(api.contentCalls, 0);
      expect(adapter.request, isNull);
      expect(
        jsonEncode(
          container.read(chatMessagesProvider).map((m) => m.toJson()).toList(),
        ),
        bBefore,
      );
      final durableRows = await db.messagesDao.getForChat(chatA.id);
      final committedUser = durableRows.singleWhere(
        (row) => row.role == 'user' && row.content == 'Do not leak this image',
      );
      final committedAssistant = durableRows.singleWhere(
        (row) => row.role == 'assistant' && row.parentId == committedUser.id,
      );
      final assistantPayload =
          jsonDecode(committedAssistant.payload) as Map<String, dynamic>;
      expect(assistantPayload['isStreaming'], isFalse);
      expect(assistantPayload['done'], isTrue);
    },
  );

  test(
    'OpenWebUI auth rotation after turn commit settles the placeholder',
    () async {
      const userContent = 'Rotate immediately after commit';
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final directLocal = AppDatabase(NativeDatabase.memory());
      addTearDown(directLocal.close);
      final epochState = NotifierProvider<_EpochState, Object>(
        () => _EpochState(Object()),
      );
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final adapter = _Adapter();
      final chat = withChatStorageProvenance(
        await _seedDirectConversation(
          db: db,
          chatId: 'post-commit-auth-rotation',
          modelId: model.id,
          suffix: 'post-commit-auth-rotation',
        ),
        ChatStorageKind.openWebUi,
      );
      late ProviderContainer container;
      final repository = _RotateAuthAfterTurnStartCommitRepository(
        openWebUiDatabase: db,
        directLocalDatabase: directLocal,
        userContent: userContent,
        rotateAuthSession: () {
          container.read(epochState.notifier).rotate();
        },
      );
      container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(db),
          directLocalDatabaseProvider.overrideWithValue(directLocal),
          chatDatabaseRepositoryProvider.overrideWithValue(repository),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(epochState),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      container.read(activeConversationProvider.notifier).set(chat);
      container.read(chatMessagesProvider.notifier).setMessages(chat.messages);

      await sendMessageWithContainer(
        container,
        userContent,
        null,
      ).timeout(const Duration(seconds: 1));

      expect(repository.rotated, isTrue);
      expect(adapter.startCalls, 0);
      final durableRows = await db.messagesDao.getForChat(chat.id);
      final committedUser = durableRows.singleWhere(
        (row) => row.role == 'user' && row.content == userContent,
      );
      final committedAssistant = durableRows.singleWhere(
        (row) => row.role == 'assistant' && row.parentId == committedUser.id,
      );
      final assistantPayload =
          jsonDecode(committedAssistant.payload) as Map<String, dynamic>;
      expect(assistantPayload['isStreaming'], isFalse);
      expect(assistantPayload['done'], isTrue);
    },
  );

  test(
    'queued direct attachment request cannot adopt the next account token',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final directLocal = AppDatabase(NativeDatabase.memory());
      addTearDown(directLocal.close);
      final transport = _AuthorizationRecordingFileAdapter();
      final api = ApiService(
        serverConfig: const ServerConfig(
          id: 'same-server',
          name: 'Same server',
          url: 'https://same.example.test',
        ),
        workerManager: WorkerManager(),
        authToken: 'account-a-token',
      );
      api.dio.httpClientAdapter = transport;
      addTearDown(() => api.dio.close(force: true));
      final requestReachedPreAuthGate = Completer<void>();
      final releasePreAuthGate = Completer<void>();
      api.dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/api/v1/files/same-file-id' &&
                !requestReachedPreAuthGate.isCompleted) {
              requestReachedPreAuthGate.complete();
              unawaited(
                releasePreAuthGate.future.then((_) => handler.next(options)),
              );
              return;
            }
            handler.next(options);
          },
        ),
      );
      final epochState = NotifierProvider<_EpochState, Object>(
        () => _EpochState(Object()),
      );
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'recording-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model', isMultimodal: true),
      ]).single;
      final adapter = _RequestRecordingAdapter();
      final chatA = withChatStorageProvenance(
        await _seedDirectConversation(
          db: directLocal,
          chatId: 'direct-local:account-a',
          modelId: model.id,
          suffix: 'token-a',
        ),
        ChatStorageKind.directLocal,
      );
      final chatB = withChatStorageProvenance(
        chatA.copyWith(
          id: 'direct-local:account-b',
          title: 'Account B',
          messages: [
            ChatMessage(
              id: 'b-sentinel',
              role: 'assistant',
              content: 'Account B sentinel',
              timestamp: DateTime.utc(2026, 7, 13),
            ),
          ],
        ),
        ChatStorageKind.directLocal,
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(api),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(db),
          directLocalDatabaseProvider.overrideWithValue(directLocal),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(epochState),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(chatA);
      container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);

      final send = sendMessageWithContainer(
        container,
        'Keep this request on account A',
        const ['same-file-id'],
      );
      await requestReachedPreAuthGate.future.timeout(
        const Duration(seconds: 1),
      );

      api.updateAuthToken('account-b-token');
      container.read(epochState.notifier).rotate();
      container.read(activeConversationProvider.notifier).set(chatB);
      container.read(chatMessagesProvider.notifier).setMessages(chatB.messages);
      releasePreAuthGate.complete();

      await send.timeout(const Duration(seconds: 1));

      expect(transport.authorizationHeaders, isEmpty);
      expect(adapter.request, isNull);
      expect(
        container.read(chatMessagesProvider).single.content,
        'Account B sentinel',
      );
    },
  );

  test(
    'queued durable attachment cannot adopt the next account token or persist',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final transport = _AuthorizationRecordingFileAdapter();
      final api = ApiService(
        serverConfig: const ServerConfig(
          id: 'same-server',
          name: 'Same server',
          url: 'https://same.example.test',
        ),
        workerManager: WorkerManager(),
        authToken: 'account-a-token',
      );
      api.dio.httpClientAdapter = transport;
      addTearDown(() => api.dio.close(force: true));
      final requestReachedPreAuthGate = Completer<void>();
      final releasePreAuthGate = Completer<void>();
      api.dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/api/v1/files/same-file-id' &&
                !requestReachedPreAuthGate.isCompleted) {
              requestReachedPreAuthGate.complete();
              unawaited(
                releasePreAuthGate.future.then((_) => handler.next(options)),
              );
              return;
            }
            handler.next(options);
          },
        ),
      );
      final epochState = NotifierProvider<_EpochState, Object>(
        () => _EpochState(Object()),
      );
      const model = Model(id: 'server-model', name: 'Server model');
      final chatA = withChatStorageProvenance(
        await _seedDirectConversation(
          db: db,
          chatId: 'openwebui:account-a',
          modelId: model.id,
          suffix: 'durable-token-a',
        ),
        ChatStorageKind.openWebUi,
      );
      final chatB = withChatStorageProvenance(
        Conversation(
          id: 'openwebui:account-b',
          title: 'Account B',
          createdAt: DateTime.utc(2026, 7, 13),
          updatedAt: DateTime.utc(2026, 7, 13),
          messages: [
            ChatMessage(
              id: 'b-sentinel',
              role: 'assistant',
              content: 'Account B sentinel',
              timestamp: DateTime.utc(2026, 7, 13),
            ),
          ],
        ),
        ChatStorageKind.openWebUi,
      );
      final rowsBefore = await db.messagesDao.getForChat(chatA.id);
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(api),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(db),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(epochState),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      container.read(activeConversationProvider.notifier).set(chatA);
      container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);

      final send = durableSend(
        container,
        'Do not persist this stale turn',
        const ['same-file-id'],
      );
      await requestReachedPreAuthGate.future.timeout(
        const Duration(seconds: 1),
      );

      api.updateAuthToken('account-b-token');
      container.read(epochState.notifier).rotate();
      container.read(activeConversationProvider.notifier).set(chatB);
      container.read(chatMessagesProvider.notifier).setMessages(chatB.messages);
      releasePreAuthGate.complete();

      await expectLater(
        send.timeout(const Duration(seconds: 1)),
        throwsA(isA<StateError>()),
      );
      expect(transport.authorizationHeaders, isEmpty);
      expect(
        container.read(chatMessagesProvider).single.content,
        'Account B sentinel',
      );
      final rowsAfter = await db.messagesDao.getForChat(chatA.id);
      expect(rowsAfter.map((row) => row.id), rowsBefore.map((row) => row.id));
      expect(
        rowsAfter.where(
          (row) => row.content == 'Do not persist this stale turn',
        ),
        isEmpty,
      );
    },
  );

  test('delayed direct preflight keeps its captured OpenWebUI remap stream and '
      'detaches hostile cleanup', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final directLocal = AppDatabase(NativeDatabase.memory());
    addTearDown(directLocal.close);
    final api = _ProvenanceApi(label: 'a', gateFirstInfo: true);
    final syncEngine = _SwitchableRemapSyncEngine();
    addTearDown(syncEngine.disposeStreams);
    final profile = DirectConnectionProfile(
      id: 'profile',
      name: 'Provider',
      adapterKey: 'test-adapter',
      baseUrl: 'http://localhost:11434',
    );
    final modelRegistry = DirectModelRegistry();
    final model = modelRegistry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model', isMultimodal: true),
    ]).single;
    final adapter = _GatedAdapter();
    addTearDown(adapter.dispose);
    final runRegistry = DirectRunRegistry();
    final chat = withChatStorageProvenance(
      await _seedDirectConversation(
        db: db,
        chatId: 'local:captured-remap',
        modelId: model.id,
        suffix: 'captured-remap',
      ),
      ChatStorageKind.openWebUi,
    );
    final container = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        selectedModelProvider.overrideWithValue(model),
        reviewerModeProvider.overrideWithValue(false),
        isAuthenticatedProvider2.overrideWithValue(false),
        apiServiceProvider.overrideWithValue(api),
        socketServiceProvider.overrideWithValue(null),
        appDatabaseProvider.overrideWithValue(db),
        directLocalDatabaseProvider.overrideWithValue(directLocal),
        directModelRegistryProvider.overrideWithValue(modelRegistry),
        directRunRegistryProvider.overrideWithValue(runRegistry),
        directConnectionProfilesProvider.overrideWith(() => _Profiles(profile)),
        directProviderAdapterRegistryProvider.overrideWithValue(
          DirectProviderAdapterRegistry([adapter]),
        ),
        syncEngineProvider.overrideWith(() => syncEngine),
      ],
    );
    addTearDown(container.dispose);
    container.read(openWebUiDatabaseAccessProvider.notifier).open();
    container.read(activeConversationProvider.notifier).set(chat);
    container.read(chatMessagesProvider.notifier).setMessages(chat.messages);

    final started = adapter.nextRun();
    final send = sendMessageWithContainer(
      container,
      'Track the original remap stream',
      const ['same-file-id'],
    );
    await api.firstInfoStarted.future.timeout(const Duration(seconds: 1));
    syncEngine.useA = false;
    api.firstInfoGate.complete();
    final run = await started.timeout(const Duration(seconds: 1));
    addTearDown(run.close);
    final assistantId = container.read(chatMessagesProvider).last.id;
    const remappedId = 'server-remapped';
    final remapper = IdRemapper(db);
    addTearDown(remapper.dispose);
    await remapper.remapChat(
      localId: chat.id,
      serverId: remappedId,
      serverCreatedAt: 1,
      serverUpdatedAt: 2,
    );
    syncEngine.emitA(
      const RemapEvent(
        fromId: 'local:captured-remap',
        toId: remappedId,
        entityKind: 'chat',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final remappedConversation = withChatStorageProvenance(
      chat.copyWith(id: remappedId),
      ChatStorageKind.openWebUi,
    );
    final remappedKey = (
      ownerConversationId: directRunOwnerScopeForTest(
        container,
        remappedConversation,
      ),
      assistantMessageId: assistantId,
    );
    expect(runRegistry.runFor(remappedKey), same(run.run));

    run.add(const DirectContentDelta('Remap-safe answer'));
    run.add(const DirectStreamDone());
    await send.timeout(const Duration(seconds: 1));
  });

  test('stale Hermes remap cannot rebind a direct-local completion', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final profile = DirectConnectionProfile(
      id: 'profile',
      name: 'Provider',
      adapterKey: 'test-adapter',
      baseUrl: 'http://localhost:11434',
    );
    final modelRegistry = DirectModelRegistry();
    final model = modelRegistry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model'),
    ]).single;
    final adapter = _GatedAdapter();
    addTearDown(adapter.dispose);
    final runRegistry = DirectRunRegistry();
    final directChat = await _seedDirectConversation(
      db: db,
      chatId: 'shared-chat-id',
      modelId: model.id,
      suffix: 'shared',
    );
    final container = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        selectedModelProvider.overrideWithValue(model),
        reviewerModeProvider.overrideWithValue(false),
        isAuthenticatedProvider2.overrideWithValue(false),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        appDatabaseProvider.overrideWithValue(null),
        directLocalDatabaseProvider.overrideWithValue(db),
        directModelRegistryProvider.overrideWithValue(modelRegistry),
        directConnectionProfilesProvider.overrideWith(() => _Profiles(profile)),
        directRunRegistryProvider.overrideWithValue(runRegistry),
        directProviderAdapterRegistryProvider.overrideWithValue(
          DirectProviderAdapterRegistry([adapter]),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeConversationProvider.notifier).set(directChat);
    container
        .read(chatMessagesProvider.notifier)
        .setMessages(directChat.messages);

    // Hermes session binding also writes this process-global raw-id remap.
    // Leave one behind to model switching from Hermes to a direct-local chat
    // whose id happens to collide with the old Hermes source id.
    container
        .read(activeConversationInPlaceRemapProvider.notifier)
        .mark(fromId: directChat.id, toId: 'local:hermes_stale-session');

    final started = adapter.nextRun();
    final send = sendMessageWithContainer(
      container,
      'Keep direct ownership',
      null,
    );
    final run = await started.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);
    final assistantId = container.read(chatMessagesProvider).last.id;
    final directOwnerKey = (
      ownerConversationId: directRunOwnerScopeForTest(container, directChat),
      assistantMessageId: assistantId,
    );
    final staleTargetKey = (
      ownerConversationId: directRunOwnerScopeForTest(
        container,
        directChat.copyWith(id: 'local:hermes_stale-session'),
      ),
      assistantMessageId: assistantId,
    );

    expect(runRegistry.runFor(directOwnerKey), same(run.run));
    expect(runRegistry.runFor(staleTargetKey), isNull);
    run.add(const DirectContentDelta('Owned by direct X'));
    await Future<void>.delayed(Duration.zero);

    // Cancellation must address the direct-local X key, not the stale
    // backend-agnostic remap destination.
    final cancellation = runRegistry.cancel(directOwnerKey);
    expect(cancellation, isNotNull);
    await run.close();
    await cancellation!.timeout(const Duration(seconds: 1));
    await send.timeout(const Duration(seconds: 1));

    final completed = container.read(chatMessagesProvider).last;
    expect(completed.id, assistantId);
    expect(completed.isStreaming, isFalse);
    expect(completed.content, 'Owned by direct X');
    expect(runRegistry.runFor(staleTargetKey), isNull);
    expect(runRegistry.cancel(staleTargetKey), isNull);
  });

  test(
    'reopening a direct chat mid-stream completes from its run accumulator',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final adapter = _GatedAdapter();
      addTearDown(adapter.dispose);
      final chatA = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:reopen-a',
        modelId: model.id,
        suffix: 'reopen-a',
      );
      final chatB = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:reopen-b',
        modelId: model.id,
        suffix: 'reopen-b',
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseProvider.overrideWithValue(db),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(chatA);
      container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);

      final started = adapter.nextRun();
      final send = sendMessageWithContainer(container, 'Stream in A', null);
      final run = await started.timeout(const Duration(seconds: 1));
      run.add(const DirectReasoningDelta('Inspect the route.'));
      run.add(const DirectContentDelta('Accumulator'));
      await Future<void>.delayed(Duration.zero);
      final assistantId = container.read(chatMessagesProvider).last.id;

      container.read(activeConversationProvider.notifier).set(chatB);
      await Future<void>.delayed(Duration.zero);
      final reopened = await container
          .read(chatDatabaseRepositoryProvider)
          .loadConversation(chatA.id, preferred: ChatStorageKind.directLocal);
      expect(reopened, isNotNull);
      container
          .read(activeConversationProvider.notifier)
          .set(reopened!.conversation);
      await Future<void>.delayed(Duration.zero);

      final reopenedPlaceholder = container
          .read(chatMessagesProvider)
          .singleWhere((message) => message.id == assistantId);
      expect(reopenedPlaceholder.isStreaming, isTrue);

      run.add(const DirectContentDelta(' wins'));
      await Future<void>.delayed(Duration.zero);
      container.read(chatMessagesProvider.notifier).syncStreamingBuffer();
      final resumed = container
          .read(chatMessagesProvider)
          .singleWhere((message) => message.id == assistantId);
      expect(resumed.isStreaming, isTrue);
      expect(resumed.content, contains('Inspect the route.'));
      expect(resumed.content, endsWith('Accumulator wins'));

      run.add(const DirectStreamDone());
      await run.close();
      await send.timeout(const Duration(seconds: 1));

      final completed = container
          .read(chatMessagesProvider)
          .singleWhere((message) => message.id == assistantId);
      expect(completed.isStreaming, isFalse);
      expect(completed.content, contains('done="true"'));
      expect(completed.content, endsWith('Accumulator wins'));

      final persisted = await container
          .read(chatDatabaseRepositoryProvider)
          .loadConversation(chatA.id, preferred: ChatStorageKind.directLocal);
      final persistedAssistant = persisted!.conversation.messages.singleWhere(
        (message) => message.id == assistantId,
      );
      expect(persistedAssistant.isStreaming, isFalse);
      expect(persistedAssistant.content, contains('done="true"'));
      expect(persistedAssistant.content, endsWith('Accumulator wins'));
      expect(
        parseConduitDirectReplayOutput(persistedAssistant.output!)?.text,
        'Accumulator wins',
      );
      expect(
        persistedAssistant
            .metadata?[kConduitDirectRawAssistantContentMetadataKey],
        'Accumulator wins',
      );
    },
  );

  test(
    'direct completion persists in its owner chat while another chat is open',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final adapter = _GatedAdapter();
      addTearDown(adapter.dispose);
      final chatA = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:background-a',
        modelId: model.id,
        suffix: 'background-a',
      );
      final chatB = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:background-b',
        modelId: model.id,
        suffix: 'background-b',
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseProvider.overrideWithValue(db),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(chatA);
      container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);

      final started = adapter.nextRun();
      final send = sendMessageWithContainer(container, 'Background turn', null);
      final run = await started.timeout(const Duration(seconds: 1));
      final assistantId = container.read(chatMessagesProvider).last.id;
      run.add(const DirectContentDelta('Background answer'));
      await Future<void>.delayed(Duration.zero);

      container.read(activeConversationProvider.notifier).set(chatB);
      await Future<void>.delayed(Duration.zero);
      run.add(const DirectStreamDone());
      await run.close();
      await send.timeout(const Duration(seconds: 1));

      expect(container.read(activeConversationProvider)?.id, chatB.id);
      expect(
        container.read(chatMessagesProvider).map((message) => message.id),
        chatB.messages.map((message) => message.id),
      );
      final persisted = await container
          .read(chatDatabaseRepositoryProvider)
          .loadConversation(chatA.id, preferred: ChatStorageKind.directLocal);
      final persistedAssistant = persisted!.conversation.messages.singleWhere(
        (message) => message.id == assistantId,
      );
      expect(persistedAssistant.isStreaming, isFalse);
      expect(persistedAssistant.content, 'Background answer');
    },
  );

  test(
    'late direct send failure retains its assistant id across a chat switch',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final adapter = _GatedAdapter();
      addTearDown(adapter.dispose);
      final chatA = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:failure-a',
        modelId: model.id,
        suffix: 'failure-a',
      );
      final chatB = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:failure-b',
        modelId: model.id,
        suffix: 'failure-b',
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseProvider.overrideWithValue(db),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(chatA);
      container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);

      ChatSendPlaceholderHandle? pendingSend;
      final started = adapter.nextRun();
      final send = durableSend(
        container,
        'Fail in A',
        null,
        onAssistantPlaceholderCreated: (handle) => pendingSend = handle,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      expect(pendingSend, isNotNull);

      final streamingB = chatB.messages.last.copyWith(
        id: pendingSend!.assistantMessageId,
        isStreaming: true,
      );
      container.read(activeConversationProvider.notifier).set(chatB);
      container.read(chatMessagesProvider.notifier).setMessages([
        ...chatB.messages.take(chatB.messages.length - 1),
        streamingB,
      ]);

      final failure = StateError('late chat A stream failure');
      run.addError(failure);
      await run.close();
      await expectLater(
        send,
        throwsA(
          isA<DirectProviderException>().having(
            (error) => error.message,
            'message',
            'The provider request failed.',
          ),
        ),
      );

      // Mirrors ChatPage's recovery boundary: the failure may only address
      // the placeholder reported by this exact send, never chat B's tail.
      recoverFailedChatSend(container, failure, pendingSend);

      final visible = container.read(chatMessagesProvider).last;
      expect(visible.id, streamingB.id);
      expect(visible.isStreaming, isTrue);
      expect(visible.error, isNull);
      container.read(chatMessagesProvider.notifier).clearMessages();
    },
  );

  test(
    'post-write persistence failure cannot overwrite the accumulator snapshot',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = _ThrowAfterCompletionPersistRepository(db);
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final adapter = _GatedAdapter();
      addTearDown(adapter.dispose);
      final chat = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:persist-after-write',
        modelId: model.id,
        suffix: 'persist-after-write',
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseProvider.overrideWithValue(db),
          chatDatabaseRepositoryProvider.overrideWithValue(repository),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(chat);
      container.read(chatMessagesProvider.notifier).setMessages(chat.messages);

      final started = adapter.nextRun();
      final send = sendMessageWithContainer(container, 'Persist once', null);
      final run = await started.timeout(const Duration(seconds: 1));
      final assistantId = container.read(chatMessagesProvider).last.id;
      run.add(const DirectContentDelta('Authoritative accumulator'));
      run.add(const DirectStreamDone());
      await run.close();

      await expectLater(send, throwsA(isA<StateError>()));
      final rows = await db.messagesDao.getForChat(chat.id);
      final persisted = rows.singleWhere((row) => row.id == assistantId);
      expect(persisted.content, 'Authoritative accumulator');
      expect(repository.persistCalls, 2);
    },
  );

  test(
    'stop settles partial output when adapter never closes or finishes',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final adapter = _GatedAdapter();
      addTearDown(adapter.dispose);
      final chat = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:hostile-stop',
        modelId: model.id,
        suffix: 'hostile-stop',
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseProvider.overrideWithValue(db),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(chat);
      container.read(chatMessagesProvider.notifier).setMessages(chat.messages);

      final started = adapter.nextRun();
      final send = sendMessageWithContainer(
        container,
        'Stop hostile run',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      addTearDown(run.close);
      run.add(const DirectContentDelta('Partial answer'));
      await Future<void>.delayed(Duration.zero);

      container.read(stopGenerationProvider)();
      await send.timeout(const Duration(seconds: 1));

      final completed = container.read(chatMessagesProvider).last;
      expect(completed.content, 'Partial answer');
      expect(completed.isStreaming, isFalse);
      expect(run.run.isCancelled, isTrue);
      final persisted = (await db.messagesDao.getForChat(
        chat.id,
      )).singleWhere((row) => row.id == completed.id);
      expect(persisted.content, 'Partial answer');
    },
  );

  test(
    'done event settles without provider EOF and ignores late events',
    () async {
      final harness = await _createGatedDirectHarness('done-without-eof');
      final started = harness.adapter.nextRun();
      final send = sendMessageWithContainer(
        harness.container,
        'Finish at terminal event',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      addTearDown(run.close);

      run.add(const DirectContentDelta('Final answer'));
      run.add(const DirectStreamDone());
      await send.timeout(const Duration(seconds: 1));

      run.add(const DirectContentDelta(' late corruption'));
      run.add(const DirectStreamError('late error'));
      await Future<void>.delayed(Duration.zero);

      final completed = harness.container.read(chatMessagesProvider).last;
      expect(completed.content, 'Final answer');
      expect(completed.error, isNull);
      expect(completed.isStreaming, isFalse);
      expect(run.run.isCancelled, isTrue);
      final persisted = (await harness.db.messagesDao.getForChat(
        harness.chat.id,
      )).singleWhere((row) => row.id == completed.id);
      expect(persisted.content, 'Final answer');
    },
  );

  test(
    'error event settles without provider EOF and ignores late events',
    () async {
      final harness = await _createGatedDirectHarness('error-without-eof');
      final started = harness.adapter.nextRun();
      final send = sendMessageWithContainer(
        harness.container,
        'Fail at terminal event',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      addTearDown(run.close);

      run.add(const DirectContentDelta('Safe partial'));
      run.add(const DirectStreamError('provider failed'));
      await send.timeout(const Duration(seconds: 1));

      run.add(const DirectContentDelta(' late corruption'));
      run.add(const DirectStreamDone());
      await Future<void>.delayed(Duration.zero);

      final completed = harness.container.read(chatMessagesProvider).last;
      expect(completed.content, 'Safe partial');
      expect(completed.error?.content, 'provider failed');
      expect(completed.isStreaming, isFalse);
      final persisted = (await harness.db.messagesDao.getForChat(
        harness.chat.id,
      )).singleWhere((row) => row.id == completed.id);
      expect(persisted.content, 'Safe partial');
    },
  );

  test('provider EOF without a terminal event is a protocol failure', () async {
    final harness = await _createGatedDirectHarness('eof-without-terminal');
    final started = harness.adapter.nextRun();
    final send = sendMessageWithContainer(
      harness.container,
      'Reject clean EOF',
      null,
    );
    final run = await started.timeout(const Duration(seconds: 1));
    run.add(const DirectContentDelta('Unconfirmed partial'));
    await run.close();

    await expectLater(
      send.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<DirectProviderException>().having(
          (error) => error.message,
          'message',
          contains('terminal event'),
        ),
      ),
    );
    final completed = harness.container.read(chatMessagesProvider).last;
    expect(completed.content, 'Unconfirmed partial');
    expect(completed.error?.content, contains('terminal event'));
    expect(completed.isStreaming, isFalse);
  });

  test(
    'stop between request creation and registration never awaits run.done',
    () async {
      final harness = await _createGatedDirectHarness(
        'stop-before-register',
        onStart: (container) => container.read(stopGenerationProvider)(),
      );
      final started = harness.adapter.nextRun();
      final send = sendMessageWithContainer(
        harness.container,
        'Stop before register',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      addTearDown(run.close);

      await send.timeout(const Duration(seconds: 1));

      expect(run.run.isCancelled, isTrue);
      expect(
        harness.container.read(chatMessagesProvider).last.isStreaming,
        isFalse,
      );
    },
  );

  test(
    'registered runtime adapter observes run.done rejection immediately',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final profile = DirectConnectionProfile(
        id: 'early-done-profile',
        name: 'Early done provider',
        adapterKey: 'early-rejecting-done-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(
        profile,
        <DirectRemoteModel>[DirectRemoteModel(id: 'model')],
      ).single;
      final adapter = _EarlyRejectingDoneAdapter();
      addTearDown(adapter.events.close);
      final chat = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:early-done',
        modelId: model.id,
        suffix: 'early-done',
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseProvider.overrideWithValue(db),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry(<DirectProviderAdapter>[adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(chat);
      container.read(chatMessagesProvider.notifier).setMessages(chat.messages);
      final uncaught = <Object>[];

      await runZonedGuarded(() async {
        final send = sendMessageWithContainer(
          container,
          'Observe cleanup independently',
          null,
        );
        await adapter.started.future.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(Duration.zero);
        adapter.events
          ..add(const DirectContentDelta('Safe answer'))
          ..add(const DirectStreamDone());
        await send.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(Duration.zero);
      }, (error, stackTrace) => uncaught.add(error));

      expect(uncaught, isEmpty);
      final completed = container.read(chatMessagesProvider).last;
      expect(completed.content, 'Safe answer');
      expect(completed.isStreaming, isFalse);
    },
  );

  test('done-only direct response finalizes as a provider error', () async {
    final harness = await _createGatedDirectHarness('done-only');
    final started = harness.adapter.nextRun();
    final send = sendMessageWithContainer(
      harness.container,
      'Reject empty response',
      null,
    );
    final run = await started.timeout(const Duration(seconds: 1));
    addTearDown(run.close);

    run.add(const DirectStreamDone());
    await send.timeout(const Duration(seconds: 1));

    final completed = harness.container.read(chatMessagesProvider).last;
    expect(completed.content, isEmpty);
    expect(completed.error?.content, contains('no usable completion'));
    expect(completed.isStreaming, isFalse);
  });

  test(
    'reasoning-only direct response persists a safe replay sentinel',
    () async {
      final harness = await _createGatedDirectHarness('reasoning-only');
      final started = harness.adapter.nextRun();
      final send = sendMessageWithContainer(
        harness.container,
        'Reject reasoning-only response',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      addTearDown(run.close);

      run.add(const DirectReasoningDelta('Private provider reasoning'));
      run.add(const DirectStreamDone());
      await send.timeout(const Duration(seconds: 1));

      final completed = harness.container.read(chatMessagesProvider).last;
      expect(completed.content, contains('Private provider reasoning'));
      expect(completed.error, isNull);
      expect(
        parseConduitDirectReplayOutput(
          completed.output!,
        )?.isIncompleteAnswerSentinel,
        isTrue,
      );
      expect(
        completed.metadata?[kConduitDirectRawAssistantContentMetadataKey],
        isEmpty,
      );
      expect(
        outboundProviderReplayText(completed),
        kConduitDirectIncompleteAnswerReplayText,
      );
    },
  );

  test('whitespace-only direct response preserves bytes but fails', () async {
    final harness = await _createGatedDirectHarness('whitespace-only');
    final started = harness.adapter.nextRun();
    final send = sendMessageWithContainer(
      harness.container,
      'Reject whitespace response',
      null,
    );
    final run = await started.timeout(const Duration(seconds: 1));
    addTearDown(run.close);

    run.add(const DirectContentDelta(' \n\t '));
    run.add(const DirectStreamDone());
    await send.timeout(const Duration(seconds: 1));

    final completed = harness.container.read(chatMessagesProvider).last;
    expect(completed.content, ' \n\t ');
    expect(completed.error?.content, contains('no usable completion'));
    expect(completed.isStreaming, isFalse);
  });

  test(
    'whitespace prefix is accepted once direct output becomes usable',
    () async {
      final harness = await _createGatedDirectHarness('whitespace-prefix');
      final started = harness.adapter.nextRun();
      final send = sendMessageWithContainer(
        harness.container,
        'Keep whitespace prefix',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      addTearDown(run.close);

      run.add(const DirectContentDelta('  '));
      run.add(const DirectContentDelta('answer'));
      run.add(const DirectStreamDone());
      await send.timeout(const Duration(seconds: 1));

      final completed = harness.container.read(chatMessagesProvider).last;
      expect(completed.content, '  answer');
      expect(completed.error, isNull);
      expect(completed.isStreaming, isFalse);
    },
  );

  test('normalized direct output enforces its character budget', () async {
    final harness = await _createGatedDirectHarness(
      'normalized-character-budget',
      streamLimits: const DirectNormalizedStreamLimits(
        idleTimeout: Duration(seconds: 1),
        maxDuration: Duration(seconds: 2),
        maxCharacters: 5,
        maxEvents: 10,
      ),
    );
    final started = harness.adapter.nextRun();
    final send = sendMessageWithContainer(
      harness.container,
      'Bound normalized characters',
      null,
    );
    final run = await started.timeout(const Duration(seconds: 1));
    addTearDown(run.close);

    run.add(const DirectContentDelta('12345'));
    run.add(const DirectContentDelta('6'));

    await expectLater(
      send.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<DirectProviderException>().having(
          (error) => error.message,
          'message',
          contains('size limit'),
        ),
      ),
    );
    final completed = harness.container.read(chatMessagesProvider).last;
    expect(completed.content, '12345');
    expect(completed.error?.content, contains('size limit'));
    expect(completed.isStreaming, isFalse);
  });

  test('normalized direct output enforces its event budget', () async {
    final harness = await _createGatedDirectHarness(
      'normalized-event-budget',
      streamLimits: const DirectNormalizedStreamLimits(
        idleTimeout: Duration(seconds: 1),
        maxDuration: Duration(seconds: 2),
        maxCharacters: 100,
        maxEvents: 2,
      ),
    );
    final started = harness.adapter.nextRun();
    final send = sendMessageWithContainer(
      harness.container,
      'Bound normalized events',
      null,
    );
    final run = await started.timeout(const Duration(seconds: 1));
    addTearDown(run.close);

    run.add(const DirectContentDelta('a'));
    run.add(const DirectContentDelta('b'));
    run.add(const DirectContentDelta('c'));

    await expectLater(
      send.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<DirectProviderException>().having(
          (error) => error.message,
          'message',
          contains('resource limit'),
        ),
      ),
    );
    final completed = harness.container.read(chatMessagesProvider).last;
    expect(completed.content, 'ab');
    expect(completed.error?.content, contains('resource limit'));
    expect(completed.isStreaming, isFalse);
  });

  test(
    'normalized direct idle timeout detaches hostile cancellation',
    () async {
      final harness = await _createGatedDirectHarness(
        'normalized-idle-timeout',
        hostileCancellation: true,
        streamLimits: const DirectNormalizedStreamLimits(
          idleTimeout: Duration(milliseconds: 30),
          maxDuration: Duration(seconds: 2),
          maxCharacters: 100,
          maxEvents: 100,
        ),
      );
      final started = harness.adapter.nextRun();
      final send = sendMessageWithContainer(
        harness.container,
        'Timeout hostile adapter',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      addTearDown(run.close);

      await expectLater(
        send.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<DirectProviderException>().having(
            (error) => error.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
      final completed = harness.container.read(chatMessagesProvider).last;
      expect(completed.error?.content, contains('timed out'));
      expect(completed.isStreaming, isFalse);
      expect(run.run.isCancelled, isTrue);
    },
  );

  test('normalized direct stream enforces an absolute deadline', () async {
    final harness = await _createGatedDirectHarness(
      'normalized-absolute-timeout',
      streamLimits: const DirectNormalizedStreamLimits(
        idleTimeout: Duration(milliseconds: 250),
        maxDuration: Duration(milliseconds: 60),
        maxCharacters: 1000,
        maxEvents: 1000,
      ),
    );
    final started = harness.adapter.nextRun();
    final send = sendMessageWithContainer(
      harness.container,
      'Enforce absolute timeout',
      null,
    );
    final run = await started.timeout(const Duration(seconds: 1));
    addTearDown(run.close);
    final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
      run.add(const DirectContentDelta('x'));
    });
    addTearDown(ticker.cancel);

    await expectLater(
      send.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<DirectProviderException>().having(
          (error) => error.message,
          'message',
          contains('time limit'),
        ),
      ),
    );
    ticker.cancel();
    final completed = harness.container.read(chatMessagesProvider).last;
    expect(completed.content, isNotEmpty);
    expect(completed.error?.content, contains('time limit'));
    expect(completed.isStreaming, isFalse);
  });

  test('normalized direct usage rejects cyclic metadata', () async {
    final harness = await _createGatedDirectHarness('normalized-cyclic-usage');
    final started = harness.adapter.nextRun();
    final send = sendMessageWithContainer(
      harness.container,
      'Reject cyclic usage',
      null,
    );
    final run = await started.timeout(const Duration(seconds: 1));
    addTearDown(run.close);
    final cycle = <Object?>[];
    cycle.add(cycle);

    run.add(DirectUsageUpdate({'cycle': cycle}));

    await expectLater(
      send.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<DirectProviderException>().having(
          (error) => error.message,
          'message',
          contains('usage metadata'),
        ),
      ),
    );
    final completed = harness.container.read(chatMessagesProvider).last;
    expect(completed.usage, isNull);
    expect(completed.error?.content, contains('usage metadata'));
    expect(completed.isStreaming, isFalse);
  });

  test('repeated direct usage strings exhaust the run-wide budget', () async {
    final harness = await _createGatedDirectHarness(
      'normalized-usage-character-budget',
      streamLimits: const DirectNormalizedStreamLimits(
        idleTimeout: Duration(seconds: 1),
        maxDuration: Duration(seconds: 2),
        maxCharacters: 5,
        maxEvents: 10,
        maxWorkUnits: 100,
      ),
    );
    final started = harness.adapter.nextRun();
    final send = sendMessageWithContainer(
      harness.container,
      'Bound repeated usage strings',
      null,
    );
    final run = await started.timeout(const Duration(seconds: 1));
    addTearDown(run.close);

    for (var index = 0; index < 3; index++) {
      run.add(DirectUsageUpdate(const {'a': 'b'}));
    }

    await expectLater(
      send.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<DirectProviderException>().having(
          (error) => error.message,
          'message',
          contains('size limit'),
        ),
      ),
    );
    final completed = harness.container.read(chatMessagesProvider).last;
    expect(completed.usage, const {'a': 'b'});
    expect(completed.error?.content, contains('size limit'));
    expect(completed.isStreaming, isFalse);
  });

  test(
    'repeated direct usage nodes exhaust the run-wide work budget',
    () async {
      final harness = await _createGatedDirectHarness(
        'normalized-usage-work-budget',
        streamLimits: const DirectNormalizedStreamLimits(
          idleTimeout: Duration(seconds: 1),
          maxDuration: Duration(seconds: 2),
          maxCharacters: 100,
          maxEvents: 10,
          maxWorkUnits: 5,
        ),
      );
      final started = harness.adapter.nextRun();
      final send = sendMessageWithContainer(
        harness.container,
        'Bound repeated usage nodes',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      addTearDown(run.close);

      run.add(
        DirectUsageUpdate(const {
          '': <Object?>[null],
        }),
      );
      run.add(
        DirectUsageUpdate(const {
          '': <Object?>[null],
        }),
      );

      await expectLater(
        send.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<DirectProviderException>().having(
            (error) => error.message,
            'message',
            contains('resource limit'),
          ),
        ),
      );
      final completed = harness.container.read(chatMessagesProvider).last;
      expect(completed.usage, const {
        '': <Object?>[null],
      });
      expect(completed.error?.content, contains('resource limit'));
      expect(completed.isStreaming, isFalse);
    },
  );

  test(
    'normalized direct errors are bounded and redact every profile secret',
    () async {
      const apiSecret = 'api-secret-value';
      const headerSecret = 'header-secret-value';
      const cookieSecret = 'cookie-component-secret';
      const csrfSecret = 'csrf-component-secret';
      const authorizationSecret = 'authorization-component-secret';
      const quotedHeaderSecret = 'quoted-header-component-secret';
      const certificateSecret = 'certificate-body-secret';
      const certificateLabelSecret = 'certificate-label-secret';
      const privateKeySecret = 'private-key-body-secret';
      const privateKeyLabelSecret = 'private-key-label-secret';
      const privateKeyPasswordSecret = 'private-key-password-secret';
      final harness = await _createGatedDirectHarness(
        'normalized-provider-error',
        profileBaseUrl: 'https://provider.example.test/v1',
        profileApiKey: apiSecret,
        profileHeaders: const {
          'X-Private': headerSecret,
          'Cookie': 'session=$cookieSecret; csrf=$csrfSecret',
          'X-Authorization-Context': 'Bearer $authorizationSecret',
          'X-Quoted-Credential': '"$quotedHeaderSecret"',
        },
        profileMtlsCertificateChainPem:
            '-----BEGIN CERTIFICATE-----\n$certificateSecret\n'
            '-----END CERTIFICATE-----',
        profileMtlsCertificateLabel: certificateLabelSecret,
        profileMtlsPrivateKeyPem:
            '-----BEGIN PRIVATE KEY-----\n$privateKeySecret\n'
            '-----END PRIVATE KEY-----',
        profileMtlsPrivateKeyLabel: privateKeyLabelSecret,
        profileMtlsPrivateKeyPassword: privateKeyPasswordSecret,
      );
      final started = harness.adapter.nextRun();
      final send = sendMessageWithContainer(
        harness.container,
        'Sanitize custom adapter errors',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      addTearDown(run.close);

      run.add(
        DirectStreamError(
          '$apiSecret $headerSecret $cookieSecret $csrfSecret '
          '$authorizationSecret $quotedHeaderSecret $certificateSecret '
          '$certificateLabelSecret $privateKeySecret $privateKeyLabelSecret '
          '$privateKeyPasswordSecret ${List.filled(700, 'x').join()}',
        ),
      );
      await send.timeout(const Duration(seconds: 1));

      final completed = harness.container.read(chatMessagesProvider).last;
      final error = completed.error?.content;
      expect(error, isNotNull);
      for (final secret in const [
        apiSecret,
        headerSecret,
        cookieSecret,
        csrfSecret,
        authorizationSecret,
        quotedHeaderSecret,
        certificateSecret,
        certificateLabelSecret,
        privateKeySecret,
        privateKeyLabelSecret,
        privateKeyPasswordSecret,
      ]) {
        expect(error, isNot(contains(secret)));
      }
      expect(
        error!.runes.length,
        lessThanOrEqualTo(kMaxDirectProviderErrorCharacters),
      );
      expect(completed.isStreaming, isFalse);
      final persisted = await harness.container
          .read(chatDatabaseRepositoryProvider)
          .loadConversation(
            harness.chat.id,
            preferred: ChatStorageKind.directLocal,
          );
      final durableAssistant = persisted!.conversation.messages.singleWhere(
        (message) => message.id == completed.id,
      );
      final durableJson = jsonEncode(durableAssistant.toJson());
      for (final secret in const [
        apiSecret,
        headerSecret,
        cookieSecret,
        csrfSecret,
        authorizationSecret,
        quotedHeaderSecret,
        certificateSecret,
        certificateLabelSecret,
        privateKeySecret,
        privateKeyLabelSecret,
        privateKeyPasswordSecret,
      ]) {
        expect(durableJson, isNot(contains(secret)));
      }
      expect(durableAssistant.error?.content, error);
    },
  );

  test(
    'stream-thrown direct failures are generic, bounded, and redacted',
    () async {
      const apiSecret = 'stream-api-secret';
      const headerSecret = 'stream-header-secret';
      const stackSecret = 'provider-controlled-stream-stack-secret';
      final harness = await _createGatedDirectHarness(
        'normalized-thrown-provider-error',
        profileApiKey: apiSecret,
        profileHeaders: const {'X-Private': headerSecret},
      );
      final started = harness.adapter.nextRun();
      final send = sendMessageWithContainer(
        harness.container,
        'Sanitize stream errors',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      addTearDown(run.close);
      run.addError(
        DirectProviderException(
          '$apiSecret $headerSecret ${List.filled(700, 'x').join()}',
        ),
        StackTrace.fromString('$stackSecret\nprovider supplied stack'),
      );

      DirectProviderException? thrown;
      StackTrace? thrownStack;
      try {
        await send.timeout(const Duration(seconds: 1));
      } on DirectProviderException catch (error, stackTrace) {
        thrown = error;
        thrownStack = stackTrace;
      }
      expect(thrown, isNotNull);
      expect(thrown!.message, isNot(contains(apiSecret)));
      expect(thrown.message, isNot(contains(headerSecret)));
      expect(
        thrown.message.runes.length,
        lessThanOrEqualTo(kMaxDirectProviderErrorCharacters),
      );
      expect(thrownStack.toString(), isNot(contains(stackSecret)));

      final completed = harness.container.read(chatMessagesProvider).last;
      expect(completed.error?.content, thrown.message);
      expect(completed.isStreaming, isFalse);
      final persisted = await harness.container
          .read(chatDatabaseRepositoryProvider)
          .loadConversation(
            harness.chat.id,
            preferred: ChatStorageKind.directLocal,
          );
      final persistedAssistant = persisted!.conversation.messages.singleWhere(
        (message) => message.id == completed.id,
      );
      final encoded = jsonEncode(persistedAssistant.toJson());
      expect(encoded, isNot(contains(apiSecret)));
      expect(encoded, isNot(contains(headerSecret)));
      expect(persistedAssistant.error?.content, thrown.message);
    },
  );

  test('synchronous adapter start failures are bounded and redacted', () async {
    const apiSecret = 'start-api-secret';
    const headerSecret = 'start-header-secret';
    const stackSecret = 'provider-controlled-start-stack-secret';
    final rawFailure =
        '$apiSecret $headerSecret ${List.filled(700, 'x').join()}';
    final harness = await _createGatedDirectHarness(
      'normalized-start-provider-error',
      profileApiKey: apiSecret,
      profileHeaders: const {'X-Private': headerSecret},
      startError: DirectProviderException(rawFailure),
      startErrorStack: StackTrace.fromString(
        '$stackSecret\nprovider supplied stack',
      ),
    );

    DirectProviderException? thrown;
    StackTrace? thrownStack;
    try {
      await sendMessageWithContainer(
        harness.container,
        'Sanitize start errors',
        null,
      ).timeout(const Duration(seconds: 1));
    } on DirectProviderException catch (error, stackTrace) {
      thrown = error;
      thrownStack = stackTrace;
    }
    expect(thrown, isNotNull);
    expect(thrown!.message, isNot(contains(apiSecret)));
    expect(thrown.message, isNot(contains(headerSecret)));
    expect(
      thrown.message.runes.length,
      lessThanOrEqualTo(kMaxDirectProviderErrorCharacters),
    );
    expect(thrownStack.toString(), isNot(contains(stackSecret)));
    final persisted = await harness.container
        .read(chatDatabaseRepositoryProvider)
        .loadConversation(
          harness.chat.id,
          preferred: ChatStorageKind.directLocal,
        );
    final persistedAssistant = persisted!.conversation.messages.last;
    expect(persistedAssistant.error?.content, thrown.message);
    final completed = harness.container.read(chatMessagesProvider).last;
    expect(completed.error?.content, thrown.message);
    expect(completed.isStreaming, isFalse);
  });

  test('OpenWebUI auth epoch changes do not stop direct-local runs', () async {
    final epochState = NotifierProvider<_EpochState, Object>(
      () => _EpochState(Object()),
    );
    final harness = await _createGatedDirectHarness(
      'direct-local-auth-rotation',
      authEpochState: epochState,
    );
    final started = harness.adapter.nextRun();
    final send = sendMessageWithContainer(
      harness.container,
      'Continue locally',
      null,
    );
    final run = await started.timeout(const Duration(seconds: 1));
    addTearDown(run.close);

    harness.container.read(epochState.notifier).rotate();
    run.add(const DirectContentDelta('Local answer'));
    run.add(const DirectStreamDone());
    await send.timeout(const Duration(seconds: 1));

    final completed = harness.container.read(chatMessagesProvider).last;
    expect(completed.content, 'Local answer');
    expect(completed.error, isNull);
    expect(completed.isStreaming, isFalse);
  });

  test(
    'direct turn start aborts before writing through a closing managed database',
    () async {
      final manager = DatabaseManager(
        openDatabase: (_) => GatedCloseDatabase.memory(failClose: false),
      );
      final database =
          manager.openForServerId('closing-turn-start') as GatedCloseDatabase;
      final closeGate = Completer<void>();
      database.closeGate = closeGate;
      final profile = DirectConnectionProfile(
        id: 'closing-profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final adapter = _Adapter();
      final chat = await _seedDirectConversation(
        db: database,
        chatId: 'direct-local:closing-turn-start',
        modelId: model.id,
        suffix: 'closing-turn-start',
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseManagerProvider.overrideWithValue(manager),
          directLocalDatabaseProvider.overrideWithValue(database),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() async {
        if (!closeGate.isCompleted) closeGate.complete();
        await manager.closeActive();
      });
      container.read(activeConversationProvider.notifier).set(chat);
      container.read(chatMessagesProvider.notifier).setMessages(chat.messages);

      final close = manager.closeActive();
      await database.closeStarted.future.timeout(const Duration(seconds: 1));

      await expectLater(
        sendMessageWithContainer(container, 'Must not be written', null),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('database is closing'),
          ),
        ),
      );
      expect(adapter.startCalls, 0);
      final rows = await database.messagesDao.getForChat(chat.id);
      expect(
        rows.where((row) => row.content == 'Must not be written'),
        isEmpty,
      );

      closeGate.complete();
      await close.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'OpenWebUI auth revocation detaches a silent direct run and releases its lease',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'conduit_direct_auth_revoke_',
      );
      final manager = DatabaseManager(
        databaseDirectory: () async => directory,
        openDatabase: (fileName) => AppDatabase(
          NativeDatabase(File(p.join(directory.path, '$fileName.sqlite'))),
        ),
      );
      addTearDown(() async {
        await manager.closeActive();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      const serverA = ServerConfig(
        id: 'auth-revoke-a',
        name: 'Server A',
        url: 'https://a.example.test',
      );
      const serverB = ServerConfig(
        id: 'auth-revoke-b',
        name: 'Server B',
        url: 'https://b.example.test',
      );
      final databaseA = manager.openFor(serverA);
      final directLocal = AppDatabase(NativeDatabase.memory());
      addTearDown(directLocal.close);
      final repository = ChatDatabaseRepository(
        openWebUiDatabase: databaseA,
        directLocalDatabase: directLocal,
      );
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final adapter = _GatedAdapter(hostileCancellation: true);
      addTearDown(adapter.dispose);
      final chat = withChatStorageProvenance(
        await _seedDirectConversation(
          db: databaseA,
          chatId: 'auth-revoke-chat',
          modelId: model.id,
          suffix: 'auth-revoke-a',
        ),
        ChatStorageKind.openWebUi,
      );
      final epochState = NotifierProvider<_EpochState, Object>(
        () => _EpochState(Object()),
      );
      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith((_) async => serverA),
          databaseManagerProvider.overrideWithValue(manager),
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(databaseA),
          directLocalDatabaseProvider.overrideWithValue(directLocal),
          chatDatabaseRepositoryProvider.overrideWithValue(repository),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(epochState),
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set(serverA.id);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      container.read(activeConversationProvider.notifier).set(chat);
      container.read(chatMessagesProvider.notifier).setMessages(chat.messages);

      final started = adapter.nextRun();
      final send = sendMessageWithContainer(
        container,
        'Wait forever unless auth revokes ownership',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      addTearDown(run.close);

      final databaseB = manager.openFor(serverB);
      expect(await databaseB.customSelect('SELECT 1').get(), isNotEmpty);
      expect(await databaseA.customSelect('SELECT 1').get(), isNotEmpty);

      container.read(epochState.notifier).rotate();
      await send.timeout(const Duration(seconds: 1));

      expect(run.run.isCancelled, isTrue);
      await _waitForDatabaseClosed(databaseA);
    },
  );

  test(
    'hidden OpenWebUI direct final write keeps its leased database alive',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'conduit_direct_lease_',
      );
      final manager = DatabaseManager(
        databaseDirectory: () async => directory,
        openDatabase: (fileName) => AppDatabase(
          NativeDatabase(File(p.join(directory.path, '$fileName.sqlite'))),
        ),
      );
      addTearDown(() async {
        await manager.closeActive();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      const serverA = ServerConfig(
        id: 'server-a',
        name: 'Server A',
        url: 'https://a.example.test',
      );
      const serverB = ServerConfig(
        id: 'server-b',
        name: 'Server B',
        url: 'https://b.example.test',
      );
      final databaseA = manager.openFor(serverA);
      final directLocal = AppDatabase(NativeDatabase.memory());
      addTearDown(directLocal.close);
      const finalContent = 'Leased final from A';
      final repository = _GatedCompletionPersistRepository(
        openWebUiDatabase: databaseA,
        directLocalDatabase: directLocal,
        finalContent: finalContent,
      );
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final adapter = _GatedAdapter();
      addTearDown(adapter.dispose);
      final chatA = withChatStorageProvenance(
        await _seedDirectConversation(
          db: databaseA,
          chatId: 'shared-chat',
          modelId: model.id,
          suffix: 'lease-a',
        ),
        ChatStorageKind.openWebUi,
      );
      final chatB = withChatStorageProvenance(
        Conversation(
          id: 'chat-b',
          title: 'Chat B',
          createdAt: DateTime.utc(2026, 7, 13),
          updatedAt: DateTime.utc(2026, 7, 13),
          messages: [
            ChatMessage(
              id: 'b-message',
              role: 'assistant',
              content: 'B must not change',
              timestamp: DateTime.utc(2026, 7, 13),
            ),
          ],
        ),
        ChatStorageKind.openWebUi,
      );
      final runRegistry = DirectRunRegistry();
      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith((_) async => serverA),
          databaseManagerProvider.overrideWithValue(manager),
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(databaseA),
          directLocalDatabaseProvider.overrideWithValue(directLocal),
          chatDatabaseRepositoryProvider.overrideWithValue(repository),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directRunRegistryProvider.overrideWithValue(runRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set(serverA.id);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      container.read(activeConversationProvider.notifier).set(chatA);
      container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);

      final started = adapter.nextRun();
      final send = sendMessageWithContainer(container, 'Question in A', null);
      final run = await started.timeout(const Duration(seconds: 1));
      final assistantId = container.read(chatMessagesProvider).last.id;
      final ownerScope = directRunOwnerScopeForTest(container, chatA);
      run.add(const DirectContentDelta(finalContent));
      run.add(const DirectStreamDone());
      await run.close();
      await repository.completionPersistStarted.future.timeout(
        const Duration(seconds: 1),
      );

      container.read(activeConversationProvider.notifier).set(chatB);
      container.read(chatMessagesProvider.notifier).setMessages(chatB.messages);
      final bBefore = jsonEncode(
        container.read(chatMessagesProvider).map((m) => m.toJson()).toList(),
      );
      final databaseB = manager.openFor(serverB);
      expect((await databaseB.customSelect('SELECT 1').get()), isNotEmpty);
      expect((await databaseA.customSelect('SELECT 1').get()), isNotEmpty);

      repository.completionPersistGate.complete();
      await send.timeout(const Duration(seconds: 2));
      expect(
        jsonEncode(
          container.read(chatMessagesProvider).map((m) => m.toJson()).toList(),
        ),
        bBefore,
      );
      expect(
        runRegistry.hasLiveIntent((
          ownerConversationId: ownerScope,
          assistantMessageId: assistantId,
        )),
        isFalse,
      );
      await _waitForDatabaseClosed(databaseA);

      final reopenedA = manager.openFor(serverA);
      expect(identical(reopenedA, databaseA), isFalse);
      final finalRow = (await reopenedA.messagesDao.getForChat(
        chatA.id,
      )).singleWhere((row) => row.id == assistantId);
      expect(finalRow.content, finalContent);
    },
  );

  test(
    'retained pre-commit final retries only in its reopened server database',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'conduit_direct_retry_',
      );
      final manager = DatabaseManager(
        databaseDirectory: () async => directory,
        openDatabase: (fileName) => AppDatabase(
          NativeDatabase(File(p.join(directory.path, '$fileName.sqlite'))),
        ),
      );
      addTearDown(() async {
        await manager.closeActive();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      const serverA = ServerConfig(
        id: 'retry-a',
        name: 'Retry A',
        url: 'https://retry-a.example.test',
      );
      const serverB = ServerConfig(
        id: 'retry-b',
        name: 'Retry B',
        url: 'https://retry-b.example.test',
      );
      final databaseA = manager.openFor(serverA);
      final directLocal = AppDatabase(NativeDatabase.memory());
      addTearDown(directLocal.close);
      final databaseState = NotifierProvider<_DatabaseState, AppDatabase?>(
        () => _DatabaseState(databaseA),
      );
      const finalContent = 'Retained final from A';
      final failure = _FailFinalPersistOnce(finalContent);
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final adapter = _GatedAdapter();
      addTearDown(adapter.dispose);
      final chatA = withChatStorageProvenance(
        await _seedDirectConversation(
          db: databaseA,
          chatId: 'same-raw-id',
          modelId: model.id,
          suffix: 'retry-a',
        ),
        ChatStorageKind.openWebUi,
      );
      final runRegistry = DirectRunRegistry();
      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith((_) async => serverA),
          databaseManagerProvider.overrideWithValue(manager),
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWith((ref) => ref.watch(databaseState)),
          directLocalDatabaseProvider.overrideWithValue(directLocal),
          chatDatabaseRepositoryProvider.overrideWith((ref) {
            final openWebUi = ref.watch(appDatabaseProvider);
            return _FailFinalPersistOnceRepository(
              openWebUiDatabase: openWebUi!,
              directLocalDatabase: ref.watch(directLocalDatabaseProvider),
              control: failure,
            );
          }),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directRunRegistryProvider.overrideWithValue(runRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set(serverA.id);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      container.read(activeConversationProvider.notifier).set(chatA);
      container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);

      final started = adapter.nextRun();
      final send = sendMessageWithContainer(container, 'Question in A', null);
      final run = await started.timeout(const Duration(seconds: 1));
      final assistantId = container.read(chatMessagesProvider).last.id;
      run.add(const DirectContentDelta(finalContent));
      run.add(const DirectStreamDone());
      await run.close();
      await expectLater(send, throwsA(isA<StateError>()));
      expect(failure.failures, 1);

      final databaseB = manager.openFor(serverB);
      container.read(databaseState.notifier).set(databaseB);
      final collidingB = withChatStorageProvenance(
        Conversation(
          id: chatA.id,
          title: 'Server B collision',
          createdAt: DateTime.utc(2026, 7, 13),
          updatedAt: DateTime.utc(2026, 7, 13),
          messages: [
            ChatMessage(
              id: assistantId,
              role: 'assistant',
              content: 'Server B sentinel',
              timestamp: DateTime.utc(2026, 7, 13),
              isStreaming: true,
              metadata: const {'transport': 'direct'},
            ),
          ],
        ),
        ChatStorageKind.openWebUi,
      );
      container.read(activeConversationProvider.notifier).set(collidingB);
      container
          .read(chatMessagesProvider.notifier)
          .setMessages(collidingB.messages);
      expect(
        container.read(chatMessagesProvider).single.content,
        'Server B sentinel',
      );
      expect(container.read(chatMessagesProvider).single.isStreaming, isTrue);
      await _waitForDatabaseClosed(databaseA);

      final reopenedA = manager.openFor(serverA);
      container.read(databaseState.notifier).set(reopenedA);
      await Future<void>.delayed(Duration.zero);
      final reloadedA = await container
          .read(chatDatabaseRepositoryProvider)
          .loadConversation(chatA.id, preferred: ChatStorageKind.openWebUi);
      expect(reloadedA, isNotNull);
      container
          .read(activeConversationProvider.notifier)
          .set(reloadedA!.withStorageMetadata);
      container
          .read(chatMessagesProvider.notifier)
          .setMessages(reloadedA.conversation.messages);

      final projected = container
          .read(chatMessagesProvider)
          .singleWhere((message) => message.id == assistantId);
      expect(projected.content, finalContent);
      expect(projected.isStreaming, isFalse);
      await _waitUntil(() async {
        final row = await reopenedA.messagesDao.getMessage(
          chatA.id,
          assistantId,
        );
        return row?.content == finalContent;
      });
      expect(
        runRegistry.retainedFinalizedOutput((
          ownerConversationId: directRunOwnerScopeForTest(
            container,
            reloadedA.withStorageMetadata,
          ),
          assistantMessageId: assistantId,
        ), serverA.id),
        isNull,
      );
    },
  );

  test(
    'retained final does not retry through a managed database that is closing',
    () async {
      final manager = DatabaseManager(
        openDatabase: (_) =>
            GatedCloseDatabase(NativeDatabase.memory(), failClose: false),
      );
      final database =
          manager.openForServerId('closing-retry-server') as GatedCloseDatabase;
      final closeGate = Completer<void>();
      final directLocal = AppDatabase(NativeDatabase.memory());
      addTearDown(() async {
        if (!closeGate.isCompleted) closeGate.complete();
        await manager.closeActive();
        await directLocal.close();
      });
      const finalContent = 'Retained while database closes';
      final failure = _FailFinalPersistOnce(finalContent);
      final repository = _FailFinalPersistOnceRepository(
        openWebUiDatabase: database,
        directLocalDatabase: directLocal,
        control: failure,
      );
      final profile = DirectConnectionProfile(
        id: 'closing-retry-profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(
        profile,
        <DirectRemoteModel>[DirectRemoteModel(id: 'model')],
      ).single;
      final adapter = _GatedAdapter();
      addTearDown(adapter.dispose);
      final runRegistry = DirectRunRegistry();
      final chat = withChatStorageProvenance(
        await _seedDirectConversation(
          db: database,
          chatId: 'closing-retry-chat',
          modelId: model.id,
          suffix: 'closing-retry',
        ),
        ChatStorageKind.openWebUi,
      );
      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (_) async => const ServerConfig(
              id: 'closing-retry-server',
              name: 'Closing retry server',
              url: 'https://closing-retry.example.test',
            ),
          ),
          databaseManagerProvider.overrideWithValue(manager),
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(database),
          directLocalDatabaseProvider.overrideWithValue(directLocal),
          chatDatabaseRepositoryProvider.overrideWithValue(repository),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directRunRegistryProvider.overrideWithValue(runRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry(<DirectProviderAdapter>[adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set('closing-retry-server');
      container.read(activeConversationProvider.notifier).set(chat);
      container.read(chatMessagesProvider.notifier).setMessages(chat.messages);

      final started = adapter.nextRun();
      final send = sendMessageWithContainer(
        container,
        'Create a retained final',
        null,
      );
      final run = await started.timeout(const Duration(seconds: 1));
      final assistantId = container.read(chatMessagesProvider).last.id;
      run
        ..add(const DirectContentDelta(finalContent))
        ..add(const DirectStreamDone());
      await run.close();
      await expectLater(send, throwsA(isA<StateError>()));
      expect(failure.attempts, 1);
      final stale = await repository.loadConversation(
        chat.id,
        preferred: ChatStorageKind.openWebUi,
      );
      expect(stale, isNotNull);

      database.closeGate = closeGate;
      final close = manager.closeActive();
      await database.closeStarted.future.timeout(const Duration(seconds: 1));
      container.read(activeConversationProvider.notifier).set(null);
      container
          .read(activeConversationProvider.notifier)
          .set(stale!.withStorageMetadata);
      container
          .read(chatMessagesProvider.notifier)
          .setMessages(stale.conversation.messages);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(failure.attempts, 1);
      expect(
        runRegistry.retainedFinalizedOutput(
          (
            ownerConversationId: directRunOwnerScopeForTest(
              container,
              stale.withStorageMetadata,
            ),
            assistantMessageId: assistantId,
          ),
          'closing-retry-server',
          authSessionEpoch: container.read(openWebUiAuthSessionEpochProvider),
        ),
        isNotNull,
      );

      closeGate.complete();
      await close.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'superseded same-id direct regeneration cannot overwrite durable output',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final adapter = _GatedAdapter();
      addTearDown(adapter.dispose);
      final chat = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:durable-generation-race',
        modelId: model.id,
        suffix: 'durable-race',
      );
      final assistantId = chat.messages.last.id;
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseProvider.overrideWithValue(db),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(chat);
      container.read(chatMessagesProvider.notifier).setMessages(chat.messages);

      final firstStarted = adapter.nextRun();
      final firstRegeneration = regenerateMessage(
        container,
        chat.messages.first.content,
        null,
      );
      final first = await firstStarted.timeout(const Duration(seconds: 1));
      first.add(const DirectContentDelta('stale durable response'));
      await Future<void>.delayed(Duration.zero);
      container.read(stopGenerationProvider)();

      final secondStarted = adapter.nextRun();
      final secondRegeneration = regenerateMessage(
        container,
        chat.messages.first.content,
        null,
      );
      final second = await secondStarted.timeout(const Duration(seconds: 1));
      second.add(const DirectContentDelta('authoritative durable response'));
      await Future<void>.delayed(Duration.zero);

      first.add(const DirectStreamDone());
      await first.close();
      await firstRegeneration.timeout(const Duration(seconds: 1));
      second.add(const DirectStreamDone());
      await second.close();
      await secondRegeneration.timeout(const Duration(seconds: 1));

      final visible = container
          .read(chatMessagesProvider)
          .singleWhere((message) => message.id == assistantId);
      expect(visible.content, 'authoritative durable response');
      expect(visible.isStreaming, isFalse);

      final reloaded = await container
          .read(chatDatabaseRepositoryProvider)
          .loadConversation(chat.id, preferred: ChatStorageKind.directLocal);
      final durable = reloaded!.conversation.messages.singleWhere(
        (message) => message.id == assistantId,
      );
      expect(durable.content, 'authoritative durable response');
      expect(durable.isStreaming, isFalse);
    },
  );
}
