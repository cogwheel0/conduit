import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/database_manager.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/local_conversation_loader.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/streaming_response_controller.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/utils/message_tree_utils.dart' as message_tree;
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit/features/chat/services/file_attachment_service.dart';
import 'package:conduit/features/direct_connections/direct_connections.dart';
import 'package:conduit/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_service.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit/features/hermes/services/hermes_session_provenance.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestActiveConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

ProviderContainer _testContainer({required List<Override> overrides}) {
  return ProviderContainer(
    overrides: [
      openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
      appDatabaseProvider.overrideWith((ref) {
        final database = AppDatabase(NativeDatabase.memory());
        ref.onDispose(() => unawaited(database.close()));
        return database;
      }),
      ...overrides,
    ],
  );
}

ChatMessage _assistantMessage({
  String id = 'assistant-1',
  String content = 'Visible response body',
  bool isStreaming = false,
  List<String> followUps = const <String>[],
  Map<String, dynamic>? metadata,
}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    timestamp: DateTime(2024, 1, 1),
    isStreaming: isStreaming,
    followUps: followUps,
    metadata: metadata,
  );
}

Conversation _conversation(String id, List<ChatMessage> messages) {
  return Conversation(
    id: id,
    title: 'Test chat',
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2024, 1, 1),
    messages: messages,
  );
}

class _StoppingHermesApi extends HermesApiService {
  _StoppingHermesApi()
    : super(
        config: const HermesConfig(enabled: true, baseUrl: 'http://hermes'),
        dio: Dio(),
      );

  final List<String> stopped = [];

  @override
  Future<void> stopRun(String runId, {CancelToken? cancelToken}) async {
    stopped.add(runId);
  }
}

final class _CountingStopApi extends ApiService {
  _CountingStopApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  int broadStops = 0;

  @override
  Future<void> stopTasksByChat(String chatId) async {
    broadStops++;
  }
}

final class _FailOnceConversationLocks extends ConversationLocks {
  var _shouldFail = true;

  @override
  Future<T> runExclusive<T>(String chatId, Future<T> Function() action) {
    if (_shouldFail) {
      _shouldFail = false;
      return Future<T>.error(StateError('transient database write failure'));
    }
    return super.runExclusive(chatId, action);
  }
}

final class _GatedSecondPersistenceLocks extends ConversationLocks {
  final firstPersistenceCompleted = Completer<void>();
  final secondPersistenceStarted = Completer<void>();
  final allowSecondPersistence = Completer<void>();
  final secondPersistenceCompleted = Completer<void>();
  final allowSecondReturn = Completer<void>();
  var _calls = 0;

  @override
  Future<T> runExclusive<T>(String chatId, Future<T> Function() action) async {
    final call = ++_calls;
    if (call == 2) {
      secondPersistenceStarted.complete();
      await allowSecondPersistence.future;
    }
    final result = await super.runExclusive(chatId, action);
    if (call == 1) {
      firstPersistenceCompleted.complete();
    } else if (call == 2) {
      secondPersistenceCompleted.complete();
      await allowSecondReturn.future;
    }
    return result;
  }
}

final class _GatedFirstHermesPersistenceLocks extends ConversationLocks {
  final started = Completer<void>();
  final allow = Completer<void>();
  var _calls = 0;

  @override
  Future<T> runExclusive<T>(String chatId, Future<T> Function() action) async {
    if (++_calls == 1) {
      started.complete();
      await allow.future;
    }
    return super.runExclusive(chatId, action);
  }
}

Future<void> _seedDurableAssistantOwner(
  AppDatabase database, {
  required String chatId,
  required ChatMessage assistant,
  bool bodySynced = false,
}) async {
  final message = MessageRowData(
    id: assistant.id,
    chatId: chatId,
    role: assistant.role,
    content: assistant.content,
    model: assistant.model,
    createdAt: assistant.timestamp.millisecondsSinceEpoch ~/ 1000,
    orderIndex: 0,
    payload: <String, dynamic>{
      'id': assistant.id,
      'role': assistant.role,
      'content': assistant.content,
      'timestamp': assistant.timestamp.millisecondsSinceEpoch ~/ 1000,
      'isStreaming': assistant.isStreaming,
      'metadata': assistant.metadata,
    },
  );
  if (bodySynced) {
    await database.chatsDao.upsertLocalOnlyChat(
      rows: ChatRows(
        chat: ChatRowData(
          id: chatId,
          title: 'Persisted chat',
          currentMessageId: assistant.id,
          createdAt: 1,
          updatedAt: 1,
        ),
        messages: <MessageRowData>[message],
        blobHadTitle: true,
        blobTitleValue: 'Persisted chat',
        blobHadHistory: true,
        historyHadMessages: true,
        historyHadCurrentId: true,
      ),
    );
    return;
  }
  await database.chatsDao.upsertEnvelopeStub(
    id: chatId,
    title: 'Persisted chat',
    createdAt: 1,
    updatedAt: 1,
  );
  await database.messagesDao.upsertLocalEcho(message);
}

class _FixedHermesConfigController extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'http://hermes',
    apiKey: 'key',
    sessionKey: 'memory',
  );

  @override
  Future<String> ensureSessionKey() async => 'memory';
}

class _GatedHermesConfigController extends HermesConfigController {
  final started = Completer<void>();
  final gate = Completer<String>();

  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'http://hermes',
    apiKey: 'key',
    sessionKey: 'memory',
  );

  @override
  Future<String> ensureSessionKey() {
    if (!started.isCompleted) started.complete();
    return gate.future;
  }
}

class _RotatableAdmissionHermesConfigController
    extends _FixedHermesConfigController {
  var _epoch = 0;

  @override
  int? captureSessionActionAdmission() => _epoch;

  @override
  bool sessionActionAdmissionIsCurrent(int admission) => admission == _epoch;

  void rotateServer() => _epoch++;
}

final class _HermesServiceGeneration extends Notifier<HermesApiService?> {
  _HermesServiceGeneration(this.initial);

  final HermesApiService? initial;

  @override
  HermesApiService? build() => initial;

  void set(HermesApiService? service) => state = service;
}

final class _HermesAuthEpoch extends Notifier<Object> {
  _HermesAuthEpoch(this.initial);

  final Object initial;

  @override
  Object build() => initial;

  void rotate() => state = Object();
}

final class _HermesDatabaseOwner extends Notifier<AppDatabase?> {
  _HermesDatabaseOwner(this.initial);

  final AppDatabase? initial;

  @override
  AppDatabase? build() => initial;

  void set(AppDatabase? database) => state = database;
}

class _SessionRecordingHermesApi extends HermesApiService {
  _SessionRecordingHermesApi({this.events, this.stopError, this.stopGate})
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'http://hermes',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  final StreamController<HermesRunEvent>? events;
  final Object? stopError;
  final Completer<void>? stopGate;
  final stopRunStarted = Completer<void>();
  final runEventsStarted = Completer<void>();
  final List<String> inputs = [];
  final List<String?> sessionIds = [];
  final List<List<Map<String, dynamic>>?> conversationHistories = [];
  final List<String> stoppedRuns = [];
  CancelToken? createRunCancelToken;
  var createSessionCalls = 0;

  @override
  Future<String> createSession({
    String? title,
    CancelToken? cancelToken,
  }) async {
    createSessionCalls++;
    return 'fresh-session';
  }

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async {
    inputs.add(input);
    sessionIds.add(sessionId);
    conversationHistories.add(conversationHistory);
    createRunCancelToken = cancelToken;
    return 'recorded-run';
  }

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) {
    if (!runEventsStarted.isCompleted) runEventsStarted.complete();
    return events?.stream ??
        Stream<HermesRunEvent>.fromIterable(const [HermesRunDone()]);
  }

  @override
  Future<void> stopRun(String runId, {CancelToken? cancelToken}) async {
    stoppedRuns.add(runId);
    if (!stopRunStarted.isCompleted) stopRunStarted.complete();
    await stopGate?.future;
    final error = stopError;
    if (error != null) throw error;
  }
}

class _SessionListingHermesApi extends _SessionRecordingHermesApi {
  var listSessionsCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> listSessions() async {
    listSessionsCalls++;
    if (createSessionCalls == 0) return const [];
    return const [
      {
        'id': 'fresh-session',
        'title': 'Brand new chat',
        'updated_at': '2026-07-16T00:00:00Z',
      },
    ];
  }
}

/// Gives each input its own controllable run stream so restoration tests can
/// retain multiple same-content snapshots for one conversation concurrently.
class _MultiRunHermesApi extends HermesApiService {
  _MultiRunHermesApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'http://hermes',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  final Map<String, StreamController<HermesRunEvent>> _eventsByRun = {};
  final Map<String, String> runIdsByInput = {};
  final twoStreamsStarted = Completer<void>();
  final fourStreamsStarted = Completer<void>();
  var _startedStreams = 0;

  @override
  Future<String> createSession({
    String? title,
    CancelToken? cancelToken,
  }) async => 'multi-run-session';

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async {
    final runId = 'run-$input';
    runIdsByInput[input] = runId;
    _eventsByRun[runId] = StreamController<HermesRunEvent>(sync: true);
    return runId;
  }

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) {
    _startedStreams++;
    if (_startedStreams == 2 && !twoStreamsStarted.isCompleted) {
      twoStreamsStarted.complete();
    }
    if (_startedStreams == 4 && !fourStreamsStarted.isCompleted) {
      fourStreamsStarted.complete();
    }
    return _eventsByRun[runId]!.stream;
  }

  void emit(String input, HermesRunEvent event) {
    _eventsByRun[runIdsByInput[input]]!.add(event);
  }

  Future<void> closeStreams() async {
    for (final controller in _eventsByRun.values) {
      await controller.close();
    }
  }
}

class _RevocationHermesApi extends HermesApiService {
  _RevocationHermesApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'http://hermes',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  final runEventsStarted = Completer<void>();
  final streamCancelled = Completer<void>();
  final List<String> stoppedRuns = <String>[];
  late final StreamController<HermesRunEvent> events =
      StreamController<HermesRunEvent>(
        sync: true,
        onCancel: () {
          if (!streamCancelled.isCompleted) streamCancelled.complete();
        },
      );
  CancelToken? runCancelToken;

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async {
    runCancelToken = cancelToken;
    return 'revoked-run';
  }

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) {
    if (!runEventsStarted.isCompleted) runEventsStarted.complete();
    return events.stream;
  }

  @override
  Future<void> stopRun(String runId, {CancelToken? cancelToken}) async {
    stoppedRuns.add(runId);
  }
}

class _PreflightHermesApi extends HermesApiService {
  _PreflightHermesApi({
    this.deleteError,
    this.deleteErrorStack,
    this.trickleDelete = false,
  }) : super(
         config: const HermesConfig(
           enabled: true,
           baseUrl: 'http://hermes',
           apiKey: 'key',
         ),
         dio: Dio(),
       );

  final createSessionStarted = Completer<void>();
  final createSessionGate = Completer<String>();
  final deleteSessionStarted = Completer<void>();
  final deleteSessionGate = Completer<void>();
  final deleteSessionSettled = Completer<void>();
  final deleteTrickleStarted = Completer<void>();
  final List<String> deletedSessions = [];
  final Object? deleteError;
  final StackTrace? deleteErrorStack;
  final bool trickleDelete;
  CancelToken? createSessionCancelToken;
  CancelToken? deleteSessionCancelToken;
  Timer? _deleteTrickleTimer;
  var deleteTrickleTicks = 0;
  var createRunCalls = 0;

  @override
  Future<String> createSession({String? title, CancelToken? cancelToken}) {
    createSessionCancelToken = cancelToken;
    createSessionStarted.complete();
    // Intentionally ignore cancellation to model a server response racing the
    // client's Stop/New Chat request.
    return createSessionGate.future;
  }

  @override
  Future<void> deleteSession(
    String sessionId, {
    CancelToken? cancelToken,
  }) async {
    deletedSessions.add(sessionId);
    deleteSessionCancelToken = cancelToken;
    deleteSessionStarted.complete();
    if (trickleDelete) {
      _deleteTrickleTimer = Timer.periodic(const Duration(milliseconds: 2), (
        _,
      ) {
        deleteTrickleTicks++;
        if (deleteTrickleTicks == 3 && !deleteTrickleStarted.isCompleted) {
          deleteTrickleStarted.complete();
        }
      });
      if (cancelToken != null) {
        unawaited(
          cancelToken.whenCancel.then<void>(
            (_) => _deleteTrickleTimer?.cancel(),
          ),
        );
      }
    }
    try {
      await deleteSessionGate.future;
      final error = deleteError;
      if (error != null) {
        final stackTrace = deleteErrorStack;
        if (stackTrace != null) Error.throwWithStackTrace(error, stackTrace);
        throw error;
      }
    } finally {
      _deleteTrickleTimer?.cancel();
      if (!deleteSessionSettled.isCompleted) deleteSessionSettled.complete();
    }
  }

  void dispose() {
    _deleteTrickleTimer?.cancel();
    if (!deleteSessionGate.isCompleted) deleteSessionGate.complete();
  }

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async {
    createRunCalls++;
    return 'unexpected-run';
  }
}

class _BranchingHermesApi extends HermesApiService {
  _BranchingHermesApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'http://hermes',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  @override
  Future<String> createSession({
    String? title,
    CancelToken? cancelToken,
  }) async => 'branch-session';

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async => 'branch-run';

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) => Stream<HermesRunEvent>.value(const HermesRunDone());
}

class _CreateRunRaceHermesApi extends HermesApiService {
  _CreateRunRaceHermesApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'http://hermes',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  final createRunStarted = Completer<void>();
  final createRunGate = Completer<String>();
  final stopRunStarted = Completer<void>();
  final stopRunGate = Completer<void>();
  final List<String> stoppedRuns = [];
  CancelToken? createRunToken;
  bool closed = false;

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) {
    createRunToken = cancelToken;
    createRunStarted.complete();
    // Model a server that commits the run despite local cancellation while its
    // response is in flight.
    return createRunGate.future;
  }

  @override
  Future<void> stopRun(String runId, {CancelToken? cancelToken}) async {
    stoppedRuns.add(runId);
    stopRunStarted.complete();
    check(closed).isFalse();
    await stopRunGate.future;
  }

  @override
  void close() {
    closed = true;
  }
}

class _ResponsesHermesApi extends HermesApiService {
  _ResponsesHermesApi({
    this.uniqueSessionIds = false,
    this.establishedSessionIdOverride,
  }) : super(
         config: const HermesConfig(
           enabled: true,
           baseUrl: 'http://hermes',
           apiKey: 'key',
         ),
         dio: Dio(),
       );

  final bool uniqueSessionIds;
  final String? establishedSessionIdOverride;

  final List<HermesChatInput> inputs = [];
  final List<String?> sessionIds = [];
  final List<String?> previousResponseIds = [];
  final List<List<Map<String, dynamic>>?> histories = [];
  final Map<String, List<Map<String, dynamic>>> committedUserMessagesBySession =
      {};
  var createRunCalls = 0;
  var createSessionCalls = 0;
  var responseCreatedSessionCalls = 0;
  var failNextResponse = false;

  List<Map<String, dynamic>> get committedUserMessages => [
    for (final messages in committedUserMessagesBySession.values) ...messages,
  ];

  @override
  Future<String> createSession({
    String? title,
    CancelToken? cancelToken,
  }) async {
    createSessionCalls++;
    return uniqueSessionIds
        ? 'responses-session-$createSessionCalls'
        : 'responses-session';
  }

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async {
    createRunCalls++;
    return 'unexpected-run';
  }

  @override
  Future<HermesResponseStream> streamResponse(
    HermesChatInput input, {
    String? instructions,
    String? sessionId,
    String? conversation,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async {
    if (failNextResponse) {
      failNextResponse = false;
      throw StateError('response rejected before acceptance');
    }
    inputs.add(input);
    sessionIds.add(sessionId);
    previousResponseIds.add(previousResponseId);
    histories.add(conversationHistory);
    if (sessionId == null) responseCreatedSessionCalls++;
    final committedSessionId =
        establishedSessionIdOverride ??
        sessionId ??
        (uniqueSessionIds
            ? 'responses-session-$responseCreatedSessionCalls'
            : 'responses-session');
    final sessionMessages = committedUserMessagesBySession.putIfAbsent(
      committedSessionId,
      () => <Map<String, dynamic>>[],
    );
    sessionMessages.add(<String, dynamic>{
      'id': 'server-user-${committedUserMessages.length + 1}',
      'role': 'user',
      'content': input.toJson(),
    });
    final responseId = 'resp-${inputs.length}';
    return HermesResponseStream(
      sessionId: committedSessionId,
      events: Stream<HermesRunEvent>.fromIterable([
        HermesResponseCreated(responseId),
        HermesTokenDelta('answer ${inputs.length}'),
        HermesFinalOutput('answer ${inputs.length}'),
        const HermesRunDone(),
      ]),
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String sessionId, {
    CancelToken? cancelToken,
  }) async => List<Map<String, dynamic>>.unmodifiable(
    (committedUserMessagesBySession[sessionId] ?? const []).map(
      Map<String, dynamic>.from,
    ),
  );
}

class _ResponseSessionListingHermesApi extends _ResponsesHermesApi {
  _ResponseSessionListingHermesApi({
    this.failSessionCreation = false,
    this.sessionAlreadyExists = false,
  });

  final bool failSessionCreation;
  final bool sessionAlreadyExists;
  var listSessionsCalls = 0;

  @override
  Future<String> createSession({String? title, CancelToken? cancelToken}) {
    if (failSessionCreation) {
      throw StateError('create endpoint unavailable');
    }
    return super.createSession(title: title, cancelToken: cancelToken);
  }

  @override
  Future<List<Map<String, dynamic>>> listSessions() async {
    listSessionsCalls++;
    if (!sessionAlreadyExists && createSessionCalls == 0 && inputs.isEmpty) {
      return const [];
    }
    return const [
      {
        'id': 'responses-session',
        'title': 'Response-created chat',
        'updated_at': '2026-07-16T00:00:00Z',
      },
    ];
  }
}

class _TrailingStaleHistoryHermesApi extends _ResponsesHermesApi {
  _TrailingStaleHistoryHermesApi({
    required this.stalePrompt,
    this.failSessionCreation = false,
  });

  final String stalePrompt;
  final bool failSessionCreation;

  @override
  Future<String> createSession({String? title, CancelToken? cancelToken}) {
    if (failSessionCreation) {
      throw StateError('session creation unavailable');
    }
    return super.createSession(title: title, cancelToken: cancelToken);
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String sessionId, {
    CancelToken? cancelToken,
  }) async => <Map<String, dynamic>>[
    ...await super.getSessionMessages(sessionId, cancelToken: cancelToken),
    <String, dynamic>{
      'id': ' stale-message ',
      'role': 'user',
      'content': stalePrompt,
    },
  ];
}

class _StalledDocumentBaselineHermesApi extends HermesApiService {
  _StalledDocumentBaselineHermesApi({this.stallPostCommit = false})
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'http://hermes',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  final bool stallPostCommit;
  final historyStarted = Completer<void>();
  final historyCancelled = Completer<void>();
  final _uncancellableHistory = Completer<List<Map<String, dynamic>>>();
  final historyCancelTokens = <CancelToken?>[];
  CancelToken? historyCancelToken;
  CancelToken? responseCancelToken;
  var historyCalls = 0;
  var responseCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String sessionId, {
    CancelToken? cancelToken,
  }) async {
    historyCalls++;
    historyCancelTokens.add(cancelToken);
    if (stallPostCommit && historyCalls == 1) {
      return const <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'existing-user-row',
          'role': 'user',
          'content': 'older prompt',
        },
      ];
    }
    historyCancelToken = cancelToken;
    if (!historyStarted.isCompleted) historyStarted.complete();
    if (cancelToken == null) return _uncancellableHistory.future;
    await cancelToken.whenCancel;
    if (!historyCancelled.isCompleted) historyCancelled.complete();
    throw StateError('history request cancelled');
  }

  @override
  Future<HermesResponseStream> streamResponse(
    HermesChatInput input, {
    String? instructions,
    String? sessionId,
    String? conversation,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async {
    responseCalls++;
    responseCancelToken = cancelToken;
    return HermesResponseStream(
      sessionId: sessionId,
      events: Stream<HermesRunEvent>.value(const HermesRunDone()),
    );
  }

  void dispose() {
    if (!_uncancellableHistory.isCompleted) {
      _uncancellableHistory.complete(const <Map<String, dynamic>>[]);
    }
  }
}

class _SeededAttachedFiles extends AttachedFilesNotifier {
  _SeededAttachedFiles(this.files);

  final List<FileUploadState> files;

  @override
  List<FileUploadState> build() => List<FileUploadState>.of(files);

  void reseed() => state = List<FileUploadState>.of(files);
}

class _GatedProfilesController extends DirectConnectionProfilesController {
  _GatedProfilesController(this.profiles);

  final Future<List<DirectConnectionProfile>> profiles;

  @override
  Future<List<DirectConnectionProfile>> build() => profiles;
}

typedef _DelayedHermesEditFixture = ({
  ProviderContainer container,
  Completer<List<DirectConnectionProfile>> profiles,
  List<ChatMessage> originalMessages,
});

_DelayedHermesEditFixture _buildDelayedHermesEditFixture() {
  final profiles = Completer<List<DirectConnectionProfile>>();
  final profile = DirectConnectionProfile(
    id: 'edit-profile',
    name: 'Edit profile',
    adapterKey: kOpenAiCompatibleAdapterKey,
    baseUrl: 'https://example.test/v1',
    apiKey: 'key',
  );
  final registry = DirectModelRegistry();
  final selectedModel = registry.replaceProfileModels(
    profile,
    <DirectRemoteModel>[DirectRemoteModel(id: 'edit-model')],
  ).single;
  final originalMessages = <ChatMessage>[
    ChatMessage(
      id: 'user-edit',
      role: 'user',
      content: 'original prompt',
      timestamp: DateTime(2024, 1, 1),
    ),
    _assistantMessage(id: 'assistant-edit', content: 'original answer'),
  ];
  final container = _testContainer(
    overrides: [
      activeConversationProvider.overrideWith(
        () => _TestActiveConversationNotifier(),
      ),
      reviewerModeProvider.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(null),
      socketServiceProvider.overrideWithValue(null),
      directModelRegistryProvider.overrideWithValue(registry),
      directConnectionProfilesProvider.overrideWith(
        () => _GatedProfilesController(profiles.future),
      ),
    ],
  );
  container
      .read(activeConversationProvider.notifier)
      .set(
        markNativeHermesConversation(
          Conversation(
            id: 'shared-id',
            title: 'Hermes edit',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            model: selectedModel.id,
            messages: originalMessages,
            metadata: const <String, dynamic>{'backend': 'hermes'},
          ),
        ),
      );
  container.read(selectedModelProvider.notifier).set(selectedModel);
  return (
    container: container,
    profiles: profiles,
    originalMessages: originalMessages,
  );
}

ProviderContainer _buildContainer({HermesApiService? hermesService}) {
  return _testContainer(
    overrides: [
      activeConversationProvider.overrideWith(
        () => _TestActiveConversationNotifier(),
      ),
      reviewerModeProvider.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(null),
      hermesApiServiceProvider.overrideWithValue(hermesService),
      socketServiceProvider.overrideWithValue(null),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatMessagesNotifier streaming seams', () {
    setUp(() async {
      PreferencesStore.debugReset();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
    });

    tearDown(() {
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      PreferencesStore.debugReset();
    });

    test('send recovery follows an OpenWebUI local-to-server remap', () {
      final container = _buildContainer();
      addTearDown(container.dispose);
      final placeholder = _assistantMessage(
        id: 'assistant-remap',
        content: '',
        isStreaming: true,
      );
      final localOwner = withChatStorageProvenance(
        _conversation('local:chat', [placeholder]),
        ChatStorageKind.openWebUi,
      );
      final serverOwner = withChatStorageProvenance(
        _conversation('server-chat', [placeholder]),
        ChatStorageKind.openWebUi,
      );
      final handle = chatSendPlaceholderHandleForTest(
        ref: container,
        assistantMessageId: placeholder.id,
        owner: localOwner,
      );
      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: localOwner.id, toId: serverOwner.id);
      container.read(activeConversationProvider.notifier).set(serverOwner);
      container.read(chatMessagesProvider.notifier).setMessages([placeholder]);

      recoverFailedChatSend(
        container,
        StateError('post-remap failure'),
        handle,
      );

      final recovered = container.read(chatMessagesProvider).single;
      check(recovered.isStreaming).isFalse();
      check(recovered.error).isNotNull();
    });

    test('send recovery never follows a remap into direct-local storage', () {
      final container = _buildContainer();
      addTearDown(container.dispose);
      final placeholder = _assistantMessage(
        id: 'assistant-collision',
        content: '',
        isStreaming: true,
      );
      final localOwner = withChatStorageProvenance(
        _conversation('local:chat', [placeholder]),
        ChatStorageKind.openWebUi,
      );
      final collidingDirectChat = withChatStorageProvenance(
        _conversation('server-chat', [placeholder]),
        ChatStorageKind.directLocal,
      );
      final handle = chatSendPlaceholderHandleForTest(
        ref: container,
        assistantMessageId: placeholder.id,
        owner: localOwner,
      );
      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: localOwner.id, toId: collidingDirectChat.id);
      container
          .read(activeConversationProvider.notifier)
          .set(collidingDirectChat);
      container.read(chatMessagesProvider.notifier).setMessages([placeholder]);

      recoverFailedChatSend(container, StateError('wrong owner'), handle);

      final untouched = container.read(chatMessagesProvider).single;
      check(untouched.isStreaming).isTrue();
      check(untouched.error).isNull();
      container.read(chatMessagesProvider.notifier).clearMessages();
    });

    test('Hermes rejects unresolved attachment ids before dispatch', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);
      container
          .read(selectedModelProvider.notifier)
          .set(hermesSyntheticModel());

      await expectLater(
        sendMessageWithContainer(container, 'inspect this', ['file-1']),
        throwsA(
          isA<HermesAttachmentsUnsupportedException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('cannot use this attachment'),
              isNot(contains('PDF')),
            ),
          ),
        ),
      );

      final messages = container.read(chatMessagesProvider);
      check(messages).isEmpty();
    });

    test(
      'Hermes leaves rejected context attachments in the composer',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());
        container
            .read(contextAttachmentsProvider.notifier)
            .addWeb(
              displayName: 'Reference',
              content: 'Important context',
              url: 'https://example.com/reference',
            );

        await expectLater(
          sendMessageWithContainer(container, 'use this context', null),
          throwsA(isA<HermesAttachmentsUnsupportedException>()),
        );

        final messages = container.read(chatMessagesProvider);
        check(messages).isEmpty();
        check(container.read(contextAttachmentsProvider)).single
            .has((attachment) => attachment.displayName, 'displayName')
            .equals('Reference');
      },
    );

    test(
      'mixed OpenWebUI to Hermes turn persists its tree and oversized final',
      () async {
        final events = StreamController<HermesRunEvent>();
        addTearDown(events.close);
        final service = _SessionRecordingHermesApi(events: events);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            hermesProjectionRetentionLimitsProvider.overrideWithValue((
              maxProjections: 1,
              maxBytes: 512,
            )),
          ],
        );
        addTearDown(container.dispose);
        final database = container.read(appDatabaseProvider)!;
        final parent = _assistantMessage(
          id: 'openwebui-parent',
          content: 'OpenWebUI answer',
          metadata: const <String, dynamic>{'childrenIds': <String>[]},
        );
        final seedRows = ChatBlobMapper.blobToRows(
          chatId: 'mixed-openwebui-chat',
          blob: <String, dynamic>{
            'title': 'Mixed chat',
            'history': <String, dynamic>{
              'currentId': parent.id,
              'messages': <String, dynamic>{
                parent.id: <String, dynamic>{
                  'id': parent.id,
                  'role': parent.role,
                  'content': parent.content,
                  'childrenIds': <String>[],
                  'timestamp': parent.timestamp.millisecondsSinceEpoch ~/ 1000,
                },
              },
            },
          },
          title: 'Mixed chat',
          createdAt: 1,
          updatedAt: 1,
        );
        await database.chatsDao.upsertServerChat(rows: seedRows);
        final conversation = withChatStorageProvenance(
          Conversation(
            id: 'mixed-openwebui-chat',
            title: 'Mixed chat',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: <ChatMessage>[parent],
          ),
          ChatStorageKind.openWebUi,
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());
        await Future<void>.delayed(Duration.zero);

        final send = sendMessageWithContainer(
          container,
          'Continue with Hermes',
          null,
        );
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );
        final oversizedAnswer = 'H' * 2048;
        events
          ..add(HermesTokenDelta(oversizedAnswer))
          ..add(HermesFinalOutput(oversizedAnswer))
          ..add(const HermesRunDone());
        await send.timeout(const Duration(seconds: 1));

        final reloaded = await loadLocalConversation(
          container,
          conversation.id,
        );
        check(reloaded).isNotNull();
        final messages = reloaded!.messages;
        check(messages).length.equals(3);
        final reloadedParent = messages.first;
        final user = messages[1];
        final assistant = messages[2];
        check(
          message_tree.chatMessageChildrenIds(reloadedParent),
        ).deepEquals(<String>[user.id]);
        check(message_tree.chatMessageParentId(user)).equals(parent.id);
        check(
          message_tree.chatMessageChildrenIds(user),
        ).deepEquals(<String>[assistant.id]);
        check(message_tree.chatMessageParentId(assistant)).equals(user.id);
        check(assistant.content).equals(oversizedAnswer);
        check(assistant.isStreaming).isFalse();
        // The general OpenWebUI parser intentionally strips Hermes provenance
        // from server-shaped blobs so a hostile server cannot manufacture an
        // authenticated Hermes action. Verify app-owned durability against the
        // normalized row itself, before that trust-boundary sanitization.
        final durableAssistant = await database.messagesDao.getMessage(
          conversation.id,
          assistant.id,
        );
        check(durableAssistant).isNotNull();
        final durablePayload =
            jsonDecode(durableAssistant!.payload) as Map<String, dynamic>;
        check(
          (durablePayload['metadata'] as Map)['transport'],
        ).equals(kHermesTransport);
        final pending = await database.outboxDao.pendingForChat(
          conversation.id,
        );
        check(
          pending.where(
            (operation) => operation.kind == OutboxKind.requestCompletion.name,
          ),
        ).isEmpty();
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'server-cancelled Hermes projection persists a terminal error',
      () async {
        final events = StreamController<HermesRunEvent>(sync: true);
        final service = _SessionRecordingHermesApi(events: events);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(() async {
          await events.close();
          container.dispose();
        });
        final placeholder = _assistantMessage(
          id: 'server-cancelled-assistant',
          content: 'Partial answer',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final owner = withChatStorageProvenance(
          _conversation('server-cancelled-chat', <ChatMessage>[placeholder]),
          ChatStorageKind.openWebUi,
        );
        final database = container.read(appDatabaseProvider)!;
        await _seedDurableAssistantOwner(
          database,
          chatId: owner.id,
          assistant: placeholder,
        );
        container.read(activeConversationProvider.notifier).set(owner);
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          placeholder,
        ]);

        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: placeholder.id,
          assistantSeed: placeholder,
          input: 'cancel this remotely',
          existingMessages: <ChatMessage>[
            _assistantMessage(
              id: 'server-cancelled-history',
              metadata: const <String, dynamic>{
                'hermesSessionId': 'server-cancelled-session',
              },
            ),
          ],
        );
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );
        events.add(const HermesRunError('Hermes run was cancelled.'));
        await dispatch.timeout(const Duration(seconds: 1));

        final visible = container.read(chatMessagesProvider).single;
        check(visible.isStreaming).isFalse();
        check(visible.error?.content).equals('Hermes run was cancelled.');

        final durable = await database.messagesDao.getMessage(
          owner.id,
          placeholder.id,
        );
        check(durable).isNotNull();
        final payload = jsonDecode(durable!.payload) as Map<String, dynamic>;
        check(payload['isStreaming']).equals(false);
        check(payload['done']).equals(true);
        check(
          (payload['error'] as Map<String, dynamic>)['content'],
        ).equals('Hermes run was cancelled.');
      },
    );

    test(
      'mixed Hermes dispatch keeps its pre-commit assistant seed after navigation',
      () async {
        final events = StreamController<HermesRunEvent>();
        addTearDown(events.close);
        final service = _SessionRecordingHermesApi(events: events);
        final hermesModel = hermesSyntheticModel();
        late ProviderContainer container;
        late String assistantId;
        late String userId;
        container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            hermesTurnStartPostCommitHookProvider.overrideWithValue(() {
              final committed = container.read(chatMessagesProvider);
              userId = committed.first.id;
              assistantId = committed.last.id;
              final foreign = committed.last.copyWith(
                content: 'foreign view',
                model: 'foreign-model',
                metadata: const <String, dynamic>{
                  'transport': kHermesTransport,
                  'parentId': 'foreign-parent',
                  'childrenIds': <String>['foreign-child'],
                  'modelName': 'Foreign model',
                },
              );
              final foreignOwner = withChatStorageProvenance(
                Conversation(
                  id: 'foreign-openwebui-chat',
                  title: 'Foreign',
                  createdAt: DateTime(2024),
                  updatedAt: DateTime(2024),
                  messages: <ChatMessage>[foreign],
                ),
                ChatStorageKind.openWebUi,
              );
              container
                  .read(activeConversationProvider.notifier)
                  .set(foreignOwner);
              container.read(chatMessagesProvider.notifier).setMessages(
                <ChatMessage>[foreign],
              );
            }),
          ],
        );
        addTearDown(container.dispose);
        final database = container.read(appDatabaseProvider)!;
        await database.chatsDao.upsertEnvelopeStub(
          id: 'seed-owner-chat',
          title: 'Seed owner',
          createdAt: 1,
          updatedAt: 1,
        );
        final owner = withChatStorageProvenance(
          Conversation(
            id: 'seed-owner-chat',
            title: 'Seed owner',
            createdAt: DateTime(2024),
            updatedAt: DateTime(2024),
          ),
          ChatStorageKind.openWebUi,
        );
        container.read(activeConversationProvider.notifier).set(owner);
        container.read(selectedModelProvider.notifier).set(hermesModel);

        final send = sendMessageWithContainer(
          container,
          'Owned question',
          null,
        );
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );
        events
          ..add(const HermesTokenDelta('Owned final'))
          ..add(const HermesRunDone());
        await send.timeout(const Duration(seconds: 1));

        final durable = await database.messagesDao.getMessage(
          owner.id,
          assistantId,
        );
        check(durable).isNotNull();
        check(durable!.parentId).equals(userId);
        check(durable.model).equals(hermesModel.id);
        check(durable.content).equals('Owned final');
        final payload = jsonDecode(durable.payload) as Map<String, dynamic>;
        check(payload['parentId']).equals(userId);
        check(payload['childrenIds'] as List).isEmpty();
        check(
          (payload['metadata'] as Map)['modelName'],
        ).equals(hermesModel.name);
      },
    );

    test(
      'approval mutation waiting behind primary persistence writes one snapshot',
      () async {
        final events = StreamController<HermesRunEvent>(sync: true);
        final service = _SessionRecordingHermesApi(events: events);
        final locks = _GatedFirstHermesPersistenceLocks();
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            chatLocksProvider.overrideWithValue(locks),
          ],
        );
        addTearDown(() async {
          if (!locks.allow.isCompleted) locks.allow.complete();
          await events.close();
          container.dispose();
        });
        final placeholder = _assistantMessage(
          id: 'approval-primary-race',
          content: 'final body',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final owner = withChatStorageProvenance(
          _conversation('approval-primary-race-chat', <ChatMessage>[
            placeholder,
          ]),
          ChatStorageKind.openWebUi,
        );
        final database = container.read(appDatabaseProvider)!;
        await _seedDurableAssistantOwner(
          database,
          chatId: owner.id,
          assistant: placeholder,
        );
        container.read(activeConversationProvider.notifier).set(owner);
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          placeholder,
        ]);
        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: placeholder.id,
          assistantSeed: placeholder,
          input: 'race approval persistence',
          existingMessages: <ChatMessage>[
            _assistantMessage(
              id: 'approval-primary-history',
              metadata: const <String, dynamic>{
                'hermesSessionId': 'approval-primary-session',
              },
            ),
          ],
        );
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );
        events.add(
          const HermesApprovalRequested(
            approvalId: 'approval-primary-id',
            summary: 'Continue?',
          ),
        );
        await pumpEventQueue();
        final registry = container.read(hermesRunRegistryProvider);
        final key = hermesRunKeyForConversation(
          container,
          conversation: owner,
          assistantMessageId: placeholder.id,
        );
        final generation = registry.generationTokenFor(
          key,
          runId: 'recorded-run',
        )!;
        final cancelToken = registry.cancelTokenForGeneration(
          key,
          generationToken: generation,
          runId: 'recorded-run',
        )!;
        final updateApproval = captureHermesApprovalProjectionStateUpdater(
          container,
          cancelToken: cancelToken,
          messageId: placeholder.id,
          runId: 'recorded-run',
          approvalId: 'approval-primary-id',
        );
        check(
          updateApproval(
            expectedState: 'pending',
            nextState: 'resolving',
          ).changed,
        ).isTrue();
        events.add(const HermesRunDone());
        await locks.started.future.timeout(const Duration(seconds: 1));
        check(
          updateApproval(
            expectedState: 'resolving',
            nextState: 'approved',
          ).changed,
        ).isTrue();
        locks.allow.complete();
        await dispatch.timeout(const Duration(seconds: 1));

        String? durableState;
        for (var attempt = 0; attempt < 20; attempt++) {
          await pumpEventQueue();
          final row = await database.messagesDao.getMessage(
            owner.id,
            placeholder.id,
          );
          final payload = jsonDecode(row!.payload) as Map<String, dynamic>;
          durableState =
              ((payload['metadata'] as Map)[kHermesApprovalMeta]
                      as Map)['state']
                  as String?;
          if (durableState == 'approved') break;
        }
        check(durableState).equals('approved');
        final pending = await database.outboxDao.pendingForChat(owner.id);
        check(
          pending.where(
            (operation) => operation.kind == OutboxKind.updateChat.name,
          ),
        ).length.equals(1);
      },
    );

    test(
      'late stop cleanup error survives approval compaction and durable reopen',
      () async {
        final events = StreamController<HermesRunEvent>(sync: true);
        final stopGate = Completer<void>();
        final service = _SessionRecordingHermesApi(
          events: events,
          stopError: StateError('remote stop failed'),
          stopGate: stopGate,
        );
        final container = _testContainer(
          overrides: <Override>[
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(() async {
          if (!stopGate.isCompleted) stopGate.complete();
          await events.close();
          container.dispose();
        });
        final placeholder = _assistantMessage(
          id: 'approval-cleanup-error',
          content: 'Partial answer',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final owner = withChatStorageProvenance(
          _conversation('approval-cleanup-chat', <ChatMessage>[placeholder]),
          ChatStorageKind.openWebUi,
        );
        final database = container.read(appDatabaseProvider)!;
        await _seedDurableAssistantOwner(
          database,
          chatId: owner.id,
          assistant: placeholder,
          bodySynced: true,
        );
        container.read(activeConversationProvider.notifier).set(owner);
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          placeholder,
        ]);
        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: placeholder.id,
          assistantSeed: placeholder,
          input: 'Compact before stop cleanup settles',
          existingMessages: <ChatMessage>[
            _assistantMessage(
              id: 'approval-cleanup-history',
              metadata: const <String, dynamic>{
                'hermesSessionId': 'approval-cleanup-session',
              },
            ),
          ],
        );
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );
        events.add(
          const HermesApprovalRequested(
            approvalId: 'approval-cleanup-id',
            summary: 'Continue?',
          ),
        );
        await pumpEventQueue();
        final registry = container.read(hermesRunRegistryProvider);
        final key = hermesRunKeyForConversation(
          container,
          conversation: owner,
          assistantMessageId: placeholder.id,
        );
        final generation = registry.generationTokenFor(
          key,
          runId: 'recorded-run',
        )!;
        final cancelToken = registry.cancelTokenForGeneration(
          key,
          generationToken: generation,
          runId: 'recorded-run',
        )!;
        final updateApproval = captureHermesApprovalProjectionStateUpdater(
          container,
          cancelToken: cancelToken,
          messageId: placeholder.id,
          runId: 'recorded-run',
          approvalId: 'approval-cleanup-id',
        );

        container.read(stopGenerationProvider)();
        await service.stopRunStarted.future.timeout(const Duration(seconds: 1));
        check(
          updateApproval(
            expectedState: 'pending',
            nextState: 'resolving',
          ).changed,
        ).isTrue();
        stopGate.complete();
        await dispatch.timeout(const Duration(seconds: 1));

        const expectedError =
            'Could not confirm that Hermes stopped this run. It may still '
            'be running on the server.';
        Map<String, dynamic>? durablePayload;
        for (var attempt = 0; attempt < 20; attempt++) {
          await pumpEventQueue();
          final row = await database.messagesDao.getMessage(
            owner.id,
            placeholder.id,
          );
          durablePayload = jsonDecode(row!.payload) as Map<String, dynamic>;
          final durableError = durablePayload['error'];
          if (durableError is Map && durableError['content'] == expectedError) {
            break;
          }
        }
        check(
          (durablePayload!['error'] as Map<String, dynamic>)['content'],
        ).equals(expectedError);
        check(
          ((durablePayload['metadata'] as Map)[kHermesApprovalMeta]
              as Map)['state'],
        ).equals('resolving');

        final reopened = await container
            .read(chatDatabaseRepositoryProvider)
            .loadConversation(owner.id, preferred: ChatStorageKind.openWebUi);
        check(reopened).isNotNull();
        final reopenedAssistant = reopened!.conversation.messages.singleWhere(
          (message) => message.id == placeholder.id,
        );
        check(reopenedAssistant.error?.content).equals(expectedError);
      },
    );

    test(
      'backend switch after mixed turn commit settles the durable placeholder',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        final databaseState =
            NotifierProvider<_HermesDatabaseOwner, AppDatabase?>(
              () => _HermesDatabaseOwner(database),
            );
        final service = _SessionRecordingHermesApi();
        late final ProviderContainer container;
        container = ProviderContainer(
          overrides: [
            openWebUiDatabaseAccessProvider.overrideWith(
              _OpenDatabaseAccess.new,
            ),
            appDatabaseProvider.overrideWith((ref) => ref.watch(databaseState)),
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            hermesTurnStartPostCommitHookProvider.overrideWithValue(
              () => container.read(databaseState.notifier).set(null),
            ),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });
        final parent = _assistantMessage(
          id: 'switch-after-commit-parent',
          content: 'Before switch',
          metadata: const <String, dynamic>{'childrenIds': <String>[]},
        );
        final rows = ChatBlobMapper.blobToRows(
          chatId: 'switch-after-commit-chat',
          blob: <String, dynamic>{
            'title': 'Switch after commit',
            'history': <String, dynamic>{
              'currentId': parent.id,
              'messages': <String, dynamic>{
                parent.id: <String, dynamic>{
                  'id': parent.id,
                  'role': parent.role,
                  'content': parent.content,
                  'childrenIds': <String>[],
                  'timestamp': parent.timestamp.millisecondsSinceEpoch ~/ 1000,
                },
              },
            },
          },
          title: 'Switch after commit',
          createdAt: 1,
          updatedAt: 1,
        );
        await database.chatsDao.upsertServerChat(rows: rows);
        final conversation = withChatStorageProvenance(
          Conversation(
            id: 'switch-after-commit-chat',
            title: 'Switch after commit',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: <ChatMessage>[parent],
          ),
          ChatStorageKind.openWebUi,
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          sendMessageWithContainer(container, 'Do not strand this turn', null),
          throwsA(isA<StateError>()),
        );

        check(service.inputs).isEmpty();
        final durableRows = await database.messagesDao.getForChat(
          conversation.id,
        );
        check(durableRows).length.equals(3);
        final assistant = durableRows.last;
        final payload = jsonDecode(assistant.payload) as Map<String, dynamic>;
        check(assistant.role).equals('assistant');
        check(payload['isStreaming']).equals(false);
        check(
          (payload['error'] as Map<String, dynamic>)['content'] as String,
        ).contains('backend changed');
        final pending = await database.outboxDao.pendingForChat(
          conversation.id,
        );
        check(
          pending.where(
            (operation) => operation.kind == OutboxKind.requestCompletion.name,
          ),
        ).isEmpty();
      },
    );

    test(
      'Hermes config cancellation after mixed commit settles durable start',
      () async {
        final manager = DatabaseManager(
          openDatabase: (_) => AppDatabase(NativeDatabase.memory()),
        );
        final database = manager.openForServerId('post-commit-cancel-server');
        final oldService = _ResponsesHermesApi();
        final replacementService = _ResponsesHermesApi();
        final config = _RotatableAdmissionHermesConfigController();
        final serviceGeneration =
            NotifierProvider<_HermesServiceGeneration, HermesApiService?>(
              () => _HermesServiceGeneration(oldService),
            );
        final cancellationFutures = <Future<void>>[];
        var postCommitHookCalls = 0;
        late final ProviderContainer container;
        container = ProviderContainer(
          overrides: [
            openWebUiDatabaseAccessProvider.overrideWith(
              _OpenDatabaseAccess.new,
            ),
            databaseManagerProvider.overrideWithValue(manager),
            appDatabaseProvider.overrideWithValue(database),
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(() => config),
            hermesApiServiceProvider.overrideWith(
              (ref) => ref.watch(serviceGeneration),
            ),
            hermesTurnStartPostCommitHookProvider.overrideWithValue(() {
              postCommitHookCalls++;
              config.rotateServer();
              container
                  .read(serviceGeneration.notifier)
                  .set(replacementService);
              cancellationFutures.addAll(
                container.read(hermesRunRegistryProvider).cancelAll(),
              );
            }),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await manager.closeActive();
        });
        final parent = _assistantMessage(
          id: 'post-commit-cancel-parent',
          content: 'Before cancellation',
          metadata: const <String, dynamic>{'childrenIds': <String>[]},
        );
        final rows = ChatBlobMapper.blobToRows(
          chatId: 'post-commit-cancel-chat',
          blob: <String, dynamic>{
            'title': 'Post-commit cancellation',
            'history': <String, dynamic>{
              'currentId': parent.id,
              'messages': <String, dynamic>{
                parent.id: <String, dynamic>{
                  'id': parent.id,
                  'role': parent.role,
                  'content': parent.content,
                  'childrenIds': <String>[],
                  'timestamp': parent.timestamp.millisecondsSinceEpoch ~/ 1000,
                },
              },
            },
          },
          title: 'Post-commit cancellation',
          createdAt: 1,
          updatedAt: 1,
        );
        await database.chatsDao.upsertServerChat(rows: rows);
        final conversation = withChatStorageProvenance(
          Conversation(
            id: 'post-commit-cancel-chat',
            title: 'Post-commit cancellation',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: <ChatMessage>[parent],
          ),
          ChatStorageKind.openWebUi,
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());
        await Future<void>.delayed(Duration.zero);

        await sendMessageWithContainer(
          container,
          'Cancel immediately after commit',
          null,
        ).timeout(const Duration(seconds: 1));
        await Future.wait<void>(
          cancellationFutures,
        ).timeout(const Duration(seconds: 1));

        check(postCommitHookCalls).equals(1);
        check(oldService.inputs).isEmpty();
        check(replacementService.inputs).isEmpty();
        check(oldService.createSessionCalls).equals(0);
        check(replacementService.createSessionCalls).equals(0);
        final durableRows = await database.messagesDao.getForChat(
          conversation.id,
        );
        check(durableRows).length.equals(3);
        final durableAssistant = durableRows.last;
        final durablePayload =
            jsonDecode(durableAssistant.payload) as Map<String, dynamic>;
        check(durableAssistant.role).equals('assistant');
        check(durablePayload['isStreaming']).equals(false);
        check(
          container
              .read(hermesRunRegistryProvider)
              .cancelMessage(durableAssistant.id),
        ).isNull();

        // A leaked turn-start lease would leave closeActive blocked here.
        await manager.closeActive().timeout(const Duration(seconds: 1));
      },
    );

    test(
      'projection beyond the recovery count still persists its exact final',
      () async {
        final service = _MultiRunHermesApi();
        addTearDown(service.closeStreams);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            hermesProjectionRetentionLimitsProvider.overrideWithValue((
              maxProjections: 1,
              maxBytes: 1024 * 1024,
            )),
          ],
        );
        addTearDown(container.dispose);
        final database = container.read(appDatabaseProvider)!;
        final parent = _assistantMessage(
          id: 'count-limit-parent',
          content: 'Parent',
        );
        final rows = ChatBlobMapper.blobToRows(
          chatId: 'count-limit-chat',
          blob: <String, dynamic>{
            'title': 'Count limit',
            'history': <String, dynamic>{
              'currentId': parent.id,
              'messages': <String, dynamic>{
                parent.id: <String, dynamic>{
                  'id': parent.id,
                  'role': parent.role,
                  'content': parent.content,
                  'childrenIds': <String>[],
                  'timestamp': parent.timestamp.millisecondsSinceEpoch ~/ 1000,
                },
              },
            },
          },
          title: 'Count limit',
          createdAt: 1,
          updatedAt: 1,
        );
        await database.chatsDao.upsertServerChat(rows: rows);
        final conversation = withChatStorageProvenance(
          Conversation(
            id: 'count-limit-chat',
            title: 'Count limit',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: <ChatMessage>[parent],
          ),
          ChatStorageKind.openWebUi,
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());
        await Future<void>.delayed(Duration.zero);

        final first = sendMessageWithContainer(container, 'first', null);
        await pumpEventQueue();
        final second = sendMessageWithContainer(container, 'second', null);
        await service.twoStreamsStarted.future.timeout(
          const Duration(seconds: 1),
        );
        service
          ..emit('first', const HermesTokenDelta('First final'))
          ..emit('first', const HermesRunDone())
          ..emit('second', const HermesTokenDelta('Second final'))
          ..emit('second', const HermesRunDone());
        await Future.wait(<Future<void>>[
          first,
          second,
        ]).timeout(const Duration(seconds: 1));

        final reloaded = await loadLocalConversation(
          container,
          conversation.id,
        );
        check(reloaded).isNotNull();
        check(
          reloaded!.messages.map((message) => message.content),
        ).contains('First final');
        check(
          reloaded.messages.map((message) => message.content),
        ).contains('Second final');
        // As above, inspect the trusted local rows for transport provenance;
        // assembled OpenWebUI payloads deliberately discard it.
        final durableRows = await database.messagesDao.getForChat(
          conversation.id,
        );
        final durableHermesContents = durableRows
            .where((row) {
              final payload = jsonDecode(row.payload) as Map<String, dynamic>;
              final metadata = payload['metadata'];
              return row.role == 'assistant' &&
                  metadata is Map &&
                  metadata['transport'] == kHermesTransport;
            })
            .map((row) => row.content)
            .toList(growable: false);
        check(
          durableHermesContents,
        ).unorderedEquals(<String>['First final', 'Second final']);
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'Hermes image turn enters Responses and later text stays on its chain',
      () async {
        final service = _ResponsesHermesApi();
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            hermesCapabilitiesProvider.overrideWith(
              (ref) async => const HermesCapabilities(inputImages: true),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(hermesCapabilitiesProvider.future);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());
        const image = 'data:image/png;base64,AQID';

        await sendMessageWithContainer(container, 'describe', [image]);
        await sendMessageWithContainer(container, 'continue', null);

        check(service.createRunCalls).equals(0);
        check(service.inputs).length.equals(2);
        check(
          service.inputs.first.toJson() as List<Map<String, dynamic>>,
        ).deepEquals([
          {'type': 'input_text', 'text': 'describe'},
          {'type': 'input_image', 'image_url': image},
        ]);
        check(service.inputs.last.toJson()).equals('continue');
        check(service.sessionIds).deepEquals([null, 'responses-session']);
        check(service.previousResponseIds).deepEquals([null, 'resp-1']);
        check(service.histories.first).isNotNull();
        check(service.histories.first!).isEmpty();
        check(service.histories.last).isNull();

        final messages = container.read(chatMessagesProvider);
        check(messages).length.equals(4);
        check(messages.first.files!.single['url']).equals(image);
        check(messages[1].metadata?['hermesResponseId']).equals('resp-1');
        check(messages.last.metadata?['hermesResponseId']).equals('resp-2');
        check(
          container.read(activeConversationProvider)?.metadata['backend'],
        ).equals('hermes');
      },
    );

    test('first Responses turn adopts the server-owned session', () async {
      final service = _ResponsesHermesApi(
        establishedSessionIdOverride: 'foreign-session',
      );
      final container = _testContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(),
          ),
          hermesApiServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);

      final placeholder = _assistantMessage(
        id: 'mismatched-session-assistant',
        content: '',
        isStreaming: true,
        metadata: const <String, dynamic>{'transport': kHermesTransport},
      );
      container
          .read(activeConversationProvider.notifier)
          .set(
            markNativeHermesConversation(
              Conversation(
                id: 'local:hermes_expected-session',
                title: 'Expected session',
                createdAt: DateTime(2024, 1, 1),
                updatedAt: DateTime(2024, 1, 1),
                messages: <ChatMessage>[placeholder],
                metadata: const <String, dynamic>{
                  'backend': 'hermes',
                  'hermesSessionId': 'expected-session',
                },
              ),
            ),
          );
      await Future<void>.delayed(Duration.zero);

      await dispatchHermesRunFromChatForTest(
        container,
        assistantMessageId: placeholder.id,
        assistantSeed: placeholder,
        input: 'continue',
        existingMessages: const <ChatMessage>[],
        responseInput: HermesChatInput.text('continue'),
      ).timeout(const Duration(seconds: 1));

      check(service.sessionIds).deepEquals(<String?>[null]);
      check(
        container.read(activeConversationProvider)!.metadata['hermesSessionId'],
      ).equals('foreign-session');
      check(
        container.read(hermesActiveSessionProvider),
      ).equals('foreign-session');
      final assistant = container.read(chatMessagesProvider).single;
      check(assistant.isStreaming).isFalse();
      check(assistant.content).equals('answer 1');
      check(assistant.error).isNull();
      check(assistant.metadata?['hermesSessionId']).equals('foreign-session');
      container.read(chatMessagesProvider.notifier).clearMessages();
    });

    test(
      'new-session document trust excludes stale and padded history rows',
      () async {
        const envelope =
            '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_TEST>>>\nsource\n'
            '<<<END_HERMES_UNTRUSTED_REFERENCE_TEST>>>';
        const prompt = 'summarize\n\n$envelope';
        SharedPreferences.setMockInitialValues(<String, Object>{});
        PreferencesStore.debugOverride(await SharedPreferences.getInstance());
        HermesLocalDocumentTrustStore.debugResetRuntimeState();
        addTearDown(() {
          HermesLocalDocumentTrustStore.debugResetRuntimeState();
          PreferencesStore.debugReset();
        });

        final service = _TrailingStaleHistoryHermesApi(stalePrompt: prompt);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        final placeholder = _assistantMessage(
          id: 'new-session-document-assistant',
          content: '',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          placeholder,
        ]);

        await dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: placeholder.id,
          assistantSeed: placeholder,
          input: 'summarize',
          existingMessages: const <ChatMessage>[],
          responseInput: HermesChatInput.text(prompt),
          localDocumentPromptText: prompt,
          localDocumentEnvelopes: const <String>[envelope],
        ).timeout(const Duration(seconds: 1));

        final endpointIdentity = HermesConfigController.connectionEndpoint(
          service.config.baseUrl,
        )!;
        final connectionIdentity =
            HermesLocalDocumentTrustStore.connectionIdentity(
              endpointIdentity: endpointIdentity,
              principalId: container
                  .read(hermesConfigProvider.notifier)
                  .documentTrustPrincipalId(),
            );
        final trusted = HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: connectionIdentity,
          sessionId: 'responses-session',
        );
        check(trusted).deepEquals(<String>{
          HermesLocalDocumentTrustStore.documentTrustKey(
            messageId: 'server-user-1',
            promptText: prompt,
            documentEnvelope: envelope,
            startOffset: prompt.length - envelope.length,
          ),
        });
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test('response-created sessions persist exact document trust', () async {
      const envelope =
          '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_TEST>>>\nsource\n'
          '<<<END_HERMES_UNTRUSTED_REFERENCE_TEST>>>';
      const prompt = 'summarize\n\n$envelope';
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      addTearDown(() {
        HermesLocalDocumentTrustStore.debugResetRuntimeState();
        PreferencesStore.debugReset();
      });

      final service = _TrailingStaleHistoryHermesApi(
        stalePrompt: prompt,
        failSessionCreation: true,
      );
      final container = _testContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(),
          ),
          hermesApiServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final placeholder = _assistantMessage(
        id: 'response-created-document-assistant',
        content: '',
        isStreaming: true,
        metadata: const <String, dynamic>{'transport': kHermesTransport},
      );
      container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
        placeholder,
      ]);

      await dispatchHermesRunFromChatForTest(
        container,
        assistantMessageId: placeholder.id,
        assistantSeed: placeholder,
        input: 'summarize',
        existingMessages: const <ChatMessage>[],
        responseInput: HermesChatInput.text(prompt),
        localDocumentPromptText: prompt,
        localDocumentEnvelopes: const <String>[envelope],
      ).timeout(const Duration(seconds: 1));

      final endpointIdentity = HermesConfigController.connectionEndpoint(
        service.config.baseUrl,
      )!;
      final connectionIdentity =
          HermesLocalDocumentTrustStore.connectionIdentity(
            endpointIdentity: endpointIdentity,
            principalId: container
                .read(hermesConfigProvider.notifier)
                .documentTrustPrincipalId(),
          );
      check(
        HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: connectionIdentity,
          sessionId: 'responses-session',
        ),
      ).deepEquals(<String>{
        HermesLocalDocumentTrustStore.documentTrustKey(
          messageId: 'server-user-1',
          promptText: prompt,
          documentEnvelope: envelope,
          startOffset: prompt.length - envelope.length,
        ),
      });
      container.read(chatMessagesProvider.notifier).clearMessages();
    });

    test(
      'Hermes document text is local-only and hidden from the bubble',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'conduit_hermes_send_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final document = File('${directory.path}/notes.txt');
        await document.writeAsString('private reference text');
        final attachment = FileUploadState(
          file: document,
          fileName: 'notes.txt',
          fileSize: await document.length(),
          progress: 1,
          status: FileUploadStatus.completed,
          fileId: 'hermes-local:composer-token',
          isImage: false,
        );
        final service = _ResponsesHermesApi();
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            attachedFilesProvider.overrideWith(
              () => _SeededAttachedFiles([attachment]),
            ),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());

        await sendMessageWithContainer(container, 'summarize', [
          'hermes-local:composer-token',
        ]);

        check(service.createRunCalls).equals(0);
        final requestText = service.inputs.single.toJson() as String;
        check(requestText).contains('private reference text');
        check(requestText).contains('BEGIN_HERMES_UNTRUSTED_REFERENCE');
        final user = container.read(chatMessagesProvider).first;
        check(user.content).equals('summarize');
        check(user.content).not((value) => value.contains('private reference'));
        check(user.files).isNotNull();
        check(user.files!.single['source']).equals('hermes_local');
        check(
          user.files!.single['hermes_extracted_text'],
        ).equals('private reference text');

        await regenerateEditedHermesUserMessage(
          container,
          messageId: user.id,
          content: 'summarize briefly',
        );

        check(service.inputs).length.equals(2);
        final editedRequest = service.inputs.last.toJson() as String;
        check(editedRequest).contains('summarize briefly');
        check(editedRequest).contains('private reference text');
        final editedUser = container.read(chatMessagesProvider).first;
        check(editedUser.content).equals('summarize briefly');
        check(editedUser.files!.single['source']).equals('hermes_local');
      },
    );

    test(
      'server switch during document extraction cannot route local text',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'conduit_hermes_admission_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final document = File('${directory.path}/notes.pdf');
        await document.writeAsBytes(const <int>[0x25, 0x50, 0x44, 0x46]);
        final attachment = FileUploadState(
          file: document,
          fileName: 'notes.pdf',
          fileSize: await document.length(),
          progress: 1,
          status: FileUploadStatus.completed,
          fileId: 'hermes-local:gated-pdf',
          isImage: false,
        );
        final extractionStarted = Completer<void>();
        final extractionGate = Completer<HermesPdfExtraction>();
        final documentService = HermesLocalDocumentService(
          pdfExtractor:
              (bytes, {required maxPages, required maxCharacters}) async {
                if (!extractionStarted.isCompleted) {
                  extractionStarted.complete();
                }
                return extractionGate.future;
              },
        );
        final oldService = _ResponsesHermesApi();
        final replacementService = _ResponsesHermesApi();
        final config = _RotatableAdmissionHermesConfigController();
        final serviceGeneration =
            NotifierProvider<_HermesServiceGeneration, HermesApiService?>(
              () => _HermesServiceGeneration(oldService),
            );
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(() => config),
            hermesApiServiceProvider.overrideWith(
              (ref) => ref.watch(serviceGeneration),
            ),
            hermesLocalDocumentServiceProvider.overrideWithValue(
              documentService,
            ),
            attachedFilesProvider.overrideWith(
              () => _SeededAttachedFiles([attachment]),
            ),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());

        final send = sendMessageWithContainer(container, 'summarize', [
          attachment.fileId!,
        ]);
        await extractionStarted.future.timeout(const Duration(seconds: 1));
        config.rotateServer();
        container.read(serviceGeneration.notifier).set(replacementService);
        extractionGate.complete(
          const HermesPdfExtraction(
            text: 'private replacement-bound text',
            pageCount: 1,
          ),
        );
        await send.timeout(const Duration(seconds: 1));

        check(oldService.inputs).isEmpty();
        check(replacementService.inputs).isEmpty();
        check(oldService.createSessionCalls).equals(0);
        check(replacementService.createSessionCalls).equals(0);
        check(container.read(chatMessagesProvider)).isEmpty();
      },
    );

    test(
      'server switch during initial send routing cannot capture replacement',
      () async {
        final oldService = _ResponsesHermesApi();
        final replacementService = _ResponsesHermesApi();
        final config = _RotatableAdmissionHermesConfigController();
        final serviceGeneration =
            NotifierProvider<_HermesServiceGeneration, HermesApiService?>(
              () => _HermesServiceGeneration(oldService),
            );
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(() => config),
            hermesApiServiceProvider.overrideWith(
              (ref) => ref.watch(serviceGeneration),
            ),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());

        final send = sendMessageWithContainer(
          container,
          'old-endpoint text',
          null,
        );
        config.rotateServer();
        container.read(serviceGeneration.notifier).set(replacementService);
        await send.timeout(const Duration(seconds: 1));

        check(oldService.inputs).isEmpty();
        check(replacementService.inputs).isEmpty();
        check(oldService.createSessionCalls).equals(0);
        check(replacementService.createSessionCalls).equals(0);
        check(container.read(chatMessagesProvider)).isEmpty();
      },
    );

    test(
      'server switch during regeneration routing cannot capture replacement',
      () async {
        final oldService = _ResponsesHermesApi();
        final replacementService = _ResponsesHermesApi();
        final config = _RotatableAdmissionHermesConfigController();
        final serviceGeneration =
            NotifierProvider<_HermesServiceGeneration, HermesApiService?>(
              () => _HermesServiceGeneration(oldService),
            );
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(() => config),
            hermesApiServiceProvider.overrideWith(
              (ref) => ref.watch(serviceGeneration),
            ),
          ],
        );
        addTearDown(container.dispose);
        final user = ChatMessage(
          id: 'route-regeneration-user',
          role: 'user',
          content: 'old-endpoint prompt',
          timestamp: DateTime(2024, 1, 1),
        );
        final assistant = _assistantMessage(
          id: 'route-regeneration-assistant',
          content: 'original answer',
          metadata: const <String, dynamic>{
            'transport': kHermesTransport,
            'hermesTransportMode': kHermesResponsesMode,
            'hermesResponseId': 'old-response',
          },
        );
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());
        container
            .read(activeConversationProvider.notifier)
            .set(
              markNativeHermesConversation(
                Conversation(
                  id: 'local:route-regeneration',
                  title: 'Route regeneration',
                  createdAt: DateTime(2024, 1, 1),
                  updatedAt: DateTime(2024, 1, 1),
                  messages: <ChatMessage>[user, assistant],
                  metadata: const <String, dynamic>{
                    'backend': 'hermes',
                    'hermesSessionId': 'old-session',
                  },
                ),
              ),
            );
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          user,
          assistant,
        ]);

        final regeneration = regenerateMessage(container, user.content, null);
        config.rotateServer();
        container.read(serviceGeneration.notifier).set(replacementService);
        await regeneration.timeout(const Duration(seconds: 1));

        check(oldService.inputs).isEmpty();
        check(replacementService.inputs).isEmpty();
        check(oldService.createSessionCalls).equals(0);
        check(replacementService.createSessionCalls).equals(0);
        check(
          container.read(chatMessagesProvider).last.content,
        ).equals('original answer');
      },
    );

    for (final stallPostCommit in <bool>[false, true]) {
      for (final configMutation in <bool>[false, true]) {
        test(
          '${configMutation ? 'config mutation' : 'Stop'} cancels a stalled '
          'existing-session document '
          '${stallPostCommit ? 'post-commit' : 'baseline'} request',
          () async {
            SharedPreferences.setMockInitialValues(<String, Object>{
              PreferenceKeys.hermesEnabled: true,
            });
            PreferencesStore.debugOverride(
              await SharedPreferences.getInstance(),
            );
            addTearDown(PreferencesStore.debugReset);

            final service = _StalledDocumentBaselineHermesApi(
              stallPostCommit: stallPostCommit,
            );
            addTearDown(service.dispose);
            final container = _testContainer(
              overrides: [
                activeConversationProvider.overrideWith(
                  () => _TestActiveConversationNotifier(),
                ),
                apiServiceProvider.overrideWithValue(null),
                socketServiceProvider.overrideWithValue(null),
                hermesConfigProvider.overrideWith(
                  () => _FixedHermesConfigController(),
                ),
                hermesApiServiceProvider.overrideWithValue(service),
              ],
            );
            addTearDown(container.dispose);

            final placeholder = _assistantMessage(
              id: 'stalled-document-baseline',
              content: '',
              isStreaming: true,
              metadata: const <String, dynamic>{
                'transport': kHermesTransport,
                'hermesTransportMode': kHermesResponsesMode,
                'hermesResponseId': 'existing-response',
              },
            );
            container
                .read(activeConversationProvider.notifier)
                .set(
                  markNativeHermesConversation(
                    Conversation(
                      id: 'local:hermes-baseline',
                      title: 'Hermes baseline',
                      createdAt: DateTime(2024, 1, 1),
                      updatedAt: DateTime(2024, 1, 1),
                      messages: <ChatMessage>[placeholder],
                      metadata: const <String, dynamic>{
                        'backend': 'hermes',
                        'hermesSessionId': 'existing-session',
                      },
                    ),
                  ),
                );
            await Future<void>.delayed(Duration.zero);

            final dispatch = dispatchHermesRunFromChatForTest(
              container,
              assistantMessageId: placeholder.id,
              assistantSeed: placeholder,
              input: 'summarize',
              existingMessages: const <ChatMessage>[],
              responseInput: HermesChatInput.text(
                'summarize\nBEGIN_HERMES_UNTRUSTED_REFERENCE\nprivate\n'
                'END_HERMES_UNTRUSTED_REFERENCE',
              ),
              localDocumentPromptText: 'summarize',
              localDocumentEnvelopes: const <String>[
                'BEGIN_HERMES_UNTRUSTED_REFERENCE\nprivate\n'
                    'END_HERMES_UNTRUSTED_REFERENCE',
              ],
              previousResponseIdOverride: 'existing-response',
            );
            await service.historyStarted.future.timeout(
              const Duration(seconds: 1),
            );

            check(service.historyCancelToken).isNotNull();
            final Future<void> cancellation;
            if (configMutation) {
              cancellation = container
                  .read(hermesConfigProvider.notifier)
                  .setEnabled(false);
            } else {
              cancellation = container
                  .read(hermesRunRegistryProvider)
                  .cancelMessage(placeholder.id)!;
            }

            await service.historyCancelled.future.timeout(
              const Duration(seconds: 1),
            );
            await cancellation.timeout(const Duration(seconds: 1));
            await dispatch.timeout(const Duration(seconds: 1));

            check(service.historyCancelToken!.isCancelled).isTrue();
            check(service.historyCalls).equals(stallPostCommit ? 2 : 1);
            check(service.responseCalls).equals(stallPostCommit ? 1 : 0);
            if (stallPostCommit) {
              check(service.historyCancelTokens).length.equals(2);
              check(
                service.historyCancelTokens[0],
              ).identicalTo(service.historyCancelTokens[1]);
              check(
                service.historyCancelTokens[1],
              ).identicalTo(service.responseCancelToken);
            }
            check(
              container.read(chatMessagesProvider).single.isStreaming,
            ).isFalse();
            if (configMutation) {
              check(container.read(hermesConfigProvider).enabled).isFalse();
            }
            container.read(chatMessagesProvider.notifier).clearMessages();
          },
        );
      }
    }

    test(
      'successful document sends persist exact server provenance for reopen',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        PreferencesStore.debugOverride(await SharedPreferences.getInstance());
        HermesLocalDocumentTrustStore.debugResetRuntimeState();
        addTearDown(() {
          HermesLocalDocumentTrustStore.debugResetRuntimeState();
          PreferencesStore.debugReset();
        });

        final directory = await Directory.systemTemp.createTemp(
          'conduit_hermes_trust_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final document = File('${directory.path}/notes.txt');
        await document.writeAsString('private reference text');
        final attachment = FileUploadState(
          file: document,
          fileName: 'notes.txt',
          fileSize: await document.length(),
          progress: 1,
          status: FileUploadStatus.completed,
          fileId: 'hermes-local:trusted-composer-token',
          isImage: false,
        );
        final attachedFiles = _SeededAttachedFiles([attachment]);
        final service = _ResponsesHermesApi(uniqueSessionIds: true);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            hermesCapabilitiesProvider.overrideWith(
              (ref) async => const HermesCapabilities(inputImages: false),
            ),
            attachedFilesProvider.overrideWith(() => attachedFiles),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());
        container.read(attachedFilesProvider);

        Future<void> sendDocument() async {
          attachedFiles.reseed();
          await sendMessageWithContainer(container, 'summarize', [
            attachment.fileId!,
          ]);
        }

        await sendDocument();
        final firstPrompt = service.inputs.single.toJson() as String;
        final firstServerHistory = await service.getSessionMessages(
          'responses-session-1',
        );
        check(firstServerHistory).length.equals(1);
        check(
          firstServerHistory
              .map((raw) => raw['id']?.toString().trim())
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toSet(),
        ).deepEquals(<String>{'server-user-1'});
        await sendDocument();
        check(service.inputs.last.toJson()).equals(firstPrompt);

        final endpointIdentity = HermesConfigController.connectionEndpoint(
          service.config.baseUrl,
        )!;
        final connectionIdentity =
            HermesLocalDocumentTrustStore.connectionIdentity(
              endpointIdentity: endpointIdentity,
              principalId: container
                  .read(hermesConfigProvider.notifier)
                  .documentTrustPrincipalId(),
            );
        final trustedKeys = HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: connectionIdentity,
          sessionId: 'responses-session-1',
        );
        // Both identical prompts have distinct server ids. The second send's
        // pre-dispatch baseline must exclude the older row, not bless it in
        // place of the newly committed request.
        check(trustedKeys).length.equals(2);
        final reopened = hermesMessagesToChatMessages(
          await service.getSessionMessages('responses-session-1'),
          trustedLocalDocumentKeys: trustedKeys,
        );
        check(reopened).length.equals(2);
        check(
          reopened.every((message) => message.content == 'summarize'),
        ).isTrue();
        check(
          reopened.every(
            (message) => message.files?.single['source'] == 'hermes_local',
          ),
        ).isTrue();

        await regenerateMessage(container, 'summarize', <String>[
          attachment.fileId!,
        ]);
        final regeneratedTrust =
            HermesLocalDocumentTrustStore.trustedDocumentKeys(
              connectionIdentity: connectionIdentity,
              sessionId: 'responses-session-2',
            );
        check(regeneratedTrust).length.equals(1);
        final reopenedRegeneration = hermesMessagesToChatMessages(
          await service.getSessionMessages('responses-session-2'),
          trustedLocalDocumentKeys: regeneratedTrust,
        );
        check(reopenedRegeneration).length.equals(1);
        check(reopenedRegeneration.single.content).equals('summarize');
        check(
          reopenedRegeneration.single.files?.single['source'],
        ).equals('hermes_local');

        service.failNextResponse = true;
        await sendDocument();
        check(service.committedUserMessages).length.equals(3);
        check(
          HermesLocalDocumentTrustStore.trustedDocumentKeys(
            connectionIdentity: connectionIdentity,
            sessionId: 'responses-session-2',
          ),
        ).length.equals(1);
      },
    );

    test(
      'failed Hermes inline regeneration restores the original transcript',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        final originalMessages = <ChatMessage>[
          ChatMessage(
            id: 'user-edit',
            role: 'user',
            content: 'original prompt',
            timestamp: DateTime(2024, 1, 1),
          ),
          _assistantMessage(id: 'assistant-edit', content: 'original answer'),
          ChatMessage(
            id: 'user-later',
            role: 'user',
            content: 'later prompt',
            timestamp: DateTime(2024, 1, 2),
          ),
          _assistantMessage(id: 'assistant-later', content: 'later answer'),
        ];
        container
            .read(activeConversationProvider.notifier)
            .set(
              markNativeHermesConversation(
                Conversation(
                  id: 'local:hermes_edit-session',
                  title: 'Hermes edit',
                  createdAt: DateTime(2024, 1, 1),
                  updatedAt: DateTime(2024, 1, 2),
                  messages: originalMessages,
                  metadata: const <String, dynamic>{'backend': 'hermes'},
                ),
              ),
            );

        // A missing selected model fails regeneration after the optimistic
        // edited prefix has been installed.
        await expectLater(
          regenerateEditedHermesUserMessage(
            container,
            messageId: 'user-edit',
            content: 'edited prompt',
          ),
          throwsA(isA<Exception>()),
        );

        check(
          container.read(chatMessagesProvider).map((message) => message.id),
        ).deepEquals(originalMessages.map((message) => message.id));
        check(
          container
              .read(chatMessagesProvider)
              .map((message) => message.content),
        ).deepEquals(originalMessages.map((message) => message.content));
      },
    );

    test(
      'failed Hermes edit does not restore into a colliding storage scope',
      () async {
        final fixture = _buildDelayedHermesEditFixture();
        final container = fixture.container;
        addTearDown(container.dispose);
        final failure = expectLater(
          regenerateEditedHermesUserMessage(
            container,
            messageId: 'user-edit',
            content: 'edited prompt',
          ),
          throwsA(isA<StateError>()),
        );
        await Future<void>.delayed(Duration.zero);

        final collidingMessages = <ChatMessage>[
          _assistantMessage(
            id: 'direct-assistant',
            content: 'independent direct transcript',
          ),
        ];
        container
            .read(activeConversationProvider.notifier)
            .set(
              withChatStorageProvenance(
                Conversation(
                  id: 'shared-id',
                  title: 'Direct collision',
                  createdAt: DateTime(2024, 1, 2),
                  updatedAt: DateTime(2024, 1, 2),
                  messages: collidingMessages,
                ),
                ChatStorageKind.directLocal,
              ),
            );
        fixture.profiles.complete(const <DirectConnectionProfile>[]);
        await failure;

        check(
          container.read(chatMessagesProvider).map((message) => message.id),
        ).deepEquals(collidingMessages.map((message) => message.id));
        check(
          chatStorageKindOf(container.read(activeConversationProvider)),
        ).equals(ChatStorageKind.directLocal);
      },
    );

    test(
      'failed Hermes edit preserves an independent same-chat mutation',
      () async {
        final fixture = _buildDelayedHermesEditFixture();
        final container = fixture.container;
        addTearDown(container.dispose);
        final failure = expectLater(
          regenerateEditedHermesUserMessage(
            container,
            messageId: 'user-edit',
            content: 'edited prompt',
          ),
          throwsA(isA<Exception>()),
        );
        await Future<void>.delayed(Duration.zero);

        final independentlyChanged = <ChatMessage>[
          ...fixture.originalMessages,
          ChatMessage(
            id: 'independent-user',
            role: 'user',
            content: 'newer local change',
            timestamp: DateTime(2024, 1, 2),
          ),
        ];
        container
            .read(chatMessagesProvider.notifier)
            .setMessages(independentlyChanged);
        fixture.profiles.complete(const <DirectConnectionProfile>[]);
        await failure;

        expect(
          container.read(chatMessagesProvider),
          same(independentlyChanged),
        );
      },
    );

    test('conversation switch cancels active stream subscriptions', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);

      container
          .read(activeConversationProvider.notifier)
          .set(
            _conversation('chat-1', [
              _assistantMessage(content: 'Draft', isStreaming: true),
            ]),
          );

      var subscriptionDisposed = false;
      var teardownDisposed = false;
      container.read(chatMessagesProvider.notifier).setSocketSubscriptions(
        'assistant-1',
        [() => subscriptionDisposed = true],
        onDispose: () => teardownDisposed = true,
      );

      container
          .read(activeConversationProvider.notifier)
          .set(
            _conversation('chat-2', [
              _assistantMessage(id: 'assistant-2', content: 'Other chat'),
            ]),
          );
      await Future<void>.delayed(Duration.zero);

      check(subscriptionDisposed).isTrue();
      check(teardownDisposed).isTrue();
      check(
        container.read(chatMessagesProvider).single.id,
      ).equals('assistant-2');
    });

    test('streaming buffer sync keeps the assistant message streaming', () {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(content: 'Buffered', isStreaming: true),
      ]);

      notifier.appendToLastMessage(' content');
      notifier.syncStreamingBuffer();

      final message = container.read(chatMessagesProvider).single;
      check(message.content).equals('Buffered content');
      check(message.isStreaming).isTrue();

      notifier.clearMessages();
    });

    test('clearMessages cannot carry a Hermes buffer into the next chat', () {
      final container = _buildContainer();
      addTearDown(container.dispose);
      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(id: 'old', content: '', isStreaming: true),
      ]);
      notifier.appendToLastMessage('old answer');

      notifier.clearMessages();
      notifier.setMessages([
        _assistantMessage(id: 'new', content: '', isStreaming: true),
      ]);
      notifier.appendToLastMessage('new answer');
      notifier.syncStreamingBuffer();

      check(
        container.read(chatMessagesProvider).single.content,
      ).equals('new answer');
      notifier.clearMessages();
    });

    test('message-scoped Hermes callbacks cannot mutate a newer stream', () {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(id: 'old', content: 'old:', isStreaming: true),
        _assistantMessage(id: 'new', content: 'new:', isStreaming: true),
      ]);

      notifier.appendToMessageById('old', 'late');
      notifier.finishStreamingMessage('old');

      final messages = container.read(chatMessagesProvider);
      check(messages[0].content).equals('old:late');
      check(messages[0].isStreaming).isFalse();
      check(messages[1].content).equals('new:');
      check(messages[1].isStreaming).isTrue();
      notifier.clearMessages();
    });

    test(
      'non-tail completion syncs the active conversation snapshot',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        final user = ChatMessage(
          id: 'user-old',
          role: 'user',
          content: 'old question',
          timestamp: DateTime(2024, 1, 1),
        );
        final messages = [
          user,
          _assistantMessage(
            id: 'old',
            content: 'old answer',
            isStreaming: true,
          ),
          ChatMessage(
            id: 'user-new',
            role: 'user',
            content: 'new question',
            timestamp: DateTime(2024, 1, 1),
          ),
          _assistantMessage(id: 'new', content: '', isStreaming: true),
        ];
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', messages));
        await Future<void>.delayed(Duration.zero);

        container
            .read(chatMessagesProvider.notifier)
            .finishStreamingMessage('old');

        final active = container.read(activeConversationProvider)!;
        check(active.messages[1].id).equals('old');
        check(active.messages[1].isStreaming).isFalse();
        check(active.messages.last.id).equals('new');
        check(active.messages.last.isStreaming).isTrue();
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'late Hermes completion cannot overwrite a newly active conversation',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        final notifier = container.read(chatMessagesProvider.notifier);
        final oldMessages = [
          _assistantMessage(id: 'old', content: 'old', isStreaming: true),
          _assistantMessage(id: 'new', content: 'new', isStreaming: true),
        ];
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', oldMessages));
        await Future<void>.delayed(Duration.zero);

        final activeMessages = [
          _assistantMessage(id: 'active', content: 'active chat'),
        ];
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-2', activeMessages));
        await Future<void>.delayed(Duration.zero);

        // Model a retained late-run snapshot after navigation. Completion must
        // reject the old owner before mutating state or syncing chat-2.
        notifier.setMessages(oldMessages);
        notifier.finishStreamingMessage(
          'old',
          ownerConversationId: 'chat-1',
          requireConversationOwner: true,
        );

        check(container.read(chatMessagesProvider).first.isStreaming).isTrue();
        final active = container.read(activeConversationProvider)!;
        check(active.id).equals('chat-2');
        check(active.messages).length.equals(1);
        check(active.messages.single.id).equals('active');
        notifier.clearMessages();
      },
    );

    test(
      'Hermes session is captured before key setup while navigation changes',
      () async {
        final config = _GatedHermesConfigController();
        final service = _SessionRecordingHermesApi();
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(() => config),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);

        final sharedAssistant = _assistantMessage(
          id: 'copied-assistant',
          content: 'A:',
          isStreaming: true,
          metadata: const {'transport': 'hermesRun'},
        );
        final conversationA = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes_session-a',
            title: 'Hermes A',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: [sharedAssistant],
            metadata: const {
              'backend': 'hermes',
              'hermesSessionId': 'session-a',
            },
          ),
        );
        container.read(activeConversationProvider.notifier).set(conversationA);
        await Future<void>.delayed(Duration.zero);

        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: 'copied-assistant',
          input: 'input-for-a',
          existingMessages: const [],
        );
        await config.started.future.timeout(const Duration(seconds: 1));

        final conversationB = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes_session-b',
            title: 'Hermes B',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: [
              _assistantMessage(
                id: 'copied-assistant',
                content: 'B untouched',
                isStreaming: true,
                metadata: const {'transport': 'hermesRun'},
              ),
            ],
            metadata: const {
              'backend': 'hermes',
              'hermesSessionId': 'session-b',
            },
          ),
        );
        container.read(activeConversationProvider.notifier).set(conversationB);
        await Future<void>.delayed(Duration.zero);

        config.gate.complete('memory');
        await dispatch.timeout(const Duration(seconds: 1));

        check(service.inputs).deepEquals(['input-for-a']);
        check(service.sessionIds).deepEquals(['session-a']);
        check(
          container.read(activeConversationProvider)!.id,
        ).equals(conversationB.id);
        final visible = container.read(chatMessagesProvider).single;
        check(visible.id).equals('copied-assistant');
        check(visible.content).equals('B untouched');
        check(visible.isStreaming).isTrue();
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test('fresh Hermes chat never inherits a stale global session', () async {
      final service = _SessionRecordingHermesApi();
      final container = _testContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(),
          ),
          hermesApiServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      container.read(hermesActiveSessionProvider.notifier).set('stale-session');
      container.read(chatMessagesProvider.notifier).setMessages([
        _assistantMessage(
          id: 'fresh-assistant',
          content: '',
          isStreaming: true,
          metadata: const {'transport': 'hermesRun'},
        ),
      ]);

      await dispatchHermesRunFromChatForTest(
        container,
        assistantMessageId: 'fresh-assistant',
        input: 'brand new chat',
        existingMessages: const [],
      );

      check(service.createSessionCalls).equals(1);
      check(service.sessionIds).deepEquals(['fresh-session']);
      check(
        container.read(hermesActiveSessionProvider),
      ).equals('fresh-session');
      check(
        container.read(activeConversationProvider)!.id,
      ).equals('local:hermes_fresh-session');
      container.read(chatMessagesProvider.notifier).clearMessages();
    });

    test('Hermes text turns replay prior visible session messages', () async {
      final service = _SessionRecordingHermesApi();
      final container = _testContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(),
          ),
          hermesApiServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final priorMessages = <ChatMessage>[
        ChatMessage(
          id: 'prior-user',
          role: 'user',
          content: 'Remember the code word cobalt.',
          timestamp: DateTime.utc(2026, 7, 16),
        ),
        _assistantMessage(
          id: 'prior-assistant',
          content: 'I will remember cobalt.',
        ),
      ];
      final placeholder = _assistantMessage(
        id: 'continued-assistant',
        content: '',
        isStreaming: true,
        metadata: const <String, dynamic>{'transport': kHermesTransport},
      );
      container
          .read(activeConversationProvider.notifier)
          .set(
            markNativeHermesConversation(
              Conversation(
                id: 'local:hermes_remembering-session',
                title: 'Remembering session',
                createdAt: DateTime.utc(2026, 7, 16),
                updatedAt: DateTime.utc(2026, 7, 16),
                messages: <ChatMessage>[...priorMessages, placeholder],
                metadata: const <String, dynamic>{
                  'backend': 'hermes',
                  'hermesSessionId': 'remembering-session',
                },
              ),
            ),
          );
      await Future<void>.delayed(Duration.zero);

      await dispatchHermesRunFromChatForTest(
        container,
        assistantMessageId: placeholder.id,
        assistantSeed: placeholder,
        input: 'What was the code word?',
        existingMessages: priorMessages,
      );

      check(service.sessionIds).deepEquals(<String?>['remembering-session']);
      expect(
        service.conversationHistories.single,
        equals(<Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'Remember the code word cobalt.',
          },
          <String, dynamic>{
            'role': 'assistant',
            'content': 'I will remember cobalt.',
          },
        ]),
      );
      container.read(chatMessagesProvider.notifier).clearMessages();
    });

    test('new Hermes session refreshes the mounted sidebar list', () async {
      final service = _SessionListingHermesApi();
      final container = _testContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(),
          ),
          hermesApiServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final sidebarSubscription = container.listen(
        hermesSessionsProvider,
        (_, _) {},
      );
      addTearDown(sidebarSubscription.close);

      check(await container.read(hermesSessionsProvider.future)).isEmpty();
      container.read(chatMessagesProvider.notifier).setMessages([
        _assistantMessage(
          id: 'sidebar-refresh-assistant',
          content: '',
          isStreaming: true,
          metadata: const {'transport': 'hermesRun'},
        ),
      ]);

      await dispatchHermesRunFromChatForTest(
        container,
        assistantMessageId: 'sidebar-refresh-assistant',
        input: 'brand new chat',
        existingMessages: const [],
      );

      final sessions = await container.read(hermesSessionsProvider.future);
      check(
        sessions.map((session) => session.id).toList(),
      ).deepEquals(['fresh-session']);
      check(service.listSessionsCalls).equals(2);
      container.read(chatMessagesProvider.notifier).clearMessages();
    });

    test(
      'response-created Hermes session refreshes the sidebar list',
      () async {
        final service = _ResponseSessionListingHermesApi(
          failSessionCreation: true,
        );
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        final sidebarSubscription = container.listen(
          hermesSessionsProvider,
          (_, _) {},
        );
        addTearDown(sidebarSubscription.close);

        check(await container.read(hermesSessionsProvider.future)).isEmpty();
        container.read(chatMessagesProvider.notifier).setMessages([
          _assistantMessage(
            id: 'response-sidebar-refresh-assistant',
            content: '',
            isStreaming: true,
            metadata: const {'transport': 'hermesRun'},
          ),
        ]);

        await dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: 'response-sidebar-refresh-assistant',
          input: 'brand new response chat',
          existingMessages: const [],
          responseInput: HermesChatInput.text('brand new response chat'),
        );

        final sessions = await container.read(hermesSessionsProvider.future);
        check(
          sessions.map((session) => session.id).toList(),
        ).deepEquals(['responses-session']);
        check(service.listSessionsCalls).equals(2);
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'existing Hermes Responses turn does not refetch the sidebar',
      () async {
        final service = _ResponseSessionListingHermesApi(
          sessionAlreadyExists: true,
        );
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        final sidebarSubscription = container.listen(
          hermesSessionsProvider,
          (_, _) {},
        );
        addTearDown(sidebarSubscription.close);
        check(
          (await container.read(hermesSessionsProvider.future)).single.id,
        ).equals('responses-session');

        final placeholder = _assistantMessage(
          id: 'existing-response-sidebar-assistant',
          content: '',
          isStreaming: true,
          metadata: const {'transport': 'hermesRun'},
        );
        container
            .read(activeConversationProvider.notifier)
            .set(
              markNativeHermesConversation(
                Conversation(
                  id: 'local:hermes_responses-session',
                  title: 'Existing chat',
                  createdAt: DateTime(2026, 7, 16),
                  updatedAt: DateTime(2026, 7, 16),
                  messages: [placeholder],
                  metadata: const {
                    'backend': 'hermes',
                    'hermesSessionId': 'responses-session',
                  },
                ),
              ),
            );
        await Future<void>.delayed(Duration.zero);

        await dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: placeholder.id,
          assistantSeed: placeholder,
          input: 'continue existing response chat',
          existingMessages: const [],
          responseInput: HermesChatInput.text(
            'continue existing response chat',
          ),
        );

        check(service.listSessionsCalls).equals(1);
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'unsafe legacy Hermes session ids are replaced before binding',
      () async {
        final invalidSessionIds = <Object?>[
          {
            'nested': ['session'],
          },
          'key',
          'session\ncontrol',
          List<String>.filled(
            kMaxHermesOpaqueIdentifierCharacters + 1,
            'a',
          ).join(),
        ];

        for (var index = 0; index < invalidSessionIds.length; index++) {
          final service = _SessionRecordingHermesApi();
          final container = _testContainer(
            overrides: [
              activeConversationProvider.overrideWith(
                () => _TestActiveConversationNotifier(),
              ),
              apiServiceProvider.overrideWithValue(null),
              socketServiceProvider.overrideWithValue(null),
              hermesConfigProvider.overrideWith(
                () => _FixedHermesConfigController(),
              ),
              hermesApiServiceProvider.overrideWithValue(service),
            ],
          );
          addTearDown(container.dispose);
          final placeholder = _assistantMessage(
            id: 'unsafe-session-$index',
            content: '',
            isStreaming: true,
            metadata: const {'transport': 'hermesRun'},
          );
          container
              .read(activeConversationProvider.notifier)
              .set(
                markNativeHermesConversation(
                  Conversation(
                    id: 'local:hermes_legacy-$index',
                    title: 'Legacy Hermes chat',
                    createdAt: DateTime(2024, 1, 1),
                    updatedAt: DateTime(2024, 1, 1),
                    messages: [placeholder],
                    metadata: <String, dynamic>{
                      'backend': 'hermes',
                      'hermesSessionId': invalidSessionIds[index],
                    },
                  ),
                ),
              );
          await Future<void>.delayed(Duration.zero);

          await dispatchHermesRunFromChatForTest(
            container,
            assistantMessageId: placeholder.id,
            input: 'continue safely',
            existingMessages: const [],
          );

          check(service.createSessionCalls).equals(1);
          check(service.sessionIds).deepEquals(['fresh-session']);
          check(
            container
                .read(activeConversationProvider)!
                .metadata['hermesSessionId'],
          ).equals('fresh-session');
          container.read(chatMessagesProvider.notifier).clearMessages();
        }
      },
    );

    test(
      'copied ids across stores neither cross-cancel nor receive late chunks',
      () async {
        final events = StreamController<HermesRunEvent>();
        addTearDown(events.close);
        final service = _SessionRecordingHermesApi(events: events);
        final locks = _FailOnceConversationLocks();
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            chatLocksProvider.overrideWithValue(locks),
          ],
        );
        addTearDown(container.dispose);

        final placeholderA = _assistantMessage(
          id: 'same-assistant',
          content: 'A:',
          isStreaming: true,
          metadata: const {'transport': 'hermesRun'},
        );
        final conversationA = withChatStorageProvenance(
          Conversation(
            id: 'shared-chat',
            title: 'OpenWebUI A',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: [placeholderA],
          ),
          ChatStorageKind.openWebUi,
        );
        await _seedDurableAssistantOwner(
          container.read(appDatabaseProvider)!,
          chatId: conversationA.id,
          assistant: placeholderA,
        );
        container.read(activeConversationProvider.notifier).set(conversationA);
        await Future<void>.delayed(Duration.zero);

        final endpointIdentity = HermesConfigController.connectionEndpoint(
          service.config.baseUrl,
        )!;
        final connectionIdentity =
            HermesLocalDocumentTrustStore.connectionIdentity(
              endpointIdentity: endpointIdentity,
              principalId: container
                  .read(hermesConfigProvider.notifier)
                  .documentTrustPrincipalId(),
            );
        final history = _assistantMessage(
          id: 'history-a',
          content: 'earlier',
          metadata: {
            'hermesSessionId': 'session-a',
            kHermesConnectionIdentityMetadataKey: connectionIdentity,
          },
        );
        await rememberMixedHermesMessageProvenanceForTest(
          container,
          conversation: conversationA,
          assistantMessage: history,
        );
        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: 'same-assistant',
          input: 'continue-a',
          existingMessages: [history],
        );
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );

        final conversationB = withChatStorageProvenance(
          Conversation(
            id: 'shared-chat',
            title: 'Direct B',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: [
              _assistantMessage(
                id: 'same-assistant',
                content: 'B untouched',
                isStreaming: true,
                metadata: const {'transport': 'hermesRun'},
              ),
            ],
          ),
          ChatStorageKind.directLocal,
        );
        container.read(activeConversationProvider.notifier).set(conversationB);
        await Future<void>.delayed(Duration.zero);

        final registry = container.read(hermesRunRegistryProvider);
        final keyB = hermesRunKey(
          ownerConversationId: chatMutationOwnerScopeForConversation(
            conversationB,
          ),
          assistantMessageId: 'same-assistant',
        );
        final tokenB = registry.registerPending(keyB, onCancelled: () {});
        final stopB = registry.cancelMessage(
          'same-assistant',
          ownerConversationId: keyB.ownerConversationId,
        );
        check(stopB).isNotNull();
        await stopB!;
        check(tokenB.isCancelled).isTrue();
        check(service.createRunCancelToken!.isCancelled).isFalse();

        events.add(const HermesTokenDelta('late A'));
        events.add(const HermesToolProgress(toolName: 'search', done: false));
        events.add(const HermesRunError('hidden failure'));
        events.add(const HermesRunDone());
        await dispatch.timeout(const Duration(seconds: 1));

        check(service.inputs).deepEquals(['continue-a']);
        check(service.sessionIds).deepEquals(['session-a']);
        // The foreign store's stop did not touch A, but A's own terminal event
        // must still close its HTTP transport once dispatch settles.
        check(service.createRunCancelToken!.isCancelled).isTrue();
        check(
          container.read(activeConversationProvider)!.id,
        ).equals(conversationB.id);
        final visible = container.read(chatMessagesProvider).single;
        check(visible.id).equals('same-assistant');
        check(visible.content).equals('B untouched');

        // Reopening A must replay its owner-bound final snapshot even though
        // dispatch and all of its subscriptions already settled while B was
        // visible. Text, status, and error are one atomic projection.
        container.read(activeConversationProvider.notifier).set(conversationA);
        await Future<void>.delayed(Duration.zero);
        final restored = container.read(chatMessagesProvider).single;
        check(restored.id).equals('same-assistant');
        check(restored.content).equals('A:late A');
        check(restored.isStreaming).isFalse();
        check(restored.error?.content).equals('hidden failure');
        check(restored.statusHistory).single
            .has((status) => status.action, 'action')
            .equals('hermes_tool_search');

        // The initial durable write failed through [_FailOnceConversationLocks].
        // Recovery adoption retries against the same captured database owner;
        // once that succeeds the projection can safely be consumed.
        await pumpEventQueue();
        final durable = await container
            .read(appDatabaseProvider)!
            .messagesDao
            .getMessage(conversationA.id, placeholderA.id);
        check(durable).isNotNull();
        check(durable!.content).equals('A:late A');

        // The retained final is a one-adoption bridge, not a permanent
        // override. A later authoritative pull/edit for the same row wins.
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          _assistantMessage(
            id: 'same-assistant',
            content: 'Server-edited answer',
            metadata: const <String, dynamic>{
              'transport': kHermesTransport,
              'hermesRunId': 'recorded-run',
            },
          ),
        ]);
        final authoritative = container.read(chatMessagesProvider).single;
        check(authoritative.content).equals('Server-edited answer');
        check(authoritative.error).isNull();
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'failed OpenWebUI persistence survives trim and retries on adoption',
      () async {
        final service = _MultiRunHermesApi();
        final locks = _FailOnceConversationLocks();
        addTearDown(service.closeStreams);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            chatLocksProvider.overrideWithValue(locks),
            hermesProjectionRetentionLimitsProvider.overrideWithValue((
              maxProjections: 1,
              maxBytes: 1024 * 1024,
            )),
          ],
        );
        addTearDown(container.dispose);
        final database = container.read(appDatabaseProvider)!;
        final assistantA = _assistantMessage(
          id: 'retry-after-trim-a',
          content: '',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final conversationA = withChatStorageProvenance(
          _conversation('retry-after-trim-chat', <ChatMessage>[assistantA]),
          ChatStorageKind.openWebUi,
        );
        await _seedDurableAssistantOwner(
          database,
          chatId: conversationA.id,
          assistant: assistantA,
        );
        container.read(activeConversationProvider.notifier).set(conversationA);
        await Future<void>.delayed(Duration.zero);
        final historyA = _assistantMessage(
          id: 'retry-history-a',
          metadata: const <String, dynamic>{
            'hermesSessionId': 'retry-session-a',
          },
        );
        final dispatchA = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: assistantA.id,
          input: 'retry-a',
          existingMessages: <ChatMessage>[historyA],
        );

        final assistantB = _assistantMessage(
          id: 'retry-after-trim-b',
          content: '',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final conversationB = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes_retry-session-b',
            title: 'Native Hermes B',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: <ChatMessage>[assistantB],
            metadata: const <String, dynamic>{
              'backend': 'hermes',
              'hermesSessionId': 'retry-session-b',
            },
          ),
        );
        container.read(activeConversationProvider.notifier).set(conversationB);
        await Future<void>.delayed(Duration.zero);
        final dispatchB = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: assistantB.id,
          input: 'retry-b',
          existingMessages: const <ChatMessage>[],
        );
        await service.twoStreamsStarted.future.timeout(
          const Duration(seconds: 1),
        );
        service
          ..emit('retry-a', const HermesTokenDelta('Durable A'))
          ..emit('retry-a', const HermesRunDone())
          ..emit('retry-b', const HermesTokenDelta('Disposable B'))
          ..emit('retry-b', const HermesRunDone());
        await Future.wait(<Future<void>>[
          dispatchA,
          dispatchB,
        ]).timeout(const Duration(seconds: 1));

        final failedPrimary = await database.messagesDao.getMessage(
          conversationA.id,
          assistantA.id,
        );
        check(failedPrimary).isNotNull();
        check(failedPrimary!.content).isEmpty();

        container.read(activeConversationProvider.notifier).set(conversationA);
        await pumpEventQueue();
        final retried = await database.messagesDao.getMessage(
          conversationA.id,
          assistantA.id,
        );
        check(retried).isNotNull();
        check(retried!.content).equals('Durable A');
        final payload = jsonDecode(retried.payload) as Map<String, dynamic>;
        check(payload['isStreaming']).equals(false);
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'Hermes approval received offscreen reappears when its owner returns',
      () async {
        final events = StreamController<HermesRunEvent>();
        addTearDown(events.close);
        final service = _SessionRecordingHermesApi(events: events);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        final placeholder = _assistantMessage(
          id: 'approval-assistant',
          content: '',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final conversationA = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes_approval-a',
            title: 'Hermes approval A',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: <ChatMessage>[placeholder],
            metadata: const <String, dynamic>{
              'backend': 'hermes',
              'hermesSessionId': 'approval-a',
            },
          ),
        );
        container.read(activeConversationProvider.notifier).set(conversationA);
        await Future<void>.delayed(Duration.zero);

        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: placeholder.id,
          input: 'ask before acting',
          existingMessages: const <ChatMessage>[],
        );
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );

        final conversationB = _conversation('other-chat', <ChatMessage>[
          _assistantMessage(id: 'other-assistant', content: 'B untouched'),
        ]);
        container.read(activeConversationProvider.notifier).set(conversationB);
        await Future<void>.delayed(Duration.zero);
        events.add(
          const HermesApprovalRequested(
            approvalId: 'approval-1',
            summary: 'Run a command?',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(
          container.read(chatMessagesProvider).single.content,
        ).equals('B untouched');

        container.read(activeConversationProvider.notifier).set(conversationA);
        await Future<void>.delayed(Duration.zero);
        final restored = container.read(chatMessagesProvider).single;
        final approval = restored.metadata?[kHermesApprovalMeta] as Map;
        check(restored.isStreaming).isTrue();
        check(approval['state']).equals('pending');
        check(approval['runId']).equals('recorded-run');
        check(approval['approvalId']).equals('approval-1');
        check(approval['summary']).equals('Run a command?');

        events.add(const HermesRunDone());
        await dispatch.timeout(const Duration(seconds: 1));
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'same-content Hermes turns restore by message identity, not list order',
      () async {
        final service = _MultiRunHermesApi();
        addTearDown(service.closeStreams);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);

        final first = _assistantMessage(
          id: 'duplicate-first',
          content: '',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final second = _assistantMessage(
          id: 'duplicate-second',
          content: '',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final third = _assistantMessage(
          id: 'lagging-third',
          content: '',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final fourth = _assistantMessage(
          id: 'lagging-fourth',
          content: '',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final conversation = withChatStorageProvenance(
          _conversation('duplicate-hermes-chat', <ChatMessage>[
            first,
            second,
            third,
            fourth,
          ]),
          ChatStorageKind.openWebUi,
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        await Future<void>.delayed(Duration.zero);
        final sessionHistory = <ChatMessage>[
          _assistantMessage(
            id: 'duplicate-history',
            metadata: const <String, dynamic>{
              'hermesSessionId': 'duplicate-session',
            },
          ),
        ];

        final firstDispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: first.id,
          input: 'first',
          existingMessages: sessionHistory,
        );
        final secondDispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: second.id,
          input: 'second',
          existingMessages: sessionHistory,
        );
        final thirdDispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: third.id,
          input: 'third',
          existingMessages: sessionHistory,
        );
        final fourthDispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: fourth.id,
          input: 'fourth',
          existingMessages: sessionHistory,
        );
        await service.fourStreamsStarted.future.timeout(
          const Duration(seconds: 1),
        );
        service
          ..emit('first', const HermesTokenDelta('OK'))
          ..emit('first', const HermesRunError('first turn failed'))
          ..emit('second', const HermesTokenDelta('OK'))
          ..emit('second', const HermesRunError('second turn failed'))
          ..emit('third', const HermesTokenDelta('Third final'))
          ..emit('third', const HermesRunError('third turn failed'))
          ..emit('fourth', const HermesTokenDelta('Fourth final'))
          ..emit('fourth', const HermesRunError('fourth turn failed'));
        await Future.wait(<Future<void>>[
          firstDispatch,
          secondDispatch,
          thirdDispatch,
          fourthDispatch,
        ]).timeout(const Duration(seconds: 1));

        final otherConversation = withChatStorageProvenance(
          _conversation('duplicate-other-chat', <ChatMessage>[
            _assistantMessage(id: 'other', content: 'Other chat'),
          ]),
          ChatStorageKind.directLocal,
        );
        container
            .read(activeConversationProvider.notifier)
            .set(otherConversation);
        await Future<void>.delayed(Duration.zero);

        // Reverse the server rows. A content-based first-match strategy would
        // now attach the first retained "OK" snapshot to the second message.
        final staleReversed = withChatStorageProvenance(
          _conversation('duplicate-hermes-chat', <ChatMessage>[
            _assistantMessage(
              id: second.id,
              content: 'OK',
              metadata: const <String, dynamic>{'transport': kHermesTransport},
            ),
            _assistantMessage(
              id: first.id,
              content: 'OK',
              metadata: const <String, dynamic>{'transport': kHermesTransport},
            ),
          ]),
          ChatStorageKind.openWebUi,
        );
        container.read(activeConversationProvider.notifier).set(staleReversed);
        await Future<void>.delayed(Duration.zero);

        final restored = container.read(chatMessagesProvider);
        check(
          restored.map((message) => message.id),
        ).deepEquals(<String>[second.id, first.id, third.id, fourth.id]);
        check(restored[0].content).equals('OK');
        check(restored[0].error?.content).equals('second turn failed');
        check(restored[0].metadata?['hermesRunId']).equals('run-second');
        check(restored[1].content).equals('OK');
        check(restored[1].error?.content).equals('first turn failed');
        check(restored[1].metadata?['hermesRunId']).equals('run-first');
        check(restored[2].content).equals('Third final');
        check(restored[2].error?.content).equals('third turn failed');
        check(restored[3].content).equals('Fourth final');
        check(restored[3].error?.content).equals('fourth turn failed');
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'OpenWebUI auth revocation promptly tears down only its Hermes run',
      () async {
        final epochState = NotifierProvider<_HermesAuthEpoch, Object>(
          () => _HermesAuthEpoch(Object()),
        );
        final service = _RevocationHermesApi();
        addTearDown(service.events.close);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(epochState),
            ),
          ],
        );
        addTearDown(container.dispose);

        final placeholder = _assistantMessage(
          id: 'revoked-assistant',
          content: 'accepted:',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final conversation = withChatStorageProvenance(
          _conversation('revoked-chat', <ChatMessage>[placeholder]),
          ChatStorageKind.openWebUi,
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          placeholder,
        ]);
        final runKey = hermesRunKeyForConversation(
          container,
          conversation: conversation,
          assistantMessageId: placeholder.id,
        );
        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: placeholder.id,
          input: 'stay scoped to this account',
          existingMessages: <ChatMessage>[
            _assistantMessage(
              id: 'history',
              metadata: const <String, dynamic>{
                'hermesSessionId': 'existing-session',
              },
            ),
          ],
        );
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );
        check(
          container.read(hermesRunRegistryProvider).runIdFor(runKey),
        ).equals('revoked-run');

        service.events.add(const HermesTokenDelta('owned'));
        final localSentinel = _assistantMessage(
          id: 'local-sentinel',
          content: 'local account-independent content',
        );
        final localConversation = withChatStorageProvenance(
          _conversation('local-sentinel-chat', <ChatMessage>[localSentinel]),
          ChatStorageKind.directLocal,
        );
        container
            .read(activeConversationProvider.notifier)
            .set(localConversation);
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          localSentinel,
        ]);
        final beforeRevocation = localSentinel.content;
        container.read(epochState.notifier).rotate();
        await Future<void>.delayed(Duration.zero);

        final cancelledAtRevocation = service.runCancelToken!.isCancelled;
        final streamCancelledAtRevocation = service.streamCancelled.isCompleted;
        final stopsAtRevocation = List<String>.of(service.stoppedRuns);
        service.events.add(const HermesTokenDelta('stale'));
        await Future<void>.delayed(Duration.zero);
        final afterStaleCallback = container
            .read(chatMessagesProvider)
            .single
            .content;

        // Keep the old implementation from hanging so the assertions below
        // report the missing revocation boundary deterministically.
        if (!cancelledAtRevocation) {
          service.events.add(const HermesRunDone());
        }
        await dispatch.timeout(const Duration(seconds: 1));

        check(cancelledAtRevocation).isTrue();
        check(streamCancelledAtRevocation).isTrue();
        check(stopsAtRevocation).deepEquals(<String>['revoked-run']);
        check(afterStaleCallback).equals(beforeRevocation);
        check(
          container.read(hermesRunRegistryProvider).runIdFor(runKey),
        ).isNull();
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'OpenWebUI database retirement during a server switch revokes Hermes',
      () async {
        final databaseA = AppDatabase(NativeDatabase.memory());
        final databaseState =
            NotifierProvider<_HermesDatabaseOwner, AppDatabase?>(
              () => _HermesDatabaseOwner(databaseA),
            );
        final epoch = Object();
        final service = _RevocationHermesApi();
        addTearDown(() async {
          await service.events.close();
          await databaseA.close();
        });
        final container = ProviderContainer(
          overrides: [
            openWebUiDatabaseAccessProvider.overrideWith(
              _OpenDatabaseAccess.new,
            ),
            appDatabaseProvider.overrideWith((ref) => ref.watch(databaseState)),
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            openWebUiAuthSessionEpochProvider.overrideWithValue(epoch),
          ],
        );
        addTearDown(container.dispose);

        final placeholder = _assistantMessage(
          id: 'server-switch-assistant',
          content: '',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final conversation = withChatStorageProvenance(
          _conversation('server-switch-chat', <ChatMessage>[placeholder]),
          ChatStorageKind.openWebUi,
        );
        await _seedDurableAssistantOwner(
          databaseA,
          chatId: conversation.id,
          assistant: placeholder,
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          placeholder,
        ]);
        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: placeholder.id,
          input: 'server A only',
          existingMessages: <ChatMessage>[
            _assistantMessage(
              id: 'history',
              metadata: const <String, dynamic>{
                'hermesSessionId': 'server-a-session',
              },
            ),
          ],
        );
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );

        // The database provider becomes null synchronously while the retiring
        // server is closed and the newly selected server is still opening.
        container.read(databaseState.notifier).set(null);
        await Future<void>.delayed(Duration.zero);
        final cancelledAtSwitch = service.runCancelToken!.isCancelled;
        final stopsAtSwitch = List<String>.of(service.stoppedRuns);
        if (!cancelledAtSwitch) service.events.add(const HermesRunDone());
        await dispatch.timeout(const Duration(seconds: 1));

        check(cancelledAtSwitch).isTrue();
        check(stopsAtSwitch).deepEquals(<String>['revoked-run']);
        final durable = await databaseA.messagesDao.getMessage(
          conversation.id,
          placeholder.id,
        );
        check(durable).isNotNull();
        final durablePayload =
            jsonDecode(durable!.payload) as Map<String, dynamic>;
        check(durablePayload['isStreaming']).equals(false);
        check(durablePayload['metadata'] as Map<String, dynamic>)
            .has((metadata) => metadata['transport'], 'transport')
            .equals(kHermesTransport);
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'fresh direct-local Hermes preflight survives OpenWebUI auth rotation',
      () async {
        final epochState = NotifierProvider<_HermesAuthEpoch, Object>(
          () => _HermesAuthEpoch(Object()),
        );
        final config = _GatedHermesConfigController();
        final service = _SessionRecordingHermesApi();
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(() => config),
            hermesApiServiceProvider.overrideWithValue(service),
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(epochState),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          _assistantMessage(
            id: 'fresh-local-assistant',
            content: '',
            isStreaming: true,
            metadata: const <String, dynamic>{'transport': kHermesTransport},
          ),
        ]);

        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: 'fresh-local-assistant',
          input: 'continue independently',
          existingMessages: const <ChatMessage>[],
        );
        await config.started.future.timeout(const Duration(seconds: 1));
        container.read(epochState.notifier).rotate();
        config.gate.complete('memory');
        await dispatch.timeout(const Duration(seconds: 1));

        check(service.inputs).deepEquals(<String>['continue independently']);
        check(
          container.read(activeConversationProvider)?.metadata['backend'],
        ).equals('hermes');
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test('live direct-local Hermes run ignores OpenWebUI revocation', () async {
      final epochState = NotifierProvider<_HermesAuthEpoch, Object>(
        () => _HermesAuthEpoch(Object()),
      );
      final events = StreamController<HermesRunEvent>(sync: true);
      addTearDown(events.close);
      final service = _SessionRecordingHermesApi(events: events);
      final container = _testContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(),
          ),
          hermesApiServiceProvider.overrideWithValue(service),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(epochState),
          ),
        ],
      );
      addTearDown(container.dispose);
      final placeholder = _assistantMessage(
        id: 'live-local-assistant',
        content: '',
        isStreaming: true,
        metadata: const <String, dynamic>{'transport': kHermesTransport},
      );
      final conversation = markNativeHermesConversation(
        withChatStorageProvenance(
          _conversation('local:hermes_live-session', <ChatMessage>[
            placeholder,
          ]).copyWith(
            metadata: const <String, dynamic>{
              'backend': 'hermes',
              'hermesSessionId': 'live-session',
            },
          ),
          ChatStorageKind.directLocal,
        ),
      );
      container.read(activeConversationProvider.notifier).set(conversation);
      container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
        placeholder,
      ]);

      final dispatch = dispatchHermesRunFromChatForTest(
        container,
        assistantMessageId: placeholder.id,
        input: 'keep local run alive',
        existingMessages: const <ChatMessage>[],
      );
      await service.runEventsStarted.future.timeout(const Duration(seconds: 1));

      container.read(epochState.notifier).rotate();
      await Future<void>.delayed(Duration.zero);
      final cancelledAtRevocation = service.createRunCancelToken!.isCancelled;
      events.add(const HermesTokenDelta('local answer'));
      events.add(const HermesRunDone());
      await dispatch.timeout(const Duration(seconds: 1));

      check(cancelledAtRevocation).isFalse();
      check(
        container.read(chatMessagesProvider).single.content,
      ).equals('local answer');
      container.read(chatMessagesProvider.notifier).clearMessages();
    });

    test('Hermes regeneration rebinds the active session shell', () async {
      final service = _BranchingHermesApi();
      final container = _testContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(),
          ),
          hermesApiServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final assistant = _assistantMessage(
        id: 'branch-assistant',
        content: '',
        isStreaming: true,
        metadata: const {'transport': 'hermesRun'},
      );
      container
          .read(activeConversationProvider.notifier)
          .set(
            markNativeHermesConversation(
              Conversation(
                id: 'local:hermes_old-session',
                title: 'Hermes session',
                createdAt: DateTime(2024, 1, 1),
                updatedAt: DateTime(2024, 1, 1),
                messages: [assistant],
                metadata: const {
                  'backend': 'hermes',
                  'hermesSessionId': 'old-session',
                },
              ),
            ),
          );
      await Future<void>.delayed(Duration.zero);

      await dispatchHermesRunFromChatForTest(
        container,
        assistantMessageId: 'branch-assistant',
        input: 'regenerate',
        existingMessages: const [],
        forceNewSession: true,
      );

      final active = container.read(activeConversationProvider)!;
      check(active.id).equals('local:hermes_branch-session');
      check(active.metadata['backend']).equals('hermes');
      check(active.metadata['hermesSessionId']).equals('branch-session');
      check(
        container.read(hermesActiveSessionProvider),
      ).equals('branch-session');
      container.read(chatMessagesProvider.notifier).clearMessages();
    });

    test(
      'Hermes regeneration reuses the assistant bubble and keeps its version',
      () async {
        final service = _BranchingHermesApi();
        final model = hermesSyntheticModel();
        final user = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'question',
          timestamp: DateTime(2024, 1, 1),
        );
        final previousAssistant = _assistantMessage(
          id: 'assistant-1',
          content: 'previous answer',
          metadata: const {'archivedVariant': true, 'transport': 'hermesRun'},
        );
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            selectedModelProvider.overrideWithValue(model),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(activeConversationProvider.notifier)
            .set(
              markNativeHermesConversation(
                Conversation(
                  id: 'local:hermes_old-session',
                  title: 'Hermes session',
                  createdAt: DateTime(2024, 1, 1),
                  updatedAt: DateTime(2024, 1, 1),
                  messages: [user, previousAssistant],
                  metadata: const {
                    'backend': 'hermes',
                    'hermesSessionId': 'old-session',
                  },
                ),
              ),
            );
        await Future<void>.delayed(Duration.zero);
        container.read(imageGenerationEnabledProvider.notifier).set(false);

        await regenerateMessage(
          container,
          user.content,
          null,
          forceImageGeneration: true,
        );

        final messages = container.read(chatMessagesProvider);
        check(messages).length.equals(2);
        check(messages.last.id).equals('assistant-1');
        check(messages.last.metadata?['archivedVariant']).isNull();
        check(messages.last.versions).length.equals(1);
        check(messages.last.versions.single.content).equals('previous answer');
        check(container.read(imageGenerationEnabledProvider)).isFalse();
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'Hermes regeneration cannot mutate a chat switched during capability lookup',
      () async {
        final service = _ResponsesHermesApi();
        final capabilities = Completer<HermesCapabilities>();
        final capabilitiesRequested = Completer<void>();
        final model = hermesSyntheticModel();
        final user = ChatMessage(
          id: 'old-user',
          role: 'user',
          content: 'old question',
          timestamp: DateTime(2024, 1, 1),
        );
        final previousAssistant = _assistantMessage(
          id: 'old-assistant',
          content: 'old answer',
          metadata: const <String, dynamic>{
            'transport': kHermesTransport,
            'hermesTransportMode': kHermesResponsesMode,
          },
        );
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            selectedModelProvider.overrideWithValue(model),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            hermesCapabilitiesProvider.overrideWith((ref) {
              if (!capabilitiesRequested.isCompleted) {
                capabilitiesRequested.complete();
              }
              return capabilities.future;
            }),
          ],
        );
        addTearDown(container.dispose);
        final oldConversation = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes-old',
            title: 'Old Hermes chat',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: <ChatMessage>[user, previousAssistant],
            metadata: const <String, dynamic>{
              'backend': 'hermes',
              'hermesSessionId': 'old-session',
            },
          ),
        );
        container
            .read(activeConversationProvider.notifier)
            .set(oldConversation);
        container
            .read(chatMessagesProvider.notifier)
            .setMessages(oldConversation.messages);

        final regeneration = regenerateMessage(container, user.content, null);
        await capabilitiesRequested.future.timeout(const Duration(seconds: 1));

        final newMessages = <ChatMessage>[
          _assistantMessage(id: 'new-sentinel', content: 'new chat answer'),
        ];
        container
            .read(activeConversationProvider.notifier)
            .set(
              markNativeHermesConversation(
                Conversation(
                  id: 'local:hermes-new',
                  title: 'New Hermes chat',
                  createdAt: DateTime(2024, 1, 2),
                  updatedAt: DateTime(2024, 1, 2),
                  messages: newMessages,
                  metadata: const <String, dynamic>{
                    'backend': 'hermes',
                    'hermesSessionId': 'new-session',
                  },
                ),
              ),
            );
        container.read(chatMessagesProvider.notifier).setMessages(newMessages);
        capabilities.complete(const HermesCapabilities(inputImages: true));
        await regeneration.timeout(const Duration(seconds: 1));

        check(container.read(chatMessagesProvider)).deepEquals(newMessages);
        check(service.inputs).isEmpty();
      },
    );

    for (final disableHermes in <bool>[false, true]) {
      test('${disableHermes ? 'config cancellation' : 'Stop'} during image '
          'capability lookup prevents normal Hermes dispatch', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          PreferenceKeys.hermesEnabled: true,
        });
        PreferencesStore.debugOverride(await SharedPreferences.getInstance());
        addTearDown(PreferencesStore.debugReset);
        final capabilities = Completer<HermesCapabilities>();
        final capabilitiesRequested = Completer<void>();
        final service = _ResponsesHermesApi();
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            hermesCapabilitiesProvider.overrideWith((ref) {
              if (!capabilitiesRequested.isCompleted) {
                capabilitiesRequested.complete();
              }
              return capabilities.future;
            }),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());
        final user = ChatMessage(
          id: 'normal-capability-user',
          role: 'user',
          content: 'first question',
          timestamp: DateTime(2024, 1, 1),
        );
        final previousAssistant = _assistantMessage(
          id: 'normal-capability-previous',
          content: 'first answer',
          metadata: const <String, dynamic>{
            'transport': kHermesTransport,
            'hermesTransportMode': kHermesResponsesMode,
            'hermesResponseId': 'previous-response',
          },
        );
        final conversation = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes-capability-send',
            title: 'Capability send',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: <ChatMessage>[user, previousAssistant],
            metadata: const <String, dynamic>{
              'backend': 'hermes',
              'hermesSessionId': 'capability-session',
            },
          ),
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        await Future<void>.delayed(Duration.zero);

        final send = sendMessageWithContainer(
          container,
          'second question',
          null,
        );
        await capabilitiesRequested.future.timeout(const Duration(seconds: 1));
        final placeholder = container.read(chatMessagesProvider).last;
        check(placeholder.metadata?['transport']).equals(kHermesTransport);
        check(placeholder.isStreaming).isTrue();

        if (disableHermes) {
          await container
              .read(hermesConfigProvider.notifier)
              .setEnabled(false)
              .timeout(const Duration(seconds: 1));
        } else {
          container.read(stopGenerationProvider)();
        }
        await Future<void>.delayed(Duration.zero);
        check(container.read(chatMessagesProvider).last.isStreaming).isFalse();

        capabilities.complete(const HermesCapabilities(inputImages: true));
        await send.timeout(const Duration(seconds: 1));

        check(service.inputs).isEmpty();
        check(service.createSessionCalls).equals(0);
        if (disableHermes) {
          check(container.read(hermesConfigProvider).enabled).isFalse();
        }
        check(
          container
              .read(hermesRunRegistryProvider)
              .cancelMessage(placeholder.id),
        ).isNull();
        container.read(chatMessagesProvider.notifier).clearMessages();
      });
    }

    test(
      'server switch during capability lookup cannot route Hermes regeneration',
      () async {
        final capabilities = Completer<HermesCapabilities>();
        final capabilitiesRequested = Completer<void>();
        final oldService = _ResponsesHermesApi();
        final replacementService = _ResponsesHermesApi();
        final config = _RotatableAdmissionHermesConfigController();
        final serviceGeneration =
            NotifierProvider<_HermesServiceGeneration, HermesApiService?>(
              () => _HermesServiceGeneration(oldService),
            );
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            selectedModelProvider.overrideWithValue(hermesSyntheticModel()),
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(() => config),
            hermesApiServiceProvider.overrideWith(
              (ref) => ref.watch(serviceGeneration),
            ),
            hermesCapabilitiesProvider.overrideWith((ref) {
              if (!capabilitiesRequested.isCompleted) {
                capabilitiesRequested.complete();
              }
              return capabilities.future;
            }),
          ],
        );
        addTearDown(container.dispose);
        final user = ChatMessage(
          id: 'regeneration-capability-user',
          role: 'user',
          content: 'repeat this',
          timestamp: DateTime(2024, 1, 1),
        );
        final previousAssistant = _assistantMessage(
          id: 'regeneration-capability-assistant',
          content: 'original answer',
          metadata: const <String, dynamic>{
            'transport': kHermesTransport,
            'hermesTransportMode': kHermesResponsesMode,
            'hermesResponseId': 'original-response',
          },
        );
        final originalMessages = <ChatMessage>[user, previousAssistant];
        final conversation = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes-capability-regeneration',
            title: 'Capability regeneration',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: originalMessages,
            metadata: const <String, dynamic>{
              'backend': 'hermes',
              'hermesSessionId': 'regeneration-session',
            },
          ),
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        container
            .read(chatMessagesProvider.notifier)
            .setMessages(originalMessages);

        final regeneration = regenerateMessage(container, user.content, null);
        await capabilitiesRequested.future.timeout(const Duration(seconds: 1));

        config.rotateServer();
        container.read(serviceGeneration.notifier).set(replacementService);
        capabilities.complete(const HermesCapabilities(inputImages: true));
        await regeneration.timeout(const Duration(seconds: 1));

        check(oldService.inputs).isEmpty();
        check(replacementService.inputs).isEmpty();
        check(
          container.read(chatMessagesProvider),
        ).deepEquals(originalMessages);
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'preflight cancellation detaches and bounds stalled session cleanup',
      () async {
        final service = _PreflightHermesApi();
        addTearDown(service.dispose);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(
            id: 'preflight',
            content: '',
            isStreaming: true,
            metadata: const {'transport': 'hermesRun'},
          ),
        ]);

        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: 'preflight',
          input: 'hello',
          existingMessages: const [],
          lateSessionCleanupDeadline: const Duration(milliseconds: 20),
        );
        await service.createSessionStarted.future.timeout(
          const Duration(seconds: 1),
        );

        final cancellation = container
            .read(hermesRunRegistryProvider)
            .cancelMessage('preflight');
        check(cancellation).isNotNull();
        var cancellationSettled = false;
        cancellation!.then((_) => cancellationSettled = true);
        await Future<void>.delayed(Duration.zero);
        check(cancellationSettled).isFalse();

        service.createSessionGate.complete('late-session');
        await service.deleteSessionStarted.future.timeout(
          const Duration(seconds: 1),
        );
        await dispatch.timeout(const Duration(seconds: 1));
        await cancellation.timeout(const Duration(seconds: 1));

        check(service.createRunCalls).equals(0);
        check(service.deleteSessionSettled.isCompleted).isFalse();
        check(
          container.read(hermesRunRegistryProvider).cancelMessage('preflight'),
        ).isNull();
        check(service.deletedSessions).deepEquals(['late-session']);
        check(service.deleteSessionCancelToken).isNotNull();
        check(
          identical(
            service.createSessionCancelToken,
            service.deleteSessionCancelToken,
          ),
        ).isFalse();
        check(container.read(hermesActiveSessionProvider)).isNull();
        check(cancellationSettled).isTrue();
        check(
          container.read(chatMessagesProvider).single.isStreaming,
        ).isFalse();
        await service.deleteSessionCancelToken!.whenCancel.timeout(
          const Duration(seconds: 1),
        );
        check(service.deleteSessionCancelToken!.isCancelled).isTrue();
        notifier.clearMessages();
      },
    );

    test(
      'periodic cleanup progress cannot extend the absolute deadline',
      () async {
        final service = _PreflightHermesApi(trickleDelete: true);
        addTearDown(service.dispose);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(
            id: 'trickling-cleanup',
            content: '',
            isStreaming: true,
            metadata: const {'transport': 'hermesRun'},
          ),
        ]);

        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: 'trickling-cleanup',
          input: 'hello',
          existingMessages: const [],
          lateSessionCleanupDeadline: const Duration(milliseconds: 40),
        );
        await service.createSessionStarted.future.timeout(
          const Duration(seconds: 1),
        );
        final cancellation = container
            .read(hermesRunRegistryProvider)
            .cancelMessage('trickling-cleanup');
        check(cancellation).isNotNull();
        service.createSessionGate.complete('trickling-session');
        await service.deleteSessionStarted.future.timeout(
          const Duration(seconds: 1),
        );

        await dispatch.timeout(const Duration(seconds: 1));
        await cancellation!.timeout(const Duration(seconds: 1));
        check(service.deleteSessionSettled.isCompleted).isFalse();
        await service.deleteTrickleStarted.future.timeout(
          const Duration(seconds: 1),
        );
        await service.deleteSessionCancelToken!.whenCancel.timeout(
          const Duration(seconds: 1),
        );
        final ticksAtDeadline = service.deleteTrickleTicks;
        await Future<void>.delayed(const Duration(milliseconds: 10));

        check(ticksAtDeadline).isGreaterOrEqual(3);
        check(service.deleteTrickleTicks).equals(ticksAtDeadline);
        check(service.deleteSessionCancelToken!.isCancelled).isTrue();
        check(service.createRunCalls).equals(0);
        check(container.read(hermesActiveSessionProvider)).isNull();
        check(
          container.read(chatMessagesProvider).single.isStreaming,
        ).isFalse();
        notifier.clearMessages();
      },
    );

    test(
      'late session cleanup diagnostics never log provider values',
      () async {
        const reflectedSecret =
            'conduit-late-cleanup-reflected-secret-9b34a1f0';
        const providerSessionId = 'provider-session-opaque';
        const stackSecret = 'late-cleanup-provider-stack-secret';
        final service = _PreflightHermesApi(
          deleteError: StateError(
            '$reflectedSecret $providerSessionId provider-error-secret',
          ),
          deleteErrorStack: StackTrace.fromString(stackSecret),
        );
        addTearDown(service.dispose);
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        container.read(chatMessagesProvider.notifier).setMessages([
          _assistantMessage(
            id: 'cleanup-log',
            content: '',
            isStreaming: true,
            metadata: const {'transport': 'hermesRun'},
          ),
        ]);
        final logs = <String>[];
        final previousDebugPrint = debugPrint;
        debugPrint = (value, {wrapWidth}) {
          if (value != null) logs.add(value);
        };

        try {
          final dispatch = dispatchHermesRunFromChatForTest(
            container,
            assistantMessageId: 'cleanup-log',
            input: 'hello',
            existingMessages: const [],
          );
          await service.createSessionStarted.future.timeout(
            const Duration(seconds: 1),
          );
          final cancellation = container
              .read(hermesRunRegistryProvider)
              .cancelMessage('cleanup-log');
          check(cancellation).isNotNull();
          service.createSessionGate.complete(providerSessionId);
          await service.deleteSessionStarted.future.timeout(
            const Duration(seconds: 1),
          );
          service.deleteSessionGate.complete();
          await dispatch.timeout(const Duration(seconds: 1));
          await cancellation!.timeout(const Duration(seconds: 1));
          await service.deleteSessionSettled.future.timeout(
            const Duration(seconds: 1),
          );
          await Future<void>.delayed(Duration.zero);
        } finally {
          debugPrint = previousDebugPrint;
        }

        final combinedLogs = logs.join('\n');
        check(combinedLogs).contains('late-session-cleanup-failed');
        check(combinedLogs).not((value) => value.contains(reflectedSecret));
        check(combinedLogs).not((value) => value.contains(providerSessionId));
        check(
          combinedLogs,
        ).not((value) => value.contains('provider-error-secret'));
        check(combinedLogs).not((value) => value.contains(stackSecret));
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'cancelAll keeps the originating service live through late run cleanup',
      () async {
        final service = _CreateRunRaceHermesApi();
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(
            id: 'create-race',
            content: '',
            isStreaming: true,
            metadata: const {'transport': 'hermesRun'},
          ),
        ]);
        container
            .read(hermesActiveSessionProvider.notifier)
            .set('existing-session');

        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: 'create-race',
          input: 'hello',
          existingMessages: const [],
        );
        await service.createRunStarted.future.timeout(
          const Duration(seconds: 1),
        );

        var rotationSettled = false;
        final rotation =
            Future.wait(
              container.read(hermesRunRegistryProvider).cancelAll(),
            ).then((_) {
              service.close();
              rotationSettled = true;
            });
        await Future<void>.delayed(Duration.zero);
        check(service.createRunToken!.isCancelled).isTrue();
        check(rotationSettled).isFalse();
        check(service.closed).isFalse();

        service.createRunGate.complete('late-run');
        await service.stopRunStarted.future.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(Duration.zero);
        check(rotationSettled).isFalse();
        check(service.closed).isFalse();

        service.stopRunGate.complete();
        await rotation.timeout(const Duration(seconds: 1));
        await dispatch.timeout(const Duration(seconds: 1));

        check(service.stoppedRuns).deepEquals(['late-run']);
        check(rotationSettled).isTrue();
        check(service.closed).isTrue();
        notifier.clearMessages();
      },
    );

    test(
      'New Chat reset clears the session and stops every Hermes run',
      () async {
        final service = _StoppingHermesApi();
        final container = _buildContainer(hermesService: service);
        addTearDown(container.dispose);
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(id: 'active', content: '', isStreaming: true),
        ]);
        container.read(hermesActiveSessionProvider.notifier).set('session-1');
        final registry = container.read(hermesRunRegistryProvider);
        final firstToken = CancelToken();
        final secondToken = CancelToken();
        final pendingToken = CancelToken();
        final hostilePendingCleanup = Completer<void>();
        registry.register(
          legacyHermesRunKey('first'),
          runId: 'run-1',
          cancelToken: firstToken,
          subscription: const Stream<void>.empty().listen(null),
          stopRemote: service.stopRun,
        );
        registry.register(
          legacyHermesRunKey('second'),
          runId: 'run-2',
          cancelToken: secondToken,
          subscription: const Stream<void>.empty().listen(null),
          stopRemote: service.stopRun,
        );
        registry.registerPending(
          legacyHermesRunKey('pending'),
          cancelToken: pendingToken,
          cancellationSettled: hostilePendingCleanup.future,
          onCancelled: () {},
        );

        resetHermesForNewChat(container);
        hostilePendingCleanup.completeError(
          StateError('hostile Hermes cleanup'),
          StackTrace.current,
        );
        await Future<void>.delayed(Duration.zero);

        check(firstToken.isCancelled).isTrue();
        check(secondToken.isCancelled).isTrue();
        check(pendingToken.isCancelled).isTrue();
        check(service.stopped).unorderedEquals(['run-1', 'run-2']);
        check(container.read(hermesActiveSessionProvider)).isNull();
        notifier.clearMessages();
      },
    );

    test('New Chat reset observes rejected direct cleanup futures', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);
      final registry = container.read(directRunRegistryProvider);
      final key = (
        ownerConversationId: 'direct-reset-owner',
        assistantMessageId: 'direct-reset-assistant',
      );
      final reservation = registry.reserve(key, 'profile');
      final cancelToken = CancelToken();
      final hostileCleanup = Completer<void>();
      final run = DirectCompletionRun(
        id: 'direct-reset-run',
        profileId: 'profile',
        remoteModelId: 'model',
        events: const Stream<DirectStreamEvent>.empty(),
        cancelToken: cancelToken,
        done: hostileCleanup.future,
      );
      check(registry.register(reservation, run)).isTrue();

      resetDirectRunsForNewChat(container);
      hostileCleanup.completeError(
        StateError('hostile direct cleanup'),
        StackTrace.current,
      );
      await Future<void>.delayed(Duration.zero);

      check(cancelToken.isCancelled).isTrue();
      check(registry.isCancelled(reservation)).isTrue();
      check(registry.runFor(key)).isNull();
    });

    test('Stop observes rejected direct and Hermes cleanup futures', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);
      final directRegistry = container.read(directRunRegistryProvider);
      final directAssistant = _assistantMessage(
        id: 'direct-stop-assistant',
        content: 'partial',
        isStreaming: true,
        metadata: const <String, dynamic>{'transport': kDirectTransport},
      );
      final directConversation = withChatStorageProvenance(
        _conversation('direct-stop-chat', <ChatMessage>[directAssistant]),
        ChatStorageKind.directLocal,
      );
      container
          .read(activeConversationProvider.notifier)
          .set(directConversation);
      container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
        directAssistant,
      ]);
      final directKey = (
        ownerConversationId: directRunOwnerScopeForTest(
          container,
          directConversation,
        ),
        assistantMessageId: directAssistant.id,
      );
      final directReservation = directRegistry.reserve(directKey, 'profile');
      final directCancelToken = CancelToken();
      final directCleanup = Completer<void>();
      check(
        directRegistry.register(
          directReservation,
          DirectCompletionRun(
            id: 'direct-stop-run',
            profileId: 'profile',
            remoteModelId: 'model',
            events: const Stream<DirectStreamEvent>.empty(),
            cancelToken: directCancelToken,
            done: directCleanup.future,
          ),
        ),
      ).isTrue();

      container.read(stopGenerationProvider)();
      directCleanup.completeError(
        StateError('hostile direct stop cleanup'),
        StackTrace.current,
      );
      await Future<void>.delayed(Duration.zero);
      check(directCancelToken.isCancelled).isTrue();

      final hermesAssistant = _assistantMessage(
        id: 'hermes-stop-assistant',
        content: 'partial',
        isStreaming: true,
        metadata: const <String, dynamic>{'transport': kHermesTransport},
      );
      final hermesConversation = markNativeHermesConversation(
        withChatStorageProvenance(
          _conversation('hermes-stop-chat', <ChatMessage>[
            hermesAssistant,
          ]).copyWith(metadata: const <String, dynamic>{'backend': 'hermes'}),
          ChatStorageKind.directLocal,
        ),
      );
      container
          .read(activeConversationProvider.notifier)
          .set(hermesConversation);
      container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
        hermesAssistant,
      ]);
      final hermesRegistry = container.read(hermesRunRegistryProvider);
      final hermesKey = hermesRunKeyForConversation(
        container,
        conversation: hermesConversation,
        assistantMessageId: hermesAssistant.id,
      );
      final hermesCancelToken = CancelToken();
      final hermesCleanup = Completer<void>();
      hermesRegistry.registerPending(
        hermesKey,
        cancelToken: hermesCancelToken,
        cancellationSettled: hermesCleanup.future,
        onCancelled: () {},
      );

      container.read(stopGenerationProvider)();
      hermesCleanup.completeError(
        StateError('hostile Hermes stop cleanup'),
        StackTrace.current,
      );
      await Future<void>.delayed(Duration.zero);
      check(hermesCancelToken.isCancelled).isTrue();
    });

    test(
      'Hermes stop never cancels an OpenWebUI task or queued completion',
      () async {
        final api = _CountingStopApi();
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(api),
            socketServiceProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);
        final assistant = _assistantMessage(
          id: 'isolated-hermes-stop',
          content: 'Hermes partial',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final conversation = withChatStorageProvenance(
          _conversation('mixed-transport-chat', <ChatMessage>[assistant]),
          ChatStorageKind.openWebUi,
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        await Future<void>.delayed(Duration.zero);

        final database = container.read(appDatabaseProvider)!;
        await database.transaction(() async {
          await database.outboxDao.enqueue(
            kind: OutboxKind.requestCompletion,
            chatId: conversation.id,
            payload: const RequestCompletionPayload(
              assistantMessageId: 'unrelated-openwebui-assistant',
              model: 'openwebui-model',
            ).toJson(),
          );
        });
        final registry = container.read(hermesRunRegistryProvider);
        final key = hermesRunKeyForConversation(
          container,
          conversation: conversation,
          assistantMessageId: assistant.id,
        );
        final cancelToken = registry.registerPending(key, onCancelled: () {});

        container.read(stopGenerationProvider)();
        await pumpEventQueue();

        check(cancelToken.isCancelled).isTrue();
        check(api.broadStops).equals(0);
        final pending = await database.outboxDao.pendingForChat(
          conversation.id,
        );
        check(
          pending.where(
            (operation) => operation.kind == OutboxKind.requestCompletion.name,
          ),
        ).length.equals(1);
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'stopping an orphaned Hermes placeholder settles only that message',
      () async {
        final api = _CountingStopApi();
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(api),
            socketServiceProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);
        final assistant = _assistantMessage(
          id: 'orphaned-hermes-stop',
          content: 'Retained partial answer',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final conversation = withChatStorageProvenance(
          _conversation('orphaned-hermes-chat', <ChatMessage>[assistant]),
          ChatStorageKind.openWebUi,
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        await Future<void>.delayed(Duration.zero);

        // No registry entry models a persisted/reloaded placeholder after the
        // original process (and its transport ownership table) disappeared.
        container.read(stopGenerationProvider)();
        await pumpEventQueue();

        final stopped = container.read(chatMessagesProvider).single;
        check(stopped.id).equals(assistant.id);
        check(stopped.content).equals('Retained partial answer');
        check(stopped.isStreaming).isFalse();
        check(api.broadStops).equals(0);
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'remote Hermes stop failure survives finalization and navigation',
      () async {
        final events = StreamController<HermesRunEvent>();
        addTearDown(events.close);
        final service = _SessionRecordingHermesApi(
          events: events,
          stopError: StateError('remote stop failed'),
        );
        final container = _testContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);
        final assistant = _assistantMessage(
          id: 'failed-stop-assistant',
          content: 'Partial',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final conversation = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes_failed-stop-session',
            title: 'Failed stop',
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            messages: <ChatMessage>[assistant],
            metadata: const <String, dynamic>{
              'backend': 'hermes',
              'hermesSessionId': 'failed-stop-session',
            },
          ),
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        await Future<void>.delayed(Duration.zero);
        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: assistant.id,
          input: 'keep working',
          existingMessages: const <ChatMessage>[],
        );
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );

        final key = hermesRunKeyForConversation(
          container,
          conversation: container.read(activeConversationProvider)!,
          assistantMessageId: assistant.id,
        );
        final cancellation = container
            .read(hermesRunRegistryProvider)
            .cancel(key);
        check(cancellation).isNotNull();
        await Future.wait(<Future<void>>[
          dispatch,
          cancellation!,
        ]).timeout(const Duration(seconds: 1));

        const stopFailure =
            'Could not confirm that Hermes stopped this run. It may still '
            'be running on the server.';
        check(service.stoppedRuns).deepEquals(<String>['recorded-run']);
        var stopped = container.read(chatMessagesProvider).single;
        check(stopped.isStreaming).isFalse();
        check(stopped.error?.content).equals(stopFailure);

        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation('failed-stop-other', <ChatMessage>[
                _assistantMessage(id: 'failed-stop-other-assistant'),
              ]),
            );
        await Future<void>.delayed(Duration.zero);
        container.read(activeConversationProvider.notifier).set(conversation);
        await Future<void>.delayed(Duration.zero);

        stopped = container.read(chatMessagesProvider).single;
        check(stopped.id).equals(assistant.id);
        check(stopped.isStreaming).isFalse();
        check(stopped.error?.content).equals(stopFailure);
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'server switch joins late stop persistence before releasing its lease',
      () async {
        final manager = DatabaseManager(
          openDatabase: (_) => AppDatabase(NativeDatabase.memory()),
        );
        final databaseA = manager.openForServerId('hermes-server-a');
        final databaseState =
            NotifierProvider<_HermesDatabaseOwner, AppDatabase?>(
              () => _HermesDatabaseOwner(databaseA),
            );
        final stopGate = Completer<void>();
        final events = StreamController<HermesRunEvent>();
        final service = _SessionRecordingHermesApi(
          events: events,
          stopError: StateError('remote stop failed'),
          stopGate: stopGate,
        );
        final locks = _GatedSecondPersistenceLocks();
        final container = ProviderContainer(
          overrides: [
            openWebUiDatabaseAccessProvider.overrideWith(
              _OpenDatabaseAccess.new,
            ),
            databaseManagerProvider.overrideWithValue(manager),
            appDatabaseProvider.overrideWith((ref) {
              return ref.watch(databaseState);
            }),
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FixedHermesConfigController(),
            ),
            hermesApiServiceProvider.overrideWithValue(service),
            chatLocksProvider.overrideWithValue(locks),
          ],
        );
        addTearDown(() async {
          if (!stopGate.isCompleted) stopGate.complete();
          if (!locks.allowSecondPersistence.isCompleted) {
            locks.allowSecondPersistence.complete();
          }
          if (!locks.allowSecondReturn.isCompleted) {
            locks.allowSecondReturn.complete();
          }
          await events.close();
          container.dispose();
          await manager.closeActive();
        });

        final placeholder = _assistantMessage(
          id: 'late-stop-persistence-assistant',
          content: 'Partial',
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': kHermesTransport},
        );
        final conversation = withChatStorageProvenance(
          _conversation('late-stop-persistence-chat', <ChatMessage>[
            placeholder,
          ]),
          ChatStorageKind.openWebUi,
        );
        await _seedDurableAssistantOwner(
          databaseA,
          chatId: conversation.id,
          assistant: placeholder,
        );
        container.read(activeConversationProvider.notifier).set(conversation);
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          placeholder,
        ]);
        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: placeholder.id,
          input: 'stop during a server switch',
          existingMessages: <ChatMessage>[
            _assistantMessage(
              id: 'late-stop-history',
              metadata: const <String, dynamic>{
                'hermesSessionId': 'late-stop-session',
              },
            ),
          ],
        );
        var dispatchSettled = false;
        dispatch.then<void>((_) => dispatchSettled = true);
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );

        final databaseB = manager.openForServerId('hermes-server-b');
        container.read(databaseState.notifier).set(databaseB);
        await service.stopRunStarted.future.timeout(const Duration(seconds: 1));
        await locks.firstPersistenceCompleted.future.timeout(
          const Duration(seconds: 1),
        );
        check(dispatchSettled).isFalse();

        stopGate.complete();
        await locks.secondPersistenceStarted.future.timeout(
          const Duration(seconds: 1),
        );
        check(dispatchSettled).isFalse();
        locks.allowSecondPersistence.complete();
        await locks.secondPersistenceCompleted.future.timeout(
          const Duration(seconds: 1),
        );

        final durable = await databaseA.messagesDao.getMessage(
          conversation.id,
          placeholder.id,
        );
        check(durable).isNotNull();
        final payload = jsonDecode(durable!.payload) as Map<String, dynamic>;
        check(payload['isStreaming']).equals(false);
        check((payload['error'] as Map<String, dynamic>)['content']).equals(
          'Could not confirm that Hermes stopped this run. It may still '
          'be running on the server.',
        );
        check(dispatchSettled).isFalse();

        locks.allowSecondReturn.complete();
        await dispatch.timeout(const Duration(seconds: 1));
        check(dispatchSettled).isTrue();
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'batched optimistic turn exposes user and assistant together',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        var notifications = 0;
        final subscription = container.listen<List<ChatMessage>>(
          chatMessagesProvider,
          (_, _) => notifications += 1,
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        notifier.addMessages([
          ChatMessage(
            id: 'user-1',
            role: 'user',
            content: 'Hello',
            timestamp: DateTime(2024, 1, 1),
          ),
          _assistantMessage(id: 'assistant-1', content: '', isStreaming: true),
        ]);
        await Future<void>.delayed(Duration.zero);

        final messages = container.read(chatMessagesProvider);
        check(notifications).equals(1);
        check(messages).length.equals(2);
        check(messages.last.id).equals('assistant-1');
        check(messages.last.isStreaming).isTrue();

        notifier.clearMessages();
      },
    );

    test(
      'first conversation activation preserves optimistic stream row',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final assistantMessage = _assistantMessage(
          id: 'assistant-1',
          content: '',
          isStreaming: true,
        );
        notifier.addMessages([userMessage, assistantMessage]);
        final optimisticMessages = container.read(chatMessagesProvider);

        var notifications = 0;
        final subscription = container.listen<List<ChatMessage>>(
          chatMessagesProvider,
          (_, _) => notifications += 1,
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('local:first', [userMessage, assistantMessage]));
        await Future<void>.delayed(Duration.zero);

        check(notifications).equals(0);
        check(
          identical(container.read(chatMessagesProvider), optimisticMessages),
        ).isTrue();

        notifier.clearMessages();
      },
    );

    test(
      'first conversation activation preserves a stale same-id stream echo',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final assistantMessage = _assistantMessage(
          id: 'assistant-1',
          content: '',
          isStreaming: true,
          metadata: const {'modelName': 'GPT-4o'},
        );
        notifier.addMessages([userMessage, assistantMessage]);

        final staleServerEcho = _assistantMessage(
          id: 'assistant-1',
          content: '',
          isStreaming: false,
        );
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('local:first', [userMessage, staleServerEcho]));
        await Future<void>.delayed(Duration.zero);

        final messages = container.read(chatMessagesProvider);
        check(messages).length.equals(2);
        check(messages.last.id).equals('assistant-1');
        check(messages.last.isStreaming).isTrue();
        check(messages.last.metadata?['modelName']).equals('GPT-4o');

        notifier.clearMessages();
      },
    );

    test(
      'same-chat empty server echo does not retire the active stream',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final assistantMessage = _assistantMessage(
          id: 'assistant-1',
          content: '',
          isStreaming: true,
          metadata: const {'modelName': 'GPT-4o'},
        );
        final activeConversationNotifier = container.read(
          activeConversationProvider.notifier,
        );
        activeConversationNotifier.set(
          _conversation('chat-1', [userMessage, assistantMessage]),
        );
        await Future<void>.delayed(Duration.zero);
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

        final staleServerEcho = _assistantMessage(
          id: 'assistant-1',
          content: '',
          isStreaming: false,
        );
        activeConversationNotifier.set(
          _conversation('chat-1', [userMessage, staleServerEcho]),
        );
        await Future<void>.delayed(Duration.zero);

        final messages = container.read(chatMessagesProvider);
        check(messages).length.equals(2);
        check(messages.last.id).equals('assistant-1');
        check(messages.last.isStreaming).isTrue();
        check(messages.last.metadata?['modelName']).equals('GPT-4o');

        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'in-progress status-only server echo does not retire the active stream',
      () async {
        // Regression: the server pushes status updates (e.g. "Searching…") as
        // content-empty, non-streaming snapshots before the answer tokens
        // arrive. statusHistory is populated during streaming, so a metadata-
        // only echo must NOT be treated as completion — retiring the stream here
        // drops the typing footer mid-turn.
        final container = _buildContainer();
        addTearDown(container.dispose);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final assistantMessage = _assistantMessage(
          id: 'assistant-1',
          content: '',
          isStreaming: true,
          metadata: const {'modelName': 'GPT-4o'},
        );
        final activeConversationNotifier = container.read(
          activeConversationProvider.notifier,
        );
        activeConversationNotifier.set(
          _conversation('chat-1', [userMessage, assistantMessage]),
        );
        await Future<void>.delayed(Duration.zero);
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

        final statusOnlyEcho = ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: '',
          timestamp: DateTime(2024, 1, 1),
          isStreaming: false,
          statusHistory: const [
            ChatStatusUpdate(description: 'Searching', done: false),
          ],
        );
        activeConversationNotifier.set(
          _conversation('chat-1', [userMessage, statusOnlyEcho]),
        );
        await Future<void>.delayed(Duration.zero);

        final messages = container.read(chatMessagesProvider);
        check(messages).length.equals(2);
        check(messages.last.id).equals('assistant-1');
        check(
          messages.last.isStreaming,
          because: 'an in-progress status-only echo must keep the stream alive',
        ).isTrue();

        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'non-streaming echo with a non-empty completion field retires the stream',
      () async {
        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final completionEchoes = <String, ChatMessage>{
          'files': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            files: const [
              {'id': 'f1'},
            ],
          ),
          'output': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            output: const [
              {'type': 'text'},
            ],
          ),
          'embeds': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            embeds: const [
              {'url': 'https://example.com'},
            ],
          ),
          'followUps': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            followUps: const ['Ask again'],
          ),
          'responseDone': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            metadata: const {'responseDone': true},
          ),
          'error': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            error: const ChatMessageError(content: 'boom'),
          ),
          'sources': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            sources: const [
              ChatSourceReference(title: 'Doc', url: 'https://example.com'),
            ],
          ),
          'codeExecutions': ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime(2024, 1, 1),
            codeExecutions: const [ChatCodeExecution(id: 'ce1')],
          ),
        };

        for (final entry in completionEchoes.entries) {
          final container = _buildContainer();
          final active = container.read(activeConversationProvider.notifier);
          active.set(
            _conversation('chat-1', [
              userMessage,
              _assistantMessage(
                id: 'assistant-1',
                content: '',
                isStreaming: true,
                metadata: const {'modelName': 'GPT-4o'},
              ),
            ]),
          );
          await Future<void>.delayed(Duration.zero);
          check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

          active.set(_conversation('chat-1', [userMessage, entry.value]));
          await Future<void>.delayed(Duration.zero);

          check(
            container.read(chatMessagesProvider).last.isStreaming,
            because: 'completion field "${entry.key}" should retire the stream',
          ).isFalse();

          container.read(chatMessagesProvider.notifier).clearMessages();
          container.dispose();
        }
      },
    );

    test(
      'server snapshot advancing past the streaming tail retires it',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final active = container.read(activeConversationProvider.notifier);
        active.set(
          _conversation('chat-1', [
            userMessage,
            _assistantMessage(
              id: 'assistant-1',
              content: 'Partial',
              isStreaming: true,
            ),
          ]),
        );
        await Future<void>.delayed(Duration.zero);
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

        active.set(
          _conversation('chat-1', [
            userMessage,
            _assistantMessage(
              id: 'assistant-1',
              content: 'Done',
              isStreaming: false,
            ),
            ChatMessage(
              id: 'user-2',
              role: 'user',
              content: 'Next',
              timestamp: DateTime(2024, 1, 1),
            ),
            _assistantMessage(
              id: 'assistant-2',
              content: 'New turn',
              isStreaming: false,
            ),
          ]),
        );
        await Future<void>.delayed(Duration.zero);

        final messages = container.read(chatMessagesProvider);
        check(messages).length.equals(4);
        check(
          messages
              .firstWhere((message) => message.id == 'assistant-1')
              .isStreaming,
        ).isFalse();

        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'a streaming row that is not the tail is not force-kept streaming',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final secondUser = ChatMessage(
          id: 'user-2',
          role: 'user',
          content: 'Follow up',
          timestamp: DateTime(2024, 1, 1),
        );
        final active = container.read(activeConversationProvider.notifier);
        active.set(
          _conversation('chat-1', [
            userMessage,
            _assistantMessage(
              id: 'assistant-1',
              content: 'Streaming earlier',
              isStreaming: true,
            ),
            secondUser,
            _assistantMessage(
              id: 'assistant-2',
              content: 'Tail',
              isStreaming: false,
            ),
          ]),
        );
        await Future<void>.delayed(Duration.zero);

        active.set(
          _conversation('chat-1', [
            userMessage,
            _assistantMessage(
              id: 'assistant-1',
              content: 'Streaming earlier',
              isStreaming: false,
            ),
            secondUser,
            _assistantMessage(
              id: 'assistant-2',
              content: 'Tail',
              isStreaming: false,
            ),
          ]),
        );
        await Future<void>.delayed(Duration.zero);

        check(
          container
              .read(chatMessagesProvider)
              .firstWhere((message) => message.id == 'assistant-1')
              .isStreaming,
        ).isFalse();

        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'empty non-streaming echo preserves streaming-state, content, and modelName together',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        // Local streaming tail with a non-empty partial body and a modelName chip.
        final localTail = _assistantMessage(
          id: 'assistant-1',
          content: 'Partial streamed answer',
          isStreaming: true,
          metadata: const {'modelName': 'GPT-4o'},
        );
        final active = container.read(activeConversationProvider.notifier);
        active.set(_conversation('chat-1', [userMessage, localTail]));
        await Future<void>.delayed(Duration.zero);
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

        // Lagging server echo: empty content, isStreaming:false, no modelName.
        final emptyEcho = _assistantMessage(
          id: 'assistant-1',
          content: '',
          isStreaming: false,
        );
        active.set(_conversation('chat-1', [userMessage, emptyEcho]));
        await Future<void>.delayed(Duration.zero);

        final merged = container.read(chatMessagesProvider).last;
        check(merged.isStreaming).isTrue(); // shouldPreserveStreamingState
        check(
          merged.content,
        ).equals('Partial streamed answer'); // preserveContent
        check(
          merged.metadata?['modelName'],
        ).equals('GPT-4o'); // shouldPreserveModelName

        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'socket-resumed tail preserves streaming-state when a stale empty echo carries the foreign server id',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final localTail = _assistantMessage(
          id: 'assistant-local',
          content: 'Partial',
          isStreaming: true,
          metadata: const {'modelName': 'GPT-4o'},
        );

        final notifier = container.read(chatMessagesProvider.notifier);
        final active = container.read(activeConversationProvider.notifier);
        active.set(_conversation('chat-1', [userMessage, localTail]));
        await Future<void>.delayed(Duration.zero);
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

        // Socket resume bound a foreign server id to the local tail (must be
        // recorded while the tail is still state.last).
        notifier.recordResumeBoundRemoteMessageId(
          'assistant-local',
          'server-foreign',
        );

        // Lagging snapshot carries the FOREIGN id with empty, non-streaming
        // content: the boundToTail path must still preserve streaming-state.
        final foreignEcho = _assistantMessage(
          id: 'server-foreign',
          content: '',
          isStreaming: false,
        );
        active.set(_conversation('chat-1', [userMessage, foreignEcho]));
        await Future<void>.delayed(Duration.zero);

        final merged = container.read(chatMessagesProvider).last;
        check(merged.isStreaming).isTrue();
        check(merged.metadata?['modelName']).equals('GPT-4o');

        notifier.clearMessages();
      },
    );

    test(
      'adopt preserves foreign-id streaming echo even when tracked transport '
      'does not protect the local tail',
      () async {
        // Greptile P1: `_adoptServerMessages` used to drop transport (clearing
        // `_boundRemoteMessageId`) before `_preserveFreshLocalAssistantState`.
        // Tracked-but-unprotected transport is the path that exercises that
        // ordering — e.g. a stale transport id that no longer matches the tail.
        final container = _buildContainer();
        addTearDown(container.dispose);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final localTail = _assistantMessage(
          id: 'assistant-local',
          content: 'Partial',
          isStreaming: true,
          metadata: const {'modelName': 'GPT-4o'},
        );

        final notifier = container.read(chatMessagesProvider.notifier);
        final active = container.read(activeConversationProvider.notifier);
        active.set(_conversation('chat-1', [userMessage, localTail]));
        await Future<void>.delayed(Duration.zero);

        // Transport is tracked under a non-matching id so protection is false
        // and adopt is allowed, but `_hasTrackedStreamingTransport` is true.
        var transportDisposed = false;
        notifier.setSocketSubscriptions('stale-transport-id', [
          () => transportDisposed = true,
        ]);
        check(notifier.debugShouldProtectLocalStreamingState).isFalse();

        notifier.recordResumeBoundRemoteMessageId(
          'assistant-local',
          'server-foreign',
        );

        final foreignEcho = _assistantMessage(
          id: 'server-foreign',
          content: '',
          isStreaming: false,
        );
        active.set(_conversation('chat-1', [userMessage, foreignEcho]));
        await Future<void>.delayed(Duration.zero);

        final merged = container.read(chatMessagesProvider).last;
        check(merged.isStreaming).isTrue();
        check(merged.metadata?['modelName']).equals('GPT-4o');
        // Still-streaming preserve must not tear down transport either.
        check(transportDisposed).isFalse();

        notifier.clearMessages();
      },
    );

    test(
      'genuine completion under a bound foreign id retires the stream',
      () async {
        // Cleanup previously only matched server messages by the local
        // placeholder id, so a finished foreign-id snapshot with the same
        // message count slipped past `_shouldCleanupStreamingFromServer`.
        final container = _buildContainer();
        addTearDown(container.dispose);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final localTail = _assistantMessage(
          id: 'assistant-local',
          content: 'Partial',
          isStreaming: true,
        );

        final notifier = container.read(chatMessagesProvider.notifier);
        final active = container.read(activeConversationProvider.notifier);
        active.set(_conversation('chat-1', [userMessage, localTail]));
        await Future<void>.delayed(Duration.zero);

        notifier.recordResumeBoundRemoteMessageId(
          'assistant-local',
          'server-foreign',
        );

        check(
          notifier.debugShouldCleanupStreamingFromServer([
            userMessage,
            _assistantMessage(
              id: 'server-foreign',
              content: 'Final answer',
              isStreaming: false,
              metadata: const {'responseDone': true},
            ),
          ]),
        ).isTrue();

        active.set(
          _conversation('chat-1', [
            userMessage,
            _assistantMessage(
              id: 'server-foreign',
              content: 'Final answer',
              isStreaming: false,
              metadata: const {'responseDone': true},
            ),
          ]),
        );
        await Future<void>.delayed(Duration.zero);

        final merged = container.read(chatMessagesProvider).last;
        check(merged.isStreaming).isFalse();
        check(merged.content).equals('Final answer');

        notifier.clearMessages();
      },
    );

    test(
      'server adoption cancels a tracked controller when no streaming tail remains',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final active = container.read(activeConversationProvider.notifier);
        active.set(
          _conversation('chat-1', [
            _assistantMessage(content: 'Local settled answer'),
          ]),
        );
        await Future<void>.delayed(Duration.zero);

        final upstream = StreamController<String>();
        addTearDown(upstream.close);
        final lateChunks = <String>[];
        final controller = StreamingResponseController(
          stream: upstream.stream,
          onChunk: lateChunks.add,
          onComplete: () {},
          onError: (_, _) {},
        );
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessageStream('stale-transport-id', controller);
        check(controller.isActive).isTrue();

        active.set(
          _conversation('chat-1', [
            _assistantMessage(content: 'Server replacement'),
          ]),
        );
        await Future<void>.delayed(Duration.zero);

        check(controller.isActive).isFalse();
        upstream.add('late chunk');
        await Future<void>.delayed(Duration.zero);
        check(lateChunks).isEmpty();

        notifier.clearMessages();
      },
    );

    test(
      'server completion cancels a tracked controller through the cleanup path',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final active = container.read(activeConversationProvider.notifier);
        active.set(
          _conversation('chat-1', [
            _assistantMessage(content: 'Partial', isStreaming: true),
          ]),
        );
        await Future<void>.delayed(Duration.zero);

        final upstream = StreamController<String>();
        addTearDown(upstream.close);
        final lateChunks = <String>[];
        final controller = StreamingResponseController(
          stream: upstream.stream,
          onChunk: lateChunks.add,
          onComplete: () {},
          onError: (_, _) {},
        );
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessageStream('stale-transport-id', controller);
        check(notifier.debugShouldProtectLocalStreamingState).isFalse();
        check(controller.isActive).isTrue();

        active.set(
          _conversation('chat-1', [
            _assistantMessage(
              content: 'Final answer',
              metadata: const {'responseDone': true},
            ),
          ]),
        );
        await Future<void>.delayed(Duration.zero);

        check(
          container.read(chatMessagesProvider).single.isStreaming,
        ).isFalse();
        check(controller.isActive).isFalse();
        upstream.add('late chunk');
        await Future<void>.delayed(Duration.zero);
        check(lateChunks).isEmpty();

        notifier.clearMessages();
      },
    );

    test(
      'shouldCleanupStreamingFromServer ignores a stale echo but retires real completions',
      () {
        final container = _buildContainer();
        addTearDown(container.dispose);
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(
            id: 'assistant-1',
            content: 'Partial',
            isStreaming: true,
          ),
        ]);

        // A stale empty non-streaming echo must NOT retire the stream.
        check(
          notifier.debugShouldCleanupStreamingFromServer([
            _assistantMessage(
              id: 'assistant-1',
              content: '',
              isStreaming: false,
            ),
          ]),
        ).isFalse();

        // responseDone retires it.
        check(
          notifier.debugShouldCleanupStreamingFromServer([
            _assistantMessage(
              id: 'assistant-1',
              content: '',
              isStreaming: false,
              metadata: const {'responseDone': true},
            ),
          ]),
        ).isTrue();

        // An error retires it.
        check(
          notifier.debugShouldCleanupStreamingFromServer([
            ChatMessage(
              id: 'assistant-1',
              role: 'assistant',
              content: '',
              timestamp: DateTime(2024, 1, 1),
              error: const ChatMessageError(content: 'boom'),
            ),
          ]),
        ).isTrue();

        // A stale echo is still retired once the server has moved past this
        // turn: extra messages after the echo prove streaming completed, so the
        // echo must not keep the stream (and its footer/task state) attached to
        // a no-longer-tail message.
        check(
          notifier.debugShouldCleanupStreamingFromServer([
            _assistantMessage(
              id: 'assistant-1',
              content: '',
              isStreaming: false,
            ),
            ChatMessage(
              id: 'user-2',
              role: 'user',
              content: 'Next question',
              timestamp: DateTime(2024, 1, 1),
            ),
            _assistantMessage(
              id: 'assistant-2',
              content: 'Next answer',
              isStreaming: false,
            ),
          ]),
        ).isTrue();

        notifier.clearMessages();
      },
    );

    test('send failure converts active placeholder to an error row', () {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        ),
        _assistantMessage(id: 'assistant-1', content: '', isStreaming: true),
      ]);

      notifier.failLastStreamingAssistant(Exception('500'));

      final messages = container.read(chatMessagesProvider);
      check(messages).length.equals(2);
      check(messages.last.id).equals('assistant-1');
      check(messages.last.isStreaming).isFalse();
      check(messages.last.error).isNotNull();
      check(
        messages.last.error!.content ?? '',
      ).contains('server returned an error');
    });

    test(
      'failure for a missing explicit assistant never finalizes another stream',
      () {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          ChatMessage(
            id: 'user-b',
            role: 'user',
            content: 'Chat B question',
            timestamp: DateTime(2024, 1, 1),
          ),
          _assistantMessage(
            id: 'assistant-b',
            content: 'Chat B partial',
            isStreaming: true,
          ),
        ]);

        notifier.failLastStreamingAssistant(
          Exception('late chat A failure'),
          assistantMessageId: 'missing-assistant-a',
        );

        final active = container.read(chatMessagesProvider).last;
        check(active.id).equals('assistant-b');
        check(active.isStreaming).isTrue();
        check(active.error).isNull();
        notifier.clearMessages();
      },
    );

    test(
      'non-tail failure retires only its transport and preserves the newer tail',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(
            id: 'failed-assistant',
            content: 'failed partial',
            isStreaming: true,
          ),
        ]);
        final upstream = StreamController<String>();
        addTearDown(upstream.close);
        final lateChunks = <String>[];
        final controller = StreamingResponseController(
          stream: upstream.stream,
          onChunk: lateChunks.add,
          onComplete: () {},
          onError: (_, _) {},
        );
        var socketDisposed = false;
        notifier.setMessageStream('failed-assistant', controller);
        notifier.setSocketSubscriptions('failed-assistant', [
          () => socketDisposed = true,
        ]);
        notifier.addMessage(
          _assistantMessage(
            id: 'newer-assistant',
            content: 'newer partial',
            isStreaming: true,
          ),
        );

        notifier.failLastStreamingAssistant(
          Exception('old run failed'),
          assistantMessageId: 'failed-assistant',
        );

        final messages = container.read(chatMessagesProvider);
        check(messages.first.isStreaming).isFalse();
        check(messages.first.error).isNotNull();
        check(messages.last.id).equals('newer-assistant');
        check(messages.last.isStreaming).isTrue();
        check(messages.last.error).isNull();
        check(controller.isActive).isFalse();
        check(socketDisposed).isTrue();
        upstream.add('late old chunk');
        await Future<void>.delayed(Duration.zero);
        check(lateChunks).isEmpty();
        notifier.clearMessages();
      },
    );

    test(
      'non-tail failure retires its poll-only monitor, not newer transport',
      () {
        final container = _buildContainer();
        addTearDown(container.dispose);
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(
            id: 'failed-assistant',
            content: 'failed partial',
            isStreaming: true,
          ),
        ]);
        notifier.addMessage(
          _assistantMessage(
            id: 'newer-assistant',
            content: 'newer partial',
            isStreaming: true,
          ),
        );
        var newerSocketDisposed = false;
        notifier.setSocketSubscriptions('newer-assistant', [
          () => newerSocketDisposed = true,
        ]);
        notifier.debugInstallRemoteTaskMonitor('failed-assistant');
        notifier.recordResumeBoundRemoteMessageId(
          'newer-assistant',
          'newer-remote-assistant',
        );
        check(notifier.debugHasRemoteTaskMonitor).isTrue();

        notifier.failLastStreamingAssistant(
          Exception('old poll-only run failed'),
          assistantMessageId: 'failed-assistant',
        );

        final messages = container.read(chatMessagesProvider);
        check(messages.first.isStreaming).isFalse();
        check(messages.first.error).isNotNull();
        check(messages.last.id).equals('newer-assistant');
        check(messages.last.isStreaming).isTrue();
        check(notifier.debugHasRemoteTaskMonitor).isFalse();
        check(newerSocketDisposed).isFalse();
        check(
          notifier.debugBoundRemoteMessageId,
        ).equals('newer-remote-assistant');
        notifier.cancelSocketSubscriptions();
        check(newerSocketDisposed).isTrue();
        notifier.clearMessages();
      },
    );

    test('durable assistant payload preserves display modelName', () {
      final payload = debugBuildDurableAssistantPayloadForTesting(
        id: 'assistant-1',
        parentId: 'user-1',
        modelId: 'openai/gpt-4o',
        modelName: 'GPT-4o',
        timestamp: 1700000000,
      );

      check(payload['model']).equals('openai/gpt-4o');
      check(payload['modelName']).equals('GPT-4o');
    });

    test(
      'persisted Hermes projection keeps Hermes transport and rich state',
      () {
        final message = ChatMessage(
          id: 'persisted-hermes-assistant',
          role: 'assistant',
          content: 'Final answer',
          timestamp: DateTime(2024, 1, 1),
          metadata: const <String, dynamic>{
            // The Hermes serializer must override any stale generic marker.
            'transport': kDirectTransport,
            kHermesApprovalMeta: <String, dynamic>{
              'state': 'denied',
              'approvalId': 'approval-id',
              'runId': 'run-id',
            },
          },
          statusHistory: const <ChatStatusUpdate>[
            ChatStatusUpdate(
              action: 'hermes_tool_search',
              description: 'Search',
              done: true,
            ),
          ],
          followUps: const <String>['Next question'],
          error: const ChatMessageError(content: 'Visible terminal error'),
        );

        final payload = hermesPersistedMessagePayloadForTest(message);
        final metadata = payload['metadata'] as Map<String, dynamic>;
        check(metadata['transport']).equals(kHermesTransport);
        check(metadata[kHermesApprovalMeta]).isNotNull();
        check(payload['isStreaming']).equals(false);
        check(payload['done']).equals(true);
        check(payload['statusHistory'] as List<dynamic>).length.equals(1);
        check(
          payload['followUps'] as List<dynamic>,
        ).deepEquals(<String>['Next question']);
        check(
          (payload['error'] as Map<String, dynamic>)['content'],
        ).equals('Visible terminal error');
      },
    );

    test(
      'Hermes projection buffers token content between state boundaries',
      () {
        final chunks = List<String>.generate(2000, (index) => '$index|');

        final result = bufferedHermesProjectionContentForTest(chunks);

        final firstHalf = chunks.take(chunks.length ~/ 2).join();
        check(result.beforeMetadataBoundary).equals('seed:');
        check(result.afterMetadataBoundary).equals('seed:$firstHalf');
        check(result.beforeFinalize).equals('seed:$firstHalf');
        check(result.finalizedContent).equals('seed:${chunks.join()}');
        check(result.finalizedBufferLength).equals(0);
        check(result.materializationCount).equals(2);
      },
    );

    test(
      'oversized Hermes version graph is evicted without flushing older state',
      () {
        final timestamp = DateTime(2024, 1, 1);
        final bounded = ChatMessage(
          id: 'bounded-projection',
          role: 'assistant',
          content: 'Small final answer',
          timestamp: timestamp,
        );
        final versionHeavy = ChatMessage(
          id: 'version-heavy-projection',
          role: 'assistant',
          content: 'Current answer',
          timestamp: timestamp,
          versions: <ChatMessageVersion>[
            ChatMessageVersion(
              id: 'large-prior-version',
              content: 'Prior answer',
              timestamp: timestamp,
              files: <Map<String, dynamic>>[
                <String, dynamic>{'embedded': 'x' * 4096},
              ],
              output: <Map<String, dynamic>>[
                <String, dynamic>{'type': 'message', 'content': 'y' * 4096},
              ],
            ),
          ],
        );

        final retained = retainedHermesProjectionIdsForTest(<ChatMessage>[
          bounded,
          versionHeavy,
        ], maxRetainedBytes: 2048);

        check(retained).deepEquals(<String>['bounded-projection']);
      },
    );

    test('failed compact Hermes approval persistence remains adoptable', () {
      check(failedCompactedHermesApprovalRemainsAdoptableForTest()).isTrue();
    });

    test(
      'streaming content-only changes keep the structure signature stable',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(content: 'Draft', isStreaming: true),
        ]);
        final initialSignature = container.read(
          chatMessageStructureSignatureProvider,
        );
        var notifications = 0;
        final subscription = container.listen<String>(
          chatMessageStructureSignatureProvider,
          (_, _) => notifications += 1,
          fireImmediately: false,
        );
        addTearDown(subscription.close);

        notifier.updateMessageById(
          'assistant-1',
          (current) => current.copyWith(content: 'Draft plus more content'),
        );
        await Future<void>.delayed(Duration.zero);

        check(
          container.read(chatMessageStructureSignatureProvider),
        ).equals(initialSignature);
        check(notifications).equals(0);

        notifier.clearMessages();
      },
    );

    test('streaming completion keeps the structure signature stable', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(content: 'Final response', isStreaming: true),
      ]);
      final initialSignature = container.read(
        chatMessageStructureSignatureProvider,
      );
      var notifications = 0;
      final subscription = container.listen<String>(
        chatMessageStructureSignatureProvider,
        (_, _) => notifications += 1,
        fireImmediately: false,
      );
      addTearDown(subscription.close);

      notifier.updateMessageById(
        'assistant-1',
        (current) => current.copyWith(isStreaming: false),
      );
      await Future<void>.delayed(Duration.zero);

      check(
        container.read(chatMessageStructureSignatureProvider),
      ).equals(initialSignature);
      check(notifications).equals(0);

      notifier.clearMessages();
    });

    test(
      'server snapshots do not clear already-visible follow-ups for same response',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        container.read(chatMessagesProvider.notifier);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final localAssistant = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer',
          followUps: const ['Ask again'],
        );

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', [userMessage, localAssistant]));
        await Future<void>.delayed(Duration.zero);

        final serverAssistantWithoutFollowUps = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer',
        );
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation('chat-1', [
                userMessage,
                serverAssistantWithoutFollowUps,
              ]),
            );
        await Future<void>.delayed(Duration.zero);

        check(
          container.read(chatMessagesProvider).last.followUps,
        ).deepEquals(['Ask again']);
      },
    );

    test(
      'server snapshots do not clear already-visible response content',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        container.read(chatMessagesProvider.notifier);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final localAssistant = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer that streamed completely',
          followUps: const ['Ask again'],
          metadata: const {'transport': 'httpStream'},
        );

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', [userMessage, localAssistant]));
        await Future<void>.delayed(Duration.zero);

        final laggingServerAssistant = _assistantMessage(
          id: 'assistant-1',
          content: '',
        );
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation('chat-1', [userMessage, laggingServerAssistant]),
            );
        await Future<void>.delayed(Duration.zero);

        check(
          container.read(chatMessagesProvider).last.content,
        ).equals('Answer that streamed completely');
        check(
          container.read(chatMessagesProvider).last.followUps,
        ).deepEquals(['Ask again']);
      },
    );

    test('preserved follow-ups also overwrite a stale empty followUps key in '
        'server metadata', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);
      container.read(chatMessagesProvider.notifier);

      final userMessage = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Hello',
        timestamp: DateTime(2024, 1, 1),
      );
      final localAssistant = _assistantMessage(
        id: 'assistant-1',
        content: 'Answer',
        followUps: const ['Ask again'],
      );

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', [userMessage, localAssistant]));
      await Future<void>.delayed(Duration.zero);

      // Server snapshot drops the follow-ups AND carries an explicit empty
      // followUps in its metadata map.
      final serverAssistant = _assistantMessage(
        id: 'assistant-1',
        content: 'Answer',
        metadata: const {'followUps': <String>[]},
      );
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', [userMessage, serverAssistant]));
      await Future<void>.delayed(Duration.zero);

      final adopted = container.read(chatMessagesProvider).last;
      check(adopted.followUps).deepEquals(['Ask again']);
      // The metadata mirror must match the typed field, not stay stale [].
      check(
        (adopted.metadata?['followUps'] as List).cast<String>(),
      ).deepEquals(['Ask again']);
    });

    test('content-preserving snapshot keeps local-only metadata (modelName) '
        'when the server snapshot lacks it', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);
      container.read(chatMessagesProvider.notifier);

      final userMessage = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Hello',
        timestamp: DateTime(2024, 1, 1),
      );
      // Locally-streamed assistant carries the modelName chip this PR writes
      // to every placeholder, and is fresher than the server snapshot.
      final localAssistant = _assistantMessage(
        id: 'assistant-1',
        content: 'Answer that streamed completely',
        // Locally streamed: carries provenance (transport) plus the modelName
        // chip. The bug erased modelName when content was preserved.
        metadata: const {'transport': 'httpStream', 'modelName': 'GPT-4o'},
      );

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', [userMessage, localAssistant]));
      await Future<void>.delayed(Duration.zero);

      // Server snapshot captured before the durable payload was finalized:
      // shorter content and no modelName.
      final laggingServerAssistant = _assistantMessage(
        id: 'assistant-1',
        content: 'Answer that',
      );
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', [userMessage, laggingServerAssistant]));
      await Future<void>.delayed(Duration.zero);

      final adopted = container.read(chatMessagesProvider).last;
      check(adopted.content).equals('Answer that streamed completely');
      check(adopted.metadata?['modelName']).equals('GPT-4o');
    });

    test('empty placeholder keeps its modelName when a pre-first-token server '
        'snapshot lacks it', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);
      container.read(chatMessagesProvider.notifier);

      final userMessage = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Hello',
        timestamp: DateTime(2024, 1, 1),
      );
      // Fresh placeholder: no content yet, but already carries the modelName
      // chip written at send time.
      final placeholder = _assistantMessage(
        id: 'assistant-1',
        content: '',
        metadata: const {'modelName': 'GPT-4o'},
      );

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', [userMessage, placeholder]));
      await Future<void>.delayed(Duration.zero);

      // Stale snapshot adopted before the first token: server content arrives
      // but without modelName.
      final serverFirstTokens = _assistantMessage(
        id: 'assistant-1',
        content: 'Hel',
      );
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', [userMessage, serverFirstTokens]));
      await Future<void>.delayed(Duration.zero);

      final adopted = container.read(chatMessagesProvider).last;
      check(adopted.content).equals('Hel');
      check(adopted.metadata?['modelName']).equals('GPT-4o');
    });

    test(
      'an explicit empty server modelName does not blank the preserved local '
      'model name',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        container.read(chatMessagesProvider.notifier);

        final userMessage = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Hello',
          timestamp: DateTime(2024, 1, 1),
        );
        final placeholder = _assistantMessage(
          id: 'assistant-1',
          content: '',
          metadata: const {'modelName': 'GPT-4o'},
        );

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', [userMessage, placeholder]));
        await Future<void>.delayed(Duration.zero);

        // Server snapshot carries an explicit empty modelName.
        final serverWithBlankModel = _assistantMessage(
          id: 'assistant-1',
          content: 'Hel',
          metadata: const {'modelName': '   '},
        );
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', [userMessage, serverWithBlankModel]));
        await Future<void>.delayed(Duration.zero);

        final adopted = container.read(chatMessagesProvider).last;
        check(adopted.metadata?['modelName']).equals('GPT-4o');
      },
    );

    test(
      'an older completed message defers to a corrected server snapshot; only '
      'the streaming tail is content-preserved',
      () async {
        final container = _buildContainer();
        addTearDown(container.dispose);
        container.read(chatMessagesProvider.notifier);

        final user1 = ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Q1',
          timestamp: DateTime(2024, 1, 1),
        );
        final user2 = ChatMessage(
          id: 'user-2',
          role: 'user',
          content: 'Q2',
          timestamp: DateTime(2024, 1, 1),
        );
        // Older, already-completed assistant whose local body is longer than
        // the server's with a matching prefix — must NOT block a correction.
        final olderLocal = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer one local-extra',
          metadata: const {'responseDone': true},
        );
        // Streaming tail: its longer local body is still preserved.
        final tailLocal = _assistantMessage(
          id: 'assistant-2',
          content: 'Answer two streamed completely',
          metadata: const {'transport': 'httpStream'},
        );

        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation('chat-1', [user1, olderLocal, user2, tailLocal]),
            );
        await Future<void>.delayed(Duration.zero);

        // Authoritative server snapshot: the older message is corrected
        // (shorter, same prefix); the tail still lags.
        final olderServer = _assistantMessage(
          id: 'assistant-1',
          content: 'Answer one',
        );
        final tailServer = _assistantMessage(
          id: 'assistant-2',
          content: 'Answer two',
        );
        container
            .read(activeConversationProvider.notifier)
            .set(
              _conversation('chat-1', [user1, olderServer, user2, tailServer]),
            );
        await Future<void>.delayed(Duration.zero);

        final messages = container.read(chatMessagesProvider);
        final older = messages.firstWhere((m) => m.id == 'assistant-1');
        final tail = messages.firstWhere((m) => m.id == 'assistant-2');
        // Older completed message defers to the server correction.
        check(older.content).equals('Answer one');
        // Streaming tail keeps its longer local body.
        check(tail.content).equals('Answer two streamed completely');
      },
    );
  });

  group('Feature C — local streaming protection invariants', () {
    test(
      'Hermes metadata protects its optimistic placeholder before dispatch',
      () {
        final container = _buildContainer();
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _assistantMessage(
            id: 'hermes-placeholder',
            content: '',
            isStreaming: true,
            metadata: const <String, dynamic>{'transport': kHermesTransport},
          ),
        ]);

        check(notifier.debugShouldProtectLocalStreamingState).isTrue();
        notifier.clearMessages();
      },
    );

    // De-risk #1: a NORMAL send's protection behaviour must be byte-unchanged.
    // Registering a stream/subscription for the *current* streaming message id
    // makes protection hold; this is the exact seam dispatchChatTransport uses
    // for both normal sends and resume, so it pins the shared behaviour.
    test('registering subscriptions for the streaming tail enables '
        'protection (normal-send behaviour, unchanged)', () {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(id: 'assistant-1', content: '', isStreaming: true),
      ]);

      // No transport registered yet -> not protected.
      check(notifier.debugShouldProtectLocalStreamingState).isFalse();

      notifier.setSocketSubscriptions('assistant-1', [() {}]);

      // Matching id + active subscription -> protected.
      check(notifier.debugShouldProtectLocalStreamingState).isTrue();

      // Release streaming bookkeeping before the container disposes.
      notifier.cancelSocketSubscriptions();
      notifier.clearMessages();
    });

    // De-risk #2: resume must set protection true ONLY for the matching message
    // id. A subscription bound to a *different* message id than the streaming
    // tail must NOT protect (otherwise a stale resume would suppress adoption of
    // the genuine current message).
    test('subscriptions bound to a non-matching message id do NOT '
        'protect the streaming tail', () {
      final container = _buildContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _assistantMessage(id: 'assistant-1', content: '', isStreaming: true),
      ]);

      // Register against a foreign id (simulating a stale/other-message resume).
      notifier.setSocketSubscriptions('other-message', [() {}]);

      check(notifier.debugShouldProtectLocalStreamingState).isFalse();

      notifier.cancelSocketSubscriptions();
      notifier.clearMessages();
    });

    // De-risk #5 (offline branch): with no socket, _detectActiveOnOpen's resume
    // attach is a no-op, so opening a conversation registers no socket
    // subscriptions and protection stays false (identical to today's poll-only
    // behaviour). socketServiceProvider is overridden to null in _buildContainer.
    test('opening a conversation with no socket registers no resume '
        'subscriptions (offline poll-only fallback)', () async {
      final container = _buildContainer();
      addTearDown(container.dispose);

      // Materialize the notifier so it listens to conversation changes.
      container.read(chatMessagesProvider.notifier);

      container
          .read(activeConversationProvider.notifier)
          .set(
            _conversation('chat-1', [
              _assistantMessage(id: 'assistant-1', content: 'Partial'),
            ]),
          );
      await Future<void>.delayed(Duration.zero);

      // No socket -> no resume subscriptions -> not protected. (The 1s poll
      // fallback is gated on an API service, also null here, so it is inert.)
      check(
        container
            .read(chatMessagesProvider.notifier)
            .debugShouldProtectLocalStreamingState,
      ).isFalse();
    });
  });
}
