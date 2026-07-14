import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit/features/hermes/services/hermes_stream_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestActiveConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _FakeHermesApiService extends HermesApiService {
  _FakeHermesApiService(
    this.events, {
    this.runResult = const {},
    this.runResults = const [],
    this.eventsOverride,
    this.runStreamError,
    this.eventStreamLimits,
    this.createRunGate,
    this.createRunError,
    this.createRunErrorStack,
    this.getRunGate,
    this.getRunError,
    this.stopRunGate,
    this.stopRunError,
    this.responseEvents = const [],
    this.responseEventsOverride,
    this.responseStreamError,
    this.responseEventStreamLimits,
    this.responseSessionId,
    this.responseResult = const {},
    this.responseResults,
    this.getResponseError,
    this.getResponseErrorStack,
    this.cancelTokenOnCreateError = false,
    this.cancelTokenOnStreamError = false,
    this.cancelTokenOnRecoveryError = false,
    HermesConfig? serviceConfig,
    HermesStreamLimits serviceStreamLimits = const HermesStreamLimits(),
  }) : super(
         config:
             serviceConfig ??
             HermesConfig(enabled: true, baseUrl: 'http://x', apiKey: 'k'),
         dio: Dio(),
         streamLimits: serviceStreamLimits,
       );

  final List<HermesRunEvent> events;
  final Map<String, dynamic> runResult;
  final List<Map<String, dynamic>> runResults;
  final Stream<HermesRunEvent>? eventsOverride;
  final Object? runStreamError;
  final HermesStreamLimits? eventStreamLimits;
  final Completer<String>? createRunGate;
  final Object? createRunError;
  final StackTrace? createRunErrorStack;
  final Completer<Map<String, dynamic>>? getRunGate;
  final Object? getRunError;
  final Completer<void>? stopRunGate;
  final Object? stopRunError;
  final List<HermesRunEvent> responseEvents;
  final Stream<HermesRunEvent>? responseEventsOverride;
  final Object? responseStreamError;
  final HermesStreamLimits? responseEventStreamLimits;
  final String? responseSessionId;
  final Map<String, dynamic> responseResult;
  final List<Map<String, dynamic>>? responseResults;
  final Object? getResponseError;
  final StackTrace? getResponseErrorStack;
  final bool cancelTokenOnCreateError;
  final bool cancelTokenOnStreamError;
  final bool cancelTokenOnRecoveryError;
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
  }) async {
    final error = createRunError;
    if (error != null) {
      if (cancelTokenOnCreateError && cancelToken != null) {
        signalHermesInternalCancellation(cancelToken);
      }
      final stackTrace = createRunErrorStack;
      if (stackTrace != null) Error.throwWithStackTrace(error, stackTrace);
      throw error;
    }
    return createRunGate?.future ?? 'run-1';
  }

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) {
    final streamError = runStreamError;
    final source = streamError == null
        ? (eventsOverride ?? Stream<HermesRunEvent>.fromIterable(events))
        : _failedHermesStream(
            streamError,
            cancelToken: cancelToken,
            cancelBeforeError: cancelTokenOnStreamError,
          );
    final limits = eventStreamLimits;
    if (limits == null) return source;
    return guardHermesEventStream(
      source,
      cancelToken: cancelToken ?? CancelToken(),
      limits: limits,
    );
  }

  @override
  Future<Map<String, dynamic>> getRun(
    String runId, {
    CancelToken? cancelToken,
  }) async {
    final index = getRunCalls++;
    if (getRunGate != null) return getRunGate!.future;
    final error = getRunError;
    if (error != null) {
      if (cancelTokenOnRecoveryError &&
          cancelToken != null &&
          !cancelToken.isCancelled) {
        signalHermesInternalCancellation(cancelToken);
      }
      throw error;
    }
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
    final streamError = responseStreamError;
    final source = streamError == null
        ? (responseEventsOverride ??
              Stream<HermesRunEvent>.fromIterable(responseEvents))
        : _failedHermesStream(
            streamError,
            cancelToken: cancelToken,
            cancelBeforeError: cancelTokenOnStreamError,
          );
    final limits = responseEventStreamLimits;
    return HermesResponseStream(
      events: limits == null
          ? source
          : guardHermesEventStream(
              source,
              cancelToken: cancelToken ?? CancelToken(),
              limits: limits,
            ),
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
    if (error != null) {
      if (cancelTokenOnRecoveryError &&
          cancelToken != null &&
          !cancelToken.isCancelled) {
        signalHermesInternalCancellation(cancelToken);
      }
      final stackTrace = getResponseErrorStack;
      if (stackTrace != null) Error.throwWithStackTrace(error, stackTrace);
      throw error;
    }
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

Stream<HermesRunEvent> _failedHermesStream(
  Object error, {
  required CancelToken? cancelToken,
  required bool cancelBeforeError,
}) async* {
  if (cancelBeforeError && cancelToken != null && !cancelToken.isCancelled) {
    signalHermesInternalCancellation(cancelToken);
  }
  throw error;
}

void main() {
  test('OpenWebUI Hermes run identity includes authentication epoch', () {
    final database = Object();
    final api = Object();
    final epochA = Object();
    final epochB = Object();
    final identityA = HermesRunBackendIdentity.openWebUi(
      database: database,
      api: api,
      authSessionEpoch: epochA,
    );
    final sameA = HermesRunBackendIdentity.openWebUi(
      database: database,
      api: api,
      authSessionEpoch: epochA,
    );
    final identityB = HermesRunBackendIdentity.openWebUi(
      database: database,
      api: api,
      authSessionEpoch: epochB,
    );

    expect(identityA, sameA);
    expect(identityA, isNot(identityB));
  });

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

    test('many tiny response deltas reconcile in exact order', () async {
      const deltaCount = 20000;
      final expected = List<String>.filled(deltaCount, 'x').join();
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: <HermesRunEvent>[
          const HermesResponseCreated('resp-many-deltas'),
          for (var index = 0; index < deltaCount; index++)
            const HermesTokenDelta('x'),
          HermesFinalOutput(expected),
          const HermesRunDone(),
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
      ).timeout(const Duration(seconds: 5));

      check(content.length).equals(deltaCount);
      check(content.toString()).equals(expected);
    });

    test(
      'response transport applies the shared Hermes status budget',
      () async {
        const uniqueToolCount = 2000;
        final fake = _FakeHermesApiService(
          const [],
          responseEvents: [
            const HermesResponseCreated('resp-many-tools'),
            const HermesReasoningDelta('plan'),
            for (var index = 0; index < uniqueToolCount; index++)
              HermesToolProgress(toolName: 'response_tool_$index', done: false),
            for (var index = 0; index < uniqueToolCount; index++)
              HermesToolProgress(toolName: 'response_tool_$index', done: true),
            const HermesRunDone(),
          ],
        );
        final statuses = <ChatStatusUpdate>[];

        await dispatchHermesResponse(
          service: fake,
          registry: HermesRunRegistry(),
          assistantMessageId: 'm',
          input: HermesChatInput.text('hello'),
          appendContent: (_) {},
          appendStatus: statuses.add,
          updateMessage: (_) {},
          finishStreaming: () {},
          completeStreamingUi: () {},
        );

        expect(
          statuses.where((status) => status.action == 'hermes_tools_omitted'),
          hasLength(1),
        );
        expect(
          statuses
              .where(
                (status) => status.action?.startsWith('hermes_tool_') ?? false,
              )
              .length,
          (kMaxHermesStatusRowsPerTurn - 2) * 2,
        );
        expect(
          statuses.length,
          lessThanOrEqualTo(kMaxHermesStatusRowsPerTurn * 2),
        );
      },
    );

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

    test('surfaces response guard failures without recovery', () async {
      final cancelToken = CancelToken();
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: const [
          HermesTokenDelta('x'),
          HermesTokenDelta('x'),
          HermesTokenDelta('x'),
          HermesTokenDelta('x'),
        ],
        responseEventStreamLimits: const HermesStreamLimits(
          idleTimeout: Duration(seconds: 1),
          maxDuration: Duration(seconds: 1),
          maxCharacters: 3,
          maxEvents: 100,
        ),
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
        cancelToken: cancelToken,
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(cancelToken.isCancelled).isTrue();
      check(fake.getResponseCalls).equals(0);
      check(message.error).isNotNull();
      expect(message.error!.content, contains('size limit'));
    });

    test(
      'surfaces a malformed UTF-8 response stream after parser cancellation',
      () async {
        final cancelToken = CancelToken();
        final fake = _FakeHermesApiService(
          const [],
          responseStreamError: const FormatException('Invalid UTF-8 byte'),
          cancelTokenOnStreamError: true,
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
          cancelToken: cancelToken,
          appendContent: (_) {},
          appendStatus: (_) {},
          updateMessage: (updater) => message = updater(message),
          finishStreaming: () {},
          completeStreamingUi: () {},
        );

        check(cancelToken.isCancelled).isTrue();
        check(fake.getResponseCalls).equals(0);
        check(
          message.error?.content,
        ).equals('Hermes returned an invalid response.');
      },
    );

    test(
      'local response cancellation wins over queued provider failures',
      () async {
        final listened = Completer<void>();
        final events = StreamController<HermesRunEvent>(
          onListen: listened.complete,
        );
        addTearDown(() async {
          if (!events.isClosed) await events.close();
        });
        final cancelToken = CancelToken();
        final fake = _FakeHermesApiService(
          const [],
          responseEventsOverride: events.stream,
        );
        var message = ChatMessage(
          id: 'm',
          role: 'assistant',
          content: '',
          timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        );

        final dispatch = dispatchHermesResponse(
          service: fake,
          registry: HermesRunRegistry(),
          assistantMessageId: message.id,
          input: HermesChatInput.text('hello'),
          cancelToken: cancelToken,
          appendContent: (_) {},
          appendStatus: (_) {},
          updateMessage: (updater) => message = updater(message),
          finishStreaming: () {},
          completeStreamingUi: () {},
        );
        await listened.future;
        cancelToken.cancel('user stopped');
        events.add(const HermesRunError('Hermes response was cancelled.'));
        events.addError(const FormatException('truncated after stop'));
        await dispatch;

        check(message.error).isNull();
        check(fake.getResponseCalls).equals(0);
      },
    );

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

      final cancellation = registry.cancel(legacyHermesRunKey('m'));
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

    test(
      'terminal response ignores hostile subscription cleanup failures',
      () async {
        const errorSecret = 'response-cancel-error-secret';
        const stackSecret = 'response-cancel-stack-secret';
        final logs = <String>[];
        final uncaughtErrors = <Object>[];
        final previousDebugPrint = debugPrint;
        final events = StreamController<HermesRunEvent>(
          onCancel: () => Future<void>.error(
            StateError(errorSecret),
            StackTrace.fromString(stackSecret),
          ),
        );
        final content = StringBuffer();
        final cancelToken = CancelToken();
        final fake = _FakeHermesApiService(
          const [],
          responseEventsOverride: events.stream,
        );
        var finished = 0;
        var completedUi = 0;
        debugPrint = (message, {wrapWidth}) {
          if (message != null) logs.add(message);
        };

        try {
          await runZonedGuarded(() async {
            final dispatch = dispatchHermesResponse(
              service: fake,
              registry: HermesRunRegistry(),
              assistantMessageId: 'm',
              input: HermesChatInput.text('hello'),
              cancelToken: cancelToken,
              appendContent: content.write,
              appendStatus: (_) {},
              updateMessage: (_) {},
              finishStreaming: () => finished++,
              completeStreamingUi: () => completedUi++,
            );
            events.add(const HermesTokenDelta('answer'));
            events.add(const HermesFinalOutput('answer'));
            events.add(const HermesRunDone());

            await dispatch.timeout(const Duration(seconds: 1));
            await Future<void>.delayed(Duration.zero);
          }, (error, stackTrace) => uncaughtErrors.add(error));
        } finally {
          debugPrint = previousDebugPrint;
          await events.close();
        }

        check(content.toString()).equals('answer');
        check(finished).equals(1);
        check(completedUi).equals(1);
        check(cancelToken.isCancelled).isTrue();
        check(fake.lastResponseCancelToken).identicalTo(cancelToken);
        check(uncaughtErrors).isEmpty();
        final combinedLogs = logs.join('\n');
        check(combinedLogs).contains('response-subscription-cleanup-failed');
        check(combinedLogs).not((value) => value.contains(errorSecret));
        check(combinedLogs).not((value) => value.contains(stackSecret));
      },
    );

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

    test('response recovery never falls back past its output guard', () async {
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: const [HermesResponseCreated('resp-refusal')],
        responseResult: const {
          'id': 'resp-refusal',
          'object': 'response',
          'created_at': 1,
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'id': 'msg-refusal',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {'type': 'refusal', 'refusal': 'denied'},
              ],
            },
          ],
        },
        serviceStreamLimits: const HermesStreamLimits(maxCharacters: 3),
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
      check(
        message.error?.content,
      ).equals('The Hermes recovery output exceeded Conduit\'s size limit.');
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

    test('recovery errors use safe UI and value-free diagnostics', () async {
      const apiKey = 'recovery-api-secret';
      const sessionKey = 'recovery-session-secret';
      const errorSecret = 'provider-recovery-error-secret';
      const stackSecret = 'provider-recovery-stack-secret';
      final logs = <String>[];
      final previousDebugPrint = debugPrint;
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: const [HermesResponseCreated('resp-recover')],
        getResponseError: StateError(
          '$apiKey $sessionKey $errorSecret\n'
          '${List<String>.filled(1000, 'x').join()}',
        ),
        getResponseErrorStack: StackTrace.fromString(stackSecret),
        serviceConfig: const HermesConfig(
          enabled: true,
          baseUrl: 'http://x',
          apiKey: apiKey,
          sessionKey: sessionKey,
        ),
      );
      var message = ChatMessage(
        id: 'm',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );
      debugPrint = (value, {wrapWidth}) {
        if (value != null) logs.add(value);
      };

      try {
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
      } finally {
        debugPrint = previousDebugPrint;
      }

      check(fake.getResponseCalls).equals(1);
      check(message.error).isNotNull();
      check(message.error!.content).equals('Hermes run failed.');
      final combinedLogs = logs.join('\n');
      check(combinedLogs).contains('response-stream-error');
      check(combinedLogs).not((value) => value.contains(apiKey));
      check(combinedLogs).not((value) => value.contains(sessionKey));
      check(combinedLogs).not((value) => value.contains(errorSecret));
      check(combinedLogs).not((value) => value.contains(stackSecret));
    });

    test(
      'surfaces malformed stored response after decoder cancellation',
      () async {
        final fake = _FakeHermesApiService(
          const [],
          responseEvents: const [HermesResponseCreated('resp-malformed')],
          getResponseError: const FormatException('invalid recovery JSON'),
          cancelTokenOnRecoveryError: true,
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
        check(
          message.error?.content,
        ).equals('Hermes returned an invalid response.');
      },
    );

    test('recovery errors preserve a useful HTTP status', () async {
      final options = RequestOptions(path: '/v1/responses/resp-recover');
      final fake = _FakeHermesApiService(
        const [],
        responseEvents: const [HermesResponseCreated('resp-recover')],
        getResponseError: DioException(
          requestOptions: options,
          response: Response<void>(requestOptions: options, statusCode: 429),
        ),
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

      check(message.error!.content).equals('Hermes request failed (HTTP 429).');
    });
  });

  test('create-run errors use safe UI and value-free diagnostics', () async {
    const apiKey = 'create-api-secret';
    const sessionKey = 'create-session-secret';
    const stackSecret = 'create-provider-stack-secret';
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    final fake = _FakeHermesApiService(
      const [],
      createRunError: StateError(
        '$apiKey\n$sessionKey ${List<String>.filled(1000, 'x').join()}',
      ),
      createRunErrorStack: StackTrace.fromString(stackSecret),
      serviceConfig: const HermesConfig(
        enabled: true,
        baseUrl: 'http://x',
        apiKey: apiKey,
        sessionKey: sessionKey,
      ),
    );
    var message = ChatMessage(
      id: 'm',
      role: 'assistant',
      content: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );
    var finished = false;
    var completedUi = false;
    debugPrint = (value, {wrapWidth}) {
      if (value != null) logs.add(value);
    };

    try {
      await dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: message.id,
        input: 'hi',
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () => finished = true,
        completeStreamingUi: () => completedUi = true,
      );
    } finally {
      debugPrint = previousDebugPrint;
    }

    check(message.error!.content).equals('Hermes run failed.');
    check(finished).isTrue();
    check(completedUi).isTrue();
    final combinedLogs = logs.join('\n');
    check(combinedLogs).contains('create-run-failed');
    check(combinedLogs).not((value) => value.contains(apiKey));
    check(combinedLogs).not((value) => value.contains(sessionKey));
    check(combinedLogs).not((value) => value.contains(stackSecret));
  });

  test(
    'an internally cancelled create guard still surfaces invalid response',
    () async {
      final fake = _FakeHermesApiService(
        const [],
        createRunError: const FormatException('oversized create envelope'),
        cancelTokenOnCreateError: true,
      );
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
        assistantMessageId: message.id,
        input: 'hi',
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () => finished = true,
        completeStreamingUi: () => completedUi = true,
      );

      check(
        message.error?.content,
      ).equals('Hermes returned an invalid response.');
      check(finished).isTrue();
      check(completedUi).isTrue();
    },
  );

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

  test(
    'reasoning status text is bounded, redacted, and control-safe',
    () async {
      const apiKey = 'reasoning-api-secret';
      const sessionKey = 'reasoning-session-secret';
      final fake = _FakeHermesApiService(
        [
          HermesReasoningDelta(
            '$apiKey\u0000\n$sessionKey '
            'Authorization: Bearer reflected-reasoning-token '
            '${List<String>.filled(200, '😀').join()}',
          ),
          const HermesRunDone(),
        ],
        serviceConfig: const HermesConfig(
          enabled: true,
          baseUrl: 'http://x',
          apiKey: apiKey,
          sessionKey: sessionKey,
        ),
      );
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

      final description = statuses.single.description ?? '';
      check(description).startsWith('Thinking…');
      check(description).not((value) => value.contains(apiKey));
      check(description).not((value) => value.contains(sessionKey));
      check(
        description,
      ).not((value) => value.contains('reflected-reasoning-token'));
      check(description).not((value) => value.contains('\u0000'));
      check(description).not((value) => value.contains('\n'));
      check(
        description.replaceFirst('Thinking… ', '').runes.length,
      ).isLessOrEqual(kMaxHermesStatusDetailCharacters);
    },
  );

  test(
    'many distinct reasoning deltas stop mutating status after the detail cap',
    () async {
      final fragments = List<String>.generate(5000, (index) => 'r$index;');
      final fake = _FakeHermesApiService([
        for (final fragment in fragments) HermesReasoningDelta(fragment),
        const HermesRunDone(),
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

      final expectedDetail = String.fromCharCodes(
        fragments.join().runes.take(kMaxHermesStatusDetailCharacters),
      );
      expect(statuses, isNotEmpty);
      expect(
        statuses.length,
        lessThanOrEqualTo(kMaxHermesStatusDetailCharacters),
      );
      expect(statuses.every((status) => status.action == 'reasoning'), isTrue);
      expect(statuses.last.description, 'Thinking… $expectedDetail');
      expect(
        statuses.last.description!.replaceFirst('Thinking… ', '').runes.length,
        kMaxHermesStatusDetailCharacters,
      );
      expect(statuses.last.description, isNot(contains('r4999')));
    },
  );

  test(
    'many unique Hermes tools keep notifier history and mutation work bounded',
    () async {
      const uniqueToolCount = 2000;
      final fake = _FakeHermesApiService([
        const HermesReasoningDelta('plan'),
        for (var index = 0; index < uniqueToolCount; index++)
          HermesToolProgress(toolName: 'tool_$index', done: false),
        const HermesReasoningDelta(' safely'),
        for (var index = 0; index < uniqueToolCount; index++)
          HermesToolProgress(toolName: 'tool_$index', done: true),
        const HermesRunDone(),
      ]);
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        ChatMessage(
          id: 'bounded-tools',
          role: 'assistant',
          content: '',
          timestamp: DateTime.fromMillisecondsSinceEpoch(0),
          isStreaming: true,
        ),
      ]);

      var notifications = 0;
      var maxHistoryLength = 0;
      final subscription = container.listen<List<ChatMessage>>(
        chatMessagesProvider,
        (_, next) {
          notifications++;
          maxHistoryLength = max(
            maxHistoryLength,
            next.single.statusHistory.length,
          );
        },
        fireImmediately: false,
      );
      addTearDown(subscription.close);

      await dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'bounded-tools',
        input: 'hi',
        appendContent: (_) {},
        appendStatus: (update) =>
            notifier.appendStatusUpdate('bounded-tools', update),
        updateMessage: (_) {},
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      final history = container.read(chatMessagesProvider).single.statusHistory;
      expect(maxHistoryLength, kMaxHermesStatusRowsPerTurn);
      expect(history, hasLength(kMaxHermesStatusRowsPerTurn));
      expect(
        history.where((status) => status.action == 'reasoning'),
        hasLength(1),
      );
      expect(
        history
            .singleWhere((status) => status.action == 'reasoning')
            .description,
        'Thinking… plan safely',
      );
      final admittedTools = history
          .where((status) => status.action?.startsWith('hermes_tool_') ?? false)
          .toList(growable: false);
      expect(admittedTools, hasLength(kMaxHermesStatusRowsPerTurn - 2));
      expect(admittedTools.every((status) => status.done == true), isTrue);
      final overflow = history.singleWhere(
        (status) => status.action == 'hermes_tools_omitted',
      );
      expect(overflow.done, isTrue);
      expect(overflow.description, 'Additional Hermes tool activity omitted');
      expect(notifications, lessThanOrEqualTo(kMaxHermesStatusRowsPerTurn * 2));
    },
  );

  test(
    'approval summary is safe while a valid opaque id stays exact',
    () async {
      const apiKey = 'approval-api-secret';
      const sessionKey = 'approval-session-secret';
      const approvalId = 'approval_opaque-123';
      final fake = _FakeHermesApiService(
        [
          HermesApprovalRequested(
            approvalId: approvalId,
            summary:
                '$apiKey\u0000\n$sessionKey '
                'Authorization: Bearer reflected-approval-token '
                '${List<String>.filled(700, '😀').join()}',
          ),
          const HermesRunDone(),
        ],
        serviceConfig: const HermesConfig(
          enabled: true,
          baseUrl: 'http://x',
          apiKey: apiKey,
          sessionKey: sessionKey,
        ),
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
        assistantMessageId: message.id,
        input: 'hi',
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      final approval = message.metadata?[kHermesApprovalMeta] as Map;
      check(approval['approvalId']).equals(approvalId);
      final summary = approval['summary'] as String? ?? '';
      check(
        summary.runes.length,
      ).isLessOrEqual(kMaxHermesApprovalSummaryCharacters);
      check(summary).not((value) => value.contains(apiKey));
      check(summary).not((value) => value.contains(sessionKey));
      check(summary).not((value) => value.contains('reflected-approval-token'));
      check(summary).not((value) => value.contains('\u0000'));
      check(summary).not((value) => value.contains('\n'));
    },
  );

  test('unsafe approval identifiers fail closed without metadata', () async {
    const apiKey = 'approval-id-api-secret';
    final unsafeIds = <String>[
      apiKey,
      'approval\ncontrol',
      List<String>.filled(kMaxHermesOpaqueIdentifierCharacters + 1, 'a').join(),
    ];

    for (final approvalId in unsafeIds) {
      final fake = _FakeHermesApiService(
        [
          HermesApprovalRequested(approvalId: approvalId),
          const HermesRunDone(),
        ],
        serviceConfig: const HermesConfig(
          enabled: true,
          baseUrl: 'http://x',
          apiKey: apiKey,
        ),
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
        assistantMessageId: message.id,
        input: 'hi',
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(message.metadata?[kHermesApprovalMeta]).isNull();
      check(
        message.error?.content,
      ).equals('Hermes returned an invalid approval request.');
    }
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
    check(statuses.first.action).equals('hermes_tool_web_search');
    check(statuses.last)
      ..has(
        (status) => status.description,
        'description',
      ).equals('web_search failed: provider unavailable')
      ..has(
        (status) => status.action,
        'action',
      ).equals('hermes_tool_web_search')
      ..has((status) => status.done, 'done').equals(true);
  });

  test(
    'distinct terminal-only invocations of the same tool remain visible',
    () async {
      final fake = _FakeHermesApiService(const [
        HermesToolProgress(
          toolName: 'web_search',
          done: true,
          detail: 'timeout',
          failed: true,
        ),
        HermesToolProgress(
          toolName: 'web_search',
          done: true,
          detail: 'permission denied',
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

      check(statuses.map((status) => status.description).toList()).deepEquals([
        'web_search failed: timeout',
        'web_search failed: permission denied',
      ]);
    },
  );

  test('exact duplicate terminal tool frames are suppressed', () async {
    const terminal = HermesToolProgress(
      toolName: 'web_search',
      done: true,
      detail: 'timeout',
      failed: true,
    );
    final fake = _FakeHermesApiService(const [
      terminal,
      terminal,
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

    check(statuses).length.equals(1);
    check(statuses.single.description).equals('web_search failed: timeout');
  });

  test(
    'hostile tool names are bounded, redacted, and keep stable identity',
    () async {
      const apiKey = 'tool-api-secret';
      const sessionKey = 'tool-session-secret';
      final hostileName =
          '$apiKey\u0000\n$sessionKey '
          'Authorization: Bearer reflected-token '
          '${List<String>.filled(1000, 'x').join()}';
      final fake = _FakeHermesApiService(
        [
          HermesToolProgress(toolName: hostileName, done: false),
          HermesToolProgress(
            toolName: hostileName,
            done: true,
            detail: 'failed safely',
            failed: true,
          ),
          const HermesRunDone(),
        ],
        serviceConfig: const HermesConfig(
          enabled: true,
          baseUrl: 'http://x',
          apiKey: apiKey,
          sessionKey: sessionKey,
        ),
      );
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
      final started = statuses.first;
      final completed = statuses.last;
      check(started.action).equals(completed.action);
      final action = started.action;
      final description = started.description;
      check(action).isNotNull();
      check(description).isNotNull();
      expect(action, matches(r'^hermes_tool_opaque_[0-9a-f]{16}$'));
      check(
        description!.runes.length,
      ).isLessOrEqual(kMaxHermesToolNameCharacters);
      final persisted = <String>[
        started.action ?? '',
        started.description ?? '',
        completed.action ?? '',
        completed.description ?? '',
      ].join('\n');
      check(persisted).not((value) => value.contains(apiKey));
      check(persisted).not((value) => value.contains(sessionKey));
      check(persisted).not((value) => value.contains('reflected-token'));
      check(persisted).not((value) => value.contains('\u0000'));
      expect(completed.description, endsWith('failed: failed safely'));
    },
  );

  test('a credential-only tool name uses a neutral stable label', () async {
    const apiKey = 'tool-name-is-the-api-key';
    final fake = _FakeHermesApiService(
      const [
        HermesToolProgress(toolName: apiKey, done: false),
        HermesToolProgress(toolName: apiKey, done: true),
        HermesRunDone(),
      ],
      serviceConfig: const HermesConfig(
        enabled: true,
        baseUrl: 'http://x',
        apiKey: apiKey,
      ),
    );
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

    check(
      statuses.map((status) => status.description).toList(),
    ).deepEquals(['Hermes tool', 'Hermes tool']);
    check(statuses.first.action).equals(statuses.last.action);
    check(statuses.first.action ?? '').not((value) => value.contains(apiKey));
  });

  test(
    'opaque tool identities stay distinct after display truncation',
    () async {
      final sharedPrefix = List<String>.filled(100, 'p').join();
      final firstName = '${sharedPrefix}a';
      final secondName = '${sharedPrefix}b';
      final fake = _FakeHermesApiService([
        HermesToolProgress(toolName: firstName, done: false),
        HermesToolProgress(toolName: secondName, done: false),
        HermesToolProgress(toolName: firstName, done: true),
        HermesToolProgress(toolName: secondName, done: true),
        const HermesRunDone(),
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

      check(statuses).length.equals(4);
      check(statuses[0].description).equals(statuses[1].description);
      check(statuses[0].action).equals(statuses[2].action);
      check(statuses[1].action).equals(statuses[3].action);
      expect(statuses[0].action, isNot(equals(statuses[1].action)));
    },
  );

  test('run error events are bounded, redacted, and control-safe', () async {
    const apiKey = 'event-api-secret';
    const sessionKey = 'event-session-secret';
    final fake = _FakeHermesApiService(
      [
        HermesRunError(
          '$apiKey\u0000\n$sessionKey '
          'Authorization: Bearer reflected-token '
          '${List<String>.filled(1000, 'x').join()}',
        ),
      ],
      serviceConfig: const HermesConfig(
        enabled: true,
        baseUrl: 'http://x',
        apiKey: apiKey,
        sessionKey: sessionKey,
      ),
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
      assistantMessageId: message.id,
      input: 'hi',
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    final error = message.error?.content ?? '';
    check(error).not((value) => value.contains(apiKey));
    check(error).not((value) => value.contains(sessionKey));
    check(error).not((value) => value.contains('reflected-token'));
    check(error).not((value) => value.contains('\u0000'));
    check(error).not((value) => value.contains('\n'));
    check(error.runes.length).isLessOrEqual(kMaxHermesProviderErrorCharacters);
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

  test('many tiny run deltas reconcile in exact order', () async {
    const deltaCount = 20000;
    final expected = List<String>.filled(deltaCount, 'y').join();
    final fake = _FakeHermesApiService(<HermesRunEvent>[
      for (var index = 0; index < deltaCount; index++)
        const HermesTokenDelta('y'),
      HermesFinalOutput(expected),
      const HermesRunDone(),
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
    ).timeout(const Duration(seconds: 5));

    check(content.length).equals(deltaCount);
    check(content.toString()).equals(expected);
  });

  test('surfaces run guard failures without recovery', () async {
    final cancelToken = CancelToken();
    final fake = _FakeHermesApiService(
      const [
        HermesTokenDelta('x'),
        HermesTokenDelta('x'),
        HermesTokenDelta('x'),
        HermesTokenDelta('x'),
      ],
      eventStreamLimits: const HermesStreamLimits(
        idleTimeout: Duration(seconds: 1),
        maxDuration: Duration(seconds: 1),
        maxCharacters: 3,
        maxEvents: 100,
      ),
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
      assistantMessageId: message.id,
      input: 'hello',
      cancelToken: cancelToken,
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    check(cancelToken.isCancelled).isTrue();
    check(fake.getRunCalls).equals(0);
    check(message.error).isNotNull();
    expect(message.error!.content, contains('size limit'));
  });

  test(
    'surfaces a malformed UTF-8 run stream after parser cancellation',
    () async {
      final cancelToken = CancelToken();
      final fake = _FakeHermesApiService(
        const [],
        runStreamError: const FormatException('Invalid UTF-8 byte'),
        cancelTokenOnStreamError: true,
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
        assistantMessageId: message.id,
        input: 'hello',
        cancelToken: cancelToken,
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(cancelToken.isCancelled).isTrue();
      check(fake.getRunCalls).equals(0);
      check(
        message.error?.content,
      ).equals('Hermes returned an invalid response.');
    },
  );

  test('local run cancellation wins over queued provider failures', () async {
    final listened = Completer<void>();
    final events = StreamController<HermesRunEvent>(
      onListen: listened.complete,
    );
    addTearDown(() async {
      if (!events.isClosed) await events.close();
    });
    final cancelToken = CancelToken();
    final fake = _FakeHermesApiService(const [], eventsOverride: events.stream);
    var message = ChatMessage(
      id: 'm',
      role: 'assistant',
      content: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final dispatch = dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: message.id,
      input: 'hello',
      cancelToken: cancelToken,
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () {},
      completeStreamingUi: () {},
    );
    await listened.future;
    cancelToken.cancel('user stopped');
    events.add(const HermesRunError('Hermes run was cancelled.'));
    events.addError(const FormatException('truncated after stop'));
    await dispatch;

    check(message.error).isNull();
    check(fake.getRunCalls).equals(0);
  });

  test('streamed remote cancellation is not reported as success', () async {
    for (final status in const ['cancelled', 'canceled', 'stopped']) {
      final fake = _FakeHermesApiService(
        const [],
        eventsOverride: parseHermesRunStream(
          Stream<List<int>>.value(
            utf8.encode(
              'event: run.$status\n'
              'data: {"output":"Partial answer"}\n\n',
            ),
          ),
        ),
      );
      var message = ChatMessage(
        id: 'm-$status',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final content = StringBuffer();

      await dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: message.id,
        input: 'hello',
        appendContent: content.write,
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(content.toString()).equals('Partial answer');
      check(message.error?.content).equals(
        status == 'stopped'
            ? 'Hermes run was stopped.'
            : 'Hermes run was cancelled.',
      );
      check(fake.getRunCalls).equals(0);
    }
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
    final cancelToken = CancelToken();
    final dispatch = dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      cancelToken: cancelToken,
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    events.add(const HermesRunDone());
    await dispatch.timeout(const Duration(seconds: 1));
    check(cancelToken.isCancelled).isTrue();
  });

  test('terminal run ignores hostile subscription cleanup failures', () async {
    const errorSecret = 'run-cancel-error-secret';
    const stackSecret = 'run-cancel-stack-secret';
    final logs = <String>[];
    final uncaughtErrors = <Object>[];
    final previousDebugPrint = debugPrint;
    final events = StreamController<HermesRunEvent>(
      onCancel: () => Future<void>.error(
        StateError(errorSecret),
        StackTrace.fromString(stackSecret),
      ),
    );
    final cancelToken = CancelToken();
    var finished = 0;
    var completedUi = 0;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };

    try {
      await runZonedGuarded(() async {
        final dispatch = dispatchHermesRun(
          service: _FakeHermesApiService(
            const [],
            eventsOverride: events.stream,
          ),
          registry: HermesRunRegistry(),
          assistantMessageId: 'm',
          input: 'hi',
          cancelToken: cancelToken,
          appendContent: (_) {},
          appendStatus: (_) {},
          updateMessage: (_) {},
          finishStreaming: () => finished++,
          completeStreamingUi: () => completedUi++,
        );
        events.add(const HermesRunDone());

        await dispatch.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(Duration.zero);
      }, (error, stackTrace) => uncaughtErrors.add(error));
    } finally {
      debugPrint = previousDebugPrint;
      await events.close();
    }

    check(finished).equals(1);
    check(completedUi).equals(1);
    check(cancelToken.isCancelled).isTrue();
    check(uncaughtErrors).isEmpty();
    final combinedLogs = logs.join('\n');
    check(combinedLogs).contains('run-subscription-cleanup-failed');
    check(combinedLogs).not((value) => value.contains(errorSecret));
    check(combinedLogs).not((value) => value.contains(stackSecret));
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

    registry.cancel(legacyHermesRunKey('m'));
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

    registry.cancel(legacyHermesRunKey('m'));
    createGate.complete('run-late');
    await dispatch.timeout(const Duration(seconds: 1));

    check(fake.stoppedRuns).deepEquals(['run-late']);
    check(fake.lastStopCancelToken).isNotNull();
    check(identical(fake.lastStopCancelToken, runToken)).isFalse();
    check(fake.lastStopCancelToken!.isCancelled).isTrue();
    stopGate.complete();
  });

  test('local Stop completes cleanup without a cancellation error', () async {
    final events = StreamController<HermesRunEvent>();
    addTearDown(events.close);
    final registry = HermesRunRegistry();
    final fake = _FakeHermesApiService(const [], eventsOverride: events.stream);
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

    while (registry.runIdFor(legacyHermesRunKey('m')) == null) {
      await Future<void>.delayed(Duration.zero);
    }
    final stop = registry.cancel(legacyHermesRunKey('m'));
    check(stop).isNotNull();
    await stop!;

    await dispatch.timeout(const Duration(seconds: 1));
    check(registry.runIdFor(legacyHermesRunKey('m'))).isNull();
    check(fake.stoppedRuns).deepEquals(['run-1']);
    check(message.error).isNull();
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

      while (registry.runIdFor(legacyHermesRunKey('m')) == null) {
        await Future<void>.delayed(Duration.zero);
      }
      final cancellation = registry.cancel(legacyHermesRunKey('m'));
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

  test('surfaces oversized run recovery after decoder cancellation', () async {
    final fake = _FakeHermesApiService(
      const [],
      getRunError: const HermesStreamGuardException(
        'The Hermes recovery response exceeded Conduit\'s transfer limit.',
      ),
      cancelTokenOnRecoveryError: true,
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
      assistantMessageId: message.id,
      input: 'hello',
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    check(fake.getRunCalls).equals(1);
    check(message.error?.content).equals(
      'The Hermes recovery response exceeded Conduit\'s transfer limit.',
    );
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
