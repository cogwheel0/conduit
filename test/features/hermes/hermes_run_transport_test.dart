import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_run_transport.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHermesApiService extends HermesApiService {
  _FakeHermesApiService(
    this.events, {
    this.runResult = const {},
    this.runResults = const [],
    this.eventsOverride,
    this.createRunGate,
    this.getRunGate,
    this.stopRunGate,
    this.stopRunError,
    this.responseEvents = const [],
    this.responseEventsOverride,
    this.responseSessionId,
    this.responseResult = const {},
    this.responseResults,
    this.getResponseError,
  }) : super(
         config: HermesConfig(enabled: true, baseUrl: 'http://x', apiKey: 'k'),
         dio: Dio(),
       );

  final List<HermesRunEvent> events;
  final Map<String, dynamic> runResult;
  final List<Map<String, dynamic>> runResults;
  final Stream<HermesRunEvent>? eventsOverride;
  final Completer<String>? createRunGate;
  final Completer<Map<String, dynamic>>? getRunGate;
  final Completer<void>? stopRunGate;
  final Object? stopRunError;
  final List<HermesRunEvent> responseEvents;
  final Stream<HermesRunEvent>? responseEventsOverride;
  final String? responseSessionId;
  final Map<String, dynamic> responseResult;
  final List<Map<String, dynamic>>? responseResults;
  final Object? getResponseError;
  var getRunCalls = 0;
  var streamResponseCalls = 0;
  var getResponseCalls = 0;
  final List<String> stoppedRuns = [];
  CancelToken? lastStopCancelToken;
  HermesChatInput? lastResponseInput;
  String? lastResponseSessionId;
  String? lastResponseConversation;
  String? lastResponsePreviousResponseId;
  List<Map<String, dynamic>>? lastResponseConversationHistory;
  String? lastResponseInstructions;
  CancelToken? lastResponseCancelToken;

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    CancelToken? cancelToken,
  }) async => createRunGate?.future ?? 'run-1';

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) => eventsOverride ?? Stream<HermesRunEvent>.fromIterable(events);

  @override
  Future<Map<String, dynamic>> getRun(
    String runId, {
    CancelToken? cancelToken,
  }) async {
    final index = getRunCalls++;
    if (getRunGate != null) return getRunGate!.future;
    if (runResults.isNotEmpty) {
      return runResults[index.clamp(0, runResults.length - 1)];
    }
    return runResult;
  }

  @override
  Future<void> stopRun(String runId, {CancelToken? cancelToken}) async {
    stoppedRuns.add(runId);
    lastStopCancelToken = cancelToken;
    await stopRunGate?.future;
    final error = stopRunError;
    if (error != null) throw error;
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
    streamResponseCalls++;
    lastResponseInput = input;
    lastResponseSessionId = sessionId;
    lastResponseConversation = conversation;
    lastResponsePreviousResponseId = previousResponseId;
    lastResponseConversationHistory = conversationHistory;
    lastResponseInstructions = instructions;
    lastResponseCancelToken = cancelToken;
    return HermesResponseStream(
      events:
          responseEventsOverride ??
          Stream<HermesRunEvent>.fromIterable(responseEvents),
      sessionId: responseSessionId,
    );
  }

  @override
  Future<Map<String, dynamic>> getResponse(
    String responseId, {
    CancelToken? cancelToken,
  }) async {
    getResponseCalls++;
    final error = getResponseError;
    if (error != null) throw error;
    final results = responseResults;
    if (results != null && results.isNotEmpty) {
      final requestedIndex = getResponseCalls - 1;
      final index = requestedIndex < results.length
          ? requestedIndex
          : results.length - 1;
      return results[index];
    }
    return responseResult;
  }
}

void main() {
  group('dispatchHermesResponse', () {
    test('forwards typed input and response chain context', () async {
      final input = HermesChatInput.multimodal([
        HermesInputTextPart('What is shown?'),
        HermesInputImagePart('data:image/png;base64,aGVsbG8='),
      ]);
      const history = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'Earlier question'},
        {'role': 'assistant', 'content': 'Earlier answer'},
      ];
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: const [HermesRunDone()],
        responseSessionId: 'session-from-header',
      );
      String? establishedSession;

      await dispatchHermesResponse(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'response-message',
        input: input,
        sessionId: 'session-1',
        previousResponseId: 'resp-previous',
        conversationHistory: history,
        instructions: 'Be concise',
        onSessionEstablished: (sessionId) => establishedSession = sessionId,
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (_) {},
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(fake.streamResponseCalls).equals(1);
      check(identical(fake.lastResponseInput, input)).isTrue();
      check(fake.lastResponseSessionId).equals('session-1');
      check(fake.lastResponsePreviousResponseId).equals('resp-previous');
      check(fake.lastResponseConversation).isNull();
      expect(fake.lastResponseConversationHistory, equals(history));
      check(fake.lastResponseInstructions).equals('Be concise');
      check(establishedSession).equals('session-from-header');
    });

    test('records response identity and transport metadata', () async {
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: const [
          HermesResponseCreated('resp-1'),
          HermesRunDone(),
        ],
      );
      var message = ChatMessage(
        id: 'm',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );

      await dispatchHermesResponse(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: message.id,
        input: HermesChatInput.text('hello'),
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(message.metadata?['transport']).equals(kHermesTransport);
      check(
        message.metadata?['hermesTransportMode'],
      ).equals(kHermesResponsesMode);
      check(message.metadata?['hermesResponseId']).equals('resp-1');
      check(message.metadata?['hermesRunId']).isNull();
    });

    test('reconciles deltas with final output without duplication', () async {
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: const [
          HermesResponseCreated('resp-1'),
          HermesTokenDelta('Hello'),
          HermesTokenDelta(' world'),
          HermesFinalOutput('Hello world'),
          HermesRunDone(),
        ],
      );
      final content = StringBuffer();

      await dispatchHermesResponse(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: HermesChatInput.text('hello'),
        appendContent: content.write,
        appendStatus: (_) {},
        updateMessage: (_) {},
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(content.toString()).equals('Hello world');
    });

    test('appends a final-only response', () async {
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: const [
          HermesResponseCreated('resp-1'),
          HermesFinalOutput('Only the final response'),
          HermesRunDone(),
        ],
      );
      final content = StringBuffer();

      await dispatchHermesResponse(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: HermesChatInput.text('hello'),
        appendContent: content.write,
        appendStatus: (_) {},
        updateMessage: (_) {},
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(content.toString()).equals('Only the final response');
    });

    test('cancellation closes the stream without stopping a run', () async {
      final listened = Completer<void>();
      final cancelled = Completer<void>();
      final events = StreamController<HermesRunEvent>(
        onListen: listened.complete,
        onCancel: cancelled.complete,
      );
      addTearDown(() async {
        if (!events.isClosed) await events.close();
      });
      final fake = _FakeHermesApiService(
        const [],
        responseEventsOverride: events.stream,
      );
      final registry = HermesRunRegistry();
      var finished = false;
      var completedUi = false;

      final dispatch = dispatchHermesResponse(
        service: fake,
        registry: registry,
        assistantMessageId: 'm',
        input: HermesChatInput.text('hello'),
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (_) {},
        finishStreaming: () => finished = true,
        completeStreamingUi: () => completedUi = true,
      );
      await listened.future;
      await Future<void>.delayed(Duration.zero);

      final cancellation = registry.cancel('m');
      check(cancellation).isNotNull();
      await cancellation!;
      await dispatch.timeout(const Duration(seconds: 1));
      await cancelled.future.timeout(const Duration(seconds: 1));

      check(fake.lastResponseCancelToken).isNotNull();
      check(fake.lastResponseCancelToken!.isCancelled).isTrue();
      check(fake.stoppedRuns).isEmpty();
      check(finished).isTrue();
      check(completedUi).isTrue();
    });

    test('recovers a completed response after the stream drops', () async {
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: const [HermesResponseCreated('resp-recover')],
        responseResult: const {
          'id': 'resp-recover',
          'object': 'response',
          'created_at': 1,
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'id': 'msg-recover',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {'type': 'output_text', 'text': 'Recovered response'},
              ],
            },
          ],
        },
      );
      final content = StringBuffer();

      await dispatchHermesResponse(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: HermesChatInput.text('hello'),
        appendContent: content.write,
        appendStatus: (_) {},
        updateMessage: (_) {},
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(fake.getResponseCalls).equals(1);
      check(content.toString()).equals('Recovered response');
    });

    test('recovery waits while a stored response is queued', () async {
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: const [HermesResponseCreated('resp-queued')],
        responseResults: const [
          {
            'id': 'resp-queued',
            'object': 'response',
            'created_at': 1,
            'status': 'queued',
            'output': <dynamic>[],
          },
          {
            'id': 'resp-queued',
            'object': 'response',
            'created_at': 1,
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'id': 'msg-queued',
                'role': 'assistant',
                'status': 'completed',
                'content': [
                  {'type': 'output_text', 'text': 'Ready now'},
                ],
              },
            ],
          },
        ],
      );
      final content = StringBuffer();

      await dispatchHermesResponse(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: HermesChatInput.text('hello'),
        recoveryPollInterval: Duration.zero,
        appendContent: content.write,
        appendStatus: (_) {},
        updateMessage: (_) {},
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(fake.getResponseCalls).equals(2);
      check(content.toString()).equals('Ready now');
    });

    test(
      'recovers a sparse stored response from older Hermes servers',
      () async {
        final fake = _FakeHermesApiService(
          const [],
          responseEvents: const [HermesResponseCreated('resp-legacy')],
          responseResult: const {
            'status': 'completed',
            'output': 'Legacy response',
          },
        );
        final content = StringBuffer();

        await dispatchHermesResponse(
          service: fake,
          registry: HermesRunRegistry(),
          assistantMessageId: 'm',
          input: HermesChatInput.text('hello'),
          appendContent: content.write,
          appendStatus: (_) {},
          updateMessage: (_) {},
          finishStreaming: () {},
          completeStreamingUi: () {},
        );

        check(content.toString()).equals('Legacy response');
      },
    );

    test('surfaces recovery errors after a dropped stream', () async {
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: const [HermesResponseCreated('resp-recover')],
        getResponseError: StateError('response expired'),
      );
      var message = ChatMessage(
        id: 'm',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );

      await dispatchHermesResponse(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: message.id,
        input: HermesChatInput.text('hello'),
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(fake.getResponseCalls).equals(1);
      check(message.error).isNotNull();
      expect(message.error!.content, contains('response expired'));
    });
  });

  test('dispatchHermesRun maps events onto chat callbacks', () async {
    final fake = _FakeHermesApiService([
      const HermesToolProgress(toolName: 'web_search', done: false),
      const HermesTokenDelta('Hello'),
      const HermesTokenDelta(' world'),
      const HermesToolProgress(toolName: 'web_search', done: true),
      const HermesApprovalRequested(approvalId: 'a1', summary: 'ok?'),
      const HermesRunDone(),
    ]);

    final content = StringBuffer();
    final statuses = <ChatStatusUpdate>[];
    var message = ChatMessage(
      id: 'm',
      role: 'assistant',
      content: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );
    var finished = false;
    var completedUi = false;

    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: content.write,
      appendStatus: statuses.add,
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () => finished = true,
      completeStreamingUi: () => completedUi = true,
    );

    check(content.toString()).equals('Hello world');
    check(statuses).has((s) => s.length, 'length').equals(2);
    check(statuses.first.done).equals(false);
    check(statuses.last.done).equals(true);

    check(message.metadata?['transport']).equals(kHermesTransport);
    check(message.metadata?['hermesRunId']).equals('run-1');

    final approval = message.metadata?[kHermesApprovalMeta] as Map?;
    check(approval).isNotNull();
    check(approval!['state']).equals('pending');
    check(approval['approvalId']).equals('a1');

    check(finished).isTrue();
    check(completedUi).isTrue();
  });

  test('failed tool detail is visible in its completed status', () async {
    final fake = _FakeHermesApiService(const [
      HermesToolProgress(toolName: 'web_search', done: false),
      HermesToolProgress(
        toolName: 'web_search',
        done: true,
        detail: 'provider unavailable',
        failed: true,
      ),
      HermesRunDone(),
    ]);
    final statuses = <ChatStatusUpdate>[];

    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: (_) {},
      appendStatus: statuses.add,
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    check(statuses).length.equals(2);
    check(statuses.first.description).equals('web_search');
    check(statuses.last)
      ..has(
        (status) => status.description,
        'description',
      ).equals('web_search failed: provider unavailable')
      ..has((status) => status.done, 'done').equals(true);
  });

  test('appends final output when no deltas streamed', () async {
    final fake = _FakeHermesApiService(const [
      HermesFinalOutput('Only the final'),
      HermesRunDone(),
    ]);
    final content = StringBuffer();
    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: content.write,
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );
    check(content.toString()).equals('Only the final');
  });

  test('does not duplicate when deltas and final output both arrive', () async {
    final fake = _FakeHermesApiService(const [
      HermesTokenDelta('pong'),
      HermesFinalOutput('pong'),
      HermesRunDone(),
    ]);
    final content = StringBuffer();
    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: content.write,
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );
    check(content.toString()).equals('pong');
  });

  test('appends missing suffix from authoritative terminal output', () async {
    final fake = _FakeHermesApiService(const [
      HermesTokenDelta('Hello'),
      HermesFinalOutput('Hello world'),
      HermesRunDone(),
    ]);
    final content = StringBuffer();

    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: content.write,
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    check(content.toString()).equals('Hello world');
  });

  test(
    'replaces streamed text when terminal output corrects its prefix',
    () async {
      final fake = _FakeHermesApiService(const [
        HermesTokenDelta('Helo'),
        HermesFinalOutput('Hello world'),
        HermesRunDone(),
      ]);
      var content = '';

      await dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: 'hi',
        appendContent: (delta) => content += delta,
        replaceContent: (value) => content = value,
        appendStatus: (_) {},
        updateMessage: (_) {},
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(content).equals('Hello world');
    },
  );

  test('terminal event completes dispatch while SSE remains open', () async {
    final events = StreamController<HermesRunEvent>();
    addTearDown(events.close);
    final fake = _FakeHermesApiService(const [], eventsOverride: events.stream);
    final dispatch = dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    events.add(const HermesRunDone());
    await dispatch.timeout(const Duration(seconds: 1));
  });

  test('stop during createRun stops the remote id once it arrives', () async {
    final gate = Completer<String>();
    final registry = HermesRunRegistry();
    final fake = _FakeHermesApiService(const [], createRunGate: gate);
    final dispatch = dispatchHermesRun(
      service: fake,
      registry: registry,
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    registry.cancel('m');
    gate.complete('run-late');

    await dispatch.timeout(const Duration(seconds: 1));
    check(fake.stoppedRuns).deepEquals(['run-late']);
  });

  test('late create cleanup uses a fresh bounded stop token', () async {
    final createGate = Completer<String>();
    final stopGate = Completer<void>();
    final runToken = CancelToken();
    final registry = HermesRunRegistry();
    final fake = _FakeHermesApiService(
      const [],
      createRunGate: createGate,
      stopRunGate: stopGate,
    );
    final dispatch = dispatchHermesRun(
      service: fake,
      registry: registry,
      assistantMessageId: 'm',
      input: 'hi',
      cancelToken: runToken,
      remoteStopTimeout: const Duration(milliseconds: 10),
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    registry.cancel('m');
    createGate.complete('run-late');
    await dispatch.timeout(const Duration(seconds: 1));

    check(fake.stoppedRuns).deepEquals(['run-late']);
    check(fake.lastStopCancelToken).isNotNull();
    check(identical(fake.lastStopCancelToken, runToken)).isFalse();
    check(fake.lastStopCancelToken!.isCancelled).isTrue();
    stopGate.complete();
  });

  test('stop after registration completes dispatch cleanup', () async {
    final events = StreamController<HermesRunEvent>();
    addTearDown(events.close);
    final registry = HermesRunRegistry();
    final fake = _FakeHermesApiService(const [], eventsOverride: events.stream);
    final dispatch = dispatchHermesRun(
      service: fake,
      registry: registry,
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    while (registry.runIdFor('m') == null) {
      await Future<void>.delayed(Duration.zero);
    }
    final stop = registry.cancel('m');
    check(stop).isNotNull();
    await stop!;

    await dispatch.timeout(const Duration(seconds: 1));
    check(registry.runIdFor('m')).isNull();
    check(fake.stoppedRuns).deepEquals(['run-1']);
  });

  test(
    'remote stop failure is surfaced without poisoning cancellation',
    () async {
      final events = StreamController<HermesRunEvent>();
      addTearDown(events.close);
      final registry = HermesRunRegistry();
      final fake = _FakeHermesApiService(
        const [],
        eventsOverride: events.stream,
        stopRunError: StateError('offline'),
      );
      var message = ChatMessage(
        id: 'm',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final dispatch = dispatchHermesRun(
        service: fake,
        registry: registry,
        assistantMessageId: 'm',
        input: 'hi',
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      while (registry.runIdFor('m') == null) {
        await Future<void>.delayed(Duration.zero);
      }
      final cancellation = registry.cancel('m');
      check(cancellation).isNotNull();
      await cancellation;
      await dispatch.timeout(const Duration(seconds: 1));

      check(message.error).isNotNull();
      expect(message.error!.content, contains('may still be running'));
    },
  );

  test('recovers final output when the event stream drops', () async {
    // Stream ends with no terminal event (dropped); getRun reconciles it.
    final fake = _FakeHermesApiService(
      const [],
      runResult: const {'status': 'completed', 'output': 'Recovered answer'},
    );

    final content = StringBuffer();
    var message = ChatMessage(
      id: 'm',
      role: 'assistant',
      content: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );

    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: content.write,
      appendStatus: (_) {},
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    check(content.toString()).equals('Recovered answer');
  });

  test(
    'recovery discards a getRun result that arrives after cancellation',
    () async {
      final getRunGate = Completer<Map<String, dynamic>>();
      final runToken = CancelToken();
      final fake = _FakeHermesApiService(const [], getRunGate: getRunGate);
      final content = StringBuffer();
      var message = ChatMessage(
        id: 'm',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );

      final dispatch = dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: 'hi',
        cancelToken: runToken,
        appendContent: content.write,
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );
      while (fake.getRunCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      runToken.cancel('stopped');
      getRunGate.complete(const {
        'status': 'completed',
        'output': 'Late answer',
      });
      await dispatch.timeout(const Duration(seconds: 1));

      check(content.toString()).isEmpty();
      check(message.error).isNull();
    },
  );

  test('recovery suppresses getRun errors caused by cancellation', () async {
    final getRunGate = Completer<Map<String, dynamic>>();
    final runToken = CancelToken();
    final fake = _FakeHermesApiService(const [], getRunGate: getRunGate);
    var message = ChatMessage(
      id: 'm',
      role: 'assistant',
      content: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final dispatch = dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      cancelToken: runToken,
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () {},
      completeStreamingUi: () {},
    );
    while (fake.getRunCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }

    runToken.cancel('stopped');
    getRunGate.completeError(StateError('request cancelled'));
    await dispatch.timeout(const Duration(seconds: 1));

    check(message.error).isNull();
  });

  test('recovered remote cancellation is not reported as success', () async {
    for (final status in const ['cancelled', 'canceled', 'stopped']) {
      final fake = _FakeHermesApiService(
        const [],
        runResult: {'status': status, 'output': 'Partial answer'},
      );
      var message = ChatMessage(
        id: 'm-$status',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );

      await dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: message.id,
        input: 'hi',
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(message.error).isNotNull();
    }
  });

  test(
    'recovery waits for terminal state and ignores running output',
    () async {
      final fake = _FakeHermesApiService(
        const [],
        runResults: const [
          {'status': 'running', 'output': 'Partial'},
          {'status': 'completed', 'output': 'Complete answer'},
        ],
      );
      final content = StringBuffer();

      await dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: 'hi',
        appendContent: content.write,
        appendStatus: (_) {},
        updateMessage: (_) {},
        finishStreaming: () {},
        completeStreamingUi: () {},
      ).timeout(const Duration(seconds: 3));

      check(fake.getRunCalls).equals(2);
      check(content.toString()).equals('Complete answer');
    },
  );

  test('recovery stops after the configured poll budget', () async {
    final fake = _FakeHermesApiService(
      const [],
      runResult: const {'status': 'running', 'output': 'Partial'},
    );
    var message = ChatMessage(
      id: 'm',
      role: 'assistant',
      content: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );

    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      maxRecoveryPolls: 2,
      recoveryPollInterval: Duration.zero,
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    check(fake.getRunCalls).equals(2);
    check(message.error).isNotNull();
  });

  test(
    'recovery surfaces repeated successful responses with unknown status',
    () async {
      final fake = _FakeHermesApiService(
        const [],
        runResult: const {'status': 'mystery', 'output': 'not final'},
      );
      var message = ChatMessage(
        id: 'm',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );

      await dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: 'hi',
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      ).timeout(const Duration(seconds: 4));

      check(fake.getRunCalls).equals(3);
      check(message.error).isNotNull();
    },
  );
}
