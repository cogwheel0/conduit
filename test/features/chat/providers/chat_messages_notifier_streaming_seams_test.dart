import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/streaming_response_controller.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestActiveConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
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

class _PreflightHermesApi extends HermesApiService {
  _PreflightHermesApi()
    : super(
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
  final List<String> deletedSessions = [];
  var createRunCalls = 0;

  @override
  Future<String> createSession({String? title, CancelToken? cancelToken}) {
    createSessionStarted.complete();
    // Intentionally ignore cancellation to model a server response racing the
    // client's Stop/New Chat request.
    return createSessionGate.future;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    deletedSessions.add(sessionId);
    deleteSessionStarted.complete();
    await deleteSessionGate.future;
  }

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
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

ProviderContainer _buildContainer({HermesApiService? hermesService}) {
  return ProviderContainer(
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
    test('Hermes rejects file attachments with an in-chat error', () async {
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
            contains('does not support file or context attachments'),
          ),
        ),
      );

      final messages = container.read(chatMessagesProvider);
      check(messages).has((it) => it.length, 'length').equals(2);
      expect(messages.first.attachmentIds, ['file-1']);
      expect(
        messages.last.error?.content,
        contains('does not support file or context attachments'),
      );
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
        check(messages).has((it) => it.length, 'length').equals(2);
        check(messages.first.files).isNotNull();
        check(messages.first.files!).isNotEmpty();
        expect(
          messages.last.error?.content,
          contains('does not support file or context attachments'),
        );
        check(container.read(contextAttachmentsProvider)).single
            .has((attachment) => attachment.displayName, 'displayName')
            .equals('Reference');
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

    test('Hermes regeneration rebinds the active session shell', () async {
      final service = _BranchingHermesApi();
      final container = ProviderContainer(
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
        final container = ProviderContainer(
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
            );
        await Future<void>.delayed(Duration.zero);

        await regenerateMessage(container, user.content, null);

        final messages = container.read(chatMessagesProvider);
        check(messages).length.equals(2);
        check(messages.last.id).equals('assistant-1');
        check(messages.last.metadata?['archivedVariant']).isNull();
        check(messages.last.versions).length.equals(1);
        check(messages.last.versions.single.content).equals('previous answer');
        container.read(chatMessagesProvider.notifier).clearMessages();
      },
    );

    test(
      'preflight cancellation waits for late session cleanup without dispatch',
      () async {
        final service = _PreflightHermesApi();
        final container = ProviderContainer(
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
        );
        await service.createSessionStarted.future.timeout(
          const Duration(seconds: 1),
        );

        final cancellation = container
            .read(hermesRunRegistryProvider)
            .cancel('preflight');
        check(cancellation).isNotNull();
        var cancellationSettled = false;
        cancellation!.then((_) => cancellationSettled = true);
        await Future<void>.delayed(Duration.zero);
        check(cancellationSettled).isFalse();

        service.createSessionGate.complete('late-session');
        await service.deleteSessionStarted.future.timeout(
          const Duration(seconds: 1),
        );
        await Future<void>.delayed(Duration.zero);
        check(cancellationSettled).isFalse();
        service.deleteSessionGate.complete();
        await dispatch.timeout(const Duration(seconds: 1));
        await cancellation.timeout(const Duration(seconds: 1));

        check(service.createRunCalls).equals(0);
        check(service.deletedSessions).deepEquals(['late-session']);
        check(container.read(hermesActiveSessionProvider)).isNull();
        check(cancellationSettled).isTrue();
        check(
          container.read(chatMessagesProvider).single.isStreaming,
        ).isFalse();
        notifier.clearMessages();
      },
    );

    test(
      'cancelAll keeps the originating service live through late run cleanup',
      () async {
        final service = _CreateRunRaceHermesApi();
        final container = ProviderContainer(
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
        registry.register(
          'first',
          runId: 'run-1',
          cancelToken: firstToken,
          subscription: const Stream<void>.empty().listen(null),
          stopRemote: service.stopRun,
        );
        registry.register(
          'second',
          runId: 'run-2',
          cancelToken: secondToken,
          subscription: const Stream<void>.empty().listen(null),
          stopRemote: service.stopRun,
        );
        registry.registerPending(
          'pending',
          cancelToken: pendingToken,
          onCancelled: () {},
        );

        resetHermesForNewChat(container);
        await Future<void>.delayed(Duration.zero);

        check(firstToken.isCancelled).isTrue();
        check(secondToken.isCancelled).isTrue();
        check(pendingToken.isCancelled).isTrue();
        check(service.stopped).unorderedEquals(['run-1', 'run-2']);
        check(container.read(hermesActiveSessionProvider)).isNull();
        notifier.clearMessages();
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
